import { P } from '../src/core';
import { makeQrToken } from '../src/lib/qr';
import { addDays, todayIST } from '../src/lib/dates';
import { EMULATOR, GYM_ADDRESS, resetEmulator, setup } from './helpers';

let h: ReturnType<typeof setup>;
beforeEach(async () => {
  if (EMULATOR) await resetEmulator();
  h = setup();
});
const qrSecret = async () => ((await h.store.get<any>(P.secrets)) as any).qr as string;

describe('auth', () => {
  it('signs up and logs in with email or phone', async () => {
    const u = await h.signup();
    expect((await h.api.post('/auth/login', { identifier: u.email, password: 'secret123' })).status).toBe(200);
    expect((await h.api.post('/auth/login', { identifier: u.phone, password: 'secret123' })).status).toBe(200);
    const me = await h.api.get('/auth/me', u.token);
    expect(me.body.user.email).toBe(u.email);
    // Firebase holds the password account
    if (!EMULATOR) expect(h.identity.accounts.has(u.email)).toBe(true);
  });

  it('refuses a login with a role the account does not have', async () => {
    const M = { 'x-gm-client': 'mobile' };
    const owner = await h.ownerWithGym('Role Gym');
    // A new member account signs up from the Member screen.
    const ph = h.nextPhone();
    const s = await h.api.post('/auth/signup', { name: 'Role Member', email: `r${ph}@test.in`, phone: ph, password: 'secret123', role: 'MEMBER' }, undefined, M);
    expect(s.status).toBe(201);
    expect(s.body.user.appRole).toBe('MEMBER');
    const asOwner = await h.api.post('/auth/login', { identifier: ph, password: 'secret123', role: 'OWNER' }, undefined, M);
    expect(asOwner.status).toBe(403);
    expect(asOwner.body.error ?? asOwner.body.message ?? JSON.stringify(asOwner.body)).toContain('registered as a Member');
    expect((await h.api.post('/auth/login', { identifier: ph, password: 'secret123', role: 'TRAINER' }, undefined, M)).status).toBe(403);
    expect((await h.api.post('/auth/login', { identifier: ph, password: 'secret123', role: 'MEMBER' }, undefined, M)).status).toBe(200);
    // The gym owner cannot open the member side either.
    expect((await h.api.post('/auth/login', { identifier: owner.phone, password: 'secret123', role: 'MEMBER' }, undefined, M)).status).toBe(403);
    expect((await h.api.post('/auth/login', { identifier: owner.phone, password: 'secret123', role: 'OWNER' }, undefined, M)).status).toBe(200);
    // An old account without a role takes the one chosen at log-in, and keeps it.
    const old = await h.signup('Old User');
    expect((await h.api.post('/auth/login', { identifier: old.phone, password: 'secret123', role: 'TRAINER' }, undefined, M)).body.user.appRole).toBe('TRAINER');
    expect((await h.api.post('/auth/login', { identifier: old.phone, password: 'secret123', role: 'OWNER' }, undefined, M)).status).toBe(403);
    // Once linked to a gym, the role cannot be switched in the profile.
    const tok = (await h.api.post('/auth/login', { identifier: ph, password: 'secret123', role: 'MEMBER' }, undefined, M)).body.token;
    expect((await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, tok)).status).toBe(201);
    expect((await h.api.patch('/me/profile', { appRole: 'OWNER' }, tok)).status).toBe(400);
  });

  it('rejects a duplicate signup', async () => {
    const u = await h.signup();
    expect((await h.api.post('/auth/signup', { name: 'Dup User', email: u.email, phone: h.nextPhone(), password: 'secret123' })).status).toBe(409);
    expect((await h.api.post('/auth/signup', { name: 'Dup User', email: 'other@test.in', phone: u.phone, password: 'secret123' })).status).toBe(409);
  });

  it('locks the account after 3 wrong passwords', async () => {
    const u = await h.signup();
    const r1 = await h.api.post('/auth/login', { identifier: u.email, password: 'wrong1' });
    expect(r1.status).toBe(401);
    expect(r1.body.message).toContain('2 attempts left');
    expect((await h.api.post('/auth/login', { identifier: u.email, password: 'wrong2' })).status).toBe(401);
    const r3 = await h.api.post('/auth/login', { identifier: u.email, password: 'wrong3' });
    expect(r3.status).toBe(429);
    expect(r3.body.message).toMatch(/Too many attempts. Try again in 15 minutes/);
    expect((await h.api.post('/auth/login', { identifier: u.email, password: 'secret123' })).status).toBe(429);
    const user = (await h.store.get<any>(P.user(u.user.id)))!;
    await h.store.set(P.user(u.user.id), { ...user, lockedUntil: new Date(Date.now() - 1000).toISOString() });
    expect((await h.api.post('/auth/login', { identifier: u.email, password: 'secret123' })).status).toBe(200);
  });

  it('forgot password sends a reset email for email or mobile', async () => {
    const u = await h.signup();
    const r = await h.api.post('/auth/forgot', { identifier: u.phone });
    expect(r.status).toBe(200);
    expect(r.body.to).toMatch(/^u•+@test\.in$/);
    expect((await h.api.post('/auth/forgot', { identifier: 'nobody@test.in' })).status).toBe(404);
    if (!(h.deps.identity as any).resets) return;
    expect((h.deps.identity as any).resets).toContain(u.email);
  });

  it('sign-up: a used mobile number gets a clear message, a new email works', async () => {
    const u = await h.signup();
    const r = await h.api.post('/auth/signup', { name: 'Other', email: 'other@test.in', phone: u.phone, password: 'secret123' });
    expect(r.status).toBe(409);
    expect(r.body.message).toMatch(/mobile number already exists/);
    const e = await h.api.post('/auth/signup', { name: 'Other', email: u.email, phone: h.nextPhone(), password: 'secret123' });
    expect(e.status).toBe(409);
    expect(e.body.message).toMatch(/email ID already exists/);
    const ok = await h.api.post('/auth/signup', { name: 'Other', email: 'other@test.in', phone: h.nextPhone(), password: 'secret123' });
    expect(ok.status).toBe(201);
  });

  it('sign-up finishes a half-made login (Firebase account but no GymMantra record)', async () => {
    const email = 'half@test.in';
    await h.deps.identity.signUp(email, 'secret123'); // left behind by an earlier failed sign-up
    // Same password: the old login is used again.
    const r = await h.api.post('/auth/signup', { name: 'Half', email, phone: h.nextPhone(), password: 'secret123' });
    expect(r.status).toBe(201);
    expect((await h.api.post('/auth/login', { identifier: email, password: 'secret123' })).status).toBe(200);
    // Another password on another left-behind login: a fresh login is made, never "email taken".
    const email2 = 'half2@test.in';
    await h.deps.identity.signUp(email2, 'secret123');
    const r2 = await h.api.post('/auth/signup', { name: 'Half Two', email: email2, phone: h.nextPhone(), password: 'other-pass1' });
    expect(r2.status).toBe(201);
    expect((await h.api.post('/auth/login', { identifier: email2, password: 'other-pass1' })).status).toBe(200);
  });

  it('reset link page sets a new password and clears the lock', async () => {
    if (!(h.deps.identity as any).resets) return; // reset codes cannot be read from the emulator here
    const u = await h.signup();
    for (let i = 0; i < 3; i++) await h.api.post('/auth/login', { identifier: u.email, password: 'wrong-pass' });
    expect((await h.api.post('/auth/login', { identifier: u.email, password: 'secret123' })).status).toBe(429);
    const chk = await h.api.post('/auth/reset/check', { oobCode: `reset:${u.email}` });
    expect(chk.status).toBe(200);
    expect(chk.body.email).toMatch(/^u•+@test\.in$/);
    expect((await h.api.post('/auth/reset/check', { oobCode: 'bad' })).status).toBe(400);
    expect((await h.api.post('/auth/reset', { oobCode: `reset:${u.email}`, password: 'brandnew1' })).status).toBe(200);
    expect((await h.api.post('/auth/login', { identifier: u.email, password: 'brandnew1' })).status).toBe(200);
  });

  it('accepts real-length Google tokens', async () => {
    const r = await h.api.post('/auth/google/login', { idToken: 'x'.repeat(1200) });
    expect(r.status).toBe(401);
  });

  it('Google login only works after Google signup', async () => {
    expect((await h.api.post('/auth/google/login', { idToken: 'google:g-1:g1@test.in' })).status).toBe(404);
    expect((await h.api.post('/auth/google/signup', { idToken: 'google:g-1:g1@test.in' })).status).toBe(201);
    expect((await h.api.post('/auth/google/login', { idToken: 'google:g-1:g1@test.in' })).status).toBe(200);
    // Signing up again just logs in to the same account
    const again = await h.api.post('/auth/google/signup', { idToken: 'google:g-1:g1@test.in' });
    expect(again.status).toBe(200);
    expect(again.body.existing).toBe(true);
  });

  it('Google with the same verified email opens the same password account (no second account)', async () => {
    const u = await h.signup();
    const g = await h.api.post('/auth/google/signup', { idToken: `google:g-2:${u.email}` });
    expect(g.status).toBe(200);
    expect(g.body.user.email).toBe(u.email);
    expect((await h.api.post('/auth/google/login', { idToken: `google:g-2:${u.email}` })).body.user.id).toBe(g.body.user.id);
    // Google without a verified email cannot take an account
    expect((await h.api.post('/auth/google/login', { idToken: 'google:g-3:' })).status).toBe(404);
  });

  it('cookie sessions need the client header for writes', async () => {
    const u = await h.signup();
    const cookie = { cookie: `gm_session=${u.token}` };
    expect((await h.api.post('/gyms', { name: 'Cookie Gym' }, undefined, cookie)).status).toBe(403);
    expect((await h.api.post('/gyms', { name: 'Cookie Gym', ...GYM_ADDRESS }, undefined, { ...cookie, 'x-gm-client': 'admin' })).status).toBe(201);
  });

  it('gym owners can use the app; the super admin cannot', async () => {
    const owner = await h.ownerWithGym('App Gym');
    const mobile = { 'x-gm-client': 'mobile' };
    const r = await h.api.post('/auth/login', { identifier: owner.email, password: 'secret123' }, undefined, mobile);
    expect(r.status).toBe(200);
    expect(r.body.user.isOwner).toBe(true);
    expect(r.body.user.appRole).toBe('OWNER');
    expect((await h.api.get('/dashboard', owner.token, mobile)).status).toBe(200);
    await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' });
    const s = await h.api.post('/auth/login', { identifier: 'boss@gymmantra.app', password: 'secret123' }, undefined, mobile);
    expect(s.status).toBe(403);
    expect(s.body.message).toMatch(/website/);
  });

  it('the super admin email becomes super admin', async () => {
    const r = await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' });
    expect(r.body.user.isSuperAdmin).toBe(true);
  });
});

describe('gym, members and memberships', () => {
  let A: any, B: any, planA: any, memberA: any;
  beforeEach(async () => {
    A = await h.ownerWithGym('Gym A');
    B = await h.ownerWithGym('Gym B');
    planA = (await h.api.post('/plans', { name: 'Quarterly', months: 3, price: 4000, joiningFee: 500, freezeDays: 10 }, A.token)).body;
    memberA = (await h.api.post('/members', { name: 'Rahul', phone: h.nextPhone() }, A.token)).body;
  });

  it('gym B cannot see or change gym A data', async () => {
    expect((await h.api.get(`/members/${memberA.id}`, B.token)).status).toBe(404);
    expect((await h.api.patch(`/members/${memberA.id}`, { name: 'Hacked' }, B.token)).status).toBe(404);
    expect((await h.api.patch(`/plans/${planA.id}`, { price: 1 }, B.token)).status).toBe(404);
    expect((await h.api.post(`/members/${memberA.id}/memberships`, { planId: planA.id, paymentMode: 'CASH' }, B.token)).status).toBe(404);
    const list = await h.api.get('/members', B.token);
    expect(list.body.rows.find((r: any) => r.id === memberA.id)).toBeUndefined();
    expect((await h.api.get('/members', B.token, { 'x-gym-id': A.gym.id })).status).toBe(403);
    const { token } = await makeQrToken(await qrSecret(), memberA.id);
    expect((await h.api.post('/attendance/scan', { token }, B.token)).status).toBe(404);
  });

  it('adds a membership with joining fee and discount, then renews from the end date', async () => {
    const r = await h.api.post(`/members/${memberA.id}/memberships`, { planId: planA.id, discount: 300, paymentMode: 'UPI' }, A.token);
    expect(r.status).toBe(201);
    expect(r.body.subscription.total).toBe(4200);
    expect(r.body.subscription.kind).toBe('NEW');
    expect(r.body.whatsappReceipt).toContain('https://wa.me/91');
    const prev = await h.api.get(`/members/${memberA.id}/membership-preview?planId=${planA.id}`, A.token);
    expect(prev.body.kind).toBe('RENEWAL');
    expect(prev.body.joiningFee).toBe(0);
    expect(prev.body.startDate).toBe(addDays(r.body.subscription.endDate, 1));
    const dash = await h.api.get('/dashboard', A.token);
    expect(dash.body.today.collected).toBe(4200);
    expect(dash.body.totals.active).toBe(1);
  });

  it('reports money, visits and plans for the period', async () => {
    await h.api.post(`/members/${memberA.id}/memberships`, { planId: planA.id, paymentMode: 'UPI' }, A.token);
    const r = await h.api.get('/reports?days=7', A.token);
    expect(r.status).toBe(200);
    expect(r.body.series).toHaveLength(7);
    expect(r.body.totals.collected).toBe(4500);
    expect(r.body.totals.sold).toBe(1);
    expect(r.body.totals.newMembers).toBe(1);
    expect(r.body.plans[0]).toMatchObject({ name: 'Quarterly', active: 1, sold: 1 });
    // gym B sees only its own numbers
    expect((await h.api.get('/reports', B.token)).body.totals.collected).toBe(0);
  });

  it('freezes the current membership within the allowed days', async () => {
    await h.api.post(`/members/${memberA.id}/memberships`, { planId: planA.id, paymentMode: 'CASH' }, A.token);
    const d = await h.api.get(`/members/${memberA.id}`, A.token);
    const subId = d.body.state.currentId;
    expect((await h.api.post(`/memberships/${subId}/freeze`, { days: 11 }, A.token)).status).toBe(400);
    const f = await h.api.post(`/memberships/${subId}/freeze`, { days: 4 }, A.token);
    expect(f.status).toBe(201);
    const d2 = await h.api.get(`/members/${memberA.id}`, A.token);
    expect(d2.body.state.status).toBe('FROZEN');
    expect(d2.body.state.entry.result).toBe('BLOCKED');
    expect((await h.api.post(`/freezes/${f.body.freeze.id}/end`, {}, A.token)).status).toBe(201);
    const d3 = await h.api.get(`/members/${memberA.id}`, A.token);
    expect(d3.body.state.status).not.toBe('FROZEN');
  });

  it('not paid yet: admin decides entry; later payment clears the due', async () => {
    const m = (await h.api.post('/members', { name: 'Due Person', phone: h.nextPhone() }, A.token)).body;
    const r = await h.api.post(`/members/${m.id}/memberships`, { planId: planA.id, paymentMode: 'NOT_PAID', allowEntryWhileDue: false }, A.token);
    expect(r.body.due).toBe(4500);
    const s1 = await h.api.post('/attendance/manual', { memberId: m.id }, A.token);
    expect(s1.body.result).toBe('BLOCKED');
    expect(s1.body.reason).toContain('Payment due');
    const m2 = (await h.api.post('/members', { name: 'Allowed Due', phone: h.nextPhone() }, A.token)).body;
    await h.api.post(`/members/${m2.id}/memberships`, { planId: planA.id, paymentMode: 'NOT_PAID', allowEntryWhileDue: true }, A.token);
    expect((await h.api.post('/attendance/manual', { memberId: m2.id }, A.token)).body.result).toBe('WARNED');
    expect((await h.api.post(`/memberships/${r.body.subscription.id}/payments`, { amount: 5000, mode: 'CASH' }, A.token)).status).toBe(400);
    expect((await h.api.post(`/memberships/${r.body.subscription.id}/payments`, { amount: 4500, mode: 'CASH' }, A.token)).status).toBe(201);
    expect((await h.api.post('/attendance/manual', { memberId: m.id }, A.token)).body.result).toBe('ALLOWED');
  });

  it('ignores a second scan within 2 minutes and blocks members with no plan', async () => {
    const m = (await h.api.post('/members', { name: 'Scanner', phone: h.nextPhone() }, A.token)).body;
    expect((await h.api.post('/attendance/manual', { memberId: m.id }, A.token)).body.result).toBe('BLOCKED');
    await h.api.post(`/members/${m.id}/memberships`, { planId: planA.id, paymentMode: 'CASH' }, A.token);
    const { token } = await makeQrToken(await qrSecret(), m.id);
    expect((await h.api.post('/attendance/scan', { token }, A.token)).body.duplicate).toBe(false);
    expect((await h.api.post('/attendance/scan', { token }, A.token)).body.duplicate).toBe(true);
    const today = await h.api.get('/attendance/today', A.token);
    expect(today.body.events.filter((e: any) => e.memberId === m.id && e.result !== 'BLOCKED')).toHaveLength(1);
    expect(today.body.checkins).toBe(1);
  });

  it('a correction is a new row; history keeps the old one', async () => {
    const m = (await h.api.post('/members', { name: 'Fix Me', phone: h.nextPhone() }, A.token)).body;
    const r = await h.api.post(`/members/${m.id}/memberships`, { planId: planA.id, paymentMode: 'CASH' }, A.token);
    expect((await h.api.post(`/memberships/${r.body.subscription.id}/correct`, { planId: planA.id, discount: 500, paymentMode: 'CASH', amountReceived: 0 }, A.token)).status).toBe(400);
    const fix = await h.api.post(`/memberships/${r.body.subscription.id}/correct`, { planId: planA.id, discount: 0, paymentMode: 'NOT_PAID', startDate: todayIST() }, A.token);
    expect(fix.body.subscription.kind).toBe('CORRECTION');
    expect(fix.body.due).toBe(0);
    const d = await h.api.get(`/members/${m.id}`, A.token);
    expect(d.body.history).toHaveLength(2);
    expect(d.body.history.filter((x: any) => x.superseded)).toHaveLength(1);
    const audits = await h.store.query(`tenants/${A.gym.id}/audit`, [['action', 'membership.correct']]);
    expect(audits).toHaveLength(1);
  });

  it('front desk cannot change plans or add staff, but can give discounts', async () => {
    const deskPhone = h.nextPhone();
    expect((await h.api.post('/gym/staff', { name: 'Desk', phone: deskPhone, role: 'FRONT_DESK', tempPassword: 'desk12345' }, A.token)).status).toBe(201);
    const login = await h.api.post('/auth/login', { identifier: deskPhone, password: 'desk12345' });
    expect(login.status).toBe(200);
    const desk = login.body.token;
    expect((await h.api.post('/plans', { name: 'X plan', months: 1, price: 1 }, desk)).status).toBe(403);
    expect((await h.api.post('/gym/staff', { name: 'Y', phone: h.nextPhone(), role: 'OWNER', tempPassword: 'abcdefgh' }, desk)).status).toBe(403);
    const m = (await h.api.post('/members', { name: 'Desk Added', phone: h.nextPhone() }, desk)).body;
    const r = await h.api.post(`/members/${m.id}/memberships`, { planId: planA.id, discount: 500, paymentMode: 'CASH' }, desk);
    expect(r.body.subscription.discount).toBe(500);
    const staff = await h.api.get('/gym/staff', A.token);
    expect(staff.body).toHaveLength(2);
  });

  it('imports members from a sheet and skips duplicates', async () => {
    const p = h.nextPhone();
    const r = await h.api.post('/members/import', { rows: [{ name: 'One', phone: p }, { name: 'Two', phone: p }, { name: 'Bad', phone: '123' }] }, A.token);
    expect(r.body.added).toBe(1);
    expect(r.body.failed).toBe(2);
  });
});

describe('member app', () => {
  it('joins a gym by code, gets approved, sees membership and QR', async () => {
    const owner = await h.ownerWithGym('Join Gym');
    const plan = (await h.api.post('/plans', { name: 'Monthly', months: 1, price: 1500 }, owner.token)).body;
    await h.api.post('/plans', { name: 'Hidden', months: 1, price: 900, showInApp: false }, owner.token);
    const mem = await h.signup('Member Person');
    const look = await h.api.get(`/me/gym-lookup?code=${owner.gym.gymCode}`, mem.token);
    expect(look.body.name).toBe('Join Gym');
    expect((await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, mem.token)).status).toBe(201);
    const plans = await h.api.get(`/me/gyms/${owner.gym.id}/plans`, mem.token);
    expect(plans.body.map((p: any) => p.name)).toEqual(['Monthly']);
    const reqs = await h.api.get('/join-requests', owner.token);
    const m = await h.api.post(`/join-requests/${reqs.body[0].id}/approve`, {}, owner.token);
    expect(m.status).toBe(201);
    await h.api.post(`/members/${m.body.id}/memberships`, { planId: plan.id, paymentMode: 'UPI' }, owner.token);
    const gyms = await h.api.get('/me/gyms', mem.token);
    expect(gyms.body.memberships[0].status).toBe('ACTIVE');
    const detail = await h.api.get(`/me/memberships/${m.body.id}`, mem.token);
    expect(detail.body.current.updatedBy).toBe('Join Gym Owner');
    const qr = await h.api.get(`/me/qr/${m.body.id}`, mem.token);
    expect((await h.api.post('/attendance/scan', { token: qr.body.token }, owner.token)).body.result).toBe('ALLOWED');
    expect((await h.api.get(`/me/qr/${m.body.id}`, mem.token)).body.visitsThisMonth).toBe(1);
    expect((await h.api.get('/me/notifications', mem.token)).body.length).toBeGreaterThanOrEqual(2);
    const other = await h.signup('Other');
    expect((await h.api.get(`/me/memberships/${m.body.id}`, other.token)).status).toBe(404);
  });

  it('links a hand-added member when they join with the same mobile number', async () => {
    const owner = await h.ownerWithGym('Link Gym');
    const mem = await h.signup('Walk In');
    const added = (await h.api.post('/members', { name: 'Walk In', phone: mem.phone }, owner.token)).body;
    // Adding a member whose number already has an account links it straight away
    expect(added.userId).toBe(mem.user.id);
    expect((await h.api.get('/me/gyms', mem.token)).body.memberships).toHaveLength(1);
  });

  it('member tickets go to GymMantra, not to the gym', async () => {
    const owner = await h.ownerWithGym('Ticket Gym');
    const mem = await h.signup('Ticket Member');
    await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, mem.token);
    const reqs = await h.api.get('/join-requests', owner.token);
    await h.api.post(`/join-requests/${reqs.body[0].id}/approve`, {}, owner.token);
    const t = await h.api.post('/me/tickets', { topic: 'membership', subject: 'Renewal date wrong', body: 'Please check' }, mem.token);
    expect(t.body).toMatchObject({ routedTo: 'GYMMANTRA', gymName: 'Ticket Gym', role: 'MEMBER' });
    expect((await h.api.get('/tickets', owner.token)).body).toHaveLength(0);
    expect((await h.api.get('/super/tickets', owner.token)).status).toBe(403);
  });

  it('profile photo is visible only to the member and their gym staff', async () => {
    const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 0xff, 0xd9]).toString('base64');
    const owner = await h.ownerWithGym('Photo Gym');
    const mem = await h.signup('Photo Member');
    const stranger = await h.signup('Stranger');
    const up = await h.api.post('/me/photo', { mime: 'image/jpeg', base64: JPEG }, mem.token);
    expect(up.status).toBe(201);
    expect((await h.api.get(`/photos/${mem.user.id}`, mem.token)).status).toBe(200);
    expect((await h.api.get(`/photos/${mem.user.id}`, stranger.token)).status).toBe(403);
    expect((await h.api.get(`/photos/${mem.user.id}`, owner.token)).status).toBe(403);
    await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, mem.token);
    expect((await h.api.get(`/photos/${mem.user.id}`, owner.token)).status).toBe(200);
    expect((await h.api.post('/me/photo', { mime: 'image/png', base64: JPEG }, mem.token)).status).toBe(400);
  });

  it('lists the 40 exercise guides', async () => {
    const r = await h.api.get('/exercises');
    expect(r.body).toHaveLength(40);
    expect(r.body[0].videoUrl).toMatch(/^\/media\/exercises\/videos\/01_/);
  });

  it('deletes an account and unlinks it from the gym', async () => {
    const owner = await h.ownerWithGym('Delete Gym');
    const mem = await h.signup('Leaver');
    await h.api.post('/members', { name: 'Leaver', phone: mem.phone }, owner.token);
    expect((await h.api.del('/me', mem.token, { password: 'secret123' })).status).toBe(200);
    expect((await h.api.get('/auth/me', mem.token)).status).toBe(401);
    const list = await h.api.get('/members', owner.token);
    expect(list.body.rows[0].hasApp).toBe(false);
  });
});

describe('super admin', () => {
  it('only super admins can change SaaS plans', async () => {
    const u = await h.signup();
    expect((await h.api.get('/super/saas-plans', u.token)).status).toBe(403);
    const boss = (await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' })).body.token;
    const plans = await h.api.get('/super/saas-plans', boss);
    expect(plans.body.plans.map((p: any) => [p.name, p.monthlyPrice, p.annualPrice])).toEqual([
      ['Starter', 399, 3990],
      ['Growth', 799, 7990],
      ['Pro', 1399, 13990],
    ]);
    const growth = plans.body.plans[1];
    expect((await h.api.patch(`/super/saas-plans/${growth.id}`, { monthlyPrice: 849 }, boss)).status).toBe(200);
    expect((await h.api.get('/saas-plans')).body.plans[1].monthlyPrice).toBe(849);
    expect((await h.api.patch('/super/settings', { trialMonths: 2 }, boss)).status).toBe(200);
    const g = await h.ownerWithGym('Trial Gym');
    const gyms = await h.api.get('/super/gyms', boss);
    expect(gyms.body.map((x: any) => x.name)).toContain('Trial Gym');
    expect((await h.api.patch(`/super/gyms/${g.gym.id}`, { status: 'SUSPENDED' }, boss)).status).toBe(200);
    expect((await h.api.get('/members', g.token)).status).toBe(403);
  });
});

describe('trainers and offers', () => {
  it('a trainer joins with the gym code and the owner approves', async () => {
    const A = await h.ownerWithGym('Trainer Gym');
    const tr = await h.signup('Vikram Trainer');
    const j = await h.api.post('/me/join', { gymCode: A.gym.gymCode, as: 'TRAINER', speciality: 'Weight loss', experienceYears: 6 }, tr.token);
    expect(j.status).toBe(201);
    expect(j.body.kind).toBe('TRAINER');
    // Not a trainer yet: no access to trainer screens, request shows as pending.
    let home = await h.api.get('/trainer/home', tr.token);
    expect(home.body.gyms).toHaveLength(0);
    expect(home.body.pending[0].name).toBe('Trainer Gym');
    expect((await h.api.get('/auth/me', tr.token)).body.user.trainerPending).toBe(true);
    // A trainer cannot register a gym.
    expect((await h.api.post('/gyms', { name: 'My Own Gym' }, tr.token)).status).toBe(400);
    const reqs = await h.api.get('/join-requests', A.token);
    const r = reqs.body.find((x: any) => x.kind === 'TRAINER');
    expect(r.user.name).toBe('Vikram Trainer');
    expect((await h.api.post(`/join-requests/${r.id}/approve`, {}, A.token)).status).toBe(201);
    home = await h.api.get('/trainer/home', tr.token);
    expect(home.body.gyms[0].profile.speciality).toBe('Weight loss');
    expect(home.body.pending).toHaveLength(0);
    // Trainers cannot use desk screens.
    expect((await h.api.get('/members', tr.token)).status).toBe(403);
    expect((await h.api.get('/dashboard', tr.token)).status).toBe(403);
    // Owner sets PT packages.
    const list = await h.api.get('/trainers', A.token);
    expect(list.body).toHaveLength(1);
    const up = await h.api.patch(`/trainers/${list.body[0].id}`, { packages: [{ sessions: 12, days: 30, perWeek: 3, price: 6000 }], sharePercent: 40 }, A.token);
    expect(up.status).toBe(200);
    expect(up.body.packages[0].price).toBe(6000);
    // An owner cannot join another gym as a trainer.
    const B = await h.ownerWithGym('Other Gym');
    expect((await h.api.post('/me/join', { gymCode: A.gym.gymCode, as: 'TRAINER' }, B.token)).status).toBe(400);
    // The owner can remove the trainer.
    expect((await h.api.post(`/trainers/${list.body[0].id}/remove`, {}, A.token)).status).toBe(200);
    expect((await h.api.get('/trainer/home', tr.token)).body.gyms).toHaveLength(0);
  });

  it('offers reach the chosen people', async () => {
    const A = await h.ownerWithGym('Offer Gym');
    const mem = await h.signup('Offer Member');
    await h.api.post('/me/join', { gymCode: A.gym.gymCode }, mem.token);
    const jr = (await h.api.get('/join-requests', A.token)).body[0];
    await h.api.post(`/join-requests/${jr.id}/approve`, {}, A.token);
    const far = addDays(todayIST(), 10);
    expect((await h.api.post('/offers', { title: 'Diwali 20% off', validTill: far, forMembers: true, memberFilter: 'ALL' }, A.token)).status).toBe(201);
    expect((await h.api.post('/offers', { title: 'Only expired people', validTill: far, forMembers: true, memberFilter: 'ACTIVE' }, A.token)).status).toBe(201);
    const t = await h.api.post('/offers', { title: 'Trainer bonus', validTill: far, forMembers: false, forTrainers: true }, A.token);
    expect(t.status).toBe(201);
    const g = await h.api.get('/me/gyms', mem.token);
    expect(g.body.memberships[0].offers.map((o: any) => o.title)).toEqual(['Diwali 20% off']);
    // Owner turns an offer off.
    await h.api.patch(`/offers/${t.body.id}`, { active: false }, A.token);
    const all = await h.api.get('/offers', A.token);
    expect(all.body.find((o: any) => o.id === t.body.id).live).toBe(false);
    expect((await h.api.post('/offers', { title: 'Nobody', validTill: far, forMembers: false, forTrainers: false }, A.token)).status).toBe(400);
  });
});

describe('personal training', () => {
  it('member asks for PT, owner approves, trainer marks sessions, owner pays the trainer', async () => {
    const A = await h.ownerWithGym('PT Gym');
    // trainer
    const tr = await h.signup('Vikram PT');
    await h.api.post('/me/join', { gymCode: A.gym.gymCode, as: 'TRAINER' }, tr.token);
    let jr = (await h.api.get('/join-requests', A.token)).body[0];
    await h.api.post(`/join-requests/${jr.id}/approve`, {}, A.token);
    const pk = await h.api.patch(`/trainers/${tr.user.id}`, { packages: [{ sessions: 3, days: 30, perWeek: 3, price: 6000 }], sharePercent: 50 }, A.token);
    const packageId = pk.body.packages[0].id;
    // member
    const mem = await h.signup('Rahul PT');
    await h.api.post('/me/join', { gymCode: A.gym.gymCode }, mem.token);
    jr = (await h.api.get('/join-requests', A.token)).body[0];
    await h.api.post(`/join-requests/${jr.id}/approve`, {}, A.token);
    const list = await h.api.get(`/me/gyms/${A.gym.id}/trainers`, mem.token);
    expect(list.body.trainers[0].packages[0].sessions).toBe(3);
    expect(list.body.trainers[0].phone).toBeUndefined();
    const req = await h.api.post('/me/pt', { tenantId: A.gym.id, trainerId: tr.user.id, packageId }, mem.token);
    expect(req.status).toBe(201);
    expect(req.body.state).toBe('PENDING');
    expect((await h.api.post('/me/pt', { tenantId: A.gym.id, trainerId: tr.user.id, packageId }, mem.token)).status).toBe(400);
    // trainer and owner were told
    expect((await h.api.get('/me/notifications', tr.token)).body[0].title).toBe('New PT request');
    expect((await h.api.get('/dashboard', A.token)).body.ptPending).toBe(1);
    // trainer sees it as pending, cannot approve
    expect((await h.api.get('/trainer/clients', tr.token)).body.clients[0].state).toBe('PENDING');
    expect((await h.api.post(`/pt/${req.body.id}/approve`, {}, tr.token)).status).toBe(403);
    // owner approves with money received
    const ap = await h.api.post(`/pt/${req.body.id}/approve`, { amountReceived: 6000, paymentMode: 'UPI', startDate: addDays(todayIST(), -3) }, A.token);
    expect(ap.status).toBe(200);
    expect(ap.body.left).toBe(3);
    // trainer marks sessions
    const today = todayIST();
    const mark = (date: string, m: string) => h.api.post(`/pt/${req.body.id}/session`, { tenantId: A.gym.id, date, mark: m }, tr.token);
    expect((await mark(today, 'DONE')).body.left).toBe(2);
    expect((await mark(addDays(today, -1), 'MISSED')).body.missed).toBe(1);
    expect((await mark(addDays(today, -9), 'DONE')).status).toBe(400);
    expect((await mark(addDays(today, 2), 'DONE')).status).toBe(400);
    expect((await mark(addDays(today, 2), 'PLANNED')).status).toBe(200);
    expect((await mark(addDays(today, 2), 'MISSED')).status).toBe(400); // future day: only Planned
    expect((await mark(addDays(today, -1), 'PLANNED')).status).toBe(400); // past day cannot be planned
    expect((await mark(addDays(today, -3), 'DONE')).status).toBe(400); // older than 2 days: locked for the trainer
    const c = await h.api.get('/trainer/clients', tr.token);
    expect(c.body.clients[0].left).toBe(2);
    expect(c.body.clients[0].price).toBeUndefined();
    // member sees the same calendar
    const my = await h.api.get('/me/pt', mem.token);
    expect(my.body[0].log[today]).toBe('DONE');
    expect(my.body[0].trainerName).toBe('Vikram PT');
    // another member cannot touch it; front desk cannot mark
    const other = await h.signup('Other');
    expect((await h.api.post(`/pt/${req.body.id}/session`, { tenantId: A.gym.id, date: today, mark: 'DONE' }, other.token)).status).toBe(403);
    // PT money: trainer earned 50% of 6000
    const acc = await h.api.get('/pt-accounts', A.token);
    expect(acc.body.trainers[0].earned).toBe(3000);
    expect(acc.body.trainers[0].due).toBe(3000);
    expect((await h.api.post('/pt-payouts', { trainerId: tr.user.id, amount: 2000, mode: 'UPI' }, A.token)).status).toBe(201);
    expect((await h.api.get('/pt-accounts', A.token)).body.trainers[0].due).toBe(1000);
    expect((await h.api.get('/trainer/payouts', tr.token)).body[0].amount).toBe(2000);
    expect((await h.api.get('/pt-accounts', tr.token)).status).toBe(403);
    // trainer writes the diet chart and workout; member sees it; others cannot
    const memberId = my.body[0].memberId;
    const put = await h.api.put(`/programs/${memberId}`, {
      tenantId: A.gym.id,
      diet: { kcal: 1850, protein: 140, meals: [{ name: 'Breakfast', time: '8:00 am', items: '4 egg whites, 2 toast' }] },
      workout: { days: [{ day: 'Wed', title: 'Legs', exercises: [{ name: 'Squats', sets: '4 x 10', weight: '60 kg' }] }] },
    }, tr.token);
    expect(put.status).toBe(200);
    const prog = await h.api.get('/me/program', mem.token);
    expect(prog.body[0].diet.meals[0].items).toBe('4 egg whites, 2 toast');
    expect(prog.body[0].workout.days[0].exercises[0].name).toBe('Squats');
    expect((await h.api.get('/me/notifications', mem.token)).body[0].title).toBe('Your plan is updated');
    const tr2 = await h.signup('Other Trainer');
    await h.api.post('/me/join', { gymCode: A.gym.gymCode, as: 'TRAINER' }, tr2.token);
    const j2 = (await h.api.get('/join-requests', A.token)).body[0];
    await h.api.post(`/join-requests/${j2.id}/approve`, {}, A.token);
    expect((await h.api.put(`/programs/${memberId}`, { tenantId: A.gym.id, diet: null }, tr2.token)).status).toBe(403);
    expect((await h.api.get(`/programs/${memberId}?tenantId=${A.gym.id}`, A.token)).status).toBe(200);
  });
});

describe('gym address, plans and bills', () => {
  it('a new gym needs a full address with a matching PIN', async () => {
    const o = await h.signup('Address Owner');
    expect((await h.api.post('/gyms', { name: 'No Address Gym' }, o.token)).status).toBe(400);
    const bad = await h.api.post('/gyms', { name: 'Wrong Pin Gym', addressLine: 'SCO 44, Sector 29', state: 'Haryana', city: 'Gurugram', pincode: '110075' }, o.token);
    expect(bad.status).toBe(400);
    expect(bad.body.message).toMatch(/not from Haryana/);
    const ok = await h.api.post('/gyms', { name: 'Good Gym', addressLine: 'SCO 44, Sector 29', state: 'Haryana', city: 'Gurugram', pincode: '122001' }, o.token);
    expect(ok.status).toBe(201);
    expect(ok.body.stateCode).toBe('06');
  });

  it('trial unlocks everything; a plan unlocks only its features; receipts have no GST until the switch is on', async () => {
    const A = await h.ownerWithGym('Plan Gym');
    let sub = await h.api.get('/subscription', A.token);
    expect(sub.body.inTrial).toBe(true);
    expect(sub.body.ring).toBe('trial');
    expect(sub.body.unlocks).toEqual(['offers', 'pt', 'reports', 'branches']);
    const starter = sub.body.plans.find((p: any) => p.name === 'Starter');
    const growth = sub.body.plans.find((p: any) => p.name === 'Growth');
    // super admin
    await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' });
    const boss = (await h.api.post('/auth/login', { identifier: 'boss@gymmantra.app', password: 'secret123' })).body.token;
    expect((await h.api.post(`/super/gyms/${A.gym.id}/subscription`, { planId: starter.id, cycle: 'MONTHLY', mode: 'UPI' }, A.token)).status).toBe(403);
    const bill = await h.api.post(`/super/gyms/${A.gym.id}/subscription`, { planId: starter.id, cycle: 'MONTHLY', mode: 'UPI', ref: '1234' }, boss);
    expect(bill.status).toBe(201);
    expect(bill.body.kind).toBe('RECEIPT');
    expect(bill.body.gst).toBeNull();
    expect(bill.body.total).toBe(399);
    sub = await h.api.get('/subscription', A.token);
    expect(sub.body.ring).toBe('starter');
    expect(sub.body.unlocks).toEqual([]);
    expect(sub.body.bills).toHaveLength(1);
    // Starter: offers locked
    const far = addDays(todayIST(), 5);
    const off = await h.api.post('/offers', { title: 'Locked offer', validTill: far, forMembers: true }, A.token);
    expect(off.status).toBe(403);
    expect(off.body.message).toMatch(/Growth plan/);
    // GST switch on: Delhi gym gets CGST + SGST on the next bill
    expect((await h.api.patch('/super/gst', { registered: true }, boss)).status).toBe(400);
    expect((await h.api.patch('/super/gst', { registered: true, gstin: '07ABCDE1234F1Z5' }, boss)).status).toBe(200);
    const b2 = await h.api.post(`/super/gyms/${A.gym.id}/subscription`, { planId: growth.id, cycle: 'ANNUAL', mode: 'UPI' }, boss);
    expect(b2.body.kind).toBe('TAX_INVOICE');
    expect(b2.body.gst.type).toBe('CGST_SGST');
    expect(b2.body.total).toBe(9428.2);
    expect(b2.body.number).toMatch(/^GM\/\d{2}-\d{2}\/0001$/);
    expect((await h.api.post('/offers', { title: 'Now open', validTill: far, forMembers: true }, A.token)).status).toBe(201);
    const full = await h.api.get(`/subscription/bills/${b2.body.id}`, A.token);
    expect(full.body.seller.gstin).toBe('07ABCDE1234F1Z5');
  });
});

describe('notices', () => {
  it('owner sends a notice to members or trainers; they see it on the dashboard and in notifications', async () => {
    const owner = await h.ownerWithGym('Notice Gym');
    const mem = await h.signup('Notice Member');
    await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, mem.token);
    const reqs = await h.api.get('/join-requests', owner.token);
    await h.api.post(`/join-requests/${reqs.body[0].id}/approve`, {}, owner.token);

    expect((await h.api.post('/notices', { title: 'Gym closed', message: 'Closed tomorrow for Diwali', forMembers: false, forTrainers: false }, owner.token)).status).toBe(400);
    const onlyTrainers = await h.api.post('/notices', { title: 'Staff meeting', message: 'Meeting at 9 am', forMembers: false, forTrainers: true }, owner.token);
    expect(onlyTrainers.status).toBe(201);
    const n = await h.api.post('/notices', { title: 'Gym closed', message: 'Closed tomorrow for Diwali', forMembers: true }, owner.token);
    expect(n.status).toBe(201);

    const gyms = await h.api.get('/me/gyms', mem.token);
    const notices = gyms.body.memberships[0].notices;
    expect(notices.map((x: any) => x.title)).toEqual(['Gym closed']);
    const inbox = await h.api.get('/me/notifications', mem.token);
    const item = inbox.body.find((x: any) => x.id === `notice:${n.body.id}`);
    expect(item.readAt).toBeNull();
    await h.api.post('/me/notifications/read', {}, mem.token);
    expect((await h.api.get('/me/notifications', mem.token)).body.find((x: any) => x.id === `notice:${n.body.id}`).readAt).not.toBeNull();

    // another gym cannot remove it; the owner can
    const other = await h.ownerWithGym('Other Gym');
    expect((await h.api.del(`/notices/${n.body.id}`, other.token)).status).toBe(404);
    expect((await h.api.del(`/notices/${n.body.id}`, owner.token)).status).toBe(200);
    expect((await h.api.get('/me/gyms', mem.token)).body.memberships[0].notices).toHaveLength(0);
    expect((await h.api.get('/notices', owner.token)).body.map((x: any) => x.title)).toEqual(['Staff meeting']);
  });
});

describe('dues, check-in QR, leads, PDFs, reports', () => {
  let A: any, plan: any, mem: any, memberId: string;
  beforeEach(async () => {
    A = await h.ownerWithGym('Due Gym');
    plan = (await h.api.post('/plans', { name: 'Yearly', months: 12, price: 12000 }, A.token)).body;
    mem = await h.signup('Due Member');
    await h.api.post('/me/join', { gymCode: A.gym.gymCode }, mem.token);
    const reqs = await h.api.get('/join-requests', A.token);
    memberId = (await h.api.post(`/join-requests/${reqs.body[0].id}/approve`, {}, A.token)).body.member?.id ?? (await h.api.get('/members', A.token)).body.rows[0].id;
  });

  it('lists dues with paid of total, reminds members, and clears after payment', async () => {
    const r = await h.api.post(`/members/${memberId}/memberships`, { planId: plan.id, paymentMode: 'CASH', amountReceived: 5000, allowEntryWhileDue: false }, A.token);
    expect(r.status).toBe(201);
    const subId = r.body.subscription.id;
    const dues = await h.api.get('/dues', A.token);
    expect(dues.body.count).toBe(1);
    expect(dues.body.members[0]).toMatchObject({ due: 7000, paid: 5000, total: 12000 });
    const list = await h.api.get('/members', A.token);
    expect(list.body.rows[0]).toMatchObject({ due: 7000, duePaid: 5000, dueTotal: 12000 });
    const rem = await h.api.post('/dues/remind', {}, A.token);
    expect(rem.body.sent).toBe(1);
    const inbox = await h.api.get('/me/notifications', mem.token);
    expect(inbox.body[0].title).toContain('Payment due');
    const gyms = await h.api.get('/me/gyms', mem.token);
    expect(gyms.body.memberships[0]).toMatchObject({ due: 7000, duePaid: 5000, dueTotal: 12000 });
    expect(gyms.body.memberships[0].entry.result).toBe('BLOCKED');
    // notice only to members who owe money
    const aud = await h.api.get('/notices/audience?filter=DUE', A.token);
    expect(aud.body.count).toBe(1);
    expect((await h.api.post(`/memberships/${subId}/payments`, { amount: 7000, mode: 'UPI' }, A.token)).status).toBe(201);
    expect((await h.api.get('/dues', A.token)).body.count).toBe(0);
    expect((await h.api.get('/me/gyms', mem.token)).body.memberships[0].due).toBe(0);
    // member detail shows the member's own profile
    await h.api.patch('/me/profile', { dob: '1996-08-14', gender: 'male', address: 'Palam, Delhi' }, mem.token);
    const d = await h.api.get(`/members/${memberId}`, A.token);
    expect(d.body.profile).toMatchObject({ dob: '1996-08-14', gender: 'male', address: 'Palam, Delhi' });
    // reports entries
    const rep = await h.api.get('/reports/entries?days=30', A.token);
    expect(rep.body.entries[0]).toMatchObject({ kind: 'MEMBERSHIP', type: 'New', total: 12000, paid: 12000, status: 'PAID' });
  });

  it('checks in with the gym check-in QR (not the join QR), once a day, near the gym', async () => {
    await h.api.post(`/members/${memberId}/memberships`, { planId: plan.id, paymentMode: 'CASH' }, A.token);
    const qr = await h.api.get('/gym/checkin-qr', A.token);
    expect(qr.body.text).toMatch(/^gymmantra-checkin:/);
    expect((await h.api.post('/me/checkin', { code: qr.body.joinText }, mem.token)).status).toBe(400);
    expect((await h.api.post('/me/checkin', { code: qr.body.text.slice(0, -2) + 'zz' }, mem.token)).status).toBe(400);
    const first = await h.api.post('/me/checkin', { code: qr.body.text }, mem.token);
    expect(first.status).toBe(201);
    expect(first.body).toMatchObject({ kind: 'MEMBER', result: 'ALLOWED', duplicate: false, visitsThisMonth: 1 });
    expect((await h.api.post('/me/checkin', { code: qr.body.text }, mem.token)).body.duplicate).toBe(true);
    // a stranger cannot check in
    const other = await h.signup('Stranger');
    expect((await h.api.post('/me/checkin', { code: qr.body.text }, other.token)).status).toBe(403);
    // with the gym location saved, the phone must be near
    expect((await h.api.put('/gym/location', { lat: 28.5921, lng: 77.0460 }, A.token)).status).toBe(200);
    const mem2 = await h.signup('Second Member');
    await h.api.post('/me/join', { gymCode: A.gym.gymCode }, mem2.token);
    const reqs = await h.api.get('/join-requests', A.token);
    await h.api.post(`/join-requests/${reqs.body[0].id}/approve`, {}, A.token);
    const id2 = (await h.api.get('/members', A.token)).body.rows.find((r: any) => r.name === 'Second Member').id;
    await h.api.post(`/members/${id2}/memberships`, { planId: plan.id, paymentMode: 'CASH' }, A.token);
    expect((await h.api.post('/me/checkin', { code: qr.body.text }, mem2.token)).status).toBe(400);
    expect((await h.api.post('/me/checkin', { code: qr.body.text, lat: 28.70, lng: 77.10 }, mem2.token)).status).toBe(403);
    expect((await h.api.post('/me/checkin', { code: qr.body.text, lat: 28.5925, lng: 77.0462 }, mem2.token)).status).toBe(403); // ~45 m away
    expect((await h.api.post('/me/checkin', { code: qr.body.text, lat: 28.59215, lng: 77.04603, accuracy: 8 }, mem2.token)).status).toBe(201);
    // rotating the key stops old printouts
    const rot = await h.api.post('/gym/checkin-qr/rotate', {}, A.token);
    expect(rot.body.text).not.toBe(qr.body.text);
  });

  it('member says Interested in a plan; owner sees it', async () => {
    const plans = await h.api.get(`/me/gyms/${A.gym.id}/plans`, mem.token);
    expect(plans.body[0]).toMatchObject({ id: plan.id, active: false, interested: false });
    expect((await h.api.post(`/me/gyms/${A.gym.id}/plans/${plan.id}/interest`, {}, mem.token)).status).toBe(201);
    expect((await h.api.post(`/me/gyms/${A.gym.id}/plans/${plan.id}/interest`, {}, mem.token)).status).toBe(409);
    expect((await h.api.get(`/me/gyms/${A.gym.id}/plans`, mem.token)).body[0].interested).toBe(true);
    const leads = await h.api.get('/leads', A.token);
    expect(leads.body[0]).toMatchObject({ name: 'Due Member', planName: 'Yearly' });
    expect((await h.api.post(`/leads/${leads.body[0].id}/done`, {}, A.token)).status).toBe(200);
    expect((await h.api.get('/leads', A.token)).body).toHaveLength(0);
    await h.api.post(`/members/${memberId}/memberships`, { planId: plan.id, paymentMode: 'CASH' }, A.token);
    expect((await h.api.get(`/me/gyms/${A.gym.id}/plans`, mem.token)).body[0].active).toBe(true);
  });

  it('owner uploads a PDF diet chart; member reads it; other members cannot', async () => {
    const pdf = Buffer.from('%PDF-1.4\n' + 'x'.repeat(1_500_000)).toString('base64');
    const up = await h.api.put(`/programs/${memberId}/pdf/diet`, { tenantId: A.gym.id, name: 'diet.pdf', base64: pdf }, A.token);
    expect(up.status).toBe(200);
    expect(up.body.dietPdf.parts).toBe(3);
    expect((await h.api.put(`/programs/${memberId}/pdf/diet`, { tenantId: A.gym.id, name: 'x.pdf', base64: Buffer.from('hello').toString('base64') }, A.token)).status).toBe(400);
    const my = await h.api.get('/me/program', mem.token);
    expect(my.body[0].dietPdf.name).toBe('diet.pdf');
    const read = await h.api.get(`/me/program/${A.gym.id}/pdf/diet`, mem.token);
    expect(read.body.base64).toBe(pdf);
    const other = await h.signup('Other');
    expect((await h.api.get(`/me/program/${A.gym.id}/pdf/diet`, other.token)).status).toBe(403);
    expect((await h.api.del(`/programs/${memberId}/pdf/diet?tenantId=${A.gym.id}`, A.token)).status).toBe(200);
    expect((await h.api.get(`/me/program/${A.gym.id}/pdf/diet`, mem.token)).status).toBe(404);
    // new app: in pieces (a 1.9 MB PDF)
    const big = Buffer.from('%PDF-1.7\n' + 'y'.repeat(1_900_000)).toString('base64');
    const id = '0f8fad5b-d9cb-469f-a165-70867728950e';
    const pieces = big.match(/[\s\S]{1,350000}/g)!;
    for (let i = 0; i < pieces.length; i++) {
      expect((await h.api.put(`/programs/${memberId}/pdf/workout/parts/${i}`, { tenantId: A.gym.id, uploadId: id, data: pieces[i] }, A.token)).status).toBe(200);
    }
    const done = await h.api.put(`/programs/${memberId}/pdf/workout`, { tenantId: A.gym.id, name: 'gym.pdf', uploadId: id, parts: pieces.length, size: 1_900_009 }, A.token);
    expect(done.status).toBe(200);
    const meta = await h.api.get(`/me/program/${A.gym.id}/pdf/workout?meta=1`, mem.token);
    expect(meta.body.parts).toBe(pieces.length);
    let joined = '';
    for (let i = 0; i < meta.body.parts; i++) joined += (await h.api.get(`/me/program/${A.gym.id}/pdf/workout?part=${i}`, mem.token)).body.data;
    expect(joined).toBe(big);
    expect((await h.api.put(`/programs/${memberId}/pdf/workout/parts/0`, { tenantId: A.gym.id, uploadId: id, data: 'aGVsbG8=' }, A.token)).status).toBe(400);
  });
});

describe('tickets, deletes and offer banners', () => {
  it('every ticket goes to GymMantra with a number; the person waits for a reply', async () => {
    const owner = await h.ownerWithGym('Ticket Gym');
    const r = await h.api.post('/me/tickets', { topic: 'payment', subject: 'Paid but due shows', body: 'I paid by UPI yesterday' }, owner.token);
    expect(r.status).toBe(201);
    expect(r.body.number).toBe('GM-1001');
    expect(r.body.routedTo).toBe('GYMMANTRA');
    const r2 = await h.api.post('/me/tickets', { topic: 'other', subject: 'Second one', body: 'Another question here' }, owner.token);
    expect(r2.body.number).toBe('GM-1002');
    expect((await h.api.post(`/me/tickets/${r.body.id}/messages`, { body: 'any update?' }, owner.token)).status).toBe(400);
    // gym staff cannot see it; super admin can and replies
    expect((await h.api.get('/tickets', owner.token)).body).toHaveLength(0);
    const boss = await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' });
    const list = await h.api.get('/super/tickets', boss.body.token);
    expect(list.body.map((t: any) => t.number).sort()).toEqual(['GM-1001', 'GM-1002']);
    expect((await h.api.post(`/super/tickets/${r.body.id}/messages`, { body: 'Fixed now' }, boss.body.token)).status).toBe(201);
    const mine = await h.api.get(`/me/tickets/${r.body.id}`, owner.token);
    expect(mine.body.waiting).toBe(false);
    expect((await h.api.post(`/me/tickets/${r.body.id}/messages`, { body: 'Thanks!' }, owner.token)).status).toBe(201);
    // statuses: person wrote → OPEN; super admin sets IN_PROGRESS → person still waits; RESOLVED → person can reopen; CLOSED → no more messages
    expect((await h.api.get(`/me/tickets/${r.body.id}`, owner.token)).body.status).toBe('OPEN');
    const ip = await h.api.patch(`/super/tickets/${r.body.id}`, { status: 'IN_PROGRESS' }, boss.body.token);
    expect(ip.body.status).toBe('IN_PROGRESS');
    expect((await h.api.get('/me/notifications', owner.token)).body[0].title).toContain('in progress');
    expect((await h.api.post(`/me/tickets/${r.body.id}/messages`, { body: 'hello?' }, owner.token)).status).toBe(400);
    await h.api.post(`/super/tickets/${r.body.id}/messages`, { body: 'Done, check now' }, boss.body.token);
    expect((await h.api.get(`/me/tickets/${r.body.id}`, owner.token)).body).toMatchObject({ status: 'WAITING', canReply: true });
    await h.api.patch(`/super/tickets/${r.body.id}`, { status: 'RESOLVED' }, boss.body.token);
    expect((await h.api.get(`/me/tickets/${r.body.id}`, owner.token)).body).toMatchObject({ status: 'RESOLVED', canReply: true });
    expect((await h.api.post(`/me/tickets/${r.body.id}/messages`, { body: 'Still not fixed' }, owner.token)).status).toBe(201);
    expect((await h.api.get(`/me/tickets/${r.body.id}`, owner.token)).body.status).toBe('OPEN');
    await h.api.patch(`/super/tickets/${r.body.id}`, { status: 'CLOSED' }, boss.body.token);
    expect((await h.api.post(`/super/tickets/${r.body.id}/messages`, { body: 'x' }, boss.body.token)).status).toBe(201);
    await h.api.patch(`/super/tickets/${r.body.id}`, { status: 'CLOSED' }, boss.body.token);
    expect((await h.api.post(`/me/tickets/${r.body.id}/messages`, { body: 'one more' }, owner.token)).status).toBe(400);
    expect((await h.api.get('/super/tickets?status=CLOSED', boss.body.token)).body).toHaveLength(1);
  });

  it('owner deletes offers, unused plans and empty branches; offers can have a banner', async () => {
    const owner = await h.ownerWithGym('Delete Gym');
    const o = await h.api.post('/offers', { title: 'Diwali 20% off', validTill: '2099-01-01', forMembers: true }, owner.token);
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    const img = await h.api.post(`/offers/${o.body.id}/image`, { mime: 'image/png', base64: png }, owner.token);
    expect(img.status).toBe(201);
    expect(img.body.imageUrl).toContain(`/offers/${owner.gym.id}/${o.body.id}/image`);
    expect((await h.api.del(`/offers/${o.body.id}`, owner.token)).status).toBe(200);
    expect((await h.api.get('/offers', owner.token)).body).toHaveLength(0);
    const plan = (await h.api.post('/plans', { name: 'Monthly', months: 1, price: 1000 }, owner.token)).body;
    expect((await h.api.del(`/plans/${plan.id}`, owner.token)).status).toBe(200);
    const plan2 = (await h.api.post('/plans', { name: 'Yearly', months: 12, price: 9000 }, owner.token)).body;
    const m = (await h.api.post('/members', { name: 'Ravi', phone: h.nextPhone() }, owner.token)).body;
    await h.api.post(`/members/${m.id}/memberships`, { planId: plan2.id, paymentMode: 'CASH' }, owner.token);
    expect((await h.api.del(`/plans/${plan2.id}`, owner.token)).status).toBe(400);
  });
});

describe('ads', () => {
  it('super admin runs an ad for chosen roles and states', async () => {
    await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' });
    const boss = (await h.api.post('/auth/login', { identifier: 'boss@gymmantra.app', password: 'secret123' })).body.token;
    const A = await h.ownerWithGym('Ad Gym'); // Delhi
    const mem = await h.signup('Ad Member');
    await h.api.post('/me/join', { gymCode: A.gym.gymCode }, mem.token);
    const jr = (await h.api.get('/join-requests', A.token)).body[0];
    await h.api.post(`/join-requests/${jr.id}/approve`, {}, A.token);
    const end = addDays(todayIST(), 10);
    expect((await h.api.post('/super/ads', { title: 'Nope', endsOn: end }, A.token)).status).toBe(403);
    const ad = await h.api.post('/super/ads', { title: 'ProFuel Whey 20% off', endsOn: end, forMembers: true, states: ['Delhi'], linkKind: 'URL', linkValue: 'https://example.com' }, boss);
    expect(ad.status).toBe(201);
    await h.api.post('/super/ads', { title: 'Only Mumbai', endsOn: end, forMembers: true, states: ['Maharashtra'] }, boss);
    await h.api.post('/super/ads', { title: 'Owners only', endsOn: end, forMembers: false, forOwners: true }, boss);
    const seen = await h.api.get('/ads?role=MEMBER', mem.token);
    expect(seen.body.map((a: any) => a.title)).toEqual(['ProFuel Whey 20% off']);
    expect((await h.api.get('/ads?role=OWNER', A.token)).body.map((a: any) => a.title)).toEqual(['Owners only']);
    await h.api.post(`/ads/${ad.body.id}/event`, { type: 'view', role: 'MEMBER' }, mem.token);
    await h.api.post(`/ads/${ad.body.id}/event`, { type: 'click', role: 'MEMBER' }, mem.token);
    const list = await h.api.get('/super/ads', boss);
    const mine = list.body.find((a: any) => a.id === ad.body.id);
    expect(mine.views.MEMBER).toBe(1);
    expect(mine.clicks.MEMBER).toBe(1);
    await h.api.patch(`/super/ads/${ad.body.id}`, { active: false }, boss);
    expect((await h.api.get('/ads?role=MEMBER', mem.token)).body).toHaveLength(0);
  });

  it('only the super admin can use the admin app', async () => {
    const A = await h.ownerWithGym('Admin App Gym');
    const r = await h.api.post('/auth/login', { identifier: A.email, password: 'secret123' }, undefined, { 'x-gm-client': 'admin-app' });
    expect(r.status).toBe(403);
    await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' });
    const ok = await h.api.post('/auth/login', { identifier: 'boss@gymmantra.app', password: 'secret123' }, undefined, { 'x-gm-client': 'admin-app' });
    expect(ok.status).toBe(200);
  });
});

describe('profile details', () => {
  it('saves name parts, DOB, gender, address; changes phone/email with the password', async () => {
    const u = await h.signup('Rahul Sharma');
    const r = await h.api.patch('/me/profile', { firstName: 'Rahul', middleName: 'Kumar', lastName: 'Sharma', dob: '1997-05-20', gender: 'male', address: 'Dwarka, Delhi' }, u.token);
    expect(r.status).toBe(200);
    expect(r.body.name).toBe('Rahul Kumar Sharma');
    expect(r.body.dob).toBe('1997-05-20');
    expect((await h.api.patch('/me/profile', { dob: '2999-01-01' }, u.token)).status).toBe(400);
    expect((await h.api.patch('/me/contact', { phone: h.nextPhone(), password: 'wrong-one' }, u.token)).status).toBe(400);
    const newPhone = h.nextPhone();
    const c = await h.api.patch('/me/contact', { phone: newPhone, email: 'rahul.new@test.in', password: 'secret123' }, u.token);
    expect(c.status).toBe(200);
    expect(c.body.email).toBe('rahul.new@test.in');
    // logs in with the new mobile and the new email
    expect((await h.api.post('/auth/login', { identifier: newPhone, password: 'secret123' })).status).toBe(200);
    expect((await h.api.post('/auth/login', { identifier: 'rahul.new@test.in', password: 'secret123' })).status).toBe(200);
    // old number is free again
    const other = await h.api.post('/auth/signup', { name: 'Other', email: 'o@test.in', phone: u.phone, password: 'secret123' });
    expect(other.status).toBe(201);
  });
});

describe('branches', () => {
  it('each branch has its own code and check-in QR; one branch per gym; transfers', async () => {
    const A = await h.ownerWithGym('Branch Gym');
    const plan = (await h.api.post('/plans', { name: 'Monthly', months: 1, price: 1000 }, A.token)).body;
    const br = await h.api.post('/gym/branches', { name: 'Dwarka' }, A.token);
    expect(br.status).toBe(201);
    expect(br.body.code).toBeTruthy();
    expect(br.body.code).not.toBe(A.gym.gymCode);
    const B = { 'x-branch-id': br.body.id };
    const gym = await h.api.get('/gym', A.token);
    expect(gym.body.branches[0].code).toBe(A.gym.gymCode);
    // a member joins branch 2 with its code
    const mem = await h.signup('Branch Member');
    const look = await h.api.get(`/me/gym-lookup?code=${br.body.code}`, mem.token);
    expect(look.body.branch.name).toBe('Dwarka');
    expect((await h.api.post('/me/join', { gymCode: br.body.code }, mem.token)).status).toBe(201);
    // the request shows in branch 2, not branch 1
    expect((await h.api.get('/join-requests', A.token)).body).toHaveLength(0);
    const reqs = await h.api.get('/join-requests', A.token, B);
    expect(reqs.body).toHaveLength(1);
    await h.api.post(`/join-requests/${reqs.body[0].id}/approve`, {}, A.token, B);
    expect((await h.api.get('/members', A.token)).body.rows).toHaveLength(0);
    const rows = (await h.api.get('/members', A.token, B)).body.rows;
    expect(rows).toHaveLength(1);
    await h.api.post(`/members/${rows[0].id}/memberships`, { planId: plan.id, paymentMode: 'CASH' }, A.token, B);
    // joining branch 1 of the same gym is refused; transfer is off
    const again = await h.api.post('/me/join', { gymCode: A.gym.gymCode }, mem.token);
    expect(again.status).toBe(409);
    expect(again.body).toMatchObject({ code: 'ALREADY_MEMBER', sameBranch: false, allowTransfer: false });
    const off = await h.api.post(`/me/gyms/${A.gym.id}/transfer`, { branchId: gym.body.branches[0].id }, mem.token);
    expect(off.status).toBe(403);
    expect(off.body.message).toContain('not enabled transfer');
    // check-in QR of branch 2 counts for branch 2
    const qr2 = await h.api.get('/gym/checkin-qr', A.token, B);
    const qr1 = await h.api.get('/gym/checkin-qr', A.token);
    expect(qr2.body.text).not.toBe(qr1.body.text);
    expect(qr2.body.joinText).toBe(`gymmantra-join:${br.body.code}`);
    const ci = await h.api.post('/me/checkin', { code: qr2.body.text }, mem.token);
    expect(ci.status).toBe(201);
    expect(ci.body.gym.name).toBe('Dwarka'); // another branch shows only its own name
    expect((await h.api.get('/attendance/today', A.token, B)).body.checkins).toBe(1);
    expect((await h.api.get('/attendance/today', A.token)).body.checkins).toBe(0);
    // offers follow the branch
    await h.api.post('/offers', { title: 'Dwarka Diwali offer', details: '20% off on yearly', validTill: '2099-01-01', forMembers: true }, A.token, B);
    await h.api.post('/offers', { title: 'Main branch offer', details: 'Free t-shirt on joining', validTill: '2099-01-01', forMembers: true }, A.token);
    const mine = (await h.api.get('/me/gyms', mem.token)).body.memberships[0];
    expect(mine.branch.name).toBe('Dwarka');
    expect(mine.offers.map((o: any) => o.title)).toEqual(['Dwarka Diwali offer']);
    // owner turns transfer on; member asks; owner approves
    await h.api.patch('/gym', { allowTransfer: true }, A.token);
    const ask = await h.api.post(`/me/gyms/${A.gym.id}/transfer`, { branchId: gym.body.branches[0].id }, mem.token);
    expect(ask.status).toBe(201);
    const list = await h.api.get('/transfers', A.token);
    expect(list.body.items).toHaveLength(1);
    expect((await h.api.post(`/transfers/${list.body.items[0].id}/approve`, {}, A.token)).status).toBe(200);
    expect((await h.api.get('/members', A.token)).body.rows).toHaveLength(1);
    expect((await h.api.get('/me/gyms', mem.token)).body.memberships[0].branch.id).toBe(gym.body.branches[0].id);
    // branches made before codes existed get one when the gym is opened
    const tn: any = await h.store.get(`tenants/${A.gym.id}`);
    await h.store.set(`tenants/${A.gym.id}`, { ...tn, branches: [...tn.branches, { id: 'old-branch', name: 'Old', address: 'Sector 21', hours: null, createdAt: tn.createdAt ?? '' }] });
    const g2 = await h.api.get('/gym', A.token);
    const old = g2.body.branches.find((b: any) => b.id === 'old-branch');
    expect(old.code).toMatch(/^[A-Z]+\d+$/);
    expect((await h.api.get(`/me/gym-lookup?code=${old.code}`, (await h.signup('Looker')).token)).body.branch.name).toBe('Old');
    // member sees their branch in the gym name
    expect((await h.api.get('/me/gyms', mem.token)).body.memberships[0].gym.code).toBe(A.gym.gymCode);
    // a different gym is still fine
    const other = await h.ownerWithGym('Other Gym');
    expect((await h.api.post('/me/join', { gymCode: other.gym.gymCode }, mem.token)).status).toBe(201);
  });
});

describe('Nov 3: coupons, UPI payments, full details, branch codes', () => {
  const boss = async () => {
    const r = await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' });
    return r.body.token as string;
  };

  it('coupon lowers the price; UPI payment turns the plan on at once (idempotent); super admin can cancel; 3 fails pause', async () => {
    const sa = await boss();
    const o = await h.ownerWithGym('Coupon Gym');
    const plans = (await h.api.get('/saas-plans')).body.plans as any[];
    const pro = plans.find((p) => p.name === 'Pro');
    const till = addDays(todayIST(), 10);
    expect((await h.api.post('/super/coupons', { code: 'diwali20', kind: 'PERCENT', value: 20, validTill: till, maxUses: 100 }, sa)).status).toBe(201);
    const q = await h.api.post('/subscription/quote', { planId: pro.id, cycle: 'ANNUAL', coupon: 'DIWALI20' }, o.token);
    expect(q.status).toBe(200);
    expect(q.body.rate).toBe(13990);
    expect(q.body.discount).toBe(2798);
    expect(q.body.total).toBe(11192);
    expect(q.body.upiId).toBe('7827862630@ptaxis');
    expect((await h.api.post('/subscription/quote', { planId: pro.id, cycle: 'ANNUAL', coupon: 'NOPE' }, o.token)).status).toBe(400);
    // pay → back from the UPI app → plan on at once
    const pay = await h.api.post('/subscription/payments', { key: 'key-aaaa-0001', planId: pro.id, cycle: 'ANNUAL', coupon: 'DIWALI20' }, o.token);
    expect(pay.status).toBe(201);
    expect(pay.body.payId).toMatch(/^GM-/);
    expect(pay.body.amount).toBe(11192);
    // same key again = same payment (idempotent)
    const again = await h.api.post('/subscription/payments', { key: 'key-aaaa-0001', planId: pro.id, cycle: 'ANNUAL', coupon: 'DIWALI20' }, o.token);
    expect(again.body.id).toBe(pay.body.id);
    expect(again.body.payId).toBe(pay.body.payId);
    const done = await h.api.post('/subscription/payments/key-aaaa-0001/done', { upiStatus: 'SUCCESS', app: 'Google Pay' }, o.token);
    expect(done.status).toBe(200);
    expect(done.body.payment.status).toBe('PAID');
    const done2 = await h.api.post('/subscription/payments/key-aaaa-0001/done', { upiStatus: 'SUCCESS' }, o.token);
    expect(done2.body.bill.id).toBe(done.body.bill.id); // no second receipt
    const sub = (await h.api.get('/subscription', o.token)).body;
    expect(sub.plan.name).toBe('Pro');
    expect(sub.bills.length).toBe(1);
    const bill = (await h.api.get(`/subscription/bills/${sub.bills[0].id}`, o.token)).body;
    expect(bill.total).toBe(11192);
    expect(bill.discount).toBe(2798);
    expect(bill.couponCode).toBe('DIWALI20');
    const coupons = (await h.api.get('/super/coupons', sa)).body;
    expect(coupons[0].used).toBe(1);
    // super admin sees it
    const list = (await h.api.get('/super/payments?status=PAID', sa)).body;
    expect(list.payments.length).toBe(1);
    expect(list.monthTotal).toBe(11192);
    // once per gym
    expect((await h.api.post('/subscription/quote', { planId: pro.id, cycle: 'ANNUAL', coupon: 'DIWALI20' }, o.token)).status).toBe(400);
    // super admin: payment never came → plan stopped, receipt cancelled
    expect((await h.api.post(`/super/payments/${pay.body.id}/cancel`, { reason: 'Not in bank' }, sa)).status).toBe(200);
    const after = (await h.api.get('/subscription', o.token)).body;
    expect(after.plan).toBeNull();
    expect(after.bills[0].cancelledAt).toBeTruthy();
    // UPI app says failed → nothing turns on; 3 fails pause payments
    for (let i = 0; i < 2; i++) {
      const p = await h.api.post('/subscription/payments', { key: `key-fail-000${i}`, planId: pro.id, cycle: 'MONTHLY' }, o.token);
      expect((await h.api.post(`/subscription/payments/${p.body.id}/done`, { upiStatus: 'FAILURE' }, o.token)).body.payment.status).toBe('FAILED');
    }
    const locked = await h.api.post('/subscription/payments', { key: 'key-lock-0001', planId: pro.id, cycle: 'MONTHLY' }, o.token);
    expect(locked.status).toBe(403);
    expect((await h.api.get('/subscription', o.token)).body.lockedUntil).toBeTruthy();
    // super admin report sees the income
    const rep = (await h.api.get('/super/reports?days=7', sa)).body;
    expect(rep.totals.income).toBe(11192); // income counts the day it came in
    expect(rep.totals.newGyms).toBeGreaterThanOrEqual(1);
  });

  it('owner adds a member with full details: account is made, sign-up says set password', async () => {
    const o = await h.ownerWithGym('Detail Gym');
    const ph = h.nextPhone();
    const d = { firstName: 'Rahul', middleName: 'Kumar', lastName: 'Sharma', dob: '1996-08-14', gender: 'male', state: 'Delhi', city: 'New Delhi', country: 'India', pincode: '110077' };
    const m = await h.api.post('/members', { ...d, phone: ph, email: 'rahul@test.in' }, o.token);
    expect(m.status).toBe(201);
    expect(m.body.accountMade).toBe(true);
    expect(m.body.name).toBe('Rahul Kumar Sharma');
    expect(m.body.pincode).toBe('110077');
    const s = await h.api.post('/auth/signup', { ...d, email: 'rahul@test.in', phone: h.nextPhone(), password: 'secret123' });
    expect(s.status).toBe(409);
    expect(s.body.code).toBe('ADDED_BY_GYM');
    expect(s.body.gymName).toBe('Detail Gym');
    // PIN must match the state
    expect((await h.api.post('/members', { ...d, pincode: '400001', phone: h.nextPhone(), email: 'x@test.in' }, o.token)).status).toBe(400);
    // normal sign-up with details
    const s2 = await h.api.post('/auth/signup', { ...d, email: 'new@test.in', phone: h.nextPhone(), password: 'secret123' });
    expect(s2.status).toBe(201);
    expect(s2.body.user.city).toBe('New Delhi');
    expect(s2.body.user.dob).toBe('1996-08-14');
  });

  it('branch code comes from the branch name; custom report dates work', async () => {
    const o = await h.ownerWithGym('Lifetime Fitness');
    const br = await h.api.post('/gym/branches', { name: 'Athelete' }, o.token);
    expect(br.status).toBe(201);
    expect(br.body.code).toMatch(/^ATHE\d{3}$/);
    const from = addDays(todayIST(), -5);
    const r = await h.api.get(`/reports?from=${from}&to=${todayIST()}`, o.token);
    expect(r.status).toBe(200);
    expect(r.body.days).toBe(6);
    expect(r.body.custom).toBe(true);
    expect((await h.api.get(`/reports?from=${todayIST()}&to=${from}`, o.token)).status).toBe(400);
  });
});

describe('Nov 3 night: rate limit, Google link, set password', () => {
  it('6th login try in a minute gets 429', async () => {
    const u = await h.signup();
    for (let i = 0; i < 5; i++) expect((await h.api.post('/auth/login', { identifier: u.email, password: 'secret123' })).status).toBe(200);
    const r = await h.api.post('/auth/login', { identifier: u.email, password: 'secret123' });
    expect(r.status).toBe(429);
    expect(r.body.message).toContain('Too many requests');
  });

  it('gym-added member logs in with Google (same email), then sets a password once', async () => {
    const o = await h.ownerWithGym('Google Gym');
    const d = { firstName: 'Neha', lastName: 'Gupta', dob: '1999-01-02', state: 'Delhi', city: 'New Delhi', country: 'India', pincode: '110001' };
    const m = await h.api.post('/members', { ...d, phone: h.nextPhone(), email: 'neha@test.in' }, o.token);
    expect(m.body.accountMade).toBe(true);
    const g = await h.api.post('/auth/google/login', { idToken: 'google:sub-neha:neha@test.in' });
    expect(g.status).toBe(200);
    expect(g.body.user.needsPassword).toBe(true);
    expect(g.body.user.email).toBe('neha@test.in');
    const set = await h.api.post('/auth/set-password', { next: 'newpass123' }, g.body.token);
    expect(set.status).toBe(200);
    expect(set.body.user.needsPassword).toBe(false);
    expect((await h.api.post('/auth/login', { identifier: 'neha@test.in', password: 'newpass123' })).status).toBe(200);
    // Google again: same account, no password page
    const g2 = await h.api.post('/auth/google/login', { idToken: 'google:sub-neha:neha@test.in' });
    expect(g2.body.user.id).toBe(g.body.user.id);
    expect(g2.body.user.needsPassword).toBe(false);
    // Google sign-up with that email just logs in
    const gs = await h.api.post('/auth/google/signup', { idToken: 'google:sub-neha:neha@test.in' });
    expect(gs.body.user.id).toBe(g.body.user.id);
  });
});

describe('deleted accounts', () => {
  it('owner removes a member, trainer or staff from the gym: their login stays', async () => {
    const owner = await h.ownerWithGym('Remove Gym');
    const mem = await h.signup('Removed Member');
    await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, mem.token);
    const reqs = await h.api.get('/join-requests', owner.token);
    const m = await h.api.post(`/join-requests/${reqs.body[0].id}/approve`, {}, owner.token);
    expect((await h.api.del(`/members/${m.body.id}`, owner.token)).status).toBe(200);
    expect((await h.api.get('/me/gyms', mem.token)).body.memberships).toEqual([]);
    expect((await h.api.post('/auth/login', { identifier: mem.email, password: 'secret123' })).status).toBe(200);
    // Joins again as new
    await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, mem.token);
    const r2 = await h.api.get('/join-requests', owner.token);
    expect((await h.api.post(`/join-requests/${r2.body[0].id}/approve`, {}, owner.token)).status).toBe(201);
    // Staff added with full details, then removed: login stays
    const ph = h.nextPhone();
    const add = await h.api.post('/gym/staff', { firstName: 'Desk', lastName: 'Person', dob: '1998-03-12', state: 'Delhi', city: 'New Delhi', pincode: '110075', phone: ph, email: `d${ph}@test.in`, preset: 'CHECKIN' }, owner.token);
    expect(add.status).toBe(201);
    expect(add.body.rights).toEqual(['members', 'checkin']);
    const staffList = await h.api.get('/gym/staff', owner.token);
    expect(staffList.body.some((x: any) => x.id === add.body.id && x.user.waitingForLogin)).toBe(true);
    expect((await h.api.del(`/gym/staff/${add.body.id}`, owner.token)).status).toBe(200);
    const su = await h.store.get<any>(P.user(add.body.id));
    expect(su.deleted).toBeFalsy();
    expect(su.staffOf[owner.gym.id].active).toBe(false);
  });

  it('staff rights limit what front desk can do; staff cannot sign up themselves', async () => {
    const owner = await h.ownerWithGym('Rights Gym');
    const ph = h.nextPhone();
    const add = await h.api.post('/gym/staff', { name: 'Check Only', phone: ph, role: 'FRONT_DESK', tempPassword: 'desk12345', preset: 'CHECKIN' }, owner.token);
    expect(add.status).toBe(201);
    const tok = (await h.api.post('/auth/login', { identifier: ph, password: 'desk12345' })).body.token;
    expect((await h.api.get('/members', tok)).status).toBe(200);
    expect((await h.api.post('/members', { name: 'Nope', phone: h.nextPhone() }, tok)).status).toBe(403);
    expect((await h.api.get('/reports?days=7', tok)).status).toBe(403);
    await h.api.patch(`/gym/staff/${add.body.id}`, { preset: 'MANAGER' }, owner.token);
    expect((await h.api.post('/members', { name: 'Yes Now', phone: h.nextPhone() }, tok)).status).toBe(201);
    const M = { 'x-gm-client': 'mobile' };
    const s = await h.api.post('/auth/signup', { name: 'Self Staff', email: `s${h.nextPhone()}@test.in`, phone: h.nextPhone(), password: 'secret123', role: 'STAFF' }, undefined, M);
    expect(s.status).toBe(400);
    // Logging in as Gym staff works; as Gym owner it does not
    expect((await h.api.post('/auth/login', { identifier: ph, password: 'desk12345', role: 'STAFF' }, undefined, M)).status).toBe(200);
    expect((await h.api.post('/auth/login', { identifier: ph, password: 'desk12345', role: 'OWNER' }, undefined, M)).status).toBe(403);
  });

  it('member deletes account: gym sees "No longer available", can delete them, and the same email/mobile can sign up again', async () => {
    const owner = await h.ownerWithGym('Gone Gym');
    const mem = await h.signup('Leaving Member');
    await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, mem.token);
    const reqs = await h.api.get('/join-requests', owner.token);
    const m = await h.api.post(`/join-requests/${reqs.body[0].id}/approve`, {}, owner.token);
    expect((await h.api.del('/me', mem.token)).status).toBe(400); // password needed
    expect((await h.api.del('/me', mem.token, { password: 'nope12345' })).body.message).toMatch(/Wrong password/);
    expect((await h.api.del('/me', mem.token, { password: 'secret123' })).status).toBe(200);
    const list = await h.api.get('/members', owner.token);
    const row = list.body.rows.find((r: any) => r.id === m.body.id);
    expect(row.gone).toBe(true);
    expect(list.body.counts.gone).toBe(1);
    // Signing up again with the same email and mobile works.
    const again = await h.api.post('/auth/signup', { name: 'Back Again', email: mem.email, phone: mem.phone, password: 'another123' });
    expect(again.status).toBe(201);
    // The owner deletes the old record; it leaves the list.
    expect((await h.api.del(`/members/${m.body.id}`, owner.token)).status).toBe(200);
    expect((await h.api.get('/members', owner.token)).body.rows.find((r: any) => r.id === m.body.id)).toBeUndefined();
    // Coming back to the gym works as a new member.
    await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, again.body.token);
    const r2 = await h.api.get('/join-requests', owner.token);
    expect((await h.api.post(`/join-requests/${r2.body[0].id}/approve`, {}, owner.token)).status).toBe(201);
  });

  it('super admin finds and deletes a person; the same email signs up again with a new password', async () => {
    const boss = await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' });
    const sup = boss.status === 201 ? boss.body.token : (await h.api.post('/auth/login', { identifier: 'boss@gymmantra.app', password: 'secret123' })).body.token;
    const p = await h.signup('Someone');
    const found = await h.api.get(`/super/users?q=${p.phone}`, sup);
    expect(found.body[0].id).toBe(p.user.id);
    expect((await h.api.post(`/super/users/${p.user.id}/delete`, {}, sup)).status).toBe(200);
    expect((await h.api.get(`/super/users?q=${p.email}`, sup)).body).toEqual([]);
    const again = await h.api.post('/auth/signup', { name: 'Someone Again', email: p.email, phone: p.phone, password: 'different99' });
    expect(again.status).toBe(201);
    const login = await h.api.post('/auth/login', { identifier: p.email, password: 'different99' });
    expect(login.status).toBe(200);
  });
});

describe('staff attendance', () => {
  it('staff marks Present only at the gym location; owner sees the month', async () => {
    const owner = await h.ownerWithGym('Present Gym');
    const ph = h.nextPhone();
    const add = await h.api.post('/gym/staff', { name: 'Desk Day', phone: ph, role: 'FRONT_DESK', tempPassword: 'desk12345' }, owner.token);
    const tok = (await h.api.post('/auth/login', { identifier: ph, password: 'desk12345' })).body.token;
    // No gym location yet
    expect((await h.api.post('/me/staff-attendance', { lat: 28.6, lng: 77.0 }, tok)).status).toBe(403);
    await h.api.get('/gym/checkin-qr', owner.token);
    expect((await h.api.put('/gym/location', { lat: 28.6, lng: 77.0 }, owner.token)).status).toBeLessThan(300);
    // Far away
    const far = await h.api.post('/me/staff-attendance', { lat: 28.7, lng: 77.0 }, tok);
    expect(far.status).toBe(403);
    expect(far.body.message).toMatch(/away/);
    const ok = await h.api.post('/me/staff-attendance', { lat: 28.60005, lng: 77.0, accuracy: 10 }, tok);
    expect(ok.status).toBe(201);
    const mine = await h.api.get('/me/staff-attendance', tok);
    expect(mine.body.markedToday).toBe(true);
    const all = await h.api.get('/staff-attendance', owner.token);
    expect(all.body.rows.find((r: any) => r.id === add.body.id).present.length).toBe(1);
  });
});

describe('gym transfer, close, broadcasts and gate', () => {
  const boss = async () => {
    const r = await h.api.post('/auth/login', { identifier: 'boss@gymmantra.app', password: 'secret123' });
    if (r.status === 200) return r.body.token as string;
    return (await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' })).body.token as string;
  };

  it('owner transfers the gym; old owner is free and can be deleted', async () => {
    const owner = await h.ownerWithGym('Sell Gym');
    const buyer = await h.signup('Buyer');
    const r = await h.api.post('/gym/transfer', { phone: buyer.phone, oldOwner: 'remove' }, owner.token);
    expect(r.status).toBe(200);
    expect((await h.api.get('/gym', buyer.token)).body.id).toBe(owner.gym.id);
    expect((await h.api.get('/gym', owner.token)).status).toBe(403);
    const sup = await boss();
    expect((await h.api.post(`/super/users/${owner.user.id}/delete`, {}, sup)).status).toBe(200);
  });

  it('super admin closes and reopens a gym', async () => {
    const owner = await h.ownerWithGym('Close Gym');
    const mem = await h.signup('Close Member');
    await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, mem.token);
    const reqs = await h.api.get('/join-requests', owner.token);
    await h.api.post(`/join-requests/${reqs.body[0].id}/approve`, {}, owner.token);
    const sup = await boss();
    expect((await h.api.post(`/super/gyms/${owner.gym.id}/close`, { confirm: 'wrong' }, sup)).status).toBe(400);
    expect((await h.api.post(`/super/gyms/${owner.gym.id}/close`, { confirm: owner.gym.gymCode }, sup)).status).toBe(200);
    expect((await h.api.get('/gym', owner.token)).status).toBe(403);
    expect((await h.api.get('/me/gyms', mem.token)).body.memberships[0].gym.closed).toBe(true);
    expect((await h.api.post(`/super/gyms/${owner.gym.id}/reopen`, {}, sup)).status).toBe(200);
    expect((await h.api.get('/gym', owner.token)).status).toBe(200);
  });

  it('broadcast reaches only the chosen roles', async () => {
    const owner = await h.ownerWithGym('Bc Gym');
    const mem = await h.signup('Bc Member');
    await h.api.patch('/me/profile', { appRole: 'MEMBER' }, mem.token);
    const sup = await boss();
    expect((await h.api.post('/super/broadcasts', { title: 'For owners', message: 'Hello owners', roles: ['OWNER'] }, sup)).status).toBe(201);
    const on = await h.api.get('/me/notifications', owner.token);
    expect(on.body.some((n: any) => n.title === 'For owners')).toBe(true);
    const mn = await h.api.get('/me/notifications', mem.token);
    expect(mn.body.some((n: any) => n.title === 'For owners')).toBe(false);
  });

  it('gate opens after an allowed desk check-in', async () => {
    const owner = await h.ownerWithGym('Gate Gym');
    const plan = (await h.api.post('/plans', { name: 'Monthly', months: 1, price: 1000 }, owner.token)).body;
    const m = (await h.api.post('/members', { name: 'Gate Member', phone: h.nextPhone() }, owner.token)).body;
    await h.api.post(`/members/${m.id}/memberships`, { planId: plan.id, paymentMode: 'CASH' }, owner.token);
    expect((await h.api.put('/gym/gate', { type: 'webhook', url: 'https://relay.example/open?key=abc' }, owner.token)).status).toBe(200);
    const calls: string[] = [];
    const real = global.fetch;
    (global as any).fetch = async (u: any, init?: any) => {
      if (!String(u).startsWith('https://relay.example/')) return real(u, init); // the emulator store uses fetch too
      calls.push(String(u));
      return new Response('ok');
    };
    try {
      const r = await h.api.post('/attendance/manual', { memberId: m.id }, owner.token);
      expect(r.body.result).toBe('ALLOWED');
      expect(r.body.gate).toBe('opened');
      expect(calls).toEqual(['https://relay.example/open?key=abc']);
    } finally {
      (global as any).fetch = real;
    }
    const g = await h.api.get('/gym/gate', owner.token);
    expect(g.body.url).not.toContain('abc');
  });
});

describe('phone notifications', () => {
  it('a payment sends a push to the member phone through FCM', async () => {
    const kp = (await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const der = new Uint8Array((await crypto.subtle.exportKey('pkcs8', kp.privateKey)) as ArrayBuffer);
    const pem = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(der).toString('base64')}\n-----END PRIVATE KEY-----\n`;
    h.deps.serviceAccount = { project_id: 'demo', client_email: 'sa@demo.iam.gserviceaccount.com', private_key: pem };
    const sent: any[] = [];
    const real = global.fetch;
    (global as any).fetch = async (u: any, init?: any) => {
      const url = String(u);
      if (url === 'https://oauth2.googleapis.com/token') return new Response(JSON.stringify({ access_token: 'tok', expires_in: 3600 }));
      if (url.startsWith('https://fcm.googleapis.com/')) {
        sent.push(JSON.parse(init.body));
        return new Response('{}');
      }
      return real(u, init);
    };
    try {
      const owner = await h.ownerWithGym('Push Gym');
      const mem = await h.signup('Push Member');
      expect((await h.api.post('/me/push-token', { token: 'phone-token-1234567890' }, mem.token)).status).toBe(200);
      await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, mem.token);
      const reqs = await h.api.get('/join-requests', owner.token);
      await h.api.post(`/join-requests/${reqs.body[0].id}/approve`, {}, owner.token);
      await new Promise((r) => setTimeout(r, 50));
      expect(sent.some((m) => m.message.token === 'phone-token-1234567890' && m.message.notification.title === 'Welcome!')).toBe(true);
      const topics = await h.api.get('/me/push-topics', mem.token);
      expect(topics.body.topics).toContain('all');
      expect(topics.body.topics.some((t: string) => t.startsWith('g_'))).toBe(true);
      // A notice only for expired members: this member has no plan (counts as not active) → gets it on the phone.
      sent.length = 0;
      expect((await h.api.post('/notices', { title: 'Come back', message: 'Renew this week', memberFilter: 'EXPIRED' }, owner.token)).status).toBe(201);
      await new Promise((r) => setTimeout(r, 50));
      expect(sent.some((m) => m.message.token === 'phone-token-1234567890' && m.message.notification.body === 'Renew this week')).toBe(true);
      // Only for active members: not sent to them.
      sent.length = 0;
      await h.api.post('/notices', { title: 'Active only', message: 'Yoga class', memberFilter: 'ACTIVE' }, owner.token);
      await new Promise((r) => setTimeout(r, 50));
      expect(sent.some((m) => m.message.token === 'phone-token-1234567890')).toBe(false);
    } finally {
      (global as any).fetch = real;
      h.deps.serviceAccount = null;
    }
  });
});

describe('plan reminders and GM Admin notifications', () => {
  it('reminder text by days left', async () => {
    const { reminderFor } = await import('../src/lib/superpush');
    const base: any = { name: 'Iron Gym', status: 'ACTIVE', trialEndsAt: null };
    const end = (d: string) => ({ ...base, planEndsAt: `${d}T18:29:59.000Z` });
    expect(reminderFor(end('2026-11-20'), 'Pro', '2026-11-05')).toBeNull();
    expect(reminderFor(end('2026-11-12'), 'Pro', '2026-11-05')!.title).toBe('Pro plan ends in 7 days');
    expect(reminderFor(end('2026-11-06'), 'Pro', '2026-11-05')!.title).toBe('Pro plan ends tomorrow');
    expect(reminderFor(end('2026-11-05'), 'Pro', '2026-11-05')!.title).toBe('Last day of your Pro plan');
    expect(reminderFor(end('2026-11-01'), 'Pro', '2026-11-05')!.title).toBe('Pro plan has ended');
    expect(reminderFor(end('2026-09-01'), 'Pro', '2026-11-05')).toBeNull(); // 65 days ago, not a weekly day
    expect(reminderFor(end('2026-09-03'), 'Pro', '2026-11-05')!.title).toBe('Pro plan has ended'); // 63 days = 9 weeks
    expect(reminderFor({ ...base, status: 'TRIAL', trialEndsAt: '2026-11-08T18:29:59.000Z' }, null, '2026-11-05')!.title).toBe('Free trial ends in 3 days');
  });

  it('super admin hears about a new gym, and can switch it off', async () => {
    const boss = await h.api.post('/auth/login', { identifier: 'boss@gymmantra.app', password: 'secret123' });
    const sup = boss.status === 200 ? boss.body.token : (await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' })).body.token;
    await h.ownerWithGym('Notify Me Gym');
    await new Promise((r) => setTimeout(r, 30));
    expect((await h.api.get('/me/notifications', sup)).body.some((n: any) => n.title === 'New gym registered' && n.body.includes('Notify Me Gym'))).toBe(true);
    expect((await h.api.put('/super/push-settings', { gyms: false }, sup)).body.gyms).toBe(false);
    await h.ownerWithGym('Quiet Gym');
    await new Promise((r) => setTimeout(r, 30));
    expect((await h.api.get('/me/notifications', sup)).body.some((n: any) => n.body.includes('Quiet Gym'))).toBe(false);
    await h.api.put('/super/push-settings', { gyms: true }, sup);
  });
});
