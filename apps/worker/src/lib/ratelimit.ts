import type { C } from '../core';
import { HttpError } from './http';

export const RATE_LIMIT = 5; // attempts
export const RATE_WINDOW_MS = 60_000; // per minute

// Counters live in Worker memory and in Cloudflare's cache of the data centre, never in the
// database: a flood of bad requests then costs no Firestore writes (the free daily limit
// would run out and stop the whole app).
const HOST = 'https://ratelimit.gymmantra.internal/';
const mem = new Map<string, { start: number; n: number }>();
export function resetRateLimits() {
  mem.clear();
}

function cacheApi(): Cache | null {
  try {
    return typeof caches !== 'undefined' ? (caches as unknown as { default: Cache }).default ?? null : null;
  } catch {
    return null;
  }
}

async function keyId(s: string) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  return Array.from(d.slice(0, 12), (x) => x.toString(16).padStart(2, '0')).join('');
}

async function read(key: string, windowMs: number) {
  const now = Date.now();
  let cur = mem.get(key) ?? null;
  const c = cacheApi();
  if (c) {
    try {
      const r = await c.match(new Request(HOST + key));
      const v = r ? ((await r.json()) as { start: number; n: number }) : null;
      if (v && (!cur || v.n > cur.n)) cur = v;
    } catch {
      /* memory only */
    }
  }
  return cur && now - cur.start < windowMs ? cur : null;
}

async function write(key: string, v: { start: number; n: number } | null, windowMs: number) {
  if (mem.size > 20000) mem.clear();
  if (v) mem.set(key, v);
  else mem.delete(key);
  const c = cacheApi();
  if (!c) return;
  try {
    if (!v) await c.delete(new Request(HOST + key));
    else {
      const ttl = Math.max(1, Math.ceil((v.start + windowMs - Date.now()) / 1000));
      await c.put(new Request(HOST + key), new Response(JSON.stringify(v), { headers: { 'cache-control': `max-age=${ttl}` } }));
    }
  } catch {
    /* memory only */
  }
}

/** Adds one to a counter and returns it. */
export async function bumpCounter(name: string, windowMs: number) {
  const key = await keyId(name);
  const cur = await read(key, windowMs);
  const next = cur ? { start: cur.start, n: cur.n + 1 } : { start: Date.now(), n: 1 };
  await write(key, next, windowMs);
  return next;
}
export async function readCounter(name: string, windowMs: number) {
  return read(await keyId(name), windowMs);
}
export async function clearCounter(name: string) {
  await write(await keyId(name), null, 1);
}

export const ipOf = (c: C) => c.req.header('cf-connecting-ip') ?? c.req.header('x-real-ip') ?? null;

/**
 * Login, sign-up and password reset: at most 5 tries a minute for the same email/mobile,
 * and for the same phone network address (IP). The 6th gets 429 "Too many requests".
 */
export async function rateLimit(c: C, action: string, identifier: string | null | undefined, limit = RATE_LIMIT) {
  const keys = [identifier ? `${action}:id:${identifier.trim().toLowerCase()}` : null, ipOf(c) ? `${action}:ip:${ipOf(c)}` : null].filter(Boolean) as string[];
  let wait = 0;
  for (const k of keys) {
    const d = await bumpCounter(k, RATE_WINDOW_MS);
    if (d.n > limit) wait = Math.max(wait, d.start + RATE_WINDOW_MS - Date.now());
  }
  if (wait > 0) {
    const s = Math.max(1, Math.ceil(wait / 1000));
    throw new HttpError(429, `Too many requests. Please try again in ${s} seconds`, { retryAfterSeconds: s });
  }
}
