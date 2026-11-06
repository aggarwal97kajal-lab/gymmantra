import { App, audit, authenticate, C, gymOf, notify, P, Role, TenantDoc, UserDoc } from '../core';
import { todayIST } from '../lib/dates';
import { bad, notFound, nowIso, uuid } from '../lib/http';
import { body, int, oneOf, optStr, str } from '../lib/validate';
import type { StaffDaysDoc } from './staffdays';
import type { TrainerDoc } from './trainers';

/**
 * Staff salary (board 88): the owner sets each person's salary once (fixed a month, or per day).
 * Each month: present days come from staff attendance ("Present"), absent days beyond the free
 * leaves are cut, advance / bonus / cut are added, and payments are recorded. Staff and trainers
 * see only their own slips. People without the app (cleaner, guard) can be added by name.
 * PT money stays in PT accounts (paid separately), so it is never paid twice.
 */
export interface SalaryCfg {
  uid: string;
  name: string; // kept for people without the app
  role: Role | 'OTHER';
  branchId: string | null;
  noApp?: boolean;
  amount: number; // a month (MONTH) or a day (DAY)
  mode: 'MONTH' | 'DAY';
  workDays: number;
  freeLeaves: number;
  cutAbsent: boolean;
  active: boolean;
}
export interface SalaryMonth {
  uid: string;
  month: string;
  adj: { id: string; kind: 'ADVANCE' | 'BONUS' | 'CUT'; amount: number; note: string | null; at: string }[];
  pays: { id: string; amount: number; mode: string; at: string; byId: string; note: string | null }[];
}

const MODES = ['CASH', 'UPI', 'CARD', 'BANK_TRANSFER'] as const;
const monthOf = (v: string | undefined) => (v && /^\d{4}-\d{2}$/.test(v) ? v : todayIST().slice(0, 7));
const sum = (a: { amount: number }[]) => a.reduce((n, x) => n + x.amount, 0);

/** The month's numbers for one person. */
export function slip(cfg: SalaryCfg, m: SalaryMonth | null, days: StaffDaysDoc | null, month: string, today = todayIST()) {
  const present = Object.values(days?.days ?? {}).filter((d) => !d.absent).length;
  const inMonth = new Date(Number(month.slice(0, 4)), Number(month.slice(5, 7)), 0).getDate();
  const elapsed = month < today.slice(0, 7) ? inMonth : month > today.slice(0, 7) ? 0 : Number(today.slice(8, 10));
  // Work days expected so far (the whole month once it is over).
  const expected = Math.round((cfg.workDays * elapsed) / inMonth);
  let base: number;
  let cut = 0;
  let absent = 0;
  if (cfg.mode === 'DAY') base = cfg.amount * present;
  else {
    base = cfg.amount;
    if (cfg.cutAbsent && !cfg.noApp) {
      absent = Math.max(0, expected - present);
      cut = Math.round((Math.max(0, absent - cfg.freeLeaves) * cfg.amount) / Math.max(1, cfg.workDays));
    }
  }
  const adj = m?.adj ?? [];
  const bonus = sum(adj.filter((a) => a.kind === 'BONUS'));
  const advance = sum(adj.filter((a) => a.kind === 'ADVANCE'));
  const otherCut = sum(adj.filter((a) => a.kind === 'CUT'));
  const total = Math.max(0, base - cut - otherCut + bonus);
  const paid = sum(m?.pays ?? []) + advance; // an advance is money already given
  return { month, present, absent, expected, base, cut, otherCut, bonus, advance, total, paid, due: Math.max(0, total - paid), adj, pays: m?.pays ?? [], running: elapsed < inMonth };
}

async function people(c: C, tenantId: string, tenant: TenantDoc, branchId: string) {
  const { store } = c.var.deps;
  const [staff, trainers, cfgs] = await Promise.all([
    store.query<{ role: Role; branchIds: string[]; active: boolean }>(P.staffCol(tenantId), [['active', true]]),
    store.query<TrainerDoc>(P.trainers(tenantId), [['active', true]]),
    store.query<SalaryCfg>(P.salaryCfgs(tenantId)),
  ]);
  const first = tenant.branches[0]?.id ?? '';
  const list: { id: string; role: Role | 'OTHER'; noApp: boolean }[] = [];
  for (const s of staff) if (s.data.role === 'FRONT_DESK' && (s.data.branchIds[0] ?? first) === branchId) list.push({ id: s.id, role: 'FRONT_DESK', noApp: false });
  for (const t of trainers) if (!t.data.gone && (t.data.branchId ?? first) === branchId) list.push({ id: t.data.userId, role: 'TRAINER', noApp: false });
  for (const r of cfgs) if (r.data.noApp && r.data.active && (r.data.branchId ?? first) === branchId) list.push({ id: r.id, role: 'OTHER', noApp: true });
  const byId = new Map(cfgs.map((r) => [r.id, r.data]));
  return { list, byId };
}

export function salaryRoutes(app: App) {
  app.get('/api/v1/salary', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const month = monthOf(c.req.query('month'));
    const branchId = g.branchId || g.tenant.branches[0]?.id || '';
    const { store } = c.var.deps;
    const { list, byId } = await people(c, g.tenantId, g.tenant, branchId);
    const [users, months, days] = await Promise.all([
      store.getMany<UserDoc>(list.map((p) => P.user(p.noApp ? '-' : p.id))),
      store.getMany<SalaryMonth>(list.map((p) => P.salaryMonth(g.tenantId, p.id, month))),
      store.getMany<StaffDaysDoc>(list.map((p) => `tenants/${g.tenantId}/staffDays/${p.id}_${month}`)),
    ]);
    const rows = list.map((p, i) => {
      const cfg = byId.get(p.id) ?? null;
      const name = p.noApp ? (cfg?.name ?? 'Staff') : (users[i]?.name ?? cfg?.name ?? 'Staff');
      return { id: p.id, role: p.role, name, noApp: p.noApp, cfg, slip: cfg ? slip(cfg, months[i], days[i], month) : null };
    });
    const set = rows.filter((r) => r.slip);
    return c.json({
      month,
      total: set.reduce((n, r) => n + r.slip!.total, 0),
      paid: set.reduce((n, r) => n + r.slip!.paid, 0),
      due: set.reduce((n, r) => n + r.slip!.due, 0),
      rows: rows.sort((a, b) => a.name.localeCompare(b.name)),
    });
  });

  /** Salary of one person (or a new person without the app: uid "new"). */
  app.put('/api/v1/salary/:uid', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    let uid = c.req.param('uid');
    const branchId = g.branchId || g.tenant.branches[0]?.id || null;
    const isNew = uid === 'new';
    if (isNew) uid = `e_${uuid()}`;
    const { store } = c.var.deps;
    const old = isNew ? null : await store.get<SalaryCfg>(P.salaryCfg(g.tenantId, uid));
    let role: SalaryCfg['role'] = old?.role ?? 'OTHER';
    let name = old?.name ?? '';
    if (!isNew && !old?.noApp) {
      const [st, tr, usr] = await store.getMany<any>([P.staff(g.tenantId, uid), P.trainer(g.tenantId, uid), P.user(uid)]);
      if (!st?.active) throw notFound('Staff not found');
      role = st.role;
      name = (usr as UserDoc | null)?.name ?? tr?.name ?? name;
    }
    if (isNew || old?.noApp) name = str(b, 'name', { max: 60, label: 'the name' });
    const cfg: SalaryCfg = {
      uid,
      name,
      role: isNew || old?.noApp ? 'OTHER' : role,
      branchId: old?.branchId ?? branchId,
      noApp: isNew || old?.noApp || undefined,
      amount: int(b, 'amount', { min: 0, max: 10_000_000, label: 'salary' }),
      mode: oneOf(b, 'mode', ['MONTH', 'DAY'] as const, true) ?? 'MONTH',
      workDays: int(b, 'workDays', { min: 1, max: 31, label: 'work days' }),
      freeLeaves: int(b, 'freeLeaves', { min: 0, max: 31, label: 'free leaves' }),
      cutAbsent: b.cutAbsent === true,
      active: b.active !== false,
    };
    await store.tx(async (t) => {
      t.set(P.salaryCfg(g.tenantId, uid), cfg);
      audit(t, g.tenantId, u.id, 'salary.set', 'staff', uid, old, cfg);
    });
    return c.json(cfg);
  });

  /** Advance / bonus / cut for a month. */
  app.post('/api/v1/salary/:uid/adjust', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const uid = c.req.param('uid');
    const month = monthOf(typeof b.month === 'string' ? b.month : undefined);
    const kind = oneOf(b, 'kind', ['ADVANCE', 'BONUS', 'CUT'] as const)!;
    const amount = int(b, 'amount', { min: 1, max: 10_000_000, label: 'amount' });
    const note = optStr(b, 'note', { max: 200 }) ?? null;
    const out = await c.var.deps.store.tx(async (t) => {
      const cfg = await t.get<SalaryCfg>(P.salaryCfg(g.tenantId, uid));
      if (!cfg) throw bad('Set the salary first');
      const m = (await t.get<SalaryMonth>(P.salaryMonth(g.tenantId, uid, month))) ?? { uid, month, adj: [], pays: [] };
      const n = { ...m, adj: [...m.adj, { id: uuid(), kind, amount, note, at: nowIso() }] };
      t.set(P.salaryMonth(g.tenantId, uid, month), n);
      audit(t, g.tenantId, u.id, `salary.${kind.toLowerCase()}`, 'staff', uid, null, { month, amount, note });
      return n;
    });
    return c.json(out);
  });

  app.post('/api/v1/salary/:uid/pay', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const uid = c.req.param('uid');
    const month = monthOf(typeof b.month === 'string' ? b.month : undefined);
    const amount = int(b, 'amount', { min: 1, max: 10_000_000, label: 'amount' });
    const mode = oneOf(b, 'mode', MODES)!;
    const note = optStr(b, 'note', { max: 200 }) ?? null;
    const out = await c.var.deps.store.tx(async (t) => {
      const cfg = await t.get<SalaryCfg>(P.salaryCfg(g.tenantId, uid));
      if (!cfg) throw bad('Set the salary first');
      const m = (await t.get<SalaryMonth>(P.salaryMonth(g.tenantId, uid, month))) ?? { uid, month, adj: [], pays: [] };
      const n = { ...m, pays: [...m.pays, { id: uuid(), amount, mode, at: nowIso(), byId: u.id, note }] };
      t.set(P.salaryMonth(g.tenantId, uid, month), n);
      if (!cfg.noApp) await notify(t, uid, g.tenantId, 'Salary paid', `${g.tenant.name} paid you ₹${amount} salary for ${month}.`, null, 'salary');
      audit(t, g.tenantId, u.id, 'salary.pay', 'staff', uid, null, { month, amount, mode });
      return n;
    });
    return c.json(out, 201);
  });

  /** Staff / trainer: my salary slips (last 12 months that have a salary set). */
  app.get('/api/v1/me/salary', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'FRONT_DESK', 'TRAINER', 'OWNER');
    const { store } = c.var.deps;
    const cfg = await store.get<SalaryCfg>(P.salaryCfg(g.tenantId, u.id));
    if (!cfg) return c.json({ gymName: g.tenant.name, name: u.name, months: [] });
    const now = todayIST().slice(0, 7);
    const months: string[] = [];
    for (let i = 0; i < 12; i++) {
      const d = new Date(Date.UTC(Number(now.slice(0, 4)), Number(now.slice(5, 7)) - 1 - i, 1));
      months.push(d.toISOString().slice(0, 7));
    }
    const [ms, ds] = await Promise.all([
      store.getMany<SalaryMonth>(months.map((m) => P.salaryMonth(g.tenantId, u.id, m))),
      store.getMany<StaffDaysDoc>(months.map((m) => `tenants/${g.tenantId}/staffDays/${u.id}_${m}`)),
    ]);
    const out = months.map((m, i) => slip(cfg, ms[i], ds[i], m)).filter((s, i) => i === 0 || ms[i] || s.present);
    return c.json({ gymName: g.tenant.name, name: u.name, mode: cfg.mode, months: out });
  });
}
