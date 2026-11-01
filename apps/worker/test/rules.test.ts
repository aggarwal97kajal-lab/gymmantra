import { EMULATOR, resetEmulator } from './helpers';

// Firestore rules: nobody but the server account can read or write.
(EMULATOR ? describe : describe.skip)('firestore rules', () => {
  beforeAll(resetEmulator);
  const AUTH = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts';
  const DOC = 'http://127.0.0.1:8080/v1/projects/demo-gymmantra/databases/(default)/documents/users/x';
  const token = async (email: string, password: string, create: boolean) => {
    const r = await fetch(`${AUTH}:${create ? 'signUp' : 'signInWithPassword'}?key=fake-key`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password, returnSecureToken: true }) });
    return ((await r.json()) as any).idToken as string;
  };
  it('blocks anonymous and ordinary users, allows the server', async () => {
    expect((await fetch(DOC)).status).toBe(403);
    const user = await token('someone@test.in', 'secret123', true);
    expect((await fetch(DOC, { headers: { authorization: `Bearer ${user}` } })).status).toBe(403);
    const server = await token('server@gymmantra.internal', 'emulator-server-password', false);
    expect((await fetch(DOC, { headers: { authorization: `Bearer ${server}` } })).status).toBe(404); // allowed, just missing
  });
});
