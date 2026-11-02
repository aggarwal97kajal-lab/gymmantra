import { App, authenticate, C, gymOf, notify, P, requireSuper, UserDoc } from '../core';
import { bad, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { body, optStr, str } from '../lib/validate';
import type { Where } from '../store/store';

/** Topics people pick in the app. Owner decision (Nov 2026): every ticket goes to GymMantra support (super admin). */
export const TICKET_TOPICS: Record<string, 'GYM' | 'GYMMANTRA'> = {
  app_problem: 'GYMMANTRA',
  payment: 'GYMMANTRA',
  checkin: 'GYMMANTRA',
  account: 'GYMMANTRA',
  other: 'GYMMANTRA',
  // older topic names still accepted
  membership: 'GYMMANTRA',
  facility: 'GYMMANTRA',
  trainer: 'GYMMANTRA',
  other_gym: 'GYMMANTRA',
  app_login: 'GYMMANTRA',
  app_bug: 'GYMMANTRA',
  app_other: 'GYMMANTRA',
};
export const WAIT_FOR_REPLY = 'Please wait for our reply on this ticket. You can write again after GymMantra support answers.';

export interface Ticket {
  number?: string; // GM-1001, unique
  role?: string | null; // MEMBER / OWNER / TRAINER of the person who raised it
  gymName?: string | null;
  tenantId: string | null;
  memberId: string | null;
  userId: string;
  topic: string;
  subject: string;
  status: 'OPEN' | 'RESOLVED';
  routedTo: 'GYM' | 'GYMMANTRA';
  createdAt: string;
  updatedAt: string;
  messages: { id: string; authorId: string; fromStaff: boolean; body: string; attachmentUrl: string | null; createdAt: string }[];
}

export async function listTickets(c: C, where: Where) {
  const status = c.req.query('status');
  const w: Where = status === 'OPEN' || status === 'RESOLVED' ? [...where, ['status', status]] : where;
  const rows = await c.var.deps.store.query<Ticket>(P.tickets, w);
  return rows
    .map((r) => ({ id: r.id, ...r.data, waiting: !r.data.messages[r.data.messages.length - 1]?.fromStaff, messages: r.data.messages.slice(-1) }))
    // Tickets waiting for a reply first, then newest.
    .sort((a, b) => (a.waiting !== b.waiting ? (a.waiting ? -1 : 1) : a.updatedAt < b.updatedAt ? 1 : -1))
    .slice(0, 200);
}

export async function getTicket(c: C, id: string, allowed: (t: Ticket) => boolean) {
  const { store } = c.var.deps;
  const t = isUuid(id) ? await store.get<Ticket>(P.ticket(id)) : null;
  if (!t || !allowed(t)) throw notFound('Ticket not found');
  const ids = [...new Set([t.userId, ...t.messages.map((m) => m.authorId)])];
  const users = await store.getMany<UserDoc>(ids.map(P.user));
  const member = t.tenantId && t.memberId ? await store.get<any>(P.member(t.tenantId, t.memberId)) : null;
  return {
    id,
    ...t,
    waiting: !t.messages[t.messages.length - 1]?.fromStaff,
    member: member ? { id: member.id, name: member.name, memberCode: member.memberCode, phone: member.phone } : null,
    authors: ids.map((uid, i) => ({ id: uid, name: users[i]?.name ?? 'User' })),
  };
}

export async function replyTicket(c: C, id: string, allowed: (t: Ticket) => boolean, fromStaff: boolean) {
  const b = body(await c.req.json().catch(() => null));
  const text = str(b, 'body', { max: 4000, label: 'a message' });
  const attachmentUrl = optStr(b, 'attachmentUrl', { max: 500 }) ?? null;
  const msg = { id: uuid(), authorId: c.var.user.id, fromStaff, body: text, attachmentUrl, createdAt: nowIso() };
  await c.var.deps.store.tx(async (tx) => {
    const t = isUuid(id) ? await tx.get<Ticket>(P.ticket(id)) : null;
    if (!t || !allowed(t)) throw notFound('Ticket not found');
    // The person waits for support's answer before writing again on the same ticket.
    if (!fromStaff && !t.messages[t.messages.length - 1]?.fromStaff) throw bad(WAIT_FOR_REPLY);
    tx.set(P.ticket(id), { ...t, status: 'OPEN', updatedAt: msg.createdAt, messages: [...t.messages, msg].slice(-200) });
    if (fromStaff) await notify(tx, t.userId, t.tenantId, `Reply on ticket ${t.number ?? ''}`.trim(), t.subject);
  });
  return msg;
}

export async function resolveTicket(c: C, id: string, allowed: (t: Ticket) => boolean) {
  return c.var.deps.store.tx(async (tx) => {
    const t = isUuid(id) ? await tx.get<Ticket>(P.ticket(id)) : null;
    if (!t || !allowed(t)) throw notFound('Ticket not found');
    if (t.status === 'RESOLVED') throw bad('Already resolved');
    const next = { ...t, status: 'RESOLVED' as const, updatedAt: nowIso() };
    tx.set(P.ticket(id), next);
    await notify(tx, t.userId, t.tenantId, `Ticket ${t.number ?? ''} closed`.replace('  ', ' '), t.subject);
    return { id, ...next };
  });
}

export function ticketRoutes(app: App) {
  // Gym staff see only tickets from their own gym's members about gym topics.
  const gymAllowed = (tenantId: string) => (t: Ticket) => t.tenantId === tenantId && t.routedTo === 'GYM';
  app.get('/api/v1/tickets', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    return c.json(await listTickets(c, [['tenantId', g.tenantId], ['routedTo', 'GYM']]));
  });
  app.get('/api/v1/tickets/:id', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    return c.json(await getTicket(c, c.req.param('id'), gymAllowed(g.tenantId)));
  });
  app.post('/api/v1/tickets/:id/messages', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    return c.json(await replyTicket(c, c.req.param('id'), gymAllowed(g.tenantId), true), 201);
  });
  app.post('/api/v1/tickets/:id/resolve', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    return c.json(await resolveTicket(c, c.req.param('id'), gymAllowed(g.tenantId)), 201);
  });

  // GymMantra support (super admin) sees and answers every ticket.
  const superAllowed = (_t: Ticket) => true;
  app.get('/api/v1/super/tickets', async (c) => {
    await authenticate(c);
    requireSuper(c);
    return c.json(await listTickets(c, []));
  });
  app.get('/api/v1/super/tickets/:id', async (c) => {
    await authenticate(c);
    requireSuper(c);
    return c.json(await getTicket(c, c.req.param('id'), superAllowed));
  });
  app.post('/api/v1/super/tickets/:id/messages', async (c) => {
    await authenticate(c);
    requireSuper(c);
    return c.json(await replyTicket(c, c.req.param('id'), superAllowed, true), 201);
  });
  app.post('/api/v1/super/tickets/:id/resolve', async (c) => {
    await authenticate(c);
    requireSuper(c);
    return c.json(await resolveTicket(c, c.req.param('id'), superAllowed), 201);
  });
}
