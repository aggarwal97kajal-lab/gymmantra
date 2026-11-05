/**
 * Google OAuth access token from a Firebase service account (FIREBASE_SERVICE_ACCOUNT secret),
 * signed here with WebCrypto (RS256). Used for phone notifications (FCM HTTP v1).
 */
export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

export function parseServiceAccount(raw: string | undefined | null): ServiceAccount | null {
  if (!raw) return null;
  try {
    const j = JSON.parse(raw.trim());
    if (typeof j.client_email === 'string' && typeof j.private_key === 'string' && typeof j.project_id === 'string') return j;
  } catch {
    /* not JSON */
  }
  return null;
}

const b64url = (b: ArrayBuffer | Uint8Array) => {
  const bytes = b instanceof Uint8Array ? b : new Uint8Array(b);
  let s = '';
  for (const x of bytes) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
const enc = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));

async function importKey(pem: string) {
  const body = pem.replace(/-----[^-]+-----/g, '').replace(/\\n/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
}

let cached: { token: string; until: number; email: string } | null = null;

export async function googleAccessToken(sa: ServiceAccount, scope = 'https://www.googleapis.com/auth/firebase.messaging'): Promise<string> {
  if (cached && cached.email === sa.client_email && cached.until > Date.now() + 60_000) return cached.token;
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${enc({ alg: 'RS256', typ: 'JWT' })}.${enc({ iss: sa.client_email, scope, aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 })}`;
  const key = await importKey(sa.private_key);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned));
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${unsigned}.${b64url(sig)}` }),
  });
  const j = (await res.json().catch(() => ({}))) as { access_token?: string; expires_in?: number; error_description?: string; error?: string };
  if (!res.ok || !j.access_token) throw new Error(j.error_description || j.error || `Google answered ${res.status}`);
  cached = { token: j.access_token, until: Date.now() + (j.expires_in ?? 3600) * 1000, email: sa.client_email };
  return j.access_token;
}
