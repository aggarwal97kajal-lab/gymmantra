import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { AppModule } from '../src/app.module';
import { AuthService } from '../src/auth/auth.service';
import { ensureBaseData } from '../src/base-data';
import { addDays, todayIST } from '../src/common/dates';
import { PrismaService } from '../src/common/prisma.service';
import { makeQrToken } from '../src/attendance/qr-token';
import { configureApp } from '../src/setup';

let app: INestApplication;
let prisma: PrismaService;
let http: ReturnType<typeof request>;
let phoneN = 9000000000;
const nextPhone = () => String(++phoneN);

async function signup(name = 'Test User') {
  const phone = nextPhone();
  const email = `u${phone}@test.in`;
  const r = await http.post('/api/v1/auth/signup').send({ name, email, phone, password: 'secret123' }).expect(201);
  return { token: r.body.token as string, user: r.body.user, email, phone };
}
const auth = (t: string) => ({ Authorization: `Bearer ${t}` });

async function ownerWithGym(name: string) {
  const o = await signup(`${name} Owner`);
  const g = await http.post('/api/v1/gyms').set(auth(o.token)).send({ name, phone: o.phone }).expect(201);
  return { ...o, gym: g.body };
}

beforeAll(async () => {
  const mod = await Test.createTestingModule({ imports: [AppModule] }).compile();
  app = configureApp(mod.createNestApplication());
  await app.init();
  prisma = app.get(PrismaService);
  await ensureBaseData(prisma);
  http = request(app.getHttpServer());
  // Fake Google: the id token is "google:<sub>:<email>"
  app.get(AuthService).verifyGoogle = async (t: string) => {
    const [, sub, email] = t.split(':');
    return { sub, email, name: 'Google Person', picture: null };
  };
});
afterAll(async () => app.close());

describe('auth', () => {
  it('signs up and logs in with email or phone', async () => {
    const u = await signup();
    await http.post('/api/v1/auth/login').send({ identifier: u.email, password: 'secret123' }).expect(200);
    await http.post('/api/v1/auth/login').send({ identifier: u.phone, password: 'secret123' }).expect(200);
    const me = await http.get('/api/v1/auth/me').set(auth(u.token)).expect(200);
    expect(me.body.user.email).toBe(u.email);
  });

  it('rejects a duplicate signup', async () => {
    const u = await signup();
    await http.post('/api/v1/auth/signup').send({ name: 'Dup User', email: u.email, phone: nextPhone(), password: 'secret123' }).expect(409);
  });

  it('locks the account after 3 wrong passwords', async () => {
    const u = await signup();
    const r1 = await http.post('/api/v1/auth/login').send({ identifier: u.email, password: 'wrong1' }).expect(401);
    expect(r1.body.message).toContain('2 attempts left');
    await http.post('/api/v1/auth/login').send({ identifier: u.email, password: 'wrong2' }).expect(401);
    const r3 = await http.post('/api/v1/auth/login').send({ identifier: u.email, password: 'wrong3' }).expect(429);
    expect(r3.body.message).toMatch(/Too many attempts/);
    // Even the right password is refused while locked
    await http.post('/api/v1/auth/login').send({ identifier: u.email, password: 'secret123' }).expect(429);
    // After the lock passes, the right password works
    await prisma.user.update({ where: { email: u.email }, data: { lockedUntil: new Date(Date.now() - 1000) } });
    await http.post('/api/v1/auth/login').send({ identifier: u.email, password: 'secret123' }).expect(200);
  });

  it('Google login only works after Google signup', async () => {
    await http.post('/api/v1/auth/google/login').send({ idToken: 'google:g-1:g1@test.in' }).expect(404);
    await http.post('/api/v1/auth/google/signup').send({ idToken: 'google:g-1:g1@test.in' }).expect(201);
    await http.post('/api/v1/auth/google/login').send({ idToken: 'google:g-1:g1@test.in' }).expect(200);
    await http.post('/api/v1/auth/google/signup').send({ idToken: 'google:g-1:g1@test.in' }).expect(409);
  });

  it('Google signup does not take over a password account', async () => {
    const u = await signup();
    await http.post('/api/v1/auth/google/signup').send({ idToken: `google:g-2:${u.email}` }).expect(409);
  });

  it('cookie sessions need the client header for writes', async () => {
    const u = await signup();
    await http.post('/api/v1/gyms').set('Cookie', `gm_session=${u.token}`).send({ name: 'Cookie Gym' }).expect(403);
    await http.post('/api/v1/gyms').set('Cookie', `gm_session=${u.token}`).set('x-gm-client', 'admin').send({ name: 'Cookie Gym' }).expect(201);
  });
});

describe('gym, members and memberships', () => {
  let A: Awaited<ReturnType<typeof ownerWithGym>>;
  let B: Awaited<ReturnType<typeof ownerWithGym>>;
  let planA: any;
  let memberA: any;

  beforeAll(async () => {
    A = await ownerWithGym('Gym A');
    B = await ownerWithGym('Gym B');
    planA = (await http.post('/api/v1/plans').set(auth(A.token)).send({ name: 'Quarterly', months: 3, price: 4000, joiningFee: 500, freezeDays: 10 }).expect(201)).body;
    memberA = (await http.post('/api/v1/members').set(auth(A.token)).send({ name: 'Rahul', phone: nextPhone() }).expect(201)).body;
  });

  it('gym B cannot see or change gym A data', async () => {
    await http.get(`/api/v1/members/${memberA.id}`).set(auth(B.token)).expect(404);
    await http.patch(`/api/v1/members/${memberA.id}`).set(auth(B.token)).send({ name: 'Hacked' }).expect(404);
    await http.patch(`/api/v1/plans/${planA.id}`).set(auth(B.token)).send({ price: 1 }).expect(404);
    await http.post(`/api/v1/members/${memberA.id}/memberships`).set(auth(B.token)).send({ planId: planA.id, paymentMode: 'CASH' }).expect(404);
    const list = await http.get('/api/v1/members').set(auth(B.token)).expect(200);
    expect(list.body.rows.find((r: any) => r.id === memberA.id)).toBeUndefined();
    // Asking for gym A by header does not help: B is not staff there
    await http.get('/api/v1/members').set(auth(B.token)).set('x-gym-id', A.gym.id).expect(403);
    // A QR from gym A's member is rejected at gym B
    const { token } = makeQrToken('dev-only-qr-secret', memberA.id);
    await http.post('/api/v1/attendance/scan').set(auth(B.token)).send({ token }).expect(404);
  });

  it('adds a membership with joining fee and discount, then renews from the end date', async () => {
    const r = await http.post(`/api/v1/members/${memberA.id}/memberships`).set(auth(A.token)).send({ planId: planA.id, discount: 300, paymentMode: 'UPI' }).expect(201);
    expect(r.body.subscription.total).toBe(4200);
    expect(r.body.subscription.kind).toBe('NEW');
    expect(r.body.whatsappReceipt).toContain('https://wa.me/91');
    const prev = await http.get(`/api/v1/members/${memberA.id}/membership-preview?planId=${planA.id}`).set(auth(A.token)).expect(200);
    expect(prev.body.kind).toBe('RENEWAL');
    expect(prev.body.joiningFee).toBe(0);
    expect(prev.body.startDate).toBe(addDays(r.body.subscription.endDate.slice(0, 10), 1));
  });

  it('freezes the current membership within the allowed days', async () => {
    const d = await http.get(`/api/v1/members/${memberA.id}`).set(auth(A.token)).expect(200);
    const subId = d.body.state.currentId;
    await http.post(`/api/v1/memberships/${subId}/freeze`).set(auth(A.token)).send({ days: 11 }).expect(400);
    const f = await http.post(`/api/v1/memberships/${subId}/freeze`).set(auth(A.token)).send({ days: 4 }).expect(201);
    const d2 = await http.get(`/api/v1/members/${memberA.id}`).set(auth(A.token)).expect(200);
    expect(d2.body.state.status).toBe('FROZEN');
    expect(d2.body.state.entry.result).toBe('BLOCKED');
    await http.post(`/api/v1/freezes/${f.body.freeze.id}/end`).set(auth(A.token)).expect(201);
    const d3 = await http.get(`/api/v1/members/${memberA.id}`).set(auth(A.token)).expect(200);
    expect(d3.body.state.status).not.toBe('FROZEN');
  });

  it('not paid yet: admin decides entry; later payment clears the due', async () => {
    const m = (await http.post('/api/v1/members').set(auth(A.token)).send({ name: 'Due Person', phone: nextPhone() }).expect(201)).body;
    const r = await http.post(`/api/v1/members/${m.id}/memberships`).set(auth(A.token)).send({ planId: planA.id, paymentMode: 'NOT_PAID', allowEntryWhileDue: false }).expect(201);
    expect(r.body.due).toBe(4500);
    const scan1 = await http.post('/api/v1/attendance/manual').set(auth(A.token)).send({ memberId: m.id }).expect(201);
    expect(scan1.body.result).toBe('BLOCKED');
    expect(scan1.body.reason).toContain('Payment due');

    const m2 = (await http.post('/api/v1/members').set(auth(A.token)).send({ name: 'Allowed Due', phone: nextPhone() }).expect(201)).body;
    await http.post(`/api/v1/members/${m2.id}/memberships`).set(auth(A.token)).send({ planId: planA.id, paymentMode: 'NOT_PAID', allowEntryWhileDue: true }).expect(201);
    const scan2 = await http.post('/api/v1/attendance/manual').set(auth(A.token)).send({ memberId: m2.id }).expect(201);
    expect(scan2.body.result).toBe('WARNED');

    await http.post(`/api/v1/memberships/${r.body.subscription.id}/payments`).set(auth(A.token)).send({ amount: 5000, mode: 'CASH' }).expect(400);
    await http.post(`/api/v1/memberships/${r.body.subscription.id}/payments`).set(auth(A.token)).send({ amount: 4500, mode: 'CASH' }).expect(201);
    const scan3 = await http.post('/api/v1/attendance/manual').set(auth(A.token)).send({ memberId: m.id }).expect(201);
    expect(scan3.body.result).toBe('ALLOWED');
  });

  it('ignores a second scan within 2 minutes and blocks members with no plan', async () => {
    const m = (await http.post('/api/v1/members').set(auth(A.token)).send({ name: 'Scanner', phone: nextPhone() }).expect(201)).body;
    const none = await http.post('/api/v1/attendance/manual').set(auth(A.token)).send({ memberId: m.id }).expect(201);
    expect(none.body.result).toBe('BLOCKED');
    await http.post(`/api/v1/members/${m.id}/memberships`).set(auth(A.token)).send({ planId: planA.id, paymentMode: 'CASH' }).expect(201);
    const { token } = makeQrToken('dev-only-qr-secret', m.id);
    const s1 = await http.post('/api/v1/attendance/scan').set(auth(A.token)).send({ token }).expect(201);
    expect(s1.body.duplicate).toBe(false);
    const s2 = await http.post('/api/v1/attendance/scan').set(auth(A.token)).send({ token }).expect(201);
    expect(s2.body.duplicate).toBe(true);
    const today = await http.get('/api/v1/attendance/today').set(auth(A.token)).expect(200);
    expect(today.body.events.filter((e: any) => e.memberId === m.id && e.result !== 'BLOCKED')).toHaveLength(1);
  });

  it('a correction is a new row; history keeps the old one', async () => {
    const m = (await http.post('/api/v1/members').set(auth(A.token)).send({ name: 'Fix Me', phone: nextPhone() }).expect(201)).body;
    const r = await http.post(`/api/v1/members/${m.id}/memberships`).set(auth(A.token)).send({ planId: planA.id, paymentMode: 'CASH' }).expect(201);
    await http.post(`/api/v1/memberships/${r.body.subscription.id}/correct`).set(auth(A.token)).send({ planId: planA.id, discount: 500, paymentMode: 'CASH', amountReceived: 0 }).expect(400);
    const fix = await http.post(`/api/v1/memberships/${r.body.subscription.id}/correct`).set(auth(A.token)).send({ planId: planA.id, discount: 0, paymentMode: 'NOT_PAID', startDate: todayIST() }).expect(201);
    expect(fix.body.subscription.kind).toBe('CORRECTION');
    expect(fix.body.due).toBe(0); // earlier payment carried over
    const d = await http.get(`/api/v1/members/${m.id}`).set(auth(A.token)).expect(200);
    expect(d.body.history).toHaveLength(2);
    expect(d.body.history.filter((h: any) => h.superseded)).toHaveLength(1);
    expect(await prisma.auditLog.count({ where: { tenantId: A.gym.id, action: 'membership.correct' } })).toBe(1);
  });

  it('front desk cannot change plans or add staff, but can give discounts', async () => {
    const deskPhone = nextPhone();
    await http.post('/api/v1/gym/staff').set(auth(A.token)).send({ name: 'Desk', phone: deskPhone, role: 'FRONT_DESK', tempPassword: 'desk12345' }).expect(201);
    const login = await http.post('/api/v1/auth/login').send({ identifier: deskPhone, password: 'desk12345' }).expect(200);
    const desk = login.body.token;
    await http.post('/api/v1/plans').set(auth(desk)).send({ name: 'X', months: 1, price: 1 }).expect(403);
    await http.post('/api/v1/gym/staff').set(auth(desk)).send({ name: 'Y', phone: nextPhone(), role: 'OWNER', tempPassword: 'abcdefgh' }).expect(403);
    const m = (await http.post('/api/v1/members').set(auth(desk)).send({ name: 'Desk Added', phone: nextPhone() }).expect(201)).body;
    const r = await http.post(`/api/v1/members/${m.id}/memberships`).set(auth(desk)).send({ planId: planA.id, discount: 500, paymentMode: 'CASH' }).expect(201);
    expect(r.body.subscription.discount).toBe(500);
  });
});

describe('member app', () => {
  it('joins a gym by code, gets approved, sees membership and QR', async () => {
    const owner = await ownerWithGym('Join Gym');
    const plan = (await http.post('/api/v1/plans').set(auth(owner.token)).send({ name: 'Monthly', months: 1, price: 1500 }).expect(201)).body;
    await http.post('/api/v1/plans').set(auth(owner.token)).send({ name: 'Hidden', months: 1, price: 900, showInApp: false }).expect(201);
    const mem = await signup('Member Person');
    const look = await http.get(`/api/v1/me/gym-lookup?code=${owner.gym.gymCode}`).set(auth(mem.token)).expect(200);
    expect(look.body.name).toBe('Join Gym');
    await http.post('/api/v1/me/join').set(auth(mem.token)).send({ gymCode: owner.gym.gymCode }).expect(201);
    const plans = await http.get(`/api/v1/me/gyms/${owner.gym.id}/plans`).set(auth(mem.token)).expect(200);
    expect(plans.body.map((p: any) => p.name)).toEqual(['Monthly']);
    const reqs = await http.get('/api/v1/join-requests').set(auth(owner.token)).expect(200);
    const m = await http.post(`/api/v1/join-requests/${reqs.body[0].id}/approve`).set(auth(owner.token)).send({}).expect(201);
    await http.post(`/api/v1/members/${m.body.id}/memberships`).set(auth(owner.token)).send({ planId: plan.id, paymentMode: 'UPI' }).expect(201);
    const gyms = await http.get('/api/v1/me/gyms').set(auth(mem.token)).expect(200);
    expect(gyms.body.memberships[0].status).toBe('ACTIVE');
    const detail = await http.get(`/api/v1/me/memberships/${m.body.id}`).set(auth(mem.token)).expect(200);
    expect(detail.body.current.updatedBy).toBe('Join Gym Owner');
    const qr = await http.get(`/api/v1/me/qr/${m.body.id}`).set(auth(mem.token)).expect(200);
    const scan = await http.post('/api/v1/attendance/scan').set(auth(owner.token)).send({ token: qr.body.token }).expect(201);
    expect(scan.body.result).toBe('ALLOWED');
    const notes = await http.get('/api/v1/me/notifications').set(auth(mem.token)).expect(200);
    expect(notes.body.length).toBeGreaterThanOrEqual(2);
    // Another user cannot read this membership
    const other = await signup('Other');
    await http.get(`/api/v1/me/memberships/${m.body.id}`).set(auth(other.token)).expect(404);
  });

  it('routes tickets: gym topics to the gym, app problems to GymMantra', async () => {
    const owner = await ownerWithGym('Ticket Gym');
    const mem = await signup('Ticket Member');
    await http.post('/api/v1/me/join').set(auth(mem.token)).send({ gymCode: owner.gym.gymCode }).expect(201);
    const reqs = await http.get('/api/v1/join-requests').set(auth(owner.token)).expect(200);
    const m = await http.post(`/api/v1/join-requests/${reqs.body[0].id}/approve`).set(auth(owner.token)).send({}).expect(201);
    await http.post('/api/v1/me/tickets').set(auth(mem.token)).send({ topic: 'membership', subject: 'Renewal date wrong', body: 'Please check', memberId: m.body.id }).expect(201);
    await http.post('/api/v1/me/tickets').set(auth(mem.token)).send({ topic: 'app_bug', subject: 'App crashed', body: 'On QR screen' }).expect(201);
    const gymT = await http.get('/api/v1/tickets').set(auth(owner.token)).expect(200);
    expect(gymT.body.map((t: any) => t.subject)).toEqual(['Renewal date wrong']);
    await http.post(`/api/v1/tickets/${gymT.body[0].id}/messages`).set(auth(owner.token)).send({ body: 'Fixed' }).expect(201);
    await http.get('/api/v1/super/tickets').set(auth(owner.token)).expect(403);
  });
});

describe('super admin', () => {
  it('only super admins can change SaaS plans', async () => {
    const u = await signup();
    await http.get('/api/v1/super/saas-plans').set(auth(u.token)).expect(403);
    await prisma.user.update({ where: { id: u.user.id }, data: { isSuperAdmin: true } });
    const plans = await http.get('/api/v1/super/saas-plans').set(auth(u.token)).expect(200);
    expect(plans.body.plans.map((p: any) => [p.name, p.monthlyPrice, p.annualPrice])).toEqual([
      ['Starter', 399, 3990],
      ['Growth', 799, 7990],
      ['Pro', 1399, 13990],
    ]);
    const growth = plans.body.plans[1];
    await http.patch(`/api/v1/super/saas-plans/${growth.id}`).set(auth(u.token)).send({ monthlyPrice: 849 }).expect(200);
    const pub = await http.get('/api/v1/saas-plans').expect(200);
    expect(pub.body.plans[1].monthlyPrice).toBe(849);
    await http.patch('/api/v1/super/settings').set(auth(u.token)).send({ trialMonths: 2 }).expect(200);
    expect(await prisma.auditLog.count({ where: { action: 'saas_plan.update' } })).toBe(1);
  });
});

describe('photos and exercises', () => {
  const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 0xff, 0xd9]).toString('base64');

  it('uploads a profile photo that only the member and their gym staff can see', async () => {
    const owner = await ownerWithGym('Photo Gym');
    const mem = await signup('Photo Member');
    const stranger = await signup('Stranger');
    const up = await http.post('/api/v1/me/photo').set(auth(mem.token)).send({ mime: 'image/jpeg', base64: JPEG }).expect(201);
    expect(up.body.photoUrl).toContain(`/api/v1/photos/${mem.user.id}`);
    await http.get(`/api/v1/photos/${mem.user.id}`).set(auth(mem.token)).expect(200);
    await http.get(`/api/v1/photos/${mem.user.id}`).set(auth(stranger.token)).expect(403);
    await http.get(`/api/v1/photos/${mem.user.id}`).set(auth(owner.token)).expect(403);
    await http.post('/api/v1/me/join').set(auth(mem.token)).send({ gymCode: owner.gym.gymCode }).expect(201);
    await http.get(`/api/v1/photos/${mem.user.id}`).set(auth(owner.token)).expect(200);
    await http.post('/api/v1/me/photo').set(auth(mem.token)).send({ mime: 'image/png', base64: JPEG }).expect(400);
  });

  it('lists the 40 exercise guides', async () => {
    const r = await http.get('/api/v1/exercises').expect(200);
    expect(r.body).toHaveLength(40);
    expect(r.body[0].videoUrl).toMatch(/^\/media\/exercises\/videos\/01_/);
    await http.get(r.body[0].stillUrl).expect(200);
  });
});
