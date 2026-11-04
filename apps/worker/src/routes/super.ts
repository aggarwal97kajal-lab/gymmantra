import { edgeGet, edgePut } from '../lib/edge';
import { App, audit, authenticate, P, requireSuper, Role, TenantDoc, UserDoc } from '../core';
import { removeAccount } from './me';
import { bad, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { isYmd } from '../lib/dates';
import { body, int, oneOf, optBool, optInt, optStr, str, strList } from '../lib/validate';
import type { Store } from '../store/store';
import type { SaasPlan } from './gym';
import { FEATURE_KEYS } from './billing';
import { normalizeEmail, normalizePhone } from '../lib/phone';
import { addDays, todayIST } from '../lib/dates';
import { reportRange } from './reports';
import { ticketStatus, type Ticket } from './tickets';

/** Starting SaaS plans. Created once; after that the super admin edits them in the panel. */
export const DEFAULT_SAAS_PLANS = [
  { name: 'Starter', monthlyPrice: 399, annualPrice: 3990, memberLimit: 150, branchLimit: 1, staffLimit: 3, whatsappLimit: 0, features: ['Admin panel', 'Member app', 'Plans & manual memberships', 'QR attendance', 'Support inbox'], unlocks: [] as string[], sortOrder: 1 },
  { name: 'Growth', monthlyPrice: 799, annualPrice: 7990, memberLimit: 500, branchLimit: 1, staffLimit: 5, whatsappLimit: 1000, features: ['Everything in Starter', 'Offers', 'Trainers, PT and diet plans', 'PT accounts'], unlocks: ['offers', 'pt'], sortOrder: 2 },
  { name: 'Pro', monthlyPrice: 1399, annualPrice: 13990, memberLimit: null, branchLimit: 3, staffLimit: 15, whatsappLimit: 5000, features: ['Everything in Growth', 'Reports', 'Up to 3 branches', 'Priority support'], unlocks: ['offers', 'pt', 'reports', 'branches'], sortOrder: 3 },
];

let baseChecked = false;
export async function ensureBaseData(store: Store) {
  if (baseChecked) return;
  if (await edgeGet<boolean>('base-ok')) {
    baseChecked = true;
    return;
  }
  await store.tx(async (t) => {
    if (await t.get(P.platform)) return;
    t.set(P.platform, { trialMonths: 3 });
    for (const p of DEFAULT_SAAS_PLANS) t.set(P.saasPlan(uuid()), { ...p, visible: true, createdAt: nowIso() });
  });
  baseChecked = true;
  await edgePut('base-ok', true, 24 * 3600);
}
export function resetBaseCheck() {
  baseChecked = false;
}

function planFields(b: Record<string, unknown>, partial: boolean) {
  const o: Partial<SaasPlan> = {};
  if (!partial || b.name !== undefined) o.name = str(b, 'name', { min: 2, max: 40, label: 'the plan name' });
  if (!partial || b.monthlyPrice !== undefined) o.monthlyPrice = int(b, 'monthlyPrice', { min: 0, max: 1_000_000, label: 'monthly price' });
  if (!partial || b.annualPrice !== undefined) o.annualPrice = int(b, 'annualPrice', { min: 0, max: 10_000_000, label: 'annual price' });
  if (b.memberLimit !== undefined) o.memberLimit = b.memberLimit === null ? null : int(b, 'memberLimit', { min: 1, label: 'member limit' });
  else if (!partial) o.memberLimit = null;
  const n = (k: 'branchLimit' | 'staffLimit' | 'whatsappLimit' | 'sortOrder', d: number, min: number, max: number) => {
    const v = optInt(b, k, { min, max, label: k });
    if (v !== undefined) o[k] = v;
    else if (!partial) o[k] = d;
  };
  n('branchLimit', 1, 1, 100);
  n('staffLimit', 5, 1, 500);
  n('whatsappLimit', 0, 0, 10_000_000);
  n('sortOrder', 0, -1000, 1000);
  const f = strList(b, 'features', 30);
  if (f !== undefined || !partial) o.features = f ?? [];
  const v = optBool(b, 'visible');
  if (v !== undefined || !partial) o.visible = v ?? true;
  const un = strList(b, 'unlocks', 10);
  if (un !== undefined) (o as { unlocks?: string[] }).unlocks = un.filter((k) => (FEATURE_KEYS as readonly string[]).includes(k));
  return o;
}

export function superRoutes(app: App) {
  /** Public pricing, for the website and the admin panel. */
  app.get('/api/v1/saas-plans', async (c) => {
    const { store } = c.var.deps;
    const [plans, s] = await Promise.all([store.query<SaasPlan>(P.saasPlans, [['visible', true]]), store.get<{ trialMonths: number }>(P.platform)]);
    return c.json({ trialMonths: s?.trialMonths ?? 3, plans: plans.map((p) => ({ ...p.data, id: p.id })).sort((a, b) => a.sortOrder - b.sortOrder) });
  });

  app.get('/api/v1/super/overview', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const { store } = c.var.deps;
    const [tenants, stats, tickets] = await Promise.all([store.query<TenantDoc>('tenants'), store.get<{ users: number }>(P.stats), store.query(P.tickets, [['routedTo', 'GYMMANTRA'], ['status', 'OPEN']])]);
    const n = (s: string) => tenants.filter((t) => t.data.status === s).length;
    return c.json({ gyms: tenants.length, trial: n('TRIAL'), active: n('ACTIVE'), suspended: n('SUSPENDED'), members: tenants.reduce((x, t) => x + (t.data.memberCount ?? 0), 0), users: stats?.users ?? 0, openTickets: tickets.length });
  });

  app.get('/api/v1/super/gyms', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const { store } = c.var.deps;
    const [tenants, plans] = await Promise.all([store.query<TenantDoc>('tenants'), store.query<SaasPlan>(P.saasPlans)]);
    const out = [];
    for (const t of tenants) {
      const owners = (await store.query<{ role: Role; active: boolean }>(P.staffCol(t.id), [['role', 'OWNER']])).filter((s) => s.data.active);
      const users = await store.getMany<any>(owners.map((o) => P.user(o.id)));
      const plan = plans.find((p) => p.id === t.data.saasPlanId);
      out.push({
        ...t.data,
        id: t.id,
        saasPlan: plan ? { id: plan.id, name: plan.data.name } : null,
        _count: { members: t.data.memberCount ?? 0, branches: t.data.branches.length },
        owners: users.filter(Boolean).map((u) => ({ name: u.name, phone: u.phone, email: u.email })),
      });
    }
    return c.json(out.sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)));
  });

  app.patch('/api/v1/super/gyms/:id', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const status = oneOf(b, 'status', ['TRIAL', 'ACTIVE', 'SUSPENDED'] as const, true);
    const verified = optBool(b, 'verified');
    const saasPlanId = b.saasPlanId === null ? null : typeof b.saasPlanId === 'string' ? b.saasPlanId : undefined;
    const custom = b.customMonthlyPrice === null ? null : optInt(b, 'customMonthlyPrice', { min: 0, label: 'custom price' });
    const trialEnd = typeof b.trialEndsAt === 'string' ? b.trialEndsAt : undefined;
    if (trialEnd && !isYmd(trialEnd)) throw bad('Trial end date is not valid');
    const { store } = c.var.deps;
    if (saasPlanId && !(await store.get(P.saasPlan(saasPlanId)))) throw bad('Unknown plan');
    const out = await store.tx(async (t) => {
      const before = isUuid(id) ? await t.get<TenantDoc>(P.tenant(id)) : null;
      if (!before) throw notFound('Gym not found');
      const after: TenantDoc = {
        ...before,
        status: status ?? before.status,
        verified: verified ?? before.verified,
        saasPlanId: saasPlanId === undefined ? before.saasPlanId : saasPlanId,
        customMonthlyPrice: custom === undefined ? before.customMonthlyPrice : custom,
        trialEndsAt: trialEnd ? `${trialEnd}T18:29:59.000Z` : before.trialEndsAt,
      };
      t.set(P.tenant(id), after);
      audit(t, id, u.id, 'super.gym.update', 'tenant', id, before, after);
      return after;
    });
    return c.json({ id, ...out });
  });

  app.get('/api/v1/super/saas-plans', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const { store } = c.var.deps;
    const [plans, tenants, s] = await Promise.all([store.query<SaasPlan>(P.saasPlans), store.query<TenantDoc>('tenants'), store.get<{ trialMonths: number }>(P.platform)]);
    return c.json({
      trialMonths: s?.trialMonths ?? 3,
      plans: plans.map((p) => ({ ...p.data, id: p.id, _count: { tenants: tenants.filter((t) => t.data.saasPlanId === p.id).length } })).sort((a, b) => a.sortOrder - b.sortOrder),
    });
  });

  app.post('/api/v1/super/saas-plans', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const b = body(await c.req.json().catch(() => null));
    const id = uuid();
    const p = { ...planFields(b, false), createdAt: nowIso() };
    await c.var.deps.store.tx(async (t) => {
      t.set(P.saasPlan(id), p);
      audit(t, null, u.id, 'saas_plan.create', 'saas_plan', id, null, p);
    });
    return c.json({ id, ...p }, 201);
  });

  /** Price changes apply to new gyms now and to existing gyms at their next renewal. */
  app.patch('/api/v1/super/saas-plans/:id', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const patch = planFields(b, true);
    const out = await c.var.deps.store.tx(async (t) => {
      const before = isUuid(id) ? await t.get<SaasPlan>(P.saasPlan(id)) : null;
      if (!before) throw notFound('Plan not found');
      const after = { ...before, ...patch };
      t.set(P.saasPlan(id), after);
      audit(t, null, u.id, 'saas_plan.update', 'saas_plan', id, before, after);
      return after;
    });
    return c.json({ ...out, id });
  });

  app.patch('/api/v1/super/settings', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const b = body(await c.req.json().catch(() => null));
    const patch: Record<string, unknown> = {};
    if (b.trialMonths !== undefined) patch.trialMonths = int(b, 'trialMonths', { min: 0, max: 24, label: 'trial months' });
    if (b.supportWhatsapp !== undefined) {
      const w = optStr(b, 'supportWhatsapp', { max: 20 });
      const p = w ? normalizePhone(w) : null;
      if (w && !p) throw bad('Enter a valid WhatsApp number');
      patch.supportWhatsapp = p;
    }
    if (b.appUrl !== undefined) {
      const a = optStr(b, 'appUrl', { max: 300 }) ?? null;
      if (a && !/^https:\/\/\S+$/.test(a)) throw bad('App link must start with https://');
      patch.appUrl = a;
    }
    if (b.businessName !== undefined) patch.businessName = optStr(b, 'businessName', { max: 120 }) ?? null;
    if (b.businessAddress !== undefined) patch.businessAddress = optStr(b, 'businessAddress', { max: 300 }) ?? null;
    if (b.businessPan !== undefined) {
      const pan = (optStr(b, 'businessPan', { max: 10 }) ?? '').toUpperCase();
      if (pan && !/^[A-Z]{5}\d{4}[A-Z]$/.test(pan)) throw bad('PAN is not valid');
      patch.businessPan = pan || null;
    }
    if (b.upiId !== undefined) {
      const upi = (optStr(b, 'upiId', { max: 60 }) ?? '').trim();
      if (upi && !/^[\w.-]{2,}@[a-zA-Z][\w.-]*$/.test(upi)) throw bad('UPI ID is not valid');
      patch.upiId = upi || null;
    }
    const out = await c.var.deps.store.tx(async (t) => {
      const before = await t.get(P.platform);
      const after = { ...(before ?? {}), ...patch };
      t.set(P.platform, after);
      audit(t, null, u.id, 'settings.update', 'platform_settings', '1', before, after);
      return after;
    });
    return c.json(out);
  });

  /** GymMantra-wide report: plan income, new gyms, gyms by plan, tickets, top gyms. ?days=7|30|90|365 or ?from&to. */
  app.get('/api/v1/super/reports', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const { store } = c.var.deps;
    const { from, to, days, custom } = reportRange((k) => c.req.query(k), [7, 30, 90, 365]);
    const dates = Array.from({ length: days }, (_, i) => addDays(from, i));
    const [tenants, daily, tickets, plans] = await Promise.all([
      store.query<TenantDoc>('tenants'),
      store.getMany<{ income?: number; bills?: number }>(dates.map((d) => P.platformDaily(d))),
      store.query<Ticket>(P.tickets),
      store.query<SaasPlan>(P.saasPlans),
    ]);
    const planName = new Map(plans.map((p) => [p.id, p.data.name]));
    const now = Date.now();
    const newByDay = new Map<string, number>();
    for (const t of tenants) {
      const d = todayIST(new Date(t.data.createdAt));
      if (d >= from && d <= to) newByDay.set(d, (newByDay.get(d) ?? 0) + 1);
    }
    const series = dates.map((date, i) => ({ date, income: daily[i]?.income ?? 0, bills: daily[i]?.bills ?? 0, newGyms: newByDay.get(date) ?? 0 }));
    const byPlan: Record<string, number> = {};
    let activeGyms = 0;
    for (const t of tenants) {
      if (t.data.status === 'SUSPENDED') {
        byPlan.Suspended = (byPlan.Suspended ?? 0) + 1;
        continue;
      }
      const g = t.data;
      const inTrial = g.status === 'TRIAL' && (!g.trialEndsAt || Date.parse(g.trialEndsAt) > now);
      const paid = !inTrial && g.status === 'ACTIVE' && !!g.saasPlanId && planName.has(g.saasPlanId) && (!g.planEndsAt || Date.parse(g.planEndsAt) > now);
      const k = inTrial ? 'Trial' : paid ? planName.get(g.saasPlanId!)! : 'Expired';
      byPlan[k] = (byPlan[k] ?? 0) + 1;
      if (inTrial || paid) activeGyms++;
    }
    const tk = { OPEN: 0, IN_PROGRESS: 0, WAITING: 0, RESOLVED: 0, CLOSED: 0 } as Record<string, number>;
    for (const r of tickets) {
      const d = todayIST(new Date(r.data.createdAt));
      if (d < from || d > to) continue;
      const st = ticketStatus(r.data);
      tk[st] = (tk[st] ?? 0) + 1;
    }
    return c.json({
      days,
      custom,
      from,
      to,
      series,
      totals: {
        income: series.reduce((n, x) => n + x.income, 0),
        bills: series.reduce((n, x) => n + x.bills, 0),
        newGyms: series.reduce((n, x) => n + x.newGyms, 0),
        gyms: tenants.length,
        activeGyms,
        members: tenants.reduce((n, t) => n + (t.data.memberCount ?? 0), 0),
      },
      byPlan: Object.entries(byPlan).map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count),
      tickets: tk,
      topGyms: tenants
        .map((t) => ({ id: t.id, name: t.data.name, gymCode: t.data.gymCode, city: t.data.city ?? null, members: t.data.memberCount ?? 0 }))
        .sort((a, b) => b.members - a.members)
        .slice(0, 10),
    });
  });

  /** Find a person by mobile number or email (GM Admin → People). */
  app.get('/api/v1/super/users', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const { store } = c.var.deps;
    const q = (c.req.query('q') ?? '').trim();
    if (q.length < 3) return c.json([]);
    const email = normalizeEmail(q);
    const phone = email ? null : normalizePhone(q);
    const ids = new Set<string>();
    if (phone) {
      const ref = await store.get<{ uid: string }>(P.phone(phone));
      if (ref) ids.add(ref.uid);
      for (const r of await store.query<UserDoc>('users', [['phone', phone]])) ids.add(r.id);
    } else if (email) {
      for (const r of await store.query<UserDoc>('users', [['email', email]])) ids.add(r.id);
      for (const r of await store.query<UserDoc>('users', [['authEmail', email]])) ids.add(r.id);
    } else {
      throw bad('Type a full mobile number or email');
    }
    const users = await store.getMany<UserDoc>([...ids].map(P.user));
    const rows = [...ids].map((id, i) => ({ id, u: users[i] })).filter((x) => x.u && !x.u.deleted);
    const tids = [...new Set(rows.flatMap((x) => [...Object.keys(x.u!.memberships ?? {}), ...Object.keys(x.u!.staffOf ?? {})]))];
    const tenants = await store.getMany<TenantDoc>(tids.map(P.tenant));
    const nameOf = (t: string) => tenants[tids.indexOf(t)]?.name ?? 'Gym';
    return c.json(
      rows.map(({ id, u }) => ({
        id,
        name: u!.name,
        email: u!.email,
        phone: u!.phone,
        appRole: u!.appRole ?? null,
        createdAt: u!.createdAt ?? null,
        google: !!u!.googleSub && !u!.authEmail,
        gyms: [
          ...Object.keys(u!.memberships ?? {}).map((t) => ({ name: nameOf(t), role: 'MEMBER' })),
          ...Object.entries(u!.staffOf ?? {}).filter(([, v]) => v.active).map(([t, v]) => ({ name: nameOf(t), role: v.role })),
        ],
        runsGym: Object.values(u!.staffOf ?? {}).some((v) => v.active && v.role !== 'TRAINER'),
      })),
    );
  });

  /** Super admin deletes a person's account, so the same mobile and email can sign up again. */
  app.post('/api/v1/super/users/:id/delete', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    if (id === u.id) throw bad('You cannot delete your own account here');
    const before = await c.var.deps.store.get<UserDoc>(P.user(id));
    await removeAccount(c.var.deps, id, { bySuper: true });
    await c.var.deps.store.tx(async (t) => {
      audit(t, null, u.id, 'user.delete', 'user', id, { name: before?.name, email: before?.email, phone: before?.phone }, null);
    });
    return c.json({ ok: true });
  });

  app.get('/api/v1/super/audit', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const rows = await c.var.deps.store.query<{ createdAt: string }>(P.platformAudit, [['month', new Date().toISOString().slice(0, 7)]]);
    return c.json(rows.map((r) => ({ id: r.id, ...r.data })).sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)));
  });
}
