import { App, audit, authenticate, P, requireSuper } from '../core';
import { bad, notFound, nowIso, uuid } from '../lib/http';
import { body, oneOf, optBool, optStr, str, strList } from '../lib/validate';

/**
 * Festival looks (GM Admin → Festivals): on the chosen days the apps show the festival's opening
 * animation (instead of the normal splash), its sound, a Home banner, festival tab icons and tap
 * sparkles. The animations live in the app; the super admin only picks which, when, for whom.
 * No app update is needed for a new year's festivals.
 */
export const FESTIVAL_KINDS = [
  'diwali', 'holi', 'christmas', 'newyear', 'eid', 'rakhi', 'janmashtami', 'ganesh', 'navratri', 'durga',
  'dussehra', 'sankranti', 'republic', 'onam', 'gurpurab', 'baisakhi', 'chhath', 'shivratri',
] as const;
const ROLES = ['MEMBER', 'TRAINER', 'STAFF', 'OWNER'] as const;

export interface Festival {
  id: string;
  kind: (typeof FESTIVAL_KINDS)[number];
  title: string; // banner heading, e.g. "Happy Diwali!"
  sub: string; // banner line
  from: string; // ISO time it starts
  to: string; // ISO time it ends
  roles: string[]; // empty = everyone
  states: string[]; // empty = all of India
  sound: boolean;
  every: boolean; // opening animation every time the app opens (else once a day)
  active: boolean;
  updatedAt: string;
}

export function festivalRoutes(app: App) {
  /** For the apps (also before log-in): what is on now or in the next 2 weeks. */
  app.get('/api/v1/festivals', async (c) => {
    const d = await c.var.deps.store.get<{ items: Festival[] }>(P.festivals);
    const now = nowIso();
    const soon = new Date(Date.now() + 14 * 86400_000).toISOString();
    const items = (d?.items ?? []).filter((f) => f.active && f.to > now && f.from < soon);
    c.header('cache-control', 'public, max-age=300');
    return c.json(items.map(({ updatedAt, ...f }) => f));
  });

  app.get('/api/v1/super/festivals', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const d = await c.var.deps.store.get<{ items: Festival[] }>(P.festivals);
    return c.json((d?.items ?? []).sort((a, b) => (a.from < b.from ? -1 : 1)));
  });

  app.put('/api/v1/super/festivals/:id', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const b = body(await c.req.json().catch(() => null));
    const id = c.req.param('id') === 'new' ? uuid() : c.req.param('id');
    const from = str(b, 'from', { max: 40, label: 'the start' });
    const to = str(b, 'to', { max: 40, label: 'the end' });
    if (Number.isNaN(Date.parse(from)) || Number.isNaN(Date.parse(to))) throw bad('Choose the start and end');
    if (Date.parse(to) <= Date.parse(from)) throw bad('The end must be after the start');
    if (Date.parse(to) - Date.parse(from) > 31 * 86400_000) throw bad('A festival look can run for 31 days at most');
    const f: Festival = {
      id,
      kind: oneOf(b, 'kind', FESTIVAL_KINDS)!,
      title: str(b, 'title', { min: 2, max: 60, label: 'the heading' }),
      sub: optStr(b, 'sub', { max: 100 }) ?? '',
      from: new Date(from).toISOString(),
      to: new Date(to).toISOString(),
      roles: (strList(b, 'roles', 4) ?? []).filter((r) => (ROLES as readonly string[]).includes(r)),
      states: (strList(b, 'states', 40) ?? []).map((s) => s.slice(0, 60)),
      sound: optBool(b, 'sound') ?? true,
      every: optBool(b, 'every') ?? false,
      active: optBool(b, 'active') ?? true,
      updatedAt: nowIso(),
    };
    await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<{ items: Festival[] }>(P.festivals)) ?? { items: [] };
      const old = cur.items.find((x) => x.id === id) ?? null;
      if (!old && c.req.param('id') !== 'new') throw notFound('Not found');
      t.set(P.festivals, { items: [f, ...cur.items.filter((x) => x.id !== id)].slice(0, 60) });
      audit(t, null, u.id, old ? 'festival.update' : 'festival.create', 'festival', id, old, f);
    });
    return c.json(f);
  });

  app.delete('/api/v1/super/festivals/:id', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<{ items: Festival[] }>(P.festivals)) ?? { items: [] };
      t.set(P.festivals, { items: cur.items.filter((x) => x.id !== id) });
      audit(t, null, u.id, 'festival.delete', 'festival', id);
    });
    return c.json({ ok: true });
  });
}
