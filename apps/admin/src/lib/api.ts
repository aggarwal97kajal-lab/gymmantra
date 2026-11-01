'use client';

const GYM_KEY = 'gm.gymId';

export function getGymId(): string | null {
  try {
    return localStorage.getItem(GYM_KEY);
  } catch {
    return null;
  }
}
export function setGymId(id: string | null) {
  try {
    if (id) localStorage.setItem(GYM_KEY, id);
    else localStorage.removeItem(GYM_KEY);
  } catch {
    /* private mode */
  }
}

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
    public body?: unknown,
  ) {
    super(message);
  }
}

/** Calls the GymMantra API through the same-origin /api proxy. The session is an httpOnly cookie. */
export async function api<T = any>(path: string, opts: { method?: string; body?: unknown } = {}): Promise<T> {
  const headers: Record<string, string> = { 'x-gm-client': 'admin' };
  const gym = getGymId();
  if (gym) headers['x-gym-id'] = gym;
  if (opts.body !== undefined) headers['content-type'] = 'application/json';
  let res: Response;
  try {
    res = await fetch(`/api/v1${path}`, {
      method: opts.method ?? (opts.body !== undefined ? 'POST' : 'GET'),
      headers,
      credentials: 'same-origin',
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    });
  } catch {
    throw new ApiError(0, 'Could not reach the server. Check your internet connection.');
  }
  const text = await res.text();
  let data: any = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  if (!res.ok) {
    let msg = (data && (Array.isArray(data.message) ? data.message[0] : data.message)) || `Something went wrong (${res.status})`;
    if (res.status === 429 && !String(msg).startsWith('Too many')) msg = 'Too many attempts. Please wait a bit and try again.';
    if (res.status === 401 && typeof window !== 'undefined' && !path.startsWith('/auth/')) {
      window.location.href = '/login';
    }
    throw new ApiError(res.status, String(msg), data);
  }
  return data as T;
}

export const rupees = (n: number | null | undefined) => `₹${(n ?? 0).toLocaleString('en-IN')}`;

export function fmtDate(ymd: string | null | undefined) {
  if (!ymd) return '—';
  const d = new Date(ymd.length === 10 ? `${ymd}T00:00:00Z` : ymd);
  return d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: ymd.length === 10 ? 'UTC' : 'Asia/Kolkata' });
}

export function fmtTime(iso: string) {
  return new Date(iso).toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit', timeZone: 'Asia/Kolkata' });
}

export function fmtDateTime(iso: string) {
  return new Date(iso).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit', timeZone: 'Asia/Kolkata' });
}

export function todayIST() {
  return new Date(Date.now() + 330 * 60_000).toISOString().slice(0, 10);
}

export const STATUS: Record<string, { label: string; cls: string }> = {
  ACTIVE: { label: 'Active', cls: 'ok' },
  ENDING_SOON: { label: 'Ending soon', cls: 'warn' },
  FROZEN: { label: 'Frozen', cls: 'info' },
  EXPIRED: { label: 'Expired', cls: 'bad' },
  NO_PLAN: { label: 'No plan', cls: 'off' },
  UPCOMING: { label: 'Starts later', cls: 'info' },
};

export const PAY_MODES = [
  { v: 'CASH', l: 'Cash' },
  { v: 'UPI', l: 'UPI' },
  { v: 'CARD', l: 'Card' },
  { v: 'BANK_TRANSFER', l: 'Bank transfer' },
  { v: 'NOT_PAID', l: 'Not paid yet' },
];

export function initials(name: string) {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]!.toUpperCase())
    .join('');
}

export const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;
