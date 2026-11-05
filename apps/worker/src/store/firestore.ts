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
  /**
   * Short memory cache (per Worker instance) for the documents read on almost every
   * request: the user, the gym and the gym's roster. It saves 1–3 round trips to
   * Firestore (~0.3 s each). Writes from this instance update it at once; writes
   * from other instances show up within CACHE_MS.
   */
  private cache = new Map<string, { v: unknown; until: number }>();
  static CACHE_MS = 8000;
  private static cacheable = /^(users\/[^/]+|tenants\/[^/]+|tenants\/[^/]+\/roster\/main|settings\/platform)$/;
  private cached(path: string): { hit: boolean; v: unknown } {
    const e = this.cache.get(path);
    if (e && e.until > Date.now()) return { hit: true, v: structuredClone(e.v) };
    if (e) this.cache.delete(path);
    return { hit: false, v: null };
  }
  private remember(path: string, v: unknown) {
    if (!FirestoreStore.cacheable.test(path)) return;
    if (this.cache.size > 500) this.cache.clear();
    this.cache.set(path, { v: structuredClone(v), until: Date.now() + FirestoreStore.CACHE_MS });
  }
  private forget(path: string) {
    this.cache.delete(path);
  }
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

  /** Database calls and time spent, for the slow-request log. */
  calls = 0;
  callMs = 0;
  tokMs = 0;
  private async call(method: string, url: string, body?: unknown): Promise<any> {
    this.calls++;
    const t0 = Date.now();
    try {
      return await this.call0(method, url, body);
    } finally {
      this.callMs += Date.now() - t0;
    }
  }

  private async call0(method: string, url: string, body?: unknown): Promise<any> {
    const tt = Date.now();
    const tok = await this.token();
    this.tokMs += Date.now() - tt;
    const res = await fetch(url, {
      method,
      headers: { Authorization: `Bearer ${tok}`, 'content-type': 'application/json' },
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

  async get<T>(path: string) {
    const c = this.cached(path);
    if (c.hit) return c.v as T | null;
    const v = await this.getIn<T>(path);
    this.remember(path, v);
    return v;
  }
  async getMany<T>(paths: string[]) {
    const out: (T | null)[] = new Array(paths.length);
    const need: number[] = [];
    paths.forEach((p, i) => {
      const c = this.cached(p);
      if (c.hit) out[i] = c.v as T | null;
      else need.push(i);
    });
    if (need.length) {
      const got = await this.getManyIn<T>(need.map((i) => paths[i]));
      need.forEach((i, k) => {
        out[i] = got[k];
        this.remember(paths[i], got[k]);
      });
    }
    return out;
  }
  query<T>(collection: string, where?: Where) {
    return this.queryIn<T>(collection, where);
  }
  async set(path: string, data: Doc) {
    this.forget(path);
    await this.call('POST', `${this.base}:commit`, { writes: [{ update: { name: this.name(path), fields: encFields(data) } }] });
    this.remember(path, data);
  }
  async delete(path: string) {
    this.forget(path);
    await this.call('POST', `${this.base}:commit`, { writes: [{ delete: this.name(path) }] });
  }

  async dump(after: string | null, limit: number) {
    // A query over every collection at every depth, in document-name order.
    const structuredQuery: any = { from: [{ allDescendants: true }], orderBy: [{ field: { fieldPath: '__name__' }, direction: 'ASCENDING' }], limit };
    if (after) structuredQuery.startAt = { values: [{ referenceValue: this.name(after) }], before: false };
    const res: any[] = await this.call('POST', `${this.base}:runQuery`, { structuredQuery });
    const prefix = this.name('');
    return res.filter((r) => r.document).map((r) => ({ p: (r.document.name as string).slice(prefix.length), d: decFields(r.document.fields ?? {}) }));
  }

  async load(rows: { p: string; d: Doc }[]) {
    for (let i = 0; i < rows.length; i += 400) {
      const part = rows.slice(i, i + 400);
      for (const r of part) this.forget(r.p);
      await this.call('POST', `${this.base}:commit`, { writes: part.map((r) => ({ update: { name: this.name(r.p), fields: encFields(r.d) } })) });
    }
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
      const plain = new Map<string, Doc | null>(); // path -> new value (null = deleted), for the cache
      const seen = new Map<string, unknown>(); // documents already read in this attempt (read once, reuse)
      const readMany = async <T,>(paths: string[]) => {
        if (!paths.length) return [] as (T | null)[];
        const todo = [...new Set(paths.filter((p) => !seen.has(this.name(p))))];
        if (!todo.length) return paths.map((p) => structuredClone(seen.get(this.name(p)) ?? null) as T | null);
        const res: any[] = await this.call('POST', `${this.base}:batchGet`, { documents: todo.map((p) => this.name(p)) });
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
        for (const [n, v] of byName) seen.set(n, v);
        return paths.map((p) => structuredClone(seen.get(this.name(p)) ?? null) as T | null);
      };
      const t: Tx = {
        get: async (p) => (await readMany<any>([p]))[0],
        getMany: (ps) => readMany(ps),
        query: (c, w) => this.queryIn(c, w),
        set: (p, d) => {
          plain.set(p, d);
          writes.set(this.name(p), { update: { name: this.name(p), fields: encFields(d) } });
        },
        create: (p, d) => {
          plain.set(p, d);
          creates.add(this.name(p));
          writes.set(this.name(p), { update: { name: this.name(p), fields: encFields(d) } });
        },
        delete: (p) => {
          plain.set(p, null);
          writes.set(this.name(p), { delete: this.name(p) });
        },
      };
      const r = await fn(t);
      if (!writes.size) return r;
      const list = [...writes.entries()].map(([name, w]) => {
        if (creates.has(name)) return { ...w, currentDocument: { exists: false } };
        if (!versions.has(name)) return w;
        const v = versions.get(name);
        return { ...w, currentDocument: v ? { updateTime: v } : { exists: false } };
      });
      for (const p of plain.keys()) this.forget(p);
      try {
        await this.call('POST', `${this.base}:commit`, { writes: list });
        for (const [p, d] of plain) this.remember(p, d);
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
