import { hasDetails, personDetails } from '../lib/person';
import {
  App,
  audit,
  authenticate,
  bumpDaily,
  C,
  canSeeBranch,
  inBranch,
  branchOf,
  dailyFor,
  Freeze,
  GymCtx,
  gymOf,
  isDeskStaff,
  MemberDoc,
  memberCodeFor,
  notify,
  P,
  paidOf,
  readRoster,
  Roster,
  RosterEntry,
  rosterEntry,
  rosterPutSub,
  stateOf,
  SubDoc,
  TenantDoc,
  UserDoc,
  userNames,
} from '../core';
import { addDays, diffDays, isYmd, planEndDate, todayIST } from '../lib/dates';
import { bad, conflict, forbidden, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { normalizeEmail, normalizePhone } from '../lib/phone';
import { activeFreeze, effectiveEnd, entryDecision, freezeDaysLeft, MembershipStatus, renewalStart, validSubs } from '../lib/status';
import { body, int, oneOf, optBool, optInt, optStr, str, strList } from '../lib/validate';
import type { Tx } from '../store/store';
import { gymLimits } from './gym';
import { newTrainer } from './trainers';
import { requireFeature } from './billing';
import type { ScanLog } from './attendance';

export interface PlanDoc {
  id: string;
  name: string;
  months: number;
  price: number;
  joiningFee: number;
  freezeDays: number;
  features: string[];
  showInApp: boolean;
  active: boolean;
  createdAt: string;
}

const PAY_MODES = ['CASH', 'UPI', 'CARD', 'BANK_TRANSFER', 'NOT_PAID'] as const;
const inr = (n: number) => `₹${n.toLocaleString('en-IN')}`;
const prettyDate = (ymd: string) => new Date(`${ymd}T00:00:00Z`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
export const whatsappLink = (phone: string, text: string) => `https://wa.me/${phone.replace(/[^\d]/g, '')}?text=${encodeURIComponent(text)}`;

const TABS = ['all', 'active', 'ending', 'expired', 'frozen', 'due', 'noplan'] as const;
type Tab = (typeof TABS)[number];
function inTab(tab: Tab, status: MembershipStatus, due: number) {
  switch (tab) {
    case 'all':
      return true;
    case 'active':
      return status === 'ACTIVE';
    case 'ending':
      return status === 'ENDING_SOON';
    case 'expired':
      return status === 'EXPIRED';
    case 'frozen':
      return status === 'FROZEN';
    case 'due':
      return due > 0;
    case 'noplan':
      return status === 'NO_PLAN' || status === 'UPCOMING';
  }
}

export function summaries(g: GymCtx, roster: Roster, includeArchived = false) {
  const today = todayIST();
  return Object.entries(roster.members)
    .filter(([, e]) => (includeArchived || !e.archived) && canSeeBranch(g, e.branchId) && inBranch(g, e.branchId))
    .map(([id, e]) => {
      const st = stateOf(e, today);
      return {
        id,
        name: e.name,
        phone: e.phone,
        memberCode: e.memberCode,
        branchId: e.branchId,
        photoUrl: e.userId && e.photoV ? `/api/v1/photos/${e.userId}?v=${e.photoV}` : null,
        hasApp: !!e.userId,
        archived: e.archived,
        status: st.status,
        planName: st.current?.planName ?? st.upcoming?.planName ?? null,
        planId: st.current?.planId ?? null,
        endsOn: st.endsOn,
        daysLeft: st.daysLeft,
        due: st.due,
        // For members who owe money: how much they paid of the memberships that still have money due.
        ...(() => {
          if (st.due <= 0) return { duePaid: 0, dueTotal: 0 };
          const owing = validSubs(e.subs).filter((s) => s.total > s.paid);
          return { duePaid: owing.reduce((n, s) => n + s.paid, 0), dueTotal: owing.reduce((n, s) => n + s.total, 0) };
        })(),
      };
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function memberFor(t: { get: Tx['get'] }, g: GymCtx, id: string) {
  if (!isUuid(id)) throw notFound('Member not found');
  const m = await t.get<MemberDoc>(P.member(g.tenantId, id));
  if (!m || !canSeeBranch(g, m.branchId)) throw notFound('Member not found');
  return m;
}

function checkBranch(g: GymCtx, branchId: string | undefined | null) {
  if (!branchId) return;
  if (!g.tenant.branches.some((b) => b.id === branchId)) throw bad('Unknown branch');
  if (g.role === 'FRONT_DESK' && g.branchIds.length && !g.branchIds.includes(branchId)) throw bad('You can only add members to your own branch');
}

/** Adds a member inside a transaction. Also used by imports and join approvals. */
export async function addMember(
  t: Tx,
  g: GymCtx,
  actorId: string,
  input: { name: string; phone: string; email?: string | null; gender?: string | null; branchId?: string | null; joinedOn?: string; notes?: string | null; userId?: string | null; photoV?: number | null; details?: Partial<MemberDoc> },
) {
  const tenant = (await t.get<TenantDoc>(P.tenant(g.tenantId)))!;
  const roster = await readRoster(t, g.tenantId);
  const limits = await gymLimits(t, tenant);
  const activeCount = Object.values(roster.members).filter((e) => !e.archived).length;
  if (limits.memberLimit != null && activeCount >= limits.memberLimit) throw forbidden(`Your ${limits.planName} plan allows ${limits.memberLimit} members. Upgrade to add more`);
  if (Object.values(roster.members).some((e) => e.phone === input.phone)) throw conflict('A member with this mobile number already exists');
  const id = uuid();
  const m: MemberDoc = {
    id,
    userId: input.userId ?? null,
    memberCode: `${tenant.memberCodePrefix}-${tenant.nextMemberNumber}`,
    name: input.name,
    phone: input.phone,
    email: input.email ?? null,
    gender: input.gender ?? null,
    branchId: input.branchId ?? (g.role === 'FRONT_DESK' && g.branchIds.length ? g.branchIds[0] : null),
    joinedOn: input.joinedOn ?? todayIST(),
    notes: input.notes ?? null,
    archived: false,
    createdAt: nowIso(),
    ...(input.details ?? {}),
  };
  roster.members[id] = { ...rosterEntry(m), photoV: input.photoV ?? null };
  t.set(P.tenant(g.tenantId), { ...tenant, nextMemberNumber: tenant.nextMemberNumber + 1, memberCount: activeCount + 1 });
  t.set(P.member(g.tenantId, id), m);
  t.set(P.roster(g.tenantId), roster);
  audit(t, g.tenantId, actorId, 'member.create', 'member', id, null, m);
  return { m, roster, tenant };
}

async function linkUser(t: Tx, userId: string, tenantId: string, memberId: string) {
  const u = await t.get<UserDoc>(P.user(userId));
  if (!u) return;
  const requested = { ...(u.requested ?? {}) };
  delete requested[tenantId];
  t.set(P.user(userId), { ...u, memberships: { ...u.memberships, [tenantId]: memberId }, requested });
}

export function memberRoutes(app: App) {
  // ---------- Plans ----------

  app.get('/api/v1/plans', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const { store } = c.var.deps;
    const [plans, roster] = await Promise.all([store.query<PlanDoc>(P.plans(g.tenantId)), readRoster(store, g.tenantId)]);
    const counts = new Map<string, number>();
    for (const e of Object.values(roster.members)) {
      if (e.archived) continue;
      const st = stateOf(e);
      const pid = st.current?.planId;
      if (pid && ['ACTIVE', 'ENDING_SOON', 'FROZEN'].includes(st.status)) counts.set(pid, (counts.get(pid) ?? 0) + 1);
    }
    return c.json(
      plans
        .map((p) => ({ ...p.data, id: p.id, activeMembers: counts.get(p.id) ?? 0 }))
        .sort((a, b) => Number(b.active) - Number(a.active) || a.months - b.months),
    );
  });

  const planFields = (b: Record<string, unknown>, partial: boolean) => {
    const out: Partial<PlanDoc> = {};
    if (!partial || b.name !== undefined) out.name = str(b, 'name', { min: 2, max: 60, label: 'the plan name' });
    if (!partial || b.months !== undefined) out.months = int(b, 'months', { min: 1, max: 60, label: 'months' });
    if (!partial || b.price !== undefined) out.price = int(b, 'price', { min: 0, max: 10_000_000, label: 'price' });
    const jf = optInt(b, 'joiningFee', { min: 0, max: 1_000_000, label: 'joining fee' });
    if (jf !== undefined || !partial) out.joiningFee = jf ?? 0;
    const fd = optInt(b, 'freezeDays', { min: 0, max: 365, label: 'freeze days' });
    if (fd !== undefined || !partial) out.freezeDays = fd ?? 0;
    const f = strList(b, 'features', 12);
    if (f !== undefined || !partial) out.features = f ?? [];
    const s = optBool(b, 'showInApp');
    if (s !== undefined || !partial) out.showInApp = s ?? true;
    const a = optBool(b, 'active');
    if (a !== undefined || !partial) out.active = a ?? true;
    return out;
  };

  app.post('/api/v1/plans', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const p = { id: uuid(), ...planFields(b, false), createdAt: nowIso() } as PlanDoc;
    await c.var.deps.store.tx(async (t) => {
      t.set(P.plan(g.tenantId, p.id), p);
      audit(t, g.tenantId, u.id, 'plan.create', 'plan', p.id, null, p);
    });
    return c.json(p, 201);
  });

  /** Price changes affect only new and renewed memberships; old rows keep their recorded price. */
  app.patch('/api/v1/plans/:id', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const patch = planFields(b, true);
    const out = await c.var.deps.store.tx(async (t) => {
      const before = isUuid(id) ? await t.get<PlanDoc>(P.plan(g.tenantId, id)) : null;
      if (!before) throw notFound('Plan not found');
      const after = { ...before, ...patch };
      t.set(P.plan(g.tenantId, id), after);
      audit(t, g.tenantId, u.id, 'plan.update', 'plan', id, before, after);
      return after;
    });
    return c.json(out);
  });

  // ---------- Dashboard and members ----------

  /** Delete a plan nobody has used yet; a used plan can only be switched off. */
  app.delete('/api/v1/plans/:id', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    const { store } = c.var.deps;
    await store.tx(async (t) => {
      const [plan, roster] = (await t.getMany<any>([P.plan(g.tenantId, isUuid(id) ? id : 'x'), P.roster(g.tenantId)])) as [PlanDoc | null, Roster | null];
      if (!plan) throw notFound('Plan not found');
      const used = Object.values(roster?.members ?? {}).some((e) => e.subs.some((s) => s.planId === id));
      if (used) throw bad('Members have this plan, so it cannot be deleted. Switch it off (Active) instead');
      t.delete(P.plan(g.tenantId, id));
      audit(t, g.tenantId, u.id, 'plan.delete', 'plan', id, plan, null);
    });
    return c.json({ ok: true });
  });

  app.get('/api/v1/dashboard', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const { store } = c.var.deps;
    const [roster, daily, joins, tickets, pts] = await Promise.all([
      readRoster(store, g.tenantId),
      store.get<Record<string, number>>(P.daily(g.tenantId, todayIST())),
      store.query(P.joins(g.tenantId), [['status', 'PENDING']]),
      store.query(P.tickets, [['tenantId', g.tenantId], ['routedTo', 'GYM'], ['status', 'OPEN']]),
      store.query(P.pts(g.tenantId), [['status', 'PENDING']]),
    ]);
    const all = summaries(g, roster);
    const count = (s: MembershipStatus) => all.filter((m) => m.status === s).length;
    return c.json({
      totals: {
        members: all.length,
        active: count('ACTIVE'),
        endingSoon: count('ENDING_SOON'),
        expired: count('EXPIRED'),
        frozen: count('FROZEN'),
        noPlan: count('NO_PLAN') + count('UPCOMING'),
        dueAmount: all.reduce((n, m) => n + m.due, 0),
        dueMembers: all.filter((m) => m.due > 0).length,
      },
      today: (({ collected, payments, checkins }) => ({ collected, payments, checkins }))(dailyFor(g, daily)),
      joinPending: joins.filter((j: any) => inBranch(g, j.data.branchId)).length,
      ptPending: pts.filter((p: any) => inBranch(g, roster.members[p.data.memberId]?.branchId)).length,
      openTickets: tickets.length,
      renewalsDue: all
        .filter((m) => m.status === 'ENDING_SOON' || (m.status === 'EXPIRED' && (m.daysLeft ?? -999) >= -30))
        .sort((a, b) => (a.daysLeft ?? 0) - (b.daysLeft ?? 0))
        .slice(0, 20),
    });
  });

  app.get('/api/v1/members', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const tab = (c.req.query('tab') ?? 'all') as Tab;
    if (!TABS.includes(tab)) throw bad('Unknown tab');
    const needle = (c.req.query('q') ?? '').trim().toLowerCase();
    const digits = needle.replace(/[^\d]/g, '');
    const all = summaries(g, await readRoster(c.var.deps.store, g.tenantId));
    const rows = all.filter(
      (m) => inTab(tab, m.status, m.due) && (!needle || m.name.toLowerCase().includes(needle) || m.memberCode.toLowerCase().includes(needle) || (digits.length >= 3 && m.phone.includes(digits))),
    );
    return c.json({ rows, counts: Object.fromEntries(TABS.map((t) => [t, all.filter((m) => inTab(t, m.status, m.due)).length])) });
  });

  const memberInput = (g: GymCtx, b: Record<string, unknown>) => {
    const name = str(b, 'name', { min: 2, max: 80, label: 'the name' });
    const phone = normalizePhone(str(b, 'phone', { label: 'the mobile number' }));
    if (!phone) throw bad('Enter a valid 10-digit mobile number');
    const emailIn = optStr(b, 'email');
    const email = emailIn ? normalizeEmail(emailIn) : null;
    if (emailIn && !email) throw bad('Enter a valid email address');
    const gender = oneOf(b, 'gender', ['male', 'female', 'other'] as const, true) ?? null;
    const branchId = optStr(b, 'branchId') ?? null;
    checkBranch(g, branchId);
    const joinedOn = optStr(b, 'joinedOn');
    if (joinedOn && !isYmd(joinedOn)) throw bad('Joining date is not valid');
    return { name, phone, email, gender, branchId, joinedOn, notes: optStr(b, 'notes', { max: 500 }) ?? null };
  };
  /** New app: first / middle / last name, DOB, state, city, country, PIN, email (all required like sign-up). */
  const fullInput = (g: GymCtx, b: Record<string, unknown>) => {
    const d = personDetails(b);
    const base = memberInput(g, { ...b, name: d.name, gender: d.gender ?? b.gender });
    if (!base.email) throw bad('Enter the email ID');
    return { ...base, details: { firstName: d.firstName, middleName: d.middleName, lastName: d.lastName, dob: d.dob, state: d.state, city: d.city, country: d.country, pincode: d.pincode } };
  };

  app.post('/api/v1/members', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const b = body(await c.req.json().catch(() => null));
    const full = hasDetails(b) ? fullInput(g, b) : null;
    const input = full ?? memberInput(g, b);
    const { store, identity } = c.var.deps;
    let existingUser = (await store.get<{ uid: string }>(P.phone(input.phone)))?.uid ?? null;
    if (!existingUser && input.email) existingUser = (await store.query<UserDoc>('users', [['email', input.email]])).find((r) => !r.data.deleted)?.id ?? null;
    if (existingUser) {
      const eu = await store.get<UserDoc>(P.user(existingUser));
      if (eu?.memberships?.[g.tenantId]) throw conflict('This person is already a member of your gym');
    }
    // No GymMantra account yet: make one with these details. The member sets a password from the email link.
    let made: { uid: string; idToken?: string } | null = null;
    const pw = `${crypto.randomUUID()}Aa1!`;
    if (!existingUser && full && input.email) {
      try {
        made = await identity.signUp(input.email, pw);
      } catch {
        made = null; // the email already has a login somewhere; add the member without an account
      }
    }
    try {
      const m = await store.tx(async (t) => {
        const r = await addMember(t, g, u.id, { ...input, userId: existingUser ?? made?.uid ?? null, details: full?.details });
        if (existingUser) await linkUser(t, existingUser, g.tenantId, r.m.id);
        else if (made && full) {
          const phoneRef = await t.get<{ uid: string }>(P.phone(input.phone));
          if (phoneRef) throw conflict('This mobile number already has a GymMantra account');
          t.create(P.phone(input.phone), { uid: made.uid });
          const nu: UserDoc = {
            name: input.name,
            email: input.email,
            authEmail: input.email,
            fbUid: made.uid,
            phone: input.phone,
            googleSub: null,
            photoV: null,
            language: 'en',
            isSuperAdmin: false,
            failed: 0,
            lockedUntil: null,
            createdAt: nowIso(),
            memberships: { [g.tenantId]: r.m.id },
            requested: {},
            staffOf: {},
            appRole: 'MEMBER',
            gender: (input.gender as UserDoc['gender']) ?? null,
            ...full.details,
            createdByGym: { tenantId: g.tenantId, gymName: g.tenant.name },
            mustSetPassword: true,
            initPw: pw,
          };
          t.set(P.user(made.uid), nu);
          const st = (await t.get<{ users: number }>(P.stats)) ?? { users: 0 };
          t.set(P.stats, { ...st, users: (st.users ?? 0) + 1 });
        }
        return r.m;
      });
      return c.json({ ...m, accountMade: !!made }, 201);
    } catch (e) {
      if (made?.idToken) await identity.deleteAccount(made.idToken).catch(() => {});
      throw e;
    }
  });

  app.post('/api/v1/members/import', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const b = body(await c.req.json().catch(() => null));
    if (!Array.isArray(b.rows) || b.rows.length > 2000) throw bad('Invalid rows');
    const branchId = optStr(b, 'branchId') ?? null;
    checkBranch(g, branchId);
    const results: { row: number; ok: boolean; error?: string; memberCode?: string }[] = [];
    const good: ReturnType<typeof memberInput>[] = [];
    const rowOf: number[] = [];
    (b.rows as unknown[]).forEach((r, i) => {
      try {
        const x = body(r);
        const gender = typeof x.gender === 'string' && ['male', 'female', 'other'].includes(x.gender.toLowerCase()) ? x.gender.toLowerCase() : undefined;
        const joinedOn = typeof x.joinedOn === 'string' && isYmd(x.joinedOn) ? x.joinedOn : undefined;
        const email = typeof x.email === 'string' && normalizeEmail(x.email) ? x.email : undefined;
        good.push(memberInput(g, { name: x.name, phone: x.phone, email, gender, joinedOn, branchId: branchId ?? undefined }));
        rowOf.push(i + 1);
      } catch (e: any) {
        results.push({ row: i + 1, ok: false, error: e.message });
      }
    });
    // One transaction per 50 rows keeps each write batch small.
    for (let i = 0; i < good.length; i += 50) {
      const chunk = good.slice(i, i + 50);
      const chunkRows = rowOf.slice(i, i + 50);
      const out = await c.var.deps.store.tx(async (t) => {
        const res: typeof results = [];
        const tenant = (await t.get<TenantDoc>(P.tenant(g.tenantId)))!;
        const roster = await readRoster(t, g.tenantId);
        const limits = await gymLimits(t, tenant);
        let next = tenant.nextMemberNumber;
        let active = Object.values(roster.members).filter((e) => !e.archived).length;
        const phones = new Set(Object.values(roster.members).map((e) => e.phone));
        chunk.forEach((inp, k) => {
          if (phones.has(inp.phone)) return res.push({ row: chunkRows[k], ok: false, error: 'A member with this mobile number already exists' });
          if (limits.memberLimit != null && active >= limits.memberLimit) return res.push({ row: chunkRows[k], ok: false, error: 'Member limit reached for your plan' });
          const id = uuid();
          const m: MemberDoc = { id, userId: null, memberCode: `${tenant.memberCodePrefix}-${next++}`, name: inp.name, phone: inp.phone, email: inp.email, gender: inp.gender, branchId: inp.branchId, joinedOn: inp.joinedOn ?? todayIST(), notes: null, archived: false, createdAt: nowIso() };
          phones.add(inp.phone);
          active++;
          roster.members[id] = rosterEntry(m);
          t.set(P.member(g.tenantId, id), m);
          res.push({ row: chunkRows[k], ok: true, memberCode: m.memberCode });
        });
        t.set(P.tenant(g.tenantId), { ...tenant, nextMemberNumber: next, memberCount: active });
        t.set(P.roster(g.tenantId), roster);
        audit(t, g.tenantId, u.id, 'member.import', 'member', 'bulk', null, { added: res.filter((r) => r.ok).length });
        return res;
      });
      results.push(...out);
    }
    results.sort((a, b) => a.row - b.row);
    return c.json({ added: results.filter((r) => r.ok).length, failed: results.filter((r) => !r.ok).length, results });
  });

  app.get('/api/v1/members/:id', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const { store } = c.var.deps;
    const id = c.req.param('id');
    if (!isUuid(id)) throw notFound('Member not found');
    // Everything that does not depend on the member document is read at the same time.
    const [m0, roster, subsRows, att] = await Promise.all([
      store.get<MemberDoc>(P.member(g.tenantId, id)),
      readRoster(store, g.tenantId),
      store.query<SubDoc>(P.subs(g.tenantId), [['memberId', id]]),
      store.get<ScanLog>(P.lastScan(g.tenantId, id)),
    ]);
    if (!m0 || !canSeeBranch(g, m0.branchId)) throw notFound('Member not found');
    const m = m0;
    const entry = roster.members[m.id] ?? rosterEntry(m);
    const state = stateOf(entry);
    const subs = subsRows.map((r) => r.data);
    const [user, names] = await Promise.all([
      m.userId ? store.get<UserDoc>(P.user(m.userId)) : Promise.resolve(null),
      userNames(store, subs.flatMap((s) => [s.createdById, ...s.payments.map((p) => p.receivedById)])),
    ]);
    const replaced = new Set(subs.map((s) => s.replacesId).filter(Boolean));
    const month = todayIST().slice(0, 7);
    return c.json({
      member: { ...m, photoUrl: user?.photoV ? `/api/v1/photos/${m.userId}?v=${user.photoV}` : null, hasApp: !!m.userId },
      // What the member filled in their own app profile (read-only for the gym).
      profile: user
        ? {
            name: user.name,
            firstName: user.firstName ?? null,
            middleName: user.middleName ?? null,
            lastName: user.lastName ?? null,
            dob: user.dob ?? null,
            gender: user.gender ?? m.gender ?? null,
            email: user.email ?? m.email ?? null,
            phone: user.phone ?? m.phone,
            address: user.address ?? null,
            city: user.city ?? m.city ?? null,
            state: user.state ?? m.state ?? null,
            country: user.country ?? m.country ?? null,
            pincode: user.pincode ?? m.pincode ?? null,
          }
        : m.firstName
          ? { name: m.name, firstName: m.firstName, middleName: m.middleName ?? null, lastName: m.lastName ?? null, dob: m.dob ?? null, gender: m.gender, email: m.email, phone: m.phone, address: null, city: m.city ?? null, state: m.state ?? null, country: m.country ?? null, pincode: m.pincode ?? null }
          : null,
      visits: { thisMonth: att?.month === month ? att.visits : 0, lastAt: att?.lastAllowedAt ?? null },
      state: {
        status: state.status,
        daysLeft: state.daysLeft,
        endsOn: state.endsOn,
        due: state.due,
        frozenUntil: state.frozenUntil,
        currentId: state.current?.id ?? null,
        upcomingId: state.upcoming?.id ?? null,
        freezeDaysLeft: state.current ? freezeDaysLeft(state.current) : 0,
        entry: entryDecision(state),
      },
      history: subs
        .sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1))
        .map((s) => ({
          ...s,
          paid: paidOf(s),
          createdByName: names.get(s.createdById),
          superseded: replaced.has(s.id),
          due: Math.max(0, s.total - paidOf(s)),
          payments: s.payments.map((p) => ({ ...p, receivedByName: names.get(p.receivedById) })),
        })),
      attendance: (att?.recent ?? []).map((r) => ({ id: r.id, scannedAt: r.at, result: r.result, reason: r.reason })),
    });
  });

  app.patch('/api/v1/members/:id', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const b = body(await c.req.json().catch(() => null));
    const out = await c.var.deps.store.tx(async (t) => {
      const before = await memberFor(t, g, c.req.param('id'));
      const after: MemberDoc = { ...before };
      if (b.name !== undefined) after.name = str(b, 'name', { min: 2, max: 80, label: 'the name' });
      const roster = await readRoster(t, g.tenantId);
      if (b.phone !== undefined) {
        const phone = normalizePhone(str(b, 'phone', { label: 'the mobile number' }));
        if (!phone) throw bad('Enter a valid 10-digit mobile number');
        if (Object.entries(roster.members).some(([id, e]) => id !== before.id && e.phone === phone)) throw conflict('Another member has this mobile number');
        after.phone = phone;
      }
      if (b.email !== undefined) {
        const e = optStr(b, 'email');
        after.email = e ? normalizeEmail(e) : null;
        if (e && !after.email) throw bad('Enter a valid email address');
      }
      if (b.gender !== undefined) after.gender = oneOf(b, 'gender', ['male', 'female', 'other'] as const, true) ?? null;
      if (b.branchId !== undefined) {
        after.branchId = optStr(b, 'branchId') ?? null;
        checkBranch(g, after.branchId);
        if (branchOf(g.tenant, after.branchId) !== branchOf(g.tenant, before.branchId)) after.memberCode = memberCodeFor(g.tenant, branchOf(g.tenant, after.branchId), before.memberCode);
      }
      if (b.notes !== undefined) after.notes = optStr(b, 'notes', { max: 500 }) ?? null;
      const archived = optBool(b, 'archived');
      if (archived !== undefined) after.archived = archived;
      const e = roster.members[before.id] ?? rosterEntry(before);
      roster.members[before.id] = { ...e, name: after.name, phone: after.phone, memberCode: after.memberCode, branchId: after.branchId, archived: after.archived };
      t.set(P.member(g.tenantId, before.id), after);
      t.set(P.roster(g.tenantId), roster);
      audit(t, g.tenantId, u.id, 'member.update', 'member', before.id, before, after);
      return after;
    });
    return c.json(out);
  });

  /** WhatsApp renewal reminders from the gym's own WhatsApp: one ready-to-send link per member. */
  app.post('/api/v1/members/reminders', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const b = body(await c.req.json().catch(() => null));
    const ids = strList(b, 'memberIds', 500) ?? [];
    const all = summaries(g, await readRoster(c.var.deps.store, g.tenantId));
    const name = g.tenant.name;
    return c.json(
      all
        .filter((m) => ids.includes(m.id))
        .map((m) => {
          const line =
            m.status === 'EXPIRED'
              ? `Hi ${m.name}, your ${m.planName ?? ''} membership at ${name} ended on ${prettyDate(m.endsOn!)}. Renew today to keep training!`
              : m.status === 'ENDING_SOON'
                ? `Hi ${m.name}, your ${m.planName ?? ''} membership at ${name} ends on ${prettyDate(m.endsOn!)} (${m.daysLeft} day${m.daysLeft === 1 ? '' : 's'} left). Visit the front desk to renew.`
                : `Hi ${m.name}, a reminder from ${name}.`;
          const due = m.due > 0 ? `\nPayment due: ${inr(m.due)}` : '';
          return { memberId: m.id, name: m.name, link: whatsappLink(m.phone, `${line.replace(/\s+/g, ' ')}${due}\n- ${name}`) };
        }),
    );
  });

  // ---------- Join requests ----------

  app.get('/api/v1/join-requests', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const status = ['PENDING', 'APPROVED', 'DECLINED'].includes(c.req.query('status') ?? '') ? c.req.query('status')! : 'PENDING';
    const { store } = c.var.deps;
    const rows = (await store.query<{ userId: string; createdAt: string; branchId: string | null }>(P.joins(g.tenantId), [['status', status]])).filter((r) => inBranch(g, r.data.branchId));
    const users = await store.getMany<UserDoc>(rows.map((r) => P.user(r.data.userId)));
    return c.json(
      rows
        .map((r, i) => ({
          id: r.id,
          ...r.data,
          user: { id: r.data.userId, name: users[i]?.name ?? 'User', phone: users[i]?.phone ?? null, email: users[i]?.email ?? null, photoUrl: users[i]?.photoV ? `/api/v1/photos/${r.data.userId}?v=${users[i]!.photoV}` : null },
        }))
        .sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)),
    );
  });

  app.post('/api/v1/join-requests/:id/approve', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const b = body((await c.req.json().catch(() => ({}))) ?? {});
    const id = c.req.param('id');
    const member = await c.var.deps.store.tx(async (t) => {
      const jr = isUuid(id) ? await t.get<{ userId: string; status: string; branchId: string | null; kind?: string; speciality?: string | null; experienceYears?: number | null }>(P.join(g.tenantId, id)) : null;
      if (!jr) throw notFound('Request not found');
      if (jr.status !== 'PENDING') throw bad('This request was already handled');
      const ju = await t.get<UserDoc>(P.user(jr.userId));
      if (!ju || ju.deleted) throw bad('This account no longer exists');
      if (jr.kind === 'TRAINER') {
        if (g.role !== 'OWNER') throw forbidden('Only the gym owner can approve trainers');
        await requireFeature(t, g.tenant, 'pt');
        if (isDeskStaff(ju)) throw bad('This person runs a gym and cannot be a trainer');
        const now = nowIso();
        const tb = branchOf(g.tenant, jr.branchId);
        t.set(P.staff(g.tenantId, jr.userId), { userId: jr.userId, role: 'TRAINER', branchIds: tb ? [tb] : [], active: true, createdAt: now });
        const tr = (await t.get(P.trainer(g.tenantId, jr.userId))) ?? { ...newTrainer(jr.userId, ju.name, jr.speciality ?? null, jr.experienceYears ?? null), branchId: tb };
        t.set(P.trainer(g.tenantId, jr.userId), { ...tr, active: true });
        const trq = { ...(ju.trainerRequested ?? {}) };
        delete trq[g.tenantId];
        t.set(P.user(jr.userId), { ...ju, appRole: 'TRAINER', trainerRequested: trq, staffOf: { ...ju.staffOf, [g.tenantId]: { role: 'TRAINER', branchIds: tb ? [tb] : [], active: true } } });
        t.set(P.join(g.tenantId, id), { ...jr, status: 'APPROVED', decidedById: u.id, decidedAt: now });
        audit(t, g.tenantId, u.id, 'trainer.approve', 'join_request', id, null, { trainerId: jr.userId });
        await notify(t, jr.userId, g.tenantId, 'Welcome!', `${g.tenant.name} approved you as a trainer.`);
        return { trainerId: jr.userId };
      }
      if (!ju.phone) throw bad('This person has no mobile number on their account');
      const branchId = optStr(b, 'branchId') ?? jr.branchId ?? g.branchId;
      checkBranch(g, branchId);
      const roster = await readRoster(t, g.tenantId);
      // If the gym already added this person by hand, link that record.
      const existing = Object.entries(roster.members).find(([, e]) => e.phone === ju.phone);
      let m: MemberDoc;
      if (existing) {
        const [mid, e] = existing;
        if (e.userId && e.userId !== jr.userId) throw conflict('This mobile number belongs to another member');
        m = { ...(await t.get<MemberDoc>(P.member(g.tenantId, mid)))!, userId: jr.userId };
        roster.members[mid] = { ...e, userId: jr.userId, photoV: ju.photoV ?? null };
        t.set(P.member(g.tenantId, mid), m);
        t.set(P.roster(g.tenantId), roster);
      } else {
        m = (await addMember(t, g, u.id, { name: ju.name, phone: ju.phone, email: ju.email, branchId, userId: jr.userId, photoV: ju.photoV ?? null })).m;
      }
      await linkUser(t, jr.userId, g.tenantId, m.id);
      t.set(P.join(g.tenantId, id), { ...jr, status: 'APPROVED', decidedById: u.id, decidedAt: nowIso() });
      audit(t, g.tenantId, u.id, 'join.approve', 'join_request', id, null, { memberId: m.id });
      await notify(t, jr.userId, g.tenantId, 'Welcome!', `${g.tenant.name} approved your request. Your member ID is ${m.memberCode}.`);
      return m;
    });
    return c.json(member, 201);
  });

  app.post('/api/v1/join-requests/:id/decline', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const id = c.req.param('id');
    await c.var.deps.store.tx(async (t) => {
      const jr = isUuid(id) ? await t.get<{ userId: string; status: string }>(P.join(g.tenantId, id)) : null;
      if (!jr) throw notFound('Request not found');
      if (jr.status !== 'PENDING') throw bad('This request was already handled');
      t.set(P.join(g.tenantId, id), { ...jr, status: 'DECLINED', decidedById: u.id, decidedAt: nowIso() });
      const ju = await t.get<UserDoc>(P.user(jr.userId));
      if (ju) {
        const requested = { ...(ju.requested ?? {}) };
        const trainerRequested = { ...(ju.trainerRequested ?? {}) };
        if ((jr as { kind?: string }).kind === 'TRAINER') delete trainerRequested[g.tenantId];
        else delete requested[g.tenantId];
        t.set(P.user(jr.userId), { ...ju, requested, trainerRequested });
      }
      await notify(t, jr.userId, g.tenantId, 'Request declined', `${g.tenant.name} did not approve your request. Contact the gym if this is a mistake.`);
      audit(t, g.tenantId, u.id, 'join.decline', 'join_request', id);
    });
    return c.json({ ok: true }, 201);
  });

  // ---------- Memberships (owner and front desk) ----------

  app.get('/api/v1/members/:id/membership-preview', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    const { store } = c.var.deps;
    const m = await memberFor(store, g, c.req.param('id'));
    const planId = c.req.query('planId') ?? '';
    const plan = isUuid(planId) ? await store.get<PlanDoc>(P.plan(g.tenantId, planId)) : null;
    if (!plan) throw notFound('Plan not found');
    const roster = await readRoster(store, g.tenantId);
    const entry = roster.members[m.id] ?? rosterEntry(m);
    const today = todayIST();
    const first = validSubs(entry.subs).length === 0;
    const start = renewalStart(stateOf(entry, today), today);
    return c.json({ kind: first ? 'NEW' : 'RENEWAL', startDate: start, endDate: planEndDate(start, plan.months), price: plan.price, joiningFee: first ? plan.joiningFee : 0, freezeDays: plan.freezeDays, allowEntryWhileDue: g.tenant.allowEntryWhenDue });
  });

  app.post('/api/v1/members/:id/memberships', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const b = body(await c.req.json().catch(() => null));
    return c.json(await saveMembership(c, g, u.id, c.req.param('id'), b, null), 201);
  });

  /** Records a correction as a new entry. The old entry is kept in history. */
  app.post('/api/v1/memberships/:id/correct', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const b = body(await c.req.json().catch(() => null));
    const id = c.req.param('id');
    const old = isUuid(id) ? await c.var.deps.store.get<SubDoc>(P.sub(g.tenantId, id)) : null;
    if (!old) throw notFound('Membership not found');
    return c.json(await saveMembership(c, g, u.id, old.memberId, b, id), 201);
  });

  app.post('/api/v1/memberships/:id/payments', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const b = body(await c.req.json().catch(() => null));
    const amount = int(b, 'amount', { min: 1, max: 10_000_000, label: 'amount' });
    const mode = oneOf(b, 'mode', PAY_MODES)!;
    if (mode === 'NOT_PAID') throw bad('Choose how the money was paid');
    const note = optStr(b, 'note', { max: 300 }) ?? null;
    const id = c.req.param('id');
    const out = await c.var.deps.store.tx(async (t) => {
      if (isUuid(id)) await t.getMany([P.sub(g.tenantId, id), P.roster(g.tenantId), P.daily(g.tenantId, todayIST())]);
      const s = isUuid(id) ? await t.get<SubDoc>(P.sub(g.tenantId, id)) : null;
      if (!s) throw notFound('Membership not found');
      await memberFor(t, g, s.memberId);
      const roster = await readRoster(t, g.tenantId);
      if (!roster.members[s.memberId]?.subs.some((x) => x.id === id)) throw bad('This membership was corrected. Add the payment to the corrected entry');
      const due = s.total - paidOf(s);
      if (amount > due) throw bad(`Only ${inr(due)} is due`);
      const p = { id: `${id}_${uuid().slice(0, 8)}`, amount, mode, receivedById: u.id, receivedAt: nowIso(), note };
      const next = { ...s, payments: [...s.payments, p] };
      rosterPutSub(roster, s.memberId, next);
      t.set(P.sub(g.tenantId, id), next);
      t.set(P.roster(g.tenantId), roster);
      await bumpDaily(t, g.tenantId, { collected: amount, payments: 1 }, branchOf(g.tenant, roster.members[s.memberId]?.branchId));
      audit(t, g.tenantId, u.id, 'payment.create', 'payment', p.id, null, p);
      return { payment: p, due: due - amount };
    });
    return c.json(out, 201);
  });

  app.post('/api/v1/memberships/:id/freeze', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const b = body(await c.req.json().catch(() => null));
    const days = int(b, 'days', { min: 1, max: 365, label: 'days' });
    const reason = optStr(b, 'reason', { max: 300 }) ?? null;
    const id = c.req.param('id');
    const today = todayIST();
    const start = optStr(b, 'startDate') ?? today;
    if (!isYmd(start)) throw bad('Start date is not valid');
    const out = await c.var.deps.store.tx(async (t) => {
      const s = isUuid(id) ? await t.get<SubDoc>(P.sub(g.tenantId, id)) : null;
      if (!s) throw notFound('Membership not found');
      const m = await memberFor(t, g, s.memberId);
      const roster = await readRoster(t, g.tenantId);
      const st = stateOf(roster.members[m.id] ?? rosterEntry(m), today);
      const cur = st.current;
      if (!cur || cur.id !== id || !['ACTIVE', 'ENDING_SOON', 'FROZEN'].includes(st.status)) throw bad('Only the current, running membership can be frozen');
      if (activeFreeze(cur, today) || cur.freezes.some((f) => f.startDate > today && !f.endedOn)) throw bad('This membership already has a freeze. End it first');
      if (start < today) throw bad('A freeze cannot start in the past');
      if (start > effectiveEnd(cur)) throw bad('A freeze must start before the membership ends');
      const left = freezeDaysLeft(cur);
      if (left <= 0) throw forbidden('No freeze days left on this membership');
      if (days > left) throw bad(`Only ${left} freeze day${left === 1 ? '' : 's'} left on this membership`);
      const f: Freeze = { id: `${id}_${uuid().slice(0, 8)}`, startDate: start, days, endedOn: null, reason, createdById: u.id, createdAt: nowIso() };
      const next = { ...s, freezes: [...s.freezes, f] };
      rosterPutSub(roster, m.id, next);
      t.set(P.sub(g.tenantId, id), next);
      t.set(P.roster(g.tenantId), roster);
      audit(t, g.tenantId, u.id, 'membership.freeze', 'freeze', f.id, null, f);
      await notify(t, m.userId, g.tenantId, 'Membership frozen', `Your membership is frozen for ${days} day${days === 1 ? '' : 's'} from ${prettyDate(start)}. Your end date moves ahead by the same days.`);
      return { freeze: f, newEndDate: addDays(effectiveEnd(cur), days) };
    });
    return c.json(out, 201);
  });

  /** Ends a freeze early. Unused freeze days go back to the member. */
  app.post('/api/v1/freezes/:id/end', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c);
    const fid = c.req.param('id');
    const subId = fid.slice(0, 36);
    const today = todayIST();
    const out = await c.var.deps.store.tx(async (t) => {
      const s = isUuid(subId) ? await t.get<SubDoc>(P.sub(g.tenantId, subId)) : null;
      const f = s?.freezes.find((x) => x.id === fid);
      if (!s || !f) throw notFound('Freeze not found');
      await memberFor(t, g, s.memberId);
      if (f.endedOn || diffDays(f.startDate, today) >= f.days) throw bad('This freeze has already ended');
      const after = { ...f, endedOn: today < f.startDate ? f.startDate : today };
      const next = { ...s, freezes: s.freezes.map((x) => (x.id === fid ? after : x)) };
      const roster = await readRoster(t, g.tenantId);
      rosterPutSub(roster, s.memberId, next);
      t.set(P.sub(g.tenantId, subId), next);
      t.set(P.roster(g.tenantId), roster);
      audit(t, g.tenantId, u.id, 'membership.unfreeze', 'freeze', fid, f, after);
      return after;
    });
    return c.json(out, 201);
  });
}

/** Adds, renews or corrects a membership. Payments already received carry over to a correction. */
async function saveMembership(c: C, g: GymCtx, actorId: string, memberId: string, b: Record<string, unknown>, replacesId: string | null) {
  const planId = str(b, 'planId', { label: 'a plan' });
  const mode = oneOf(b, 'paymentMode', PAY_MODES)!;
  const priceIn = optInt(b, 'price', { min: 0, max: 10_000_000, label: 'price' });
  const discount = optInt(b, 'discount', { min: 0, max: 10_000_000, label: 'discount' }) ?? 0;
  const receivedIn = optInt(b, 'amountReceived', { min: 0, max: 10_000_000, label: 'amount received' });
  const allowIn = optBool(b, 'allowEntryWhileDue');
  const note = optStr(b, 'note', { max: 500 }) ?? null;
  const startIn = optStr(b, 'startDate');
  const endIn = optStr(b, 'endDate');
  const today = todayIST();

  const result = await c.var.deps.store.tx(async (t) => {
    // One batched read for everything this needs (the later reads come from it).
    await t.getMany([
      ...(isUuid(memberId) ? [P.member(g.tenantId, memberId)] : []),
      ...(isUuid(planId) ? [P.plan(g.tenantId, planId)] : []),
      P.tenant(g.tenantId),
      P.roster(g.tenantId),
      P.daily(g.tenantId, today),
      ...(replacesId && isUuid(replacesId) ? [P.sub(g.tenantId, replacesId)] : []),
    ]);
    const m = await memberFor(t, g, memberId);
    const plan = isUuid(planId) ? await t.get<PlanDoc>(P.plan(g.tenantId, planId)) : null;
    if (!plan) throw notFound('Plan not found');
    const tenant = (await t.get<TenantDoc>(P.tenant(g.tenantId)))!;
    const roster = await readRoster(t, g.tenantId);
    const entry: RosterEntry = roster.members[m.id] ?? rosterEntry(m);
    roster.members[m.id] = entry;
    const valid = validSubs(entry.subs);
    const state = stateOf(entry, today);

    let old: SubDoc | null = null;
    if (replacesId) {
      if (!valid.some((s) => s.id === replacesId)) throw notFound('Membership to correct not found');
      old = await t.get<SubDoc>(P.sub(g.tenantId, replacesId));
      if (!old) throw notFound('Membership to correct not found');
    }
    // Joining fee only on the first membership ever (a correction of the first keeps it).
    const isFirst = old ? valid.filter((s) => s.id !== old!.id && s.startDate < old!.startDate).length === 0 : valid.length === 0;
    const startDate = startIn ?? (old ? old.startDate : renewalStart(state, today));
    if (!isYmd(startDate)) throw bad('Start date is not valid');
    const endDate = endIn ?? planEndDate(startDate, plan.months);
    if (!isYmd(endDate)) throw bad('End date is not valid');
    if (endDate < startDate) throw bad('End date must be on or after the start date');
    const price = priceIn ?? plan.price;
    const joiningFee = isFirst ? (old ? old.joiningFee : plan.joiningFee) : 0;
    if (discount > price + joiningFee) throw bad('Discount cannot be more than the price');
    const total = price + joiningFee - discount;
    const alreadyPaid = old ? paidOf(old) : 0;
    let received = receivedIn ?? (mode === 'NOT_PAID' ? 0 : total - alreadyPaid);
    if (mode === 'NOT_PAID') received = 0;
    if (received + alreadyPaid > total) throw bad(`Amount received cannot be more than ${inr(Math.max(0, total - alreadyPaid))}`);
    if (received === 0 && mode !== 'NOT_PAID' && total - alreadyPaid > 0) throw bad('Enter the amount received, or choose "Not paid yet"');
    const due = total - alreadyPaid - received;

    const id = uuid();
    const s: SubDoc = {
      id,
      memberId: m.id,
      planId: plan.id,
      planName: plan.name,
      months: plan.months,
      startDate,
      endDate,
      price,
      joiningFee,
      discount,
      total,
      freezeDaysAllowed: old ? old.freezeDaysAllowed : plan.freezeDays,
      allowEntryWhileDue: due > 0 ? (allowIn ?? tenant.allowEntryWhenDue) : false,
      kind: old ? 'CORRECTION' : isFirst ? 'NEW' : 'RENEWAL',
      replacesId: old?.id ?? null,
      note,
      createdById: actorId,
      createdAt: nowIso(),
      carriedPaid: alreadyPaid,
      payments: received > 0 ? [{ id: `${id}_${uuid().slice(0, 8)}`, amount: received, mode, receivedById: actorId, receivedAt: nowIso(), note: null }] : [],
      freezes: old ? old.freezes : [],
    };
    rosterPutSub(roster, m.id, s);
    t.create(P.sub(g.tenantId, id), s);
    t.set(P.roster(g.tenantId), roster);
    if (received > 0) await bumpDaily(t, g.tenantId, { collected: received, payments: 1 }, branchOf(g.tenant, m.branchId));
    audit(t, g.tenantId, actorId, old ? 'membership.correct' : 'membership.create', 'subscription', id, old, { ...s, received });
    await notify(t, m.userId, g.tenantId, old ? 'Membership updated' : 'Membership added', `${tenant.name} ${old ? 'updated' : 'added'} your ${plan.name} membership: ${prettyDate(startDate)} to ${prettyDate(endDate)}.`);
    return { s, m, tenant, received, due };
  });

  const { s, m, tenant, received, due } = result;
  const receipt = [
    `Hi ${m.name}, your ${s.planName} membership at ${tenant.name} is confirmed.`,
    `Valid: ${prettyDate(s.startDate)} to ${prettyDate(s.endDate)}`,
    `Amount: ${inr(s.total)}${s.discount ? ` (discount ${inr(s.discount)})` : ''}`,
    received > 0 ? `Received: ${inr(received)} by ${s.payments[0].mode.replace('_', ' ').toLowerCase()}` : null,
    due > 0 ? `Due: ${inr(due)}` : null,
    `Member ID: ${m.memberCode}`,
    `- ${tenant.name}`,
  ]
    .filter(Boolean)
    .join('\n');
  return { subscription: s, due, whatsappReceipt: whatsappLink(m.phone, receipt) };
}
