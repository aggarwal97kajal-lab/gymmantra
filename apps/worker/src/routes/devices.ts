import { App, audit, authenticate, branchOf, C, Deps, gymOf, MemberDoc, notify, notifyDesk, P, readRoster, Role, TenantDoc, UserDoc } from '../core';
import { openGate } from './gate';
import { todayIST } from '../lib/dates';
import { bad, conflict, notFound, nowIso } from '../lib/http';
import { bumpCounter } from '../lib/ratelimit';
import { body, oneOf, optStr, str } from '../lib/validate';
import { addDays } from '../lib/dates';
import { sendPush, takePush } from '../lib/push';
import type { ServiceAccount } from '../lib/gauth';
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
/**
 * Kinds (boards 99-105): `adms` eSSL / ZKTeco / Realtime / Identix ("Cloud server"), `hik` Hikvision
 * ("HTTP Listening"), `link` any other machine or software that calls our secret web link, `file`
 * machines without internet (attendance file from a pen drive). For hik / link / file the id is a
 * random key (the web link is /api/v1/punch/{id}).
 */
export type DeviceKind = 'adms' | 'hik' | 'link' | 'file';
export interface DeviceDoc {
  serial: string;
  kind?: DeviceKind; // missing = adms (machines added before kinds)
  tenantId: string;
  branchId: string | null;
  name: string;
  addedAt: string;
  lastSeen: string | null;
  pins: Record<string, { kind: 'member' | 'staff'; id: string; name: string }>;
  unknown: Record<string, string>; // PIN -> last punch time, for PINs not linked yet
  offlineAlertAt?: string | null; // owner told the machine is offline (once until it is back)
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

/** The member whose Member ID number is this machine number (LF-1023 → 1023). */
async function memberByCode(store: Deps['store'], tenantId: string, pin: string): Promise<string | null> {
  const n = Number(pin);
  if (!Number.isFinite(n) || n <= 0) return null;
  const roster = await readRoster(store, tenantId);
  for (const [id, e] of Object.entries(roster.members)) {
    if (e.archived || e.gone) continue;
    const digits = /(\d+)\s*$/.exec(e.memberCode ?? '')?.[1];
    if (digits && Number(digits) === n) return id;
  }
  return null;
}

/** Links a machine number to a person; the first punch of an unknown number is remembered for the owner. */
async function linkFor(c: C, dev: DeviceDoc, pin: string, when: string) {
  const { store } = c.var.deps;
  if (dev.pins[pin]) return dev.pins[pin];
  const mid = await memberByCode(store, dev.tenantId, pin);
  const m = mid ? await store.get<MemberDoc>(P.member(dev.tenantId, mid)) : null;
  return store.tx(async (t) => {
    const d = await t.get<DeviceDoc>(P.device(dev.serial));
    if (!d) return null;
    if (m) {
      const link = { kind: 'member' as const, id: m.id, name: m.name };
      const unknown = { ...d.unknown };
      delete unknown[pin];
      t.set(P.device(dev.serial), { ...d, pins: { ...d.pins, [pin]: link }, unknown });
      return link;
    }
    t.set(P.device(dev.serial), { ...d, unknown: { ...d.unknown, [pin]: when } });
    return null;
  });
}

/** One punch: "PIN" at "YYYY-MM-DD HH:MM:SS" (machine time = India time). */
async function punch(c: C, dev: DeviceDoc, pin: string, when: string) {
  const day = when.slice(0, 10);
  if (day !== todayIST()) return; // an old punch sent late is not a check-in now (pen-drive files use importPunches)
  const link = await linkFor(c, dev, pin, when);
  if (!link) return;
  const { store } = c.var.deps;
  if (link.kind === 'member') {
    const m = await store.get<MemberDoc>(P.member(dev.tenantId, link.id));
    if (!m || m.archived) return;
    const o = await store.tx(async (t) => {
      const out = await recordMemberCheckIn(t, dev.tenantId, m, { method: 'DEVICE', byId: `device:${dev.serial}`, branchId: dev.branchId, oncePerDay: true });
      // Plan over / frozen / money due (and entry not allowed): tell the desk at once.
      if (out.result === 'BLOCKED' && !out.duplicate) {
        const tenant = (await t.get<TenantDoc>(P.tenant(dev.tenantId)))!;
        await notifyDesk(t, { tenantId: dev.tenantId, tenant }, null, 'Fingerprint: entry stopped', `${m.name} (${m.memberCode}) · ${out.reason ?? 'Not allowed'} · ${dev.name}`, branchOf(tenant, dev.branchId), 'checkin', `member:${m.id}`);
      }
      return out;
    });
    await countCheckIn(c, o);
    // Door option B: GymMantra opens the gate only for a member who may enter.
    if (o.result !== 'BLOCKED') {
      const tenant = await store.get<TenantDoc>(P.tenant(dev.tenantId));
      const b = tenant?.branches.find((x) => x.id === branchOf(tenant, dev.branchId));
      if (b?.fpGate) await openGate(c.var.deps, dev.tenantId, b.id);
    }
    return;
  }
  await markStaff(store, dev, link.id, day, `Fingerprint (${dev.name})`);
}

async function markStaff(store: Deps['store'], dev: DeviceDoc, uid: string, day: string, note: string) {
  const path = `tenants/${dev.tenantId}/staffDays/${uid}_${day.slice(0, 7)}`;
  await store.tx(async (t) => {
    const cur = (await t.get<StaffDaysDoc>(path)) ?? { uid, month: day.slice(0, 7), branchId: dev.branchId, days: {} };
    if (cur.days[day] && !cur.days[day].absent) return;
    t.set(path, { ...cur, days: { ...cur.days, [day]: { at: nowIso(), distM: null, note } } });
  });
}

/** Punch lines from a pen-drive file: ZKTeco attlog ("1023<TAB>2026-11-06 07:12:33…"), CSV or plain text. */
export function parsePunchFile(text: string) {
  const out: { pin: string; day: string; time: string }[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const m = /^"?(\d{1,9})"?[\s,;|]+"?(\d{4})[-/](\d{2})[-/](\d{2})[ T,;]+(\d{1,2}):(\d{2})/.exec(line) ?? null;
    const d = m ? null : /^"?(\d{1,9})"?[\s,;|]+"?(\d{2})[-/](\d{2})[-/](\d{4})[ T,;]+(\d{1,2}):(\d{2})/.exec(line); // 06-11-2026 07:12
    if (m) out.push({ pin: String(Number(m[1])), day: `${m[2]}-${m[3]}-${m[4]}`, time: `${m[5].padStart(2, '0')}:${m[6]}` });
    else if (d) out.push({ pin: String(Number(d[1])), day: `${d[4]}-${d[3]}-${d[2]}`, time: `${d[5].padStart(2, '0')}:${d[6]}` });
  }
  return out;
}

/** Pulls the machine number and time out of a pushed punch (Hikvision event or any simple JSON / form). */
export function punchFromBody(data: unknown): { pin: string; when: string } | null {
  const find = (o: unknown, keys: string[], depth = 0): string | null => {
    if (!o || typeof o !== 'object' || depth > 4) return null;
    for (const [k, v] of Object.entries(o as Record<string, unknown>)) {
      if (keys.includes(k.toLowerCase()) && (typeof v === 'string' || typeof v === 'number') && String(v).trim()) return String(v).trim();
    }
    for (const v of Object.values(o as Record<string, unknown>)) {
      const r = find(v, keys, depth + 1);
      if (r) return r;
    }
    return null;
  };
  const pin = find(data, ['employeenostring', 'employeeno', 'pin', 'userid', 'user_id', 'empcode', 'emp_code', 'enrollno', 'cardholderid']);
  if (!pin || !/^\d{1,9}$/.test(pin)) return null;
  const t = find(data, ['datetime', 'time', 'timestamp', 'punchtime', 'punch_time', 'logtime']);
  // "2026-11-06T07:12:33+05:30" / "2026-11-06 07:12:33" → India time; missing → now.
  let when = '';
  if (t && /^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/.test(t)) {
    const hasZone = /([+-]\d{2}:?\d{2}|Z)$/.test(t);
    const ms = hasZone ? Date.parse(t) : NaN;
    when = Number.isFinite(ms) ? `${todayIST(new Date(ms))} ${new Date(ms + 5.5 * 3600_000).toISOString().slice(11, 19)}` : t.replace('T', ' ').slice(0, 19);
  } else {
    const now = new Date();
    when = `${todayIST(now)} ${new Date(now.getTime() + 5.5 * 3600_000).toISOString().slice(11, 19)}`;
  }
  return { pin: String(Number(pin)), when };
}

const LIVE_MS: Record<DeviceKind, number> = { adms: 30 * 60_000, hik: 24 * 3600_000, link: 24 * 3600_000, file: 0 };
const isLive = (d: DeviceDoc) => (d.kind ?? 'adms') !== 'file' && !!d.lastSeen && Date.now() - Date.parse(d.lastSeen) < LIVE_MS[d.kind ?? 'adms'];
const randomId = () => [...crypto.getRandomValues(new Uint8Array(18))].map((b) => 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'[b % 57]).join('');

/** Every 10 minutes: a live machine of a fingerprint-only branch quiet for an hour → tell the owners once. */
export async function cronDevices(deps: Deps, sa: ServiceAccount | null, now = new Date()) {
  if (now.getUTCMinutes() % 10 !== 0) return;
  const { store } = deps;
  const all = await store.query<DeviceDoc>(P.devices, []);
  for (const { data: d } of all) {
    if ((d.kind ?? 'adms') !== 'adms' || !d.lastSeen) continue;
    const quiet = now.getTime() - Date.parse(d.lastSeen) > 3600_000;
    if (!quiet) {
      if (d.offlineAlertAt) await store.tx(async (t) => t.set(P.device(d.serial), { ...d, offlineAlertAt: null }));
      continue;
    }
    if (d.offlineAlertAt) continue;
    await store
      .tx(async (t) => {
        const tenant = await t.get<TenantDoc>(P.tenant(d.tenantId));
        const b = tenant?.branches.find((x) => x.id === branchOf(tenant, d.branchId));
        t.set(P.device(d.serial), { ...d, offlineAlertAt: now.toISOString() });
        if (!tenant || !b?.fingerprintOnly) return;
        const owners = (await t.query<{ role: Role; active: boolean }>(P.staffCol(d.tenantId), [['active', true]])).filter((s) => s.data.role === 'OWNER');
        for (const o of owners) await notify(t, o.id, d.tenantId, 'Fingerprint machine offline', `${d.name} has not been in touch for an hour. Check its internet and power, or turn off "Attendance only by fingerprint" to use QR check-in again.`, b.id, 'devices');
      })
      .catch(() => {});
  }
  await sendPush(store, sa, takePush());
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

  // ---------------- Hikvision / any other machine or software: our secret web link ----------------
  app.post('/api/v1/punch/:id', async (c) => {
    const id = c.req.param('id');
    if (!SERIAL.test(id) || id.length < 18) return c.json({ ok: false }, 404);
    if ((await bumpCounter(`punch:${id}`, 60_000)).n > 120) return c.json({ ok: false }, 429);
    const dev = await c.var.deps.store.get<DeviceDoc>(P.device(id));
    if (!dev || (dev.kind !== 'hik' && dev.kind !== 'link')) return c.json({ ok: false }, 404);
    // JSON, a form, or Hikvision's multipart event (field "event_log" / "AccessControllerEvent").
    let data: unknown = null;
    const type = c.req.header('content-type') ?? '';
    try {
      if (type.includes('json')) data = await c.req.json();
      else if (type.includes('form')) {
        const f = await c.req.parseBody();
        const out: Record<string, unknown> = {};
        for (const [k, v] of Object.entries(f)) {
          if (typeof v !== 'string') continue;
          try {
            out[k] = JSON.parse(v);
          } catch {
            out[k] = v;
          }
        }
        data = out;
      } else {
        const txt = (await c.req.text()).slice(0, 50_000);
        try {
          data = JSON.parse(txt);
        } catch {
          data = Object.fromEntries(new URLSearchParams(txt));
        }
      }
    } catch {
      data = null;
    }
    await c.var.deps.store.tx(async (t) => {
      const d = await t.get<DeviceDoc>(P.device(id));
      if (d) t.set(P.device(id), { ...d, lastSeen: nowIso() });
    });
    const p = punchFromBody(data);
    if (!p) return c.json({ ok: true, punch: false }); // heartbeats and other events
    await punch(c, dev, p.pin, p.when).catch((e) => console.error('punch', e));
    return c.json({ ok: true, punch: true });
  });

  // ---------------- owner ----------------
  const view = (c: C, d: DeviceDoc) => {
    const kind = d.kind ?? 'adms';
    const host = new URL(c.req.url).host;
    return {
      ...d,
      kind,
      online: isLive(d),
      url: kind === 'hik' || kind === 'link' ? `https://${host}/api/v1/punch/${d.serial}` : null,
      server: kind === 'adms' ? host : null,
      pins: Object.entries(d.pins).map(([pin, x]) => ({ pin, ...x })).sort((a, b) => Number(a.pin) - Number(b.pin)),
      unknown: Object.entries(d.unknown).filter(([pin]) => !d.pins[pin]).map(([pin, at]) => ({ pin, at })).sort((a, b) => (a.at < b.at ? 1 : -1)),
    };
  };

  /** Machines of the branch open on Home, and the branch's fingerprint settings. */
  app.get('/api/v1/gym/devices', async (c) => {
    await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const rows = (await c.var.deps.store.query<DeviceDoc>(P.devices, [['tenantId', g.tenantId]])).map((r) => r.data).filter((d) => branchOf(g.tenant, d.branchId) === g.branchId);
    const b = g.tenant.branches.find((x) => x.id === g.branchId);
    const list = rows.map((d) => view(c, d));
    // Old app (build 63 and before) reads a plain list; it never sends ?v=2.
    if (c.req.query('v') !== '2') return c.json(list);
    return c.json({ machines: list, fingerprintOnly: !!b?.fingerprintOnly, fpGate: !!b?.fpGate, branchName: b?.name ?? null });
  });

  app.post('/api/v1/gym/devices', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const kind: DeviceKind = b.kind == null ? 'adms' : oneOf(b, 'kind', ['adms', 'hik', 'link', 'file'] as const)!;
    let serial: string;
    if (kind === 'adms') {
      serial = str(b, 'serial', { max: 40, label: 'the serial number' }).toUpperCase().trim();
      if (!SERIAL.test(serial)) throw bad('The serial number has only letters and numbers');
    } else serial = randomId();
    const name = optStr(b, 'name', { max: 40 }) || { adms: 'Fingerprint machine', hik: 'Hikvision machine', link: 'Machine (web link)', file: 'Machine (pen drive)' }[kind];
    const d = await c.var.deps.store.tx(async (t) => {
      if (await t.get(P.device(serial))) throw conflict('This machine is already added');
      const doc: DeviceDoc = { serial, kind, tenantId: g.tenantId, branchId: g.branchId ?? null, name, addedAt: nowIso(), lastSeen: null, pins: {}, unknown: {} };
      t.create(P.device(serial), doc);
      audit(t, g.tenantId, u.id, 'device.add', 'device', serial, null, { ...doc, serial: kind === 'adms' ? serial : '(secret)' });
      return doc;
    });
    return c.json(view(c, d), 201);
  });

  /** Owner: attendance only by fingerprint at this branch (QR check-in and app "Present" off), and door option B. */
  app.put('/api/v1/gym/fingerprint-mode', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const on = typeof b.on === 'boolean' ? b.on : undefined;
    const gate = typeof b.gate === 'boolean' ? b.gate : undefined;
    if (on === undefined && gate === undefined) throw bad('Nothing to change');
    if (on) {
      const mine = (await c.var.deps.store.query<DeviceDoc>(P.devices, [['tenantId', g.tenantId]])).map((r) => r.data).filter((d) => branchOf(g.tenant, d.branchId) === g.branchId);
      if (!mine.some(isLive)) throw bad('Add a fingerprint machine at this branch and let it come online first');
    }
    const out = await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<TenantDoc>(P.tenant(g.tenantId)))!;
      const branches = cur.branches.map((x) => (x.id === g.branchId ? { ...x, ...(on !== undefined ? { fingerprintOnly: on } : {}), ...(gate !== undefined ? { fpGate: gate } : {}) } : x));
      t.set(P.tenant(g.tenantId), { ...cur, branches });
      const nb = branches.find((x) => x.id === g.branchId);
      audit(t, g.tenantId, u.id, 'fingerprint.mode', 'branch', g.branchId, null, { fingerprintOnly: !!nb?.fingerprintOnly, fpGate: !!nb?.fpGate });
      return { fingerprintOnly: !!nb?.fingerprintOnly, fpGate: !!nb?.fpGate };
    });
    return c.json(out);
  });

  /** Owner: a pen-drive attendance file (last 31 days). dry=1 only counts. Big files go in pieces (offset). */
  app.post('/api/v1/gym/devices/:serial/import', async (c) => {
    const { g, serial } = await mine(c);
    const b = body(await c.req.json().catch(() => null));
    const text = str(b, 'text', { max: 3_000_000, label: 'the file' });
    const dry = b.dry === true;
    const offset = typeof b.offset === 'number' && b.offset > 0 ? Math.floor(b.offset) : 0;
    const { store } = c.var.deps;
    const dev = await store.get<DeviceDoc>(P.device(serial));
    if (!dev || dev.tenantId !== g.tenantId) throw notFound('Machine not found');
    const from = addDays(todayIST(), -31);
    // One entry per person per day (the first punch of the day).
    const seenKey = new Set<string>();
    const punches = parsePunchFile(text).filter((x) => x.day >= from && x.day <= todayIST()).sort((a, b) => (a.day + a.time < b.day + b.time ? -1 : 1)).filter((x) => {
      const k = `${x.pin}|${x.day}`;
      if (seenKey.has(k)) return false;
      seenKey.add(k);
      return true;
    });
    if (!punches.length) throw bad('No attendance found in this file. Use the attendance file from the machine (pen drive / USB download)');
    const pins = [...new Set(punches.map((x) => x.pin))];
    const links: Record<string, { kind: 'member' | 'staff'; id: string; name: string } | null> = {};
    let cur = dev;
    for (const pin of pins) {
      links[pin] = cur.pins[pin] ?? null;
      if (!links[pin]) {
        const mid = await memberByCode(store, g.tenantId, pin);
        const m = mid ? await store.get<MemberDoc>(P.member(g.tenantId, mid)) : null;
        if (m && !dry) {
          const d = (await store.get<DeviceDoc>(P.device(serial)))!;
          cur = { ...d, pins: { ...d.pins, [pin]: { kind: 'member', id: m.id, name: m.name } } };
          await store.set(P.device(serial), cur);
        }
        links[pin] = m ? { kind: 'member', id: m.id, name: m.name } : null;
      }
    }
    const count = { members: 0, staff: 0, unknown: 0, days: { from: punches[0].day, to: punches[punches.length - 1].day } };
    for (const x of punches) {
      const l = links[x.pin];
      if (!l) count.unknown++;
      else if (l.kind === 'member') count.members++;
      else count.staff++;
    }
    if (dry) return c.json({ ...count, total: punches.length, unknownPins: pins.filter((p) => !links[p]) });
    // Write a slice per request (the free Workers plan allows only so much work per request).
    const SLICE = 60;
    const part = punches.slice(offset, offset + SLICE);
    for (const x of part) {
      const l = links[x.pin];
      if (!l) {
        await store.tx(async (t) => {
          const d = await t.get<DeviceDoc>(P.device(serial));
          if (d && !d.pins[x.pin]) t.set(P.device(serial), { ...d, unknown: { ...d.unknown, [x.pin]: `${x.day} ${x.time}:00` } });
        });
        continue;
      }
      if (l.kind === 'staff') {
        await markStaff(store, dev, l.id, x.day, `Fingerprint file (${dev.name})`);
        continue;
      }
      // A member: one check-in entry for that day (the same file sent twice adds nothing).
      const id = `file-${l.id}-${x.day}`;
      await store.tx(async (t) => {
        const [m, old, tenant] = (await t.getMany<any>([P.member(g.tenantId, l.id), P.attendanceEv(g.tenantId, id), P.tenant(g.tenantId)])) as [MemberDoc | null, unknown, TenantDoc];
        if (!m || m.archived || old) return;
        const at = new Date(Date.parse(`${x.day}T${x.time}:00+05:30`)).toISOString();
        t.set(P.attendanceEv(g.tenantId, id), { memberId: m.id, memberName: m.name, memberCode: m.memberCode, branchId: branchOf(tenant, dev.branchId ?? m.branchId), day: x.day, at, result: 'ALLOWED', reason: null, method: 'DEVICE', scannedById: `device:${serial}` });
      });
    }
    const next = offset + part.length;
    return c.json({ ...count, total: punches.length, done: next, more: next < punches.length, next });
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
