import { App, AuthUser, authenticate, C, isMobile, issueSession, isWebOnly, P, SessionDoc, UserDoc, WEB_ONLY_MESSAGE } from '../core';
import { bad, conflict, forbidden, HttpError, notFound, nowIso, unauthorized } from '../lib/http';
import { normalizeEmail, normalizePhone } from '../lib/phone';
import { body, oneOf, optStr, str } from '../lib/validate';
import { AlreadyExists } from '../store/store';
import { hasDetails, personDetails } from '../lib/person';
import { bumpCounter, clearCounter, ipOf, rateLimit, readCounter } from '../lib/ratelimit';
import { cleanRights, RIGHTS, accountRole, ADMIN_ONLY_MESSAGE, AppRole, isAdminApp, isDeskStaff, isTrainer, wrongRoleMessage } from '../core';

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
    firstName: u.firstName ?? u.name.split(' ')[0] ?? null,
    middleName: u.middleName ?? null,
    lastName: u.lastName ?? (u.firstName ? null : u.name.split(' ').slice(1).join(' ') || null),
    dob: u.dob ?? null,
    gender: u.gender ?? null,
    address: u.address ?? null,
    state: u.state ?? null,
    city: u.city ?? null,
    country: u.country ?? null,
    pincode: u.pincode ?? null,
    addedByGym: u.createdByGym?.gymName ?? null,
    needsPassword: !!u.mustSetPassword,
    needsDetails: !!u.detailsNeeded,
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
/** The gym made this account: don't sign up again, set a password from the email link. */
function addedByGym(u: UserDoc) {
  // The gym's name and the email are not shown: anyone could type someone's mobile number here.
  const asStaff = u.appRole === 'STAFF';
  return new HttpError(409, `An account with these details already exists. Your gym has made you ${asStaff ? 'gym staff' : 'a member'}. Don't make a new account — just set your password and log in`, { code: 'ADDED_BY_GYM', gymName: 'Your gym', asStaff });
}

/** A second login address for the same inbox: name@gmail.com → name+gm4821@gmail.com. */
export function aliasEmail(email: string) {
  const [local, domain] = email.split('@');
  return `${local.split('+')[0]}+gm${Math.floor(1000 + Math.random() * 9000)}@${domain}`;
}

export async function createPasswordUser(c: C, input: { name: string; email: string | null; phone: string; password: string; appRole?: AppRole | null; details?: Partial<UserDoc> }) {
  const { store, identity, superAdminEmail } = c.var.deps;
  // The email and the mobile number must be free. Records of removed accounts do not count.
  if (input.email) {
    const taken = (await store.query<UserDoc>('users', [['email', input.email]])).find((r) => !r.data.deleted);
    if (taken) throw taken.data.createdByGym ? addedByGym(taken.data) : conflict(EMAIL_TAKEN);
  }
  const phoneRef = await store.get<{ uid: string }>(P.phone(input.phone));
  const phoneOwner = phoneRef ? await store.get<UserDoc>(P.user(phoneRef.uid)) : null;
  if (phoneOwner && !phoneOwner.deleted) throw phoneOwner.createdByGym ? addedByGym(phoneOwner) : conflict(PHONE_TAKEN);
  let authEmail = input.email ?? phoneAuthEmail(input.phone);
  let fb: { uid: string; idToken?: string };
  let fresh = true;
  try {
    fb = await identity.signUp(authEmail, input.password);
  } catch (e) {
    if (!(e instanceof HttpError && e.message === 'EMAIL_EXISTS')) throw e;
    const owner = (await store.query<UserDoc>('users', [['authEmail', authEmail]])).find((r) => !r.data.deleted);
    if (owner) throw conflict(input.email ? EMAIL_TAKEN : PHONE_TAKEN);
    // An old login with no live GymMantra account: a deleted account, or a sign-up that did not finish.
    // Same password: use it again. Otherwise make a fresh login (email "name+gm1234@…" still reaches
    // the same inbox for password resets), so the person is never told the email is already taken.
    try {
      fb = await identity.signIn(authEmail, input.password);
      fresh = false;
    } catch {
      authEmail = aliasEmail(authEmail);
      fb = await identity.signUp(authEmail, input.password);
    }
  }
  const uid = fb.uid;
  const user = newUser(input.name, { ...(input.details ?? {}), email: input.email, authEmail, fbUid: uid, phone: input.phone, appRole: input.appRole ?? null }, !!input.email && input.email === superAdminEmail);
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

const APP_ROLES = ['MEMBER', 'OWNER', 'TRAINER', 'STAFF'] as const;
const STAFF_NO_SIGNUP = 'Gym staff accounts are made by the gym owner. Ask your gym owner to add you (More → Staff → Add staff), then log in here';
/** The role picked on the app's first screen (mobile app only). */
function chosenRole(c: C, b: Record<string, unknown>): AppRole | null {
  if (!isMobile(c) || isAdminApp(c)) return null;
  return oneOf(b as never, 'role', APP_ROLES, true) ?? null;
}
/**
 * A login must match the account's role: a member's account cannot open the owner or trainer side.
 * An account that has no role yet takes the one chosen now.
 */
async function enforceRole(c: C, uid: string, user: UserDoc, chose: AppRole | null): Promise<UserDoc> {
  if (!chose || user.isSuperAdmin) return user;
  const have = accountRole(user);
  if (have && have !== chose) throw forbidden(wrongRoleMessage(have));
  if (have) return user;
  return c.var.deps.store.tx(async (t) => {
    const u = (await t.get<UserDoc>(P.user(uid)))!;
    const next = { ...u, appRole: chose };
    t.set(P.user(uid), next);
    return next;
  });
}

/**
 * The account for this Google sign-in: one made with Google, one already linked, or — when Google says
 * the email is verified — the account with the same email (for example a member the gym owner added).
 * That account gets linked to Google, so both Google and email+password work from then on.
 */
async function findGoogleUser(c: C, g: { sub: string; email: string | null }): Promise<{ uid: string; user: UserDoc } | null> {
  const { store } = c.var.deps;
  const own = await store.get<UserDoc>(P.user(`g_${g.sub}`));
  if (own && !own.deleted) return { uid: `g_${g.sub}`, user: own };
  const link = await store.get<{ uid: string }>(`googleSubs/${g.sub}`);
  if (link) {
    const u = await store.get<UserDoc>(P.user(link.uid));
    if (u && !u.deleted) return { uid: link.uid, user: u };
  }
  if (!g.email) return null;
  const row = (await store.query<UserDoc>('users', [['email', g.email]])).find((r) => !r.data.deleted);
  if (!row) return null;
  // Emails typed at sign-up or in Profile are not checked, so Google is linked only to an account
  // without a password of its own (Google-made, or made by a gym and waiting for its first password).
  // Otherwise someone could sign up with another person's email and wait for them to use Google.
  if (row.data.authEmail && !row.data.mustSetPassword) throw conflict('An account with this email already exists. Log in with your email or mobile number and password');
  const user = await store.tx(async (t) => {
    const u = (await t.get<UserDoc>(P.user(row.id)))!;
    const n = { ...u, googleSub: u.googleSub ?? g.sub };
    t.set(P.user(row.id), n);
    t.set(`googleSubs/${g.sub}`, { uid: row.id });
    return n;
  });
  return { uid: row.id, user };
}

export function authRoutes(app: App) {
  app.get('/api/v1/auth/config', async (c) => {
    const s = await c.var.deps.store.get<{ appUrl?: string | null }>(P.platform).catch(() => null);
    return c.json({ googleClientId: c.var.deps.googleClientId, maxLoginAttempts: MAX_LOGIN_ATTEMPTS, lockMinutes: LOCK_MINUTES, appUrl: s?.appUrl ?? null });
  });

  app.post('/api/v1/auth/signup', async (c) => {
    const b = body(await c.req.json().catch(() => null));
    await rateLimit(c, 'signup', typeof b.email === 'string' ? b.email : null);
    const d = hasDetails(b) ? personDetails(b) : null;
    const name = d ? d.name : str(b, 'name', { min: 2, max: 80, label: 'your name' });
    const email = normalizeEmail(str(b, 'email', { label: 'your email' }));
    if (!email) throw bad('Enter a valid email address');
    const phone = normalizePhone(str(b, 'phone', { label: 'your mobile number' }));
    if (!phone) throw bad('Enter a valid 10-digit mobile number');
    const password = str(b, 'password', { min: 8, max: 100, label: 'password' });
    if (chosenRole(c, b) === 'STAFF') {
      // Staff never sign up themselves. If the owner already made their account, send them to set a password.
      const { store } = c.var.deps;
      const byEmail = (await store.query<UserDoc>('users', [['email', email]])).find((r) => !r.data.deleted)?.data;
      const ref = await store.get<{ uid: string }>(P.phone(phone));
      const byPhone = ref ? await store.get<UserDoc>(P.user(ref.uid)) : null;
      const made = [byEmail, byPhone].find((x) => x && !x.deleted && x.createdByGym);
      if (made) throw addedByGym(made);
      throw bad(STAFF_NO_SIGNUP);
    }
    const { uid, user } = await createPasswordUser(c, { name, email, phone, password, appRole: chosenRole(c, b), details: d ? { firstName: d.firstName, middleName: d.middleName, lastName: d.lastName, dob: d.dob, gender: d.gender, state: d.state, city: d.city, country: d.country, pincode: d.pincode } : undefined });
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
    await rateLimit(c, 'login', email ?? phone ?? identifier);

    // Find the GymMantra account first, so the lockout applies before Firebase is asked.
    let uid: string | null = null;
    if (phone) uid = (await store.get<{ uid: string }>(P.phone(phone)))?.uid ?? null;
    else if (email) {
      uid = (await store.query<UserDoc>('users', [['authEmail', email]]))[0]?.id ?? null;
      // Someone who changed their email in Profile still signs in to Firebase with the old one.
      if (!uid) uid = (await store.query<UserDoc>('users', [['email', email]])).find((r) => !r.data.deleted && r.data.authEmail)?.id ?? null;
    }
    const user = uid ? await store.get<UserDoc>(P.user(uid)) : null;
    if (!uid && email && (await store.query<UserDoc>('users', [['email', email]])).some((r) => !r.data.authEmail && !r.data.deleted)) {
      throw bad('This account was created with Google. Use "Continue with Google" to log in');
    }
    // Wrong tries are counted per account and per phone network (IP), in memory/cache, not in the
    // database: someone else cannot lock your account from their phone, and an unknown email/mobile
    // gets exactly the same answers as a real one (nobody can test who has an account).
    const who = uid && user && !user.deleted ? `${uid}:${user.sessionV ?? 0}` : `x:${email ?? phone ?? identifier}`;
    const ip = ipOf(c) ?? '';
    const lockKey = `lock:${who}:${ip}`;
    const failKey = `fail:${who}:${ip}`;
    const lock = await readCounter(lockKey, LOCK_MINUTES * 60_000);
    if (lock) throw tooMany(new Date(lock.start + LOCK_MINUTES * 60_000).toISOString());
    if (user && !user.deleted && user.lockedUntil && new Date(user.lockedUntil) > new Date()) throw tooMany(user.lockedUntil);
    const wrong = async () => {
      const f = await bumpCounter(failKey, LOCK_MINUTES * 60_000);
      if (f.n >= MAX_LOGIN_ATTEMPTS) {
        await clearCounter(failKey);
        await bumpCounter(lockKey, LOCK_MINUTES * 60_000);
        return tooMany(new Date(Date.now() + LOCK_MINUTES * 60_000).toISOString());
      }
      const left = MAX_LOGIN_ATTEMPTS - f.n;
      return unauthorized(`Wrong email/mobile or password. ${left} attempt${left === 1 ? '' : 's'} left`);
    };
    if (!uid || !user || user.deleted) throw await wrong();
    if (!user.authEmail) throw bad('This account was created with Google. Use "Continue with Google" to log in');

    try {
      await identity.signIn(user.authEmail, password);
    } catch (e) {
      if (!(e instanceof HttpError) || e.message !== 'WRONG_PASSWORD') throw e;
      throw await wrong();
    }
    await clearCounter(failKey);
    // Only write when something changes (saves two database round trips on a normal log-in).
    const needsWrite = (user.failed ?? 0) > 0 || !!user.lockedUntil || (!user.isSuperAdmin && !!user.authEmail && user.authEmail === c.var.deps.superAdminEmail);
    const fresh = !needsWrite
      ? user
      : await store.tx(async (t) => {
          const u = (await t.get<UserDoc>(P.user(uid!)))!;
          const promote = !u.isSuperAdmin && !!u.authEmail && u.authEmail === c.var.deps.superAdminEmail; // the login email, not the editable profile email
          const next = { ...u, failed: 0, lockedUntil: null, isSuperAdmin: u.isSuperAdmin || promote };
          t.set(P.user(uid!), next);
          return next;
        });
    if (isMobile(c) && isWebOnly(fresh)) throw forbidden(WEB_ONLY_MESSAGE);
    if (isAdminApp(c) && !fresh.isSuperAdmin) throw forbidden(ADMIN_ONLY_MESSAGE);
    const checked = await enforceRole(c, uid, fresh, chosenRole(c, b));
    const token = await issueSession(c, uid);
    return c.json({ token, user: publicUser(uid, checked) });
  });

  /** Google sign-up creates the account. */
  app.post('/api/v1/auth/google/signup', async (c) => {
    const { store, identity, superAdminEmail } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    await rateLimit(c, 'google', null);
    const g = await identity.verifyGoogle(str(b, 'idToken', { max: 8000, label: 'the Google sign-in token' }));
    const uid = `g_${g.sub}`;
    // Already has an account (Google, or same verified email): just log in.
    const have = await findGoogleUser(c, g);
    if (have) {
      if (isMobile(c) && isWebOnly(have.user)) throw forbidden(WEB_ONLY_MESSAGE);
      const checked = await enforceRole(c, have.uid, have.user, chosenRole(c, b));
      const token = await issueSession(c, have.uid);
      return c.json({ token, user: publicUser(have.uid, checked), existing: true });
    }
    if (chosenRole(c, b) === 'STAFF') throw bad(STAFF_NO_SIGNUP);
    const phoneIn = optStr(b, 'phone');
    const phone = phoneIn ? normalizePhone(phoneIn) : null;
    if (phoneIn && !phone) throw bad('Enter a valid 10-digit mobile number');
    const user = newUser(
      g.name || (g.email ? g.email.split('@')[0] : 'GymMantra user'),
      { email: g.email, phone, googleSub: g.sub, appRole: chosenRole(c, b), detailsNeeded: true },
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
    await rateLimit(c, 'google', null);
    const { store, identity } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    const g = await identity.verifyGoogle(str(b, 'idToken', { max: 8000, label: 'the Google sign-in token' }));
    const found = await findGoogleUser(c, g);
    if (!found) throw notFound('No GymMantra account for this Google account. Please sign up with Google first');
    const { uid, user } = found;
    if (user.lockedUntil && new Date(user.lockedUntil) > new Date()) throw tooMany(user.lockedUntil);
    if (isMobile(c) && isWebOnly(user)) throw forbidden(WEB_ONLY_MESSAGE);
    if (isAdminApp(c) && !user.isSuperAdmin) throw forbidden(ADMIN_ONLY_MESSAGE);
    const checked = await enforceRole(c, uid, user, chosenRole(c, b));
    const token = await issueSession(c, uid);
    return c.json({ token, user: publicUser(uid, checked) });
  });

  /** Gym-made account, first login: the member chooses their own password once. */
  app.post('/api/v1/auth/set-password', async (c) => {
    const u = await authenticate(c);
    await rateLimit(c, 'password', u.id);
    const b = body(await c.req.json().catch(() => null));
    const next = str(b, 'next', { min: 8, max: 100, label: 'new password' });
    const { store, identity } = c.var.deps;
    const cur = (await store.get<UserDoc>(P.user(u.id)))!;
    if (!cur.mustSetPassword) throw bad('Your password is already set. Use Change password');
    if (cur.authEmail && cur.initPw) await identity.changePassword(cur.authEmail, cur.initPw, next);
    else {
      const authEmail = cur.email ?? (cur.phone ? phoneAuthEmail(cur.phone) : null);
      if (!authEmail) throw bad('Add an email first');
      await identity.changePassword(authEmail, null, next);
      cur.authEmail = authEmail;
    }
    const after = await store.tx(async (t) => {
      const x = (await t.get<UserDoc>(P.user(u.id)))!;
      const n: UserDoc = { ...x, authEmail: cur.authEmail, mustSetPassword: false, initPw: null, sessionV: (x.sessionV ?? 0) + 1 };
      t.set(P.user(u.id), n);
      return n;
    });
    return c.json({ ok: true, user: publicUser(u.id, after), token: await issueSession(c, u.id, after.sessionV) });
  });

  /** Forgot password: Firebase emails a reset link to the account's email. */
  app.post('/api/v1/auth/forgot', async (c) => {
    const { store, identity } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    const identifier = str(b, 'identifier', { label: 'your email or mobile number' });
    const email = normalizeEmail(identifier);
    const phone = email ? null : normalizePhone(identifier);
    if (!email && !phone) throw bad('Enter a valid email or 10-digit mobile number');
    await rateLimit(c, 'forgot', email ?? phone);
    // Same answer whether or not an account exists, so nobody can test who has an account.
    const answer = { sent: true, to: email ?? 'the email on this account' };
    let user: UserDoc | null = null;
    if (phone) {
      const uid = (await store.get<{ uid: string }>(P.phone(phone)))?.uid;
      user = uid ? await store.get<UserDoc>(P.user(uid)) : null;
    } else {
      user = (await store.query<UserDoc>('users', [['email', email!]]))[0]?.data ?? null;
    }
    const to = user && !user.deleted ? user.authEmail : email; // a login from a sign-up that did not finish: let them reset it
    if (to && !to.endsWith('@phone.gymmantra.app')) await identity.sendPasswordReset(to).catch(() => {});
    return c.json(answer);
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
    await rateLimit(c, 'reset', code.slice(0, 40));
    const email = await identity.resetPassword(code, password);
    // A fresh password also clears any lockout.
    // A reset also logs out every phone that was logged in with the old password.
    const row = (await store.query<UserDoc>('users', [['authEmail', email]]))[0];
    if (row) {
      await store.tx(async (t) => {
        const u = await t.get<UserDoc>(P.user(row.id));
        if (u) t.set(P.user(row.id), { ...u, failed: 0, lockedUntil: null, mustSetPassword: false, initPw: null, sessionV: (u.sessionV ?? 0) + 1 });
      });
    }
    return c.json({ ok: true });
  });

  app.get('/api/v1/auth/me', async (c) => {
    const u = await authenticate(c);
    // "Last used" for Logged-in devices (at most once an hour).
    if (c.var.sid) {
      const { store } = c.var.deps;
      const s = await store.get<SessionDoc>(P.session(c.var.sid));
      if (s && Date.now() - Date.parse(s.lastSeenAt) > 3600_000) await store.set(P.session(c.var.sid), { ...s, lastSeenAt: nowIso() }).catch(() => {});
    }
    return c.json(await meResponse(c, u));
  });

  app.post('/api/v1/auth/change-password', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    await rateLimit(c, 'password', u.id);
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
    // Every other phone / browser is logged out; this one gets a fresh login.
    const v = await bumpSession(store, u.id);
    return c.json({ ok: true, token: await issueSession(c, u.id, v) });
  });
}

/** Logs the account out everywhere (password changed). Returns the new session version. */
async function bumpSession(store: C['var']['deps']['store'], uid: string) {
  return store.tx(async (t) => {
    const cur = (await t.get<UserDoc>(P.user(uid)))!;
    const v = (cur.sessionV ?? 0) + 1;
    t.set(P.user(uid), { ...cur, sessionV: v });
    return v;
  });
}

export async function meResponse(c: C, u: AuthUser) {
  const ids = Object.entries(u.staffOf ?? {}).filter(([, s]) => s.active);
  const tenants = await c.var.deps.store.getMany<any>(ids.map(([t]) => P.tenant(t)));
  return {
    user: publicUser(u.id, u),
    gyms: ids
      .map(([id, s], i) => (tenants[i] ? { id, name: tenants[i].name, gymCode: tenants[i].gymCode, status: tenants[i].status, logoUrl: tenants[i].logoUrl, role: s.role, branchIds: s.branchIds, rights: s.role === 'OWNER' ? [...RIGHTS] : cleanRights(s.rights) } : null))
      .filter(Boolean),
  };
}

export { forbidden };
