import { notify, P, type Deps, type Role, type TenantDoc, type UserDoc } from '../core';
import { todayIST } from './dates';
import { edgeGet, edgePut } from './edge';
import { sendPush, takePush } from './push';
import type { ServiceAccount } from './gauth';

/**
 * Attendance reminders (board 73): at 11 AM and 5 PM (India time) front desk staff and trainers who have
 * not pressed "Present" today get a notification. Run by the every-minute job a few gyms at a time
 * (Worker sub-request limit); a gym that is closed, or a person who already marked, gets nothing.
 */
interface AttRemDoc {
  key: string; // day + slot, e.g. 2026-11-05-am
  queue: string[]; // gym ids still to do
}
const DOC = 'settings/attendanceReminders';
const PEOPLE_PER_RUN = 15;

export function attendanceSlot(now = new Date()): 'am' | 'pm' | null {
  const h = new Date(now.getTime() + 5.5 * 3600_000).getUTCHours();
  if (h >= 17 && h < 22) return 'pm';
  if (h >= 11 && h < 17) return 'am';
  return null;
}

export async function cronAttendanceReminders(deps: Deps, sa: ServiceAccount | null, now = new Date()) {
  const slot = attendanceSlot(now);
  if (!slot) return;
  const today = todayIST(now);
  const key = `${today}-${slot}`;
  if ((await edgeGet<{ key: string }>('att-rem-done'))?.key === key) return;
  const { store } = deps;
  let doc = await store.get<AttRemDoc>(DOC);
  if (!doc || doc.key !== key) {
    const tenants = await store.query<TenantDoc>('tenants', []);
    doc = { key, queue: tenants.filter((t) => t.data.status !== 'CLOSED' && t.data.status !== 'SUSPENDED').map((t) => t.id) };
    await store.tx(async (t) => t.set(DOC, doc!));
  }
  let budget = PEOPLE_PER_RUN;
  let done = 0;
  for (const tid of doc.queue) {
    if (budget <= 0) break;
    done++;
    const staff = (await store.query<{ role: Role; active: boolean }>(P.staffCol(tid), [['active', true]])).filter((s) => s.data.role === 'FRONT_DESK' || s.data.role === 'TRAINER');
    if (!staff.length) continue;
    const month = today.slice(0, 7);
    const [days, users] = await Promise.all([
      store.getMany<{ days: Record<string, { absent?: boolean }> }>(staff.map((s) => `tenants/${tid}/staffDays/${s.id}_${month}`)),
      store.getMany<UserDoc>(staff.map((s) => P.user(s.id))),
    ]);
    const missing = staff.filter((s, i) => users[i] && !users[i]!.deleted && !(days[i]?.days?.[today] && !days[i]!.days[today].absent)).map((s) => s.id);
    if (!missing.length) continue;
    budget -= missing.length;
    const title = slot === 'am' ? 'Mark your attendance' : 'Still not marked';
    const body = slot === 'am' ? 'You have not marked Present today. Open My attendance at the gym and tap Present.' : 'Your attendance for today is still not marked. Mark Present at the gym before you leave.';
    // Fingerprint-only branches: the machine marks Present, so the reminder says to use the machine
    // (and stops once the finger is on the machine, like the app "Present").
    const tenant = await store.get<TenantDoc>(P.tenant(tid));
    const trainers = await store.getMany<{ branchId?: string | null }>(missing.map((uid) => P.trainer(tid, uid)));
    const fpBody = slot === 'am' ? 'You have not marked your attendance today. Put your finger on the fingerprint machine at the gym.' : 'Your attendance for today is still not marked. Put your finger on the fingerprint machine before you leave.';
    const first = tenant?.branches[0]?.id ?? null;
    const fpOf = (uid: string, i: number) => {
      const s = staff.find((x) => x.id === uid) as { data: { branchIds?: string[] } } | undefined;
      const bid = trainers[i]?.branchId ?? s?.data.branchIds?.[0] ?? first;
      return !!tenant?.branches.find((b) => b.id === bid)?.fingerprintOnly;
    };
    await store
      .tx(async (t) => {
        await t.getMany(missing.map(P.notes)); // one read for everyone
        for (const [i, uid] of missing.entries()) await notify(t, uid, tid, title, fpOf(uid, i) ? fpBody : body, null, 'attendance');
      })
      .catch(() => {});
  }
  await sendPush(store, sa, takePush());
  const rest = doc.queue.slice(done);
  await store.tx(async (t) => t.set(DOC, { key, queue: rest }));
  if (!rest.length) await edgePut('att-rem-done', { key }, 86400);
}
