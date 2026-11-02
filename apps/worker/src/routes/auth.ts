import { App, AuthUser, authenticate, C, clearSession, isMobile, issueSession, isWebOnly, P, UserDoc, WEB_ONLY_MESSAGE } from '../core';
import { bad, conflict, forbidden, HttpError, notFound, nowIso, unauthorized } from '../lib/http';
import { normalizeEmail, normalizePhone } from '../lib/phone';
import { body, optStr, str } from '../lib/validate';
import { AlreadyExists } from '../store/store';
import { ADMIN_ONLY_MESSAGE, isAdminApp, isDeskStaff, isTrainer } from '../core';

export const MAX_LOGIN_ATTEMPTS = 3;
export const LOCK_MINUTES = 15;

export function publicUser(id: string, u: UserDoc) {
  return {
    id,
    name: u.name,
    email: u.email,
    phone: u.phone,
    photoUrl: u.photoV ? `/api/v1/photos/${id}?v=${u.photoV}` : null,
    isSuperAdmin: u.isSuperAdmin,
    language: u.language ?? 'en',
    hasPassword: !!u.authEmail,
    hasGoogle: !!u.googleSub,
    appRole: u.appRole ?? null,
    isOwner: isDeskStaff(u),
    isTrainer: isTrainer(u),
    trainerPending: Object.keys(u.trainerRequested ?? {}).length > 0,
  };
}

function newUser(name: string, extra: Partial<UserDoc>, isSuper: boolean): UserDoc {
  return {
    name,
    email: null,
    authEmail: null,
    fbUid: null,
    phone: null,
    googleSub: null,
    photoV: null,
    language: 'en',
    isSuperAdmin: isSuper,
    failed: 0,
    lockedUntil: null,
    createdAt: nowIso(),
    memberships: {},
    requested: {},
    staffOf: {},
    ...extra,
  };
}

function tooMany(until: string) {
  const mins = Math.max(1, Math.ceil((new Date(until).getTime() - Date.now()) / 60_000));
  return new HttpError(429, `Too many attempts. Try again in ${mins} minute${mins === 1 ? '' : 's'}`, { retryAfterMinutes: mins });
}

const PHONE_TAKEN = 'This mobile number already exists. Please log in, or use a different number';
const EMAIL_TAKEN = 'This email ID already exists. Please log in, or use a different email';

/** Mobile numbers with no email get a private sign-in address for Firebase. */
export const phoneAuthEmail = (phone: string) => `${phone.replace('+', '')}@phone.gymmantra.app`;

/** Creates a password account in Firebase and the GymMantra user record. */
export async function createPasswordUser(c: C, input: { name: string; email: string | null; phone: string; password: string }) {
  const { store, identity, superAdminEmail } = c.var.deps;
  // The email and the mobile number must be free. Records of removed accounts do not count.
  if (input.email && (await store.query<UserDoc>('users', [['email', input.email]])).some((r) => !r.data.deleted)) throw conflict(EMAIL_TAKEN);
  const phoneRef = await store.get<{ uid: string }>(P.phone(input.phone));
  const phoneOwner = phoneRef ? await store.get<UserDoc>(P.user(phoneRef.uid)) : null;
  if (phoneOwner && !phoneOwner.deleted) throw conflict(PHONE_TAKEN);
  const authEmail = input.email ?? phoneAuthEmail(input.phone);
  let fb: { uid: string; idToken?: string };
  let fresh = true;
  try {
    fb = await identity.signUp(authEmail, input.password);
  } catch (e) {
    if (!(e instanceof HttpError && e.message === 'EMAIL_EXISTS')) throw e;
    const owner = (await store.query<UserDoc>('users', [['authEmail', authEmail]])).find((r) => !r.data.deleted);
    if (owner) throw conflict(input.email ? EMAIL_TAKEN : PHONE_TAKEN);
    // Firebase has the login but GymMantra has no record (an earlier sign-up did not finish).
    // If the password matches, finish that sign-up now.
    try {
      fb = await identity.signIn(authEmail, input.password);
      fresh = false;
    } catch {
      throw conflict('This email was used in a sign-up that did not finish. Tap "Forgot password?" on the login page to set a new password, then sign up again with that password');
    }
  }
  const uid = fb.uid;
  const user = newUser(input.name, { email: input.email, authEmail, fbUid: uid, phone: input.phone }, !!input.email && input.email === superAdminEmail);
  try {
    await store.tx(async (t) => {
      if (phoneRef) t.set(P.phone(input.phone), { uid });
      else t.create(P.phone(input.phone), { uid });
      t.set(P.user(uid), user);
      const st = (await t.get<{ users: number }>(P.stats)) ?? { users: 0 };
      t.set(P.stats, { ...st, users: (st.users ?? 0) + 1 });
    });
  } catch (e) {
    // Don't leave a half-made login behind, or the same email could never sign up again.
    if (fresh && fb.idToken) await identity.deleteAccount(fb.idToken).catch(() => {});
    if (e instanceof AlreadyExists) throw conflict(PHONE_TAKEN);
    throw e;
  }
  return { uid, user };
}

export function authRoutes(app: App) {
  app.get('/api/v1/auth/config', (c) =>
    c.json({ googleClientId: c.var.deps.googleClientId, maxLoginAttempts: MAX_LOGIN_ATTEMPTS, lockMinutes: LOCK_MINUTES }),
  );

  app.post('/api/v1/auth/signup', async (c) => {
    const b = body(await c.req.json().catch(() => null));
    const name = str(b, 'name', { min: 2, max: 80, label: 'your name' });
    const email = normalizeEmail(str(b, 'email', { label: 'your email' }));
    if (!email) throw bad('Enter a valid email address');
    const phone = normalizePhone(str(b, 'phone', { label: 'your mobile number' }));
    if (!phone) throw bad('Enter a valid 10-digit mobile number');
    const password = str(b, 'password', { min: 8, max: 100, label: 'password' });
    const { uid, user } = await createPasswordUser(c, { name, email, phone, password });
    const token = await issueSession(c, uid);
    return c.json({ token, user: publicUser(uid, user) }, 201);
  });

  app.post('/api/v1/auth/login', async (c) => {
    const { store, identity } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    const identifier = str(b, 'identifier', { label: 'your email or mobile number' });
    const password = str(b, 'password', { max: 100, label: 'your password' });
    const email = normalizeEmail(identifier);
    const phone = email ? null : normalizePhone(identifier);

    // Find the GymMantra account first, so the lockout applies before Firebase is asked.
    let uid: string | null = null;
    if (phone) uid = (await store.get<{ uid: string }>(P.phone(phone)))?.uid ?? null;
    else if (email) uid = (await store.query<UserDoc>('users', [['authEmail', email]]))[0]?.id ?? null;
    const user = uid ? await store.get<UserDoc>(P.user(uid)) : null;
    if (!uid && email && (await store.query<UserDoc>('users', [['email', email]])).some((r) => !r.data.authEmail && !r.data.deleted)) {
      throw bad('This account was created with Google. Use "Continue with Google" to log in');
    }
    if (!uid || !user || user.deleted) throw unauthorized('Wrong email/mobile or password');
    if (user.lockedUntil && new Date(user.lockedUntil) > new Date()) throw tooMany(user.lockedUntil);
    if (!user.authEmail) throw bad('This account was created with Google. Use "Continue with Google" to log in');

    try {
      await identity.signIn(user.authEmail, password);
    } catch (e) {
      if (!(e instanceof HttpError) || e.message !== 'WRONG_PASSWORD') throw e;
      const res = await store.tx(async (t) => {
        const u = (await t.get<UserDoc>(P.user(uid!)))!;
        const failed = (u.failed ?? 0) + 1;
        if (failed >= MAX_LOGIN_ATTEMPTS) {
          const until = new Date(Date.now() + LOCK_MINUTES * 60_000).toISOString();
          t.set(P.user(uid!), { ...u, failed: 0, lockedUntil: until });
          return { locked: until, left: 0 };
        }
        t.set(P.user(uid!), { ...u, failed });
        return { locked: null, left: MAX_LOGIN_ATTEMPTS - failed };
      });
      if (res.locked) throw tooMany(res.locked);
      throw unauthorized(`Wrong password. ${res.left} attempt${res.left === 1 ? '' : 's'} left`);
    }
    const fresh = await store.tx(async (t) => {
      const u = (await t.get<UserDoc>(P.user(uid!)))!;
      const promote = !u.isSuperAdmin && !!u.email && u.email === c.var.deps.superAdminEmail;
      const next = { ...u, failed: 0, lockedUntil: null, isSuperAdmin: u.isSuperAdmin || promote };
      t.set(P.user(uid!), next);
      return next;
    });
    if (isMobile(c) && isWebOnly(fresh)) throw forbidden(WEB_ONLY_MESSAGE);
    if (isAdminApp(c) && !fresh.isSuperAdmin) throw forbidden(ADMIN_ONLY_MESSAGE);
    const token = await issueSession(c, uid);
    return c.json({ token, user: publicUser(uid, fresh) });
  });

  /** Google sign-up creates the account. */
  app.post('/api/v1/auth/google/signup', async (c) => {
    const { store, identity, superAdminEmail } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    const g = await identity.verifyGoogle(str(b, 'idToken', { max: 8000, label: 'the Google sign-in token' }));
    const uid = `g_${g.sub}`;
    if (await store.get(P.user(uid))) throw conflict('You already signed up with this Google account. Please log in with Google');
    if (g.email && (await store.query('users', [['email', g.email]])).length) {
      throw conflict('This email is already registered with a password. Log in with your email and password');
    }
    const phoneIn = optStr(b, 'phone');
    const phone = phoneIn ? normalizePhone(phoneIn) : null;
    if (phoneIn && !phone) throw bad('Enter a valid 10-digit mobile number');
    const user = newUser(
      g.name || (g.email ? g.email.split('@')[0] : 'GymMantra user'),
      { email: g.email, phone, googleSub: g.sub },
      !!g.email && g.email === superAdminEmail,
    );
    await store.tx(async (t) => {
      if (phone) t.create(P.phone(phone), { uid });
      t.create(P.user(uid), user);
      const st = (await t.get<{ users: number }>(P.stats)) ?? { users: 0 };
      t.set(P.stats, { ...st, users: (st.users ?? 0) + 1 });
    }).catch((e) => {
      if (e instanceof AlreadyExists) throw conflict('An account with this mobile number already exists. Please log in');
      throw e;
    });
    const token = await issueSession(c, uid);
    return c.json({ token, user: publicUser(uid, user) }, 201);
  });

  /** Google log-in works only for accounts that signed up with Google first. */
  app.post('/api/v1/auth/google/login', async (c) => {
    const { store, identity } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    const g = await identity.verifyGoogle(str(b, 'idToken', { max: 8000, label: 'the Google sign-in token' }));
    const uid = `g_${g.sub}`;
    const user = await store.get<UserDoc>(P.user(uid));
    if (!user || user.deleted) throw notFound('No GymMantra account for this Google account. Please sign up with Google first');
    if (user.lockedUntil && new Date(user.lockedUntil) > new Date()) throw tooMany(user.lockedUntil);
    if (isMobile(c) && isWebOnly(user)) throw forbidden(WEB_ONLY_MESSAGE);
    if (isAdminApp(c) && !user.isSuperAdmin) throw forbidden(ADMIN_ONLY_MESSAGE);
    const token = await issueSession(c, uid);
    return c.json({ token, user: publicUser(uid, user) });
  });

  /** Forgot password: Firebase emails a reset link to the account's email. */
  app.post('/api/v1/auth/forgot', async (c) => {
    const { store, identity } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    const identifier = str(b, 'identifier', { label: 'your email or mobile number' });
    const email = normalizeEmail(identifier);
    const phone = email ? null : normalizePhone(identifier);
    if (!email && !phone) throw bad('Enter a valid email or 10-digit mobile number');
    let user: UserDoc | null = null;
    if (phone) {
      const uid = (await store.get<{ uid: string }>(P.phone(phone)))?.uid;
      user = uid ? await store.get<UserDoc>(P.user(uid)) : null;
    } else {
      user = (await store.query<UserDoc>('users', [['email', email!]]))[0]?.data ?? null;
    }
    if ((!user || user.deleted) && email) {
      // A login from a sign-up that did not finish: let them reset it, then sign up again.
      try {
        await identity.sendPasswordReset(email);
      } catch {
        throw notFound('No GymMantra account found with this email or mobile number');
      }
      const [n, d] = email.split('@');
      return c.json({ sent: true, to: `${n.slice(0, 1)}${'•'.repeat(Math.max(2, Math.min(6, n.length - 1)))}@${d}` });
    }
    if (!user || user.deleted) throw notFound('No GymMantra account found with this email or mobile number');
    if (!user.authEmail) throw bad('This account uses Google sign-in. Use "Continue with Google" to log in');
    if (user.authEmail.endsWith('@phone.gymmantra.app')) {
      throw bad('This account has no email address. Ask your gym to help you reset the password');
    }
    await identity.sendPasswordReset(user.authEmail);
    const [name, domain] = user.authEmail.split('@');
    return c.json({ sent: true, to: `${name.slice(0, 1)}${'•'.repeat(Math.max(2, Math.min(6, name.length - 1)))}@${domain}` });
  });

  /** Our own "set a new password" page (the link in the reset email points here). */
  app.post('/api/v1/auth/reset/check', async (c) => {
    const b = body(await c.req.json().catch(() => null));
    const email = await c.var.deps.identity.checkResetCode(str(b, 'oobCode', { max: 2000, label: 'the reset code' }));
    const [n, d] = email.split('@');
    return c.json({ email: `${n.slice(0, 1)}${'•'.repeat(Math.max(2, Math.min(6, n.length - 1)))}@${d}` });
  });

  app.post('/api/v1/auth/reset', async (c) => {
    const { store, identity } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    const code = str(b, 'oobCode', { max: 2000, label: 'the reset code' });
    const password = str(b, 'password', { min: 8, max: 100, label: 'new password' });
    const email = await identity.resetPassword(code, password);
    // A fresh password also clears any lockout.
    const row = (await store.query<UserDoc>('users', [['authEmail', email]]))[0];
    if (row && (row.data.failed || row.data.lockedUntil)) {
      await store.tx(async (t) => {
        const u = await t.get<UserDoc>(P.user(row.id));
        if (u) t.set(P.user(row.id), { ...u, failed: 0, lockedUntil: null });
      });
    }
    return c.json({ ok: true });
  });

  app.post('/api/v1/auth/logout', (c) => {
    clearSession(c);
    return c.json({ ok: true });
  });

  app.get('/api/v1/auth/me', async (c) => {
    const u = await authenticate(c);
    return c.json(await meResponse(c, u));
  });

  app.post('/api/v1/auth/change-password', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const next = str(b, 'next', { min: 8, max: 100, label: 'new password' });
    const current = optStr(b, 'current', { max: 100 });
    const { store, identity } = c.var.deps;
    if (u.authEmail) {
      if (!current) throw unauthorized('Current password is wrong');
      try {
        await identity.changePassword(u.authEmail, current, next);
      } catch (e) {
        if (e instanceof HttpError && e.message === 'WRONG_PASSWORD') throw unauthorized('Current password is wrong');
        throw e;
      }
    } else {
      // Google account adding a password: create the Firebase password account.
      const authEmail = u.email ?? (u.phone ? phoneAuthEmail(u.phone) : null);
      if (!authEmail) throw bad('Add an email or mobile number first');
      const fb = await identity.changePassword(authEmail, null, next).catch((e) => {
        if (e instanceof HttpError && e.message === 'EMAIL_EXISTS') throw conflict('This email already has a password account');
        throw e;
      });
      await store.tx(async (t) => {
        const cur = (await t.get<UserDoc>(P.user(u.id)))!;
        t.set(P.user(u.id), { ...cur, authEmail, fbUid: fb.uid });
      });
    }
    return c.json({ ok: true });
  });
}

export async function meResponse(c: C, u: AuthUser) {
  const ids = Object.entries(u.staffOf ?? {}).filter(([, s]) => s.active);
  const tenants = await c.var.deps.store.getMany<any>(ids.map(([t]) => P.tenant(t)));
  return {
    user: publicUser(u.id, u),
    gyms: ids
      .map(([id, s], i) => (tenants[i] ? { id, name: tenants[i].name, gymCode: tenants[i].gymCode, status: tenants[i].status, logoUrl: tenants[i].logoUrl, role: s.role, branchIds: s.branchIds } : null))
      .filter(Boolean),
  };
}

export { forbidden };
