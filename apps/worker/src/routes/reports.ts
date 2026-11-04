import { App, authenticate, dailyFor, gymOf, P, readRoster, need } from '../core';
import { addDays, isYmd, todayIST } from '../lib/dates';
import { bad } from '../lib/http';
import { validSubs } from '../lib/status';
import { requireFeature } from './billing';
import { summaries } from './members';
import type { PtDoc } from './pt';

const RANGES = [7, 30, 90] as const;

/** Reports for the owner app: money, visits and members over the last 7 / 30 / 90 days. */
const ENTRY_RANGES = [7, 30, 90, 365] as const;
const OVERDUE_AFTER_DAYS = 7;

/** `?days=7|30|90` or a custom `?from=YYYY-MM-DD&to=YYYY-MM-DD` (up to 1 year). */
export function reportRange(q: (k: string) => string | undefined, allowed: readonly number[]) {
  const today = todayIST();
  const f = q('from');
  const t = q('to');
  if (f || t) {
    if (!f || !t || !isYmd(f) || !isYmd(t)) throw bad('Choose both dates');
    const to = t > today ? today : t;
    if (f > to) throw bad('From date must be before To date');
    const days = Math.round((Date.parse(to) - Date.parse(f)) / 86400000) + 1;
    if (days > 366) throw bad('Choose up to 1 year');
    return { from: f, to, days, custom: true };
  }
  const asked = Number(q('days') ?? 30);
  const days = allowed.includes(asked) ? asked : 30;
  return { from: addDays(today, -(days - 1)), to: today, days, custom: false };
}

export function reportRoutes(app: App) {
  /**
   * Every membership sold (and PT package) in the period, plus anything older that still has
   * money due. The app searches and filters this list itself (tabs: All / Paid / Pending / Overdue).
   */
  app.get('/api/v1/reports/entries', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    need(g, 'reports');
    const { store } = c.var.deps;
    await requireFeature(store, g.tenant, 'reports');
    const { from, to: today, days, custom } = reportRange((k) => c.req.query(k), ENTRY_RANGES);
    const overdueBefore = addDays(today, -OVERDUE_AFTER_DAYS);
    const [roster, pts] = await Promise.all([readRoster(store, g.tenantId), store.query<PtDoc>(P.pts(g.tenantId), [['status', 'ACTIVE']])]);
    const visible = new Map(summaries(g, roster).map((m) => [m.id, m]));
    const status = (total: number, paid: number, start: string) => (paid >= total ? 'PAID' : start <= overdueBefore ? 'OVERDUE' : 'PENDING');
    const entries: Record<string, unknown>[] = [];
    for (const [mid, e] of Object.entries(roster.members)) {
      const m = visible.get(mid);
      if (!m) continue;
      const subs = validSubs(e.subs).sort((a, b) => (a.startDate < b.startDate ? -1 : 1));
      const byId = new Map(e.subs.map((s) => [s.id, s]));
      subs.forEach((s, i) => {
        let root = s;
        for (let k = 0; k < 20 && root.replacesId && byId.has(root.replacesId); k++) root = byId.get(root.replacesId)!;
        const date = todayIST(new Date(root.createdAt));
        const due = Math.max(0, s.total - s.paid);
        if ((date < from || date > today) && due === 0) return;
        entries.push({
          id: s.id,
          kind: 'MEMBERSHIP',
          type: i === 0 ? 'New' : 'Renewal',
          memberId: mid,
          name: e.name,
          memberCode: e.memberCode,
          photoUrl: m.photoUrl,
          title: s.planName,
          date,
          startDate: s.startDate,
          endDate: s.endDate,
          total: s.total,
          paid: s.paid,
          due,
          status: status(s.total, s.paid, s.startDate),
        });
      });
    }
    for (const r of pts) {
      const p = r.data;
      const paid = p.payments.reduce((n, x) => n + x.amount, 0);
      const date = p.decidedAt ? todayIST(new Date(p.decidedAt)) : p.startDate ?? today;
      const due = Math.max(0, p.price - paid);
      if ((date < from || date > today) && due === 0) continue;
      const m = visible.get(p.memberId);
      if (!m) continue;
      entries.push({
        id: p.id,
        kind: 'PT',
        type: 'PT',
        memberId: p.memberId,
        name: p.memberName,
        memberCode: m.memberCode,
        photoUrl: m.photoUrl,
        title: `PT · ${p.trainerName}`,
        date,
        startDate: p.startDate ?? date,
        endDate: p.endDate,
        total: p.price,
        paid,
        due,
        status: status(p.price, paid, p.startDate ?? date),
      });
    }
    entries.sort((a, b) => (String(a.date) < String(b.date) ? 1 : String(a.date) > String(b.date) ? -1 : 0));
    const sum = (k: string) => entries.reduce((n, x) => n + Number(x[k]), 0);
    return c.json({ days, custom, from, to: today, overdueAfterDays: OVERDUE_AFTER_DAYS, count: entries.length, total: sum('total'), paid: sum('paid'), due: sum('due'), entries });
  });

  app.get('/api/v1/reports', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    need(g, 'reports');
    const { store } = c.var.deps;
    await requireFeature(store, g.tenant, 'reports');
    const { from, to: today, days, custom } = reportRange((k) => c.req.query(k), RANGES);
    const dates = Array.from({ length: days }, (_, i) => addDays(from, i));
    const [daily, roster] = await Promise.all([
      store.getMany<Record<string, number>>(dates.map((d) => P.daily(g.tenantId, d))),
      readRoster(store, g.tenantId),
    ]);
    const series = dates.map((date, i) => {
      const d = dailyFor(g, daily[i]); // only the branch being looked at
      return { date, collected: d.collected, payments: d.payments, checkins: d.checkins };
    });
    const sum = (k: 'collected' | 'payments' | 'checkins') => series.reduce((n, d) => n + d[k], 0);

    const all = summaries(g, roster);
    const status: Record<string, number> = {};
    for (const m of all) status[m.status] = (status[m.status] ?? 0) + 1;

    // Memberships sold in the period, and how many members each plan has now.
    let sold = 0;
    let soldAmount = 0;
    let newMembers = 0;
    const plans = new Map<string, { name: string; active: number; sold: number; amount: number }>();
    const plan = (name: string) => plans.get(name) ?? (plans.set(name, { name, active: 0, sold: 0, amount: 0 }), plans.get(name)!);
    for (const [id, e] of Object.entries(roster.members)) {
      if (e.archived) continue;
      if (!all.some((m) => m.id === id)) continue; // branch the user cannot see
      const subs = validSubs(e.subs);
      // A correction counts on the day the original membership was sold.
      const byId = new Map(e.subs.map((s) => [s.id, s]));
      const soldOn = (s: (typeof e.subs)[number]) => {
        let cur = s;
        for (let i = 0; i < 20 && cur.replacesId && byId.has(cur.replacesId); i++) cur = byId.get(cur.replacesId)!;
        return todayIST(new Date(cur.createdAt));
      };
      const firstDay = subs.map(soldOn).sort()[0];
      if (firstDay && firstDay >= from && firstDay <= today) newMembers++;
      for (const s of subs) {
        const on = soldOn(s);
        if (on < from || on > today) continue;
        sold++;
        soldAmount += s.total;
        const p = plan(s.planName);
        p.sold++;
        p.amount += s.total;
      }
    }
    for (const m of all) if ((m.status === 'ACTIVE' || m.status === 'ENDING_SOON' || m.status === 'FROZEN') && m.planName) plan(m.planName).active++;

    return c.json({
      days,
      custom,
      from,
      to: today,
      series,
      totals: {
        collected: sum('collected'),
        payments: sum('payments'),
        checkins: sum('checkins'),
        avgCheckins: Math.round((sum('checkins') / days) * 10) / 10,
        sold,
        soldAmount,
        newMembers,
        members: all.length,
        dueAmount: all.reduce((n, m) => n + m.due, 0),
        dueMembers: all.filter((m) => m.due > 0).length,
      },
      status,
      plans: [...plans.values()].sort((a, b) => b.active - a.active || b.sold - a.sold),
      topDue: all.filter((m) => m.due > 0).sort((a, b) => b.due - a.due).slice(0, 10),
    });
  });
}
