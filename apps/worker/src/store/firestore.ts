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
    const text = await res.text(); // always read the body so the connection is released
    if (res.status === 404 && method === 'GET') return null;
    let data: any = {};
    try {
      data = text ? JSON.parse(text) : {};
    } catch {
      /* not JSON */
    }
    if (!res.ok) {
      const status = data?.error?.status ?? '';
      if (status === 'ALREADY_EXISTS' || (status === 'FAILED_PRECONDITION' && /exist/i.test(data?.error?.message ?? ''))) throw new AlreadyExists('');
      const op = url.split('/documents')[1]?.split('?')[0] || url;
      const err = new Error(`Firestore ${res.status} ${status} on ${method} ${op}: ${data?.error?.message ?? ''}`);
      (err as any).fsStatus = status;
      throw err;
    }
    return data;
  }

  private async getIn<T>(path: string, transaction?: string): Promise<T | null> {
    // Inside a transaction, reads go through batchGet (as the official SDKs do).
    if (transaction) return (await this.getManyIn<T>([path], transaction))[0];
    const d = await this.call('GET', `${this.base}/${path}`);
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

  /**
   * Atomic read-then-write without Firestore server transactions (signed-in
   * Firebase users may not start them over REST). Every document read is
   * remembered with its version; the commit only succeeds if none of the
   * written documents changed in the meantime. On a clash the whole function
   * runs again.
   */
  async tx<R>(fn: (t: Tx) => Promise<R>): Promise<R> {
    for (let attempt = 0; ; attempt++) {
      const versions = new Map<string, string | null>(); // doc name -> updateTime (null = missing)
      const creates = new Set<string>();
      const writes = new Map<string, any>();
      const readMany = async <T,>(paths: string[]) => {
        if (!paths.length) return [] as (T | null)[];
        const res: any[] = await this.call('POST', `${this.base}:batchGet`, { documents: paths.map((p) => this.name(p)) });
        const byName = new Map<string, T | null>();
        for (const r of res) {
          if (r.found) {
            byName.set(r.found.name, decFields(r.found.fields ?? {}) as T);
            if (!versions.has(r.found.name)) versions.set(r.found.name, r.found.updateTime);
          } else if (r.missing) {
            byName.set(r.missing, null);
            if (!versions.has(r.missing)) versions.set(r.missing, null);
          }
        }
        return paths.map((p) => byName.get(this.name(p)) ?? null);
      };
      const t: Tx = {
        get: async (p) => (await readMany<any>([p]))[0],
        getMany: (ps) => readMany(ps),
        query: (c, w) => this.queryIn(c, w),
        set: (p, d) => void writes.set(this.name(p), { update: { name: this.name(p), fields: encFields(d) } }),
        create: (p, d) => {
          creates.add(this.name(p));
          writes.set(this.name(p), { update: { name: this.name(p), fields: encFields(d) } });
        },
        delete: (p) => void writes.set(this.name(p), { delete: this.name(p) }),
      };
      const r = await fn(t);
      if (!writes.size) return r;
      const list = [...writes.entries()].map(([name, w]) => {
        if (creates.has(name)) return { ...w, currentDocument: { exists: false } };
        if (!versions.has(name)) return w;
        const v = versions.get(name);
        return { ...w, currentDocument: v ? { updateTime: v } : { exists: false } };
      });
      try {
        await this.call('POST', `${this.base}:commit`, { writes: list });
        return r;
      } catch (e: any) {
        const clash = e instanceof AlreadyExists || e?.fsStatus === 'FAILED_PRECONDITION' || e?.fsStatus === 'ABORTED' || e?.fsStatus === 'NOT_FOUND';
        if (!clash) throw e;
        // An explicit create that hits an existing document is a real conflict, not a race.
        if (creates.size) {
          const now = await this.getManyIn<any>([...creates].map((n) => n.split('/documents/')[1]));
          if (now.some((d) => d !== null)) throw new AlreadyExists('');
        }
        if (attempt >= 5) throw new Error('The database was busy. Please try again.');
      }
    }
  }

}
