// Logged-in devices, logout everywhere, new-phone alert and the quiet 1-day login renewal (boards 96-98).
import { P } from '../src/core';
import { setup } from './helpers';

let h: ReturnType<typeof setup>;
beforeEach(() => {
  h = setup();
});

const phone = (name: string, id: string) => ({ 'x-gm-client': 'mobile', 'x-gm-refresh': '1', 'x-gm-device': name, 'x-gm-device-id': id });
async function login(identifier: string, headers: Record<string, string>) {
  const r = await h.api.call('POST', '/auth/login', { body: { identifier, password: 'secret123' }, headers });
  expect(r.status).toBe(200);
  return { token: r.body.token as string, refresh: r.headers.get('x-gm-refresh') };
}
const notes = async (token: string) => (await h.api.get('/me/notifications', token)).body as any[];
const refresh = (key: string) => h.api.call('POST', '/auth/refresh', { body: { refresh: key }, headers: { 'x-gm-client': 'mobile' } });

describe('sessions', () => {
  it('lists logins, logs one out at once, alerts on a new phone', async () => {
    const u = await h.signup('Session User');
    const a = await login(u.phone, phone('Redmi Note 12', 'dev-a'));
    expect(a.refresh).toMatch(/^[\w-]+\.[\w-]+$/);
    expect((await notes(a.token)).filter((n) => n.title === 'New login on your account')).toHaveLength(0); // first phone
    const b = await login(u.phone, phone('Samsung Galaxy A14', 'dev-b'));
    const alert = (await notes(a.token)).find((n) => n.title === 'New login on your account');
    expect([alert?.body.startsWith('Samsung Galaxy A14'), alert?.go]).toEqual([true, 'security']);
    const list = (await h.api.get('/me/sessions', a.token)).body;
    expect(list.map((s: any) => [s.device, s.current])).toEqual([['Redmi Note 12', true], ['Samsung Galaxy A14', false], ['Browser (website)', false]]);
    // log the Samsung out from the Redmi: its login stops at once, and its refresh key too
    const bid = list[1].id;
    expect((await h.api.del(`/me/sessions/${bid}`, a.token)).status).toBe(200);
    expect((await h.api.get('/auth/me', b.token)).status).toBe(401);
    expect((await refresh(b.refresh!)).status).toBe(401);
    expect((await h.api.get('/auth/me', a.token)).status).toBe(200);
    // another person cannot end my login
    const x = await h.signup('Other');
    expect((await h.api.del(`/me/sessions/${list[0].id}`, x.token)).status).toBe(404);
  });

  it('refresh: new key every time; a lost answer is forgiven; an old key later means theft', async () => {
    const u = await h.signup('Refresh User');
    const a = await login(u.phone, phone('Redmi', 'dev-a'));
    const r1 = await refresh(a.refresh!);
    expect(r1.status).toBe(200);
    const k1 = r1.headers.get('x-gm-refresh')!;
    expect(k1).not.toBe(a.refresh);
    expect((await h.api.get('/auth/me', r1.body.token)).status).toBe(200);
    // the phone lost that answer and sends the old key again right away: still fine
    const r2 = await refresh(a.refresh!);
    expect(r2.status).toBe(200);
    const k2 = r2.headers.get('x-gm-refresh')!;
    // later, the key from two steps ago (k1 is now old) shows up again: stolen → logged out
    const sid = k2.split('.')[0];
    const r3 = await refresh(k2);
    expect(r3.status).toBe(200);
    const s = await h.store.get<any>(P.session(sid));
    await h.store.set(P.session(sid), { ...s, rotatedAt: new Date(Date.now() - 10 * 60_000).toISOString() });
    const r4 = await refresh(k2); // k2 is now the previous key, used again after the grace time
    expect(r4.status).toBe(401);
    expect((await h.api.get('/auth/me', r3.body.token)).status).toBe(401);
    expect((await notes(u.token)).some((n) => n.title === 'Suspicious login stopped')).toBe(true);
    expect((await refresh('nope.nope')).status).toBe(401);
  });

  it('logout everywhere else, "It was not me", logout on the server, password change', async () => {
    const u = await h.signup('Everywhere User');
    const a = await login(u.phone, phone('Redmi', 'dev-a'));
    const b = await login(u.phone, phone('Samsung', 'dev-b'));
    const r = await h.api.post('/me/sessions/logout-others', {}, a.token);
    expect(r.status).toBe(200);
    expect((await h.api.get('/auth/me', a.token)).status).toBe(401); // old login of this phone replaced…
    expect((await h.api.get('/auth/me', r.body.token)).status).toBe(200); // …by the new one
    expect((await h.api.get('/auth/me', b.token)).status).toBe(401);
    expect((await h.api.get('/auth/me', u.token)).status).toBe(401); // older 30-day login too
    expect((await refresh(b.refresh!)).status).toBe(401);
    const list = (await h.api.get('/me/sessions', r.body.token)).body;
    expect(list.map((s: any) => s.device)).toEqual(['Redmi']);
    // the same phone keeps its refresh key working
    expect((await refresh(r.headers.get('x-gm-refresh') ?? a.refresh!)).status).toBe(200);
    // "It was not me"
    const c2 = await login(u.phone, phone('Unknown', 'dev-c'));
    const nm = await h.api.post('/me/sessions/not-me', {}, c2.token);
    expect(nm.status).toBe(200);
    expect((await h.api.get('/me/sessions', nm.body.token)).body).toHaveLength(1);
    // logout ends the login on the server
    const out = await h.api.call('POST', '/auth/logout', { token: nm.body.token, body: {} });
    expect(out.status).toBe(200);
    expect((await h.api.get('/auth/me', nm.body.token)).status).toBe(401);
    // logout with an expired login but the refresh key still ends that session
    const d = await login(u.phone, phone('Old', 'dev-d'));
    expect((await h.api.call('POST', '/auth/logout', { body: { refresh: d.refresh } })).status).toBe(200);
    expect((await refresh(d.refresh!)).status).toBe(401);
  });

  it('older apps (no refresh) still get a 30-day login', async () => {
    const u = await h.signup('Old App User');
    const r = await h.api.call('POST', '/auth/login', { body: { identifier: u.phone, password: 'secret123' }, headers: { 'x-gm-client': 'mobile' } });
    expect(r.headers.get('x-gm-refresh')).toBeNull();
    const exp = JSON.parse(Buffer.from((r.body.token as string).split('.')[1], 'base64url').toString()).exp;
    expect(exp - Date.now() / 1000).toBeGreaterThan(29 * 86400);
  });
});
