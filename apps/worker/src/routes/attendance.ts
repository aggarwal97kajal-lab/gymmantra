import { App, authenticate, bumpDaily, C, gymOf, MemberDoc, P, readRoster, rosterEntry, stateOf } from '../core';
import { todayIST } from '../lib/dates';
import { bad, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { verifyQrToken } from '../lib/qr';
import { entryDecision } from '../lib/status';
import { body, optStr, str } from '../lib/validate';

const DUPLICATE_WINDOW_MS = 2 * 60_000;

/** Per-member check-in log: last scan, recent visits and this month's count, in one document. */
export interface ScanLog {
  lastAllowedAt: string | null;
  lastResult: string | null;
  month: string;
  visits: number;
  recent: { id: string; at: string; result: string; reason: string | null }[];
}

async function checkIn(c: C, memberId: string, method: 'QR' | 'MANUAL', branchIdIn?: string) {
  const u = c.var.user;
  const g = await gymOf(c);
  if (branchIdIn && !g.tenant.branches.some((b) => b.id === branchIdIn)) throw bad('Unknown branch');
  const today = todayIST();
  return c.var.deps.store.tx(async (t) => {
    const m = isUuid(memberId) ? await t.get<MemberDoc>(P.member(g.tenantId, memberId)) : null;
    // A QR from another gym (or another branch for front desk) is not accepted here.
    if (!m || (g.role === 'FRONT_DESK' && g.branchIds.length && m.branchId && !g.branchIds.includes(m.branchId))) throw notFound('This member is not part of your gym');
    const roster = await readRoster(t, g.tenantId);
    const st = stateOf(roster.members[m.id] ?? rosterEntry(m), today);
    const decision = entryDecision(st);
    const view = {
      member: { id: m.id, name: m.name, memberCode: m.memberCode, phone: m.phone },
      status: st.status,
      planName: st.current?.planName ?? null,
      endsOn: st.endsOn,
      daysLeft: st.daysLeft,
      due: st.due,
    };
    const month = today.slice(0, 7);
    const log = (await t.get<ScanLog>(P.lastScan(g.tenantId, m.id))) ?? { lastAllowedAt: null, lastResult: null, month, visits: 0, recent: [] };
    if (decision.result !== 'BLOCKED' && log.lastAllowedAt && Date.now() - new Date(log.lastAllowedAt).getTime() < DUPLICATE_WINDOW_MS) {
      return { ...view, result: log.lastResult, reason: 'Already checked in', duplicate: true, eventId: log.recent[0]?.id ?? null };
    }
    const id = uuid();
    const at = nowIso();
    const ev = { memberId: m.id, memberName: m.name, memberCode: m.memberCode, branchId: branchIdIn ?? m.branchId, day: today, at, result: decision.result, reason: decision.reason, method, scannedById: u.id };
    t.set(P.attendanceEv(g.tenantId, id), ev);
    const allowed = decision.result !== 'BLOCKED';
    t.set(P.lastScan(g.tenantId, m.id), {
      lastAllowedAt: allowed ? at : log.lastAllowedAt,
      lastResult: allowed ? decision.result : log.lastResult,
      month,
      visits: (log.month === month ? log.visits : 0) + (allowed ? 1 : 0),
      recent: [{ id, at, result: decision.result, reason: decision.reason }, ...log.recent].slice(0, 30),
    });
    await bumpDaily(t, g.tenantId, allowed ? { checkins: 1 } : { blocked: 1 });
    return { ...view, result: decision.result, reason: decision.reason, duplicate: false, eventId: id };
  });
}

export function attendanceRoutes(app: App) {
  app.post('/api/v1/attendance/scan', async (c) => {
    await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const memberId = await verifyQrToken(c.var.secrets.qr, str(b, 'token', { max: 200 }));
    if (!memberId) throw bad('QR code expired or not valid. Ask the member to refresh it');
    return c.json(await checkIn(c, memberId, 'QR', optStr(b, 'branchId')), 201);
  });

  app.post('/api/v1/attendance/manual', async (c) => {
    await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    return c.json(await checkIn(c, str(b, 'memberId'), 'MANUAL', optStr(b, 'branchId')), 201);
  });

  app.get('/api/v1/attendance/today', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const rows = await c.var.deps.store.query<{ memberId: string; memberName: string; memberCode: string; at: string; result: string; reason: string | null; method: string }>(P.attendance(g.tenantId), [['day', todayIST()]]);
    const events = rows
      .map((r) => ({ id: r.id, scannedAt: r.data.at, result: r.data.result, reason: r.data.reason, method: r.data.method, memberId: r.data.memberId, member: { id: r.data.memberId, name: r.data.memberName, memberCode: r.data.memberCode } }))
      .sort((a, b) => (a.scannedAt < b.scannedAt ? 1 : -1));
    const twoHoursAgo = Date.now() - 2 * 3600_000;
    return c.json({
      checkins: events.filter((e) => e.result !== 'BLOCKED').length,
      inGymNow: new Set(events.filter((e) => e.result !== 'BLOCKED' && new Date(e.scannedAt).getTime() > twoHoursAgo).map((e) => e.memberId)).size,
      blocked: events.filter((e) => e.result === 'BLOCKED').length,
      events,
    });
  });
}
