import { App, audit, authenticate, branchOf, gymOf, inBranch, P, Role, TenantDoc, UserDoc, gymFace } from '../core';
import { noticesFor } from './notices';
import { isYmd, todayIST } from '../lib/dates';
import { bad, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { body, int, oneOf, optBool, optInt, optStr, str } from '../lib/validate';
import type { Reader } from '../store/store';
import { requireFeature } from './billing';

// ---------- Trainers (staff with role TRAINER) and gym offers ----------

export interface PtPackage {
  id: string;
  sessions: number;
  days: number; // how long the package lasts
  perWeek: number | null;
  price: number;
}

export interface TrainerDoc {
  branchId?: string | null; // branch the trainer works at (old trainers: first branch)
  userId: string;
  name: string;
  speciality: string | null;
  experienceYears: number | null;
  bio: string | null;
  hours: string | null;
  packages: PtPackage[];
  visible: boolean; // shown to members
  sharePercent: number; // trainer's share of PT money (owner pays it)
  active: boolean;
  createdAt: string;
}

export function newTrainer(userId: string, name: string, speciality: string | null, experienceYears: number | null): TrainerDoc {
  return { userId, name, speciality, experienceYears, bio: null, hours: null, packages: [], visible: true, sharePercent: 50, active: true, createdAt: nowIso() };
}

export const photoUrlOf = (uid: string, u: Pick<UserDoc, 'photoV'> | null | undefined) => (u?.photoV ? `/api/v1/photos/${uid}?v=${u.photoV}` : null);

export function trainerView(t: TrainerDoc, u: UserDoc | null) {
  return {
    id: t.userId,
    name: u?.name ?? t.name,
    photoUrl: photoUrlOf(t.userId, u),
    phone: u?.phone ?? null,
    speciality: t.speciality,
    experienceYears: t.experienceYears,
    bio: t.bio,
    hours: t.hours,
    packages: [...t.packages].sort((a, b) => a.sessions - b.sessions),
    visible: t.visible,
    sharePercent: t.sharePercent,
  };
}

export async function listTrainers(r: Reader, tenantId: string, onlyVisible: boolean) {
  const rows = (await r.query<TrainerDoc>(P.trainers(tenantId), [['active', true]])).map((x) => x.data).filter((t) => !onlyVisible || t.visible);
  const users = await r.getMany<UserDoc>(rows.map((t) => P.user(t.userId)));
  return rows.map((t, i) => trainerView(t, users[i])).sort((a, b) => a.name.localeCompare(b.name));
}

export interface OfferDoc {
  id: string;
  branchIds?: string[] | null; // branches that see it (null = every branch)
  imageV?: number | null; // banner picture version
  title: string;
  details: string | null;
  validTill: string;
  forMembers: boolean;
  forTrainers: boolean;
  memberFilter: 'ALL' | 'ACTIVE' | 'EXPIRING' | 'EXPIRED';
  active: boolean;
  createdById: string;
  createdAt: string;
}

export const offerImageUrl = (tenantId: string, o: Pick<OfferDoc, 'id' | 'imageV'>) => (o.imageV ? `/api/v1/offers/${tenantId}/${o.id}/image?v=${o.imageV}` : null);
const MAX_BANNER = 400 * 1024;

/** Live offers of a gym for a member (with their membership status) or a trainer. */
export async function offersFor(r: Reader, tenantId: string, who: 'MEMBER' | 'TRAINER', memberStatus?: string, branchId?: string | null) {
  const today = todayIST();
  const rows = (await r.query<OfferDoc>(P.offers(tenantId), [['active', true]]))
    .map((x) => x.data)
    .filter((o) => o.validTill >= today && (!o.branchIds?.length || !branchId || o.branchIds.includes(branchId)));
  return rows
    .filter((o) => {
      if (who === 'TRAINER') return o.forTrainers;
      if (!o.forMembers) return false;
      switch (o.memberFilter) {
        case 'ACTIVE':
          return memberStatus === 'ACTIVE' || memberStatus === 'ENDING_SOON' || memberStatus === 'FROZEN';
        case 'EXPIRING':
          return memberStatus === 'ENDING_SOON';
        case 'EXPIRED':
          return memberStatus === 'EXPIRED' || memberStatus === 'NO_PLAN';
        default:
          return true;
      }
    })
    .sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1))
    .map((o) => ({ id: o.id, title: o.title, details: o.details, validTill: o.validTill, imageUrl: offerImageUrl(tenantId, o) }));
}

function packagesFrom(v: unknown): PtPackage[] {
  if (!Array.isArray(v) || v.length > 10) throw bad('Up to 10 PT packages');
  return v.map((x) => {
    const b = (x ?? {}) as Record<string, unknown>;
    return {
      id: typeof b.id === 'string' && isUuid(b.id) ? b.id : uuid(),
      sessions: int(b, 'sessions', { min: 1, max: 300, label: 'sessions' }),
      days: int(b, 'days', { min: 1, max: 400, label: 'days' }),
      perWeek: optInt(b, 'perWeek', { min: 1, max: 7 }) ?? null,
      price: int(b, 'price', { min: 0, max: 1_000_000, label: 'price' }),
    };
  });
}

export function trainerRoutes(app: App) {
  // ---- owner / front desk ----
  app.get('/api/v1/trainers', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const { store } = c.var.deps;
    // One list read, then names/photos and check-in days together (fewer round trips = opens faster).
    const rows = (await store.query<TrainerDoc>(P.trainers(g.tenantId), [['active', true]])).map((r) => r.data).filter((t) => inBranch(g, t.branchId));
    const [users, days0] = await Promise.all([
      store.getMany<UserDoc>(rows.map((t) => P.user(t.userId))),
      store.getMany<{ month: string; visits: number; lastAt: string | null; days: string[] }>(rows.map((t) => P.trainerDays(g.tenantId, t.userId))),
    ]);
    const joined = rows.map((t, i) => ({ v: trainerView(t, users[i]), d: days0[i] })).sort((a, b) => a.v.name.localeCompare(b.v.name));
    const list = joined.map((x) => x.v);
    const days = joined.map((x) => x.d);
    const month = todayIST().slice(0, 7);
    return c.json(list.map((t, i) => ({ ...t, visitsThisMonth: days[i]?.month === month ? days[i]!.visits : 0, lastCheckinAt: days[i]?.lastAt ?? null, checkinDays: days[i]?.days.slice(0, 31) ?? [] })));
  });

  app.patch('/api/v1/trainers/:id', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const out = await c.var.deps.store.tx(async (t) => {
      const before = await t.get<TrainerDoc>(P.trainer(g.tenantId, id));
      if (!before || !before.active) throw notFound('Trainer not found');
      const after: TrainerDoc = { ...before };
      if (b.speciality !== undefined) after.speciality = optStr(b, 'speciality', { max: 200 }) ?? null;
      if (b.experienceYears !== undefined) after.experienceYears = optInt(b, 'experienceYears', { min: 0, max: 60 }) ?? null;
      if (b.bio !== undefined) after.bio = optStr(b, 'bio', { max: 400 }) ?? null;
      if (b.hours !== undefined) after.hours = optStr(b, 'hours', { max: 60 }) ?? null;
      const vis = optBool(b, 'visible');
      if (vis !== undefined) after.visible = vis;
      if (b.sharePercent !== undefined) after.sharePercent = int(b, 'sharePercent', { min: 0, max: 100, label: 'trainer share' });
      if (b.packages !== undefined) after.packages = packagesFrom(b.packages);
      t.set(P.trainer(g.tenantId, id), after);
      audit(t, g.tenantId, u.id, 'trainer.update', 'trainer', id, before, after);
      return after;
    });
    const tu = await c.var.deps.store.get<UserDoc>(P.user(id));
    return c.json(trainerView(out, tu));
  });

  app.post('/api/v1/trainers/:id/remove', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    await c.var.deps.store.tx(async (t) => {
      const tr = await t.get<TrainerDoc>(P.trainer(g.tenantId, id));
      const st = await t.get<{ role: Role; active: boolean }>(P.staff(g.tenantId, id));
      if (!tr || !st || st.role !== 'TRAINER') throw notFound('Trainer not found');
      const tu = await t.get<UserDoc>(P.user(id));
      t.set(P.trainer(g.tenantId, id), { ...tr, active: false });
      t.set(P.staff(g.tenantId, id), { ...st, active: false });
      if (tu) t.set(P.user(id), { ...tu, staffOf: { ...tu.staffOf, [g.tenantId]: { role: 'TRAINER', branchIds: [], active: false } } });
      audit(t, g.tenantId, u.id, 'trainer.remove', 'trainer', id, tr, null);
    });
    return c.json({ ok: true });
  });

  // ---- trainer ----
  app.get('/api/v1/trainer/home', async (c) => {
    const u = await authenticate(c);
    const { store } = c.var.deps;
    const gyms = Object.entries(u.staffOf ?? {}).filter(([, s]) => s.active && s.role === 'TRAINER').map(([id]) => id);
    const pending = Object.keys(u.trainerRequested ?? {});
    const [tenants, profiles, pendingTenants] = await Promise.all([
      store.getMany<TenantDoc>(gyms.map(P.tenant)),
      store.getMany<TrainerDoc>(gyms.map((t) => P.trainer(t, u.id))),
      store.getMany<TenantDoc>(pending.map(P.tenant)),
    ]);
    // Each trainer sees their own branch's offers and notices.
    const myBranch = gyms.map((t, i) => (tenants[i] ? branchOf(tenants[i]!, profiles[i]?.branchId ?? u.staffOf?.[t]?.branchIds?.[0]) : null));
    const [offers, notices] = await Promise.all([
      Promise.all(gyms.map((t, i) => offersFor(store, t, 'TRAINER', undefined, myBranch[i]))),
      Promise.all(gyms.map((t, i) => noticesFor(store, t, 'TRAINER', undefined, 0, 0, myBranch[i]))),
    ]);
    return c.json({
      gyms: gyms
        .map((id, i) => (tenants[i] && profiles[i] ? { id, ...(() => { const f = gymFace(tenants[i]!, myBranch[i]); return { name: f.name, branchName: f.branchName, code: f.code, address: f.address }; })(), phone: tenants[i]!.phone, profile: trainerView(profiles[i]!, u), offers: offers[i], notices: notices[i] } : null))
        .filter(Boolean),
      pending: pending.map((id, i) => (pendingTenants[i] ? { id, name: pendingTenants[i]!.name } : null)).filter(Boolean),
    });
  });

  app.patch('/api/v1/trainer/profile', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'TRAINER');
    const b = body(await c.req.json().catch(() => null));
    const out = await c.var.deps.store.tx(async (t) => {
      const cur = await t.get<TrainerDoc>(P.trainer(g.tenantId, u.id));
      if (!cur) throw notFound('Trainer profile not found');
      const next = { ...cur };
      if (b.speciality !== undefined) next.speciality = optStr(b, 'speciality', { max: 200 }) ?? null;
      if (b.experienceYears !== undefined) next.experienceYears = optInt(b, 'experienceYears', { min: 0, max: 60 }) ?? null;
      if (b.bio !== undefined) next.bio = optStr(b, 'bio', { max: 400 }) ?? null;
      if (b.hours !== undefined) next.hours = optStr(b, 'hours', { max: 60 }) ?? null;
      t.set(P.trainer(g.tenantId, u.id), next);
      return next;
    });
    return c.json(trainerView(out, u));
  });

  // ---- offers (owner creates; members / trainers see them on their dashboard) ----
  app.get('/api/v1/offers', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const rows = (await c.var.deps.store.query<OfferDoc>(P.offers(g.tenantId))).map((x) => x.data).filter((o) => !o.branchIds?.length || o.branchIds.includes(g.branchId));
    const today = todayIST();
    return c.json(rows.map((o) => ({ ...o, imageUrl: offerImageUrl(g.tenantId, o), live: o.active && o.validTill >= today })).sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)));
  });

  const readOffer = (b: Record<string, unknown>, cur?: OfferDoc) => {
    const title = b.title !== undefined || !cur ? str(b, 'title', { min: 3, max: 80, label: 'the offer name' }) : cur.title;
    const details = b.details !== undefined ? optStr(b, 'details', { max: 300 }) ?? null : cur?.details ?? null;
    const validTill = b.validTill !== undefined || !cur ? str(b, 'validTill', { label: 'the last date' }) : cur.validTill;
    if (!isYmd(validTill)) throw bad('Choose a valid last date');
    const forMembers = optBool(b, 'forMembers') ?? cur?.forMembers ?? true;
    const forTrainers = optBool(b, 'forTrainers') ?? cur?.forTrainers ?? false;
    if (!forMembers && !forTrainers) throw bad('Choose who should see this offer');
    const memberFilter = oneOf(b, 'memberFilter', ['ALL', 'ACTIVE', 'EXPIRING', 'EXPIRED'] as const, true) ?? cur?.memberFilter ?? 'ALL';
    return { title, details, validTill, forMembers, forTrainers, memberFilter };
  };
  /** Branches from the request: a list of ids, "ALL", or (default) the branch the app is looking at. */
  const readBranches = (b: Record<string, unknown>, g: { tenant: TenantDoc; branchId: string }, cur?: { branchIds?: string[] | null }) => {
    if (b.branchIds === 'ALL') return null;
    if (Array.isArray(b.branchIds)) {
      const ids = (b.branchIds as unknown[]).filter((x): x is string => typeof x === 'string' && g.tenant.branches.some((br) => br.id === x));
      if (!ids.length) throw bad('Choose at least one branch');
      return ids.length === g.tenant.branches.length ? null : ids;
    }
    return cur ? cur.branchIds ?? null : [g.branchId];
  };

  app.post('/api/v1/offers', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    await requireFeature(c.var.deps.store, g.tenant, 'offers');
    const b = body(await c.req.json().catch(() => null));
    const o: OfferDoc = { id: uuid(), ...readOffer(b), branchIds: readBranches(b, g), active: true, createdById: u.id, createdAt: nowIso() };
    if (o.validTill < todayIST()) throw bad('The last date has already passed');
    await c.var.deps.store.tx(async (t) => {
      t.set(P.offer(g.tenantId, o.id), o);
      audit(t, g.tenantId, u.id, 'offer.create', 'offer', o.id, null, o);
    });
    return c.json(o, 201);
  });

  app.patch('/api/v1/offers/:id', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const out = await c.var.deps.store.tx(async (t) => {
      const before = isUuid(id) ? await t.get<OfferDoc>(P.offer(g.tenantId, id)) : null;
      if (!before) throw notFound('Offer not found');
      const after: OfferDoc = { ...before, ...readOffer(b, before), branchIds: readBranches(b, g, before), active: optBool(b, 'active') ?? before.active };
      t.set(P.offer(g.tenantId, id), after);
      audit(t, g.tenantId, u.id, 'offer.update', 'offer', id, before, after);
      return after;
    });
    return c.json(out);
  });

  app.delete('/api/v1/offers/:id', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    await c.var.deps.store.tx(async (t) => {
      const before = isUuid(id) ? await t.get<OfferDoc>(P.offer(g.tenantId, id)) : null;
      if (!before) throw notFound('Offer not found');
      t.delete(P.offer(g.tenantId, id));
      if (before.imageV) t.delete(P.offerImage(g.tenantId, id));
      audit(t, g.tenantId, u.id, 'offer.delete', 'offer', id, before, null);
    });
    return c.json({ ok: true });
  });

  /** Banner picture for an offer (JPEG/PNG up to 400 KB). */
  app.post('/api/v1/offers/:id/image', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const mime = oneOf(b, 'mime', ['image/jpeg', 'image/png'] as const)!;
    const b64 = str(b, 'base64', { max: 560_000, label: 'the picture' });
    if (Math.floor((b64.length * 3) / 4) > MAX_BANNER) throw bad('Banner must be smaller than 400 KB');
    const v = Date.now();
    const out = await c.var.deps.store.tx(async (t) => {
      const o = isUuid(id) ? await t.get<OfferDoc>(P.offer(g.tenantId, id)) : null;
      if (!o) throw notFound('Offer not found');
      t.set(P.offerImage(g.tenantId, id), { mime, b64 });
      const next = { ...o, imageV: v };
      t.set(P.offer(g.tenantId, id), next);
      return next;
    });
    return c.json({ ...out, imageUrl: offerImageUrl(g.tenantId, out) }, 201);
  });

  app.delete('/api/v1/offers/:id/image', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    const out = await c.var.deps.store.tx(async (t) => {
      const o = isUuid(id) ? await t.get<OfferDoc>(P.offer(g.tenantId, id)) : null;
      if (!o) throw notFound('Offer not found');
      t.delete(P.offerImage(g.tenantId, id));
      const next = { ...o, imageV: null };
      t.set(P.offer(g.tenantId, id), next);
      return next;
    });
    return c.json({ ...out, imageUrl: null });
  });

  /** Offer banners are not private (members and trainers of the gym see them); cached by the phone. */
  app.get('/api/v1/offers/:tenantId/:id/image', async (c) => {
    const tid = c.req.param('tenantId');
    const id = c.req.param('id');
    const img = isUuid(id) && isUuid(tid) ? await c.var.deps.store.get<{ mime: string; b64: string }>(P.offerImage(tid, id)) : null;
    if (!img) throw notFound('No image');
    const bin = atob(img.b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new Response(bytes, { headers: { 'content-type': img.mime, 'cache-control': 'public, max-age=604800' } });
  });
}
