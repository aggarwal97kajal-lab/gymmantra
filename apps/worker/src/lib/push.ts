import { googleAccessToken, type ServiceAccount } from './gauth';
import type { Store } from '../store/store';

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
  const uids = [...new Set(items.map((i) => i.uid).filter((x): x is string => !!x))].slice(0, 15);
  const docs = uids.length ? await store.getMany<PushTokensDoc>(uids.map(pushTokensPath)).catch(() => []) : [];
  const tokensOf = new Map(uids.map((u, i) => [u, (docs[i]?.tokens ?? []).map((t) => t.token)]));
  const url = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  const dead = new Map<string, string[]>();
  let sent = 0;
  for (const it of items) {
    const targets: Record<string, string>[] = it.topicCondition ? [{ condition: it.topicCondition }] : (tokensOf.get(it.uid ?? '') ?? []).map((token) => ({ token }));
    for (const target of targets) {
      if (sent >= 30) return; // keep inside the Worker's sub-request budget
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
