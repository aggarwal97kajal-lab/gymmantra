import { App, authenticate, C, gymOf, notify, P, requireSuper, UserDoc } from '../core';
import { bad, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { body, oneOf, optStr, str } from '../lib/validate';
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
  status: TicketStatus;
  resolvedAt?: string | null;
  routedTo: 'GYM' | 'GYMMANTRA';
  createdAt: string;
  updatedAt: string;
  messages: { id: string; authorId: string; fromStaff: boolean; body: string; attachmentUrl: string | null; createdAt: string }[];
}

/**
 * Ticket status (owner decision, Nov 2026):
 *  OPEN        new, or the person wrote again — support has to act
 *  IN_PROGRESS support is working on it (set by the super admin)
 *  WAITING     support answered; the person's turn (set by a support reply)
 *  RESOLVED    fixed; the person can still reply for 7 days, which opens it again
 *  CLOSED      finished; no more messages (7 days after RESOLVED, or set by the super admin)
 */
export type TicketStatus = 'OPEN' | 'IN_PROGRESS' | 'WAITING' | 'RESOLVED' | 'CLOSED';
export const TICKET_STATUSES: TicketStatus[] = ['OPEN', 'IN_PROGRESS', 'WAITING', 'RESOLVED', 'CLOSED'];
export const REOPEN_DAYS = 7;
const DAY = 86_400_000;

export function ticketStatus(t: Ticket): TicketStatus {
  if (t.status === 'RESOLVED') {
    const at = Date.parse(t.resolvedAt ?? t.updatedAt);
    return Number.isFinite(at) && Date.now() - at > REOPEN_DAYS * DAY ? 'CLOSED' : 'RESOLVED';
  }
  // Older tickets: "OPEN" with support's message last means the person's turn.
  if (t.status === 'OPEN' && t.messages[t.messages.length - 1]?.fromStaff) return 'WAITING';
  return t.status;
}

/** What the apps need: status, whether the person must wait for support, and whether they can write. */
export function ticketFlags(t: Ticket) {
  const status = ticketStatus(t);
  return {
    status,
    waiting: status === 'OPEN' || status === 'IN_PROGRESS',
    canReply: status === 'WAITING' || status === 'RESOLVED',
    reopenUntil: status === 'RESOLVED' ? new Date(Date.parse(t.resolvedAt ?? t.updatedAt) + REOPEN_DAYS * DAY).toISOString() : null,
  };
}

const ORDER: Record<TicketStatus, number> = { OPEN: 0, IN_PROGRESS: 1, WAITING: 2, RESOLVED: 3, CLOSED: 4 };

export async function listTickets(c: C, where: Where) {
  const want = c.req.query('status');
  const rows = await c.var.deps.store.query<Ticket>(P.tickets, where);
  return rows
    .map((r) => ({ id: r.id, ...r.data, ...ticketFlags(r.data), messages: r.data.messages.slice(-1) }))
    .filter((t) => !want || t.status === want)
    // Open first (oldest first, so nobody waits too long), then in progress, waiting, resolved, closed.
    .sort((a, b) => (a.status !== b.status ? ORDER[a.status] - ORDER[b.status] : a.status === 'OPEN' ? (a.updatedAt < b.updatedAt ? -1 : 1) : a.updatedAt < b.updatedAt ? 1 : -1))
    .slice(0, 300);
}

const STATUS_NOTE: Partial<Record<TicketStatus, (n: string) => [string, string]>> = {
  IN_PROGRESS: (n) => [`Ticket ${n} is in progress`, 'Our team is working on it.'],
  WAITING: (n) => [`Ticket ${n}: we need your reply`, 'Open the ticket and answer our question.'],
  RESOLVED: (n) => [`Ticket ${n} is resolved`, `Still not fixed? Reply within ${REOPEN_DAYS} days to open it again.`],
  CLOSED: (n) => [`Ticket ${n} is closed`, 'Raise a new ticket if you need more help.'],
};

/** Super admin changes a ticket's status. The person gets a notification. */
export async function setTicketStatus(c: C, id: string, status: TicketStatus) {
  return c.var.deps.store.tx(async (tx) => {
    const t = isUuid(id) ? await tx.get<Ticket>(P.ticket(id)) : null;
    if (!t) throw notFound('Ticket not found');
    const now = nowIso();
    const next: Ticket = { ...t, status, resolvedAt: status === 'RESOLVED' ? now : status === 'CLOSED' ? t.resolvedAt ?? null : null, updatedAt: now };
    tx.set(P.ticket(id), next);
    const note = ticketStatus(t) !== status ? STATUS_NOTE[status]?.(t.number ?? '') : undefined;
    if (note) await notify(tx, t.userId, t.tenantId, note[0], `${t.subject} · ${note[1]}`);
    return { id, ...next, ...ticketFlags(next) };
  });
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
    ...ticketFlags(t),
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
    const now = ticketStatus(t);
    if (!fromStaff) {
      if (now === 'CLOSED') throw bad('This ticket is closed. Raise a new ticket if you need more help.');
      // The person waits for support's answer before writing again on the same ticket.
      if (now === 'OPEN' || now === 'IN_PROGRESS') throw bad(WAIT_FOR_REPLY);
    }
    // Support's answer → the person's turn. The person's answer → open again for support.
    tx.set(P.ticket(id), { ...t, status: fromStaff ? 'WAITING' : 'OPEN', resolvedAt: null, updatedAt: msg.createdAt, messages: [...t.messages, msg].slice(-200) });
    if (fromStaff) await notify(tx, t.userId, t.tenantId, `Reply on ticket ${t.number ?? ''}`.trim(), t.subject);
  });
  return msg;
}

export async function resolveTicket(c: C, id: string, allowed: (t: Ticket) => boolean) {
  const t = isUuid(id) ? await c.var.deps.store.get<Ticket>(P.ticket(id)) : null;
  if (!t || !allowed(t)) throw notFound('Ticket not found');
  if (ticketStatus(t) === 'RESOLVED' || ticketStatus(t) === 'CLOSED') throw bad('Already resolved');
  return setTicketStatus(c, id, 'RESOLVED');
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
  app.patch('/api/v1/super/tickets/:id', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const b = body(await c.req.json().catch(() => null));
    const status = oneOf(b, 'status', TICKET_STATUSES)!;
    return c.json(await setTicketStatus(c, c.req.param('id'), status));
  });
  app.post('/api/v1/super/tickets/:id/resolve', async (c) => {
    await authenticate(c);
    requireSuper(c);
    return c.json(await resolveTicket(c, c.req.param('id'), superAllowed), 201);
  });
}
