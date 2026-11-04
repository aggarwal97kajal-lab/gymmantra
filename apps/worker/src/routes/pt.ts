import { App, audit, authenticate, branchOf, C, gymOf, MemberDoc, notify, P, TenantDoc, UserDoc, need } from '../core';
import { addDays, isYmd, todayIST } from '../lib/dates';
import { bad, forbidden, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { body, int, oneOf, optInt, optStr, str } from '../lib/validate';
import type { Reader, Tx } from '../store/store';
import { photoUrlOf, TrainerDoc, trainerView } from './trainers';
import { requireFeature } from './billing';

// ---------- Personal training (PT): request → owner approves → trainer marks sessions ----------
// PT money is kept apart from memberships: the member pays the gym, the owner pays the trainer their share.

export type SessionMark = 'DONE' | 'MISSED' | 'PLANNED';

export interface PtDoc {
  id: string;
  memberId: string;
  memberUserId: string | null;
  memberName: string;
  trainerId: string;
  trainerName: string;
  packageId: string;
  sessions: number;
  days: number;
  perWeek: number | null;
  price: number;
  status: 'PENDING' | 'ACTIVE' | 'DECLINED' | 'CANCELLED';
  requestedAt: string;
  startDate: string | null;
  endDate: string | null;
  decidedById: string | null;
  decidedAt: string | null;
  log: Record<string, SessionMark>;
  plans?: Record<string, { time: string | null; byId: string; byName: string; at: string }>; // details of Planned days
  payments: { id: string; amount: number; mode: string; at: string; byId: string }[];
  sharePercent: number; // trainer share fixed when approved
}

export interface PayoutDoc {
  id: string;
  trainerId: string;
  amount: number;
  mode: string;
  note: string | null;
  month: string; // YYYY-MM it was paid in
  at: string;
  byId: string;
}

const PAY_MODES = ['CASH', 'UPI', 'CARD', 'BANK_TRANSFER'] as const;
/** How many days back a trainer may still mark or change Done / Missed. */
export const SESSION_EDIT_DAYS = 2;

export function ptState(p: PtDoc, today = todayIST()) {
  const done = Object.values(p.log).filter((m) => m === 'DONE').length;
  const missed = Object.values(p.log).filter((m) => m === 'MISSED').length;
  const left = Math.max(0, p.sessions - done);
  const paid = p.payments.reduce((n, x) => n + x.amount, 0);
  let state: 'PENDING' | 'ACTIVE' | 'COMPLETED' | 'EXPIRED' | 'DECLINED' | 'CANCELLED' = p.status;
  if (p.status === 'ACTIVE') {
    if (left === 0) state = 'COMPLETED';
    else if (p.endDate && p.endDate < today) state = 'EXPIRED';
  }
  const daysLeft = p.endDate ? Math.round((Date.parse(p.endDate) - Date.parse(today)) / 86400000) : null;
  const endingSoon = state === 'ACTIVE' && (left <= 2 || (daysLeft !== null && daysLeft <= 5));
  return { done, missed, left, paid, due: Math.max(0, p.price - paid), state, daysLeft, endingSoon };
}

export function ptView(p: PtDoc, extra: Record<string, unknown> = {}) {
  return {
    id: p.id,
    memberId: p.memberId,
    memberName: p.memberName,
    trainerId: p.trainerId,
    trainerName: p.trainerName,
    sessions: p.sessions,
    days: p.days,
    perWeek: p.perWeek,
    price: p.price,
    status: p.status,
    requestedAt: p.requestedAt,
    startDate: p.startDate,
    endDate: p.endDate,
    log: p.log,
    plans: p.plans ?? {},
    payments: p.payments,
    ...ptState(p),
    ...extra,
  };
}

export async function ownerIds(r: Reader, tenantId: string) {
  return (await r.query<{ role: string; active: boolean }>(P.staffCol(tenantId), [['role', 'OWNER']])).filter((x) => x.data.active).map((x) => x.id);
}

/** Photos for a list of PT records (member and trainer). */
async function withPhotos(r: Reader, list: PtDoc[]) {
  const ids = [...new Set(list.flatMap((p) => [p.memberUserId, p.trainerId]).filter((x): x is string => !!x))];
  const users = await r.getMany<UserDoc>(ids.map(P.user));
  const map = new Map(ids.map((id, i) => [id, users[i]]));
  return list.map((p) =>
    ptView({ ...p, trainerName: map.get(p.trainerId)?.name ?? p.trainerName }, {
      memberPhotoUrl: p.memberUserId ? photoUrlOf(p.memberUserId, map.get(p.memberUserId)) : null,
      memberPhone: p.memberUserId ? map.get(p.memberUserId)?.phone ?? null : null,
      trainerPhotoUrl: photoUrlOf(p.trainerId, map.get(p.trainerId)),
      trainerPhone: map.get(p.trainerId)?.phone ?? null,
    }),
  );
}

const sortPt = <T extends { status: string; requestedAt: string }>(a: T, b: T) =>
  a.status === b.status ? (a.requestedAt < b.requestedAt ? 1 : -1) : a.status === 'PENDING' ? -1 : b.status === 'PENDING' ? 1 : 0;

async function loadPt(t: Tx | Reader, tenantId: string, id: string) {
  const p = isUuid(id) ? await t.get<PtDoc>(P.pt(tenantId, id)) : null;
  if (!p) throw notFound('PT not found');
  return p;
}

/** The member record of the signed-in user at a gym. */
async function myMemberAt(c: C, tenantId: string) {
  const mid = c.var.user.memberships?.[tenantId];
  if (!mid) throw forbidden('Join this gym first');
  const m = await c.var.deps.store.get<MemberDoc>(P.member(tenantId, mid));
  if (!m || m.archived || m.userId !== c.var.user.id) throw forbidden('Join this gym first');
  return m;
}

export function ptRoutes(app: App) {
  // ---------------- member ----------------
  app.get('/api/v1/me/gyms/:tenantId/trainers', async (c) => {
    await authenticate(c);
    const tid = c.req.param('tenantId');
    const m = await myMemberAt(c, tid);
    const { store } = c.var.deps;
    const [rows, mine, tenant] = await Promise.all([
      store.query<TrainerDoc>(P.trainers(tid), [['active', true]]),
      store.query<PtDoc>(P.pts(tid), [['memberId', m.id]]),
      store.get<TenantDoc>(P.tenant(tid)),
    ]);
    // Trainers of the member's own branch.
    const myBranch = tenant ? branchOf(tenant, m.branchId) : null;
    const visible = rows.map((r) => r.data).filter((t) => t.visible && (!tenant || branchOf(tenant, t.branchId) === myBranch));
    const users = await store.getMany<UserDoc>(visible.map((t) => P.user(t.userId)));
    const myPts = await withPhotos(store, mine.map((r) => r.data).filter((p) => p.status === 'PENDING' || p.status === 'ACTIVE'));
    return c.json({
      trainers: visible.map((t, i) => {
        const v = trainerView(t, users[i]);
        return { ...v, phone: undefined, sharePercent: undefined };
      }),
      myPt: myPts.filter((p) => p.state === 'ACTIVE' || p.state === 'PENDING').sort(sortPt),
    });
  });

  app.get('/api/v1/me/pt', async (c) => {
    const u = await authenticate(c);
    const { store } = c.var.deps;
    const entries = Object.entries(u.memberships ?? {});
    const lists = await Promise.all(entries.map(([tid, mid]) => store.query<PtDoc>(P.pts(tid), [['memberId', mid]])));
    const tenants = await store.getMany<TenantDoc>(entries.map(([tid]) => P.tenant(tid)));
    const out: unknown[] = [];
    for (const [i, [tid]] of entries.entries()) {
      const views = await withPhotos(store, lists[i].map((r) => r.data).filter((p) => p.status !== 'DECLINED' && p.status !== 'CANCELLED'));
      out.push(...views.map((v) => ({ ...v, gym: { id: tid, name: tenants[i]?.name ?? '' } })));
    }
    return c.json((out as any[]).sort(sortPt));
  });

  app.post('/api/v1/me/pt', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const tid = str(b, 'tenantId', { label: 'the gym' });
    const trainerId = str(b, 'trainerId', { label: 'a trainer' });
    const packageId = str(b, 'packageId', { label: 'a PT package' });
    const m = await myMemberAt(c, tid);
    const { store } = c.var.deps;
    const gymDoc = await store.get<TenantDoc>(P.tenant(tid));
    if (gymDoc) await requireFeature(store, gymDoc, 'pt').catch(() => {
      throw forbidden('Your gym has not turned on PT in the app yet. Ask at the front desk');
    });
    const out = await store.tx(async (t) => {
      const tr = await t.get<TrainerDoc>(P.trainer(tid, trainerId));
      if (!tr || !tr.active || !tr.visible) throw notFound('Trainer not found');
      const pkg = tr.packages.find((x) => x.id === packageId);
      if (!pkg) throw notFound('PT package not found');
      const open = (await t.query<PtDoc>(P.pts(tid), [['memberId', m.id]])).map((r) => r.data);
      if (open.some((p) => p.trainerId === trainerId && p.status === 'PENDING')) throw bad('You already sent a request to this trainer');
      if (open.some((p) => p.trainerId === trainerId && p.status === 'ACTIVE' && ptState(p).state === 'ACTIVE')) throw bad('You already take PT with this trainer');
      const tenant = await t.get<TenantDoc>(P.tenant(tid));
      const p: PtDoc = {
        id: uuid(),
        memberId: m.id,
        memberUserId: u.id,
        memberName: m.name,
        trainerId,
        trainerName: tr.name,
        packageId,
        sessions: pkg.sessions,
        days: pkg.days,
        perWeek: pkg.perWeek,
        price: pkg.price,
        status: 'PENDING',
        requestedAt: nowIso(),
        startDate: null,
        endDate: null,
        decidedById: null,
        decidedAt: null,
        log: {},
        payments: [],
        sharePercent: tr.sharePercent,
      };
      t.set(P.pt(tid, p.id), p);
      const msg = `${m.name} wants PT with ${tr.name}: ${pkg.sessions} sessions for ₹${pkg.price}.`;
      await notify(t, trainerId, tid, 'New PT request', `${msg} The owner will approve it.`);
      for (const oid of await ownerIds(t, tid)) await notify(t, oid, tid, 'PT request to approve', msg, tenant ? branchOf(tenant, m.branchId) : null);
      audit(t, tid, u.id, 'pt.request', 'pt', p.id, null, p);
      return { ...p, gymName: tenant?.name };
    });
    return c.json(ptView(out), 201);
  });

  app.post('/api/v1/me/pt/:id/cancel', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => ({})));
    const tid = str(b, 'tenantId', { label: 'the gym' });
    const m = await myMemberAt(c, tid);
    await c.var.deps.store.tx(async (t) => {
      const p = await loadPt(t, tid, c.req.param('id'));
      if (p.memberId !== m.id) throw notFound('PT not found');
      if (p.status !== 'PENDING') throw bad('Only a request that is not approved yet can be cancelled');
      t.set(P.pt(tid, p.id), { ...p, status: 'CANCELLED', decidedAt: nowIso() });
      audit(t, tid, u.id, 'pt.cancel', 'pt', p.id);
    });
    return c.json({ ok: true });
  });

  // ---------------- owner / front desk ----------------
  app.get('/api/v1/pt', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const status = oneOf({ s: c.req.query('status') ?? 'ACTIVE' }, 's', ['PENDING', 'ACTIVE'] as const)!;
    const { store } = c.var.deps;
    const rows = (await store.query<PtDoc>(P.pts(g.tenantId), [['status', status]])).map((r) => r.data);
    return c.json((await withPhotos(store, rows)).sort(sortPt));
  });

  app.get('/api/v1/pt/:id', async (c) => {
    const u = await authenticate(c);
    const { store } = c.var.deps;
    // Owner / front desk, the trainer of this PT, or the member.
    const staff = Object.entries(u.staffOf ?? {}).filter(([, s]) => s.active).map(([id]) => id);
    const gyms = [...new Set([...staff, ...Object.keys(u.memberships ?? {})])];
    for (const tid of gyms) {
      const p = isUuid(c.req.param('id')) ? await store.get<PtDoc>(P.pt(tid, c.req.param('id'))) : null;
      if (!p) continue;
      const role = u.staffOf?.[tid];
      const allowed = (role?.active && role.role !== 'TRAINER') || p.trainerId === u.id || p.memberUserId === u.id;
      if (!allowed) break;
      const [v] = await withPhotos(store, [p]);
      return c.json(v);
    }
    throw notFound('PT not found');
  });

  app.post('/api/v1/pt/:id/approve', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    await requireFeature(c.var.deps.store, g.tenant, 'pt');
    const b = body(await c.req.json().catch(() => ({})));
    const start = optStr(b, 'startDate') ?? todayIST();
    if (!isYmd(start)) throw bad('Start date is not valid');
    const amount = optInt(b, 'amountReceived', { min: 0, max: 10_000_000, label: 'amount received' }) ?? 0;
    const mode = amount > 0 ? oneOf(b, 'paymentMode', PAY_MODES)! : null;
    const out = await c.var.deps.store.tx(async (t) => {
      const p = await loadPt(t, g.tenantId, c.req.param('id'));
      if (p.status !== 'PENDING') throw bad('This request was already handled');
      if (amount > p.price) throw bad(`Amount received cannot be more than ₹${p.price}`);
      const now = nowIso();
      const next: PtDoc = {
        ...p,
        status: 'ACTIVE',
        startDate: start,
        endDate: addDays(start, p.days - 1),
        decidedById: u.id,
        decidedAt: now,
        payments: amount > 0 ? [{ id: uuid(), amount, mode: mode!, at: now, byId: u.id }] : [],
      };
      t.set(P.pt(g.tenantId, p.id), next);
      await notify(t, p.memberUserId, g.tenantId, 'PT approved', `Your PT with ${p.trainerName} starts on ${start}: ${p.sessions} sessions.`);
      await notify(t, p.trainerId, g.tenantId, 'New PT client', `${p.memberName} is now your PT client (${p.sessions} sessions).`);
      audit(t, g.tenantId, u.id, 'pt.approve', 'pt', p.id, p, next);
      return next;
    });
    return c.json(ptView(out));
  });

  app.post('/api/v1/pt/:id/decline', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    await c.var.deps.store.tx(async (t) => {
      const p = await loadPt(t, g.tenantId, c.req.param('id'));
      if (p.status !== 'PENDING') throw bad('This request was already handled');
      t.set(P.pt(g.tenantId, p.id), { ...p, status: 'DECLINED', decidedById: u.id, decidedAt: nowIso() });
      await notify(t, p.memberUserId, g.tenantId, 'PT request declined', `${g.tenant.name} did not approve PT with ${p.trainerName}. Contact the gym for details.`);
      audit(t, g.tenantId, u.id, 'pt.decline', 'pt', p.id);
    });
    return c.json({ ok: true });
  });

  /** Money the member paid for PT (kept apart from membership payments). */
  app.post('/api/v1/pt/:id/payments', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    need(g, 'payments');
    const b = body(await c.req.json().catch(() => null));
    const amount = int(b, 'amount', { min: 1, max: 10_000_000, label: 'amount' });
    const mode = oneOf(b, 'mode', PAY_MODES)!;
    const out = await c.var.deps.store.tx(async (t) => {
      const p = await loadPt(t, g.tenantId, c.req.param('id'));
      if (p.status !== 'ACTIVE') throw bad('PT is not active');
      const st = ptState(p);
      if (amount > st.due) throw bad(`Only ₹${st.due} is due`);
      const next = { ...p, payments: [...p.payments, { id: uuid(), amount, mode, at: nowIso(), byId: u.id }] };
      t.set(P.pt(g.tenantId, p.id), next);
      audit(t, g.tenantId, u.id, 'pt.payment', 'pt', p.id, null, { amount, mode });
      return next;
    });
    return c.json(ptView(out), 201);
  });

  // ---------------- sessions (trainer of this PT, or the owner) ----------------
  app.post('/api/v1/pt/:id/session', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const date = str(b, 'date', { label: 'a date' });
    if (!isYmd(date)) throw bad('Choose a valid date');
    const mark = oneOf(b, 'mark', ['DONE', 'MISSED', 'PLANNED', 'CLEAR'] as const)!;
    const tid = str(b, 'tenantId', { label: 'the gym' });
    const role = u.staffOf?.[tid];
    if (!role?.active) throw forbidden('Not allowed');
    const out = await c.var.deps.store.tx(async (t) => {
      const p = await loadPt(t, tid, c.req.param('id'));
      if (role.role === 'TRAINER' && p.trainerId !== u.id) throw forbidden('This is not your PT client');
      if (role.role === 'FRONT_DESK') throw forbidden('Only the trainer or the owner can mark sessions');
      if (p.status !== 'ACTIVE') throw bad('PT is not active');
      if (p.startDate && date < p.startDate) throw bad('This date is before the PT started');
      const today = todayIST();
      if ((mark === 'DONE' || mark === 'MISSED') && date > today) throw bad('A day that has not come yet can only be marked Planned');
      if (mark === 'PLANNED' && date < today) throw bad('A past day cannot be marked Planned. Mark it Done or Missed');
      // The trainer may fix Done / Missed only for today and the 2 days before (no changing old records).
      if (role.role === 'TRAINER') {
        const prev = p.log[date];
        const touchesRecord = mark === 'DONE' || mark === 'MISSED' || prev === 'DONE' || prev === 'MISSED';
        if (touchesRecord && date < addDays(today, -SESSION_EDIT_DAYS)) throw bad(`Sessions older than ${SESSION_EDIT_DAYS} days are locked. Ask the owner to change them`);
      }
      const log = { ...p.log };
      if (mark === 'CLEAR') delete log[date];
      else log[date] = mark;
      // Planned: keep the time (optional), who planned it and when.
      const plans = { ...(p.plans ?? {}) };
      const time = optStr(b, 'time', { max: 5 }) ?? null;
      if (time && !/^([01]\d|2[0-3]):[0-5]\d$/.test(time)) throw bad('Time is not valid');
      if (mark === 'PLANNED') {
        const who = role.role === 'TRAINER' ? p.trainerName : (u.name ?? 'Gym owner');
        plans[date] = { time: time ?? plans[date]?.time ?? null, byId: u.id, byName: who, at: nowIso() };
      } else delete plans[date];
      const done = Object.values(log).filter((m) => m === 'DONE').length;
      if (done > p.sessions) throw bad(`All ${p.sessions} sessions are already done`);
      const next = { ...p, log, plans };
      t.set(P.pt(tid, p.id), next);
      if (mark === 'PLANNED') {
        const when = `${date}${plans[date]?.time ? ` at ${plans[date]!.time}` : ''}`;
        await notify(t, p.memberUserId, tid, 'PT planned', `${p.trainerName} planned your PT for ${when}.`);
      }
      if (mark === 'DONE' && p.sessions - done <= 2) {
        await notify(t, p.memberUserId, tid, 'PT sessions ending', `${p.sessions - done} PT session${p.sessions - done === 1 ? '' : 's'} left with ${p.trainerName}.`);
      }
      return next;
    });
    const [v] = await withPhotos(c.var.deps.store, [out]);
    return c.json(v);
  });

  // ---------------- trainer ----------------
  app.get('/api/v1/trainer/clients', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'TRAINER');
    const { store } = c.var.deps;
    const rows = (await store.query<PtDoc>(P.pts(g.tenantId), [['trainerId', u.id]])).map((r) => r.data).filter((p) => p.status === 'ACTIVE' || p.status === 'PENDING');
    const views = await withPhotos(store, rows);
    // The trainer sees sessions and dates; money stays with the owner.
    return c.json({ tenantId: g.tenantId, clients: views.map((v) => ({ ...v, payments: undefined, paid: undefined, due: undefined, price: undefined })).sort(sortPt) });
  });

  app.get('/api/v1/trainer/payouts', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'TRAINER');
    const rows = (await c.var.deps.store.query<PayoutDoc>(P.payouts(g.tenantId), [['trainerId', u.id]])).map((r) => r.data);
    return c.json(rows.sort((a, b) => (a.at < b.at ? 1 : -1)));
  });

  // ---------------- PT money: what each trainer is owed, and payouts ----------------
  app.get('/api/v1/pt-accounts', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    await requireFeature(c.var.deps.store, g.tenant, 'pt');
    const month = c.req.query('month') ?? todayIST().slice(0, 7);
    if (!/^\d{4}-\d{2}$/.test(month)) throw bad('Month is not valid');
    const { store } = c.var.deps;
    const [pts, payouts, trainers] = await Promise.all([
      store.query<PtDoc>(P.pts(g.tenantId), [['status', 'ACTIVE']]),
      store.query<PayoutDoc>(P.payouts(g.tenantId), [['month', month]]),
      store.query<TrainerDoc>(P.trainers(g.tenantId)),
    ]);
    const users = await store.getMany<UserDoc>(trainers.map((t) => P.user(t.id)));
    const rows = trainers.map((tr, i) => {
      const mine = pts.map((r) => r.data).filter((p) => p.trainerId === tr.id);
      // Trainer earns their share of PT money received in this month.
      const received = mine.flatMap((p) => p.payments.filter((x) => x.at.slice(0, 7) === month).map((x) => ({ amount: x.amount, share: tr.data.sharePercent ?? p.sharePercent })));
      const collected = received.reduce((n, x) => n + x.amount, 0);
      const earned = Math.round(received.reduce((n, x) => n + (x.amount * x.share) / 100, 0));
      const paid = payouts.map((r) => r.data).filter((x) => x.trainerId === tr.id).reduce((n, x) => n + x.amount, 0);
      const sessions = mine.reduce((n, p) => n + Object.entries(p.log).filter(([d, m]) => m === 'DONE' && d.slice(0, 7) === month).length, 0);
      return {
        trainerId: tr.id,
        name: users[i]?.name ?? tr.data.name,
        photoUrl: photoUrlOf(tr.id, users[i]),
        sharePercent: tr.data.sharePercent,
        clients: mine.filter((p) => ptState(p).state === 'ACTIVE').length,
        sessions,
        collected,
        earned,
        paid,
        due: Math.max(0, earned - paid),
      };
    });
    const active = rows.filter((r) => r.clients || r.collected || r.paid || trainers.find((t) => t.id === r.trainerId)?.data.active);
    return c.json({
      month,
      collected: active.reduce((n, r) => n + r.collected, 0),
      due: active.reduce((n, r) => n + r.due, 0),
      trainers: active.sort((a, b) => b.due - a.due),
      payouts: payouts.map((r) => r.data).sort((a, b) => (a.at < b.at ? 1 : -1)),
    });
  });

  app.post('/api/v1/pt-payouts', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    await requireFeature(c.var.deps.store, g.tenant, 'pt');
    const b = body(await c.req.json().catch(() => null));
    const trainerId = str(b, 'trainerId', { label: 'a trainer' });
    const amount = int(b, 'amount', { min: 1, max: 10_000_000, label: 'amount' });
    const mode = oneOf(b, 'mode', PAY_MODES)!;
    const note = optStr(b, 'note', { max: 200 }) ?? null;
    const out = await c.var.deps.store.tx(async (t) => {
      const tr = await t.get<TrainerDoc>(P.trainer(g.tenantId, trainerId));
      if (!tr) throw notFound('Trainer not found');
      const at = nowIso();
      const p: PayoutDoc = { id: uuid(), trainerId, amount, mode, note, month: todayIST().slice(0, 7), at, byId: u.id };
      t.set(P.payout(g.tenantId, p.id), p);
      await notify(t, trainerId, g.tenantId, 'PT payment received', `${g.tenant.name} paid you ₹${amount} (${mode === 'BANK_TRANSFER' ? 'bank' : mode.toLowerCase()}).`);
      audit(t, g.tenantId, u.id, 'pt.payout', 'payout', p.id, null, p);
      return p;
    });
    return c.json(out, 201);
  });
}
