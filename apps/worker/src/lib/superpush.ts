import { notify, P, type C, type Deps, type TenantDoc, type UserDoc } from '../core';
import { todayIST, addDays } from './dates';
import { edgeGet, edgePut } from './edge';
import { sendPush, takePush } from './push';
import type { ServiceAccount } from './gauth';

/** GM Admin notifications (board 63). Each kind can be switched off in GM Admin. */
export type SuperKind = 'tickets' | 'payments' | 'gyms' | 'failed' | 'expired';
export const SUPER_KINDS: SuperKind[] = ['tickets', 'payments', 'gyms', 'failed', 'expired'];
export const ADMIN_PUSH = 'settings/adminPush';

export async function notifySuper(deps: Deps, kind: SuperKind, title: string, body: string, go?: string) {
  if (!deps.superAdminEmail) return;
  const [prefs, rows] = await Promise.all([deps.store.get<Record<string, boolean>>(ADMIN_PUSH), deps.store.query<UserDoc>('users', [['email', deps.superAdminEmail]])]);
  if (prefs && prefs[kind] === false) return;
  for (const r of rows.filter((x) => x.data.isSuperAdmin && !x.data.deleted)) {
    await deps.store.tx((t) => notify(t, r.id, null, title, body, null, go));
  }
}

/** After the answer: tell the super admin (in the app + phone). Never breaks the request. */
export function superLater(c: C, kind: SuperKind, title: string, body: string, go?: string) {
  const deps = c.var.deps;
  const job = notifySuper(deps, kind, title, body, go)
    .then(() => sendPush(deps.store, deps.serviceAccount ?? null, takePush()))
    .catch(() => {});
  try {
    c.executionCtx.waitUntil(job);
  } catch {
    /* tests: let it run */
  }
}

/**
 * Plan reminders (board 64): from 7 days before a gym's plan (or free trial) ends, every day at 10 AM IST
 * the owners get a notification; on the last day; and after it ended every day for 30 days, then weekly
 * (up to 6 months). Run by the every-minute job a few gyms at a time (Worker sub-request limit).
 */
interface ReminderDoc {
  day: string;
  queue: { tid: string; title: string; body: string }[];
}
const REM = 'settings/planReminders';

function istHour() {
  return new Date(Date.now() + 5.5 * 3600_000).getUTCHours();
}
const dayOf = (iso: string | null | undefined) => (iso ? new Date(Date.parse(iso) + 5.5 * 3600_000).toISOString().slice(0, 10) : null);
const daysBetween = (a: string, b: string) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86400_000);
const pretty = (ymd: string) => {
  const [y, m, d] = ymd.split('-').map(Number);
  return `${d} ${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][m - 1]} ${y}`;
};

/** The reminder (or none) a gym gets today. */
export function reminderFor(t: TenantDoc, planName: string | null, today: string): { title: string; body: string } | null {
  if (t.status === 'CLOSED' || t.status === 'SUSPENDED') return null;
  const trial = t.status === 'TRIAL';
  const end = dayOf(trial ? t.trialEndsAt : t.planEndsAt);
  if (!end) return null;
  const left = daysBetween(today, end);
  const what = trial ? 'free trial' : `${planName ?? 'GymMantra'} plan`;
  const What = trial ? 'Free trial' : `${planName ?? 'GymMantra'} plan`;
  if (left > 7) return null;
  if (left >= 2) return { title: `${What} ends in ${left} days`, body: `${t.name}: your ${what} ends on ${pretty(end)}. Renew now so check-ins, payments and members keep working — More → Subscription.` };
  if (left === 1) return { title: `${What} ends tomorrow`, body: `${t.name}: your ${what} ends on ${pretty(end)}. Renew today — More → Subscription.` };
  if (left === 0) return { title: `Last day of your ${what}`, body: `${t.name}: your ${what} ends tonight. Renew to keep everything on — More → Subscription.` };
  const ago = -left;
  if (ago > 180) return null;
  if (ago > 30 && ago % 7 !== 0) return null;
  return { title: `${What} has ended`, body: `${t.name}: your ${what} ended on ${pretty(end)}. Renew in 1 tap with UPI — More → Subscription.` };
}

export async function cronReminders(deps: Deps, sa: ServiceAccount | null) {
  const today = todayIST();
  if (istHour() < 10) return;
  if ((await edgeGet<{ day: string }>('plan-rem-done'))?.day === today) return;
  const { store } = deps;
  let doc = await store.get<ReminderDoc>(REM);
  if (!doc || doc.day !== today) {
    const [tenants, plans] = await Promise.all([store.query<TenantDoc>('tenants', []), store.query<{ name: string }>('saasPlans', [])]);
    const planName = new Map(plans.map((p) => [p.id, p.data.name]));
    const queue: ReminderDoc['queue'] = [];
    const endedToday: string[] = [];
    for (const r of tenants) {
      const m = reminderFor(r.data, r.data.saasPlanId ? planName.get(r.data.saasPlanId) ?? null : null, today);
      if (m) queue.push({ tid: r.id, ...m });
      const end = dayOf(r.data.status === 'TRIAL' ? r.data.trialEndsAt : r.data.planEndsAt);
      if (end && end === addDays(today, -1) && r.data.status !== 'CLOSED') endedToday.push(r.data.name);
    }
    doc = { day: today, queue };
    await store.tx(async (t) => t.set(REM, doc!));
    if (endedToday.length) await notifySuper(deps, 'expired', `${endedToday.length} gym plan${endedToday.length > 1 ? 's' : ''} ended`, endedToday.slice(0, 8).join(', ') + (endedToday.length > 8 ? '…' : '')).catch(() => {});
  }
  // A few gyms per minute.
  const batch = doc.queue.slice(0, 6);
  for (const it of batch) {
    const owners = (await store.query<{ role: string; active: boolean }>(P.staffCol(it.tid), [['role', 'OWNER']])).filter((x) => x.data.active).map((x) => x.id);
    if (owners.length) await store.tx(async (t) => {
      for (const o of owners) await notify(t, o, it.tid, it.title, it.body);
    });
  }
  await sendPush(store, sa, takePush());
  const rest = doc.queue.slice(batch.length);
  await store.tx(async (t) => t.set(REM, { day: today, queue: rest }));
  if (!rest.length) await edgePut('plan-rem-done', { day: today }, 2 * 86400);
}
