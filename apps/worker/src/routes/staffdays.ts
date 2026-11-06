import { App, audit, authenticate, GymCtx, gymOf, notifyDesk, P, Role, TenantDoc, UserDoc } from '../core';
import { todayIST } from '../lib/dates';
import { bad, forbidden, HttpError, notFound, nowIso } from '../lib/http';
import type { CheckinDoc } from './checkin';
import { distanceM } from './checkin';
import type { TrainerDoc } from './trainers';

/**
 * Staff attendance (board 56): front desk and trainers do not check in. Each day they press "Present"
 * in the app, and it only counts at their own branch's location (the one the owner set).
 * One document per person per month: tenants/{t}/staffDays/{uid}_{YYYY-MM}.
 */
export interface StaffDaysDoc {
  uid: string;
  month: string;
  branchId: string | null;
  days: Record<string, { at: string; distM: number | null; byOwner?: string; note?: string | null; absent?: boolean }>;
}

const RADIUS_M = 20;
const path = (t: string, uid: string, month: string) => `tenants/${t}/staffDays/${uid}_${month}`;
const monthOf = (v: string | undefined) => (v && /^\d{4}-\d{2}$/.test(v) ? v : todayIST().slice(0, 7));
const presentDays = (d: StaffDaysDoc | null) => Object.entries(d?.days ?? {}).filter(([, x]) => !x.absent).map(([k]) => k).sort();

/** The branch where this person works. */
async function myBranch(store: { get: <T>(p: string) => Promise<T | null> }, g: GymCtx, uid: string): Promise<string> {
  const first = g.tenant.branches[0]?.id ?? '';
  if (g.role === 'TRAINER') {
    const tr = await store.get<TrainerDoc>(P.trainer(g.tenantId, uid));
    return tr?.branchId ?? first;
  }
  if (g.role === 'FRONT_DESK') return g.branchIds[0] ?? first;
  return g.branchId || first;
}

function spotFor(cfg: CheckinDoc | null, t: TenantDoc, branchId: string): { lat: number | null; lng: number | null } {
  if (!cfg) return { lat: null, lng: null };
  if (branchId === (t.branches[0]?.id ?? '')) return { lat: cfg.lat, lng: cfg.lng };
  const s = cfg.branches?.[branchId];
  return { lat: s?.lat ?? null, lng: s?.lng ?? null };
}

export function staffDayRoutes(app: App) {
  /** Staff / trainer: my month (present days). */
  app.get('/api/v1/me/staff-attendance', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER', 'FRONT_DESK', 'TRAINER');
    const month = monthOf(c.req.query('month'));
    const { store } = c.var.deps;
    const [doc, bid] = await Promise.all([store.get<StaffDaysDoc>(path(g.tenantId, u.id, month)), myBranch(store, g, u.id)]);
    const today = todayIST();
    const branch = g.tenant.branches.find((b) => b.id === bid);
    return c.json({
      month,
      today,
      branch: branch ? { id: branch.id, name: branch.name } : null,
      present: presentDays(doc),
      absent: Object.entries(doc?.days ?? {}).filter(([, x]) => x.absent).map(([k]) => k).sort(),
      markedToday: !!doc?.days?.[today] && !doc.days[today].absent,
      fingerprintOnly: !!branch?.fingerprintOnly, // "Present" button hidden: the fingerprint machine marks it
    });
  });

  /** Staff / trainer: "Present" for today — only at their branch's location. */
  app.post('/api/v1/me/staff-attendance', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER', 'FRONT_DESK', 'TRAINER');
    const b = ((await c.req.json().catch(() => null)) ?? {}) as Record<string, unknown>;
    const { store } = c.var.deps;
    const bid = await myBranch(store, g, u.id);
    if (g.role !== 'OWNER' && g.tenant.branches.find((x) => x.id === bid)?.fingerprintOnly) {
      throw new HttpError(403, 'Attendance is marked by the fingerprint machine. Put your finger on the machine at the gym', { code: 'FINGERPRINT_ONLY' });
    }
    const cfg = await store.get<CheckinDoc>(P.checkin(g.tenantId));
    const spot = spotFor(cfg, g.tenant, bid);
    const branchName = g.tenant.branches.find((x) => x.id === bid)?.name ?? g.tenant.name;
    if (spot.lat == null || spot.lng == null) throw forbidden(`The gym location for ${branchName} is not set yet. Ask your gym owner to set it (Check-in QR → Set gym location)`);
    const lat = typeof b.lat === 'number' && Math.abs(b.lat) <= 90 ? b.lat : null;
    const lng = typeof b.lng === 'number' && Math.abs(b.lng) <= 180 ? b.lng : null;
    if (lat == null || lng == null) throw bad('Turn on location so we can check that you are at the gym');
    const d = distanceM({ lat: spot.lat, lng: spot.lng }, { lat, lng });
    const acc = typeof b.accuracy === 'number' && b.accuracy > 0 ? Math.min(b.accuracy, 30) : 0;
    if (b.mocked === true) throw forbidden('A fake location app is on. Turn it off to mark attendance');
    if (d > RADIUS_M + acc) {
      throw forbidden(`You are ${d >= 1000 ? `${(d / 1000).toFixed(1)} km` : `${Math.round(d)} m`} away from ${branchName}. Attendance can be marked only at the gym`);
    }
    const today = todayIST();
    const month = today.slice(0, 7);
    const out = await store.tx(async (t) => {
      const cur = (await t.get<StaffDaysDoc>(path(g.tenantId, u.id, month))) ?? { uid: u.id, month, branchId: bid, days: {} };
      if (cur.days[today] && !cur.days[today].absent) return cur;
      const next: StaffDaysDoc = { ...cur, branchId: bid, days: { ...cur.days, [today]: { at: nowIso(), distM: Math.round(d) } } };
      t.set(path(g.tenantId, u.id, month), next);
      if (g.role !== 'OWNER') await notifyDesk(t, g, u.id, 'Staff attendance', `${u.name} marked Present at ${branchName}`, bid);
      return next;
    });
    return c.json({ ok: true, today, present: presentDays(out) }, 201);
  });

  /** Owner: everyone's month at the branch being looked at (front desk + trainers). */
  app.get('/api/v1/staff-attendance', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const month = monthOf(c.req.query('month'));
    const { store } = c.var.deps;
    const [staff, trainers] = await Promise.all([
      store.query<{ role: Role; branchIds: string[]; active: boolean }>(P.staffCol(g.tenantId), [['active', true]]),
      store.query<TrainerDoc>(P.trainers(g.tenantId), [['active', true]]),
    ]);
    const first = g.tenant.branches[0]?.id ?? '';
    const people: { id: string; role: Role }[] = [];
    for (const s of staff) {
      if (s.data.role === 'FRONT_DESK' && (s.data.branchIds[0] ?? first) === g.branchId) people.push({ id: s.id, role: 'FRONT_DESK' });
    }
    for (const t of trainers) {
      if (!t.data.gone && (t.data.branchId ?? first) === g.branchId) people.push({ id: t.data.userId, role: 'TRAINER' });
    }
    const [users, docs] = await Promise.all([
      store.getMany<UserDoc>(people.map((p) => P.user(p.id))),
      store.getMany<StaffDaysDoc>(people.map((p) => path(g.tenantId, p.id, month))),
    ]);
    const today = todayIST();
    const sameMonth = today.slice(0, 7) === month;
    const daysSoFar = sameMonth ? Number(today.slice(8, 10)) : new Date(Number(month.slice(0, 4)), Number(month.slice(5, 7)), 0).getDate();
    return c.json({
      month,
      daysSoFar,
      rows: people
        .map((p, i) => ({ id: p.id, role: p.role, name: users[i]?.name ?? 'Staff', phone: users[i]?.phone ?? null, present: presentDays(docs[i]) }))
        .sort((a, b) => a.name.localeCompare(b.name)),
    });
  });

  /** Owner corrects one day (present / absent), with a reason. */
  app.put('/api/v1/staff-attendance/:uid/:date', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const uid = c.req.param('uid');
    const date = c.req.param('date');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date > todayIST()) throw bad('Choose a day up to today');
    const b = ((await c.req.json().catch(() => null)) ?? {}) as Record<string, unknown>;
    const present = b.present !== false;
    const note = typeof b.note === 'string' ? b.note.slice(0, 200) : null;
    const { store } = c.var.deps;
    const st = await store.get<{ active: boolean }>(P.staff(g.tenantId, uid));
    if (!st) throw notFound('Staff not found');
    const month = date.slice(0, 7);
    await store.tx(async (t) => {
      const cur = (await t.get<StaffDaysDoc>(path(g.tenantId, uid, month))) ?? { uid, month, branchId: null, days: {} };
      const before = cur.days[date] ?? null;
      const days = { ...cur.days, [date]: { at: nowIso(), distM: null, byOwner: u.id, note, absent: !present } };
      t.set(path(g.tenantId, uid, month), { ...cur, days });
      audit(t, g.tenantId, u.id, 'staff.attendance.fix', 'staff', uid, before, days[date]);
    });
    return c.json({ ok: true });
  });
}
