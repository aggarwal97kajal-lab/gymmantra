import { App, audit, authenticate, C, gymOf, need, P } from '../core';
import type { Tx } from '../store/store';
import { todayIST } from '../lib/dates';
import { bad, notFound, nowIso, uuid } from '../lib/http';
import { normalizePhone } from '../lib/phone';
import { schedule } from '../lib/scheduled';
import { body, oneOf, optStr, str, strList } from '../lib/validate';

/**
 * Enquiry follow-up (board 89): people who came to ask but did not join yet. Each has the next
 * follow-up (day + time), how keen they are, and a log of calls / WhatsApp / visits. "Joined"
 * links the member made from it. 9 AM: owner and staff with the "enquiries" right get today's list.
 */
export interface EnquiryLog {
  at: string;
  kind: 'NOTE' | 'CALL' | 'WHATSAPP' | 'VISIT' | 'TRIAL';
  text: string | null;
  byId: string;
  byName: string;
}
export interface EnquiryDoc {
  id: string;
  branchId: string | null;
  name: string;
  phone: string;
  interests: string[];
  source: string | null;
  temp: 'HOT' | 'WARM' | 'COLD';
  next: string | null; // "YYYY-MM-DDTHH:mm" (India time)
  note: string | null;
  status: 'OPEN' | 'JOINED' | 'LOST';
  memberId: string | null;
  month: string; // month it came in (for "this month")
  log: EnquiryLog[];
  createdAt: string;
  byId: string;
}

const TEMPS = ['HOT', 'WARM', 'COLD'] as const;
const KINDS = ['NOTE', 'CALL', 'WHATSAPP', 'VISIT', 'TRIAL'] as const;

function readNext(b: Record<string, unknown>): string | null | undefined {
  if (!('next' in b)) return undefined;
  if (b.next === null || b.next === '') return null;
  if (typeof b.next !== 'string' || !/^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$/.test(b.next)) throw bad('Choose when to follow up');
  return b.next.length === 10 ? `${b.next}T10:00` : b.next;
}

/** A 9 AM reminder for the day of the next follow-up (one per branch per day). */
function remind(t: Tx, tenantId: string, branchId: string | null, next: string | null) {
  if (!next) return;
  const day = next.slice(0, 10);
  if (day < todayIST()) return;
  schedule(t, { id: `enq_${day}_${tenantId}_${branchId ?? 'main'}`, day, hour: 9, tenantId, kind: 'enquiries', branchId, ref: '' });
}

/** How many open enquiries of a branch are due today or earlier (for the 9 AM reminder). */
export async function dueToday(t: Tx, tenantId: string, branchId: string | null, today: string) {
  const open = await t.query<EnquiryDoc>(P.enquiries(tenantId), [['status', 'OPEN']]);
  return open.filter((r) => (r.data.branchId ?? null) === branchId && r.data.next && r.data.next.slice(0, 10) <= today).length;
}

export function enquiryRoutes(app: App) {
  const ctx = async (c: C) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER', 'FRONT_DESK');
    need(g, 'enquiries');
    return { u, g };
  };

  app.get('/api/v1/enquiries', async (c) => {
    const { g } = await ctx(c);
    const { store } = c.var.deps;
    const view = c.req.query('view') ?? 'today';
    const today = todayIST();
    const month = today.slice(0, 7);
    const [open, thisMonth] = await Promise.all([store.query<EnquiryDoc>(P.enquiries(g.tenantId), [['status', 'OPEN']]), store.query<EnquiryDoc>(P.enquiries(g.tenantId), [['month', month]])]);
    const mine = (x: EnquiryDoc) => (x.branchId ?? null) === (g.branchId ?? null);
    const list = open.map((r) => r.data).filter(mine);
    const dayOf = (x: EnquiryDoc) => x.next?.slice(0, 10) ?? '9999';
    const groups = {
      today: list.filter((x) => dayOf(x) === today),
      missed: list.filter((x) => dayOf(x) < today),
      upcoming: list.filter((x) => dayOf(x) > today),
    };
    let rows: EnquiryDoc[];
    if (view === 'all') rows = [...(await store.query<EnquiryDoc>(P.enquiries(g.tenantId))).map((r) => r.data).filter(mine)].sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)).slice(0, 300);
    else rows = (groups[view as keyof typeof groups] ?? groups.today).sort((a, b) => ((a.next ?? '') < (b.next ?? '') ? -1 : 1));
    const came = thisMonth.map((r) => r.data).filter(mine);
    return c.json({
      view,
      counts: { today: groups.today.length, missed: groups.missed.length, upcoming: groups.upcoming.length },
      month: { total: came.length, joined: came.filter((x) => x.status === 'JOINED').length },
      rows,
    });
  });

  app.get('/api/v1/enquiries/:id', async (c) => {
    const { g } = await ctx(c);
    const e = await c.var.deps.store.get<EnquiryDoc>(P.enquiry(g.tenantId, c.req.param('id')));
    if (!e) throw notFound('Enquiry not found');
    return c.json(e);
  });

  app.post('/api/v1/enquiries', async (c) => {
    const { u, g } = await ctx(c);
    const b = body(await c.req.json().catch(() => null));
    const name = str(b, 'name', { max: 80, label: 'the name' });
    const phone = normalizePhone(str(b, 'phone', { label: 'the mobile number' }));
    if (!phone) throw bad('Enter a valid 10-digit mobile number');
    const next = readNext(b) ?? null;
    const at = nowIso();
    const e: EnquiryDoc = {
      id: uuid(),
      branchId: g.branchId ?? null,
      name,
      phone,
      interests: strList(b, 'interests', 10) ?? [],
      source: optStr(b, 'source', { max: 40 }) ?? null,
      temp: oneOf(b, 'temp', TEMPS, true) ?? 'WARM',
      next,
      note: optStr(b, 'note', { max: 500 }) ?? null,
      status: 'OPEN',
      memberId: null,
      month: todayIST().slice(0, 7),
      log: [{ at, kind: 'VISIT', text: null, byId: u.id, byName: u.name }],
      createdAt: at,
      byId: u.id,
    };
    await c.var.deps.store.tx(async (t) => {
      t.set(P.enquiry(g.tenantId, e.id), e);
      remind(t, g.tenantId, e.branchId, next);
      audit(t, g.tenantId, u.id, 'enquiry.create', 'enquiry', e.id, null, e);
    });
    return c.json(e, 201);
  });

  app.patch('/api/v1/enquiries/:id', async (c) => {
    const { u, g } = await ctx(c);
    const b = body(await c.req.json().catch(() => null));
    const id = c.req.param('id');
    const out = await c.var.deps.store.tx(async (t) => {
      const e = await t.get<EnquiryDoc>(P.enquiry(g.tenantId, id));
      if (!e) throw notFound('Enquiry not found');
      const next = readNext(b);
      const phoneIn = optStr(b, 'phone');
      const phone = phoneIn === undefined ? e.phone : normalizePhone(phoneIn);
      if (!phone) throw bad('Enter a valid 10-digit mobile number');
      const n: EnquiryDoc = {
        ...e,
        name: optStr(b, 'name', { max: 80 }) || e.name,
        phone,
        interests: strList(b, 'interests', 10) ?? e.interests,
        source: 'source' in b ? (optStr(b, 'source', { max: 40 }) ?? null) : e.source,
        temp: oneOf(b, 'temp', TEMPS, true) ?? e.temp,
        next: next === undefined ? e.next : next,
        note: 'note' in b ? (optStr(b, 'note', { max: 500 }) ?? null) : e.note,
        status: b.status === 'LOST' ? 'LOST' : b.status === 'OPEN' ? 'OPEN' : e.status,
      };
      t.set(P.enquiry(g.tenantId, id), n);
      if (n.next !== e.next) remind(t, g.tenantId, n.branchId, n.next);
      audit(t, g.tenantId, u.id, 'enquiry.update', 'enquiry', id, e, n);
      return n;
    });
    return c.json(out);
  });

  /** A call / WhatsApp / visit / trial / note, and (optionally) the next follow-up. */
  app.post('/api/v1/enquiries/:id/log', async (c) => {
    const { u, g } = await ctx(c);
    const b = body(await c.req.json().catch(() => null));
    const id = c.req.param('id');
    const kind = oneOf(b, 'kind', KINDS)!;
    const text = optStr(b, 'text', { max: 500 }) ?? null;
    const next = readNext(b);
    const out = await c.var.deps.store.tx(async (t) => {
      const e = await t.get<EnquiryDoc>(P.enquiry(g.tenantId, id));
      if (!e) throw notFound('Enquiry not found');
      const n: EnquiryDoc = { ...e, next: next === undefined ? e.next : next, log: [{ at: nowIso(), kind, text, byId: u.id, byName: u.name }, ...e.log].slice(0, 100) };
      t.set(P.enquiry(g.tenantId, id), n);
      if (n.next !== e.next) remind(t, g.tenantId, n.branchId, n.next);
      return n;
    });
    return c.json(out);
  });

  /** The person joined: link the member made from this enquiry. */
  app.post('/api/v1/enquiries/:id/joined', async (c) => {
    const { u, g } = await ctx(c);
    const b = body(await c.req.json().catch(() => null));
    const memberId = str(b, 'memberId', { label: 'the member' });
    const id = c.req.param('id');
    const out = await c.var.deps.store.tx(async (t) => {
      const [e, m] = await t.getMany<any>([P.enquiry(g.tenantId, id), P.member(g.tenantId, memberId)]);
      if (!e) throw notFound('Enquiry not found');
      if (!m) throw notFound('Member not found');
      const n: EnquiryDoc = { ...e, status: 'JOINED', memberId, next: null, log: [{ at: nowIso(), kind: 'NOTE', text: 'Joined', byId: u.id, byName: u.name }, ...e.log] };
      t.set(P.enquiry(g.tenantId, id), n);
      audit(t, g.tenantId, u.id, 'enquiry.joined', 'enquiry', id, e, n);
      return n;
    });
    return c.json(out);
  });
}
