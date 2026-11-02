import { App, audit, authenticate, gymOf, notify, P, requireSuper, Role, TenantDoc, UserDoc } from '../core';
import { addDays, addMonths, isYmd, todayIST } from '../lib/dates';
import { bad, forbidden, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { body, int, oneOf, optBool, optInt, optStr, str } from '../lib/validate';
import { stateByName } from '../lib/india';
import type { Reader, Tx } from '../store/store';
import type { SaasPlan } from './gym';

// ---------- GymMantra subscription: plan features, trial, bills (receipts), GST switch ----------

export const FEATURE_KEYS = ['offers', 'pt', 'reports', 'branches'] as const;
export type FeatureKey = (typeof FEATURE_KEYS)[number];

/** Which features a plan unlocks. Older plans without the list are read by their name. */
export function unlocksOf(plan: Pick<SaasPlan, 'name'> & { unlocks?: string[] }): FeatureKey[] {
  if (Array.isArray(plan.unlocks)) return plan.unlocks.filter((k): k is FeatureKey => (FEATURE_KEYS as readonly string[]).includes(k));
  const n = plan.name.toLowerCase();
  if (n.includes('starter')) return [];
  if (n.includes('growth')) return ['offers', 'pt'];
  return [...FEATURE_KEYS];
}

export type Ring = 'trial' | 'starter' | 'growth' | 'pro' | 'none';

export async function gymAccess(r: Reader, t: TenantDoc) {
  const now = Date.now();
  const trialEnd = t.trialEndsAt ? Date.parse(t.trialEndsAt) : null;
  const inTrial = t.status === 'TRIAL' && (trialEnd === null || trialEnd > now);
  const plan = t.saasPlanId ? await r.get<SaasPlan & { unlocks?: string[] }>(P.saasPlan(t.saasPlanId)) : null;
  const planActive = !inTrial && !!plan && t.status === 'ACTIVE' && (!t.planEndsAt || Date.parse(t.planEndsAt) > now);
  const unlocks: FeatureKey[] = inTrial ? [...FEATURE_KEYS] : planActive ? unlocksOf(plan!) : [];
  let ring: Ring = 'none';
  if (inTrial) ring = 'trial';
  else if (planActive) {
    const n = plan!.name.toLowerCase();
    ring = n.includes('starter') ? 'starter' : n.includes('pro') ? 'pro' : 'growth';
  }
  const created = Date.parse(t.createdAt);
  return {
    inTrial,
    trialEndsAt: t.trialEndsAt,
    trialDaysLeft: inTrial && trialEnd ? Math.max(0, Math.ceil((trialEnd - now) / 86400000)) : 0,
    trialTotalDays: trialEnd ? Math.max(1, Math.round((trialEnd - created) / 86400000)) : 90,
    plan: planActive ? { id: t.saasPlanId!, name: plan!.name } : null,
    planEndsAt: planActive ? t.planEndsAt ?? null : null,
    cycle: planActive ? t.planCycle ?? null : null,
    unlocks,
    ring,
    expired: !inTrial && !planActive,
  };
}

const FEATURE_PLAN: Record<FeatureKey, string> = { offers: 'Growth', pt: 'Growth', reports: 'Pro', branches: 'Pro' };
const FEATURE_NAME: Record<FeatureKey, string> = { offers: 'Offers', pt: 'Trainers and PT', reports: 'Reports', branches: 'More branches' };

/** Stops a locked feature with a clear message. */
export async function requireFeature(r: Reader, t: TenantDoc, key: FeatureKey) {
  const a = await gymAccess(r, t);
  if (!a.unlocks.includes(key)) throw forbidden(`${FEATURE_NAME[key]} is part of the ${FEATURE_PLAN[key]} plan. Upgrade in Subscription`);
}

// ---------- GST (off until GymMantra is registered) ----------

export interface GstSettings {
  registered: boolean;
  gstin: string | null;
  legalName: string | null;
  address: string | null;
  stateCode: string; // where GymMantra is registered (Delhi = 07)
  rate: number;
  from: string | null; // bills from this date get GST
  inclusive: boolean; // true = plan price already has GST in it
}
export interface PlatformSettings {
  trialMonths?: number;
  supportWhatsapp?: string | null;
  businessName?: string | null;
  businessAddress?: string | null;
  appUrl?: string | null; // where people download the app (Play Store or any link); used in gym share messages
  gst?: GstSettings;
}
export const DEFAULT_GST: GstSettings = { registered: false, gstin: null, legalName: null, address: null, stateCode: '07', rate: 18, from: null, inclusive: false };

const r2 = (n: number) => Math.round(n * 100) / 100;

export function billAmounts(price: number, gst: GstSettings | undefined, gymStateCode: string | null | undefined, today = todayIST()) {
  const on = !!gst?.registered && !!gst.gstin && (!gst.from || gst.from <= today);
  if (!on || !gst) return { taxable: price, total: price, gst: null };
  const taxable = gst.inclusive ? r2((price * 100) / (100 + gst.rate)) : price;
  const tax = gst.inclusive ? r2(price - taxable) : r2((price * gst.rate) / 100);
  const intra = (gymStateCode ?? gst.stateCode) === gst.stateCode;
  return {
    taxable,
    total: r2(taxable + tax),
    gst: intra
      ? { type: 'CGST_SGST' as const, rate: gst.rate, cgst: r2(tax / 2), sgst: r2(tax - r2(tax / 2)), igst: 0, gstin: gst.gstin, placeOfSupply: gymStateCode ?? gst.stateCode }
      : { type: 'IGST' as const, rate: gst.rate, cgst: 0, sgst: 0, igst: tax, gstin: gst.gstin, placeOfSupply: gymStateCode ?? '' },
  };
}

export interface BillDoc {
  id: string;
  number: string;
  kind: 'RECEIPT' | 'TAX_INVOICE';
  planId: string;
  planName: string;
  cycle: 'MONTHLY' | 'ANNUAL';
  periodStart: string;
  periodEnd: string;
  price: number;
  taxable: number;
  gst: ReturnType<typeof billAmounts>['gst'];
  total: number;
  mode: string;
  ref: string | null;
  paidAt: string;
  gym: { name: string; address: string | null; state: string | null; stateCode: string | null; pincode: string | null; gstin: string | null; ownerName: string | null; ownerPhone: string | null };
  seller: { name: string; address: string | null; gstin: string | null };
  createdById: string;
}

function fyOf(ymd: string) {
  const y = Number(ymd.slice(0, 4));
  const start = Number(ymd.slice(5, 7)) >= 4 ? y : y - 1;
  return `${String(start).slice(2)}-${String(start + 1).slice(2)}`;
}

async function nextNumber(t: Tx, kind: BillDoc['kind'], today: string) {
  const st = ((await t.get<Record<string, number>>(P.stats)) ?? {}) as Record<string, number>;
  const key = kind === 'TAX_INVOICE' ? `invoiceSeq_${fyOf(today)}` : 'receiptSeq';
  const n = (st[key] ?? 0) + 1;
  t.set(P.stats, { ...st, [key]: n });
  return kind === 'TAX_INVOICE' ? `GM/${fyOf(today)}/${String(n).padStart(4, '0')}` : `GM-R-${String(n).padStart(5, '0')}`;
}

const billSummary = (b: BillDoc) => ({ id: b.id, number: b.number, kind: b.kind, planName: b.planName, cycle: b.cycle, periodStart: b.periodStart, periodEnd: b.periodEnd, total: b.total, paidAt: b.paidAt });

export function billingRoutes(app: App) {
  /** Owner: plan, trial meter, features, bills. */
  app.get('/api/v1/subscription', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const { store } = c.var.deps;
    const [access, plans, bills, settings, trainers] = await Promise.all([
      gymAccess(store, g.tenant),
      store.query<SaasPlan & { unlocks?: string[] }>(P.saasPlans, [['visible', true]]),
      store.query<BillDoc>(P.bills(g.tenantId)),
      store.get<PlatformSettings>(P.platform),
      store.query(P.trainers(g.tenantId), [['active', true]]),
    ]);
    return c.json({
      ...access,
      plans: plans
        .map((p) => ({ id: p.id, name: p.data.name, monthlyPrice: p.data.monthlyPrice, annualPrice: p.data.annualPrice, memberLimit: p.data.memberLimit, branchLimit: p.data.branchLimit, features: p.data.features, unlocks: unlocksOf(p.data), sortOrder: p.data.sortOrder }))
        .sort((a, b) => a.sortOrder - b.sortOrder),
      bills: bills.map((b) => billSummary(b.data)).sort((a, b) => (a.paidAt < b.paidAt ? 1 : -1)),
      usage: { members: g.tenant.memberCount ?? 0, trainers: trainers.length, branches: g.tenant.branches.length },
      supportWhatsapp: settings?.supportWhatsapp ?? null,
      addressComplete: !!(g.tenant.state && g.tenant.city && g.tenant.pincode),
    });
  });

  app.get('/api/v1/subscription/bills/:id', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const id = c.req.param('id');
    const b = isUuid(id) ? await c.var.deps.store.get<BillDoc>(P.bill(g.tenantId, id)) : null;
    if (!b) throw notFound('Bill not found');
    return c.json(b);
  });

  // ---------------- super admin ----------------
  app.get('/api/v1/super/settings', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const s = (await c.var.deps.store.get<PlatformSettings>(P.platform)) ?? {};
    return c.json({ trialMonths: s.trialMonths ?? 3, supportWhatsapp: s.supportWhatsapp ?? null, appUrl: s.appUrl ?? null, businessName: s.businessName ?? 'GymMantra', businessAddress: s.businessAddress ?? 'New Delhi, Delhi', gst: { ...DEFAULT_GST, ...(s.gst ?? {}) } });
  });

  app.patch('/api/v1/super/gst', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const b = body(await c.req.json().catch(() => null));
    const out = await c.var.deps.store.tx(async (t) => {
      const before = (await t.get<PlatformSettings>(P.platform)) ?? {};
      const cur = { ...DEFAULT_GST, ...(before.gst ?? {}) };
      const next: GstSettings = { ...cur };
      const reg = optBool(b, 'registered');
      if (reg !== undefined) next.registered = reg;
      if (b.gstin !== undefined) {
        const v = (optStr(b, 'gstin', { max: 15 }) ?? '').toUpperCase();
        if (v && !/^\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/.test(v)) throw bad('GSTIN is not valid');
        next.gstin = v || null;
        if (v) next.stateCode = v.slice(0, 2);
      }
      if (b.legalName !== undefined) next.legalName = optStr(b, 'legalName', { max: 120 }) ?? null;
      if (b.address !== undefined) next.address = optStr(b, 'address', { max: 300 }) ?? null;
      if (b.rate !== undefined) next.rate = int(b, 'rate', { min: 0, max: 28, label: 'GST rate' });
      if (b.from !== undefined) {
        const f = optStr(b, 'from');
        if (f && !isYmd(f)) throw bad('Start date is not valid');
        next.from = f ?? null;
      }
      const inc = optBool(b, 'inclusive');
      if (inc !== undefined) next.inclusive = inc;
      if (next.registered && !next.gstin) throw bad('Enter the GSTIN before turning GST on');
      const after = { ...before, gst: next };
      t.set(P.platform, after);
      audit(t, null, u.id, 'settings.gst', 'platform_settings', 'gst', before.gst ?? null, next);
      return next;
    });
    return c.json(out);
  });

  app.get('/api/v1/super/gyms/:id', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    const { store } = c.var.deps;
    const t = isUuid(id) ? await store.get<TenantDoc>(P.tenant(id)) : null;
    if (!t) throw notFound('Gym not found');
    const [owners, bills, trainers, access] = await Promise.all([
      store.query<{ role: Role; active: boolean }>(P.staffCol(id), [['role', 'OWNER']]),
      store.query<BillDoc>(P.bills(id)),
      store.query(P.trainers(id), [['active', true]]),
      gymAccess(store, t),
    ]);
    const users = await store.getMany<UserDoc>(owners.filter((o) => o.data.active).map((o) => P.user(o.id)));
    return c.json({
      id,
      ...t,
      access,
      trainers: trainers.length,
      owners: users.filter(Boolean).map((u) => ({ name: u!.name, phone: u!.phone, email: u!.email })),
      bills: bills.map((b) => billSummary(b.data)).sort((a, b) => (a.paidAt < b.paidAt ? 1 : -1)),
    });
  });

  app.get('/api/v1/super/gyms/:id/bills/:billId', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    const bid = c.req.param('billId');
    const b = isUuid(id) && isUuid(bid) ? await c.var.deps.store.get<BillDoc>(P.bill(id, bid)) : null;
    if (!b) throw notFound('Bill not found');
    return c.json(b);
  });

  /** Super admin records a plan payment (until online payment is added). Makes the receipt. */
  app.post('/api/v1/super/gyms/:id/subscription', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const planId = str(b, 'planId', { label: 'a plan' });
    const cycle = oneOf(b, 'cycle', ['MONTHLY', 'ANNUAL'] as const)!;
    const mode = oneOf(b, 'mode', ['UPI', 'CASH', 'CARD', 'BANK_TRANSFER', 'FREE'] as const)!;
    const ref = optStr(b, 'ref', { max: 60 }) ?? null;
    const priceIn = optInt(b, 'price', { min: 0, max: 10_000_000, label: 'price' });
    const { store } = c.var.deps;
    const out = await store.tx(async (t) => {
      const tenant = isUuid(id) ? await t.get<TenantDoc>(P.tenant(id)) : null;
      if (!tenant) throw notFound('Gym not found');
      const plan = isUuid(planId) ? await t.get<SaasPlan>(P.saasPlan(planId)) : null;
      if (!plan) throw notFound('Plan not found');
      const settings = (await t.get<PlatformSettings>(P.platform)) ?? {};
      const today = todayIST();
      // Renewing the same plan early continues from its end date; a new plan starts today.
      const curEnd = tenant.saasPlanId === planId && tenant.planEndsAt && tenant.status === 'ACTIVE' && tenant.planEndsAt.slice(0, 10) >= today ? tenant.planEndsAt.slice(0, 10) : null;
      const startIn = optStr(b, 'startDate');
      if (startIn && !isYmd(startIn)) throw bad('Start date is not valid');
      const start = startIn ?? (curEnd ? addDays(curEnd, 1) : today);
      const end = addDays(addMonths(start, cycle === 'ANNUAL' ? 12 : 1), -1);
      const price = priceIn ?? (mode === 'FREE' ? 0 : cycle === 'ANNUAL' ? plan.annualPrice : plan.monthlyPrice);
      const amt = billAmounts(price, settings.gst, tenant.stateCode ?? (tenant.state ? stateByName(tenant.state)?.code : null));
      const kind: BillDoc['kind'] = amt.gst ? 'TAX_INVOICE' : 'RECEIPT';
      const owners = (await t.query<{ role: Role; active: boolean }>(P.staffCol(id), [['role', 'OWNER']])).filter((o) => o.data.active);
      const owner = owners[0] ? await t.get<UserDoc>(P.user(owners[0].id)) : null;
      const bill: BillDoc = {
        id: uuid(),
        number: await nextNumber(t, kind, today),
        kind,
        planId,
        planName: plan.name,
        cycle,
        periodStart: start,
        periodEnd: end,
        price,
        taxable: amt.taxable,
        gst: amt.gst,
        total: amt.total,
        mode,
        ref,
        paidAt: nowIso(),
        gym: {
          name: tenant.name,
          address: [tenant.addressLine ?? tenant.address, tenant.city, tenant.pincode].filter(Boolean).join(', ') || null,
          state: tenant.state ?? null,
          stateCode: tenant.stateCode ?? null,
          pincode: tenant.pincode ?? null,
          gstin: tenant.gstin ?? null,
          ownerName: owner?.name ?? null,
          ownerPhone: owner?.phone ?? null,
        },
        seller: { name: settings.gst?.registered ? settings.gst.legalName ?? settings.businessName ?? 'GymMantra' : settings.businessName ?? 'GymMantra', address: settings.gst?.registered ? settings.gst.address ?? settings.businessAddress ?? null : settings.businessAddress ?? 'New Delhi, Delhi', gstin: amt.gst ? settings.gst?.gstin ?? null : null },
        createdById: u.id,
      };
      t.set(P.bill(id, bill.id), JSON.parse(JSON.stringify(bill)));
      const after: TenantDoc = { ...tenant, status: 'ACTIVE', saasPlanId: planId, planCycle: cycle, planEndsAt: `${end}T18:29:59.000Z` };
      t.set(P.tenant(id), after);
      for (const o of owners) await notify(t, o.id, id, 'Plan activated', `${plan.name} plan is active till ${end}. Your receipt is in Subscription.`);
      audit(t, id, u.id, 'super.subscription', 'tenant', id, tenant, after);
      return bill;
    });
    return c.json(out, 201);
  });
}
