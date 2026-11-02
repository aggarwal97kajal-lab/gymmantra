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
    const wrong = await h.api.post('/auth/signup', { name: 'Half', email, phone: h.nextPhone(), password: 'other-pass1' });
    expect(wrong.status).toBe(409);
    expect(wrong.body.message).toMatch(/Forgot password/);
    expect((await h.api.post('/auth/forgot', { identifier: email })).status).toBe(200);
    const r = await h.api.post('/auth/signup', { name: 'Half', email, phone: h.nextPhone(), password: 'secret123' });
    expect(r.status).toBe(201);
    expect((await h.api.post('/auth/login', { identifier: email, password: 'secret123' })).status).toBe(200);
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
    expect((await h.api.post('/auth/google/signup', { idToken: 'google:g-1:g1@test.in' })).status).toBe(409);
  });

  it('Google signup does not take over a password account', async () => {
    const u = await h.signup();
    expect((await h.api.post('/auth/google/signup', { idToken: `google:g-2:${u.email}` })).status).toBe(409);
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

  it('routes tickets: gym topics to the gym, app problems to GymMantra', async () => {
    const owner = await h.ownerWithGym('Ticket Gym');
    const mem = await h.signup('Ticket Member');
    await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, mem.token);
    const reqs = await h.api.get('/join-requests', owner.token);
    const m = await h.api.post(`/join-requests/${reqs.body[0].id}/approve`, {}, owner.token);
    await h.api.post('/me/tickets', { topic: 'membership', subject: 'Renewal date wrong', body: 'Please check', memberId: m.body.id }, mem.token);
    await h.api.post('/me/tickets', { topic: 'app_bug', subject: 'App crashed', body: 'On QR screen' }, mem.token);
    const gymT = await h.api.get('/tickets', owner.token);
    expect(gymT.body.map((t: any) => t.subject)).toEqual(['Renewal date wrong']);
    expect((await h.api.post(`/tickets/${gymT.body[0].id}/messages`, { body: 'Fixed' }, owner.token)).status).toBe(201);
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
    expect((await h.api.del('/me', mem.token)).status).toBe(200);
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
