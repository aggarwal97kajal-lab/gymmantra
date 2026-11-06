import { App, audit, authenticate, gymOf, P, TenantDoc, UserDoc } from '../core';
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
      const [old, tenant] = (await t.getMany<any>([P.gymRating(tenantId, u.id), P.tenant(tenantId)])) as [GymRating | null, TenantDoc | null];
      if (!tenant) throw notFound('Gym not found');
      // A shown testimonial changes with the member's new words, or goes away if they no longer allow it.
      const shown = !!old?.shown && allowShow && !!comment;
      const r: GymRating = { userId: u.id, name: shortName(u.name), stars, tags, comment, allowShow, shown, at: nowIso() };
      t.set(P.gymRating(tenantId, u.id), r);
      const sum = tenant.ratingSum ?? { total: 0, count: 0 };
      const next = { total: sum.total - (old?.stars ?? 0) + stars, count: sum.count + (old ? 0 : 1) };
      const list = (tenant.testimonials ?? []).filter((x) => x.userId !== u.id);
      if (shown) list.unshift({ userId: u.id, name: r.name, stars, text: comment! });
      t.set(P.tenant(tenantId), { ...tenant, ratingSum: next, testimonials: list });
      return r;
    });
    return c.json(out);
  });

  /** Owner: all gym ratings. */
  app.get('/api/v1/gym-ratings', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const rows = (await c.var.deps.store.query<GymRating>(P.gymRatings(g.tenantId))).map((r) => r.data).sort((a, b) => (a.at < b.at ? 1 : -1));
    const month = todayIST().slice(0, 7);
    return c.json({ avg: avg(rows.map((r) => r.stars)), count: rows.length, thisMonth: rows.filter((r) => r.at.slice(0, 7) === month).length, tags: tagCounts(rows).slice(0, 8), rows });
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
      if (show) {
        if (list.length >= 12) throw bad('Up to 12 can be shown. Hide one first');
        list.unshift({ userId: uid, name: r.name, stars: r.stars, text: r.comment! });
      }
      t.set(P.gymRating(g.tenantId, uid), { ...r, shown: show });
      t.set(P.tenant(g.tenantId), { ...tenant, testimonials: list });
      audit(t, g.tenantId, u.id, show ? 'rating.show' : 'rating.hide', 'gym_rating', uid, null, null);
      return { ok: true, shown: show };
    });
    return c.json(out);
  });

  /** Anyone linked to the gym (member, trainer, staff): the gym's rating and the chosen testimonials. */
  app.get('/api/v1/gyms/:tenantId/testimonials', async (c) => {
    const u = await authenticate(c);
    const tenantId = c.req.param('tenantId');
    if (!u.memberships?.[tenantId] && !u.staffOf?.[tenantId]?.active && !u.isSuperAdmin) throw forbidden('Not your gym');
    const t = await c.var.deps.store.get<TenantDoc>(P.tenant(tenantId));
    if (!t) throw notFound('Gym not found');
    const s = t.ratingSum;
    return c.json({ avg: s?.count ? Math.round((s.total / s.count) * 10) / 10 : null, count: s?.count ?? 0, items: (t.testimonials ?? []).map(({ name, stars, text }) => ({ name, stars, text })) });
  });
}
