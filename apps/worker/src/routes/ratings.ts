import { App, audit, authenticate, branchOf, gymOf, MemberDoc, P, TenantDoc, UserDoc } from '../core';
import type { Store } from '../store/store';
import { todayIST } from '../lib/dates';
import { bad, forbidden, notFound, nowIso } from '../lib/http';
import { body, int, optStr, strList } from '../lib/validate';
import type { TrainerDoc } from './trainers';

/**
 * Ratings (boards 86, 87).
 * Trainer: a member gives their gym's trainer 1-5 stars, tags and a comment, once a month (the same
 * month can be changed). The owner sees everything; the trainer sees only the number and the tags.
 * Gym: a member gives the gym stars, tags and a comment (one each, can be changed), and may allow it
 * to be shown with their name. The owner picks which to show; picked ones are kept on the gym
 * document (`testimonials`) so every dashboard reads them with no extra reads.
 */
export interface TrainerRating {
  trainerId: string;
  userId: string;
  name: string;
  stars: number;
  tags: string[];
  comment: string | null;
  month: string;
  at: string;
}
export interface GymRating {
  userId: string;
  branchId?: string | null; // the member's branch (old ratings: the main branch)
  name: string;
  stars: number;
  tags: string[];
  comment: string | null;
  allowShow: boolean;
  shown: boolean;
  at: string;
}
export interface Testimonial {
  userId: string;
  name: string;
  stars: number;
  text: string;
  branchId?: string | null;
  photoV?: number | null;
}

type Sums = Record<string, { total: number; count: number }>;
/** Rating totals per branch; before branch-wise ratings the whole-gym total counted for the main branch. */
function sumsOf(t: TenantDoc): Sums {
  if (t.ratingSums) return { ...t.ratingSums };
  const main = t.branches[0]?.id;
  return main && t.ratingSum?.count ? { [main]: { ...t.ratingSum } } : {};
}
function addTo(s: Sums, branchId: string, stars: number, n: number) {
  const cur = s[branchId] ?? { total: 0, count: 0 };
  s[branchId] = { total: cur.total + stars * n, count: cur.count + n };
}
const avgOf = (s?: { total: number; count: number }) => (s?.count ? Math.round((s.total / s.count) * 10) / 10 : null);

/**
 * What a branch's people see: that branch's rating and the testimonials the owner chose there.
 * `code` goes into photo links for people who only typed the gym code (join page).
 */
export function testimonialsFor(t: TenantDoc, tenantId: string, branchId: string | null | undefined, code?: string) {
  const bid = branchOf(t, branchId);
  const s = bid ? sumsOf(t)[bid] : undefined;
  return {
    avg: avgOf(s),
    count: s?.count ?? 0,
    items: (t.testimonials ?? [])
      .filter((x) => branchOf(t, x.branchId) === bid)
      .map((x) => ({
        name: x.name,
        stars: x.stars,
        text: x.text,
        photoUrl: x.photoV ? `/api/v1/gyms/${tenantId}/testimonials/${x.userId}/photo?v=${x.photoV}${code ? `&code=${encodeURIComponent(code)}` : ''}` : null,
      })),
  };
}

/** After a member moves branch, their gym rating (and testimonial) moves with them. */
export async function moveGymRating(store: Store, tenantId: string, userId: string | null | undefined) {
  if (!userId) return;
  await store.tx(async (t) => {
    const [r, tenant, u] = (await t.getMany<any>([P.gymRating(tenantId, userId), P.tenant(tenantId), P.user(userId)])) as [GymRating | null, TenantDoc | null, UserDoc | null];
    const mid = u?.memberships?.[tenantId];
    if (!r || !tenant || !mid) return;
    const m = await t.get<MemberDoc>(P.member(tenantId, mid));
    const from = branchOf(tenant, r.branchId);
    const to = branchOf(tenant, m?.branchId);
    if (!from || !to || from === to) return;
    const sums = sumsOf(tenant);
    addTo(sums, from, r.stars, -1);
    addTo(sums, to, r.stars, 1);
    const list = (tenant.testimonials ?? []).map((x) => (x.userId === userId ? { ...x, branchId: to } : x));
    t.set(P.gymRating(tenantId, userId), { ...r, branchId: to });
    t.set(P.tenant(tenantId), { ...tenant, ratingSums: sums, testimonials: list });
  });
}

const shortName = (n: string) => {
  const w = n.trim().split(/\s+/);
  return w.length > 1 ? `${w[0]} ${w[w.length - 1][0]}.` : w[0];
};
const avg = (xs: number[]) => (xs.length ? Math.round((xs.reduce((a, b) => a + b, 0) / xs.length) * 10) / 10 : null);
function tagCounts(rows: { tags: string[] }[]) {
  const m: Record<string, number> = {};
  for (const r of rows) for (const t of r.tags) m[t] = (m[t] ?? 0) + 1;
  return Object.entries(m)
    .sort((a, b) => b[1] - a[1])
    .map(([tag, n]) => ({ tag, n }));
}

function memberOf(u: UserDoc, tenantId: string) {
  if (!u.memberships?.[tenantId]) throw forbidden('You are not a member of this gym');
}

export function ratingRoutes(app: App) {
  // ---------------- trainers ----------------
  /** Member: rate a trainer of my gym (this month's rating can be changed). */
  app.put('/api/v1/me/gyms/:tenantId/trainers/:trainerId/rating', async (c) => {
    const u = await authenticate(c);
    const tenantId = c.req.param('tenantId');
    const trainerId = c.req.param('trainerId');
    memberOf(u, tenantId);
    const b = body(await c.req.json().catch(() => null));
    const stars = int(b, 'stars', { min: 1, max: 5, label: 'stars' });
    const tags = (strList(b, 'tags', 8) ?? []).map((t) => t.slice(0, 40));
    const comment = optStr(b, 'comment', { max: 500 }) ?? null;
    const { store } = c.var.deps;
    const tr = await store.get<TrainerDoc>(P.trainer(tenantId, trainerId));
    if (!tr || tr.gone) throw notFound('Trainer not found');
    const month = todayIST().slice(0, 7);
    const r: TrainerRating = { trainerId, userId: u.id, name: shortName(u.name), stars, tags, comment, month, at: nowIso() };
    await store.set(P.trainerRating(tenantId, trainerId, u.id, month), r);
    return c.json(r);
  });

  /** Member: which trainers of this gym I can rate, and my rating this month. */
  app.get('/api/v1/me/gyms/:tenantId/trainer-ratings', async (c) => {
    const u = await authenticate(c);
    const tenantId = c.req.param('tenantId');
    memberOf(u, tenantId);
    const { store } = c.var.deps;
    const trainers = (await store.query<TrainerDoc>(P.trainers(tenantId), [['active', true]])).filter((t) => !t.data.gone);
    const month = todayIST().slice(0, 7);
    const mine = await store.getMany<TrainerRating>(trainers.map((t) => P.trainerRating(tenantId, t.id, u.id, month)));
    return c.json(trainers.map((t, i) => ({ trainerId: t.id, name: t.data.name, mine: mine[i] ?? null })));
  });

  /** Owner: every trainer's rating, with tags and the latest comments (with names). */
  app.get('/api/v1/trainer-ratings', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const { store } = c.var.deps;
    const [trainers, all] = await Promise.all([store.query<TrainerDoc>(P.trainers(g.tenantId)), store.query<TrainerRating>(P.trainerRatings(g.tenantId))]);
    const rows = trainers
      .filter((t) => !t.data.gone)
      .map((t) => {
        const mine = all.map((r) => r.data).filter((r) => r.trainerId === t.id);
        return {
          trainerId: t.id,
          name: t.data.name,
          avg: avg(mine.map((r) => r.stars)),
          count: mine.length,
          tags: tagCounts(mine).slice(0, 8),
          comments: mine
            .filter((r) => r.comment)
            .sort((a, b) => (a.at < b.at ? 1 : -1))
            .slice(0, 20)
            .map((r) => ({ name: r.name, stars: r.stars, comment: r.comment, at: r.at })),
        };
      })
      .sort((a, b) => (b.avg ?? 0) - (a.avg ?? 0));
    return c.json(rows);
  });

  /** Trainer: my rating (number and tags only, no names or comments). */
  app.get('/api/v1/trainer/rating', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'TRAINER');
    const mine = (await c.var.deps.store.query<TrainerRating>(P.trainerRatings(g.tenantId), [['trainerId', u.id]])).map((r) => r.data);
    return c.json({ avg: avg(mine.map((r) => r.stars)), count: mine.length, tags: tagCounts(mine).slice(0, 8) });
  });

  // ---------------- gym ----------------
  app.get('/api/v1/me/gyms/:tenantId/rating', async (c) => {
    const u = await authenticate(c);
    const tenantId = c.req.param('tenantId');
    memberOf(u, tenantId);
    return c.json((await c.var.deps.store.get<GymRating>(P.gymRating(tenantId, u.id))) ?? null);
  });

  app.put('/api/v1/me/gyms/:tenantId/rating', async (c) => {
    const u = await authenticate(c);
    const tenantId = c.req.param('tenantId');
    memberOf(u, tenantId);
    const b = body(await c.req.json().catch(() => null));
    const stars = int(b, 'stars', { min: 1, max: 5, label: 'stars' });
    const tags = (strList(b, 'tags', 8) ?? []).map((t) => t.slice(0, 40));
    const comment = optStr(b, 'comment', { max: 500 }) ?? null;
    const allowShow = b.allowShow === true;
    const out = await c.var.deps.store.tx(async (t) => {
      const [old, tenant, m] = (await t.getMany<any>([P.gymRating(tenantId, u.id), P.tenant(tenantId), P.member(tenantId, u.memberships![tenantId])])) as [GymRating | null, TenantDoc | null, MemberDoc | null];
      if (!tenant) throw notFound('Gym not found');
      const branchId = branchOf(tenant, m?.branchId);
      // A shown testimonial changes with the member's new words, or goes away if they no longer allow it.
      const shown = !!old?.shown && allowShow && !!comment;
      const r: GymRating = { userId: u.id, branchId, name: shortName(u.name), stars, tags, comment, allowShow, shown, at: nowIso() };
      t.set(P.gymRating(tenantId, u.id), r);
      // Each rating counts in the member's own branch.
      const sums = sumsOf(tenant);
      if (old) addTo(sums, branchOf(tenant, old.branchId)!, old.stars, -1);
      if (branchId) addTo(sums, branchId, stars, 1);
      const list = (tenant.testimonials ?? []).filter((x) => x.userId !== u.id);
      if (shown) list.unshift({ userId: u.id, name: r.name, stars, text: comment!, branchId, photoV: u.photoV ?? null });
      t.set(P.tenant(tenantId), { ...tenant, ratingSums: sums, testimonials: list });
      return r;
    });
    return c.json(out);
  });

  /** Owner: all gym ratings. */
  app.get('/api/v1/gym-ratings', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const rows = (await c.var.deps.store.query<GymRating>(P.gymRatings(g.tenantId)))
      .map((r) => ({ ...r.data, branchId: branchOf(g.tenant, r.data.branchId) }))
      .sort((a, b) => (a.at < b.at ? 1 : -1));
    const month = todayIST().slice(0, 7);
    const sum = (list: typeof rows) => ({ avg: avg(list.map((r) => r.stars)), count: list.length, thisMonth: list.filter((r) => r.at.slice(0, 7) === month).length, tags: tagCounts(list).slice(0, 8) });
    // One card per branch (board 93); each branch's rows are its own.
    const branches = g.tenant.branches.map((b, i) => {
      const mine = rows.filter((r) => r.branchId === b.id);
      return { id: b.id, name: i === 0 ? `${g.tenant.name}${g.tenant.branches.length > 1 ? ' (Main)' : ''}` : b.name, ...sum(mine), shown: mine.filter((r) => r.shown).length };
    });
    const withPhoto = await c.var.deps.store.getMany<UserDoc>(rows.map((r) => P.user(r.userId)));
    return c.json({ ...sum(rows), branches, rows: rows.map((r, i) => ({ ...r, photoUrl: withPhoto[i]?.photoV && !withPhoto[i]?.deleted ? `/api/v1/photos/${r.userId}?v=${withPhoto[i]!.photoV}` : null })) });
  });

  /** Owner: show / hide one rating on the dashboards (only if the member allowed it). */
  app.post('/api/v1/gym-ratings/:userId/show', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const show = body(await c.req.json().catch(() => null)).show !== false;
    const uid = c.req.param('userId');
    const out = await c.var.deps.store.tx(async (t) => {
      const [r, tenant] = (await t.getMany<any>([P.gymRating(g.tenantId, uid), P.tenant(g.tenantId)])) as [GymRating | null, TenantDoc];
      if (!r) throw notFound('Rating not found');
      if (show && (!r.allowShow || !r.comment)) throw bad('This member did not allow showing their rating');
      const list = (tenant.testimonials ?? []).filter((x) => x.userId !== uid);
      const branchId = branchOf(tenant, r.branchId);
      if (show) {
        if (list.filter((x) => branchOf(tenant, x.branchId) === branchId).length >= 12) throw bad('Up to 12 can be shown in a branch. Hide one first');
        const ru = await t.get<UserDoc>(P.user(uid));
        list.unshift({ userId: uid, name: r.name, stars: r.stars, text: r.comment!, branchId, photoV: ru?.photoV ?? null });
      }
      t.set(P.gymRating(g.tenantId, uid), { ...r, shown: show });
      t.set(P.tenant(g.tenantId), { ...tenant, testimonials: list });
      audit(t, g.tenantId, u.id, show ? 'rating.show' : 'rating.hide', 'gym_rating', uid, null, null);
      return { ok: true, shown: show };
    });
    return c.json(out);
  });

  /**
   * Anyone linked to the gym (member, trainer, staff): the rating and chosen testimonials of their own
   * branch. Owners (and staff of several branches) may ask for one of their branches with ?branchId=.
   */
  app.get('/api/v1/gyms/:tenantId/testimonials', async (c) => {
    const u = await authenticate(c);
    const tenantId = c.req.param('tenantId');
    const staff = u.staffOf?.[tenantId]?.active ? u.staffOf[tenantId] : null;
    if (!u.memberships?.[tenantId] && !staff && !u.isSuperAdmin) throw forbidden('Not your gym');
    const { store } = c.var.deps;
    const t = await store.get<TenantDoc>(P.tenant(tenantId));
    if (!t) throw notFound('Gym not found');
    const asked = c.req.query('branchId');
    let branchId: string | null = null;
    if (asked && (u.isSuperAdmin || (staff && (staff.role === 'OWNER' || !(staff.branchIds ?? []).length || staff.branchIds.includes(asked))))) branchId = asked;
    else if (staff) branchId = staff.branchIds?.[0] ?? null;
    else if (u.memberships?.[tenantId]) branchId = (await store.get<MemberDoc>(P.member(tenantId, u.memberships[tenantId])))?.branchId ?? null;
    return c.json(testimonialsFor(t, tenantId, branchId));
  });

  /**
   * Photo of someone whose rating the owner shows. Only while it is shown, and only to people of the
   * gym or to someone who typed one of its codes on the join page.
   */
  app.get('/api/v1/gyms/:tenantId/testimonials/:userId/photo', async (c) => {
    const u = await authenticate(c);
    const tenantId = c.req.param('tenantId');
    const uid = c.req.param('userId');
    const { store } = c.var.deps;
    let ok = !!u.memberships?.[tenantId] || !!u.staffOf?.[tenantId]?.active || !!u.isSuperAdmin;
    const code = (c.req.query('code') ?? '').trim().toUpperCase();
    if (!ok && code) {
      const ref = await store.get<{ tenantId: string; expiresAt?: string }>(P.gymCode(code));
      ok = !!ref && ref.tenantId === tenantId && (!ref.expiresAt || Date.parse(ref.expiresAt) > Date.now());
    }
    if (!ok) throw forbidden('Not allowed');
    const t = await store.get<TenantDoc>(P.tenant(tenantId));
    if (!t?.testimonials?.some((x) => x.userId === uid)) throw notFound('No photo');
    const p = await store.get<{ mime: string; b64: string }>(P.photo(uid));
    if (!p) throw notFound('No photo');
    const bin = atob(p.b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new Response(bytes, { headers: { 'content-type': p.mime, 'cache-control': 'private, max-age=86400' } });
  });
}
