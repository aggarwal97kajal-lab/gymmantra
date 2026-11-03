import { App, audit, authenticate, C, gymOf, notify, P, requireSuper, Role, TenantDoc } from '../core';
import { isYmd, todayIST } from '../lib/dates';
import { bad, conflict, forbidden, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { body, int, oneOf, optBool, optInt, optStr, str, strList } from '../lib/validate';
import { stateByName } from '../lib/india';
import type { Reader, Tx } from '../store/store';
import type { SaasPlan } from './gym';
import { activatePlan, billAmounts, DEFAULT_UPI, type PlatformSettings } from './billing';

// ---------- Coupons (super admin makes, gym owner uses) and UPI plan payments ----------

export interface CouponDoc {
  id: string;
  code: string;
  kind: 'PERCENT' | 'AMOUNT';
  value: number;
  planIds: string[]; // empty = all plans
  validTill: string; // last day (YYYY-MM-DD)
  maxUses: number | null;
  oncePerGym: boolean;
  used: number;
  usedBy: Record<string, number>; // tenantId -> times used
  active: boolean;
  createdAt: string;
}

export interface PlanPaymentDoc {
  id: string;
  tenantId: string;
  gymName: string;
  gymCode: string;
  planId: string;
  planName: string;
  cycle: 'MONTHLY' | 'ANNUAL';
  rate: number;
  discount: number;
  couponCode: string | null;
  amount: number; // what the owner paid (incl. GST if on)
  utr: string;
  app: string | null;
  status: 'PENDING' | 'APPROVED' | 'REJECTED';
  reason: string | null;
  billId: string | null;
  byId: string;
  createdAt: string;
  decidedAt: string | null;
}

const MAX_FAILS = 3;
const LOCK_HOURS = 24;

export const couponCodeOf = (s: string) => s.trim().toUpperCase().replace(/\s+/g, '');

const couponView = (c: CouponDoc) => ({ ...c, live: c.active && c.validTill >= todayIST() && (c.maxUses === null || c.used < c.maxUses) });

/** Checks a coupon for this gym and plan and says how much it takes off. */
export async function priceWithCoupon(r: Reader, o: { tenantId: string; plan: SaasPlan & { id: string }; cycle: 'MONTHLY' | 'ANNUAL'; code: string | null | undefined }) {
  const rate = o.cycle === 'ANNUAL' ? o.plan.annualPrice : o.plan.monthlyPrice;
  if (!o.code) return { rate, discount: 0, coupon: null as CouponDoc | null };
  const code = couponCodeOf(o.code);
  const idx = await r.get<{ id: string }>(P.couponCode(code));
  const c = idx ? await r.get<CouponDoc>(P.coupon(idx.id)) : null;
  if (!c || !c.active) throw bad('This coupon code is not valid');
  if (c.validTill < todayIST()) throw bad('This coupon has ended');
  if (c.maxUses !== null && c.used >= c.maxUses) throw bad('This coupon has been used up');
  if (c.planIds.length && !c.planIds.includes(o.plan.id)) throw bad(`This coupon is not for the ${o.plan.name} plan`);
  if (c.oncePerGym && (c.usedBy[o.tenantId] ?? 0) > 0) throw bad('Your gym has already used this coupon');
  const discount = Math.min(rate, c.kind === 'PERCENT' ? Math.round((rate * c.value) / 100) : c.value);
  return { rate, discount, coupon: c };
}

function lockOf(t: TenantDoc) {
  const until = t.payLockedUntil && Date.parse(t.payLockedUntil) > Date.now() ? t.payLockedUntil : null;
  return until;
}

function readCoupon(b: Record<string, unknown>, cur?: CouponDoc) {
  const code = b.code !== undefined || !cur ? couponCodeOf(str(b, 'code', { min: 3, max: 20, label: 'the coupon code' })) : cur.code;
  if (!/^[A-Z0-9-]{3,20}$/.test(code)) throw bad('Use only letters and numbers in the code');
  const kind = oneOf(b, 'kind', ['PERCENT', 'AMOUNT'] as const, true) ?? cur?.kind ?? 'PERCENT';
  const value = b.value !== undefined || !cur ? int(b, 'value', { min: 1, max: kind === 'PERCENT' ? 100 : 1_000_000, label: 'the discount' }) : cur.value;
  if (kind === 'PERCENT' && value > 100) throw bad('Percent must be 100 or less');
  const planIds = b.planIds !== undefined ? strList(b, 'planIds', 20) ?? [] : cur?.planIds ?? [];
  const validTill = b.validTill !== undefined || !cur ? str(b, 'validTill', { label: 'the last date' }) : cur.validTill;
  if (!isYmd(validTill)) throw bad('Last date is not valid');
  const maxUses = b.maxUses === null ? null : b.maxUses !== undefined ? optInt(b, 'maxUses', { min: 1, max: 1_000_000, label: 'max uses' }) ?? null : cur?.maxUses ?? null;
  const oncePerGym = optBool(b, 'oncePerGym') ?? cur?.oncePerGym ?? true;
  const active = optBool(b, 'active') ?? cur?.active ?? true;
  return { code, kind, value, planIds, validTill, maxUses, oncePerGym, active };
}

export function paymentRoutes(app: App) {
  // ---------------- super admin: coupons ----------------
  app.get('/api/v1/super/coupons', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const rows = await c.var.deps.store.query<CouponDoc>(P.coupons);
    return c.json(rows.map((r) => couponView(r.data)).sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)));
  });

  app.post('/api/v1/super/coupons', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const f = readCoupon(body(await c.req.json().catch(() => null)));
    const out = await c.var.deps.store.tx(async (t) => {
      if (await t.get(P.couponCode(f.code))) throw conflict('A coupon with this code already exists');
      const doc: CouponDoc = { id: uuid(), ...f, used: 0, usedBy: {}, createdAt: nowIso() };
      t.create(P.couponCode(f.code), { id: doc.id });
      t.set(P.coupon(doc.id), doc);
      audit(t, null, u.id, 'coupon.create', 'coupon', doc.id, null, doc);
      return doc;
    });
    return c.json(couponView(out), 201);
  });

  app.patch('/api/v1/super/coupons/:id', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const out = await c.var.deps.store.tx(async (t) => {
      const cur = isUuid(id) ? await t.get<CouponDoc>(P.coupon(id)) : null;
      if (!cur) throw notFound('Coupon not found');
      const f = readCoupon(b, cur);
      if (f.code !== cur.code) {
        if (await t.get(P.couponCode(f.code))) throw conflict('A coupon with this code already exists');
        t.delete(P.couponCode(cur.code));
        t.create(P.couponCode(f.code), { id });
      }
      const after = { ...cur, ...f };
      t.set(P.coupon(id), after);
      audit(t, null, u.id, 'coupon.update', 'coupon', id, cur, after);
      return after;
    });
    return c.json(couponView(out));
  });

  app.delete('/api/v1/super/coupons/:id', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    await c.var.deps.store.tx(async (t) => {
      const cur = isUuid(id) ? await t.get<CouponDoc>(P.coupon(id)) : null;
      if (!cur) throw notFound('Coupon not found');
      t.delete(P.coupon(id));
      t.delete(P.couponCode(cur.code));
      audit(t, null, u.id, 'coupon.delete', 'coupon', id, cur, null);
    });
    return c.json({ ok: true });
  });

  // ---------------- gym owner: price with coupon, pay by UPI ----------------
  async function quote(c: C, b: Record<string, unknown>) {
    const g = await gymOf(c, 'OWNER');
    const { store } = c.var.deps;
    const planId = str(b, 'planId', { label: 'a plan' });
    const cycle = oneOf(b, 'cycle', ['MONTHLY', 'ANNUAL'] as const)!;
    const plan = isUuid(planId) ? await store.get<SaasPlan>(P.saasPlan(planId)) : null;
    if (!plan || !plan.visible) throw notFound('Plan not found');
    const code = optStr(b, 'coupon', { max: 20 }) ?? null;
    const [p, settings] = await Promise.all([priceWithCoupon(store, { tenantId: g.tenantId, plan: { ...plan, id: planId }, cycle, code }), store.get<PlatformSettings>(P.platform)]);
    const amt = billAmounts(p.rate - p.discount, settings?.gst, g.tenant.stateCode ?? (g.tenant.state ? stateByName(g.tenant.state)?.code : null));
    return {
      g,
      plan: { ...plan, id: planId },
      cycle,
      out: {
        planId,
        planName: plan.name,
        cycle,
        rate: p.rate,
        discount: p.discount,
        coupon: p.coupon ? { code: p.coupon.code, kind: p.coupon.kind, value: p.coupon.value } : null,
        taxable: amt.taxable,
        gst: amt.gst,
        total: amt.total,
        upiId: settings?.upiId ?? DEFAULT_UPI,
        payeeName: settings?.businessName ?? 'GymMantra',
        lockedUntil: lockOf(g.tenant),
      },
    };
  }

  app.post('/api/v1/subscription/quote', async (c) => {
    await authenticate(c);
    const q = await quote(c as unknown as C, body(await c.req.json().catch(() => null)));
    return c.json(q.out);
  });

  /** Owner paid by UPI and sends the transaction ID (UTR). Super admin checks it and turns the plan on. */
  app.post('/api/v1/subscription/payments', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const q = await quote(c as unknown as C, b);
    const utr = str(b, 'utr', { min: 6, max: 30, label: 'the UPI transaction ID' }).replace(/\s/g, '');
    if (!/^[A-Za-z0-9]{6,30}$/.test(utr)) throw bad('Enter the 12-digit UPI transaction ID (UTR) from your UPI app');
    const appName = optStr(b, 'app', { max: 30 }) ?? null;
    const out = await c.var.deps.store.tx(async (t) => {
      const tenant = (await t.get<TenantDoc>(P.tenant(q.g.tenantId)))!;
      const locked = lockOf(tenant);
      if (locked) throw forbidden(`Payments are paused for 24 hours after 3 failed payments. Try again after ${new Date(locked).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour: 'numeric', minute: '2-digit', day: 'numeric', month: 'short' })}`);
      const mine = await t.query<PlanPaymentDoc>(P.planPayments, [['tenantId', q.g.tenantId]]);
      if (mine.some((r) => r.data.status === 'PENDING')) throw conflict('Your last payment is still being checked. You will get a notification soon');
      const dupe = await t.query<PlanPaymentDoc>(P.planPayments, [['utr', utr]]);
      if (dupe.some((r) => r.data.status !== 'REJECTED')) throw conflict('This transaction ID is already used');
      const doc: PlanPaymentDoc = {
        id: uuid(),
        tenantId: q.g.tenantId,
        gymName: tenant.name,
        gymCode: tenant.gymCode,
        planId: q.out.planId,
        planName: q.out.planName,
        cycle: q.cycle,
        rate: q.out.rate,
        discount: q.out.discount,
        couponCode: q.out.coupon?.code ?? null,
        amount: q.out.total,
        utr,
        app: appName,
        status: 'PENDING',
        reason: null,
        billId: null,
        byId: u.id,
        createdAt: nowIso(),
        decidedAt: null,
      };
      t.set(P.planPayment(doc.id), doc);
      audit(t, q.g.tenantId, u.id, 'plan.payment', 'plan_payment', doc.id, null, doc);
      return doc;
    });
    return c.json(out, 201);
  });

  app.get('/api/v1/subscription/payments', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const rows = await c.var.deps.store.query<PlanPaymentDoc>(P.planPayments, [['tenantId', g.tenantId]]);
    return c.json({ lockedUntil: lockOf(g.tenant), payments: rows.map((r) => r.data).sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)).slice(0, 20) });
  });

  // ---------------- super admin: check UPI payments ----------------
  app.get('/api/v1/super/payments', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const status = oneOf({ s: c.req.query('status') ?? 'PENDING' }, 's', ['PENDING', 'APPROVED', 'REJECTED'] as const)!;
    const rows = await c.var.deps.store.query<PlanPaymentDoc>(P.planPayments, [['status', status]]);
    return c.json(rows.map((r) => r.data).sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)).slice(0, 100));
  });

  app.post('/api/v1/super/payments/:id/:action', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    const action = oneOf({ a: c.req.param('action') }, 'a', ['approve', 'reject'] as const)!;
    const b = body(await c.req.json().catch(() => ({})));
    const reason = optStr(b, 'reason', { max: 200 }) ?? null;
    const out = await c.var.deps.store.tx(async (t) => {
      const p = isUuid(id) ? await t.get<PlanPaymentDoc>(P.planPayment(id)) : null;
      if (!p) throw notFound('Payment not found');
      if (p.status !== 'PENDING') throw bad('This payment is already checked');
      const owners = (await t.query<{ role: Role; active: boolean }>(P.staffCol(p.tenantId), [['role', 'OWNER']])).filter((x) => x.data.active);
      if (action === 'approve') {
        // Coupon is counted only when the payment is real.
        let coupon: CouponDoc | null = null;
        if (p.couponCode) {
          const idx = await t.get<{ id: string }>(P.couponCode(p.couponCode));
          coupon = idx ? await t.get<CouponDoc>(P.coupon(idx.id)) : null;
        }
        const bill = await activatePlan(t, { tenantId: p.tenantId, planId: p.planId, cycle: p.cycle, mode: 'UPI', ref: p.utr, price: p.rate, discount: p.discount, couponCode: p.couponCode, byId: u.id });
        if (coupon) t.set(P.coupon(coupon.id), { ...coupon, used: coupon.used + 1, usedBy: { ...coupon.usedBy, [p.tenantId]: (coupon.usedBy[p.tenantId] ?? 0) + 1 } });
        const done: PlanPaymentDoc = { ...p, status: 'APPROVED', billId: bill.id, decidedAt: nowIso() };
        t.set(P.planPayment(id), done);
        return done;
      }
      const tenant = await t.get<TenantDoc>(P.tenant(p.tenantId));
      if (tenant) {
        const since = Date.now() - LOCK_HOURS * 3600_000;
        const fails = [...(tenant.payFails ?? []).filter((x) => Date.parse(x) > since), nowIso()];
        const lock = fails.length >= MAX_FAILS ? new Date(Date.now() + LOCK_HOURS * 3600_000).toISOString() : tenant.payLockedUntil ?? null;
        t.set(P.tenant(p.tenantId), { ...tenant, payFails: fails, payLockedUntil: lock });
        for (const o of owners)
          await notify(t, o.id, p.tenantId, 'Payment not received', `We could not find your UPI payment of ₹${p.amount} (UTR ${p.utr}).${reason ? ` ${reason}.` : ''}${fails.length >= MAX_FAILS ? ' Payments are paused for 24 hours.' : ' Check the UTR and try again.'}`);
      }
      const done: PlanPaymentDoc = { ...p, status: 'REJECTED', reason, decidedAt: nowIso() };
      t.set(P.planPayment(id), done);
      audit(t, p.tenantId, u.id, 'plan.payment.reject', 'plan_payment', id, p, done);
      return done;
    });
    return c.json(out);
  });

  // ---------------- super admin: signature on every receipt ----------------
  app.put('/api/v1/super/signature', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const b = body(await c.req.json().catch(() => null));
    const dataUrl = b.dataUrl === null ? null : str(b, 'dataUrl', { max: 400_000, label: 'the signature' });
    if (dataUrl && !/^data:image\/(png|jpeg);base64,[A-Za-z0-9+/=]+$/.test(dataUrl)) throw bad('Signature must be a PNG or JPG picture');
    await c.var.deps.store.tx(async (t) => {
      if (dataUrl) t.set(P.signature, { dataUrl, updatedAt: nowIso() });
      else t.delete(P.signature);
      audit(t, null, u.id, 'settings.signature', 'platform_settings', 'signature', null, { set: !!dataUrl });
    });
    return c.json({ ok: true, signature: dataUrl });
  });
}

/** Coupon codes the super admin attaches to ads must exist. */
export async function couponExists(r: Reader, code: string) {
  return !!(await r.get(P.couponCode(couponCodeOf(code))));
}

export type { Tx };
