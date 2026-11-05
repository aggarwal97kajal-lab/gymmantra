import { createApp } from '../src/app';
import { Deps, resetSecretCache } from '../src/core';
import { FakeIdentity, FirebaseIdentity, serverToken } from '../src/identity';
import { FirestoreStore } from '../src/store/firestore';
import { resetBaseCheck } from '../src/routes/super';
import { MemoryStore, Store } from '../src/store/store';

/**
 * With FIREBASE_EMULATOR=1 the tests use the real Firebase adapters against the
 * Firebase emulators (Auth + Firestore with firestore.rules). Otherwise they use
 * the in-memory stand-ins.
 */
export const GYM_ADDRESS = { addressLine: 'Plot 12, Sector 7, Dwarka', state: 'Delhi', city: 'New Delhi', pincode: '110075' };
export const EMULATOR = process.env.FIREBASE_EMULATOR === '1';
const PROJECT = 'demo-gymmantra';
const AUTH_HOST = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com';
const FS_HOST = 'http://127.0.0.1:8080';
const SERVER_EMAIL = 'server@gymmantra.internal';
const SERVER_PASSWORD = 'emulator-server-password';

export async function resetEmulator() {
  await fetch(`${FS_HOST}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  await fetch(`http://127.0.0.1:9099/emulator/v1/projects/${PROJECT}/accounts`, { method: 'DELETE' });
  const r = await fetch(`${AUTH_HOST}/v1/accounts:signUp?key=fake-key`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: SERVER_EMAIL, password: SERVER_PASSWORD, returnSecureToken: true }) });
  if (!r.ok) throw new Error(`emulator server user: ${await r.text()}`);
}

class EmulatorIdentity extends FirebaseIdentity {
  fake = new FakeIdentity();
  // Google tokens cannot be minted in tests; use the fake verifier.
  verifyGoogle(idToken: string) {
    return this.fake.verifyGoogle(idToken);
  }
}
import exercises from '../../../media/exercises/exercises.json';

export function setup() {
  resetSecretCache();
  resetBaseCheck();
  let store: Store;
  let identity: any;
  if (EMULATOR) {
    // Real Firebase refuses server transactions for signed-in users; make sure we never use them.
    const realFetch = globalThis.fetch;
    (globalThis as any).fetch = (u: any, i?: any) => {
      if (String(u).includes(':beginTransaction')) throw new Error('beginTransaction is not allowed on real Firebase');
      return realFetch(u, i);
    };
    identity = new EmulatorIdentity('fake-key', [], AUTH_HOST);
    store = new FirestoreStore(PROJECT, serverToken(identity, SERVER_EMAIL, SERVER_PASSWORD), FS_HOST);
  } else {
    store = new MemoryStore();
    identity = new FakeIdentity();
  }
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
    put: (p: string, body: unknown, token?: string) => call('PUT', p, { body, token }),
    del: (p: string, token?: string, body?: unknown) => call('DELETE', p, { token, body }),
    call: (method: string, p: string, opts: { token?: string; body?: unknown; headers?: Record<string, string> } = {}) => call(method, p, opts),
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
    const g = await api.post('/gyms', { name, phone: o.phone, ...GYM_ADDRESS }, o.token);
    if (g.status !== 201) throw new Error(`gym failed ${JSON.stringify(g.body)}`);
    return { ...o, gym: g.body };
  }
  return { app, store: store as MemoryStore, identity: identity as FakeIdentity, deps, api, signup, ownerWithGym, nextPhone };
}
