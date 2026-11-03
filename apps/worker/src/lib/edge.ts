// Small values kept in Cloudflare's cache for the whole data centre, not just one Worker instance.
// A fresh Worker instance then skips the slow first steps (server sign-in to Firebase, reading the
// secrets), which made the first request on every new instance take 3–5 seconds.
// The keys are on a private made-up host, so nobody can fetch them from outside.

const HOST = 'https://edge-cache.gymmantra.internal/';

function cacheApi(): Cache | null {
  try {
    return typeof caches !== 'undefined' ? (caches as unknown as { default: Cache }).default ?? null : null;
  } catch {
    return null;
  }
}

export async function edgeGet<T>(key: string): Promise<T | null> {
  const c = cacheApi();
  if (!c) return null;
  try {
    const r = await c.match(new Request(HOST + encodeURIComponent(key)));
    return r ? ((await r.json()) as T) : null;
  } catch {
    return null;
  }
}

export async function edgePut(key: string, value: unknown, ttlSeconds: number) {
  const c = cacheApi();
  if (!c) return;
  try {
    await c.put(new Request(HOST + encodeURIComponent(key)), new Response(JSON.stringify(value), { headers: { 'content-type': 'application/json', 'cache-control': `max-age=${Math.max(1, Math.floor(ttlSeconds))}` } }));
  } catch {
    /* cache is only a speed-up */
  }
}
