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
  id: string; // idempotency key from the app (one per "Pay" tap)
  payId: string; // GM-LIFE951-4821, goes in the UPI note so the payment can be found in the bank history
  tenantId: string;
  gymName: string;
  gymCode: string;
  planId: string;
  planName: string;
  cycle: 'MONTHLY' | 'ANNUAL';
  rate: number;
  discount: number;
  couponCode: string | null;
  amount: number; // what the owner pays (incl. GST if on)
  upiId: string;
  app: string | null;
  upiStatus: string | null; // what the UPI app said (SUCCESS / FAILURE / SUBMITTED / none)
  upiRef: string | null; // transaction ref from the UPI app, when it gives one
  status: 'STARTED' | 'PAID' | 'FAILED' | 'CANCELLED';
  reason: string | null;
  billId: string | null;
  before: Pick<TenantDoc, 'status' | 'saasPlanId' | 'planCycle' | 'planEndsAt'> | null; // to undo a cancelled payment
  byId: string;
  createdAt: string;
  paidAt: string | null;
  cancelledAt: string | null;
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

/** One more failed / cancelled payment; 3 in 24 hours pause payments for 24 hours. */
function withFail(tenant: TenantDoc): TenantDoc {
  const since = Date.now() - LOCK_HOURS * 3600_000;
  const fails = [...(tenant.payFails ?? []).filter((x) => Date.parse(x) > since), nowIso()];
  const lock = fails.length >= MAX_FAILS ? new Date(Date.now() + LOCK_HOURS * 3600_000).toISOString() : tenant.payLockedUntil ?? null;
  return { ...tenant, payFails: fails, payLockedUntil: lock };
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

  /**
   * Owner taps Pay: makes (or returns) the payment for this idempotency key. The same key always
   * gives the same payment, so a double tap or a retry never makes two.
   */
  app.post('/api/v1/subscription/payments', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const key = str(b, 'key', { min: 8, max: 64, label: 'the payment key' });
    if (!/^[A-Za-z0-9-]{8,64}$/.test(key)) throw bad('Payment key is not valid');
    const existing = await c.var.deps.store.get<PlanPaymentDoc>(P.planPayment(key));
    if (existing) {
      const g0 = await gymOf(c, 'OWNER');
      if (existing.tenantId !== g0.tenantId) throw forbidden('Not your payment');
      return c.json(existing);
    }
    const q = await quote(c as unknown as C, b);
    const out = await c.var.deps.store.tx(async (t) => {
      const again = await t.get<PlanPaymentDoc>(P.planPayment(key));
      if (again) return again;
      const tenant = (await t.get<TenantDoc>(P.tenant(q.g.tenantId)))!;
      const locked = lockOf(tenant);
      if (locked) throw forbidden(`Payments are paused for 24 hours after 3 failed payments. Try again after ${new Date(locked).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour: 'numeric', minute: '2-digit', day: 'numeric', month: 'short' })}`);
      const doc: PlanPaymentDoc = {
        id: key,
        payId: `GM-${tenant.gymCode}-${1000 + Math.floor(Math.random() * 9000)}`,
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
        upiId: q.out.upiId,
        app: null,
        upiStatus: null,
        upiRef: null,
        status: 'STARTED',
        reason: null,
        billId: null,
        before: null,
        byId: u.id,
        createdAt: nowIso(),
        paidAt: null,
        cancelledAt: null,
      };
      t.create(P.planPayment(key), doc);
      return doc;
    });
    return c.json({ ...out, payeeName: q.out.payeeName }, 201);
  });

  /**
   * Back from the UPI app: the plan turns on at once and the receipt is made.
   * If the UPI app said the payment failed, nothing is turned on.
   */
  app.post('/api/v1/subscription/payments/:key/done', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const key = c.req.param('key');
    const b = body(await c.req.json().catch(() => ({})));
    const upiStatus = (optStr(b, 'upiStatus', { max: 30 }) ?? '').toUpperCase() || null;
    const upiRef = optStr(b, 'upiRef', { max: 60 }) ?? null;
    const appName = optStr(b, 'app', { max: 40 }) ?? null;
    const out = await c.var.deps.store.tx(async (t) => {
      const p = await t.get<PlanPaymentDoc>(P.planPayment(key));
      if (!p || p.tenantId !== g.tenantId) throw notFound('Payment not found');
      if (p.status !== 'STARTED') return { payment: p, bill: p.billId ? await t.get(P.bill(p.tenantId, p.billId)) : null }; // already done: same answer again
      if (upiStatus === 'FAILURE' || upiStatus === 'FAILED') {
        const tenant = (await t.get<TenantDoc>(P.tenant(p.tenantId)))!;
        t.set(P.tenant(p.tenantId), withFail(tenant));
        const failed: PlanPaymentDoc = { ...p, status: 'FAILED', app: appName, upiStatus, upiRef, reason: 'The UPI app said the payment failed' };
        t.set(P.planPayment(key), failed);
        return { payment: failed, bill: null };
      }
      const tenant = (await t.get<TenantDoc>(P.tenant(p.tenantId)))!;
      let coupon: CouponDoc | null = null;
      if (p.couponCode) {
        const idx = await t.get<{ id: string }>(P.couponCode(p.couponCode));
        coupon = idx ? await t.get<CouponDoc>(P.coupon(idx.id)) : null;
      }
      const bill = await activatePlan(t, { tenantId: p.tenantId, planId: p.planId, cycle: p.cycle, mode: 'UPI', ref: upiRef ?? p.payId, price: p.rate, discount: p.discount, couponCode: p.couponCode, byId: u.id });
      if (coupon) t.set(P.coupon(coupon.id), { ...coupon, used: coupon.used + 1, usedBy: { ...coupon.usedBy, [p.tenantId]: (coupon.usedBy[p.tenantId] ?? 0) + 1 } });
      const paid: PlanPaymentDoc = {
        ...p,
        status: 'PAID',
        app: appName,
        upiStatus,
        upiRef,
        billId: bill.id,
        paidAt: nowIso(),
        before: { status: tenant.status, saasPlanId: tenant.saasPlanId, planCycle: tenant.planCycle ?? null, planEndsAt: tenant.planEndsAt ?? null },
      };
      t.set(P.planPayment(key), paid);
      return { payment: paid, bill };
    });
    return c.json(out);
  });

  app.get('/api/v1/subscription/payments', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const rows = await c.var.deps.store.query<PlanPaymentDoc>(P.planPayments, [['tenantId', g.tenantId]]);
    return c.json({ lockedUntil: lockOf(g.tenant), payments: rows.map((r) => r.data).filter((p) => p.status !== 'STARTED').sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)).slice(0, 30) });
  });

  // ---------------- super admin: every plan payment, and undo a payment that never came ----------------
  app.get('/api/v1/super/payments', async (c) => {
    await authenticate(c);
    requireSuper(c);
    const status = oneOf({ s: c.req.query('status') ?? 'PAID' }, 's', ['PAID', 'CANCELLED', 'FAILED'] as const)!;
    const rows = await c.var.deps.store.query<PlanPaymentDoc>(P.planPayments, [['status', status]]);
    const list = rows.map((r) => r.data).sort((a, b) => ((a.paidAt ?? a.createdAt) < (b.paidAt ?? b.createdAt) ? 1 : -1));
    const month = todayIST().slice(0, 7);
    const thisMonth = list.filter((p) => todayIST(new Date(p.paidAt ?? p.createdAt)).slice(0, 7) === month);
    return c.json({ status, monthTotal: thisMonth.reduce((n, p) => n + p.amount, 0), monthCount: thisMonth.length, payments: list.slice(0, 200) });
  });

  app.post('/api/v1/super/payments/:id/cancel', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => ({})));
    const reason = optStr(b, 'reason', { max: 200 }) ?? 'Payment not received';
    const out = await c.var.deps.store.tx(async (t) => {
      const p = await t.get<PlanPaymentDoc>(P.planPayment(id));
      if (!p) throw notFound('Payment not found');
      if (p.status !== 'PAID') throw bad('Only a paid payment can be cancelled');
      const tenant = await t.get<TenantDoc>(P.tenant(p.tenantId));
      if (tenant) {
        const b4 = p.before ?? { status: 'TRIAL' as const, saasPlanId: null, planCycle: null, planEndsAt: null };
        // Undo the plan only if this payment's plan is still the current one.
        const undo = tenant.saasPlanId === p.planId;
        const next: TenantDoc = withFail(undo ? { ...tenant, status: b4.status, saasPlanId: b4.saasPlanId, planCycle: b4.planCycle, planEndsAt: b4.planEndsAt } : tenant);
        t.set(P.tenant(p.tenantId), next);
        audit(t, p.tenantId, u.id, 'plan.payment.cancel', 'plan_payment', id, tenant, next);
      }
      if (p.billId) {
        const bill = await t.get<Record<string, unknown>>(P.bill(p.tenantId, p.billId));
        if (bill) t.set(P.bill(p.tenantId, p.billId), { ...bill, cancelledAt: nowIso(), cancelReason: reason });
      }
      if (p.couponCode) {
        const idx = await t.get<{ id: string }>(P.couponCode(p.couponCode));
        const cp = idx ? await t.get<CouponDoc>(P.coupon(idx.id)) : null;
        if (cp) t.set(P.coupon(cp.id), { ...cp, used: Math.max(0, cp.used - 1), usedBy: { ...cp.usedBy, [p.tenantId]: Math.max(0, (cp.usedBy[p.tenantId] ?? 1) - 1) } });
      }
      const owners = (await t.query<{ role: Role; active: boolean }>(P.staffCol(p.tenantId), [['role', 'OWNER']])).filter((x) => x.data.active);
      for (const o of owners) await notify(t, o.id, p.tenantId, 'Payment not received', `We did not receive your UPI payment of ₹${p.amount} (${p.payId}). ${reason}. Your ${p.planName} plan is stopped — please pay again.`);
      const done: PlanPaymentDoc = { ...p, status: 'CANCELLED', reason, cancelledAt: nowIso() };
      t.set(P.planPayment(id), done);
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
