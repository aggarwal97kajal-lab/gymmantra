import { P } from '../src/core';
import { makeQrToken } from '../src/lib/qr';
import { addDays, todayIST } from '../src/lib/dates';
import { EMULATOR, resetEmulator, setup } from './helpers';

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
    expect((await h.api.post('/gyms', { name: 'Cookie Gym' }, undefined, { ...cookie, 'x-gm-client': 'admin' })).status).toBe(201);
  });

  it('staff and super admin cannot use the member app; members can', async () => {
    const owner = await h.ownerWithGym('Web Only Gym');
    const mobile = { 'x-gm-client': 'mobile' };
    const r = await h.api.post('/auth/login', { identifier: owner.email, password: 'secret123' }, undefined, mobile);
    expect(r.status).toBe(403);
    expect(r.body.message).toMatch(/website/);
    expect((await h.api.get('/me/gyms', owner.token, mobile)).status).toBe(401);
    expect((await h.api.get('/gym', owner.token)).status).toBe(200);
    const mem = await h.signup('Plain Member');
    expect((await h.api.post('/auth/login', { identifier: mem.email, password: 'secret123' }, undefined, mobile)).status).toBe(200);
    expect((await h.api.get('/me/gyms', mem.token, mobile)).status).toBe(200);
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
