import { App, authenticate, branchOf, dailyFor, gymOf, P, readRoster, need } from '../core';
import { addDays, isYmd, todayIST } from '../lib/dates';
import { bad } from '../lib/http';
import { validSubs } from '../lib/status';
import { requireFeature } from './billing';
import { summaries } from './members';
import type { PtDoc, PayoutDoc } from './pt';
import type { LockersDoc } from './lockers';
import { people, slip, type SalaryCfg, type SalaryMonth } from './salary';
import type { StaffDaysDoc } from './staffdays';

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

  /**
   * Money cards (board 94) for the branch being looked at: memberships, PT, lockers (money in) and
   * staff salary (money out, owner only). Each card has its own list; `?csv=1` gives all lists.
   */
  app.get('/api/v1/reports/money', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    need(g, 'reports');
    const { store } = c.var.deps;
    await requireFeature(store, g.tenant, 'reports');
    const { from, to, days, custom } = reportRange((k) => c.req.query(k), RANGES);
    const inRange = (iso: string) => {
      const d = todayIST(new Date(iso));
      return d >= from && d <= to;
    };
    const first = g.tenant.branches[0]?.id ?? '';
    const [roster, pts, payouts, lockers] = await Promise.all([
      readRoster(store, g.tenantId),
      store.query<PtDoc>(P.pts(g.tenantId)),
      store.query<PayoutDoc>(P.payouts(g.tenantId)),
      store.get<LockersDoc>(P.lockers(g.tenantId, g.branchId || first)),
    ]);
    type Line = { date: string; name: string; what: string; amount: number };
    const csvCell = (v: unknown) => {
      let x = v == null ? '' : String(v);
      if (/^(=|@|\t|\r|[+-](?![\d ]))/.test(x)) x = `'${x}`; // a name like =HYPERLINK(...) must not run as an Excel formula
      return /[",\n]/.test(x) ? `"${x.replace(/"/g, '""')}"` : x;
    };

    // Memberships: money received in the period (day counters), and what was sold: new vs renewal.
    const visible = new Map(summaries(g, roster).map((m) => [m.id, m]));
    const dates = Array.from({ length: days }, (_, i) => addDays(from, i));
    const daily = await store.getMany<Record<string, number>>(dates.map((d) => P.daily(g.tenantId, d)));
    const received = daily.reduce((n, d) => n + dailyFor(g, d).collected, 0);
    const mLines: Line[] = [];
    let fresh = 0;
    let renewal = 0;
    for (const [mid, e] of Object.entries(roster.members)) {
      if (!visible.has(mid)) continue;
      const byId = new Map(e.subs.map((x) => [x.id, x]));
      const soldOn = (x: (typeof e.subs)[number]) => {
        let cur = x;
        for (let i = 0; i < 20 && cur.replacesId && byId.has(cur.replacesId); i++) cur = byId.get(cur.replacesId)!;
        return todayIST(new Date(cur.createdAt));
      };
      const subs = validSubs(e.subs).map((x) => ({ x, on: soldOn(x) })).sort((p, q) => (p.on < q.on ? -1 : 1));
      subs.forEach(({ x, on }, i) => {
        if (on < from || on > to) return;
        if (i === 0) fresh += x.total;
        else renewal += x.total;
        mLines.push({ date: on, name: e.name, what: `${x.planName}${i === 0 ? ' (new)' : ' (renewal)'}`, amount: x.total });
      });
    }
    const dues = [...visible.values()].reduce((n, m) => n + m.due, 0);

    // PT: what members paid in the period, the trainers' share of it, and payouts made.
    const ptLines: Line[] = [];
    let ptIn = 0;
    let ptShare = 0;
    for (const r of pts) {
      const pt = r.data;
      const e = roster.members[pt.memberId];
      if (branchOf(g.tenant, e?.branchId) !== (g.branchId || first)) continue;
      for (const p of pt.payments ?? []) {
        if (!inRange(p.at)) continue;
        ptIn += p.amount;
        ptShare += Math.round((p.amount * (pt.sharePercent ?? 0)) / 100);
        ptLines.push({ date: todayIST(new Date(p.at)), name: pt.memberName, what: `PT with ${pt.trainerName}`, amount: p.amount });
      }
    }
    const ptPaidOut = payouts.filter((p) => p.data.month >= from.slice(0, 7) && p.data.month <= to.slice(0, 7)).reduce((n, p) => n + p.data.amount, 0);

    // Lockers: fees taken in the period; deposits are held money (to be given back), shown apart.
    const lLines: Line[] = [];
    let lFees = 0;
    let lDepIn = 0;
    let lDepOut = 0;
    for (const x of lockers?.log ?? []) {
      if (!inRange(x.at)) continue;
      if (x.what === 'GIVEN' || x.what === 'RENEWED') {
        const fee = x.fee ?? x.amount - (x.deposit ?? 0);
        lFees += fee;
        lDepIn += x.deposit ?? 0;
        lLines.push({ date: todayIST(new Date(x.at)), name: x.name, what: `Locker ${x.n} ${x.what === 'GIVEN' ? 'given' : 'renewed'}`, amount: fee });
      } else if (x.what === 'FREED_DEPOSIT_RETURNED') {
        lDepOut += -x.amount;
      }
    }
    const depositHeld = Object.values(lockers?.lockers ?? {}).reduce((n, l: any) => n + (l?.deposit ?? 0), 0);

    // Staff salary (owner only): every month that touches the period.
    let salary: Record<string, unknown> | null = null;
    const sLines: Line[] = [];
    if (g.role === 'OWNER') {
      // 7 / 30 days: this month's salary; 90 days: the last 3 months; own dates: every month they touch.
      const months: string[] = [];
      const want = custom ? Infinity : Math.max(1, Math.round(days / 30));
      for (let m = to.slice(0, 7); m >= from.slice(0, 7) || (!custom && months.length < want); ) {
        if (months.length >= want) break;
        months.unshift(m);
        const [y, mo] = m.split('-').map(Number);
        m = mo === 1 ? `${y - 1}-12` : `${y}-${String(mo - 1).padStart(2, '0')}`;
      }
      const { list, byId } = await people(c, g.tenantId, g.tenant, g.branchId || first);
      const withCfg = list.filter((p) => byId.get(p.id));
      const keys = months.flatMap((mo) => withCfg.map((p) => ({ mo, p })));
      const [ms, ds, us] = await Promise.all([
        store.getMany<SalaryMonth>(keys.map((k) => P.salaryMonth(g.tenantId, k.p.id, k.mo))),
        store.getMany<StaffDaysDoc>(keys.map((k) => `tenants/${g.tenantId}/staffDays/${k.p.id}_${k.mo}`)),
        store.getMany<any>(withCfg.map((p) => P.user(p.noApp ? '-' : p.id))),
      ]);
      const nameOf = new Map(withCfg.map((p, i) => [p.id, p.noApp ? (byId.get(p.id)?.name ?? 'Staff') : (us[i]?.name ?? byId.get(p.id)?.name ?? 'Staff')]));
      let total = 0;
      let paid = 0;
      let due = 0;
      let advance = 0;
      keys.forEach((k, i) => {
        const s = slip(byId.get(k.p.id) as SalaryCfg, ms[i], ds[i], k.mo);
        total += s.total;
        paid += s.paid;
        due += s.due;
        advance += s.advance;
        for (const p of s.pays) sLines.push({ date: todayIST(new Date(p.at)), name: nameOf.get(k.p.id)!, what: `Salary ${k.mo}`, amount: p.amount });
        for (const a of s.adj) if (a.kind === 'ADVANCE') sLines.push({ date: todayIST(new Date(a.at)), name: nameOf.get(k.p.id)!, what: `Advance ${k.mo}`, amount: a.amount });
      });
      salary = { months, total, paid, due, advance };
    }

    const byDate = (a: Line[]) => a.sort((x, y) => (x.date < y.date ? 1 : -1));
    if (c.req.query('csv') === '1') {
      const rows = [
        ['Card', 'Date', 'Name', 'Item', 'Amount'],
        ...byDate(mLines).map((l) => ['Memberships', l.date, l.name, l.what, l.amount]),
        ...byDate(ptLines).map((l) => ['PT', l.date, l.name, l.what, l.amount]),
        ...byDate(lLines).map((l) => ['Lockers', l.date, l.name, l.what, l.amount]),
        ...byDate(sLines).map((l) => ['Staff salary', l.date, l.name, l.what, -l.amount]),
      ];
      return new Response('﻿' + rows.map((r) => r.map(csvCell).join(',')).join('\n'), {
        headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': `attachment; filename="money-${from}-to-${to}.csv"` },
      });
    }
    const income = received + ptIn + lFees;
    const salaryOut = (salary?.total as number | undefined) ?? 0;
    return c.json({
      days,
      custom,
      from,
      to,
      memberships: { total: received, fresh, renewal, due: dues, lines: byDate(mLines).slice(0, 300) },
      pt: { total: ptIn, trainerShare: ptShare, gymKeeps: ptIn - ptShare, paidOut: ptPaidOut, lines: byDate(ptLines).slice(0, 300) },
      lockers: { total: lFees, depositIn: lDepIn, depositBack: lDepOut, depositHeld, lines: byDate(lLines).slice(0, 300) },
      salary: salary ? { ...salary, lines: byDate(sLines).slice(0, 300) } : null,
      net: { income, out: salaryOut + ptShare, left: income - salaryOut - ptShare },
    });
  });
}
