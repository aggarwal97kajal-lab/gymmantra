import { App, authenticate, C, gymOf, notify, P, requireSuper, UserDoc } from '../core';
import { bad, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { body, optStr, str } from '../lib/validate';
import type { Where } from '../store/store';

/** Topics members pick in the app. App problems go to GymMantra, the rest to the gym. */
export const TICKET_TOPICS: Record<string, 'GYM' | 'GYMMANTRA'> = {
  membership: 'GYM',
  payment: 'GYM',
  checkin: 'GYM',
  facility: 'GYM',
  trainer: 'GYM',
  other_gym: 'GYM',
  app_login: 'GYMMANTRA',
  app_bug: 'GYMMANTRA',
  app_other: 'GYMMANTRA',
};

export interface Ticket {
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
    .map((r) => ({ id: r.id, ...r.data, messages: r.data.messages.slice(-1) }))
    .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1))
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
    tx.set(P.ticket(id), { ...t, status: 'OPEN', updatedAt: msg.createdAt, messages: [...t.messages, msg].slice(-200) });
    if (fromStaff) await notify(tx, t.userId, t.tenantId, 'New reply on your ticket', t.subject);
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
    await notify(tx, t.userId, t.tenantId, 'Ticket resolved', t.subject);
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

  // GymMantra support sees only app-problem tickets.
  const superAllowed = (t: Ticket) => t.routedTo === 'GYMMANTRA';
  app.get('/api/v1/super/tickets', async (c) => {
    await authenticate(c);
    requireSuper(c);
    return c.json(await listTickets(c, [['routedTo', 'GYMMANTRA']]));
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
