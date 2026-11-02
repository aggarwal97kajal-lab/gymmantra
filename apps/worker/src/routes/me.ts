import { accountRole, App, authenticate, C, isDeskStaff, roleLocked, isTrainer, syncRosterPhoto, MemberDoc, NoteItem, P, paidOf, readRoster, rosterEntry, stateOf, SubDoc, TenantDoc, UserDoc, userNames } from '../core';
import { bad, conflict, forbidden, HttpError, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { makeQrToken } from '../lib/qr';
import { freezeDaysLeft } from '../lib/status';
import { todayIST } from '../lib/dates';
import { body, oneOf, optInt, optStr, str } from '../lib/validate';
import { isYmd } from '../lib/dates';
import { normalizeEmail, normalizePhone } from '../lib/phone';
import { publicUser } from './auth';
import type { PlanDoc } from './members';
import type { ScanLog } from './attendance';
import { offersFor } from './trainers';
import { noticeNotes, noticesFor } from './notices';
import { replyTicket, TICKET_TOPICS, Ticket, getTicket } from './tickets';

const MAX_PHOTO_BYTES = 400 * 1024;

/** A member record of the signed-in user (they can only reach their own). */
async function myMember(c: C, memberId: string) {
  const u = c.var.user;
  const tenantId = Object.entries(u.memberships ?? {}).find(([, m]) => m === memberId)?.[0];
  if (!tenantId) throw notFound('Membership not found');
  const { store } = c.var.deps;
  const [m, tenant] = await Promise.all([store.get<MemberDoc>(P.member(tenantId, memberId)), store.get<TenantDoc>(P.tenant(tenantId))]);
  if (!m || !tenant || m.archived || m.userId !== u.id) throw notFound('Membership not found');
  return { m, tenant, tenantId };
}

function b64ToBytes(b64: string) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function meRoutes(app: App) {
  app.get('/api/v1/me/gyms', async (c) => {
    const u = await authenticate(c);
    const { store } = c.var.deps;
    const entries = Object.entries(u.memberships ?? {});
    const [tenants, rosters, logs] = await Promise.all([
      store.getMany<TenantDoc>(entries.map(([t]) => P.tenant(t))),
      Promise.all(entries.map(([t]) => readRoster(store, t))),
      store.getMany<ScanLog>(entries.map(([t, m]) => P.lastScan(t, m))),
    ]);
    const month = todayIST().slice(0, 7);
    const states = entries.map(([tid, mid], i) => (rosters[i].members[mid] ? stateOf(rosters[i].members[mid]).status : 'NO_PLAN'));
    const [offers, notices] = await Promise.all([
      Promise.all(entries.map(([tid], i) => (tenants[i] ? offersFor(store, tid, 'MEMBER', states[i]) : []))),
      Promise.all(entries.map(([tid], i) => (tenants[i] ? noticesFor(store, tid, 'MEMBER', states[i]) : []))),
    ]);
    const memberships = entries
      .map(([tid, mid], i) => {
        const tn = tenants[i];
        const e = rosters[i].members[mid];
        if (!tn || !e || e.archived) return null;
        const st = stateOf(e);
        return {
          memberId: mid,
          memberCode: e.memberCode,
          gym: { id: tid, name: tn.name, logoUrl: tn.logoUrl, phone: tn.phone, whatsappNumber: tn.whatsappNumber, address: tn.address },
          status: st.status,
          planName: st.current?.planName ?? st.upcoming?.planName ?? null,
          daysLeft: st.daysLeft,
          endsOn: st.endsOn,
          startsOn: st.current?.startDate ?? st.upcoming?.startDate ?? null,
          visitsThisMonth: logs[i]?.month === month ? logs[i]!.visits : 0,
          lastVisitAt: logs[i]?.lastAllowedAt ?? null,
          offers: offers[i],
          notices: notices[i],
        };
      })
      .filter(Boolean);
    const reqIds = Object.keys(u.requested ?? {});
    const reqTenants = await store.getMany<TenantDoc>(reqIds.map(P.tenant));
    return c.json({ memberships, pendingRequests: reqIds.map((id, i) => (reqTenants[i] ? { id, gym: { id, name: reqTenants[i]!.name } } : null)).filter(Boolean) });
  });

  app.get('/api/v1/me/gym-lookup', async (c) => {
    await authenticate(c);
    const { store } = c.var.deps;
    const code = (c.req.query('code') ?? '').trim().toUpperCase();
    const ref = code ? await store.get<{ tenantId: string }>(P.gymCode(code)) : null;
    const t = ref ? await store.get<TenantDoc>(P.tenant(ref.tenantId)) : null;
    if (!ref || !t || t.status === 'SUSPENDED') throw notFound('No gym found with this code');
    return c.json({ id: ref.tenantId, name: t.name, logoUrl: t.logoUrl, address: t.address, branches: t.branches.map((b) => ({ id: b.id, name: b.name, address: b.address })) });
  });

  app.post('/api/v1/me/join', async (c) => {
    const u = await authenticate(c);
    const { store } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    const code = str(b, 'gymCode', { max: 20, label: 'the gym code' }).toUpperCase();
    const ref = await store.get<{ tenantId: string }>(P.gymCode(code));
    const t = ref ? await store.get<TenantDoc>(P.tenant(ref.tenantId)) : null;
    if (!ref || !t || t.status === 'SUSPENDED') throw notFound('No gym found with this code');
    const tid = ref.tenantId;
    const as = oneOf(b, 'as', ['MEMBER', 'TRAINER'] as const, true) ?? 'MEMBER';
    const branchId = optStr(b, 'branchId') ?? null;
    if (branchId && !t.branches.some((x) => x.id === branchId)) throw bad('Unknown branch');
    if (as === 'TRAINER') {
      if (isDeskStaff(u)) throw bad('A gym owner cannot join a gym as a trainer');
      if (u.staffOf?.[tid]?.active) throw conflict('You are already a trainer at this gym');
    } else if (u.memberships?.[tid]) throw conflict('You are already a member of this gym');
    if (!u.phone) throw bad('Add your mobile number in Profile first, so the gym can find you');
    const existing = (await store.query<any>(P.joins(tid), [['userId', u.id], ['status', 'PENDING']])).find((r) => (r.data.kind ?? 'MEMBER') === as);
    if (existing) return c.json({ id: existing.id, ...existing.data }, 201);
    const id = uuid();
    const trainerInfo =
      as === 'TRAINER'
        ? { speciality: optStr(b, 'speciality', { max: 80 }) ?? null, experienceYears: optInt(b, 'experienceYears', { min: 0, max: 60 }) ?? null }
        : {};
    const jr = { userId: u.id, kind: as, branchId, status: 'PENDING', createdAt: nowIso(), decidedById: null, decidedAt: null, ...trainerInfo };
    await store.tx(async (tx) => {
      const cur = (await tx.get<UserDoc>(P.user(u.id)))!;
      tx.set(P.join(tid, id), jr);
      if (as === 'TRAINER') tx.set(P.user(u.id), { ...cur, appRole: 'TRAINER', trainerRequested: { ...(cur.trainerRequested ?? {}), [tid]: true } });
      else tx.set(P.user(u.id), { ...cur, requested: { ...(cur.requested ?? {}), [tid]: true } });
    });
    return c.json({ id, ...jr }, 201);
  });

  /** "My membership" screen. Shows what the gym entered, and who updated it. */
  app.get('/api/v1/me/memberships/:memberId', async (c) => {
    await authenticate(c);
    const { m, tenant, tenantId } = await myMember(c, c.req.param('memberId'));
    const { store } = c.var.deps;
    const [roster, subRows] = await Promise.all([readRoster(store, tenantId), store.query<SubDoc>(P.subs(tenantId), [['memberId', m.id]])]);
    const st = stateOf(roster.members[m.id] ?? rosterEntry(m));
    const subs = subRows.map((r) => r.data);
    const replaced = new Set(subs.map((s) => s.replacesId).filter(Boolean));
    const visible = subs.filter((s) => !replaced.has(s.id));
    const names = await userNames(store, visible.map((s) => s.createdById));
    const curDoc = st.current ? visible.find((s) => s.id === st.current!.id) : undefined;
    return c.json({
      gym: { id: tenantId, name: tenant.name, phone: tenant.phone, whatsappNumber: tenant.whatsappNumber, address: tenant.address },
      memberCode: m.memberCode,
      status: st.status,
      daysLeft: st.daysLeft,
      endsOn: st.endsOn,
      due: st.due,
      frozenUntil: st.frozenUntil,
      current: curDoc
        ? {
            planName: curDoc.planName,
            startDate: curDoc.startDate,
            endDate: curDoc.endDate,
            total: curDoc.total,
            discount: curDoc.discount,
            paid: paidOf(curDoc),
            paymentModes: [...new Set(curDoc.payments.map((p) => p.mode))],
            freezeDaysLeft: freezeDaysLeft(st.current!),
            freezes: curDoc.freezes.map((f) => ({ startDate: f.startDate, days: f.days, endedOn: f.endedOn })),
            updatedBy: names.get(curDoc.createdById),
            updatedAt: curDoc.createdAt,
          }
        : null,
      history: visible
        .sort((a, b) => (a.startDate < b.startDate ? 1 : -1))
        .map((s) => ({ planName: s.planName, startDate: s.startDate, endDate: s.endDate, total: s.total, paid: paidOf(s), updatedBy: names.get(s.createdById), updatedAt: s.createdAt })),
    });
  });

  app.get('/api/v1/me/gyms/:tenantId/plans', async (c) => {
    const u = await authenticate(c);
    const tid = c.req.param('tenantId');
    if (!u.memberships?.[tid] && !u.requested?.[tid]) throw forbidden('Join this gym to see its plans');
    const rows = await c.var.deps.store.query<PlanDoc>(P.plans(tid), [['showInApp', true], ['active', true]]);
    return c.json(
      rows
        .map((r) => ({ id: r.id, name: r.data.name, months: r.data.months, price: r.data.price, joiningFee: r.data.joiningFee, freezeDays: r.data.freezeDays, features: r.data.features }))
        .sort((a, b) => a.months - b.months),
    );
  });

  app.get('/api/v1/me/qr/:memberId', async (c) => {
    await authenticate(c);
    const { m, tenantId } = await myMember(c, c.req.param('memberId'));
    const log = await c.var.deps.store.get<ScanLog>(P.lastScan(tenantId, m.id));
    const month = todayIST().slice(0, 7);
    return c.json({ ...(await makeQrToken(c.var.secrets.qr, m.id)), memberCode: m.memberCode, visitsThisMonth: log?.month === month ? log.visits : 0 });
  });

  app.get('/api/v1/me/attendance/:memberId', async (c) => {
    await authenticate(c);
    const { m, tenantId } = await myMember(c, c.req.param('memberId'));
    const log = await c.var.deps.store.get<ScanLog>(P.lastScan(tenantId, m.id));
    return c.json((log?.recent ?? []).filter((r) => r.result !== 'BLOCKED').map((r) => ({ id: r.id, scannedAt: r.at, result: r.result })));
  });

  app.patch('/api/v1/me/profile', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    let name = b.name !== undefined ? str(b, 'name', { min: 2, max: 80, label: 'your name' }) : undefined;
    const parts: Partial<UserDoc> = {};
    if (b.firstName !== undefined) {
      parts.firstName = str(b, 'firstName', { min: 1, max: 40, label: 'your first name' });
      parts.middleName = optStr(b, 'middleName', { max: 40 }) ?? null;
      parts.lastName = optStr(b, 'lastName', { max: 40 }) ?? null;
      name = [parts.firstName, parts.middleName, parts.lastName].filter(Boolean).join(' ');
      if (name.length < 2) throw bad('Enter your name');
    }
    if (b.dob !== undefined) {
      const d = optStr(b, 'dob') ?? null;
      if (d && (!isYmd(d) || d > todayIST() || d < '1900-01-01')) throw bad('Date of birth is not valid');
      parts.dob = d;
    }
    if (b.gender !== undefined) parts.gender = oneOf(b, 'gender', ['male', 'female', 'other'] as const, true) ?? null;
    if (b.address !== undefined) parts.address = optStr(b, 'address', { max: 300 }) ?? null;
    const language = oneOf(b, 'language', ['en', 'hi'] as const, true);
    const roleIn = oneOf(b, 'appRole', ['MEMBER', 'OWNER', 'TRAINER', 'NONE'] as const, true);
    const appRole = roleIn === 'NONE' ? null : roleIn;
    if (appRole === 'OWNER' && isTrainer(u)) throw bad('A trainer cannot be a gym owner');
    if (appRole === 'TRAINER' && isDeskStaff(u)) throw bad('A gym owner cannot be a trainer');
    // Once the account is tied to a gym (member, trainer or owner) its role is fixed.
    if (roleIn !== undefined && roleLocked(u) && appRole !== accountRole(u)) {
      throw bad('Your account role is fixed because you are already linked to a gym. Make a new account for a different role');
    }
    const next = await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<UserDoc>(P.user(u.id)))!;
      const n = { ...cur, ...parts, name: name ?? cur.name, language: language ?? cur.language, appRole: roleIn === undefined ? cur.appRole ?? null : appRole };
      t.set(P.user(u.id), n);
      return n;
    });
    return c.json(publicUser(u.id, next));
  });

  /** Change mobile number or email. Needs the current password (if the account has one). */
  app.patch('/api/v1/me/contact', async (c) => {
    const u = await authenticate(c);
    const { store, identity } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    if (u.authEmail) {
      const pw = str(b, 'password', { label: 'your current password' });
      await identity.signIn(u.authEmail, pw).catch(() => {
        throw bad('Current password is wrong');
      });
    }
    const emailIn = optStr(b, 'email');
    const email = emailIn !== undefined ? normalizeEmail(emailIn) : undefined;
    if (emailIn && !email) throw bad('Enter a valid email address');
    const phoneIn = optStr(b, 'phone');
    const phone = phoneIn !== undefined ? normalizePhone(phoneIn) : undefined;
    if (phoneIn && !phone) throw bad('Enter a valid 10-digit mobile number');
    if (email && email !== u.email && (await store.query<UserDoc>('users', [['email', email]])).some((r) => r.id !== u.id && !r.data.deleted)) throw conflict('This email ID already exists');
    const out = await store.tx(async (t) => {
      const cur = (await t.get<UserDoc>(P.user(u.id)))!;
      const next = { ...cur };
      if (email && email !== cur.email) next.email = email;
      if (phone && phone !== cur.phone) {
        if (await t.get(P.phone(phone))) throw conflict('This mobile number already exists');
        t.create(P.phone(phone), { uid: u.id });
        if (cur.phone) t.delete(P.phone(cur.phone));
        next.phone = phone;
      }
      t.set(P.user(u.id), next);
      return next;
    });
    return c.json(publicUser(u.id, out));
  });

  // ---------- Profile photo (kept small; visible to the member and their gyms' staff) ----------

  app.post('/api/v1/me/photo', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const mime = oneOf(b, 'mime', ['image/jpeg', 'image/png'] as const)!;
    const b64 = str(b, 'base64', { max: 600_000 });
    let bytes: Uint8Array;
    try {
      bytes = b64ToBytes(b64);
    } catch {
      throw bad('This file is not a JPEG or PNG image');
    }
    if (!bytes.length || bytes.length > MAX_PHOTO_BYTES) throw bad('Photo must be smaller than 400 KB');
    const isJpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    const isPng = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
    if ((mime === 'image/jpeg' && !isJpeg) || (mime === 'image/png' && !isPng)) throw bad('This file is not a JPEG or PNG image');
    const v = Date.now();
    await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<UserDoc>(P.user(u.id)))!;
      t.set(P.photo(u.id), { mime, b64 });
      t.set(P.user(u.id), { ...cur, photoV: v });
      await syncRosterPhoto(t, cur, v);
    });
    return c.json({ photoUrl: `/api/v1/photos/${u.id}?v=${v}` }, 201);
  });

  app.delete('/api/v1/me/photo', async (c) => {
    const u = await authenticate(c);
    await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<UserDoc>(P.user(u.id)))!;
      t.delete(P.photo(u.id));
      t.set(P.user(u.id), { ...cur, photoV: null });
      await syncRosterPhoto(t, cur, null);
    });
    return c.json({ ok: true });
  });

  app.get('/api/v1/photos/:userId', async (c) => {
    const u = await authenticate(c);
    const target = c.req.param('userId');
    const { store } = c.var.deps;
    if (target !== u.id && !u.isSuperAdmin) {
      const t = await store.get<UserDoc>(P.user(target));
      const myGyms = Object.entries(u.staffOf ?? {}).filter(([, s]) => s.active).map(([id]) => id);
      const theirGyms = t ? [...Object.keys(t.memberships ?? {}), ...Object.keys(t.requested ?? {}), ...Object.keys(t.trainerRequested ?? {}), ...Object.keys(t.staffOf ?? {})] : [];
      // Members may see the photos of their gym's trainers.
      const theirTrainerGyms = t ? Object.entries(t.staffOf ?? {}).filter(([, s]) => s.active && s.role === 'TRAINER').map(([id]) => id) : [];
      const memberOk = Object.keys(u.memberships ?? {}).some((g) => theirTrainerGyms.includes(g));
      if (!memberOk && !myGyms.some((g) => theirGyms.includes(g))) throw forbidden('Not allowed');
    }
    const p = await store.get<{ mime: string; b64: string }>(P.photo(target));
    if (!p) throw notFound('No photo');
    return new Response(b64ToBytes(p.b64), { headers: { 'content-type': p.mime, 'cache-control': 'private, max-age=86400' } });
  });

  // ---------- Help & Support (no email address is ever shown) ----------

  app.post('/api/v1/me/tickets', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const topic = oneOf(b, 'topic', Object.keys(TICKET_TOPICS))!;
    const subject = str(b, 'subject', { min: 3, max: 120, label: 'a subject' });
    const text = str(b, 'body', { max: 4000, label: 'a message' });
    const route = TICKET_TOPICS[topic];
    let tenantId: string | null = null;
    let memberId: string | null = null;
    if (route === 'GYM') {
      const mid = optStr(b, 'memberId');
      if (!mid) throw bad('Choose your gym');
      const r = await myMember(c, mid);
      tenantId = r.tenantId;
      memberId = r.m.id;
    }
    const id = uuid();
    const at = nowIso();
    const t: Ticket = {
      tenantId,
      memberId,
      userId: u.id,
      topic,
      subject,
      status: 'OPEN',
      routedTo: route,
      createdAt: at,
      updatedAt: at,
      messages: [{ id: uuid(), authorId: u.id, fromStaff: false, body: text, attachmentUrl: optStr(b, 'attachmentUrl', { max: 500 }) ?? null, createdAt: at }],
    };
    await c.var.deps.store.set(P.ticket(id), t);
    return c.json({ id, ...t }, 201);
  });

  app.get('/api/v1/me/tickets', async (c) => {
    const u = await authenticate(c);
    const rows = await c.var.deps.store.query<Ticket>(P.tickets, [['userId', u.id]]);
    return c.json(rows.map((r) => ({ id: r.id, ...r.data, messages: r.data.messages.slice(-1) })).sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1)));
  });

  app.get('/api/v1/me/tickets/:id', async (c) => {
    const u = await authenticate(c);
    return c.json(await getTicket(c, c.req.param('id'), (t) => t.userId === u.id));
  });

  app.post('/api/v1/me/tickets/:id/messages', async (c) => {
    const u = await authenticate(c);
    return c.json(await replyTicket(c, c.req.param('id'), (t) => t.userId === u.id, false), 201);
  });

  app.get('/api/v1/me/notifications', async (c) => {
    const u = await authenticate(c);
    const { store } = c.var.deps;
    const doc = await store.get<{ items: NoteItem[]; noticesReadAt?: string }>(P.notes(u.id));
    const notices = await noticeNotes(store, u, doc?.noticesReadAt ?? null);
    return c.json([...(doc?.items ?? []), ...notices].sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)).slice(0, 60));
  });

  app.post('/api/v1/me/notifications/read', async (c) => {
    const u = await authenticate(c);
    await c.var.deps.store.tx(async (t) => {
      const cur = await t.get<{ items: NoteItem[] }>(P.notes(u.id));
      const at = nowIso();
      t.set(P.notes(u.id), { items: (cur?.items ?? []).map((n) => ({ ...n, readAt: n.readAt ?? at })), noticesReadAt: at });
    });
    return c.json({ ok: true });
  });

  // ---------- Privacy ----------

  app.get('/api/v1/me/export', async (c) => {
    const u = await authenticate(c);
    const { store } = c.var.deps;
    const gyms = [];
    for (const [tid, mid] of Object.entries(u.memberships ?? {})) {
      const [t, m, subs] = await Promise.all([store.get<TenantDoc>(P.tenant(tid)), store.get<MemberDoc>(P.member(tid, mid)), store.query<SubDoc>(P.subs(tid), [['memberId', mid]])]);
      gyms.push({
        gym: t?.name,
        memberCode: m?.memberCode,
        joinedOn: m?.joinedOn,
        memberships: subs.map((s) => ({ plan: s.data.planName, start: s.data.startDate, end: s.data.endDate, total: s.data.total, payments: s.data.payments.map((p) => ({ amount: p.amount, mode: p.mode, at: p.receivedAt })) })),
      });
    }
    const tickets = await store.query<Ticket>(P.tickets, [['userId', u.id]]);
    return c.json({ user: { name: u.name, email: u.email, phone: u.phone, language: u.language, createdAt: u.createdAt }, gyms, tickets: tickets.map((t) => t.data) });
  });

  /** Deletes the login account. Gym records stay with the gym but are unlinked. */
  app.delete('/api/v1/me', async (c) => {
    const u = await authenticate(c);
    if (Object.values(u.staffOf ?? {}).some((s) => s.active)) throw forbidden('Gym staff accounts cannot be deleted here. Ask the gym owner to remove you first');
    const { store } = c.var.deps;
    for (const [tid, mid] of Object.entries(u.memberships ?? {})) {
      await store.tx(async (t) => {
        const m = await t.get<MemberDoc>(P.member(tid, mid));
        const roster = await readRoster(t, tid);
        if (m) t.set(P.member(tid, mid), { ...m, userId: null });
        if (roster.members[mid]) {
          roster.members[mid].userId = null;
          t.set(P.roster(tid), roster);
        }
      });
    }
    await store.tx(async (t) => {
      const cur = (await t.get<UserDoc>(P.user(u.id)))!;
      if (cur.phone) t.delete(P.phone(cur.phone));
      t.delete(P.photo(u.id));
      t.delete(P.notes(u.id));
      t.set(P.user(u.id), { ...cur, name: 'Deleted user', email: null, phone: null, authEmail: null, googleSub: null, photoV: null, deleted: true, memberships: {}, requested: {} });
    });
    return c.json({ ok: true });
  });
}

export { HttpError };
