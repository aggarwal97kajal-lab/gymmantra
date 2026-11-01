import { createHmac, timingSafeEqual } from 'crypto';

// Member QR codes change every 30 seconds so a screenshot cannot be reused.
// Token format: gm1.<memberId>.<window>.<signature>

export const QR_WINDOW_SECONDS = 30;

function sign(secret: string, memberId: string, window: number): string {
  return createHmac('sha256', secret).update(`${memberId}.${window}`).digest('base64url').slice(0, 22);
}

export function currentWindow(nowMs = Date.now()): number {
  return Math.floor(nowMs / 1000 / QR_WINDOW_SECONDS);
}

export function makeQrToken(secret: string, memberId: string, nowMs = Date.now()) {
  const w = currentWindow(nowMs);
  const expiresAt = new Date((w + 1) * QR_WINDOW_SECONDS * 1000);
  return { token: `gm1.${memberId}.${w}.${sign(secret, memberId, w)}`, expiresAt };
}

/** Returns the memberId if valid. Accepts the current and previous window for clock skew. */
export function verifyQrToken(secret: string, token: string, nowMs = Date.now()): string | null {
  const parts = token.trim().split('.');
  if (parts.length !== 4 || parts[0] !== 'gm1') return null;
  const [, memberId, ws, sig] = parts;
  const w = Number(ws);
  if (!Number.isInteger(w)) return null;
  const now = currentWindow(nowMs);
  if (w < now - 1 || w > now + 1) return null;
  const expected = Buffer.from(sign(secret, memberId, w));
  const got = Buffer.from(sig);
  if (expected.length !== got.length || !timingSafeEqual(expected, got)) return null;
  return memberId;
}
