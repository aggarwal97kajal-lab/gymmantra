import { addDays, diffDays, Ymd } from './dates';

export type MembershipStatus =
  | 'ACTIVE'
  | 'ENDING_SOON'
  | 'FROZEN'
  | 'EXPIRED'
  | 'NO_PLAN'
  | 'UPCOMING';

export interface FreezeLike {
  id?: string;
  startDate: Ymd;
  days: number;
  endedOn?: Ymd | null;
}

export interface SubLike {
  id: string;
  replacesId?: string | null;
  startDate: Ymd;
  endDate: Ymd;
  total: number;
  allowEntryWhileDue: boolean;
  freezeDaysAllowed: number;
  createdAt: Date | string;
  paid: number; // sum of payments
  freezes: FreezeLike[];
}

export const ENDING_SOON_DAYS = 7;

const inr = (n: number) => `₹${n.toLocaleString('en-IN')}`;

/** Days a freeze actually used (shorter if it was ended early). */
export function freezeUsedDays(f: FreezeLike): number {
  if (f.endedOn) return Math.max(0, Math.min(f.days, diffDays(f.startDate, f.endedOn)));
  return f.days;
}

/** End date after adding frozen days. */
export function effectiveEnd(sub: Pick<SubLike, 'endDate' | 'freezes'>): Ymd {
  const used = sub.freezes.reduce((n, f) => n + freezeUsedDays(f), 0);
  return addDays(sub.endDate, used);
}

export function activeFreeze(sub: Pick<SubLike, 'freezes'>, today: Ymd): FreezeLike | null {
  for (const f of sub.freezes) {
    const until = addDays(f.startDate, freezeUsedDays(f)); // exclusive
    if (f.startDate <= today && today < until) return f;
  }
  return null;
}

/** Rows that have not been replaced by a correction. */
export function validSubs<T extends SubLike>(subs: T[]): T[] {
  const replaced = new Set(subs.map((s) => s.replacesId).filter(Boolean) as string[]);
  return subs.filter((s) => !replaced.has(s.id));
}

export interface MemberState<T extends SubLike = SubLike> {
  status: MembershipStatus;
  current: T | null; // the membership covering today, or the latest one
  upcoming: T | null;
  daysLeft: number | null;
  endsOn: Ymd | null; // effective end including freezes
  due: number;
  frozenUntil: Ymd | null;
  frozenDays?: number; // freeze days added to the end date (current membership and the renewals after it)
}

export function computeState<T extends SubLike>(all: T[], today: Ymd): MemberState<T> {
  const subs = validSubs(all);
  if (subs.length === 0) {
    return { status: 'NO_PLAN', current: null, upcoming: null, daysLeft: null, endsOn: null, due: 0, frozenUntil: null };
  }
  // Frozen days push every renewal that follows in the same chain later (a 7-day freeze on this year's
  // membership also moves next year's start and end by 7 days). Each membership gets its shifted dates.
  const frozenOf = (s: T) => s.freezes.reduce((n, f) => n + freezeUsedDays(f), 0);
  const ranges: { s: T; start: Ymd; end: Ymd; shiftBefore: number }[] = [];
  {
    let shift = 0;
    let prevEnd = null as Ymd | null;
    for (const x of [...subs].sort((a, b) => (a.startDate > b.startDate ? 1 : a.startDate < b.startDate ? -1 : 0))) {
      const pe: Ymd | null = prevEnd;
      const chained: boolean = pe != null && addDays(x.startDate, shift) <= addDays(pe, 1);
      if (!chained) shift = 0;
      const start = addDays(x.startDate, shift);
      const end = addDays(effectiveEnd(x), shift);
      ranges.push({ s: x, start, end, shiftBefore: shift });
      prevEnd = chained && pe != null && String(pe) > String(end) ? pe : end;
      shift += frozenOf(x);
    }
  }
  const covering = ranges.filter((r) => r.start <= today && today <= r.end).sort((a, b) => (b.end > a.end ? 1 : b.end < a.end ? -1 : 0));
  const future = ranges.filter((r) => r.start > today).sort((a, b) => (a.start > b.start ? 1 : -1));
  const due = subs.reduce((n, s) => n + Math.max(0, s.total - s.paid), 0);

  if (covering.length) {
    const cur = covering[0];
    // If a renewal follows directly, days left run to the end of the chain.
    let chainEnd = cur.end;
    let frozenDays = cur.shiftBefore + frozenOf(cur.s);
    for (const f of future) {
      if (f.start <= addDays(chainEnd, 1)) {
        if (f.end > chainEnd) chainEnd = f.end;
        frozenDays = Math.max(frozenDays, f.shiftBefore + frozenOf(f.s));
      }
    }
    const daysLeft = diffDays(today, chainEnd);
    const fr = activeFreeze(cur.s, today);
    const status: MembershipStatus = fr ? 'FROZEN' : daysLeft > ENDING_SOON_DAYS ? 'ACTIVE' : 'ENDING_SOON';
    return {
      status,
      current: cur.s,
      upcoming: future[0]?.s ?? null,
      daysLeft,
      endsOn: chainEnd,
      due,
      frozenUntil: fr ? addDays(fr.startDate, freezeUsedDays(fr) - 1) : null,
      frozenDays,
    };
  }
  if (future.length) {
    return { status: 'UPCOMING', current: null, upcoming: future[0].s, daysLeft: null, endsOn: future[0].end, due, frozenUntil: null };
  }
  const latest = [...ranges].sort((a, b) => (b.end > a.end ? 1 : -1))[0];
  return { status: 'EXPIRED', current: latest.s, upcoming: null, daysLeft: diffDays(today, latest.end), endsOn: latest.end, due, frozenUntil: null };
}

export interface EntryDecision {
  result: 'ALLOWED' | 'WARNED' | 'BLOCKED';
  reason: string | null;
}

/** Whether the front desk lets a member in today. */
export function entryDecision(state: MemberState): EntryDecision {
  switch (state.status) {
    case 'NO_PLAN':
      return { result: 'BLOCKED', reason: 'No membership' };
    case 'EXPIRED':
      return { result: 'BLOCKED', reason: `Membership expired on ${state.endsOn}` };
    case 'UPCOMING':
      return { result: 'BLOCKED', reason: `Membership starts on ${state.upcoming?.startDate}` };
    case 'FROZEN':
      return { result: 'BLOCKED', reason: `Membership frozen till ${state.frozenUntil}` };
  }
  const cur = state.current!;
  const curDue = Math.max(0, cur.total - cur.paid);
  if (curDue > 0 && !cur.allowEntryWhileDue) {
    return { result: 'BLOCKED', reason: `Payment due ${inr(curDue)}` };
  }
  const notes: string[] = [];
  if (state.status === 'ENDING_SOON') notes.push(`Ends in ${state.daysLeft} day${state.daysLeft === 1 ? '' : 's'}`);
  if (curDue > 0) notes.push(`Payment due ${inr(curDue)}`);
  return notes.length ? { result: 'WARNED', reason: notes.join(' · ') } : { result: 'ALLOWED', reason: null };
}

/** Start date for a renewal: day after the current chain ends, or today if expired. */
export function renewalStart(state: MemberState, today: Ymd): Ymd {
  if ((state.status === 'ACTIVE' || state.status === 'ENDING_SOON' || state.status === 'FROZEN') && state.endsOn) {
    return addDays(state.endsOn, 1);
  }
  if (state.status === 'UPCOMING' && state.upcoming) return addDays(effectiveEnd(state.upcoming), 1);
  return today;
}

export function freezeDaysLeft(sub: SubLike): number {
  const used = sub.freezes.reduce((n, f) => n + freezeUsedDays(f), 0);
  return Math.max(0, sub.freezeDaysAllowed - used);
}
