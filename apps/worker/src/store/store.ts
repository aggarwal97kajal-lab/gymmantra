// Small document-store interface. FirestoreStore talks to Firebase over REST;
// MemoryStore is used by tests and the local preview. Paths look like
// "tenants/abc/members/xyz". Queries are equality-only on one collection, so
// Firestore needs no composite indexes.

export type Doc = Record<string, any>;
export interface Row<T = Doc> {
  id: string;
  data: T;
}
export type Where = [field: string, value: string | number | boolean | null][];

export interface Reader {
  get<T = Doc>(path: string): Promise<T | null>;
  getMany<T = Doc>(paths: string[]): Promise<(T | null)[]>;
  query<T = Doc>(collection: string, where?: Where): Promise<Row<T>[]>;
}

export interface Tx extends Reader {
  set(path: string, data: Doc): void;
  /** Fails the whole transaction if the document already exists. */
  create(path: string, data: Doc): void;
  delete(path: string): void;
}

export interface Store extends Reader {
  /** Runs fn atomically. Retried on contention, so fn must have no side effects. */
  tx<R>(fn: (t: Tx) => Promise<R>): Promise<R>;
  set(path: string, data: Doc): Promise<void>;
  delete(path: string): Promise<void>;
}

export class AlreadyExists extends Error {
  constructor(public path: string) {
    super(`Already exists: ${path}`);
  }
}

const clone = <T>(v: T): T => (v === undefined ? v : JSON.parse(JSON.stringify(v)));

function matches(d: Doc, where: Where) {
  return where.every(([f, v]) => {
    let cur: any = d;
    for (const k of f.split('.')) cur = cur?.[k];
    return (cur ?? null) === v;
  });
}

export class MemoryStore implements Store {
  docs = new Map<string, Doc>();
  private lock: Promise<unknown> = Promise.resolve();

  async get<T>(path: string) {
    return (clone(this.docs.get(path)) as T) ?? null;
  }
  async getMany<T>(paths: string[]) {
    return Promise.all(paths.map((p) => this.get<T>(p)));
  }
  async query<T>(collection: string, where: Where = []) {
    const depth = collection.split('/').length + 1;
    const out: Row<T>[] = [];
    for (const [p, d] of this.docs) {
      if (p.startsWith(`${collection}/`) && p.split('/').length === depth && matches(d, where)) {
        out.push({ id: p.slice(collection.length + 1), data: clone(d) as T });
      }
    }
    return out;
  }
  async set(path: string, data: Doc) {
    this.docs.set(path, clone(data));
  }
  async delete(path: string) {
    this.docs.delete(path);
  }
  async tx<R>(fn: (t: Tx) => Promise<R>): Promise<R> {
    // Serialise transactions so tests see the same behaviour as Firestore.
    const run = async () => {
      const writes: [string, Doc | null, boolean][] = [];
      const t: Tx = {
        get: (p) => this.get(p),
        getMany: (ps) => this.getMany(ps),
        query: (c, w) => this.query(c, w),
        set: (p, d) => void writes.push([p, clone(d), false]),
        create: (p, d) => void writes.push([p, clone(d), true]),
        delete: (p) => void writes.push([p, null, false]),
      };
      const r = await fn(t);
      for (const [p, d, mustNotExist] of writes) if (mustNotExist && this.docs.has(p)) throw new AlreadyExists(p);
      for (const [p, d] of writes) d === null ? this.docs.delete(p) : this.docs.set(p, d);
      return r;
    };
    const next = this.lock.then(run, run);
    this.lock = next.catch(() => undefined);
    return next;
  }
}
