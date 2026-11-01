import { createApp } from '../src/app';
import { Deps, resetSecretCache } from '../src/core';
import { FakeIdentity } from '../src/identity';
import { resetBaseCheck } from '../src/routes/super';
import { MemoryStore } from '../src/store/store';
import exercises from '../../../media/exercises/exercises.json';

export function setup() {
  resetSecretCache();
  resetBaseCheck();
  const store = new MemoryStore();
  const identity = new FakeIdentity();
  const deps: Deps = { store, identity, superAdminEmail: 'boss@gymmantra.app', googleClientId: 'test-client', secure: false, assetJson: async () => exercises };
  const app = createApp(() => deps);
  let phoneN = 9000000000;
  const nextPhone = () => String(++phoneN);

  async function call(method: string, path: string, opts: { token?: string; body?: unknown; headers?: Record<string, string> } = {}) {
    const headers: Record<string, string> = { ...(opts.headers ?? {}) };
    if (opts.token) headers.authorization = `Bearer ${opts.token}`;
    if (opts.body !== undefined) headers['content-type'] = 'application/json';
    const res = await app.request(`/api/v1${path}`, { method, headers, body: opts.body === undefined ? undefined : JSON.stringify(opts.body) });
    const text = await res.text();
    let data: any = text;
    try {
      data = JSON.parse(text);
    } catch {}
    return { status: res.status, body: data, headers: res.headers };
  }
  const api = {
    get: (p: string, token?: string, headers?: Record<string, string>) => call('GET', p, { token, headers }),
    post: (p: string, body: unknown, token?: string, headers?: Record<string, string>) => call('POST', p, { body, token, headers }),
    patch: (p: string, body: unknown, token?: string) => call('PATCH', p, { body, token }),
    del: (p: string, token?: string) => call('DELETE', p, { token }),
  };

  async function signup(name = 'Test User') {
    const phone = nextPhone();
    const email = `u${phone}@test.in`;
    const r = await api.post('/auth/signup', { name, email, phone, password: 'secret123' });
    if (r.status !== 201) throw new Error(`signup failed ${r.status} ${JSON.stringify(r.body)}`);
    return { token: r.body.token as string, user: r.body.user, email, phone };
  }
  async function ownerWithGym(name: string) {
    const o = await signup(`${name} Owner`);
    const g = await api.post('/gyms', { name, phone: o.phone }, o.token);
    if (g.status !== 201) throw new Error(`gym failed ${JSON.stringify(g.body)}`);
    return { ...o, gym: g.body };
  }
  return { app, store, identity, deps, api, signup, ownerWithGym, nextPhone };
}
