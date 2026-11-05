// Cloudflare D1's API over Node's built-in SQLite, so the tests can run against D1Store
// (TEST_STORE=d1). Real D1 is SQLite too; batch() is one transaction, like on Cloudflare.
import type { D1Like, D1StatementLike } from '../src/store/d1';

export function memoryD1(): D1Like & { rowsRead: number } {
  // Loaded only when used: some Node versions (e.g. the Cloudflare build) have no node:sqlite.
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { DatabaseSync } = require('node:sqlite');
  const db = new DatabaseSync(':memory:');
  const stmt = (sql: string, args: unknown[] = []): D1StatementLike & { exec(): any } => {
    const s = {
      bind: (...a: unknown[]) => stmt(sql, a),
      exec: () => {
        const p = db.prepare(sql);
        return /^\s*(SELECT|WITH|EXPLAIN)/i.test(sql) ? p.all(...args) : (p.run(...args), []);
      },
      first: async () => (s.exec()[0] ?? null) as any,
      all: async () => ({ results: s.exec() as any[] }),
      run: async () => s.exec(),
    };
    return s;
  };
  return {
    rowsRead: 0,
    prepare: (sql: string) => stmt(sql),
    batch: async (list: D1StatementLike[]) => {
      db.exec('BEGIN');
      try {
        const out = list.map((s) => (s as any).exec());
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
  };
}
