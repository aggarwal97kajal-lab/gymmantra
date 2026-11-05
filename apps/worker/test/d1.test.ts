// D1Store on Node's SQLite (same engine as Cloudflare D1). Skipped where Node has no node:sqlite.
import { D1Store } from '../src/store/d1';
import { AlreadyExists } from '../src/store/store';

let hasSqlite = true;
try {
  require('node:sqlite');
} catch {
  hasSqlite = false;
}
const d = hasSqlite ? describe : describe.skip;

d('D1Store', () => {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { memoryD1 } = require('./d1shim');
  const fresh = () => {
    const db = memoryD1();
    return { db, s: new D1Store(db), s2: new D1Store(db) }; // two Worker instances, one database
  };

  it('a transaction that lost a race runs again and sees the new value', async () => {
    const { s, s2 } = fresh();
    await s.set('t/x/daily/d1', { n: 0 });
    let runs = 0;
    await s.tx(async (t) => {
      runs++;
      const cur = (await t.get<{ n: number }>('t/x/daily/d1'))!;
      if (runs === 1) await s2.tx(async (t2) => t2.set('t/x/daily/d1', { n: (await t2.get<any>('t/x/daily/d1')).n + 1 })); // someone else, meanwhile
      t.set('t/x/daily/d1', { n: cur.n + 1 });
    });
    expect(runs).toBe(2);
    expect(await s2.get('t/x/daily/d1')).toEqual({ n: 2 });
  });

  it('create on an existing document fails; nothing in the batch is written', async () => {
    const { s } = fresh();
    await s.set('phones/+911', { uid: 'a' });
    await expect(
      s.tx(async (t) => {
        t.set('users/b', { name: 'B' });
        t.create('phones/+911', { uid: 'b' });
      }),
    ).rejects.toBeInstanceOf(AlreadyExists);
    expect(await s.get('users/b')).toBeNull();
  });

  it('queries match like Firestore (strings, numbers, true/false, null) and use the index', async () => {
    const { s, db } = fresh();
    await s.set('users/a', { email: 'a@x.in', active: true, n: 1 });
    await s.set('users/b', { email: 'b@x.in', active: false, n: 2, gone: null });
    await s.set('tenants/t1/subs/s1', { memberId: 'm1' });
    await s.set('tenants/t2/subs/s2', { memberId: 'm1' });
    expect((await s.query('users', [['email', 'b@x.in']])).map((r) => r.id)).toEqual(['b']);
    expect((await s.query('users', [['active', true]])).map((r) => r.id)).toEqual(['a']);
    expect((await s.query('users', [['n', 2], ['active', false]])).map((r) => r.id)).toEqual(['b']);
    expect((await s.query('users', [['gone', null]])).map((r) => r.id)).toEqual(['a', 'b']);
    expect((await s.query('tenants/t1/subs', [['memberId', 'm1']])).map((r) => r.id)).toEqual(['s1']);
    const plan = await db.prepare(`EXPLAIN QUERY PLAN SELECT path, data FROM docs INDEXED BY ix_subs_memberId WHERE coll = 'subs' AND parent = ? AND json_extract(data, '$.memberId') IS ? ORDER BY path`).bind("tenants/t1/subs", "m1").all();
    expect(JSON.stringify(plan.results)).toContain('ix_subs_memberId');
  });

  it('moving data in never overwrites newer rows', async () => {
    const { s } = fresh();
    await s.set('users/a', { name: 'New' });
    await s.load([{ p: 'users/a', d: { name: 'Old' } }, { p: 'users/c', d: { name: 'C' } }], true);
    expect(await s.get('users/a')).toEqual({ name: 'New' });
    expect((await s.dump(null, 10)).map((r) => r.p)).toEqual(['users/a', 'users/c']);
  });
});
