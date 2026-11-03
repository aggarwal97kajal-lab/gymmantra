import type { C } from '../core';
import { HttpError } from './http';

export const RATE_LIMIT = 5; // attempts
export const RATE_WINDOW_MS = 60_000; // per minute

/** Short stable id for a key (Firestore document ids cannot hold "/"). */
async function keyId(s: string) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  return Array.from(d.slice(0, 12), (x) => x.toString(16).padStart(2, '0')).join('');
}

/**
 * Login, sign-up and password reset: at most 5 tries a minute for the same email/mobile,
 * and for the same phone network address (IP). The 6th gets 429 "Too many requests".
 */
export async function rateLimit(c: C, action: string, identifier: string | null | undefined) {
  const ip = c.req.header('cf-connecting-ip') ?? c.req.header('x-real-ip') ?? null;
  const keys = [identifier ? `${action}:id:${identifier.trim().toLowerCase()}` : null, ip ? `${action}:ip:${ip}` : null].filter(Boolean) as string[];
  if (!keys.length) return;
  const { store } = c.var.deps;
  const now = Date.now();
  const paths = await Promise.all(keys.map(async (k) => `rateLimits/${await keyId(k)}`));
  const waitMs = await store.tx(async (t) => {
    const docs = await t.getMany<{ start: number; n: number }>(paths);
    let wait = 0;
    const next = docs.map((d) => (!d || now - d.start >= RATE_WINDOW_MS ? { start: now, n: 1 } : { start: d.start, n: d.n + 1 }));
    next.forEach((d) => {
      if (d.n > RATE_LIMIT) wait = Math.max(wait, d.start + RATE_WINDOW_MS - now);
    });
    paths.forEach((p, i) => t.set(p, next[i]));
    return wait;
  });
  if (waitMs > 0) {
    const s = Math.max(1, Math.ceil(waitMs / 1000));
    throw new HttpError(429, `Too many requests. Please try again in ${s} seconds`, { retryAfterSeconds: s });
  }
}
