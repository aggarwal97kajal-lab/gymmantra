import { openGate } from './gate';
import { App, audit, authenticate, branchCode, branchOf, gymOf, MemberDoc, P, TenantDoc, need } from '../core';
import { todayIST } from '../lib/dates';
import { bad, forbidden, HttpError, notFound, nowIso, uuid } from '../lib/http';
import { body, str } from '../lib/validate';
import { recordMemberCheckIn } from './attendance';
import { ensureBranchCodes } from './gym';

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
  /** Other branches: each has its own check-in QR and location. The first branch uses the fields above. */
  branches?: Record<string, Spot>;
}
export interface Spot {
  key: string;
  lat: number | null;
  lng: number | null;
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

const firstId = (t: TenantDoc) => t.branches[0]?.id ?? '';
/** The QR key and location of one branch (made if missing). */
function spotOf(cfg: CheckinDoc | null, t: TenantDoc, branchId: string): { cfg: CheckinDoc; spot: Spot; changed: boolean } {
  let changed = false;
  let doc = cfg;
  if (!doc) {
    doc = { key: newKey(), lat: null, lng: null, radiusM: RADIUS_M, updatedAt: nowIso() };
    changed = true;
  }
  if (branchId === firstId(t)) return { cfg: doc, spot: { key: doc.key, lat: doc.lat, lng: doc.lng }, changed };
  const cur = doc.branches?.[branchId];
  if (cur) return { cfg: doc, spot: cur, changed };
  const spot = { key: newKey(), lat: null, lng: null };
  return { cfg: { ...doc, branches: { ...(doc.branches ?? {}), [branchId]: spot } }, spot, changed: true };
}
function putSpot(cfg: CheckinDoc, t: TenantDoc, branchId: string, spot: Spot): CheckinDoc {
  if (branchId === firstId(t)) return { ...cfg, ...spot, radiusM: RADIUS_M, updatedAt: nowIso() };
  return { ...cfg, branches: { ...(cfg.branches ?? {}), [branchId]: spot }, updatedAt: nowIso() };
}
/** Which branch a scanned key belongs to. */
function branchOfKey(cfg: CheckinDoc, t: TenantDoc, key: string): { branchId: string; spot: Spot } | null {
  if (cfg.key === key) return { branchId: firstId(t), spot: { key: cfg.key, lat: cfg.lat, lng: cfg.lng } };
  for (const [id, sp] of Object.entries(cfg.branches ?? {})) if (sp.key === key && t.branches.some((b) => b.id === id)) return { branchId: id, spot: sp };
  return null;
}

const coord = (v: unknown, max: number) => (typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= max ? v : null);

export function checkinRoutes(app: App) {
  /** Owner / front desk: the check-in QR text (made on first use) and whether the gym location is set. */
  app.get('/api/v1/gym/checkin-qr', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    need(g, 'checkin');
    g.tenant = await ensureBranchCodes(c.var.deps.store, g.tenantId, g.tenant);
    const spot = await c.var.deps.store.tx(async (t) => {
      const r = spotOf(await t.get<CheckinDoc>(P.checkin(g.tenantId)), g.tenant, g.branchId);
      if (r.changed) t.set(P.checkin(g.tenantId), r.cfg);
      return r.spot;
    });
    const br = g.tenant.branches.find((b) => b.id === g.branchId);
    const code = (br && branchCode(g.tenant, br)) ?? g.tenant.gymCode;
    return c.json({
      text: checkinText(g.tenantId, spot.key),
      joinText: `gymmantra-join:${code}`,
      gymCode: code,
      branchId: g.branchId,
      branchName: br?.name ?? null,
      multiBranch: g.tenant.branches.length > 1,
      locationSet: spot.lat != null,
      radiusM: RADIUS_M,
      appCheckin: br?.appCheckin !== false,
    });
  });

  /** Owner: this branch checks in from the app (QR) or uses its own entry system. */
  app.put('/api/v1/gym/checkin-mode', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    if (typeof b.on !== 'boolean') throw bad('Choose on or off');
    const on = b.on;
    await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<TenantDoc>(P.tenant(g.tenantId)))!;
      t.set(P.tenant(g.tenantId), { ...cur, branches: cur.branches.map((x) => (x.id === g.branchId ? { ...x, appCheckin: on } : x)) });
      audit(t, g.tenantId, u.id, 'checkin.mode', 'branch', g.branchId, null, { appCheckin: on });
    });
    return c.json({ appCheckin: on });
  });

  /** Owner: make a new check-in QR (old printouts stop working). */
  app.post('/api/v1/gym/checkin-qr/rotate', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const spot = await c.var.deps.store.tx(async (t) => {
      const r = spotOf(await t.get<CheckinDoc>(P.checkin(g.tenantId)), g.tenant, g.branchId);
      const next = { ...r.spot, key: newKey() };
      t.set(P.checkin(g.tenantId), putSpot(r.cfg, g.tenant, g.branchId, next));
      audit(t, g.tenantId, u.id, 'checkin.rotate', 'branch', g.branchId);
      return next;
    });
    return c.json({ text: checkinText(g.tenantId, spot.key), locationSet: spot.lat != null, radiusM: RADIUS_M });
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
      const r = spotOf(await t.get<CheckinDoc>(P.checkin(g.tenantId)), g.tenant, g.branchId);
      t.set(P.checkin(g.tenantId), putSpot(r.cfg, g.tenant, g.branchId, { ...r.spot, lat: clear ? null : lat, lng: clear ? null : lng }));
      audit(t, g.tenantId, u.id, 'checkin.location', 'branch', g.branchId, null, { lat, lng });
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
    const hit = tenant && cfg ? branchOfKey(cfg, tenant, key) : null;
    if (!tenant || !cfg || !hit) throw bad('This QR is old or not valid. Ask the gym for the new check-in QR');
    const spot = hit.spot;
    const branchName = tenant.branches.find((b) => b.id === hit.branchId)?.name ?? null;
    if (tenant.branches.find((x) => x.id === branchOf(tenant, hit.branchId))?.appCheckin === false) {
      const where = hit.branchId && hit.branchId !== tenant.branches[0]?.id ? branchName ?? tenant.name : tenant.name;
      throw new HttpError(403, `App check-in is off at ${where}. Please check in at the front desk.`, { code: 'CHECKIN_OFF' });
    }
    const memberId = u.memberships?.[tenantId];
    const staff = u.staffOf?.[tenantId];
    const isTrainer = !!staff?.active && staff.role === 'TRAINER';
    if (!memberId && !isTrainer) throw forbidden(`You are not a member of ${tenant.name}. Join the gym first with its gym code`);
    // A fake-location (mock) app on the phone: no check-in (same rule as staff attendance).
    if (b.mocked === true) throw forbidden('A fake location app is on. Turn it off to check in');
    if (spot.lat != null && spot.lng != null) {
      const lat = coord(b.lat, 90);
      const lng = coord(b.lng, 180);
      if (lat == null || lng == null) throw bad('Turn on location so we can check that you are at the gym');
      const d = distanceM({ lat: spot.lat, lng: spot.lng }, { lat, lng });
      // Phone GPS indoors is often 10–30 m off, so the reported accuracy (up to 30 m) is allowed on top.
      const acc = typeof b.accuracy === 'number' && b.accuracy > 0 ? Math.min(b.accuracy, 30) : 0;
      if (d > RADIUS_M + acc) throw forbidden(`You are ${d >= 1000 ? `${(d / 1000).toFixed(1)} km` : `${Math.round(d)} m`} away from ${tenant.name}. Check in from inside the gym`);
    }
    // Main branch shows the gym name; another branch shows only its own name.
    const isMain = hit.branchId == null || hit.branchId === tenant.branches[0]?.id;
    const gym = { id: tenantId, name: isMain ? tenant.name : branchName ?? tenant.name, branchName: null, whatsappNumber: tenant.whatsappNumber, phone: tenant.phone };
    if (memberId) {
      const out = await store.tx(async (t) => {
        const mem = await t.get<MemberDoc>(P.member(tenantId, memberId));
        if (!mem || mem.archived) throw notFound('Your membership at this gym was removed');
        // A member checks in only at their own branch: the QR of another branch is refused.
        const mine = branchOf(tenant, mem.branchId);
        if (mine !== branchOf(tenant, hit.branchId)) {
          const b = tenant.branches.find((x) => x.id === mine);
          const myName = !b || b.id === tenant.branches[0]?.id ? tenant.name : b.name;
          const here = hit.branchId && hit.branchId !== tenant.branches[0]?.id ? branchName ?? tenant.name : tenant.name;
          throw new HttpError(403, `This is the check-in QR of ${here}. Your membership is at ${myName}, so check in there. To move branches, ask your gym.`, { code: 'OTHER_BRANCH' });
        }
        // The visit counts for the branch whose QR was scanned.
        return recordMemberCheckIn(t, tenantId, mem, { method: 'SELF', byId: u.id, branchId: hit.branchId, oncePerDay: true });
      });
      const gate = out.result === 'ALLOWED' ? await openGate(c.var.deps, tenantId, hit.branchId) : null;
      return c.json({ kind: 'MEMBER', gym, ...out, gate }, 201);
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
      t.set(P.attendanceEv(tenantId, uuid()), { memberId: null, trainerId: u.id, memberName: u.name, memberCode: 'TRAINER', branchId: hit.branchId, day: today, at, result: 'ALLOWED', reason: 'Trainer', method: 'SELF', scannedById: u.id });
      return { duplicate: false, visitsThisMonth: next.visits, at };
    });
    const gate = await openGate(c.var.deps, tenantId, hit.branchId);
    return c.json({ kind: 'TRAINER', gym, result: 'ALLOWED', reason: out.duplicate ? 'Already checked in today' : null, ...out, gate }, 201);
  });
}
