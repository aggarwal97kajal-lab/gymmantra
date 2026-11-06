import { notify, notifyDesk, P, type Deps, type TenantDoc } from '../core';
import type { Tx } from '../store/store';
import { todayIST } from './dates';
import { sendPush, takePush } from './push';
import type { ServiceAccount } from './gauth';

/**
 * Reminders set for a later day (Nov 6): "enquiry calls today" (9 AM) and locker endings (10 AM).
 * One document per reminder in `scheduled`, found by day. The every-minute job sends the ones
 * whose hour has come, a few at a time, and checks at sending time that they still apply.
 */
export interface ScheduledDoc {
  id: string;
  day: string; // YYYY-MM-DD (India)
  hour: number; // India hour to send at
  tenantId: string;
  kind: 'enquiries' | 'locker';
  branchId: string | null;
  ref: string; // locker: "<branchId>:<number>:<to>"
}

export function schedule(t: Pick<Tx, 'set'>, s: ScheduledDoc) {
  t.set(P.scheduledItem(s.id), s);
}

const PER_RUN = 10;

export async function cronScheduled(deps: Deps, sa: ServiceAccount | null, now = new Date()) {
  const { store } = deps;
  const today = todayIST(now);
  const hour = new Date(now.getTime() + 5.5 * 3600_000).getUTCHours();
  const due = (await store.query<ScheduledDoc>(P.scheduled, [['day', today]])).filter((r) => r.data.hour <= hour).slice(0, PER_RUN);
  for (const { data: s } of due) {
    await store
      .tx(async (t) => {
        const tenant = await t.get<TenantDoc>(P.tenant(s.tenantId));
        if (tenant && tenant.status !== 'CLOSED') {
          if (s.kind === 'enquiries') {
            const { dueToday } = await import('../routes/enquiries');
            const n = await dueToday(t, s.tenantId, s.branchId, today);
            if (n > 0) await notifyDesk(t, { tenantId: s.tenantId, tenant }, null, 'Enquiry calls today', `${n} ${n === 1 ? 'person' : 'people'} to call or message today. Open Enquiries.`, s.branchId, 'enquiries', 'enquiries');
          } else if (s.kind === 'locker') {
            const { lockerReminder } = await import('../routes/lockers');
            const r = await lockerReminder(t, s.tenantId, s.ref, today);
            if (r) {
              await notify(t, r.userId, s.tenantId, r.member.title, r.member.body, r.branchId);
              await notifyDesk(t, { tenantId: s.tenantId, tenant }, null, r.desk.title, r.desk.body, r.branchId, 'lockers', 'lockers');
            }
          }
        }
        t.delete(P.scheduledItem(s.id));
      })
      .catch((e) => console.error('scheduled', s.id, e));
  }
  if (due.length) await sendPush(store, sa, takePush());
}
