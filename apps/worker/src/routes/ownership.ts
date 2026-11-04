import { App, audit, authenticate, gymOf, isTrainer, notify, P, requireSuper, Role, TenantDoc, UserDoc } from '../core';
import type { Tx } from '../store/store';
import { bad, forbidden, isUuid, notFound, nowIso } from '../lib/http';
import { normalizePhone } from '../lib/phone';
import { body, oneOf, str } from '../lib/validate';

type StaffDoc = { userId: string; role: Role; branchIds: string[]; active: boolean; createdAt: string; rights?: string[] };

/**
 * Board 54: a gym can change hands (transfer) or be closed. After that the old owner is free,
 * so their account can be deleted from GM Admin → People.
 */
async function transfer(t: Tx, tenantId: string, actorId: string, newUid: string, from: string[], oldOwner: 'remove' | 'frontdesk') {
  const tenant = await t.get<TenantDoc>(P.tenant(tenantId));
  if (!tenant || tenant.status === 'CLOSED') throw notFound('Gym not found');
  const target = await t.get<UserDoc>(P.user(newUid));
  if (!target || target.deleted) throw notFound('No GymMantra account with this mobile number');
  if (isTrainer(target)) throw bad('This person is a trainer. A trainer cannot own a gym');
  if (from.includes(newUid)) throw bad('This person already owns this gym');
  const prev = await t.get<StaffDoc>(P.staff(tenantId, newUid));
  const nextOwner: StaffDoc = { userId: newUid, role: 'OWNER', branchIds: [], active: true, createdAt: prev?.createdAt ?? nowIso() };
  t.set(P.staff(tenantId, newUid), nextOwner);
  t.set(P.user(newUid), { ...target, appRole: 'OWNER', staffOf: { ...target.staffOf, [tenantId]: { role: 'OWNER', branchIds: [], active: true } } });
  for (const uid of from) {
    const s = await t.get<StaffDoc>(P.staff(tenantId, uid));
    const ou = await t.get<UserDoc>(P.user(uid));
    if (!s) continue;
    const first = tenant.branches[0]?.id;
    const after: StaffDoc =
      oldOwner === 'frontdesk' ? { ...s, role: 'FRONT_DESK', branchIds: first ? [first] : [], active: true, rights: ['members', 'memberEdit', 'payments', 'checkin', 'requests'] } : { ...s, active: false };
    t.set(P.staff(tenantId, uid), after);
    if (ou) {
      t.set(P.user(uid), { ...ou, staffOf: { ...ou.staffOf, [tenantId]: { role: after.role, branchIds: after.branchIds, active: after.active, rights: after.rights } } });
      await notify(t, uid, tenantId, 'Gym transferred', `${tenant.name} now belongs to ${target.name}.${oldOwner === 'frontdesk' ? ' You are front desk staff there now.' : ' Your GymMantra login stays the same.'}`);
    }
  }
  await notify(t, newUid, tenantId, 'You own a gym now', `${tenant.name} has been transferred to you. Open the app as "Gym owner".`);
  audit(t, tenantId, actorId, 'gym.transfer', 'tenant', tenantId, { owners: from }, { owner: newUid, oldOwner });
  return { tenantId, owner: { id: newUid, name: target.name } };
}

async function ownersOf(t: Tx, tenantId: string) {
  return (await t.query<StaffDoc>(P.staffCol(tenantId), [['role', 'OWNER']])).filter((r) => r.data.active).map((r) => r.id);
}

async function userByPhone(t: Tx, phoneIn: string) {
  const phone = normalizePhone(phoneIn);
  if (!phone) throw bad('Enter a valid 10-digit mobile number');
  const ref = await t.get<{ uid: string }>(P.phone(phone));
  if (!ref) throw notFound('No GymMantra account with this mobile number. Ask the new owner to sign up first');
  return ref.uid;
}

export function ownershipRoutes(app: App) {
  /** Look up the new owner before transferring (shows their name). */
  app.get('/api/v1/transfer-owner/lookup', async (c) => {
    const u = await authenticate(c);
    if (!u.isSuperAdmin) await gymOf(c, 'OWNER');
    const phone = normalizePhone(c.req.query('phone') ?? '');
    if (!phone) throw bad('Enter a valid 10-digit mobile number');
    const ref = await c.var.deps.store.get<{ uid: string }>(P.phone(phone));
    const tu = ref ? await c.var.deps.store.get<UserDoc>(P.user(ref.uid)) : null;
    if (!ref || !tu || tu.deleted) throw notFound('No GymMantra account with this mobile number. Ask the new owner to sign up first');
    return c.json({ id: ref.uid, name: tu.name, trainer: isTrainer(tu) });
  });

  /** Owner gives their gym to someone else (owner app → Gym settings → Transfer gym). */
  app.post('/api/v1/gym/transfer', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const oldOwner = oneOf(b, 'oldOwner', ['remove', 'frontdesk'] as const) ?? 'remove';
    const out = await c.var.deps.store.tx(async (t) => {
      const uid = await userByPhone(t, str(b, 'phone', { label: 'the new owner’s mobile number' }));
      return transfer(t, g.tenantId, u.id, uid, [u.id], oldOwner);
    });
    return c.json(out);
  });

  /** Super admin transfers a gym (GM Admin → Gyms → gym → Transfer gym). */
  app.post('/api/v1/super/gyms/:id/transfer', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    if (!isUuid(id)) throw notFound('Gym not found');
    const b = body(await c.req.json().catch(() => null));
    const oldOwner = oneOf(b, 'oldOwner', ['remove', 'frontdesk'] as const) ?? 'remove';
    const out = await c.var.deps.store.tx(async (t) => {
      const uid = await userByPhone(t, str(b, 'phone', { label: 'the new owner’s mobile number' }));
      return transfer(t, id, u.id, uid, await ownersOf(t, id), oldOwner);
    });
    return c.json(out);
  });

  /**
   * Super admin closes a gym: nobody can use it any more, members see "This gym is closed",
   * owner and staff are freed (their accounts can then be deleted). Can be reopened within 30 days.
   */
  app.post('/api/v1/super/gyms/:id/close', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    if (!isUuid(id)) throw notFound('Gym not found');
    const b = body(await c.req.json().catch(() => null));
    const { store } = c.var.deps;
    await store.tx(async (t) => {
      const tenant = await t.get<TenantDoc>(P.tenant(id));
      if (!tenant) throw notFound('Gym not found');
      if (tenant.status === 'CLOSED') throw bad('This gym is already closed');
      if (str(b, 'confirm', { label: 'the gym code' }).trim().toUpperCase() !== tenant.gymCode.toUpperCase()) throw bad('Type the gym code to confirm');
      const staff = (await t.query<StaffDoc>(P.staffCol(id), [['active', true]])).map((r) => ({ uid: r.id, ...r.data }));
      for (const s of staff) {
        t.set(P.staff(id, s.uid), { userId: s.userId, role: s.role, branchIds: s.branchIds, active: false, createdAt: s.createdAt, rights: s.rights });
        const su = await t.get<UserDoc>(P.user(s.uid));
        if (su) {
          t.set(P.user(s.uid), { ...su, staffOf: { ...su.staffOf, [id]: { ...su.staffOf[id], role: s.role, branchIds: s.branchIds, active: false } } });
          await notify(t, s.uid, id, 'Gym closed', `${tenant.name} has been closed by GymMantra support.`);
        }
      }
      t.set(P.tenant(id), { ...tenant, status: 'CLOSED', closedAt: nowIso(), closedStaff: staff.map((s) => ({ uid: s.uid, role: s.role, branchIds: s.branchIds, rights: s.rights })) });
      audit(t, id, u.id, 'gym.close', 'tenant', id, { status: tenant.status }, { status: 'CLOSED' });
    });
    return c.json({ ok: true });
  });

  app.post('/api/v1/super/gyms/:id/reopen', async (c) => {
    const u = await authenticate(c);
    requireSuper(c);
    const id = c.req.param('id');
    if (!isUuid(id)) throw notFound('Gym not found');
    const { store } = c.var.deps;
    await store.tx(async (t) => {
      const tenant = await t.get<TenantDoc>(P.tenant(id));
      if (!tenant || tenant.status !== 'CLOSED') throw bad('This gym is not closed');
      if (tenant.closedAt && Date.now() - Date.parse(tenant.closedAt) > 30 * 86400_000) throw forbidden('A gym can be reopened only within 30 days of closing');
      for (const s of tenant.closedStaff ?? []) {
        const su = await t.get<UserDoc>(P.user(s.uid));
        if (!su || su.deleted) continue;
        const prev = await t.get<StaffDoc>(P.staff(id, s.uid));
        t.set(P.staff(id, s.uid), { userId: s.uid, role: s.role, branchIds: s.branchIds, active: true, createdAt: prev?.createdAt ?? nowIso(), rights: s.rights });
        t.set(P.user(s.uid), { ...su, staffOf: { ...su.staffOf, [id]: { role: s.role, branchIds: s.branchIds, active: true, rights: s.rights } } });
        await notify(t, s.uid, id, 'Gym reopened', `${tenant.name} is open again.`);
      }
      t.set(P.tenant(id), { ...tenant, status: 'ACTIVE', closedAt: null, closedStaff: [] });
      audit(t, id, u.id, 'gym.reopen', 'tenant', id, { status: 'CLOSED' }, { status: 'ACTIVE' });
    });
    return c.json({ ok: true });
  });
}
