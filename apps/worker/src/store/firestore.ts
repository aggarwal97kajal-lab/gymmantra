import { AlreadyExists, Doc, Row, Store, Tx, Where } from './store';

// Firestore REST client. Authenticates as the GymMantra server account
// (a Firebase Auth user). Firestore security rules allow only that account.

type Value = Record<string, any>;

function enc(v: any): Value {
  if (v === null || v === undefined) return { nullValue: null };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (typeof v === 'number') return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === 'string') return { stringValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(enc) } };
  if (typeof v === 'object') return { mapValue: { fields: encFields(v) } };
  throw new Error(`Cannot store ${typeof v}`);
}
function encFields(o: Doc): Record<string, Value> {
  const f: Record<string, Value> = {};
  for (const [k, v] of Object.entries(o)) if (v !== undefined) f[k] = enc(v);
  return f;
}
function dec(v: Value): any {
  if ('nullValue' in v) return null;
  if ('booleanValue' in v) return v.booleanValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('stringValue' in v) return v.stringValue;
  if ('timestampValue' in v) return v.timestampValue;
  if ('arrayValue' in v) return (v.arrayValue.values ?? []).map(dec);
  if ('mapValue' in v) return decFields(v.mapValue.fields ?? {});
  return null;
}
function decFields(f: Record<string, Value>): Doc {
  const o: Doc = {};
  for (const [k, v] of Object.entries(f)) o[k] = dec(v);
  return o;
}

export class FirestoreStore implements Store {
  private base: string;
  constructor(
    private projectId: string,
    private token: () => Promise<string>,
    host = 'https://firestore.googleapis.com', // the Firebase emulator in tests
  ) {
    this.base = `${host}/v1/projects/${projectId}/databases/(default)/documents`;
  }

  private name(path: string) {
    return `projects/${this.projectId}/databases/(default)/documents/${path}`;
  }

  private async call(method: string, url: string, body?: unknown): Promise<any> {
    const res = await fetch(url, {
      method,
      headers: { Authorization: `Bearer ${await this.token()}`, 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (res.status === 404 && method === 'GET') return null;
    const data: any = await res.json().catch(() => ({}));
    if (!res.ok) {
      const status = data?.error?.status ?? '';
      if (status === 'ALREADY_EXISTS' || (status === 'FAILED_PRECONDITION' && /exist/i.test(data?.error?.message ?? ''))) throw new AlreadyExists('');
      const err = new Error(`Firestore ${res.status} ${status}: ${data?.error?.message ?? ''}`);
      (err as any).fsStatus = status;
      throw err;
    }
    return data;
  }

  private async getIn<T>(path: string, transaction?: string): Promise<T | null> {
    const d = await this.call('GET', `${this.base}/${path}${transaction ? `?transaction=${encodeURIComponent(transaction)}` : ''}`);
    return d ? (decFields(d.fields ?? {}) as T) : null;
  }

  private async getManyIn<T>(paths: string[], transaction?: string): Promise<(T | null)[]> {
    if (!paths.length) return [];
    const res: any[] = await this.call('POST', `${this.base}:batchGet`, { documents: paths.map((p) => this.name(p)), ...(transaction ? { transaction } : {}) });
    const byName = new Map<string, T | null>();
    for (const r of res) {
      if (r.found) byName.set(r.found.name, decFields(r.found.fields ?? {}) as T);
      else if (r.missing) byName.set(r.missing, null);
    }
    return paths.map((p) => byName.get(this.name(p)) ?? null);
  }

  private async queryIn<T>(collection: string, where: Where = [], transaction?: string): Promise<Row<T>[]> {
    const parts = collection.split('/');
    const collectionId = parts.pop()!;
    const parent = parts.length ? `${this.base}/${parts.join('/')}` : this.base;
    const filters = where.map(([field, value]) => ({ fieldFilter: { field: { fieldPath: field }, op: 'EQUAL', value: enc(value) } }));
    const structuredQuery: any = { from: [{ collectionId }] };
    if (filters.length === 1) structuredQuery.where = filters[0];
    else if (filters.length > 1) structuredQuery.where = { compositeFilter: { op: 'AND', filters } };
    const res: any[] = await this.call('POST', `${parent}:runQuery`, { structuredQuery, ...(transaction ? { transaction } : {}) });
    return res
      .filter((r) => r.document)
      .map((r) => ({ id: (r.document.name as string).split('/').pop()!, data: decFields(r.document.fields ?? {}) as T }));
  }

  get<T>(path: string) {
    return this.getIn<T>(path);
  }
  getMany<T>(paths: string[]) {
    return this.getManyIn<T>(paths);
  }
  query<T>(collection: string, where?: Where) {
    return this.queryIn<T>(collection, where);
  }
  async set(path: string, data: Doc) {
    await this.call('POST', `${this.base}:commit`, { writes: [{ update: { name: this.name(path), fields: encFields(data) } }] });
  }
  async delete(path: string) {
    await this.call('POST', `${this.base}:commit`, { writes: [{ delete: this.name(path) }] });
  }

  async tx<R>(fn: (t: Tx) => Promise<R>): Promise<R> {
    for (let attempt = 0; ; attempt++) {
      const { transaction } = await this.call('POST', `${this.base}:beginTransaction`, { options: { readWrite: {} } });
      const writes: any[] = [];
      const t: Tx = {
        get: (p) => this.getIn(p, transaction),
        getMany: (ps) => this.getManyIn(ps, transaction),
        query: (c, w) => this.queryIn(c, w, transaction),
        set: (p, d) => void writes.push({ update: { name: this.name(p), fields: encFields(d) } }),
        create: (p, d) => void writes.push({ update: { name: this.name(p), fields: encFields(d) }, currentDocument: { exists: false } }),
        delete: (p) => void writes.push({ delete: this.name(p) }),
      };
      try {
        const r = await fn(t);
        await this.call('POST', `${this.base}:commit`, { writes, transaction });
        return r;
      } catch (e: any) {
        const retry = (e?.fsStatus === 'ABORTED' || e?.fsStatus === 'UNAVAILABLE') && attempt < 4;
        if (!retry) {
          if (!(e instanceof AlreadyExists) && !e?.fsStatus) {
            await this.call('POST', `${this.base}:rollback`, { transaction }).catch(() => undefined);
          }
          throw e;
        }
      }
    }
  }
}
