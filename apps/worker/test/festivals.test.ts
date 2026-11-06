// Festival looks set by the super admin (GM Admin → Festivals), read by the apps without login.
import { setup } from './helpers';

let h: ReturnType<typeof setup>;
beforeEach(() => {
  h = setup();
});

describe('festivals', () => {
  it('super admin schedules a festival; apps see it while it is on or coming soon', async () => {
    const u0 = (await h.signup()).token;
    const boss = (await h.api.post('/auth/signup', { name: 'Boss', email: 'boss@gymmantra.app', phone: h.nextPhone(), password: 'secret123' })).body.token;
    const day = 86400_000;
    const on = { kind: 'diwali', title: 'Happy Diwali!', sub: 'Shubh Deepavali', from: new Date(Date.now() - day).toISOString(), to: new Date(Date.now() + day).toISOString(), roles: ['MEMBER', 'X'], states: [], sound: true };
    const r = await h.api.put('/super/festivals/new', on, boss);
    expect(r.status).toBe(200);
    expect(r.body.roles).toEqual(['MEMBER']);
    const old = await h.api.put('/super/festivals/new', { ...on, kind: 'holi', from: new Date(Date.now() - 9 * day).toISOString(), to: new Date(Date.now() - 8 * day).toISOString() }, boss);
    expect(old.status).toBe(200);
    expect((await h.api.put('/super/festivals/new', { ...on, kind: 'nope' }, boss)).status).toBe(400);
    expect((await h.api.put('/super/festivals/new', { ...on, to: on.from }, boss)).status).toBe(400);
    // apps (no login): only the one that is on
    const pub = await h.api.get('/festivals');
    expect(pub.body.map((f: any) => f.kind)).toEqual(['diwali']);
    // picture: only after the super admin uploads one
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    expect((await h.api.get(`/festivals/${r.body.id}/image`)).status).toBe(404);
    expect((await h.api.put(`/super/festivals/${r.body.id}/image`, { mime: 'image/png', base64: 'aGVsbG8gd29ybGQ=' }, boss)).status).toBe(400);
    const up = await h.api.put(`/super/festivals/${r.body.id}/image`, { mime: 'image/png', base64: png }, boss);
    expect(up.body.imageV).toBe(1);
    expect((await h.api.get('/festivals')).body[0].imageV).toBe(1);
    const img = await h.app.request(`/api/v1/festivals/${r.body.id}/image`);
    expect([img.status, img.headers.get('content-type')]).toEqual([200, 'image/png']);
    expect((await h.api.put(`/super/festivals/${r.body.id}`, on, boss)).body.imageV).toBe(1); // editing keeps it
    expect((await h.api.put(`/super/festivals/${r.body.id}/image`, { mime: 'image/png', base64: png }, u0)).status).toBe(403);
    expect((await h.api.del(`/super/festivals/${r.body.id}/image`, boss)).body.imageV).toBeUndefined();
    expect((await h.api.get(`/festivals/${r.body.id}/image`)).status).toBe(404);
    // turned off → gone for the apps
    await h.api.put(`/super/festivals/${r.body.id}`, { ...on, active: false }, boss);
    expect((await h.api.get('/festivals')).body).toEqual([]);
    expect((await h.api.get('/super/festivals', boss)).body).toHaveLength(2);
    // nobody else may change them
    const u = await h.signup();
    expect((await h.api.put('/super/festivals/new', on, u.token)).status).toBe(403);
    expect((await h.api.del(`/super/festivals/${r.body.id}`, u.token)).status).toBe(403);
    expect((await h.api.del(`/super/festivals/${r.body.id}`, boss)).status).toBe(200);
  });
});
