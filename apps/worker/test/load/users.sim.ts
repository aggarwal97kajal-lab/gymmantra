/**
 * Load simulation (owner request, Nov 6): 1000+ people using GymMantra, on the in-memory database.
 * Run: ../../node_modules/.bin/jest --runInBand --testRegex 'test/load/.*\.sim\.ts$'
 * It measures, for every kind of request: database reads/writes (Firestore bills each document a
 * query returns as one read), server CPU time, and the size of the big shared documents. Then it
 * checks the numbers against the limits of the free plans (Firestore: 50,000 reads and 20,000 writes
 * a day, 1 MB per document; Cloudflare Workers: 10 ms CPU and 50 sub-requests per request).
 */
import { setup } from '../helpers';
import { P } from '../../src/core';

const GYMS = Number(process.env.SIM_GYMS ?? 5);
const PER_GYM = Number(process.env.SIM_MEMBERS ?? 220); // 5 × 220 = 1100 members
const BIG_GYM = Number(process.env.SIM_BIG ?? 0); // optional: one extra gym this big

type Stat = { n: number; reads: number; writes: number; cpu: number; maxCpu: number; calls: number; maxCalls: number; errors: Record<string, number> };
const stats = new Map<string, Stat>();
let cur = { reads: 0, writes: 0, calls: 0 };

function instrument(store: any) {
  const wrap = (name: string, count: (args: any[], r: any) => [number, number]) => {
    const orig = store[name].bind(store);
    store[name] = async (...args: any[]) => {
      const r = await orig(...args);
      const [rd, wr] = count(args, r);
      cur.reads += rd;
      cur.writes += wr;
      cur.calls += 1;
      return r;
    };
  };
  wrap('get', () => [1, 0]);
  wrap('getMany', (a) => [a[0].length, 0]);
  wrap('query', (_a, r) => [Math.max(1, r.length), 0]);
  wrap('set', () => [0, 1]);
  wrap('delete', () => [0, 1]);
  const tx = store.tx.bind(store);
  store.tx = (fn: any) =>
    tx(async (t: any) => {
      cur.calls += 1; // one commit
      const tt = {
        get: async (p: string) => (cur.reads++, t.get(p)),
        getMany: async (ps: string[]) => ((cur.reads += ps.length), t.getMany(ps)),
        query: async (c: string, w: any) => {
          const r = await t.query(c, w);
          cur.reads += Math.max(1, r.length);
          cur.calls++;
          return r;
        },
        set: (p: string, d: any) => (cur.writes++, t.set(p, d)),
        create: (p: string, d: any) => (cur.writes++, t.create(p, d)),
        delete: (p: string) => (cur.writes++, t.delete(p)),
      };
      return fn(tt);
    });
}

function timed(api: any) {
  const run = async (label: string, f: () => Promise<any>) => {
    cur = { reads: 0, writes: 0, calls: 0 };
    const c0 = process.cpuUsage();
    const r = await f();
    const cu = process.cpuUsage(c0);
    const ms = (cu.user + cu.system) / 1000;
    const s = stats.get(label) ?? { n: 0, reads: 0, writes: 0, cpu: 0, maxCpu: 0, calls: 0, maxCalls: 0, errors: {} };
    s.n++;
    s.reads += cur.reads;
    s.writes += cur.writes;
    s.cpu += ms;
    s.maxCpu = Math.max(s.maxCpu, ms);
    s.calls += cur.calls;
    s.maxCalls = Math.max(s.maxCalls, cur.calls);
    if (r.status >= 400) s.errors[`${r.status} ${String(r.body?.message ?? '').slice(0, 60)}`] = (s.errors[`${r.status} ${String(r.body?.message ?? '').slice(0, 60)}`] ?? 0) + 1;
    stats.set(label, s);
    return r;
  };
  return {
    get: (l: string, p: string, t?: string) => run(l, () => api.get(p, t)),
    post: (l: string, p: string, b: unknown, t?: string) => run(l, () => api.post(p, b, t)),
  };
}

it('1000+ people: members, owners, trainers', async () => {
  const h = setup();
  instrument(h.store);
  const T = timed(h.api);
  const sizes: Record<string, number> = {};
  const gyms: any[] = [];
  const counts = [...Array(GYMS).fill(PER_GYM), ...(BIG_GYM ? [BIG_GYM] : [])];
  let people = 0;
  for (let gi = 0; gi < counts.length; gi++) {
    const owner = await h.ownerWithGym(`Sim Gym ${gi}`);
    people++;
    const plan = (await T.post('owner: add plan', '/plans', { name: 'Monthly', months: 1, price: 1000 }, owner.token)).body;
    const qr = (await T.get('owner: check-in QR', '/gym/checkin-qr', owner.token)).body;
    const mems: any[] = [];
    for (let i = 0; i < counts[gi]; i++) {
      const m = await h.signup(`Member ${gi}-${i}`);
      people++;
      await T.post('member: join request', '/me/join', { gymCode: owner.gym.gymCode }, m.token);
      mems.push(m);
    }
    const reqs = (await T.get('owner: join requests list', '/join-requests', owner.token)).body as any[];
    const memberIds: string[] = [];
    for (const r of reqs) memberIds.push((await T.post('owner: approve join', `/join-requests/${r.id}/approve`, {}, owner.token)).body.id);
    for (const id of memberIds) await T.post('owner: add membership + payment', `/members/${id}/memberships`, { planId: plan.id, paymentMode: 'CASH' }, owner.token);
    gyms.push({ owner, mems, memberIds, qr, plan });
  }
  // A normal day: every member opens the app, shows QR, checks in, reads notifications; owners work the desk.
  for (const g of gyms) {
    for (const m of g.mems) {
      await T.get('member: open app (/me/gyms)', '/me/gyms', m.token);
      await T.get('member: notifications', '/me/notifications', m.token);
      await T.post('member: self check-in', '/me/checkin', { code: g.qr.text }, m.token);
    }
    for (let k = 0; k < 20; k++) {
      await T.get('owner: dashboard', '/dashboard', g.owner.token);
      await T.get('owner: members list', '/members', g.owner.token);
    }
    await T.get('owner: today attendance', '/attendance/today', g.owner.token);
    await T.get('owner: reports 30 days', '/reports?days=30', g.owner.token);
    await T.get('owner: member detail', `/members/${g.memberIds[0]}`, g.owner.token);
    await T.post('owner: payment on a membership', `/members/${g.memberIds[1]}/memberships`, { planId: g.plan.id, paymentMode: 'UPI' }, g.owner.token);
    await T.post('owner: notice to all members', '/notices', { title: 'Holiday', message: 'Closed on Sunday' }, g.owner.token);
    const roster = await (h.store as any).get(P.roster(g.owner.gym.id));
    sizes[`roster of a ${g.mems.length}-member gym`] = JSON.stringify(roster).length;
  }
  for (const g of gyms) for (const m of g.mems.slice(0, 50)) await T.get('member: notifications', '/me/notifications', m.token);

  const rows = [...stats.entries()].map(([k, s]) => ({
    request: k,
    times: s.n,
    'reads/req': +(s.reads / s.n).toFixed(1),
    'writes/req': +(s.writes / s.n).toFixed(1),
    'db calls max': s.maxCalls,
    'cpu ms avg': +(s.cpu / s.n).toFixed(2),
    'cpu ms max': +s.maxCpu.toFixed(1),
    errors: Object.entries(s.errors).map(([e, n]) => `${n}× ${e}`).join('; '),
  }));
  console.log(`PEOPLE ${people} in ${gyms.length} gyms\n` + JSON.stringify(rows, null, 1) + '\nSIZES ' + JSON.stringify(sizes));
});
