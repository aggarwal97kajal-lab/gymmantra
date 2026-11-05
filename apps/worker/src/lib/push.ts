import { googleAccessToken, type ServiceAccount } from './gauth';
import type { Store } from '../store/store';
import { edgeGet, edgePut } from './edge';

/**
 * Phone notifications (FCM HTTP v1). Every in-app notification (`notify()`) also goes to the person's
 * phones; super admin broadcasts and gym notices go to topics the app subscribes to.
 * Nothing happens when the FIREBASE_SERVICE_ACCOUNT secret is missing.
 *
 * notify() runs inside transactions (which can re-run), so it only queues; the queue is sent once the
 * request has answered (app.ts → flushPush with waitUntil).
 */
export interface PushItem {
  uid?: string;
  topicCondition?: string;
  title: string;
  body: string;
  data?: Record<string, string>;
}

const queue = new Map<string, PushItem>();
export function queuePush(p: PushItem) {
  queue.set(`${p.uid ?? p.topicCondition}|${p.title}|${p.body}`, p); // a re-run transaction does not send twice
}
export function takePush(): PushItem[] {
  const out = [...queue.values()];
  queue.clear();
  return out;
}

export const pushTokensPath = (uid: string) => `pushTokens/${uid}`;
export interface PushTokensDoc {
  tokens: { token: string; at: string; app: string }[];
}

/** Topic names may only use letters, numbers and - _ . ~ % */
export const topicName = (s: string) => s.replace(/[^A-Za-z0-9_.~-]/g, '_').slice(0, 200);

/** Topic for a gym branch's members (M) or trainers (T). */
export const gymTopic = (tenantId: string, branchId: string, who: 'M' | 'T') => topicName(`g_${tenantId}_${branchId}_${who}`);

export async function sendPush(store: Store, sa: ServiceAccount | null, items: PushItem[]) {
  if (!sa || !items.length) return;
  let access: string;
  try {
    access = await googleAccessToken(sa);
  } catch {
    return;
  }
  const uids = [...new Set(items.map((i) => i.uid).filter((x): x is string => !!x))].slice(0, 30);
  const docs = uids.length ? await store.getMany<PushTokensDoc>(uids.map(pushTokensPath)).catch(() => []) : [];
  const tokensOf = new Map(uids.map((u, i) => [u, (docs[i]?.tokens ?? []).map((t) => t.token)]));
  const url = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  const dead = new Map<string, string[]>();
  let sent = 0;
  for (const it of items) {
    const targets: Record<string, string>[] = it.topicCondition ? [{ condition: it.topicCondition }] : (tokensOf.get(it.uid ?? '') ?? []).map((token) => ({ token }));
    for (const target of targets) {
      if (sent >= 40) return; // keep inside the Worker's sub-request budget (50)
      sent++;
      const res = await fetch(url, {
        method: 'POST',
        headers: { authorization: `Bearer ${access}`, 'content-type': 'application/json' },
        body: JSON.stringify({
          message: {
            ...target,
            notification: { title: it.title, body: it.body },
            data: it.data ?? {},
            android: { priority: 'HIGH', notification: { sound: 'default' } },
          },
        }),
      }).catch(() => null);
      if (res && (res.status === 404 || res.status === 400) && target.token && it.uid) {
        const t = await res.text().catch(() => '');
        if (/UNREGISTERED|INVALID_ARGUMENT/.test(t)) dead.set(it.uid, [...(dead.get(it.uid) ?? []), target.token]);
      } else {
        await res?.text().catch(() => '');
      }
    }
  }
  // Forget phones that uninstalled the app.
  for (const [uid, bad] of dead) {
    await store
      .tx(async (t) => {
        const d = await t.get<PushTokensDoc>(pushTokensPath(uid));
        if (d) t.set(pushTokensPath(uid), { tokens: d.tokens.filter((x) => !bad.includes(x.token)) });
      })
      .catch(() => {});
  }
}

/**
 * Sending to a chosen group of people (for example a gym notice only for active members).
 * A topic cannot be used because a member's status changes by itself, so the phones are reached
 * one by one: about 20 people right away, the rest by the every-minute job (worker.ts `scheduled`).
 */
export interface FanoutJob {
  uids: string[];
  next: number;
  title: string;
  body: string;
  data?: Record<string, string>;
  createdAt: string;
}
const JOBS = 'pushJobs';

export async function createFanout(store: Store, uids: string[], title: string, body: string, data?: Record<string, string>) {
  const list = [...new Set(uids)].slice(0, 5000);
  if (!list.length) return;
  const id = crypto.randomUUID();
  await store.tx(async (t) => {
    t.set(`${JOBS}/${id}`, { uids: list, next: 0, title, body, data: data ?? {}, createdAt: new Date().toISOString() } satisfies FanoutJob);
  });
  await edgePut('push-jobs', { at: Date.now() }, 7200); // tells the every-minute job there is work
}

/** Every minute (worker.ts scheduled): only looks at the database when there is work. */
export async function cronFanouts(store: Store, sa: ServiceAccount | null) {
  if (!sa || !(await edgeGet('push-jobs'))) return;
  await runFanouts(store, sa);
}

/** Sends the next people of each waiting job, within the sub-request budget. */
export async function runFanouts(store: Store, sa: ServiceAccount | null, people = 20) {
  if (!sa) return;
  const jobs = await store.query<FanoutJob>(JOBS, []).catch(() => []);
  for (const j of jobs) {
    if (people <= 0) return;
    const slice = j.data.uids.slice(j.data.next, j.data.next + people);
    people -= slice.length;
    await sendPush(store, sa, slice.map((uid) => ({ uid, title: j.data.title, body: j.data.body, data: j.data.data })));
    const next = j.data.next + slice.length;
    await store
      .tx(async (t) => {
        if (next >= j.data.uids.length) t.delete(`${JOBS}/${j.id}`);
        else t.set(`${JOBS}/${j.id}`, { ...j.data, next });
      })
      .catch(() => {});
  }
}
