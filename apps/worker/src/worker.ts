import { createApp } from './app';
import type { Deps } from './core';
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

function depsFor(env: WorkerEnv, url: URL): Deps {
  if (deps) return deps;
  for (const k of ['FIREBASE_API_KEY', 'FIREBASE_PROJECT_ID', 'SERVER_PASSWORD'] as const) {
    if (!env[k]) throw new Error(`Missing setting ${k}. Add it in Cloudflare → Worker → Settings → Variables`);
  }
  const googleIds = (env.GOOGLE_CLIENT_IDS ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  const identity = new FirebaseIdentity(env.FIREBASE_API_KEY, googleIds);
  const store = new FirestoreStore(env.FIREBASE_PROJECT_ID, serverToken(identity, env.SERVER_EMAIL || 'server@gymmantra.internal', env.SERVER_PASSWORD));
  deps = {
    store,
    identity,
    superAdminEmail: (env.SUPER_ADMIN_EMAIL ?? '').trim().toLowerCase(),
    googleClientId: googleIds[0] ?? null,
    secure: url.protocol === 'https:',
    assetJson: async (path) => {
      const r = await env.ASSETS.fetch(new URL(path, url.origin).toString());
      return r.ok ? r.json() : null;
    },
  };
  return deps;
}

export default {
  async fetch(req: Request, env: WorkerEnv): Promise<Response> {
    const url = new URL(req.url);
    let res: Response;
    if (url.pathname.startsWith('/api/')) {
      const app = createApp(() => depsFor(env, url));
      res = await app.fetch(req, env);
    } else {
      res = await env.ASSETS.fetch(req);
    }
    const out = new Response(res.body, res);
    for (const [k, v] of Object.entries(SECURITY_HEADERS)) out.headers.set(k, v);
    return out;
  },
};
