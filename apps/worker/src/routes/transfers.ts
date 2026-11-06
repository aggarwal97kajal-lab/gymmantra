import { moveGymRating } from './ratings';
import { App, audit, authenticate, branchOf, gymOf, MemberDoc, memberCodeFor, notify, P, readRoster, rosterEntry, TenantDoc, need, writeRoster } from '../core';
import { bad, HttpError, notFound, nowIso, uuid } from '../lib/http';
import { body, oneOf, str } from '../lib/validate';
import { ownerIds } from './pt';

// ---------- Branch transfers ----------
// A member belongs to one branch of a gym at a time. The owner can move them directly
// (PATCH /members/:id with branchId), or the member asks and the owner approves here.
// Members can ask only when the owner has turned on "allowTransfer".

export interface TransferDoc {
  id: string;
  memberId: string;
  userId: string;
  name: string;
  memberCode: string;
  fromBranchId: string | null;
  toBranchId: string;
  status: 'PENDING' | 'APPROVED' | 'DECLINED';
  createdAt: string;
  decidedById: string | null;
  decidedAt: string | null;
}

export const TRANSFER_OFF = 'Your gym owner has not enabled transfer of your membership. Ask at the front desk or the gym owner';

// The main (first) branch is shown with the gym's name.
const branchName = (t: TenantDoc, id: string | null) => {
  const b = t.branches.find((x) => x.id === branchOf(t, id));
  return !b || b.id === t.branches[0]?.id ? t.name : b.name;
};

export function transferRoutes(app: App) {
  /** Member: branches of my gym, which one I am in, whether transfer is on, and my pending request. */
  app.get('/api/v1/me/gyms/:tenantId/transfer', async (c) => {
    const u = await authenticate(c);
    const tid = c.req.param('tenantId');
    const mid = u.memberships?.[tid];
    if (!mid) throw notFound('Membership not found');
    const { store } = c.var.deps;
    const [tenant, m, pending] = await Promise.all([
      store.get<TenantDoc>(P.tenant(tid)),
      store.get<MemberDoc>(P.member(tid, mid)),
      store.query<TransferDoc>(P.transfers(tid), [['memberId', mid], ['status', 'PENDING']]),
    ]);
    if (!tenant || !m) throw notFound('Membership not found');
    const cur = branchOf(tenant, m.branchId);
    return c.json({
      allowTransfer: tenant.allowTransfer ?? false,
      offMessage: tenant.allowTransfer ? null : TRANSFER_OFF,
      currentBranchId: cur,
      branches: tenant.branches.map((b) => ({ id: b.id, name: b.name, address: b.address, current: b.id === cur })),
      pending: pending[0] ? { id: pending[0].id, toBranchId: pending[0].data.toBranchId, toBranch: branchName(tenant, pending[0].data.toBranchId), createdAt: pending[0].data.createdAt } : null,
    });
  });

  /** Member asks to move to another branch of the same gym. */
  app.post('/api/v1/me/gyms/:tenantId/transfer', async (c) => {
    const u = await authenticate(c);
    const tid = c.req.param('tenantId');
    const mid = u.memberships?.[tid];
    if (!mid) throw notFound('Membership not found');
    const b = body(await c.req.json().catch(() => null));
    const to = str(b, 'branchId', { label: 'the branch' });
    const { store } = c.var.deps;
    const [tenant, m] = await Promise.all([store.get<TenantDoc>(P.tenant(tid)), store.get<MemberDoc>(P.member(tid, mid))]);
    if (!tenant || !m || m.archived) throw notFound('Membership not found');
    if (!tenant.allowTransfer) throw new HttpError(403, TRANSFER_OFF, { code: 'TRANSFER_OFF' });
    if (!tenant.branches.some((x) => x.id === to)) throw bad('Unknown branch');
    if (branchOf(tenant, m.branchId) === to) throw bad(`You are already in ${branchName(tenant, to)}`);
    const owners = await ownerIds(store, tid);
    const out = await store.tx(async (t) => {
      const pending = await t.query<TransferDoc>(P.transfers(tid), [['memberId', mid], ['status', 'PENDING']]);
      // One open request at a time: asking again changes the branch.
      const id = pending[0]?.id ?? uuid();
      const doc: TransferDoc = {
        id,
        memberId: mid,
        userId: u.id,
        name: m.name,
        memberCode: m.memberCode,
        fromBranchId: branchOf(tenant, m.branchId),
        toBranchId: to,
        status: 'PENDING',
        createdAt: nowIso(),
        decidedById: null,
        decidedAt: null,
      };
      t.set(P.transfer(tid, id), doc);
      for (const o of owners) await notify(t, o, tid, 'Branch transfer request', `${m.name} (${m.memberCode}) wants to move from ${branchName(tenant, m.branchId)} to ${branchName(tenant, to)}`, to);
      return doc;
    });
    return c.json({ id: out.id, toBranch: branchName(tenant, to) }, 201);
  });

  /** Member cancels their request. */
  app.delete('/api/v1/me/gyms/:tenantId/transfer', async (c) => {
    const u = await authenticate(c);
    const tid = c.req.param('tenantId');
    const mid = u.memberships?.[tid];
    if (!mid) throw notFound('Membership not found');
    const { store } = c.var.deps;
    await store.tx(async (t) => {
      const pending = await t.query<TransferDoc>(P.transfers(tid), [['memberId', mid], ['status', 'PENDING']]);
      for (const p of pending) t.delete(P.transfer(tid, p.id));
    });
    return c.json({ ok: true });
  });

  /** Owner / desk: open requests into or out of the branch being looked at. */
  app.get('/api/v1/transfers', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    need(g, 'requests');
    const rows = (await c.var.deps.store.query<TransferDoc>(P.transfers(g.tenantId), [['status', 'PENDING']])).map((r) => r.data);
    return c.json({
      allowTransfer: g.tenant.allowTransfer ?? false,
      items: rows
        .filter((r) => r.toBranchId === g.branchId || branchOf(g.tenant, r.fromBranchId) === g.branchId)
        .sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1))
        .map((r) => ({ ...r, fromBranch: branchName(g.tenant, r.fromBranchId), toBranch: branchName(g.tenant, r.toBranchId), incoming: r.toBranchId === g.branchId })),
    });
  });

  /** Owner approves or declines. Approving moves the member (member doc + roster). */
  app.post('/api/v1/transfers/:id/:action', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    if (g.role !== 'OWNER') need(g, 'transfers'); // owner, or staff with the "Branch moves" right
    const action = oneOf({ a: c.req.param('action') }, 'a', ['approve', 'decline'] as const);
    const id = c.req.param('id');
    const out = await c.var.deps.store.tx(async (t) => {
      const tr = await t.get<TransferDoc>(P.transfer(g.tenantId, id));
      if (!tr) throw notFound('Request not found');
      if (tr.status !== 'PENDING') throw bad('This request is already handled');
      const [m, roster] = await Promise.all([t.get<MemberDoc>(P.member(g.tenantId, tr.memberId)), readRoster(t, g.tenantId)]);
      if (!m || m.archived) throw notFound('Member not found');
      const done: TransferDoc = { ...tr, status: action === 'approve' ? 'APPROVED' : 'DECLINED', decidedById: u.id, decidedAt: nowIso() };
      t.set(P.transfer(g.tenantId, id), done);
      if (action === 'approve') {
        if (!g.tenant.branches.some((b) => b.id === tr.toBranchId)) throw bad('That branch was deleted');
        const after = { ...m, branchId: tr.toBranchId, memberCode: memberCodeFor(g.tenant, tr.toBranchId, m.memberCode) };
        t.set(P.member(g.tenantId, m.id), after);
        roster.members[m.id] = { ...(roster.members[m.id] ?? rosterEntry(m)), branchId: tr.toBranchId, memberCode: after.memberCode };
        writeRoster(t, g.tenantId, roster);
        audit(t, g.tenantId, u.id, 'member.transfer', 'member', m.id, { branchId: m.branchId }, { branchId: tr.toBranchId });
        await notify(t, m.userId, g.tenantId, 'Branch changed', `Your membership at ${g.tenant.name} is now at ${branchName(g.tenant, tr.toBranchId)}`, tr.toBranchId);
      } else {
        audit(t, g.tenantId, u.id, 'member.transfer.decline', 'member', m.id);
        await notify(t, m.userId, g.tenantId, 'Transfer not approved', `${g.tenant.name} did not approve your move to ${branchName(g.tenant, tr.toBranchId)}. Ask at the front desk`, tr.fromBranchId);
      }
      return done;
    });
    if (out.status === 'APPROVED') {
      const m = await c.var.deps.store.get<MemberDoc>(P.member(g.tenantId, out.memberId));
      await moveGymRating(c.var.deps.store, g.tenantId, m?.userId); // their rating follows them
    }
    return c.json(out);
  });
}

