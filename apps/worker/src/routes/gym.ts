import { superLater } from '../lib/superpush';
import { App, audit, authenticate, Branch, branchCode, cleanRights, gymOf, isTrainer, notify, P, RIGHT_PRESETS, RIGHTS, Role, Roster, TenantDoc, UserDoc } from '../core';
import { personDetails } from '../lib/person';
import { addMonths, todayIST } from '../lib/dates';
import { bad, conflict, forbidden, HttpError, notFound, nowIso, uuid } from '../lib/http';
import { normalizeEmail, normalizePhone } from '../lib/phone';
import { body, oneOf, optBool, optStr, str, strList } from '../lib/validate';
import type { Reader, Store } from '../store/store';
import { aliasEmail, createPasswordUser } from './auth';
import { pinMatchesState, stateByName } from '../lib/india';

export interface SaasPlan {
  id: string;
  name: string;
  monthlyPrice: number;
  annualPrice: number;
  memberLimit: number | null;
  branchLimit: number;
  staffLimit: number;
  whatsappLimit: number;
  features: string[];
  visible: boolean;
  sortOrder: number;
  createdAt: string;
}

/** During the free trial a gym gets the limits of the most generous visible plan. */
export async function gymLimits(r: Reader, t: TenantDoc) {
  const inTrial = t.status === 'TRIAL' && (!t.trialEndsAt || new Date(t.trialEndsAt) > new Date());
  let plan = t.saasPlanId ? await r.get<SaasPlan>(P.saasPlan(t.saasPlanId)) : null;
  if (inTrial || !plan) {
    const all = (await r.query<SaasPlan>(P.saasPlans)).map((x) => x.data).filter((p) => p.visible);
    all.sort((a, b) => b.sortOrder - a.sortOrder);
    plan = all[0] ?? null;
  }
  if (!plan) return { planName: 'Trial', memberLimit: null as number | null, branchLimit: 3, staffLimit: 10, features: [] as string[] };
  return { planName: inTrial ? `Free trial (${plan.name} features)` : plan.name, memberLimit: plan.memberLimit, branchLimit: plan.branchLimit, staffLimit: plan.staffLimit, features: plan.features };
}

async function uniqueGymCode(r: Reader, name: string) {
  const base = name.toUpperCase().replace(/[^A-Z]/g, '').slice(0, 4).padEnd(3, 'X');
  for (let i = 0; i < 20; i++) {
    const code = `${base}${100 + Math.floor(Math.random() * 900)}`;
    if (!(await r.get(P.gymCode(code)))) return code;
  }
  return `GM${100000 + Math.floor(Math.random() * 900000)}`;
}

/**
 * Branches made before branch codes existed have none. Give each one its own code the
 * first time the gym is opened (the first branch keeps the gym's code).
 */
export async function ensureBranchCodes(store: Store, tenantId: string, tenant: TenantDoc): Promise<TenantDoc> {
  // Every branch after the first needs a code that starts with its own name (Athelete → ATHE482).
  // Old codes made from the gym name keep working for 30 days, then stop.
  const base = (n: string) => n.toUpperCase().replace(/[^A-Z]/g, '').slice(0, 4).padEnd(3, 'X');
  const fix = tenant.branches.filter((b, i) => i > 0 && (!b.code || !b.code.startsWith(base(b.name))));
  if (!fix.length) return tenant;
  const codes = new Map<string, string>();
  for (const b of fix) {
    let code = await uniqueGymCode(store, b.name);
    while ([...codes.values()].includes(code)) code = await uniqueGymCode(store, b.name);
    codes.set(b.id, code);
  }
  const until = new Date(Date.now() + 30 * 86400000).toISOString();
  return store.tx(async (t) => {
    const cur = (await t.get<TenantDoc>(P.tenant(tenantId)))!;
    const branches = cur.branches.map((b) => {
      const code = codes.get(b.id);
      if (!code || (b.code && b.code.startsWith(base(b.name)))) return b;
      if (b.code && b.code !== cur.gymCode) t.set(P.gymCode(b.code), { tenantId, branchId: b.id, expiresAt: until });
      t.create(P.gymCode(code), { tenantId, branchId: b.id });
      return { ...b, code };
    });
    const next = { ...cur, branches };
    t.set(P.tenant(tenantId), next);
    return next;
  });
}

function prefixFrom(name: string) {
  const words = name.toUpperCase().replace(/[^A-Z ]/g, '').split(/\s+/).filter(Boolean);
  const p = words.map((w) => w[0]).join('').slice(0, 3);
  return p.length >= 2 ? p : (words[0] ?? 'GM').slice(0, 3);
}

/** Gym address: line, state (from the list), city, PIN that fits the state, optional GSTIN. */
function readAddress(b: Record<string, unknown>, required: boolean) {
  if (!required && b.state === undefined && b.city === undefined && b.pincode === undefined && b.addressLine === undefined) return null;
  const addressLine = str(b, 'addressLine', { min: 3, max: 200, label: 'the gym address' });
  const state = str(b, 'state', { label: 'the state' });
  const st = stateByName(state);
  if (!st) throw bad('Choose the state from the list');
  const city = str(b, 'city', { min: 2, max: 60, label: 'the city' });
  const pincode = str(b, 'pincode', { label: 'the PIN code' }).replace(/\s/g, '');
  if (!/^[1-9]\d{5}$/.test(pincode)) throw bad('Enter a valid 6-digit PIN code');
  if (!pinMatchesState(pincode, state)) throw bad(`This PIN code is not from ${state}. Check the PIN or the state`);
  const g = (optStr(b, 'gstin', { max: 15 }) ?? '').toUpperCase();
  if (g && !/^\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/.test(g)) throw bad('GSTIN is not valid');
  if (g && g.slice(0, 2) !== st.code) throw bad(`This GSTIN is not from ${state}`);
  return { addressLine, state, stateCode: st.code, city, pincode, gstin: g || null };
}

function phoneOrNull(v: string | undefined, label: string) {
  if (v === undefined) return undefined;
  if (!v) return null;
  const p = normalizePhone(v);
  if (!p) throw bad(`Enter a valid ${label}`);
  return p;
}

export function gymRoutes(app: App) {
  /** Any signed-in user can register their gym. It starts on the free trial. */
  app.post('/api/v1/gyms', async (c) => {
    const u = await authenticate(c);
    if (isTrainer(u) || Object.keys(u.trainerRequested ?? {}).length) throw bad('A trainer cannot register a gym');
    const { store } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    const name = str(b, 'name', { min: 2, max: 80, label: 'the gym name' });
    const place = readAddress(b, true)!;
    const address = [place.addressLine, place.city, place.state, place.pincode].join(', ');
    const phone = phoneOrNull(optStr(b, 'phone'), 'gym phone number') ?? null;
    const wa = phoneOrNull(optStr(b, 'whatsappNumber'), 'WhatsApp number') ?? phone;
    const settings = await store.get<{ trialMonths: number }>(P.platform);
    const code = await uniqueGymCode(store, name);
    const id = uuid();
    const branch: Branch = { id: uuid(), name: optStr(b, 'branchName', { max: 60 }) || 'Main', address, hours: null, createdAt: nowIso() };
    const tenant: TenantDoc = {
      name,
      gymCode: code,
      logoUrl: null,
      phone,
      address,
      whatsappNumber: wa,
      status: 'TRIAL',
      verified: false,
      trialEndsAt: `${addMonths(todayIST(), settings?.trialMonths ?? 3)}T18:29:59.000Z`,
      saasPlanId: null,
      customMonthlyPrice: null,
      allowEntryWhenDue: false,
      memberCodePrefix: prefixFrom(name),
      nextMemberNumber: 1001,
      memberCount: 0,
      branches: [branch],
      createdAt: nowIso(),
      ...place,
      planCycle: null,
      planEndsAt: null,
    };
    await store.tx(async (t) => {
      const cur = (await t.get<UserDoc>(P.user(u.id)))!;
      t.create(P.gymCode(code), { tenantId: id });
      t.create(P.tenant(id), tenant);
      t.set(P.roster(id), { members: {} });
      t.set(P.staff(id, u.id), { userId: u.id, role: 'OWNER', branchIds: [branch.id], active: true, createdAt: nowIso() });
      t.set(P.user(u.id), { ...cur, appRole: 'OWNER', staffOf: { ...cur.staffOf, [id]: { role: 'OWNER', branchIds: [branch.id], active: true } } });
      audit(t, id, u.id, 'gym.create', 'tenant', id, null, tenant);
    });
    superLater(c, 'gyms', 'New gym registered', `${tenant.name}${tenant.city ? ` · ${tenant.city}` : ''} · free trial`);
    return c.json({ id, ...tenant }, 201);
  });

  app.get('/api/v1/gym', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    g.tenant = await ensureBranchCodes(c.var.deps.store, g.tenantId, g.tenant);
    const branches = g.tenant.branches.map((b) => ({ ...b, code: branchCode(g.tenant, b) }));
    return c.json({ id: g.tenantId, ...g.tenant, branches, allowTransfer: g.tenant.allowTransfer ?? false, myRole: g.role, myBranchIds: g.branchIds, currentBranchId: g.branchId, limits: await gymLimits(c.var.deps.store, g.tenant) });
  });

  app.patch('/api/v1/gym', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const patch: Partial<TenantDoc> = {};
    if (b.name !== undefined) patch.name = str(b, 'name', { min: 2, max: 80, label: 'the gym name' });
    if (b.address !== undefined) patch.address = optStr(b, 'address', { max: 300 }) ?? null;
    const place = readAddress(b, false);
    if (place) Object.assign(patch, place, { address: [place.addressLine, place.city, place.state, place.pincode].join(', ') });
    if (b.logoUrl !== undefined) patch.logoUrl = optStr(b, 'logoUrl', { max: 500 }) ?? null;
    const phone = phoneOrNull(optStr(b, 'phone') ?? (b.phone === '' ? '' : undefined), 'gym phone number');
    if (phone !== undefined) patch.phone = phone;
    const wa = phoneOrNull(optStr(b, 'whatsappNumber') ?? (b.whatsappNumber === '' ? '' : undefined), 'WhatsApp number');
    if (wa !== undefined) patch.whatsappNumber = wa;
    const allow = optBool(b, 'allowEntryWhenDue');
    if (allow !== undefined) patch.allowEntryWhenDue = allow;
    const transfer = optBool(b, 'allowTransfer');
    if (transfer !== undefined) patch.allowTransfer = transfer;
    if (b.memberCodePrefix !== undefined) {
      const p = str(b, 'memberCodePrefix', { max: 5 });
      if (!/^[A-Z]{1,5}$/.test(p)) throw bad('Member code prefix must be 1-5 capital letters');
      patch.memberCodePrefix = p;
    }
    const after = await c.var.deps.store.tx(async (t) => {
      const before = (await t.get<TenantDoc>(P.tenant(g.tenantId)))!;
      const next = { ...before, ...patch };
      t.set(P.tenant(g.tenantId), next);
      audit(t, g.tenantId, u.id, 'gym.update', 'tenant', g.tenantId, before, next);
      return next;
    });
    return c.json({ id: g.tenantId, ...after });
  });

  app.post('/api/v1/gym/branches', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const name = str(b, 'name', { min: 2, max: 60, label: 'the branch name' });
    // Every branch has its own join code (the first branch keeps the gym's old code).
    const code = await uniqueGymCode(c.var.deps.store, name);
    const branch: Branch = { id: uuid(), name, address: optStr(b, 'address', { max: 300 }) ?? null, hours: optStr(b, 'hours', { max: 120 }) ?? null, code, createdAt: nowIso() };
    const limits = await gymLimits(c.var.deps.store, g.tenant);
    await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<TenantDoc>(P.tenant(g.tenantId)))!;
      if (cur.branches.length >= limits.branchLimit) throw forbidden(`Your ${limits.planName} plan allows ${limits.branchLimit} branch${limits.branchLimit === 1 ? '' : 'es'}`);
      t.create(P.gymCode(code), { tenantId: g.tenantId, branchId: branch.id });
      t.set(P.tenant(g.tenantId), { ...cur, branches: [...cur.branches, branch] });
      audit(t, g.tenantId, u.id, 'branch.create', 'branch', branch.id, null, branch);
    });
    return c.json({ ...branch, code }, 201);
  });

  /** Delete a branch that has no members. */
  app.delete('/api/v1/gym/branches/:id', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    await c.var.deps.store.tx(async (t) => {
      const [cur, roster] = (await t.getMany<any>([P.tenant(g.tenantId), P.roster(g.tenantId)])) as [TenantDoc, Roster | null];
      const br = cur.branches.find((b) => b.id === id);
      if (!br) throw notFound('Branch not found');
      if (cur.branches.length <= 1) throw bad('A gym needs at least one branch');
      if (Object.values(roster?.members ?? {}).some((e) => e.branchId === id && !e.archived)) throw bad('Move the members of this branch first, then delete it');
      t.set(P.tenant(g.tenantId), { ...cur, branches: cur.branches.filter((b) => b.id !== id) });
      if (br.code && br.code !== cur.gymCode) t.delete(P.gymCode(br.code));
      audit(t, g.tenantId, u.id, 'branch.delete', 'branch', id, br, null);
    });
    return c.json({ ok: true });
  });

  app.patch('/api/v1/gym/branches/:id', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const out = await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<TenantDoc>(P.tenant(g.tenantId)))!;
      const before = cur.branches.find((x) => x.id === id);
      if (!before) throw notFound('Branch not found');
      const after = { ...before, name: str(b, 'name', { min: 2, max: 60 }), address: optStr(b, 'address', { max: 300 }) ?? null, hours: optStr(b, 'hours', { max: 120 }) ?? null };
      t.set(P.tenant(g.tenantId), { ...cur, branches: cur.branches.map((x) => (x.id === id ? after : x)) });
      audit(t, g.tenantId, u.id, 'branch.update', 'branch', id, before, after);
      return after;
    });
    return c.json(out);
  });

  type StaffDoc = { userId: string; role: Role; branchIds: string[]; active: boolean; createdAt: string; rights?: string[] };

  /** Staff of the branch the owner is looking at (each branch has its own staff), plus the gym's owners. */
  app.get('/api/v1/gym/staff', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const { store } = c.var.deps;
    const rows = (await store.query<StaffDoc>(P.staffCol(g.tenantId), [['active', true]])).filter(
      (r) => r.data.role === 'OWNER' || (r.data.role === 'FRONT_DESK' && (!(r.data.branchIds ?? []).length || r.data.branchIds.includes(g.branchId))),
    );
    rows.sort((a, b) => (a.data.role === b.data.role ? (a.data.createdAt < b.data.createdAt ? -1 : 1) : a.data.role === 'OWNER' ? -1 : 1));
    const users = await store.getMany<UserDoc>(rows.map((r) => P.user(r.id)));
    return c.json(
      rows.map((r, i) => ({
        id: r.id,
        role: r.data.role,
        active: r.data.active,
        branchIds: r.data.branchIds,
        rights: r.data.role === 'OWNER' ? [...RIGHTS] : cleanRights(r.data.rights),
        user: {
          id: r.id,
          name: users[i]?.name ?? 'Staff',
          email: users[i]?.email ?? null,
          phone: users[i]?.phone ?? null,
          photoUrl: users[i]?.photoV ? `/api/v1/photos/${r.id}?v=${users[i]!.photoV}` : null,
          waitingForLogin: !!users[i]?.mustSetPassword,
        },
      })),
    );
  });

  const rightsFrom = (b: Record<string, unknown>) => {
    const preset = typeof b.preset === 'string' ? RIGHT_PRESETS[b.preset] : undefined;
    return preset ? [...preset] : cleanRights(b.rights);
  };

  /**
   * Owner adds staff with full details, like Add member (board 62). A new person gets a GymMantra account
   * made by the gym: they log in as "Gym staff" with Google, or set a password first (same as gym-made members).
   */
  app.post('/api/v1/gym/staff', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const { store, identity } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    const role = oneOf(b, 'role', ['OWNER', 'FRONT_DESK'] as const, true) ?? 'FRONT_DESK';
    const d = typeof b.firstName === 'string' ? personDetails(b) : null;
    const name = d ? d.name : str(b, 'name', { min: 2, max: 80, label: 'the name' });
    const phone = normalizePhone(str(b, 'phone', { label: 'the mobile number' }));
    if (!phone) throw bad('Enter a valid 10-digit mobile number');
    const emailIn = optStr(b, 'email');
    const email = emailIn ? normalizeEmail(emailIn) : null;
    if (emailIn && !email) throw bad('Enter a valid email address');
    let branchIds: string[] = [];
    if (role === 'FRONT_DESK') {
      const bid = optStr(b, 'branchId') ?? (strList(b, 'branchIds', 20) ?? [])[0] ?? g.branchId;
      branchIds = checkBranches(g.tenant, [bid]);
    }
    const rights = role === 'OWNER' ? [] : rightsFrom(b);
    const limits = await gymLimits(store, g.tenant);
    const count = (await store.query<{ role: Role }>(P.staffCol(g.tenantId), [['active', true]])).filter((r) => r.data.role !== 'TRAINER').length;
    if (count >= limits.staffLimit) throw forbidden(`Your ${limits.planName} plan allows ${limits.staffLimit} staff accounts`);

    let uid = (await store.get<{ uid: string }>(P.phone(phone)))?.uid ?? null;
    if (uid && (await store.get<UserDoc>(P.user(uid)))?.deleted) uid = null;
    if (!uid && email) uid = (await store.query<UserDoc>('users', [['email', email]])).find((r) => !r.data.deleted)?.id ?? null;
    let made: { uid: string; idToken?: string; authEmail: string; pw: string } | null = null;
    const tempPw = optStr(b, 'tempPassword', { max: 100 });
    if (!uid && tempPw) {
      // Website: the owner gives a first password.
      if (tempPw.length < 8) throw bad('Set a temporary password (at least 8 characters) for the new staff account');
      uid = (await createPasswordUser(c, { name, email, phone, password: tempPw, appRole: role === 'OWNER' ? 'OWNER' : 'STAFF' })).uid;
    }
    if (!uid) {
      if (!email) throw bad('Enter the email ID');
      const pw = `${crypto.randomUUID()}Aa1!`;
      let authEmail = email;
      let fb: { uid: string; idToken?: string };
      try {
        fb = await identity.signUp(authEmail, pw);
      } catch (e) {
        if (!(e instanceof HttpError && e.message === 'EMAIL_EXISTS')) throw e;
        authEmail = aliasEmail(email); // an old login with no live account: give them a fresh one
        fb = await identity.signUp(authEmail, pw);
      }
      made = { ...fb, authEmail, pw };
    }
    const staffUid = uid ?? made!.uid;
    try {
      await store.tx(async (t) => {
        const prev = await t.get<StaffDoc>(P.staff(g.tenantId, staffUid));
        if (prev?.active) throw conflict('This person is already staff at your gym');
        const s: StaffDoc = { userId: staffUid, role, branchIds, active: true, createdAt: nowIso(), rights };
        if (made) {
          if (await t.get(P.phone(phone))) throw conflict('This mobile number already has a GymMantra account');
          t.create(P.phone(phone), { uid: staffUid });
          const nu: UserDoc = {
            name,
            email,
            authEmail: made.authEmail,
            fbUid: made.uid,
            phone,
            googleSub: null,
            photoV: null,
            language: 'en',
            isSuperAdmin: false,
            failed: 0,
            lockedUntil: null,
            createdAt: nowIso(),
            memberships: {},
            requested: {},
            staffOf: { [g.tenantId]: { role, branchIds, active: true, rights } },
            appRole: role === 'OWNER' ? 'OWNER' : 'STAFF',
            ...(d ? { firstName: d.firstName, middleName: d.middleName, lastName: d.lastName, dob: d.dob, gender: d.gender, state: d.state, city: d.city, country: d.country, pincode: d.pincode } : {}),
            createdByGym: { tenantId: g.tenantId, gymName: g.tenant.name },
            mustSetPassword: true,
            initPw: made.pw,
          } as UserDoc;
          t.set(P.user(staffUid), nu);
          const st = (await t.get<{ users: number }>(P.stats)) ?? { users: 0 };
          t.set(P.stats, { ...st, users: (st.users ?? 0) + 1 });
        } else {
          const target = (await t.get<UserDoc>(P.user(staffUid)))!;
          if (isTrainer(target)) throw bad('This person is a trainer. A trainer cannot be gym staff');
          t.set(P.user(staffUid), {
            ...target,
            appRole: target.appRole && target.appRole !== 'MEMBER' ? target.appRole : role === 'OWNER' ? 'OWNER' : 'STAFF',
            staffOf: { ...target.staffOf, [g.tenantId]: { role, branchIds, active: true, rights } },
          });
        }
        t.set(P.staff(g.tenantId, staffUid), s);
        audit(t, g.tenantId, u.id, 'staff.create', 'staff', staffUid, null, s);
        await notify(t, staffUid, g.tenantId, 'You are gym staff now', `${g.tenant.name} added you as ${role === 'OWNER' ? 'an owner' : 'staff'}. Log in as "Gym staff".`);
      });
    } catch (e) {
      if (made?.idToken) await identity.deleteAccount(made.idToken).catch(() => {});
      throw e;
    }
    return c.json({ id: staffUid, role, branchIds, rights, active: true, accountMade: !!made }, 201);
  });

  app.patch('/api/v1/gym/staff/:id', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    const b = body(await c.req.json().catch(() => null));
    const role = oneOf(b, 'role', ['OWNER', 'FRONT_DESK'] as const, true);
    const active = optBool(b, 'active');
    const bid = optStr(b, 'branchId');
    const branchIds = bid ? checkBranches(g.tenant, [bid]) : b.branchIds !== undefined ? checkBranches(g.tenant, strList(b, 'branchIds', 20) ?? []) : undefined;
    const rights = b.rights !== undefined || b.preset !== undefined ? rightsFrom(b) : undefined;
    const { store } = c.var.deps;
    const out = await store.tx(async (t) => {
      const before = await t.get<StaffDoc>(P.staff(g.tenantId, id));
      if (!before) throw notFound('Staff not found');
      if (before.role === 'TRAINER') throw bad('Use the Trainers page to manage trainers');
      if (before.role === 'OWNER' && (role === 'FRONT_DESK' || active === false)) {
        const owners = (await t.query<{ role: Role; active: boolean }>(P.staffCol(g.tenantId), [['role', 'OWNER']])).filter((r) => r.data.active);
        if (owners.length <= 1) throw forbidden('A gym needs at least one owner. Make someone else owner first, or ask GymMantra support to transfer the gym');
      }
      const after: StaffDoc = { ...before, role: role ?? before.role, active: active ?? before.active, branchIds: branchIds ?? before.branchIds, rights: rights ?? before.rights };
      const target = (await t.get<UserDoc>(P.user(id)))!;
      t.set(P.staff(g.tenantId, id), after);
      t.set(P.user(id), { ...target, staffOf: { ...target.staffOf, [g.tenantId]: { role: after.role, branchIds: after.branchIds, active: after.active, rights: after.rights } } });
      audit(t, g.tenantId, u.id, active === false ? 'staff.remove' : 'staff.update', 'staff', id, before, after);
      if (active === false) await notify(t, id, g.tenantId, 'Removed from gym staff', `${g.tenant.name} removed you from its staff. Your GymMantra login stays the same.`);
      return after;
    });
    return c.json({ id, ...out, rights: out.role === 'OWNER' ? [...RIGHTS] : cleanRights(out.rights) });
  });

  /** Owner removes staff from the gym. Their GymMantra login stays (board 60). */
  app.delete('/api/v1/gym/staff/:id', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const id = c.req.param('id');
    if (id === u.id) throw bad('You cannot remove yourself');
    await c.var.deps.store.tx(async (t) => {
      const before = await t.get<StaffDoc>(P.staff(g.tenantId, id));
      if (!before || !before.active || before.role === 'TRAINER') throw notFound('Staff not found');
      if (before.role === 'OWNER') {
        const owners = (await t.query<{ role: Role; active: boolean }>(P.staffCol(g.tenantId), [['role', 'OWNER']])).filter((r) => r.data.active);
        if (owners.length <= 1) throw forbidden('A gym needs at least one owner');
      }
      const target = await t.get<UserDoc>(P.user(id));
      t.set(P.staff(g.tenantId, id), { ...before, active: false });
      if (target) t.set(P.user(id), { ...target, staffOf: { ...target.staffOf, [g.tenantId]: { ...target.staffOf[g.tenantId], role: before.role, branchIds: before.branchIds, active: false } } });
      audit(t, g.tenantId, u.id, 'staff.remove', 'staff', id, before, null);
      await notify(t, id, g.tenantId, 'Removed from gym staff', `${g.tenant.name} removed you from its staff. Your GymMantra login stays the same.`);
    });
    return c.json({ ok: true });
  });

  app.get('/api/v1/gym/audit', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const rows = await c.var.deps.store.query<{ createdAt: string }>(P.audit(g.tenantId), [['month', new Date().toISOString().slice(0, 7)]]);
    return c.json(rows.map((r) => ({ id: r.id, ...r.data })).sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)));
  });
}

export function checkBranches(t: TenantDoc, ids: string[]) {
  const set = [...new Set(ids)];
  if (set.some((id) => !t.branches.some((b) => b.id === id))) throw bad('Unknown branch');
  return set;
}

export { HttpError };
