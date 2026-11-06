import { cronScheduled } from './lib/scheduled';
import { cronAttendanceReminders } from './lib/attendrem';
import { googleAccessToken, parseServiceAccount } from './lib/gauth';
import { cronFanouts } from './lib/push';
import { cronReminders } from './lib/superpush';
import { setEdgeKv } from './lib/edge';
import { createRemoteJWKSet, jwtVerify } from 'jose';
import { createApp } from './app';
import { D1Like, D1Store } from './store/d1';
import { loadSecrets, type Deps } from './core';
import { ensureBaseData } from './routes/super';
import { FirebaseIdentity, serverToken } from './identity';
import { FirestoreStore } from './store/firestore';

export interface WorkerEnv {
  ASSETS: { fetch: (req: Request | string) => Promise<Response> };
  FIREBASE_API_KEY: string;
  FIREBASE_PROJECT_ID: string;
  SERVER_EMAIL?: string;
  SERVER_PASSWORD: string;
  SUPER_ADMIN_EMAIL?: string;
  GOOGLE_CLIENT_IDS?: string;
  GM_KV?: unknown; // Cloudflare KV: shares the database sign-in between Worker instances
  FIREBASE_SERVICE_ACCOUNT?: string; // secret: service account JSON, for phone notifications
  GM_DB?: D1Like; // Cloudflare D1: the database (when DB_BACKEND is "d1")
  DB_BACKEND?: string; // "d1" = data in D1; anything else = Firestore
}

const SECURITY_HEADERS: Record<string, string> = {
  'content-security-policy':
    "default-src 'self'; script-src 'self' 'unsafe-inline' https://accounts.google.com/gsi/client; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://accounts.google.com/gsi/style; font-src 'self' https://fonts.gstatic.com data:; img-src 'self' data: blob: https:; connect-src 'self' https://accounts.google.com/gsi/; frame-src https://accounts.google.com/gsi/; media-src 'self' blob:; worker-src 'self' blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'self'",
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'strict-origin-when-cross-origin',
  'permissions-policy': 'camera=(self), microphone=(), geolocation=()',
  'strict-transport-security': 'max-age=31536000',
};

let deps: Deps | null = null;

// Nightly backup (routes/backup.ts): only these GitHub workflows, on main, may call it.
const BACKUP_REPO = 'aggarwal97kajal-lab/gymmantra';
const GITHUB_JWKS = createRemoteJWKSet(new URL('https://token.actions.githubusercontent.com/.well-known/jwks'));

function backupDeps(serverPassword: string): NonNullable<Deps['backup']> {
  let key: Promise<CryptoKey> | null = null;
  return {
    async verify(token, workflow) {
      const { payload } = await jwtVerify(token, GITHUB_JWKS, { issuer: 'https://token.actions.githubusercontent.com', audience: 'gymmantra-backup' });
      return payload.repository === BACKUP_REPO && payload.ref === 'refs/heads/main' && payload.workflow_ref === `${BACKUP_REPO}/.github/workflows/${workflow}.yml@refs/heads/main`;
    },
    key() {
      // The key comes from the server password (a Cloudflare secret), so it is not stored in the
      // database that is being backed up. Changing SERVER_PASSWORD means old backups cannot be opened.
      key ??= (async () => {
        const base = await crypto.subtle.importKey('raw', new TextEncoder().encode(serverPassword), 'HKDF', false, ['deriveKey']);
        return crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: new TextEncoder().encode('gymmantra-backup'), info: new TextEncoder().encode('v1') }, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
      })();
      return key;
    },
  };
}

function depsFor(env: WorkerEnv, url: URL): Deps {
  if (deps) return deps;
  setEdgeKv(env.GM_KV ?? null);
  for (const k of ['FIREBASE_API_KEY', 'FIREBASE_PROJECT_ID', 'SERVER_PASSWORD'] as const) {
    if (!env[k]) throw new Error(`Missing setting ${k}. Add it in Cloudflare → Worker → Settings → Variables`);
  }
  const googleIds = (env.GOOGLE_CLIENT_IDS ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  const identity = new FirebaseIdentity(env.FIREBASE_API_KEY, googleIds);
  const firestore = new FirestoreStore(env.FIREBASE_PROJECT_ID, serverToken(identity, env.SERVER_EMAIL || 'server@gymmantra.internal', env.SERVER_PASSWORD));
  const d1 = env.GM_DB ? new D1Store(env.GM_DB) : null;
  const store = d1 && env.DB_BACKEND === 'd1' ? d1 : firestore;
  deps = {
    store,
    migrate: d1 ? { from: firestore, to: d1 } : null,
    identity,
    superAdminEmail: (env.SUPER_ADMIN_EMAIL ?? '').trim().toLowerCase(),
    googleClientId: googleIds[0] ?? null,
    serviceAccount: parseServiceAccount(env.FIREBASE_SERVICE_ACCOUNT),
    backup: backupDeps(env.SERVER_PASSWORD),
    secure: url.protocol === 'https:',
    assetJson: async (path) => {
      const r = await env.ASSETS.fetch(new URL(path, url.origin).toString());
      return r.ok ? r.json() : null;
    },
  };
  return deps;
}

/**
 * Setup check for the owner: says which setup step is missing, without showing
 * any secret. Open /api/setup-check in a browser.
 */
async function setupCheck(env: WorkerEnv): Promise<Response> {
  const steps: { step: string; ok: boolean; fix?: string }[] = [];
  const add = (step: string, ok: boolean, fix?: string) => steps.push({ step, ok, ...(ok ? {} : { fix }) });
  add('FIREBASE_PROJECT_ID is set', !!env.FIREBASE_PROJECT_ID, 'Cloudflare → gymmantra → Settings → Runtime variables: add FIREBASE_PROJECT_ID');
  add('FIREBASE_API_KEY is set', !!env.FIREBASE_API_KEY, 'Cloudflare → Settings → Runtime variables: add FIREBASE_API_KEY');
  add('SERVER_PASSWORD is set', !!env.SERVER_PASSWORD, 'Cloudflare → Settings → Runtime variables: add SERVER_PASSWORD (type Secret)');
  add('SUPER_ADMIN_EMAIL is set', !!env.SUPER_ADMIN_EMAIL, 'Cloudflare → Settings → Runtime variables: add SUPER_ADMIN_EMAIL');
  if (env.FIREBASE_API_KEY && env.SERVER_PASSWORD) {
    const r = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${env.FIREBASE_API_KEY}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email: env.SERVER_EMAIL || 'server@gymmantra.internal', password: env.SERVER_PASSWORD, returnSecureToken: true }),
    });
    const d: any = await r.json().catch(() => ({}));
    const code = String(d?.error?.message ?? '');
    const fix = code.includes('API_KEY') || code.includes('API key')
      ? 'FIREBASE_API_KEY is wrong. Copy apiKey again from Firebase → Project settings → Your apps'
      : code.includes('OPERATION_NOT_ALLOWED')
        ? 'Firebase → Authentication → Sign-in method: enable Email/Password'
        : code.includes('INVALID') || code.includes('EMAIL_NOT_FOUND') || code.includes('PASSWORD')
          ? 'Firebase → Authentication → Users: user server@gymmantra.internal must exist and SERVER_PASSWORD must be exactly its password'
          : `Firebase login error: ${code || r.status}`;
    add('Server account can log in to Firebase', r.ok, fix);
    if (r.ok && env.FIREBASE_PROJECT_ID) {
      const f = await fetch(`https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/settings/platform`, { headers: { authorization: `Bearer ${d.idToken}` } });
      const fd: any = await f.json().catch(() => ({}));
      const msg = String(fd?.error?.message ?? '');
      // A missing document is fine (the database exists); a missing database is not.
      const missingDoc = f.status === 404 && /^Document /i.test(msg);
      // Try each kind of database call the server uses, one by one.
      const base = `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents`;
      const auth = { authorization: `Bearer ${d.idToken}`, 'content-type': 'application/json' };
      const name = `projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/settings/check`;
      const probe = async (label: string, url: string, body: unknown) => {
        const r = await fetch(url, { method: 'POST', headers: auth, body: JSON.stringify(body) });
        const j: any = await r.json().catch(() => ({}));
        add(`Database ${label}`, r.ok, `${r.status} ${j?.error?.status ?? ''} ${String(j?.error?.message ?? '').slice(0, 200)}`);
        return j;
      };
      await probe('write', `${base}:commit`, { writes: [{ update: { name, fields: { at: { stringValue: new Date().toISOString() } } } }] });
      await probe('batch read', `${base}:batchGet`, { documents: [name] });
      await probe('safe update', `${base}:commit`, { writes: [{ update: { name, fields: { at: { stringValue: 'ok' } } }, currentDocument: { exists: true } }] });
      const st = missingDoc ? '' : String(fd?.error?.status ?? '');
      const ffix = st === 'PERMISSION_DENIED'
        ? 'Firestore → Rules: paste the GymMantra rules and press Publish (or FIREBASE_PROJECT_ID belongs to another project)'
        : st === 'NOT_FOUND' || f.status === 404
          ? 'Firestore database not created yet, or FIREBASE_PROJECT_ID is wrong. Copy projectId exactly from Firebase'
          : `Firestore error: ${st || f.status} ${fd?.error?.message ?? ''}`;
      add('Database (Firestore) is reachable', f.ok || missingDoc, `${ffix} [${f.status} ${msg.slice(0, 160)}]`);
    }
  }
  if (steps.every((x) => x.ok)) {
    // Run the same first steps every API request runs, and report the real error if any.
    try {
      const d = depsFor(env, new URL('https://check.local/'));
      await loadSecrets(d.store);
      await ensureBaseData(d.store);
      add('Server can save data in the database', true);
    } catch (e: any) {
      add('Server can save data in the database', false, `${e?.name ?? 'Error'}: ${String(e?.message ?? e).slice(0, 400)}`);
    }
  }
  const allOk = steps.every((s) => s.ok);
  // Phone notifications (optional): is the service account key there, and does Google accept it?
  let push: { step: string; ok: boolean; fix?: string };
  const sa = parseServiceAccount(env.FIREBASE_SERVICE_ACCOUNT);
  if (!env.FIREBASE_SERVICE_ACCOUNT) push = { step: 'Phone notifications key (FIREBASE_SERVICE_ACCOUNT)', ok: false, fix: 'Not added yet. Cloudflare → gymmantra → Settings → Variables and Secrets → Add → Secret FIREBASE_SERVICE_ACCOUNT = the whole service account file text' };
  else if (!sa) push = { step: 'Phone notifications key (FIREBASE_SERVICE_ACCOUNT)', ok: false, fix: 'Added, but the text is not a complete service account file. Copy the whole file again (from { to })' };
  else if (env.FIREBASE_PROJECT_ID && sa.project_id !== env.FIREBASE_PROJECT_ID) push = { step: 'Phone notifications key (FIREBASE_SERVICE_ACCOUNT)', ok: false, fix: `Key is for project ${sa.project_id}, but FIREBASE_PROJECT_ID is ${env.FIREBASE_PROJECT_ID}` };
  else {
    try {
      await googleAccessToken(sa);
      push = { step: 'Phone notifications key (FIREBASE_SERVICE_ACCOUNT)', ok: true };
    } catch (e) {
      push = { step: 'Phone notifications key (FIREBASE_SERVICE_ACCOUNT)', ok: false, fix: `Google did not accept the key: ${String((e as Error)?.message ?? e).slice(0, 160)}. Make a new key and paste it again` };
    }
  }
  // Public page: only which steps pass. The error texts (they can describe the server's setup) go to the private log.
  for (const s of [...steps, push]) if (!s.ok) console.error(`setup-check: ${s.step}: ${s.fix ?? ''}`);
  const out = { allOk, steps: steps.map((s) => ({ step: s.step, ok: s.ok })), push: { step: push.step, ok: push.ok } };
  return new Response(JSON.stringify(out, null, 2), { headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' } });
}

let appInst: ReturnType<typeof createApp> | null = null;

export default {
  /** Every minute: send the rest of large notification jobs (lib/push.ts). */
  async scheduled(_ev: unknown, env: WorkerEnv, ctx: ExecutionContext) {
    try {
      const d = depsFor(env, new URL('https://cron.gymmantra.internal/'));
      ctx.waitUntil(cronFanouts(d.store, d.serviceAccount ?? null).catch(() => {}));
      ctx.waitUntil(cronReminders(d, d.serviceAccount ?? null).catch(() => {}));
      ctx.waitUntil(cronAttendanceReminders(d, d.serviceAccount ?? null).catch(() => {}));
      ctx.waitUntil(cronScheduled(d, d.serviceAccount ?? null).catch(() => {}));
    } catch {
      /* settings missing: nothing to do */
    }
  },
  async fetch(req: Request, env: WorkerEnv, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === '/api/setup-check') return setupCheck(env);
    let res: Response;
    if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/iclock/')) {
      // Built once per Worker instance (building all routes on every request wasted CPU time).
      appInst ??= createApp(() => depsFor(env, url));
      res = await appInst.fetch(req, env, ctx); // ctx: the slow-request log is written after the answer is sent
    } else {
      res = await env.ASSETS.fetch(req);
    }
    const out = new Response(res.body, res);
    for (const [k, v] of Object.entries(SECURITY_HEADERS)) out.headers.set(k, v);
    return out;
  },
};
