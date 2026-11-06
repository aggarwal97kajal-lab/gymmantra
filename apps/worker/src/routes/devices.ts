import { App, audit, authenticate, C, gymOf, MemberDoc, P, UserDoc } from '../core';
import { todayIST } from '../lib/dates';
import { bad, conflict, notFound, nowIso } from '../lib/http';
import { bumpCounter } from '../lib/ratelimit';
import { body, oneOf, optStr, str } from '../lib/validate';
import { countCheckIn, recordMemberCheckIn } from './attendance';
import type { StaffDaysDoc } from './staffdays';

/**
 * Fingerprint / face machines (board 85): eSSL, ZKTeco and similar machines with "Cloud server"
 * (ADMS / PUSH) send every punch to /iclock/cdata. The owner adds the machine by its serial number
 * and links each machine user number (PIN) to a member or a staff member / trainer. A member's punch
 * is a check-in (method DEVICE); a staff punch marks Present for that day.
 * The machine cannot log in, so the /iclock routes are public; they accept only serial numbers an
 * owner added, and only a few requests a minute per machine.
 */
export interface DeviceDoc {
  serial: string;
  tenantId: string;
  branchId: string | null;
  name: string;
  addedAt: string;
  lastSeen: string | null;
  pins: Record<string, { kind: 'member' | 'staff'; id: string; name: string }>;
  unknown: Record<string, string>; // PIN -> last punch time, for PINs not linked yet
}

const SERIAL = /^[A-Za-z0-9_-]{4,40}$/;
const seen = new Map<string, number>();

async function deviceFor(c: C) {
  const sn = c.req.query('SN') ?? '';
  if (!SERIAL.test(sn)) return null;
  const n = await bumpCounter(`iclock:${sn}`, 60_000);
  if (n.n > 120) return null; // a machine polls every few seconds; far more than that is not a machine
  const dev = await c.var.deps.store.get<DeviceDoc>(P.device(sn));
  if (!dev) return null;
  // "Last seen" is written at most every 10 minutes (machines ask every few seconds).
  if (Date.now() - (seen.get(sn) ?? 0) > 600_000) {
    seen.set(sn, Date.now());
    await c.var.deps.store.tx(async (t) => {
      const d = await t.get<DeviceDoc>(P.device(sn));
      if (d) t.set(P.device(sn), { ...d, lastSeen: nowIso() });
    });
  }
  return dev;
}

const text = (c: C, s: string, status = 200) => c.text(s, status as 200, { 'content-type': 'text/plain' });

/** One punch line: "PIN<TAB>YYYY-MM-DD HH:MM:SS<TAB>…" (machine time = India time). */
async function punch(c: C, dev: DeviceDoc, pin: string, when: string) {
  const day = when.slice(0, 10);
  const link = dev.pins[pin];
  const { store } = c.var.deps;
  if (!link) {
    await store.tx(async (t) => {
      const d = await t.get<DeviceDoc>(P.device(dev.serial));
      if (d) t.set(P.device(dev.serial), { ...d, unknown: { ...d.unknown, [pin]: when } });
    });
    return;
  }
  if (link.kind === 'member') {
    if (day !== todayIST()) return; // an old punch sent late is not a check-in now
    const m = await store.get<MemberDoc>(P.member(dev.tenantId, link.id));
    if (!m || m.archived) return;
    await store
      .tx((t) => recordMemberCheckIn(t, dev.tenantId, m, { method: 'DEVICE', byId: `device:${dev.serial}`, branchId: dev.branchId, oncePerDay: true }))
      .then((o) => countCheckIn(c, o));
    return;
  }
  const path = `tenants/${dev.tenantId}/staffDays/${link.id}_${day.slice(0, 7)}`;
  await store.tx(async (t) => {
    const cur = (await t.get<StaffDaysDoc>(path)) ?? { uid: link.id, month: day.slice(0, 7), branchId: dev.branchId, days: {} };
    if (cur.days[day] && !cur.days[day].absent) return;
    t.set(path, { ...cur, days: { ...cur.days, [day]: { at: nowIso(), distM: null, note: `Fingerprint (${dev.name})` } } });
  });
}

export function deviceRoutes(app: App) {
  // ---------------- what the machine calls ----------------
  app.get('/iclock/cdata', async (c) => {
    const dev = await deviceFor(c);
    if (!dev) return text(c, 'UNKNOWN DEVICE', 404);
    return text(
      c,
      [`GET OPTION FROM: ${dev.serial}`, 'ATTLOGStamp=None', 'OPERLOGStamp=9999', 'ATTPHOTOStamp=None', 'ErrorDelay=30', 'Delay=10', 'TransTimes=00:00;14:05', 'TransInterval=1', 'TransFlag=TransData AttLog', 'Realtime=1', 'Encrypt=None'].join('\n'),
    );
  });

  app.post('/iclock/cdata', async (c) => {
    const dev = await deviceFor(c);
    if (!dev) return text(c, 'UNKNOWN DEVICE', 404);
    const raw = (await c.req.text()).slice(0, 100_000);
    if ((c.req.query('table') ?? '').toUpperCase() !== 'ATTLOG') return text(c, 'OK');
    const lines = raw.split(/\r?\n/).filter((l) => l.trim());
    let n = 0;
    for (const line of lines.slice(0, 20)) {
      const [pin, when] = line.split('\t');
      if (!pin || !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(when ?? '')) continue;
      await punch(c, dev, pin.trim(), when).catch((e) => console.error('punch', e));
      n++;
    }
    return text(c, `OK: ${n}`);
  });

  app.get('/iclock/getrequest', async (c) => ((await deviceFor(c)) ? text(c, 'OK') : text(c, 'UNKNOWN DEVICE', 404)));
  app.post('/iclock/devicecmd', async (c) => ((await deviceFor(c)) ? text(c, 'OK') : text(c, 'UNKNOWN DEVICE', 404)));

  // ---------------- owner ----------------
  app.get('/api/v1/gym/devices', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const rows = (await c.var.deps.store.query<DeviceDoc>(P.devices, [['tenantId', g.tenantId]])).map((r) => r.data);
    return c.json(
      rows.map((d) => ({
        ...d,
        online: !!d.lastSeen && Date.now() - Date.parse(d.lastSeen) < 30 * 60_000,
        pins: Object.entries(d.pins).map(([pin, x]) => ({ pin, ...x })).sort((a, b) => Number(a.pin) - Number(b.pin)),
        unknown: Object.entries(d.unknown).filter(([pin]) => !d.pins[pin]).map(([pin, at]) => ({ pin, at })),
      })),
    );
  });

  app.post('/api/v1/gym/devices', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const serial = str(b, 'serial', { max: 40, label: 'the serial number' }).toUpperCase();
    if (!SERIAL.test(serial)) throw bad('The serial number has only letters and numbers');
    const name = optStr(b, 'name', { max: 40 }) || 'Fingerprint machine';
    const d = await c.var.deps.store.tx(async (t) => {
      if (await t.get(P.device(serial))) throw conflict('This machine is already added');
      const doc: DeviceDoc = { serial, tenantId: g.tenantId, branchId: g.branchId ?? null, name, addedAt: nowIso(), lastSeen: null, pins: {}, unknown: {} };
      t.create(P.device(serial), doc);
      audit(t, g.tenantId, u.id, 'device.add', 'device', serial, null, doc);
      return doc;
    });
    return c.json(d, 201);
  });

  async function mine(c: C) {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const serial = c.req.param('serial')!;
    return { u, g, serial };
  }

  app.delete('/api/v1/gym/devices/:serial', async (c) => {
    const { u, g, serial } = await mine(c);
    await c.var.deps.store.tx(async (t) => {
      const d = await t.get<DeviceDoc>(P.device(serial));
      if (!d || d.tenantId !== g.tenantId) throw notFound('Machine not found');
      t.delete(P.device(serial));
      audit(t, g.tenantId, u.id, 'device.remove', 'device', serial, d, null);
    });
    return c.json({ ok: true });
  });

  /** Link a machine user number (PIN) to a member or a staff member / trainer. */
  app.put('/api/v1/gym/devices/:serial/pins/:pin', async (c) => {
    const { u, g, serial } = await mine(c);
    const pin = c.req.param('pin');
    if (!/^\d{1,9}$/.test(pin)) throw bad('Machine user number is digits only');
    const b = body(await c.req.json().catch(() => null));
    const kind = oneOf(b, 'kind', ['member', 'staff'] as const)!;
    const id = str(b, 'id', { label: 'who' });
    const { store } = c.var.deps;
    let name: string;
    if (kind === 'member') {
      const m = await store.get<MemberDoc>(P.member(g.tenantId, id));
      if (!m || m.archived) throw notFound('Member not found');
      name = m.name;
    } else {
      const [st, usr] = await store.getMany<any>([P.staff(g.tenantId, id), P.user(id)]);
      if (!st?.active) throw notFound('Staff not found');
      name = (usr as UserDoc | null)?.name ?? 'Staff';
    }
    const out = await store.tx(async (t) => {
      const d = await t.get<DeviceDoc>(P.device(serial));
      if (!d || d.tenantId !== g.tenantId) throw notFound('Machine not found');
      const unknown = { ...d.unknown };
      delete unknown[pin];
      const n = { ...d, pins: { ...d.pins, [pin]: { kind, id, name } }, unknown };
      t.set(P.device(serial), n);
      audit(t, g.tenantId, u.id, 'device.pin', 'device', serial, d.pins[pin] ?? null, { pin, kind, id });
      return { pin, kind, id, name };
    });
    return c.json(out);
  });

  app.delete('/api/v1/gym/devices/:serial/pins/:pin', async (c) => {
    const { u, g, serial } = await mine(c);
    const pin = c.req.param('pin');
    await c.var.deps.store.tx(async (t) => {
      const d = await t.get<DeviceDoc>(P.device(serial));
      if (!d || d.tenantId !== g.tenantId) throw notFound('Machine not found');
      const pins = { ...d.pins };
      delete pins[pin];
      t.set(P.device(serial), { ...d, pins });
      audit(t, g.tenantId, u.id, 'device.unpin', 'device', serial, d.pins[pin] ?? null, null);
    });
    return c.json({ ok: true });
  });
}
