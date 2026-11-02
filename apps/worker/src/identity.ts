import { createRemoteJWKSet, jwtVerify } from 'jose';
import { bad, HttpError, unauthorized } from './lib/http';

// Firebase Authentication over REST (Identity Toolkit). Firebase stores and
// checks passwords; GymMantra adds the lockout rule and its own session.

export interface GoogleProfile {
  sub: string;
  email: string | null;
  name: string | null;
  picture: string | null;
}

export interface Identity {
  signUp(email: string, password: string): Promise<{ uid: string; idToken?: string }>;
  /** Removes a Firebase account we just created (when saving the GymMantra record failed). */
  deleteAccount(idToken: string): Promise<void>;
  /** Throws HttpError(401) on a wrong email/password. */
  signIn(email: string, password: string): Promise<{ uid: string; idToken: string; expiresIn: number }>;
  changePassword(email: string, current: string | null, next: string): Promise<{ uid: string }>;
  /** Firebase emails a password reset link. */
  sendPasswordReset(email: string): Promise<void>;
  verifyGoogle(idToken: string): Promise<GoogleProfile>;
}

const GOOGLE_JWKS = createRemoteJWKSet(new URL('https://www.googleapis.com/oauth2/v3/certs'));

export class FirebaseIdentity implements Identity {
  constructor(
    private apiKey: string,
    private googleClientIds: string[],
    private host = 'https://identitytoolkit.googleapis.com', // the Firebase emulator in tests
  ) {}

  private async call(method: string, body: object) {
    const res = await fetch(`${this.host}/v1/accounts:${method}?key=${this.apiKey}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data: any = await res.json().catch(() => ({}));
    if (!res.ok) {
      const code = String(data?.error?.message ?? 'ERROR').split(' ')[0];
      if (['INVALID_LOGIN_CREDENTIALS', 'INVALID_PASSWORD', 'EMAIL_NOT_FOUND'].includes(code)) throw unauthorized('WRONG_PASSWORD');
      if (code === 'EMAIL_EXISTS') throw new HttpError(409, 'EMAIL_EXISTS');
      if (code.startsWith('WEAK_PASSWORD')) throw bad('Password is too weak. Use at least 8 characters');
      if (code === 'INVALID_EMAIL') throw bad('Enter a valid email address');
      if (code === 'USER_DISABLED') throw new HttpError(403, 'This account is disabled');
      if (code === 'TOO_MANY_ATTEMPTS_TRY_LATER') throw new HttpError(429, 'Too many attempts. Try again later');
      if (code === 'OPERATION_NOT_ALLOWED') throw new HttpError(500, 'Email/password sign-in is not turned on in Firebase');
      throw new HttpError(502, `Login service error (${code})`);
    }
    return data;
  }

  async signUp(email: string, password: string) {
    const d = await this.call('signUp', { email, password, returnSecureToken: true });
    return { uid: d.localId as string, idToken: d.idToken as string };
  }
  async deleteAccount(idToken: string) {
    await this.call('delete', { idToken });
  }
  async signIn(email: string, password: string) {
    const d = await this.call('signInWithPassword', { email, password, returnSecureToken: true });
    return { uid: d.localId as string, idToken: d.idToken as string, expiresIn: Number(d.expiresIn ?? 3600) };
  }
  async changePassword(email: string, current: string | null, next: string) {
    if (current === null) return this.signUp(email, next);
    const s = await this.signIn(email, current);
    await this.call('update', { idToken: s.idToken, password: next, returnSecureToken: false });
    return { uid: s.uid };
  }
  async sendPasswordReset(email: string) {
    await this.call('sendOobCode', { requestType: 'PASSWORD_RESET', email });
  }
  async verifyGoogle(idToken: string): Promise<GoogleProfile> {
    if (!this.googleClientIds.length) throw bad('Google sign-in is not set up yet');
    try {
      const { payload: p } = await jwtVerify(idToken, GOOGLE_JWKS, { issuer: ['https://accounts.google.com', 'accounts.google.com'], audience: this.googleClientIds });
      return { sub: String(p.sub), email: p.email_verified ? String(p.email) : null, name: (p.name as string) ?? null, picture: (p.picture as string) ?? null };
    } catch {
      throw unauthorized('Google sign-in failed. Please try again');
    }
  }
}

/** In-memory Firebase stand-in for tests and the local preview. */
export class FakeIdentity implements Identity {
  accounts = new Map<string, { uid: string; password: string }>();
  async signUp(email: string, password: string) {
    if (this.accounts.has(email)) throw new HttpError(409, 'EMAIL_EXISTS');
    if (password.length < 6) throw bad('Password is too weak. Use at least 8 characters');
    const uid = crypto.randomUUID().replace(/-/g, '').slice(0, 28);
    this.accounts.set(email, { uid, password });
    return { uid, idToken: `fake.${uid}` };
  }
  async deleteAccount(idToken: string) {
    const uid = idToken.replace('fake.', '');
    for (const [e, a] of this.accounts) if (a.uid === uid) this.accounts.delete(e);
  }
  async signIn(email: string, password: string) {
    const a = this.accounts.get(email);
    if (!a || a.password !== password) throw unauthorized('WRONG_PASSWORD');
    return { uid: a.uid, idToken: `fake.${a.uid}`, expiresIn: 3600 };
  }
  async changePassword(email: string, current: string | null, next: string) {
    if (current === null) return this.signUp(email, next);
    const s = await this.signIn(email, current);
    this.accounts.get(email)!.password = next;
    return { uid: s.uid };
  }
  resets: string[] = [];
  async sendPasswordReset(email: string) {
    if (!this.accounts.has(email)) throw unauthorized('WRONG_PASSWORD');
    this.resets.push(email);
  }
  /** Test tokens look like "google:<sub>:<email>". */
  async verifyGoogle(idToken: string) {
    const [kind, sub, email] = idToken.split(':');
    if (kind !== 'google' || !sub) throw unauthorized('Google sign-in failed. Please try again');
    return { sub, email: email || null, name: 'Google Person', picture: null };
  }
}

/** Gets (and caches) an ID token for the GymMantra server account, used to call Firestore. */
export function serverToken(identity: Identity, email: string, password: string) {
  let cached: { token: string; until: number } | null = null;
  return async () => {
    if (cached && cached.until > Date.now()) return cached.token;
    const s = await identity.signIn(email, password).catch((e) => {
      if (e instanceof HttpError && e.status === 401) throw new HttpError(500, 'Server account not found. Add the server user in Firebase Authentication (see setup guide)');
      throw e;
    });
    cached = { token: s.idToken, until: Date.now() + (s.expiresIn - 300) * 1000 };
    return cached.token;
  };
}
