import { App, audit, authenticate, gymOf, need, P } from '../core';
import type { Deps } from '../core';
import { bad, nowIso } from '../lib/http';
import { body, oneOf, optInt, optStr } from '../lib/validate';

/**
 * Gate (board 55): after an allowed check-in the server tells the gate's device to open.
 * Each branch has its own gate. Two kinds of device:
 *  - "webhook": any WiFi relay / controller that opens when a web link is called (most smart relays can);
 *  - "shelly": a Shelly WiFi relay through Shelly Cloud (server + auth key + device id from the Shelly app).
 * The device itself keeps the lock open for its set seconds (auto-off), so one "open" call is enough.
 */
export interface GateCfg {
  type: 'webhook' | 'shelly';
  name: string;
  url?: string | null; // webhook
  method?: 'GET' | 'POST';
  shellyServer?: string | null; // e.g. https://shelly-49-eu.shelly.cloud
  shellyKey?: string | null;
  shellyId?: string | null;
  channel?: number;
  seconds: number;
  on: boolean;
  lastOpenAt?: string | null;
  lastError?: string | null;
}
const gatePath = (t: string) => `tenants/${t}/private/gate`;
type GateDoc = { branches: Record<string, GateCfg> };

/** Opens the gate of one branch. Never throws; says what happened. */
export async function openGate(deps: Deps, tenantId: string, branchId: string | null | undefined): Promise<'opened' | 'offline' | null> {
  if (!branchId) return null;
  const doc = await deps.store.get<GateDoc>(gatePath(tenantId)).catch(() => null);
  const g = doc?.branches?.[branchId];
  if (!g || !g.on) return null;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 3500);
  try {
    let res: Response;
    if (g.type === 'shelly') {
      const form = new URLSearchParams({ id: g.shellyId ?? '', auth_key: g.shellyKey ?? '', channel: String(g.channel ?? 0), turn: 'on' });
      if (g.seconds) form.set('timer', String(g.seconds));
      res = await fetch(`${(g.shellyServer ?? '').replace(/\/+$/, '')}/device/relay/control`, { method: 'POST', body: form, signal: ctl.signal });
    } else {
      res = await fetch(g.url!, { method: g.method ?? 'GET', signal: ctl.signal });
    }
    if (!res.ok) throw new Error(`device answered ${res.status}`);
    await res.text().catch(() => '');
    return 'opened';
  } catch (e) {
    // Remember the problem so the owner sees "Gate offline".
    await deps.store
      .tx(async (t) => {
        const cur = await t.get<GateDoc>(gatePath(tenantId));
        if (cur?.branches?.[branchId]) t.set(gatePath(tenantId), { branches: { ...cur.branches, [branchId]: { ...cur.branches[branchId], lastError: `${nowIso()} ${String((e as Error)?.message ?? e).slice(0, 120)}` } } });
      })
      .catch(() => {});
    return 'offline';
  } finally {
    clearTimeout(timer);
  }
}

const httpsUrl = (v: string | undefined, label: string) => {
  if (!v) return null;
  try {
    const u = new URL(v);
    // https only (the link often carries the device's key), and only a public internet address.
    if (u.protocol !== 'https:') throw new Error();
    const h = u.hostname.toLowerCase();
    if (h === 'localhost' || h.endsWith('.local') || h.endsWith('.internal') || /^\[|^\d+\.\d+\.\d+\.\d+$/.test(h)) throw new Error();
    return u.toString();
  } catch {
    throw bad(`Enter a valid https:// web address (not a local or IP address) for ${label}`);
  }
};

export function gateRoutes(app: App) {
  /** Gate of the branch being looked at. Secrets are not sent back, only whether they are set. */
  app.get('/api/v1/gym/gate', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    need(g, 'checkin');
    const doc = await c.var.deps.store.get<GateDoc>(gatePath(g.tenantId));
    const cfg = doc?.branches?.[g.branchId] ?? null;
    return c.json(
      cfg
        ? { set: true, type: cfg.type, name: cfg.name, on: cfg.on, seconds: cfg.seconds, method: cfg.method ?? 'GET', url: cfg.url ? cfg.url.replace(/([?&](key|token|auth[^=]*)=)[^&]+/gi, '$1•••') : null, shellyServer: cfg.shellyServer ?? null, shellyId: cfg.shellyId ?? null, channel: cfg.channel ?? 0, lastError: cfg.lastError ?? null }
        : { set: false },
    );
  });

  app.put('/api/v1/gym/gate', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const type = oneOf(b, 'type', ['webhook', 'shelly'] as const)!;
    const { store } = c.var.deps;
    await store.tx(async (t) => {
      const cur = (await t.get<GateDoc>(gatePath(g.tenantId))) ?? { branches: {} };
      const old = cur.branches[g.branchId];
      const next: GateCfg = {
        type,
        name: optStr(b, 'name', { max: 40 }) ?? old?.name ?? 'Main gate',
        on: b.on === undefined ? old?.on ?? true : b.on === true,
        seconds: optInt(b, 'seconds', { min: 1, max: 30 }) ?? old?.seconds ?? 5,
        method: oneOf(b, 'method', ['GET', 'POST'] as const, true) ?? old?.method ?? 'GET',
        channel: optInt(b, 'channel', { min: 0, max: 3 }) ?? old?.channel ?? 0,
        url: type === 'webhook' ? httpsUrl(optStr(b, 'url', { max: 500 }), 'the gate link') ?? old?.url ?? null : null,
        shellyServer: type === 'shelly' ? httpsUrl(optStr(b, 'shellyServer', { max: 200 }), 'the Shelly server') ?? old?.shellyServer ?? null : null,
        shellyKey: type === 'shelly' ? optStr(b, 'shellyKey', { max: 300 }) ?? old?.shellyKey ?? null : null,
        shellyId: type === 'shelly' ? optStr(b, 'shellyId', { max: 60 }) ?? old?.shellyId ?? null : null,
        lastError: null,
      };
      if (type === 'webhook' && !next.url) throw bad('Enter the gate link from your device');
      if (type === 'shelly' && (!next.shellyServer || !next.shellyKey || !next.shellyId)) throw bad('Enter the Shelly server, auth key and device ID');
      t.set(gatePath(g.tenantId), { branches: { ...cur.branches, [g.branchId]: next } });
      audit(t, g.tenantId, u.id, 'gate.update', 'gate', g.branchId, old ? { ...old, shellyKey: '•••' } : null, { ...next, shellyKey: next.shellyKey ? '•••' : null });
    });
    return c.json({ ok: true });
  });

  app.delete('/api/v1/gym/gate', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<GateDoc>(gatePath(g.tenantId))) ?? { branches: {} };
      const branches = { ...cur.branches };
      delete branches[g.branchId];
      t.set(gatePath(g.tenantId), { branches });
      audit(t, g.tenantId, u.id, 'gate.remove', 'gate', g.branchId, null, null);
    });
    return c.json({ ok: true });
  });

  /** Owner / front desk: "Open now". */
  app.post('/api/v1/gym/gate/open', async (c) => {
    await authenticate(c);
    const g = await gymOf(c);
    need(g, 'checkin');
    const r = await openGate(c.var.deps, g.tenantId, g.branchId);
    if (!r) throw bad('No gate is set up for this branch');
    return c.json({ gate: r });
  });
}
