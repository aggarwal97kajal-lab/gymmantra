import { App, authenticate, C, clearSession, issueSession, notify, P, revokeSid, SESSION_DAYS, SessionDoc, sha256, randomKey, signAccess, UserDoc, deviceOf } from '../core';
import { jwtVerify } from 'jose';
import { bad, notFound, nowIso, unauthorized } from '../lib/http';
import { rateLimit } from '../lib/ratelimit';
import { superLater } from '../lib/superpush';
import { body, str } from '../lib/validate';

/**
 * Logged-in devices (boards 96-98): the list of a person's logins, logging one out, logging out
 * everywhere else, "It was not me", and the app's quiet 1-day login renewal with a changing key.
 */
const GRACE_MS = 120_000; // the same old key again within 2 minutes = the phone lost the answer, not theft
const daysFromNow = (d: number) => new Date(Date.now() + d * 86400000).toISOString();

/** Ends every other session of this person and keeps (or makes) this one; returns the new login. */
async function logoutOthers(c: C, u: UserDoc & { id: string }) {
  const { store } = c.var.deps;
  const v = await store.tx(async (t) => {
    const cur = (await t.get<UserDoc>(P.user(u.id)))!;
    const next = (cur.sessionV ?? 0) + 1;
    t.set(P.user(u.id), { ...cur, sessionV: next });
    return next;
  });
  const mine = c.var.sid;
  const all = await store.query<SessionDoc>(P.sessions, [['uid', u.id]]);
  const others = all.filter((s) => s.id !== mine);
  if (others.length) await store.tx(async (t) => others.forEach((s) => t.delete(P.session(s.id))));
  return issueSession(c, u.id, v, { sid: mine && all.some((s) => s.id === mine) ? mine : undefined });
}

export function sessionRoutes(app: App) {
  /** The app's quiet renewal: a new 1-day login for a refresh key; the key changes every time. */
  app.post('/api/v1/auth/refresh', async (c) => {
    const b = body(await c.req.json().catch(() => null));
    const key = str(b, 'refresh', { max: 200, label: 'refresh' });
    const [sid, secret] = key.split('.');
    if (!sid || !secret) throw unauthorized('Please log in again');
    await rateLimit(c, 'refresh', sid, 60);
    const { store } = c.var.deps;
    const h = await sha256(secret);
    const next = randomKey();
    const nextHash = await sha256(next);
    const city = deviceOf(c).city;
    const out = await store.tx(async (t) => {
      const s = await t.get<SessionDoc>(P.session(sid));
      if (!s) return { fail: true as const };
      const u = await t.get<UserDoc>(P.user(s.uid));
      if (!u || u.deleted || (u.sessionV ?? 0) !== s.v || s.expiresAt < nowIso() || u.revokedSids?.some((r) => r.sid === sid)) {
        t.delete(P.session(sid));
        return { fail: true as const };
      }
      const lostAnswer = s.prevRt === h && !!s.rotatedAt && Date.now() - Date.parse(s.rotatedAt) < GRACE_MS;
      if (s.rt !== h && !lostAnswer) {
        // An older key used again: someone copied it. End this login and tell the person.
        if (s.prevRt === h) {
          revokeSid(t, u, s.uid, sid);
          await notify(t, s.uid, null, 'Suspicious login stopped', `A copied login for ${s.device} was used, so we logged that phone out. If it was yours, just log in again.`, null, 'security');
        }
        return { fail: true as const };
      }
      t.set(P.session(sid), { ...s, rt: nextHash, prevRt: h, rotatedAt: nowIso(), lastSeenAt: nowIso(), expiresAt: daysFromNow(SESSION_DAYS), city: city ?? s.city });
      return { uid: s.uid, v: s.v };
    });
    if ('fail' in out) throw unauthorized('Please log in again');
    c.header('x-gm-refresh', `${sid}.${next}`);
    return c.json({ token: await signAccess(c, out.uid, out.v, sid, true) });
  });

  /** Logs this phone / browser out on the server too (its login stops at once). */
  app.post('/api/v1/auth/logout', async (c) => {
    const h = c.req.header('authorization');
    const token = h?.startsWith('Bearer ') ? h.slice(7) : undefined;
    let sid: string | undefined;
    let uid: string | undefined;
    if (token) {
      try {
        const { payload } = await jwtVerify(token, new TextEncoder().encode(c.var.secrets.jwt));
        sid = typeof payload.sid === 'string' ? payload.sid : undefined;
        uid = String(payload.sub);
      } catch {
        /* expired: nothing to end */
      }
    } else {
      const u = await authenticate(c).catch(() => null);
      sid = c.var.sid;
      uid = u?.id;
    }
    // The 1-day login may have run out: the app also sends its refresh key.
    const key = await c.req.json().then((b: { refresh?: unknown }) => (typeof b?.refresh === 'string' ? b.refresh : null)).catch(() => null);
    if (!sid && key) {
      const [ks, secret] = key.split('.');
      const s = ks && secret ? await c.var.deps.store.get<SessionDoc>(P.session(ks)) : null;
      const h = secret ? await sha256(secret) : '';
      if (s && (s.rt === h || s.prevRt === h)) {
        sid = ks;
        uid = s.uid;
      }
    }
    if (sid && uid) {
      await c.var.deps.store.tx(async (t) => {
        const [u, s] = (await t.getMany<any>([P.user(uid!), P.session(sid!)])) as [UserDoc | null, SessionDoc | null];
        if (u && s?.uid === uid) revokeSid(t, u, uid!, sid!);
      });
    }
    clearSession(c);
    return c.json({ ok: true });
  });

  /** Where this account is logged in. */
  app.get('/api/v1/me/sessions', async (c) => {
    const u = await authenticate(c);
    const now = nowIso();
    const rows = (await c.var.deps.store.query<SessionDoc>(P.sessions, [['uid', u.id]]))
      .filter((s) => s.data.v === (u.sessionV ?? 0) && s.data.expiresAt > now && !u.revokedSids?.some((r) => r.sid === s.id))
      .map((s) => ({ id: s.id, device: s.data.device, app: s.data.app, city: s.data.city, createdAt: s.data.createdAt, lastSeenAt: s.data.lastSeenAt, current: s.id === c.var.sid }))
      .sort((a, b) => (a.current ? -1 : b.current ? 1 : a.lastSeenAt < b.lastSeenAt ? 1 : -1));
    return c.json(rows);
  });

  /** Log one phone / browser out. */
  app.delete('/api/v1/me/sessions/:sid', async (c) => {
    const u = await authenticate(c);
    const sid = c.req.param('sid');
    if (sid === c.var.sid) throw bad('This is the phone you are using. Use Log out instead');
    await c.var.deps.store.tx(async (t) => {
      const [cur, s] = (await t.getMany<any>([P.user(u.id), P.session(sid)])) as [UserDoc, SessionDoc | null];
      if (!s || s.uid !== u.id) throw notFound('Not found');
      revokeSid(t, cur, u.id, sid);
    });
    return c.json({ ok: true });
  });

  /** Log out everywhere except this phone (no password change needed). */
  app.post('/api/v1/me/sessions/logout-others', async (c) => {
    const u = await authenticate(c);
    const token = await logoutOthers(c, u);
    return c.json({ ok: true, token });
  });

  /** "It was not me": everywhere else logged out; the app then asks for a new password. */
  app.post('/api/v1/me/sessions/not-me', async (c) => {
    const u = await authenticate(c);
    const token = await logoutOthers(c, u);
    superLater(c, 'tickets', 'Account alert', `${u.name} said a login on their account was not them. All other logins were ended.`);
    return c.json({ ok: true, token });
  });
}
