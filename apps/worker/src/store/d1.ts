// D1Store: the same small document store, on Cloudflare D1 (SQLite). Every document is one row
// (path, parent collection, collection name, JSON data, version). Free D1 allows 5 million row
// reads a day, against 50,000 document reads on free Firestore.
//
// Transactions: read rows remember their version; the commit is one D1 batch (atomic) whose first
// statement fails on purpose if any of those rows changed meanwhile, and then the whole thing re-runs.

import { AlreadyExists, Doc, Row, Store, Tx, Where } from './store';

// The parts of Cloudflare's D1 API used here (also met by the test copy over node:sqlite).
export interface D1Like {
  prepare(sql: string): D1StatementLike;
  batch(stmts: D1StatementLike[]): Promise<unknown[]>;
}
export interface D1StatementLike {
  bind(...values: unknown[]): D1StatementLike;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
  run(): Promise<unknown>;
}

/**
 * Fields used in queries on collections that grow without end get an index, so a query reads only
 * the matching rows (D1 bills every row a query looks at). Only rows of that collection are in it.
 */
const INDEXED: [coll: string, field: string][] = [
  ['users', 'email'],
  ['users', 'authEmail'],
  ['users', 'phone'],
  ['tenants', 'state'],
  ['subs', 'memberId'],
  ['attendance', 'day'],
  ['audit', 'month'],
  ['platformAudit', 'month'],
  ['tickets', 'userId'],
  ['planPayments', 'tenantId'],
  ['planPayments', 'status'],
  ['joinRequests', 'status'],
  ['pt', 'memberId'],
  ['enquiries', 'status'],
  ['enquiries', 'month'],
  ['trainerRatings', 'trainerId'],
  ['devices', 'tenantId'],
  ['scheduled', 'day'],
  ['sessions', 'uid'],
];

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS docs (path TEXT PRIMARY KEY, parent TEXT NOT NULL, coll TEXT NOT NULL, data TEXT NOT NULL, v INTEGER NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS docs_parent ON docs(parent, path)`,
  ...INDEXED.map(([c, f]) => `CREATE INDEX IF NOT EXISTS ix_${c}_${f} ON docs(parent, json_extract(data, '$.${f}')) WHERE coll = '${c}'`),
];

const SAFE = /^[A-Za-z0-9_.]+$/;
const parentOf = (path: string) => path.slice(0, path.lastIndexOf('/'));
const collOf = (parent: string) => parent.slice(parent.lastIndexOf('/') + 1);
const newV = () => Date.now() * 1000 + Math.floor(Math.random() * 1000);
const CLASH = `json('database clash')`; // makes the guard statement fail, which rolls the batch back

export class D1Store implements Store {
  private ready: Promise<void> | null = null;
  /** Same short per-instance memory cache as FirestoreStore (user, gym, roster, platform settings). */
  private cache = new Map<string, { v: unknown; until: number }>();
  static CACHE_MS = 8000;
  private static cacheable = /^(users\/[^/]+|tenants\/[^/]+|tenants\/[^/]+\/roster\/[^/]+|settings\/platform)$/;
  calls = 0;

  constructor(private db: D1Like) {}

  private cached(path: string): { hit: boolean; v: unknown } {
    const e = this.cache.get(path);
    if (e && e.until > Date.now()) return { hit: true, v: structuredClone(e.v) };
    if (e) this.cache.delete(path);
    return { hit: false, v: null };
  }
  private remember(path: string, v: unknown) {
    if (!D1Store.cacheable.test(path)) return;
    if (this.cache.size > 500) this.cache.clear();
    this.cache.set(path, { v: structuredClone(v), until: Date.now() + D1Store.CACHE_MS });
  }
  private forget(path: string) {
    this.cache.delete(path);
  }

  /** Makes the table and indexes once per Worker instance (they stay; this is quick after the first time). */
  private init() {
    this.ready ??= this.db.batch(SCHEMA.map((s) => this.db.prepare(s))).then(
      () => undefined,
      (e) => {
        this.ready = null;
        throw e;
      },
    );
    return this.ready;
  }

  private async rows(paths: string[]): Promise<Map<string, { data: string; v: number }>> {
    await this.init();
    const out = new Map<string, { data: string; v: number }>();
    const uniq = [...new Set(paths)];
    for (let i = 0; i < uniq.length; i += 90) {
      const part = uniq.slice(i, i + 90);
      this.calls++;
      const r = await this.db
        .prepare(`SELECT path, data, v FROM docs WHERE path IN (${part.map(() => '?').join(',')})`)
        .bind(...part)
        .all<{ path: string; data: string; v: number }>();
      for (const x of r.results) out.set(x.path, { data: x.data, v: x.v });
    }
    return out;
  }

  private async queryIn<T>(collection: string, where: Where = []): Promise<Row<T>[]> {
    await this.init();
    const coll = collOf(collection);
    if (!SAFE.test(coll) || where.some(([f]) => !SAFE.test(f))) throw new Error('Bad query');
    const cond = where.map(([f]) => ` AND json_extract(data, '$.${f}') IS ?`).join('');
    const vals = where.map(([, v]) => (typeof v === 'boolean' ? (v ? 1 : 0) : v));
    // SQLite would pick the plain parent index; the field index reads only the matching rows.
    const ix = where.find(([f]) => INDEXED.some(([c, x]) => c === coll && x === f));
    const hint = ix ? ` INDEXED BY ix_${coll}_${ix[0]}` : '';
    this.calls++;
    const r = await this.db
      .prepare(`SELECT path, data FROM docs${hint} WHERE coll = '${coll}' AND parent = ?${cond} ORDER BY path`)
      .bind(collection, ...vals)
      .all<{ path: string; data: string }>();
    return r.results.map((x) => ({ id: x.path.slice(x.path.lastIndexOf('/') + 1), data: JSON.parse(x.data) as T }));
  }

  private upsert(path: string, data: Doc) {
    const parent = parentOf(path);
    return this.db
      .prepare(`INSERT INTO docs (path, parent, coll, data, v) VALUES (?, ?, ?, ?, ?) ON CONFLICT(path) DO UPDATE SET data = excluded.data, v = excluded.v`)
      .bind(path, parent, collOf(parent), JSON.stringify(data), newV());
  }

  async get<T>(path: string) {
    const c = this.cached(path);
    if (c.hit) return c.v as T | null;
    const r = (await this.rows([path])).get(path);
    const v = r ? (JSON.parse(r.data) as T) : null;
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
      const got = await this.rows(need.map((i) => paths[i]));
      for (const i of need) {
        const r = got.get(paths[i]);
        out[i] = r ? (JSON.parse(r.data) as T) : null;
        this.remember(paths[i], out[i]);
      }
    }
    return out;
  }

  query<T>(collection: string, where?: Where) {
    return this.queryIn<T>(collection, where);
  }

  async set(path: string, data: Doc) {
    await this.init();
    this.forget(path);
    this.calls++;
    await this.upsert(path, data).run();
    this.remember(path, data);
  }

  async delete(path: string) {
    await this.init();
    this.forget(path);
    this.calls++;
    await this.db.prepare(`DELETE FROM docs WHERE path = ?`).bind(path).run();
  }

  async tx<R>(fn: (t: Tx) => Promise<R>): Promise<R> {
    for (let attempt = 0; ; attempt++) {
      const versions = new Map<string, number>(); // path -> version read (0 = missing)
      const seen = new Map<string, Doc | null>();
      const creates = new Set<string>();
      const writes = new Map<string, Doc | null>(); // null = delete
      const readMany = async <T,>(paths: string[]) => {
        const todo = paths.filter((p) => !seen.has(p));
        if (todo.length) {
          const got = await this.rows(todo);
          for (const p of todo) {
            const r = got.get(p);
            seen.set(p, r ? JSON.parse(r.data) : null);
            if (!versions.has(p)) versions.set(p, r ? r.v : 0);
          }
        }
        return paths.map((p) => structuredClone(seen.get(p) ?? null) as T | null);
      };
      const t: Tx = {
        get: async (p) => (await readMany<any>([p]))[0],
        getMany: (ps) => readMany(ps),
        query: (c, w) => this.queryIn(c, w),
        set: (p, d) => void writes.set(p, d),
        create: (p, d) => {
          creates.add(p);
          writes.set(p, d);
        },
        delete: (p) => void writes.set(p, null),
      };
      const r = await fn(t);
      if (!writes.size) return r;

      // Guard: every written row that was read (or must be new) is still as it was.
      const same: string[] = [];
      const gone: string[] = [];
      const args: unknown[] = [];
      for (const p of writes.keys()) {
        const v = creates.has(p) ? 0 : versions.get(p);
        if (v === undefined) continue; // written without reading: last write wins (like Firestore)
        if (v === 0) gone.push(p);
        else {
          same.push('(path = ? AND v = ?)');
          args.push(p, v);
        }
      }
      const stmts: D1StatementLike[] = [];
      if (same.length || gone.length) {
        const a = same.length ? `(SELECT COUNT(*) FROM docs WHERE ${same.join(' OR ')}) = ${same.length}` : '1';
        const b = gone.length ? `(SELECT COUNT(*) FROM docs WHERE path IN (${gone.map(() => '?').join(',')})) = 0` : '1';
        stmts.push(this.db.prepare(`SELECT CASE WHEN ${a} AND ${b} THEN 1 ELSE ${CLASH} END AS ok`).bind(...args, ...gone));
      }
      for (const [p, d] of writes) stmts.push(d === null ? this.db.prepare(`DELETE FROM docs WHERE path = ?`).bind(p) : this.upsert(p, d));
      for (const p of writes.keys()) this.forget(p);
      try {
        this.calls++;
        await this.db.batch(stmts);
        for (const [p, d] of writes) this.remember(p, d);
        return r;
      } catch (e: any) {
        if (!/malformed JSON|database clash/i.test(String(e?.message ?? e))) throw e;
        // An explicit create that hits an existing document is a real conflict, not a race.
        if (creates.size && [...(await this.rows([...creates])).keys()].length) throw new AlreadyExists('');
        if (attempt >= 7) throw new Error('The database was busy. Please try again.');
        await new Promise((res) => setTimeout(res, Math.random() * 30 * 2 ** attempt));
      }
    }
  }

  async dump(after: string | null, limit: number) {
    await this.init();
    this.calls++;
    const r = await this.db
      .prepare(`SELECT path, data FROM docs WHERE path > ? ORDER BY path LIMIT ?`)
      .bind(after ?? '', limit)
      .all<{ path: string; data: string }>();
    return r.results.map((x) => ({ p: x.path, d: JSON.parse(x.data) as Doc }));
  }

  /** Writes documents back (backup restore). With keepNewer, rows already here are left alone (moving data in). */
  async load(rows: { p: string; d: Doc }[], keepNewer = false) {
    await this.init();
    for (let i = 0; i < rows.length; i += 20) {
      const part = rows.slice(i, i + 20);
      for (const x of part) this.forget(x.p);
      const values = part.map(() => '(?, ?, ?, ?, ?)').join(', ');
      const args = part.flatMap((x) => {
        const parent = parentOf(x.p);
        return [x.p, parent, collOf(parent), JSON.stringify(x.d), newV()];
      });
      this.calls++;
      await this.db
        .prepare(`INSERT INTO docs (path, parent, coll, data, v) VALUES ${values} ON CONFLICT(path) DO ${keepNewer ? 'NOTHING' : 'UPDATE SET data = excluded.data, v = excluded.v'}`)
        .bind(...args)
        .run();
    }
  }
}
