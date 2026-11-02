import { App, audit, authenticate, gymOf, MemberDoc, P, TenantDoc } from '../core';
import { todayIST } from '../lib/dates';
import { bad, forbidden, notFound, nowIso, uuid } from '../lib/http';
import { body, str } from '../lib/validate';
import { recordMemberCheckIn } from './attendance';

// ---------- Gym check-in QR: members and trainers scan it at the gym ----------
// Two different QR codes exist on purpose:
//  * the join QR ("gymmantra-join:<gym code>") is shared on WhatsApp and only sends a join request;
//  * the check-in QR ("gymmantra-checkin:<tenant>:<key>") hangs in the gym and only checks people in.
// The check-in key lives in a private document (never in GET /gym or the gym lookup) and can be changed.

export interface CheckinDoc {
  key: string;
  lat: number | null;
  lng: number | null;
  radiusM: number;
  updatedAt: string;
}

export interface TrainerDaysDoc {
  month: string;
  visits: number;
  lastAt: string | null;
  days: string[]; // recent days (newest first)
}

const RADIUS_M = 20; // owner decision: only inside the gym (10–20 m)
const newKey = () => uuid().replace(/-/g, '').slice(0, 16);
export const checkinText = (tenantId: string, key: string) => `gymmantra-checkin:${tenantId}:${key}`;

/** Metres between two points (haversine). */
export function distanceM(a: { lat: number; lng: number }, b: { lat: number; lng: number }) {
  const R = 6371000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

const coord = (v: unknown, max: number) => (typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= max ? v : null);

export function checkinRoutes(app: App) {
  /** Owner / front desk: the check-in QR text (made on first use) and whether the gym location is set. */
  app.get('/api/v1/gym/checkin-qr', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const doc = await c.var.deps.store.tx(async (t) => {
      const cur = await t.get<CheckinDoc>(P.checkin(g.tenantId));
      if (cur) return cur;
      const fresh: CheckinDoc = { key: newKey(), lat: null, lng: null, radiusM: RADIUS_M, updatedAt: nowIso() };
      t.set(P.checkin(g.tenantId), fresh);
      return fresh;
    });
    return c.json({ text: checkinText(g.tenantId, doc.key), joinText: `gymmantra-join:${g.tenant.gymCode}`, gymCode: g.tenant.gymCode, locationSet: doc.lat != null, radiusM: RADIUS_M });
  });

  /** Owner: make a new check-in QR (old printouts stop working). */
  app.post('/api/v1/gym/checkin-qr/rotate', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const doc = await c.var.deps.store.tx(async (t) => {
      const cur = await t.get<CheckinDoc>(P.checkin(g.tenantId));
      const next: CheckinDoc = { ...(cur ?? { lat: null, lng: null, radiusM: RADIUS_M }), key: newKey(), updatedAt: nowIso() };
      t.set(P.checkin(g.tenantId), next);
      audit(t, g.tenantId, u.id, 'checkin.rotate', 'tenant', g.tenantId);
      return next;
    });
    return c.json({ text: checkinText(g.tenantId, doc.key), locationSet: doc.lat != null, radiusM: RADIUS_M });
  });

  /** Owner: save the gym's location (taken from the phone while standing in the gym), or clear it. */
  app.put('/api/v1/gym/location', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const clear = b.lat === null && b.lng === null;
    const lat = coord(b.lat, 90);
    const lng = coord(b.lng, 180);
    if (!clear && (lat == null || lng == null)) throw bad('Location is not valid');
    await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<CheckinDoc>(P.checkin(g.tenantId))) ?? { key: newKey(), lat: null, lng: null, radiusM: RADIUS_M, updatedAt: nowIso() };
      t.set(P.checkin(g.tenantId), { ...cur, lat: clear ? null : lat, lng: clear ? null : lng, radiusM: RADIUS_M, updatedAt: nowIso() });
      audit(t, g.tenantId, u.id, 'checkin.location', 'tenant', g.tenantId, null, { lat, lng });
    });
    return c.json({ locationSet: !clear, radiusM: RADIUS_M });
  });

  /** Member or trainer scans the gym's check-in QR. */
  app.post('/api/v1/me/checkin', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const code = str(b, 'code', { max: 300, label: 'the QR code' }).trim();
    if (code.startsWith('gymmantra-join:')) throw bad('This is the gym’s join QR. To check in, scan the check-in QR in the gym');
    const m = /^gymmantra-checkin:([^:]+):([A-Za-z0-9]+)$/.exec(code);
    if (!m) throw bad('This is not a GymMantra check-in QR');
    const [, tenantId, key] = m;
    const { store } = c.var.deps;
    const [tenant, cfg] = await store.getMany<TenantDoc | CheckinDoc>([P.tenant(tenantId), P.checkin(tenantId)]) as [TenantDoc | null, CheckinDoc | null];
    if (!tenant || !cfg || cfg.key !== key) throw bad('This QR is old or not valid. Ask the gym for the new check-in QR');
    const memberId = u.memberships?.[tenantId];
    const staff = u.staffOf?.[tenantId];
    const isTrainer = !!staff?.active && staff.role === 'TRAINER';
    if (!memberId && !isTrainer) throw forbidden(`You are not a member of ${tenant.name}. Join the gym first with its gym code`);
    if (cfg.lat != null && cfg.lng != null) {
      const lat = coord(b.lat, 90);
      const lng = coord(b.lng, 180);
      if (lat == null || lng == null) throw bad('Turn on location so we can check that you are at the gym');
      const d = distanceM({ lat: cfg.lat, lng: cfg.lng }, { lat, lng });
      // Phone GPS indoors is often 10–30 m off, so the reported accuracy (up to 30 m) is allowed on top.
      const acc = typeof b.accuracy === 'number' && b.accuracy > 0 ? Math.min(b.accuracy, 30) : 0;
      if (d > RADIUS_M + acc) throw forbidden(`You are ${d >= 1000 ? `${(d / 1000).toFixed(1)} km` : `${Math.round(d)} m`} away from ${tenant.name}. Check in from inside the gym`);
    }
    const gym = { id: tenantId, name: tenant.name, whatsappNumber: tenant.whatsappNumber, phone: tenant.phone };
    if (memberId) {
      const out = await store.tx(async (t) => {
        const mem = await t.get<MemberDoc>(P.member(tenantId, memberId));
        if (!mem || mem.archived) throw notFound('Your membership at this gym was removed');
        return recordMemberCheckIn(t, tenantId, mem, { method: 'SELF', byId: u.id, oncePerDay: true });
      });
      return c.json({ kind: 'MEMBER', gym, ...out }, 201);
    }
    // Trainer attendance
    const today = todayIST();
    const out = await store.tx(async (t) => {
      const cur = (await t.get<TrainerDaysDoc>(P.trainerDays(tenantId, u.id))) ?? { month: today.slice(0, 7), visits: 0, lastAt: null, days: [] };
      const month = today.slice(0, 7);
      if (cur.days[0] === today) return { duplicate: true, visitsThisMonth: cur.month === month ? cur.visits : 0, at: cur.lastAt };
      const at = nowIso();
      const next: TrainerDaysDoc = { month, visits: (cur.month === month ? cur.visits : 0) + 1, lastAt: at, days: [today, ...cur.days].slice(0, 62) };
      t.set(P.trainerDays(tenantId, u.id), next);
      t.set(P.attendanceEv(tenantId, uuid()), { memberId: null, trainerId: u.id, memberName: u.name, memberCode: 'TRAINER', branchId: null, day: today, at, result: 'ALLOWED', reason: 'Trainer', method: 'SELF', scannedById: u.id });
      return { duplicate: false, visitsThisMonth: next.visits, at };
    });
    return c.json({ kind: 'TRAINER', gym, result: 'ALLOWED', reason: out.duplicate ? 'Already checked in today' : null, ...out }, 201);
  });
}
