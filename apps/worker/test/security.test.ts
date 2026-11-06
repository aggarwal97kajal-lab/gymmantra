/**
 * Security guard (owner request, Nov 5):
 *  1. No one gets data without logging in — checked for EVERY route the server has, so a new
 *     feature that forgets the login check fails here before it can be deployed.
 *  2. Changing an id in the URL never shows or changes someone else's data: a gym cannot reach
 *     another gym, a member cannot reach another member, a normal user cannot reach super admin.
 * The deploy runs these tests first (package.json build:cf), so a failing check stops the deploy.
 */
import { P } from '../src/core';
import { EMULATOR, GYM_ADDRESS, resetEmulator, setup } from './helpers';

let h: ReturnType<typeof setup>;
beforeEach(async () => {
  if (EMULATOR) await resetEmulator();
  h = setup();
});

/** Routes that are open on purpose (no personal data). Anything else must refuse a call without login. */
const PUBLIC = new Set([
  'GET /api/v1/auth/config', // app settings (Google client id, support number)
  'GET /api/v1/ping', // connection warm-up
  'POST /api/v1/diag', // timing reports from apps (write-only)
  'GET /api/v1/ads/:id/image', // advert picture (random id)
  'GET /api/v1/offers/:tenantId/:id/image', // offer banner picture (random ids)
  'GET /api/v1/exercises', // exercise library
  'GET /api/v1/legal/:kind', // terms and privacy
  'GET /api/v1/health', // server is up
  'GET /api/v1/saas-plans', // GymMantra prices for the sign-up page
  'GET /api/v1/festivals', // festival looks (public: which animation on which days)
  'POST /api/v1/punch/:id', // fingerprint / face machines (secret random id; unknown → 404)
]);
const OK = (s: number) => s >= 200 && s < 300;

describe('security: login needed everywhere', () => {
  it('every route refuses a call without login (except the public list)', async () => {
    const routes = (h.app as unknown as { routes: { method: string; path: string }[] }).routes
      .filter((r) => r.path.startsWith('/api/') && r.method !== 'ALL')
      .map((r) => ({ method: r.method, path: r.path }));
    const seen = new Set<string>();
    const leaks: string[] = [];
    for (const r of routes) {
      const key = `${r.method} ${r.path}`;
      if (seen.has(key)) continue;
      seen.add(key);
      if (PUBLIC.has(key) || r.path.startsWith('/api/v1/auth/')) continue; // login / sign-up routes are open by nature
      const url = r.path.replace(/^\/api\/v1/, '').replace(/:[A-Za-z]+/g, '00000000-0000-4000-8000-000000000000');
      const res = await h.app.request(`/api/v1${url}`, { method: r.method, headers: { 'content-type': 'application/json', 'x-gm-client': 'mobile' }, body: r.method === 'GET' ? undefined : '{}' });
      if (OK(res.status)) leaks.push(`${key} → ${res.status}`);
    }
    expect(routes.length).toBeGreaterThan(100);
    expect(leaks).toEqual([]);
  });

  it('fingerprint machine routes answer only machines an owner added', async () => {
    for (const [m, p] of [['GET', '/iclock/cdata?SN=NOPE123'], ['POST', '/iclock/cdata?SN=NOPE123&table=ATTLOG'], ['GET', '/iclock/getrequest?SN=NOPE123'], ['POST', '/iclock/devicecmd?SN=NOPE123'], ['GET', '/iclock/cdata']]) {
      expect([p, (await h.app.request(p, { method: m, body: m === 'POST' ? '1\t2026-01-01 10:00:00' : undefined })).status]).toEqual([p, 404]);
    }
  });

  it('a made-up or old token is refused', async () => {
    expect((await h.api.get('/auth/me', 'not-a-real-token')).status).toBe(401);
    expect((await h.api.get('/members', 'eyJhbGciOiJIUzI1NiJ9.eyJ1aWQiOiJ4In0.bad')).status).toBe(401);
  });
});

describe('security: changing an id in the URL never reaches someone else', () => {
  async function world() {
    const A = await h.ownerWithGym('Alpha Gym');
    const B = await h.ownerWithGym('Beta Gym');
    const planB = (await h.api.post('/plans', { name: 'Monthly', months: 1, price: 1000 }, B.token)).body;
    const memB = await h.signup('Beta Member');
    await h.api.post('/me/join', { gymCode: B.gym.gymCode }, memB.token);
    const jr = (await h.api.get('/join-requests', B.token)).body[0];
    const mB = (await h.api.post(`/join-requests/${jr.id}/approve`, {}, B.token)).body;
    const subB = (await h.api.post(`/members/${mB.id}/memberships`, { planId: planB.id, paymentMode: 'NOT_PAID' }, B.token)).body;
    const ticketB = (await h.api.post('/me/tickets', { topic: Object.keys((await import('../src/routes/tickets')).TICKET_TOPICS)[0], subject: 'My problem', body: 'Help me please' }, memB.token)).body;
    const memA = await h.signup('Alpha Member');
    const noticeB = (await h.api.post('/notices', { title: 'Beta notice', message: 'Only Beta' }, B.token)).body;
    const offerB = (await h.api.post('/offers', { title: 'Beta offer', details: 'x', forMembers: true, validTill: '2030-01-01' }, B.token)).body;
    // a second member in Beta for member-vs-member checks
    const memB2 = await h.signup('Beta Member Two');
    await h.api.post('/me/join', { gymCode: B.gym.gymCode }, memB2.token);
    const jr2 = (await h.api.get('/join-requests', B.token)).body[0];
    await h.api.post(`/join-requests/${jr2.id}/approve`, {}, B.token);
    // Make sure the test really has Beta's ids (otherwise the checks below would prove nothing).
    for (const [k, v] of Object.entries({ planB: planB.id, mB: mB.id, ticketB: ticketB.id, noticeB: noticeB.id, offerB: offerB.id })) expect([k, v]).toEqual([k, expect.any(String)]);
    return { A, B, planB, memB, mB, subB, ticketB, memA, memB2, noticeB, offerB };
  }

  it('gym A owner cannot see or change gym B', async () => {
    const w = await world();
    const subId = w.subB.subscription?.id ?? w.subB.id;
    expect(subId).toEqual(expect.any(String));
    const tries: [string, string, unknown?][] = [
      ['GET', `/members/${w.mB.id}`],
      ['PATCH', `/members/${w.mB.id}`, { name: 'Hacked' }],
      ['DELETE', `/members/${w.mB.id}`],
      ['POST', `/members/${w.mB.id}/memberships`, { planId: w.planB.id, paymentMode: 'CASH' }],
      ['GET', `/members/${w.mB.id}/membership-preview?planId=${w.planB.id}`],
      ['PATCH', `/plans/${w.planB.id}`, { price: 1 }],
      ['DELETE', `/plans/${w.planB.id}`],
      ['GET', `/programs/${w.mB.id}`],
      ['PUT', `/programs/${w.mB.id}`, { diet: 'x' }],
      ['DELETE', `/notices/${w.noticeB.id}`],
      ['PATCH', `/offers/${w.offerB.id}`, { title: 'x' }],
      ['DELETE', `/offers/${w.offerB.id}`],
      ['GET', `/tickets/${w.ticketB.id}`],
      ['PATCH', `/gym/staff/${w.B.user.id}`, { active: false }],
      ['DELETE', `/gym/staff/${w.B.user.id}`],
      ['PUT', `/staff-attendance/${w.B.user.id}/2026-01-01`, { present: true }],
      ['GET', `/super/gyms/${w.B.gym.id}`],
      ['POST', `/super/gyms/${w.B.gym.id}/close`, { confirm: w.B.gym.gymCode }],
      ['POST', `/super/users/${w.memB.user.id}/delete`, {}],
    ];
    if (subId) {
      tries.push(['POST', `/memberships/${subId}/payments`, { amount: 100, mode: 'CASH' }]);
      tries.push(['POST', `/memberships/${subId}/freeze`, { days: 3 }]);
      tries.push(['POST', `/memberships/${subId}/correct`, { planId: w.planB.id, paymentMode: 'NOT_PAID', note: 'x' }]);
    }
    const leaks: string[] = [];
    for (const [m, path, body] of tries) {
      const r = await h.api.call(m, path, { token: w.A.token, body: m === 'GET' ? undefined : body ?? {} });
      if (OK(r.status)) leaks.push(`${m} ${path} → ${r.status}`);
    }
    expect(leaks).toEqual([]);
    // Nothing changed in Beta
    expect((await h.store.get<any>(P.member(w.B.gym.id, w.mB.id))).name).toBe('Beta Member');
    // Even sending Beta's id in the gym header does not switch gyms
    const r = await h.api.call('GET', `/members/${w.mB.id}`, { token: w.A.token, headers: { 'x-gym-id': w.B.gym.id } });
    expect(OK(r.status)).toBe(false);
  });

  it('a member cannot see another member, another gym, or staff screens', async () => {
    const w = await world();
    const tries: [string, string, unknown?][] = [
      ['GET', `/me/memberships/${w.mB.id}`], // Alpha member → Beta member's membership
      ['GET', `/me/qr/${w.mB.id}`],
      ['GET', `/me/attendance/${w.mB.id}`],
      ['GET', `/me/tickets/${w.ticketB.id}`],
      ['POST', `/me/tickets/${w.ticketB.id}/messages`, { message: 'hi' }],
      ['GET', `/photos/${w.memB.user.id}`],
      ['GET', '/members'],
      ['GET', `/members/${w.mB.id}`],
      ['GET', '/dashboard'],
      ['GET', '/reports?days=7'],
      ['GET', '/super/overview'],
      ['GET', '/super/users?q=9999999999'],
    ];
    const leaks: string[] = [];
    for (const who of [w.memA, w.memB2]) {
      for (const [m, path, body] of tries) {
        if (who === w.memB2 && path === '/members') continue;
        const r = await h.api.call(m, path, { token: who.token, body: m === 'GET' ? undefined : body ?? {} });
        if (OK(r.status)) leaks.push(`${who === w.memA ? 'Alpha member' : 'Beta member 2'}: ${m} ${path} → ${r.status}`);
      }
    }
    expect(leaks).toEqual([]);
    // …but the real member still sees their own
    expect((await h.api.get(`/me/memberships/${w.mB.id}`, w.memB.token)).status).toBe(200);
  });

  it('front desk of branch 1 cannot open members of branch 2', async () => {
    const A = await h.ownerWithGym('Branch Gym');
    const br2 = (await h.api.post('/gym/branches', { name: 'Second', ...GYM_ADDRESS }, A.token)).body;
    const ph = h.nextPhone();
    const first = (await h.api.get('/gym', A.token)).body.branches[0].id;
    await h.api.post('/gym/staff', { name: 'Desk One', phone: ph, role: 'FRONT_DESK', tempPassword: 'desk12345', branchId: first }, A.token);
    const desk = (await h.api.post('/auth/login', { identifier: ph, password: 'desk12345' })).body.token;
    const m2 = (await h.api.call('POST', '/members', { token: A.token, body: { name: 'Second Branch Member', phone: h.nextPhone(), branchId: br2.id ?? br2.branches?.at(-1)?.id }, headers: { 'x-branch-id': br2.id ?? '' } })).body;
    if (m2?.id && m2.branchId && m2.branchId !== first) {
      expect(OK((await h.api.get(`/members/${m2.id}`, desk)).status)).toBe(false);
      expect(OK((await h.api.patch(`/members/${m2.id}`, { name: 'x' }, desk)).status)).toBe(false);
    }
  });
});
