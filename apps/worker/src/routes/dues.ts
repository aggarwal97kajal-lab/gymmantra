import { App, audit, authenticate, branchOf, gymOf, inBranch, MemberDoc, NoteItem, P, readRoster, stateOf, TenantDoc, UserDoc, need } from '../core';
import { diffDays, todayIST } from '../lib/dates';
import { bad, conflict, forbidden, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { validSubs } from '../lib/status';
import { body, strList } from '../lib/validate';
import { summaries, PlanDoc } from './members';
import { ownerIds } from './pt';

// ---------- Money due: list on the dashboard and one-tap reminders; plan "Interested" leads ----------

/** Members who owe money, with how much they paid of what total (all memberships that still have money due). */
export function dueList(g: Parameters<typeof summaries>[0], roster: Awaited<ReturnType<typeof readRoster>>) {
  const today = todayIST();
  return summaries(g, roster)
    .filter((m) => m.due > 0)
    .map((m) => {
      const e = roster.members[m.id];
      const owing = validSubs(e.subs).filter((s) => s.total > s.paid);
      const total = owing.reduce((n, s) => n + s.total, 0);
      const paid = owing.reduce((n, s) => n + s.paid, 0);
      const oldest = owing.map((s) => s.startDate).sort()[0] ?? today;
      return {
        id: m.id,
        name: m.name,
        memberCode: m.memberCode,
        phone: m.phone,
        photoUrl: m.photoUrl,
        hasApp: m.hasApp,
        status: m.status,
        planName: m.planName,
        due: m.due,
        paid,
        total,
        daysLate: Math.max(0, diffDays(oldest, today)),
        subs: owing.map((s) => ({ id: s.id, planName: s.planName, startDate: s.startDate, endDate: s.endDate, total: s.total, paid: s.paid, due: s.total - s.paid })),
      };
    })
    .sort((a, b) => b.daysLate - a.daysLate || b.due - a.due);
}

export interface LeadDoc {
  id: string;
  branchId?: string | null;
  userId: string;
  memberId: string | null;
  name: string;
  phone: string | null;
  photoV: number | null;
  planId: string;
  planName: string;
  status: 'OPEN' | 'DONE';
  createdAt: string;
}

export function dueRoutes(app: App) {
  app.get('/api/v1/dues', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    need(g, 'payments');
    const list = dueList(g, await readRoster(c.var.deps.store, g.tenantId));
    return c.json({ total: list.reduce((n, m) => n + m.due, 0), count: list.length, remindedAt: g.tenant.dueRemindedAt ?? null, members: list });
  });

  /** Sends an in-app reminder to every member who owes money (or the chosen ones). */
  app.post('/api/v1/dues/remind', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    need(g, 'payments');
    const b = body(await c.req.json().catch(() => null));
    const ids = strList(b, 'memberIds', 1000);
    const { store } = c.var.deps;
    const roster = await readRoster(store, g.tenantId);
    const list = dueList(g, roster).filter((m) => !ids || ids.includes(m.id));
    if (!list.length) throw bad('Nobody owes money right now');
    const targets = list.map((m) => ({ m, uid: roster.members[m.id]?.userId ?? null })).filter((x) => x.uid) as { m: (typeof list)[number]; uid: string }[];
    const at = nowIso();
    // Up to 400 people per tap: one batched read and one commit.
    const chunk = targets.slice(0, 400);
    await store.tx(async (t) => {
      const docs = await t.getMany<{ items: NoteItem[] }>(chunk.map((x) => P.notes(x.uid)));
      chunk.forEach(({ m, uid }, i) => {
        const doc = docs[i] ?? { items: [] };
        const body = `₹${m.due.toLocaleString('en-IN')} is due at ${g.tenant.name} (paid ₹${m.paid.toLocaleString('en-IN')} of ₹${m.total.toLocaleString('en-IN')}). Please pay at the front desk.`;
        const item: NoteItem & { kind?: string } = { id: uuid(), tenantId: g.tenantId, title: `Payment due: ₹${m.due.toLocaleString('en-IN')}`, body, createdAt: at, readAt: null, kind: 'DUE' };
        t.set(P.notes(uid), { ...doc, items: [item, ...(doc.items ?? [])].slice(0, 50) });
      });
      const tn = (await t.get<TenantDoc>(P.tenant(g.tenantId)))!;
      t.set(P.tenant(g.tenantId), { ...tn, dueRemindedAt: at });
      audit(t, g.tenantId, u.id, 'dues.remind', 'tenant', g.tenantId, null, { count: chunk.length });
    });
    return c.json({ sent: chunk.length, noApp: list.length - targets.length, at });
  });

  // ---- "Interested" in a plan ----
  app.post('/api/v1/me/gyms/:tenantId/plans/:planId/interest', async (c) => {
    const u = await authenticate(c);
    const tid = c.req.param('tenantId');
    const planId = c.req.param('planId');
    if (!u.memberships?.[tid] && !u.requested?.[tid]) throw forbidden('Join this gym first');
    const { store } = c.var.deps;
    const plan = isUuid(planId) ? await store.get<PlanDoc>(P.plan(tid, planId)) : null;
    if (!plan || !plan.active) throw notFound('Plan not found');
    const open = (await store.query<LeadDoc>(P.leads(tid), [['userId', u.id], ['status', 'OPEN']])).map((r) => r.data);
    if (open.some((l) => l.planId === planId)) throw conflict('You already told the gym about this plan');
    const mid = u.memberships?.[tid];
    const [mem, tn] = await Promise.all([mid ? store.get<MemberDoc>(P.member(tid, mid)) : null, store.get<TenantDoc>(P.tenant(tid))]);
    const branchId = tn ? branchOf(tn, mem?.branchId) : null;
    const lead: LeadDoc = { id: uuid(), branchId, userId: u.id, memberId: u.memberships?.[tid] ?? null, name: u.name, phone: u.phone, photoV: u.photoV, planId, planName: plan.name, status: 'OPEN', createdAt: nowIso() };
    await store.tx(async (t) => {
      t.set(P.lead(tid, lead.id), lead);
      const owners = await ownerIds(t, tid);
      const docs = await t.getMany<{ items: NoteItem[] }>(owners.map(P.notes));
      owners.forEach((oid, i) => {
        const doc = docs[i] ?? { items: [] };
        t.set(P.notes(oid), { ...doc, items: [{ id: uuid(), tenantId: tid, branchId, title: 'Interested in a plan', body: `${u.name} is interested in ${plan.name}. Open Requests → Plans.`, createdAt: lead.createdAt, readAt: null }, ...(doc.items ?? [])].slice(0, 50) });
      });
    });
    return c.json(lead, 201);
  });

  app.get('/api/v1/leads', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    need(g, 'members');
    const rows = (await c.var.deps.store.query<LeadDoc>(P.leads(g.tenantId), [['status', 'OPEN']])).map((r) => r.data).filter((l) => inBranch(g, l.branchId));
    return c.json(
      rows
        .sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1))
        .map((l) => ({ ...l, photoUrl: l.photoV ? `/api/v1/photos/${l.userId}?v=${l.photoV}` : null })),
    );
  });

  app.post('/api/v1/leads/:id/done', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    need(g, 'members');
    const id = c.req.param('id');
    await c.var.deps.store.tx(async (t) => {
      const l = isUuid(id) ? await t.get<LeadDoc>(P.lead(g.tenantId, id)) : null;
      if (!l) throw notFound('Request not found');
      t.set(P.lead(g.tenantId, id), { ...l, status: 'DONE' });
    });
    return c.json({ ok: true });
  });
}

export type { UserDoc };
