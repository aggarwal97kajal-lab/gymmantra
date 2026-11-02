import { App, audit, authenticate, branchOf, gymOf, NoteItem, P, readRoster, stateOf, TenantDoc, UserDoc } from '../core';
import { addDays, isYmd, todayIST } from '../lib/dates';
import { bad, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { body, oneOf, optBool, str } from '../lib/validate';
import type { Reader } from '../store/store';
import { summaries } from './members';

/**
 * Gym notices ("Gym closed tomorrow", timing change …) from the owner or front desk
 * to members and/or trainers. They are not copied into every person's inbox:
 * dashboards and the notifications list read the gym's live notices, so one notice
 * costs one write however many members the gym has.
 */
export interface NoticeDoc {
  id: string;
  branchIds?: string[] | null; // null = every branch
  title: string;
  message: string;
  forMembers: boolean;
  forTrainers: boolean;
  memberFilter: 'ALL' | 'ACTIVE' | 'EXPIRED' | 'ENDING' | 'DUE';
  showTill: string; // last day it shows on dashboards
  active: boolean;
  createdById: string;
  createdByName: string;
  createdAt: string;
}

const LIVE_STATUSES = ['ACTIVE', 'ENDING_SOON', 'FROZEN', 'UPCOMING'];
const matches = (n: NoticeDoc, who: 'MEMBER' | 'TRAINER', status?: string, due = 0) => {
  if (who === 'TRAINER') return n.forTrainers;
  if (!n.forMembers) return false;
  switch (n.memberFilter) {
    case 'ACTIVE':
      return LIVE_STATUSES.includes(status ?? '');
    case 'EXPIRED':
      return !LIVE_STATUSES.includes(status ?? '');
    case 'ENDING':
      return status === 'ENDING_SOON';
    case 'DUE':
      return due > 0;
    default:
      return true;
  }
};
const FILTERS = ['ALL', 'ACTIVE', 'EXPIRED', 'ENDING', 'DUE'] as const;
/** Members a notice with this filter goes to (shown to the owner before sending). */
export function audienceOf(list: ReturnType<typeof summaries>, filter: NoticeDoc['memberFilter']) {
  return list.filter((m) => matches({ forMembers: true, forTrainers: false, memberFilter: filter } as NoticeDoc, 'MEMBER', m.status, m.due));
}
const view = (n: NoticeDoc) => ({ id: n.id, title: n.title, message: n.message, showTill: n.showTill, createdAt: n.createdAt, from: n.createdByName });

/** Notices of a gym for one person. `days` > 0 also returns ones that ended in the last N days (for the inbox). */
export async function noticesFor(r: Reader, tenantId: string, who: 'MEMBER' | 'TRAINER', status?: string, days = 0, due = 0, branchId?: string | null) {
  const today = todayIST();
  const since = addDays(today, -days);
  return (await r.query<NoticeDoc>(P.notices(tenantId), [['active', true]]))
    .map((x) => x.data)
    .filter((n) => n.showTill >= since && matches(n, who, status, due) && (!n.branchIds?.length || !branchId || n.branchIds.includes(branchId)))
    .sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1))
    .map(view);
}

/** Gym notices shown inside a person's notifications list, newest first. */
export async function noticeNotes(r: Reader, u: UserDoc, readUpTo: string | null): Promise<(NoteItem & { from?: string; kind?: string })[]> {
  const memberGyms = Object.entries(u.memberships ?? {});
  const trainerGyms = Object.entries(u.staffOf ?? {}).filter(([, s]) => s.active && s.role === 'TRAINER').map(([t]) => t);
  if (!memberGyms.length && !trainerGyms.length) return [];
  const [rosters, tenants] = await Promise.all([
    Promise.all(memberGyms.map(([t]) => readRoster(r, t))),
    r.getMany<TenantDoc>([...memberGyms.map(([t]) => t), ...trainerGyms].map(P.tenant)),
  ]);
  const lists = await Promise.all([
    ...memberGyms.map(([t, m], i) => {
      const e = rosters[i].members[m];
      const st = e ? stateOf(e) : null;
      return noticesFor(r, t, 'MEMBER', st?.status ?? 'NO_PLAN', 30, st?.due ?? 0, tenants[i] ? branchOf(tenants[i]!, e?.branchId) : null);
    }),
    ...trainerGyms.map((t, k) => {
      const tn = tenants[memberGyms.length + k];
      return noticesFor(r, t, 'TRAINER', undefined, 30, 0, tn ? branchOf(tn, u.staffOf?.[t]?.branchIds?.[0]) : null);
    }),
  ]);
  const ids = [...memberGyms.map(([t]) => t), ...trainerGyms];
  const seen = new Set<string>();
  const out: (NoteItem & { from?: string; kind?: string })[] = [];
  lists.forEach((list, i) => {
    for (const n of list) {
      if (seen.has(n.id)) continue;
      seen.add(n.id);
      out.push({
        id: `notice:${n.id}`,
        tenantId: ids[i],
        title: n.title,
        body: n.message,
        from: tenants[i]?.name ?? 'Your gym',
        kind: 'NOTICE',
        createdAt: n.createdAt,
        readAt: readUpTo && readUpTo >= n.createdAt ? readUpTo : null,
      });
    }
  });
  return out;
}

export function noticeRoutes(app: App) {
  app.get('/api/v1/notices', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const rows = (await c.var.deps.store.query<NoticeDoc>(P.notices(g.tenantId), [['active', true]])).map((x) => x.data).filter((n) => !n.branchIds?.length || n.branchIds.includes(g.branchId));
    const today = todayIST();
    return c.json(rows.map((n) => ({ ...n, live: n.showTill >= today })).sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)).slice(0, 50));
  });

  /** Who would get a members' notice with this filter (the owner sees the list before sending). */
  app.get('/api/v1/notices/audience', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const filter = (FILTERS as readonly string[]).includes(c.req.query('filter') ?? '') ? (c.req.query('filter') as NoticeDoc['memberFilter']) : 'ALL';
    const list = audienceOf(summaries(g, await readRoster(c.var.deps.store, g.tenantId)), filter);
    return c.json({
      count: list.length,
      withApp: list.filter((m) => m.hasApp).length,
      members: list
        .sort((a, b) => (a.daysLeft ?? 999) - (b.daysLeft ?? 999))
        .slice(0, 100)
        .map((m) => ({ id: m.id, name: m.name, memberCode: m.memberCode, photoUrl: m.photoUrl, hasApp: m.hasApp, daysLeft: m.daysLeft, due: m.due, status: m.status })),
    });
  });

  app.post('/api/v1/notices', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const b = body(await c.req.json().catch(() => null));
    const title = str(b, 'title', { min: 3, max: 80, label: 'the heading' });
    const message = str(b, 'message', { min: 3, max: 600, label: 'the message' });
    const forMembers = optBool(b, 'forMembers') ?? true;
    const forTrainers = optBool(b, 'forTrainers') ?? false;
    if (!forMembers && !forTrainers) throw bad('Choose who should get this notice: members, trainers or both');
    const memberFilter = oneOf(b, 'memberFilter', FILTERS, true) ?? 'ALL';
    const today = todayIST();
    const showTill = typeof b.showTill === 'string' && b.showTill ? b.showTill : addDays(today, 2);
    if (!isYmd(showTill) || showTill < today) throw bad('Choose a valid last date');
    if (showTill > addDays(today, 90)) throw bad('A notice can show for at most 90 days');
    let branchIds: string[] | null = [g.branchId];
    if (b.branchIds === 'ALL') branchIds = null;
    else if (Array.isArray(b.branchIds)) {
      const ids = (b.branchIds as unknown[]).filter((x): x is string => typeof x === 'string' && g.tenant.branches.some((br) => br.id === x));
      if (!ids.length) throw bad('Choose at least one branch');
      branchIds = ids.length === g.tenant.branches.length ? null : ids;
    }
    const n: NoticeDoc = { id: uuid(), branchIds, title, message, forMembers, forTrainers, memberFilter, showTill, active: true, createdById: u.id, createdByName: u.name, createdAt: nowIso() };
    await c.var.deps.store.tx(async (t) => {
      t.set(P.notice(g.tenantId, n.id), n);
      audit(t, g.tenantId, u.id, 'notice.create', 'notice', n.id, null, n);
    });
    return c.json(n, 201);
  });

  /** Removes a notice from dashboards and inboxes. */
  app.delete('/api/v1/notices/:id', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const id = c.req.param('id');
    await c.var.deps.store.tx(async (t) => {
      const before = isUuid(id) ? await t.get<NoticeDoc>(P.notice(g.tenantId, id)) : null;
      if (!before) throw notFound('Notice not found');
      const after = { ...before, active: false };
      t.set(P.notice(g.tenantId, id), after);
      audit(t, g.tenantId, u.id, 'notice.remove', 'notice', id, before, after);
    });
    return c.json({ ok: true });
  });
}
