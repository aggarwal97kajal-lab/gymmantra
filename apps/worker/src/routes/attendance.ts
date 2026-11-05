import { openGate } from './gate';
import { App, authenticate, branchOf, bumpDaily, C, gymOf, inBranch, MemberDoc, TenantDoc, P, readRoster, rosterEntry, stateOf, need, UserDoc } from '../core';
import type { Tx } from '../store/store';
import { addDays, diffDays, todayIST } from '../lib/dates';
import { bad, forbidden, isUuid, notFound, nowIso, uuid } from '../lib/http';
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

/**
 * Records one check-in for a member inside a transaction. `oncePerDay` (self check-in with the
 * gym QR) counts only the first allowed visit of the day; the front desk keeps the 2-minute rule.
 */
export async function recordMemberCheckIn(
  t: Tx,
  tenantId: string,
  m: MemberDoc,
  opts: { method: 'QR' | 'MANUAL' | 'SELF'; byId: string; branchId?: string | null; oncePerDay?: boolean },
) {
  const today = todayIST();
  const roster = await readRoster(t, tenantId);
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
  const log = (await t.get<ScanLog>(P.lastScan(tenantId, m.id))) ?? { lastAllowedAt: null, lastResult: null, month, visits: 0, recent: [] };
  const visitsNow = log.month === month ? log.visits : 0;
  // Every check-in is kept (so the day's history shows each one); only a repeat scan within 2 minutes is ignored.
  // oncePerDay: the month's visit count goes up once a day, however many times the member comes in.
  const sameDay = !!log.lastAllowedAt && todayIST(new Date(log.lastAllowedAt)) === today;
  if (decision.result !== 'BLOCKED' && log.lastAllowedAt) {
    const recent = Date.now() - new Date(log.lastAllowedAt).getTime() < DUPLICATE_WINDOW_MS;
    if (recent) {
      return { ...view, result: log.lastResult, reason: 'Already checked in today', duplicate: true, eventId: log.recent[0]?.id ?? null, visitsThisMonth: visitsNow, at: log.lastAllowedAt };
    }
  }
  const id = uuid();
  const at = nowIso();
  const tn = await t.get<TenantDoc>(P.tenant(tenantId));
  const branchId = tn ? branchOf(tn, opts.branchId ?? m.branchId) : opts.branchId ?? m.branchId;
  const ev = { memberId: m.id, memberName: m.name, memberCode: m.memberCode, branchId, day: today, at, result: decision.result, reason: decision.reason, method: opts.method, scannedById: opts.byId };
  t.set(P.attendanceEv(tenantId, id), ev);
  const allowed = decision.result !== 'BLOCKED';
  const newVisit = allowed && !(opts.oncePerDay && sameDay);
  t.set(P.lastScan(tenantId, m.id), {
    lastAllowedAt: allowed ? at : log.lastAllowedAt,
    lastResult: allowed ? decision.result : log.lastResult,
    month,
    visits: visitsNow + (newVisit ? 1 : 0),
    recent: [{ id, at, result: decision.result, reason: decision.reason }, ...log.recent].slice(0, 30),
  });
  await bumpDaily(t, tenantId, allowed ? { checkins: 1 } : { blocked: 1 }, branchId);
  return { ...view, result: decision.result, reason: decision.reason, duplicate: false, eventId: id, visitsThisMonth: visitsNow + (newVisit ? 1 : 0), at };
}

async function checkIn(c: C, memberId: string, method: 'QR' | 'MANUAL', branchIdIn?: string) {
  const u = c.var.user;
  const g = await gymOf(c);
  need(g, 'checkin');
  if (branchIdIn && !g.tenant.branches.some((b) => b.id === branchIdIn)) throw bad('Unknown branch');
  const out = await c.var.deps.store.tx(async (t) => {
    const m = isUuid(memberId) ? await t.get<MemberDoc>(P.member(g.tenantId, memberId)) : null;
    // A QR from another gym (or another branch for front desk) is not accepted here.
    if (!m || m.removed || (g.role === 'FRONT_DESK' && g.branchIds.length && m.branchId && !g.branchIds.includes(m.branchId))) throw notFound('This member is not part of your gym');
    return recordMemberCheckIn(t, g.tenantId, m, { method, byId: u.id, branchId: branchIdIn ?? g.branchId });
  });
  // Allowed at the desk: open this branch's gate too.
  const gate = out.result === 'ALLOWED' ? await openGate(c.var.deps, g.tenantId, branchIdIn ?? g.branchId) : null;
  return { ...out, gate };
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
    need(g, 'checkin');
    // ?day=YYYY-MM-DD shows another day's check-ins (up to today).
    const asked = c.req.query('day');
    const day = asked && /^\d{4}-\d{2}-\d{2}$/.test(asked) && asked <= todayIST() ? asked : todayIST();
    const rows = await c.var.deps.store.query<{ memberId: string; memberName: string; memberCode: string; at: string; result: string; reason: string | null; method: string; branchId?: string | null }>(P.attendance(g.tenantId), [['day', day]]);
    const events = rows
      .filter((r) => inBranch(g, r.data.branchId))
      .map((r) => ({ id: r.id, scannedAt: r.data.at, result: r.data.result, reason: r.data.reason, method: r.data.method, memberId: r.data.memberId, member: { id: r.data.memberId, name: r.data.memberName, memberCode: r.data.memberCode } }))
      .sort((a, b) => (a.scannedAt < b.scannedAt ? 1 : -1));
    const twoHoursAgo = Date.now() - 2 * 3600_000;
    return c.json({
      day,
      checkins: events.filter((e) => e.result !== 'BLOCKED').length,
      inGymNow: new Set(events.filter((e) => e.result !== 'BLOCKED' && new Date(e.scannedAt).getTime() > twoHoursAgo).map((e) => e.memberId)).size,
      blocked: events.filter((e) => e.result === 'BLOCKED').length,
      events,
    });
  });

  /**
   * Excel (CSV) of check-ins for a range of days (≤ 31): kind=members (anyone with the check-in right)
   * or kind=staff (owner only: front desk and trainers "Present" days). Follows the branch being looked at.
   */
  app.get('/api/v1/attendance/export', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const kind = c.req.query('kind') === 'staff' ? 'staff' : 'members';
    if (kind === 'staff' && g.role !== 'OWNER') throw forbidden('Only the gym owner can download staff attendance');
    if (kind === 'members') need(g, 'checkin');
    const today = todayIST();
    const ymd = (v: string | undefined, d: string) => (v && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : d);
    let to = ymd(c.req.query('to'), today);
    if (to > today) to = today;
    let from = ymd(c.req.query('from'), to);
    if (from > to) from = to;
    if (diffDays(from, to) > 30) from = addDays(to, -30);
    const { store } = c.var.deps;
    const days: string[] = [];
    for (let d = from; d <= to; d = addDays(d, 1)) days.push(d);
    const cell = (v: unknown) => {
      let s = v == null ? '' : String(v);
      if (/^(=|@|\t|\r|[+-](?![\d ]))/.test(s)) s = `'${s}`; // a name like =HYPERLINK(...) must not run as an Excel formula
      return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    };
    const time = (iso: string) => new Date(new Date(iso).getTime() + 5.5 * 3600_000).toISOString().slice(11, 16);
    const branchName = (id: string | null | undefined) => {
      const b = g.tenant.branches.find((x) => x.id === branchOf(g.tenant, id));
      return b ? (b.id === g.tenant.branches[0]?.id ? g.tenant.name : b.name) : '';
    };
    let lines: string[];
    if (kind === 'members') {
      const all = await Promise.all(days.map((d) => store.query<{ memberName: string; memberCode: string; at: string; result: string; reason: string | null; method: string; branchId?: string | null; trainerId?: string }>(P.attendance(g.tenantId), [['day', d]])));
      const rows = all.flat().filter((r) => inBranch(g, r.data.branchId) && !r.data.trainerId).sort((a, b) => (a.data.at < b.data.at ? -1 : 1));
      lines = [
        ['Date', 'Time', 'Name', 'Member ID', 'Result', 'Reason', 'How', 'Branch'].join(','),
        ...rows.map((r) => [r.data.at ? todayIST(new Date(r.data.at)) : '', time(r.data.at), r.data.memberName, r.data.memberCode, r.data.result, r.data.reason ?? '', r.data.method === 'SELF' ? 'App QR' : r.data.method === 'MANUAL' ? 'Manual' : 'Desk scan', branchName(r.data.branchId)].map(cell).join(',')),
      ];
    } else {
      const months = [...new Set(days.map((d) => d.slice(0, 7)))];
      const docs = (await Promise.all(months.map((m) => store.query<{ uid: string; month: string; branchId: string | null; days: Record<string, { at: string; absent?: boolean; byOwner?: string }> }>(`tenants/${g.tenantId}/staffDays`, [['month', m]])))).flat();
      const mine = docs.filter((d) => (d.data.branchId ?? g.tenant.branches[0]?.id) === g.branchId);
      const users = await store.getMany<UserDoc>(mine.map((d) => P.user(d.data.uid)));
      const staffOf = (uid: string, i: number) => users[i]?.staffOf?.[g.tenantId]?.role ?? '';
      const out: string[][] = [];
      mine.forEach((d, i) => {
        for (const [day, x] of Object.entries(d.data.days)) {
          if (day < from || day > to) continue;
          out.push([day, x.absent ? '' : time(x.at), users[i]?.name ?? 'Staff', staffOf(d.data.uid, i) === 'TRAINER' ? 'Trainer' : 'Front desk', x.absent ? 'Absent' : 'Present', x.byOwner ? 'Corrected by owner' : '', branchName(d.data.branchId)]);
        }
      });
      out.sort((a, b) => (a[0] + a[2] < b[0] + b[2] ? -1 : 1));
      lines = [['Date', 'Time', 'Name', 'Role', 'Attendance', 'Note', 'Branch'].join(','), ...out.map((r) => r.map(cell).join(','))];
    }
    const name = `${kind === 'staff' ? 'staff' : 'members'}-attendance-${from}-to-${to}.csv`;
    return new Response('\uFEFF' + lines.join('\r\n'), { headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': `attachment; filename="${name}"` } });
  });
}
