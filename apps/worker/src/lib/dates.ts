// Calendar dates are handled as 'YYYY-MM-DD' strings in India time (IST),
// and stored in Postgres DATE columns (Prisma returns them as UTC midnight).

const IST_OFFSET_MIN = 330;

export type Ymd = string;

export function todayIST(now: Date = new Date()): Ymd {
  const t = new Date(now.getTime() + IST_OFFSET_MIN * 60_000);
  return t.toISOString().slice(0, 10);
}

export function toYmd(d: Date | string): Ymd {
  if (typeof d === 'string') return d.slice(0, 10);
  return d.toISOString().slice(0, 10);
}

export function toDbDate(ymd: Ymd): Date {
  return new Date(`${ymd}T00:00:00.000Z`);
}

export function isYmd(s: unknown): s is Ymd {
  if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  return !isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

export function addDays(ymd: Ymd, days: number): Ymd {
  const d = toDbDate(ymd);
  d.setUTCDate(d.getUTCDate() + days);
  return toYmd(d);
}

/** Adds calendar months, clamping to the last day of the target month. */
export function addMonths(ymd: Ymd, months: number): Ymd {
  const [y, m, d] = ymd.split('-').map(Number);
  const total = y * 12 + (m - 1) + months;
  const ty = Math.floor(total / 12);
  const tm = total % 12;
  const last = new Date(Date.UTC(ty, tm + 1, 0)).getUTCDate();
  const day = Math.min(d, last);
  return `${ty}-${String(tm + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

/** Whole days from a to b (b - a). */
export function diffDays(a: Ymd, b: Ymd): number {
  return Math.round((toDbDate(b).getTime() - toDbDate(a).getTime()) / 86_400_000);
}

/** Business rule: end date = start date + plan months - 1 day. */
export function planEndDate(start: Ymd, months: number): Ymd {
  return addDays(addMonths(start, months), -1);
}

export function maxYmd(a: Ymd, b: Ymd): Ymd {
  return a > b ? a : b;
}
