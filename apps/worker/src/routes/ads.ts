import { App, audit, authenticate, P, requireSuper, TenantDoc } from '../core';
import { isYmd, todayIST } from '../lib/dates';
import { bad, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { body, oneOf, optBool, optStr, str, strList } from '../lib/validate';
import { stateByName } from '../lib/india';
import { couponExists } from './payments';

// ---------- Ads the super admin shows on dashboards ----------

export type AdRole = 'MEMBER' | 'TRAINER' | 'OWNER';

export interface AdDoc {
  id: string;
  title: string;
  body: string | null;
  linkKind: 'URL' | 'WHATSAPP' | 'CALL' | 'NONE';
  linkValue: string | null;
  forMembers: boolean;
  forTrainers: boolean;
  forOwners: boolean;
  states: string[]; // empty = all India
  startsOn: string;
  endsOn: string;
  active: boolean;
  imageV: number | null;
  color: string;
  couponCode?: string | null; // owners tap it to use the coupon on a plan
  views: Record<AdRole, number>;
  clicks: Record<AdRole, number>;
  createdAt: string;
}

const ZERO = { MEMBER: 0, TRAINER: 0, OWNER: 0 };
const MAX_IMAGE = 350 * 1024;

function readAd(b: Record<string, unknown>, cur?: AdDoc) {
  const pick = <T>(k: string, f: () => T, fallback: T) => (b[k] !== undefined || !cur ? f() : fallback);
  const title = pick('title', () => str(b, 'title', { min: 3, max: 60, label: 'the ad title' }), cur?.title ?? '');
  const text = pick('body', () => optStr(b, 'body', { max: 140 }) ?? null, cur?.body ?? null);
  const linkKind = oneOf(b, 'linkKind', ['URL', 'WHATSAPP', 'CALL', 'NONE'] as const, true) ?? cur?.linkKind ?? 'NONE';
  const linkValue = pick('linkValue', () => optStr(b, 'linkValue', { max: 300 }) ?? null, cur?.linkValue ?? null);
  if (linkKind === 'URL' && !(linkValue ?? '').startsWith('https://')) throw bad('The link must start with https://');
  if ((linkKind === 'WHATSAPP' || linkKind === 'CALL') && !/^\+?\d{10,13}$/.test((linkValue ?? '').replace(/[\s-]/g, ''))) throw bad('Enter a valid phone number');
  const forMembers = optBool(b, 'forMembers') ?? cur?.forMembers ?? true;
  const forTrainers = optBool(b, 'forTrainers') ?? cur?.forTrainers ?? false;
  const forOwners = optBool(b, 'forOwners') ?? cur?.forOwners ?? false;
  if (!forMembers && !forTrainers && !forOwners) throw bad('Choose who should see this ad');
  const states = b.states !== undefined ? strList(b, 'states', 40) ?? [] : cur?.states ?? [];
  if (states.some((s) => !stateByName(s))) throw bad('Unknown state');
  const startsOn = pick('startsOn', () => optStr(b, 'startsOn') ?? todayIST(), cur?.startsOn ?? todayIST());
  const endsOn = pick('endsOn', () => str(b, 'endsOn', { label: 'the last date' }), cur?.endsOn ?? '');
  if (!isYmd(startsOn) || !isYmd(endsOn)) throw bad('Dates are not valid');
  if (endsOn < startsOn) throw bad('The last date is before the start date');
  const color = pick('color', () => optStr(b, 'color', { max: 9 }) ?? '#2563EB', cur?.color ?? '#2563EB');
  if (!/^#[0-9A-Fa-f]{6}$/.test(color)) throw bad('Colour is not valid');
  const couponCode = pick('couponCode', () => (optStr(b, 'couponCode', { max: 20 }) ?? '').trim().toUpperCase() || null, cur?.couponCode ?? null);
  return { title, body: text, linkKind, linkValue, forMembers, forTrainers, forOwners, states, startsOn, endsOn, color, couponCode };
}

const view = (a: AdDoc) => ({ ...a, imageUrl: a.imageV ? `/api/v1/ads/${a.id}/image?v=${a.imageV}` : null, live: a.active && a.startsOn <= todayIST() && a.endsOn >= todayIST() });

export function adRoutes(app: App) {
  // ---- super admin ----
  app.get('/api/v1/super/ads', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const rows = (await c.var.deps.store.query<AdDoc>(P.ads)).map((r) => view(r.data));
    return c.json(rows.sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)));
  });

  app.post('/api/v1/super/ads', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const b = body(await c.req.json().catch(() => null));
    const ad: AdDoc = { id: uuid(), ...readAd(b), active: true, imageV: null, views: { ...ZERO }, clicks: { ...ZERO }, createdAt: nowIso() };
    if (ad.couponCode && !(await couponExists(c.var.deps.store, ad.couponCode))) throw bad('No coupon with this code. Make the coupon first');
    await c.var.deps.store.tx(async (t) => {
      t.set(P.ad(ad.id), ad);
      audit(t, null, u.id, 'ad.create', 'ad', ad.id, null, ad);
    });
    return c.json(view(ad), 201);
  });

  app.patch('/api/v1/super/ads/:id', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const out = await c.var.deps.store.tx(async (t) => {
      const before = isUuid(id) ? await t.get<AdDoc>(P.ad(id)) : null;
      if (!before) throw notFound('Ad not found');
      const after: AdDoc = { ...before, ...readAd(b, before), active: optBool(b, 'active') ?? before.active };
      if (after.couponCode && after.couponCode !== before.couponCode && !(await couponExists(t, after.couponCode))) throw bad('No coupon with this code. Make the coupon first');
      t.set(P.ad(id), after);
      audit(t, null, u.id, 'ad.update', 'ad', id, before, after);
      return after;
    });
    return c.json(view(out));
  });

  app.delete('/api/v1/super/ads/:id', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    await c.var.deps.store.tx(async (t) => {
      const before = isUuid(id) ? await t.get<AdDoc>(P.ad(id)) : null;
      if (!before) throw notFound('Ad not found');
      t.delete(P.ad(id));
      if (before.imageV) t.delete(P.adImage(id));
      audit(t, null, u.id, 'ad.delete', 'ad', id, before, null);
    });
    return c.json({ ok: true });
  });

  app.post('/api/v1/super/ads/:id/image', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const mime = oneOf(b, 'mime', ['image/jpeg', 'image/png'] as const)!;
    const b64 = str(b, 'base64', { max: 500_000 });
    const size = Math.floor((b64.length * 3) / 4);
    if (size > MAX_IMAGE) throw bad('Image must be smaller than 350 KB');
    const v = Date.now();
    const out = await c.var.deps.store.tx(async (t) => {
      const ad = isUuid(id) ? await t.get<AdDoc>(P.ad(id)) : null;
      if (!ad) throw notFound('Ad not found');
      t.set(P.adImage(id), { mime, b64 });
      const next = { ...ad, imageV: v };
      t.set(P.ad(id), next);
      return next;
    });
    return c.json(view(out), 201);
  });

  app.get('/api/v1/ads/:id/image', async (c) => {
    const id = c.req.param('id');
    const img = isUuid(id) ? await c.var.deps.store.get<{ mime: string; b64: string }>(P.adImage(id)) : null;
    if (!img) throw notFound('No image');
    const bin = atob(img.b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new Response(bytes, { headers: { 'content-type': img.mime, 'cache-control': 'public, max-age=604800' } });
  });

  // ---- app ----
  /** Live ads for this person's role and the states of their gyms. */
  app.get('/api/v1/ads', async (c) => {
    const u = await authenticate(c);
    const role = oneOf({ r: c.req.query('role') ?? 'MEMBER' }, 'r', ['MEMBER', 'TRAINER', 'OWNER'] as const)!;
    const { store } = c.var.deps;
    const gymIds =
      role === 'MEMBER'
        ? Object.keys(u.memberships ?? {})
        : Object.entries(u.staffOf ?? {})
            .filter(([, s]) => s.active && (role === 'TRAINER' ? s.role === 'TRAINER' : s.role !== 'TRAINER'))
            .map(([id]) => id);
    const [rows, tenants] = await Promise.all([store.query<AdDoc>(P.ads, [['active', true]]), store.getMany<TenantDoc>(gymIds.map(P.tenant))]);
    const myStates = new Set(tenants.map((t) => t?.state).filter(Boolean) as string[]);
    const today = todayIST();
    const ads = rows
      .map((r) => r.data)
      .filter((a) => a.startsOn <= today && a.endsOn >= today)
      .filter((a) => (role === 'MEMBER' ? a.forMembers : role === 'TRAINER' ? a.forTrainers : a.forOwners))
      .filter((a) => !a.states.length || a.states.some((s) => myStates.has(s)))
      .map((a) => {
        const v = view(a);
        return { id: v.id, title: v.title, body: v.body, linkKind: v.linkKind, linkValue: v.linkValue, imageUrl: v.imageUrl, color: v.color, couponCode: role === 'OWNER' ? v.couponCode ?? null : null };
      });
    return c.json(ads);
  });

  /** The app reports a view (once a day per ad) or a tap. */
  app.post('/api/v1/ads/:id/event', async (c) => {
    await authenticate(c);
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const type = oneOf(b, 'type', ['view', 'click'] as const)!;
    const role = oneOf(b, 'role', ['MEMBER', 'TRAINER', 'OWNER'] as const)!;
    await c.var.deps.store.tx(async (t) => {
      const ad = isUuid(id) ? await t.get<AdDoc>(P.ad(id)) : null;
      if (!ad) return;
      const key = type === 'view' ? 'views' : 'clicks';
      const cur = { ...ZERO, ...(ad[key] ?? {}) };
      cur[role] += 1;
      t.set(P.ad(id), { ...ad, [key]: cur });
    });
    return c.json({ ok: true });
  });
}
