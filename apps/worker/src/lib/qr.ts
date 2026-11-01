// Member QR codes change every 30 seconds so a screenshot cannot be reused.
// Token: gm1.<memberId>.<window>.<signature>  (memberId is "<tenantId>:<memberId>")

export const QR_WINDOW_SECONDS = 30;
const enc = new TextEncoder();

async function key(secret: string) {
  return crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
}
function b64url(buf: ArrayBuffer) {
  let s = '';
  for (const b of new Uint8Array(buf)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
async function sign(secret: string, id: string, w: number) {
  return b64url(await crypto.subtle.sign('HMAC', await key(secret), enc.encode(`${id}.${w}`))).slice(0, 22);
}
export const currentWindow = (ms = Date.now()) => Math.floor(ms / 1000 / QR_WINDOW_SECONDS);

export async function makeQrToken(secret: string, id: string, ms = Date.now()) {
  const w = currentWindow(ms);
  return { token: `gm1.${id}.${w}.${await sign(secret, id, w)}`, expiresAt: new Date((w + 1) * QR_WINDOW_SECONDS * 1000).toISOString() };
}

/** Returns the id if valid. Accepts the previous window too, for clock skew. */
export async function verifyQrToken(secret: string, token: string, ms = Date.now()): Promise<string | null> {
  const parts = token.trim().split('.');
  if (parts.length !== 4 || parts[0] !== 'gm1') return null;
  const [, id, ws, sig] = parts;
  const w = Number(ws);
  const now = currentWindow(ms);
  if (!Number.isInteger(w) || w < now - 1 || w > now + 1) return null;
  const expected = await sign(secret, id, w);
  if (expected.length !== sig.length) return null;
  let diff = 0;
  for (let i = 0; i < sig.length; i++) diff |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  return diff === 0 ? id : null;
}
