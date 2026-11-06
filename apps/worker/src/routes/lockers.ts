import { App, audit, authenticate, C, gymOf, MemberDoc, need, notify, P } from '../core';
import type { Tx } from '../store/store';
import { addDays, diffDays, isYmd, todayIST } from '../lib/dates';
import { bad, conflict, notFound, nowIso } from '../lib/http';
import { schedule } from '../lib/scheduled';
import { body, int, oneOf, optInt, str } from '../lib/validate';

/**
 * Lockers (board 84): one document per branch with every locker. A locker is given to a member
 * from a day to a day, with a fee and a key deposit. 3 days before it ends and on the last day,
 * the member and the desk get a notification. The member sees their locker on their plan page.
 */
export interface LockerUse {
  memberId: string;
  userId: string | null;
  name: string;
  phone: string;
  from: string;
  to: string;
  fee: number;
  deposit: number; // key deposit held
  at: string;
  byId: string;
}
export interface LockersDoc {
  count: number;
  lockers: Record<string, LockerUse>; // locker number -> who has it
  log: { n: number; what: string; name: string; amount: number; fee?: number; deposit?: number; mode: string | null; at: string; byId: string }[];
}

const MODES = ['CASH', 'UPI', 'CARD', 'BANK_TRANSFER'] as const;

function stateOf(l: LockerUse | undefined, today: string) {
  if (!l) return 'FREE';
  if (l.to < today) return 'ENDED';
  if (diffDays(today, l.to) <= 3) return 'ENDING';
  return 'IN_USE';
}

/** Reminders 3 days before and on the last day (checked again when sent). */
function remind(t: Tx, tenantId: string, branchId: string, n: number, to: string) {
  const today = todayIST();
  for (const day of [addDays(to, -3), to]) {
    if (day < today) continue;
    schedule(t, { id: `lock_${tenantId}_${branchId}_${n}_${day}`, day, hour: 10, tenantId, kind: 'locker', branchId, ref: `${branchId}:${n}:${to}` });
  }
}

/** For the reminder job: the notification texts, if this locker is still given till that day. */
export async function lockerReminder(t: Tx, tenantId: string, ref: string, today: string) {
  const [branchId, nStr, to] = ref.split(':');
  const doc = await t.get<LockersDoc>(P.lockers(tenantId, branchId));
  const l = doc?.lockers[nStr];
  if (!l || l.to !== to) return null;
  const last = to === today;
  return {
    userId: l.userId,
    branchId,
    member: last
      ? { title: 'Your locker ends today', body: `Locker ${nStr} is yours till today. Renew at the desk or empty it.` }
      : { title: 'Your locker ends soon', body: `Locker ${nStr} ends on ${to}. Renew at the desk to keep it.` },
    desk: last ? { title: 'Locker ending today', body: `Locker ${nStr} (${l.name}) ends today.` } : { title: 'Locker ending soon', body: `Locker ${nStr} (${l.name}) ends on ${to}.` },
  };
}

async function ctx(c: C) {
  const u = await authenticate(c);
  const g = await gymOf(c, 'OWNER', 'FRONT_DESK');
  need(g, 'lockers');
  const branchId = g.branchId || g.tenant.branches[0]?.id || 'main';
  return { u, g, branchId };
}

function lockerNo(c: C, count: number) {
  const n = Number(c.req.param('n'));
  if (!Number.isInteger(n) || n < 1 || n > count) throw notFound('Locker not found');
  return n;
}

export function lockerRoutes(app: App) {
  app.get('/api/v1/lockers', async (c) => {
    const { g, branchId } = await ctx(c);
    const doc = (await c.var.deps.store.get<LockersDoc>(P.lockers(g.tenantId, branchId))) ?? { count: 0, lockers: {}, log: [] };
    const today = todayIST();
    const rows = Array.from({ length: doc.count }, (_, i) => {
      const l = doc.lockers[String(i + 1)];
      return { n: i + 1, state: stateOf(l, today), use: l ?? null, daysLeft: l ? diffDays(today, l.to) : null };
    });
    return c.json({
      count: doc.count,
      free: rows.filter((r) => r.state === 'FREE').length,
      ended: rows.filter((r) => r.state === 'ENDED').length,
      ending: rows.filter((r) => r.state === 'ENDING').length,
      rows,
      log: doc.log.slice(0, 50),
    });
  });

  /** How many lockers this branch has. */
  app.put('/api/v1/lockers/count', async (c) => {
    const { u, g, branchId } = await ctx(c);
    const count = int(body(await c.req.json().catch(() => null)), 'count', { min: 0, max: 500, label: 'number of lockers' });
    await c.var.deps.store.tx(async (t) => {
      const doc = (await t.get<LockersDoc>(P.lockers(g.tenantId, branchId))) ?? { count: 0, lockers: {}, log: [] };
      const busy = Object.keys(doc.lockers).map(Number).filter((n) => n > count);
      if (busy.length) throw conflict(`Locker ${busy[0]} is given to someone. Empty it first`);
      t.set(P.lockers(g.tenantId, branchId), { ...doc, count });
      audit(t, g.tenantId, u.id, 'locker.count', 'locker', branchId, doc.count, count);
    });
    return c.json({ ok: true, count });
  });

  app.post('/api/v1/lockers/:n/assign', async (c) => {
    const { u, g, branchId } = await ctx(c);
    const b = body(await c.req.json().catch(() => null));
    const memberId = str(b, 'memberId', { label: 'a member' });
    const from = typeof b.from === 'string' && isYmd(b.from) ? b.from : todayIST();
    if (typeof b.to !== 'string' || !isYmd(b.to) || b.to < from) throw bad('Choose till when');
    const to = b.to;
    const fee = optInt(b, 'fee', { min: 0, max: 1_000_000 }) ?? 0;
    const deposit = optInt(b, 'deposit', { min: 0, max: 1_000_000 }) ?? 0;
    const mode = oneOf(b, 'mode', MODES, true) ?? 'CASH';
    const out = await c.var.deps.store.tx(async (t) => {
      const [doc, m] = (await t.getMany<any>([P.lockers(g.tenantId, branchId), P.member(g.tenantId, memberId)])) as [LockersDoc | null, MemberDoc | null];
      if (!doc) throw notFound('Set the number of lockers first');
      const n = lockerNo(c, doc.count);
      if (!m || m.archived) throw notFound('Member not found');
      if (doc.lockers[String(n)]) throw conflict(`Locker ${n} is already given`);
      const use: LockerUse = { memberId, userId: m.userId, name: m.name, phone: m.phone, from, to, fee, deposit, at: nowIso(), byId: u.id };
      const next: LockersDoc = { ...doc, lockers: { ...doc.lockers, [String(n)]: use }, log: [{ n, what: 'GIVEN', name: m.name, amount: fee + deposit, fee, deposit, mode, at: use.at, byId: u.id }, ...doc.log].slice(0, 300) };
      t.set(P.lockers(g.tenantId, branchId), next);
      t.set(P.member(g.tenantId, memberId), { ...m, locker: { branchId, n, from, to } });
      remind(t, g.tenantId, branchId, n, to);
      await notify(t, m.userId, g.tenantId, 'Locker given', `Locker ${n} is yours till ${to}.`, branchId);
      audit(t, g.tenantId, u.id, 'locker.give', 'locker', `${branchId}:${n}`, null, use);
      return { n, use };
    });
    return c.json(out, 201);
  });

  app.post('/api/v1/lockers/:n/renew', async (c) => {
    const { u, g, branchId } = await ctx(c);
    const b = body(await c.req.json().catch(() => null));
    if (typeof b.to !== 'string' || !isYmd(b.to)) throw bad('Choose till when');
    const to = b.to;
    const fee = optInt(b, 'fee', { min: 0, max: 1_000_000 }) ?? 0;
    const mode = oneOf(b, 'mode', MODES, true) ?? 'CASH';
    const out = await c.var.deps.store.tx(async (t) => {
      const doc = await t.get<LockersDoc>(P.lockers(g.tenantId, branchId));
      if (!doc) throw notFound('Locker not found');
      const n = lockerNo(c, doc.count);
      const l = doc.lockers[String(n)];
      if (!l) throw bad(`Locker ${n} is free`);
      if (to <= l.to) throw bad('The new end must be after the current end');
      const use = { ...l, to, fee: l.fee + fee };
      t.set(P.lockers(g.tenantId, branchId), { ...doc, lockers: { ...doc.lockers, [String(n)]: use }, log: [{ n, what: 'RENEWED', name: l.name, amount: fee, fee, mode, at: nowIso(), byId: u.id }, ...doc.log].slice(0, 300) });
      const m = await t.get<MemberDoc>(P.member(g.tenantId, l.memberId));
      if (m) t.set(P.member(g.tenantId, l.memberId), { ...m, locker: { branchId, n, from: l.from, to } });
      remind(t, g.tenantId, branchId, n, to);
      await notify(t, l.userId, g.tenantId, 'Locker given', `Locker ${n} is now yours till ${to}.`, branchId);
      audit(t, g.tenantId, u.id, 'locker.renew', 'locker', `${branchId}:${n}`, l, use);
      return { n, use };
    });
    return c.json(out);
  });

  /** Empty the locker: deposit given back (or kept, when the key was lost). */
  app.post('/api/v1/lockers/:n/free', async (c) => {
    const { u, g, branchId } = await ctx(c);
    const b = body(await c.req.json().catch(() => null));
    const keep = b.keepDeposit === true;
    const out = await c.var.deps.store.tx(async (t) => {
      const doc = await t.get<LockersDoc>(P.lockers(g.tenantId, branchId));
      if (!doc) throw notFound('Locker not found');
      const n = lockerNo(c, doc.count);
      const l = doc.lockers[String(n)];
      if (!l) throw bad(`Locker ${n} is already free`);
      const lockers = { ...doc.lockers };
      delete lockers[String(n)];
      t.set(P.lockers(g.tenantId, branchId), { ...doc, lockers, log: [{ n, what: keep ? 'FREED_DEPOSIT_KEPT' : 'FREED_DEPOSIT_RETURNED', name: l.name, amount: keep ? 0 : -l.deposit, mode: null, at: nowIso(), byId: u.id }, ...doc.log].slice(0, 300) });
      const m = await t.get<MemberDoc & { locker?: unknown }>(P.member(g.tenantId, l.memberId));
      if (m) {
        const { locker: _gone, ...rest } = m;
        t.set(P.member(g.tenantId, l.memberId), rest);
      }
      audit(t, g.tenantId, u.id, 'locker.free', 'locker', `${branchId}:${n}`, l, { keepDeposit: keep });
      return { n, depositBack: keep ? 0 : l.deposit };
    });
    return c.json(out);
  });
}
