import { rateLimit } from '../lib/ratelimit';
import { superLater } from '../lib/superpush';
import { gymTopic, pushTokensPath, topicName, type PushTokensDoc } from '../lib/push';
import { personDetails } from '../lib/person';
import { Broadcast, broadcastRolesOf, pushStatesOf, Deps, notifyDesk, accountRole, branchOf, gymFace, App, authenticate, C, isDeskStaff, roleLocked, isTrainer, syncRosterPhoto, MemberDoc, NoteItem, P, paidOf, readRoster, writeRoster, rosterEntry, stateOf, SubDoc, TenantDoc, UserDoc, userNames } from '../core';
import { bad, conflict, forbidden, HttpError, isUuid, notFound, nowIso, uuid } from '../lib/http';
import { makeQrToken } from '../lib/qr';
import { entryDecision, freezeDaysLeft, validSubs } from '../lib/status';
import { todayIST } from '../lib/dates';
import { body, oneOf, optInt, optStr, str } from '../lib/validate';
import { isYmd } from '../lib/dates';
import { normalizeEmail, normalizePhone } from '../lib/phone';
import { publicUser } from './auth';
import type { PlanDoc } from './members';
import type { ScanLog } from './attendance';
import { offersFor } from './trainers';
import { noticeNotes, noticesFor } from './notices';
import { replyTicket, TICKET_TOPICS, Ticket, getTicket, ticketFlags } from './tickets';

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
    const reqIds = Object.keys(u.requested ?? {});
    const [tenants, rosters, logs, reqTenants, memberDocs] = await Promise.all([
      store.getMany<TenantDoc>(entries.map(([t]) => P.tenant(t))),
      Promise.all(entries.map(([t]) => readRoster(store, t))),
      store.getMany<ScanLog>(entries.map(([t, m]) => P.lastScan(t, m))),
      reqIds.length ? store.getMany<TenantDoc>(reqIds.map(P.tenant)) : Promise.resolve([] as (TenantDoc | null)[]),
      store.getMany<MemberDoc>(entries.map(([t, m]) => P.member(t, m))),
    ]);
    const month = todayIST().slice(0, 7);
    const states = entries.map(([tid, mid], i) => (rosters[i].members[mid] ? stateOf(rosters[i].members[mid]).status : 'NO_PLAN'));
    const [offers, notices] = await Promise.all([
      Promise.all(entries.map(([tid, mid], i) => (tenants[i] ? offersFor(store, tid, 'MEMBER', states[i], branchOf(tenants[i]!, rosters[i].members[mid]?.branchId)) : []))),
      Promise.all(
        entries.map(([tid, mid], i) =>
          tenants[i] ? noticesFor(store, tid, 'MEMBER', states[i], 0, rosters[i].members[mid] ? stateOf(rosters[i].members[mid]).due : 0, branchOf(tenants[i]!, rosters[i].members[mid]?.branchId)) : [],
        ),
      ),
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
          gym: (() => {
            const f = gymFace(tn, e.branchId);
            return { id: tid, name: f.name, gymName: f.gymName, branchName: f.branchName, code: f.code, logoUrl: f.logoUrl, phone: tn.phone, whatsappNumber: tn.whatsappNumber, address: f.address, closed: tn.status === 'CLOSED', appCheckin: f.appCheckin };
          })(),
          ...(() => {
            const bid = branchOf(tn, e.branchId);
            const br = tn.branches.find((x) => x.id === bid);
            return { branch: br ? { id: br.id, name: br.name, address: br.address } : null, multiBranch: tn.branches.length > 1, allowTransfer: tn.allowTransfer ?? false };
          })(),
          status: st.status,
          planName: st.current?.planName ?? st.upcoming?.planName ?? null,
          daysLeft: st.daysLeft,
          endsOn: st.endsOn,
          frozenDays: st.frozenDays ?? 0,
          startsOn: st.current?.startDate ?? st.upcoming?.startDate ?? null,
          visitsThisMonth: logs[i]?.month === month ? logs[i]!.visits : 0,
          lastVisitAt: logs[i]?.lastAllowedAt ?? null,
          due: st.due,
          ...(() => {
            const owing = validSubs(e.subs).filter((x) => x.total > x.paid);
            return { duePaid: owing.reduce((n, x) => n + x.paid, 0), dueTotal: owing.reduce((n, x) => n + x.total, 0), duePlan: owing[0]?.planName ?? null };
          })(),
          entry: entryDecision(st),
          offers: offers[i],
          notices: notices[i],
          locker: memberDocs[i]?.locker ?? null,
          testimonials: { avg: tn.ratingSum?.count ? Math.round((tn.ratingSum.total / tn.ratingSum.count) * 10) / 10 : null, count: tn.ratingSum?.count ?? 0, items: (tn.testimonials ?? []).map(({ name, stars, text }) => ({ name, stars, text })) },
        };
      })
      .filter(Boolean);
    return c.json({ memberships, pendingRequests: reqIds.map((id, i) => (reqTenants[i] ? { id, gym: { id, name: reqTenants[i]!.name } } : null)).filter(Boolean) });
  });

  app.get('/api/v1/me/gym-lookup', async (c) => {
    const u = await authenticate(c);
    await rateLimit(c, 'gymcode', u.id, 20); // gym codes cannot be guessed by trying many
    const { store } = c.var.deps;
    const code = (c.req.query('code') ?? '').trim().toUpperCase();
    const ref0 = code ? await store.get<{ tenantId: string; branchId?: string; expiresAt?: string }>(P.gymCode(code)) : null;
    const ref = ref0 && (!ref0.expiresAt || Date.parse(ref0.expiresAt) > Date.now()) ? ref0 : null; // old branch codes stop after 30 days
    const t = ref ? await store.get<TenantDoc>(P.tenant(ref.tenantId)) : null;
    if (!ref || !t || t.status === 'SUSPENDED' || t.status === 'CLOSED') throw notFound('No gym found with this code');
    const bid = branchOf(t, ref.branchId);
    const br = t.branches.find((b) => b.id === bid) ?? null;
    // Already in another branch of this gym? The app offers a transfer instead of a join.
    const mid = u.memberships?.[ref.tenantId];
    let already: Record<string, unknown> | null = null;
    if (mid) {
      const m = await store.get<MemberDoc>(P.member(ref.tenantId, mid));
      const cur = m ? branchOf(t, m.branchId) : null;
      already = { memberId: mid, branchId: cur, branchName: t.branches.find((b) => b.id === cur)?.name ?? null, sameBranch: cur === bid, allowTransfer: t.allowTransfer ?? false };
    }
    return c.json({
      id: ref.tenantId,
      name: t.name,
      logoUrl: t.logoUrl,
      address: br?.address ?? t.address,
      branch: br ? { id: br.id, name: br.name, address: br.address } : null,
      multiBranch: t.branches.length > 1,
      already,
      branches: t.branches.map((b) => ({ id: b.id, name: b.name, address: b.address })),
    });
  });

  app.post('/api/v1/me/join', async (c) => {
    const u = await authenticate(c);
    await rateLimit(c, 'gymcode', u.id, 20);
    const { store } = c.var.deps;
    const b = body(await c.req.json().catch(() => null));
    const code = str(b, 'gymCode', { max: 20, label: 'the gym code' }).toUpperCase();
    const ref0 = await store.get<{ tenantId: string; branchId?: string; expiresAt?: string }>(P.gymCode(code));
    const ref = ref0 && (!ref0.expiresAt || Date.parse(ref0.expiresAt) > Date.now()) ? ref0 : null; // old branch codes stop after 30 days
    const t = ref ? await store.get<TenantDoc>(P.tenant(ref.tenantId)) : null;
    if (!ref || !t || t.status === 'SUSPENDED' || t.status === 'CLOSED') throw notFound('No gym found with this code');
    const tid = ref.tenantId;
    const as = oneOf(b, 'as', ['MEMBER', 'TRAINER'] as const, true) ?? 'MEMBER';
    // The code decides the branch (each branch has its own code); old codes mean the first branch.
    const asked = optStr(b, 'branchId') ?? null;
    if (asked && !t.branches.some((x) => x.id === asked)) throw bad('Unknown branch');
    const branchId = ref.branchId && t.branches.some((x) => x.id === ref.branchId) ? ref.branchId : asked ?? branchOf(t, null);
    if (as === 'TRAINER') {
      if (isDeskStaff(u)) throw bad('A gym owner cannot join a gym as a trainer');
      if (u.staffOf?.[tid]?.active) throw conflict('You are already a trainer at this gym');
    } else if (u.memberships?.[tid]) {
      // One branch at a time inside the same gym (other gyms are fine).
      const m = await store.get<MemberDoc>(P.member(tid, u.memberships[tid]));
      const cur = m ? branchOf(t, m.branchId) : null;
      const curName = t.branches.find((x) => x.id === cur)?.name ?? t.name;
      const toName = t.branches.find((x) => x.id === branchId)?.name ?? t.name;
      if (cur === branchId) throw new HttpError(409, `You are already a member of ${t.name} (${curName})`, { code: 'ALREADY_MEMBER', sameBranch: true });
      throw new HttpError(
        409,
        t.allowTransfer
          ? `You are a member of ${t.name} (${curName}). A member can be in one branch at a time. Ask for a transfer to ${toName}`
          : `You are a member of ${t.name} (${curName}). A member can be in one branch at a time. Your gym owner has not enabled transfer of your membership. Ask at the front desk or the gym owner`,
        { code: 'ALREADY_MEMBER', sameBranch: false, tenantId: tid, memberId: m?.id ?? null, fromBranchId: cur, toBranchId: branchId, toBranch: toName, allowTransfer: t.allowTransfer ?? false },
      );
    }
    if (!u.phone) throw bad('Add your mobile number in Profile first, so the gym can find you');
    const existing = (await store.query<any>(P.joins(tid), [['userId', u.id], ['status', 'PENDING']])).find((r) => (r.data.kind ?? 'MEMBER') === as);
    if (existing) return c.json({ id: existing.id, ...existing.data }, 201);
    const id = uuid();
    const trainerInfo =
      as === 'TRAINER'
        ? { speciality: optStr(b, 'speciality', { max: 200 }) ?? null, experienceYears: optInt(b, 'experienceYears', { min: 0, max: 60 }) ?? null }
        : {};
    const jr = { userId: u.id, kind: as, branchId, status: 'PENDING', createdAt: nowIso(), decidedById: null, decidedAt: null, ...trainerInfo };
    await store.tx(async (tx) => {
      const cur = (await tx.get<UserDoc>(P.user(u.id)))!;
      tx.set(P.join(tid, id), jr);
      if (as === 'TRAINER') tx.set(P.user(u.id), { ...cur, appRole: 'TRAINER', trainerRequested: { ...(cur.trainerRequested ?? {}), [tid]: true } });
      else tx.set(P.user(u.id), { ...cur, requested: { ...(cur.requested ?? {}), [tid]: true } });
      const tn = await tx.get<TenantDoc>(P.tenant(tid));
      if (tn) await notifyDesk(tx, { tenantId: tid, tenant: tn }, u.id, as === 'TRAINER' ? 'New trainer request' : 'New join request', `${u.name} wants to join ${as === 'TRAINER' ? 'as a trainer' : 'as a member'}. Open Requests to approve.`, branchId ?? null, 'requests');
    });
    return c.json({ id, ...jr }, 201);
  });

  /** "My membership" screen. Shows what the gym entered, and who updated it. */
  /** The member's own check-ins (every one, newest first; the last 30). */
  app.get('/api/v1/me/memberships/:memberId/checkins', async (c) => {
    await authenticate(c);
    const { tenantId, m } = await myMember(c, c.req.param('memberId'));
    const log = await c.var.deps.store.get<ScanLog>(P.lastScan(tenantId, m.id));
    return c.json((log?.recent ?? []).map((r) => ({ at: r.at, result: r.result, reason: r.reason })));
  });

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
      gym: (() => {
        const f = gymFace(tenant, m.branchId);
        return { id: tenantId, name: f.name, gymName: f.gymName, branchName: f.branchName, code: f.code, phone: tenant.phone, whatsappNumber: tenant.whatsappNumber, address: f.address, logoUrl: f.logoUrl };
      })(),
      memberCode: m.memberCode,
      status: st.status,
      daysLeft: st.daysLeft,
      endsOn: st.endsOn,
      frozenDays: st.frozenDays ?? 0,
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
    const { store } = c.var.deps;
    const mid = u.memberships?.[tid];
    const [rows, roster, leads] = await Promise.all([
      store.query<PlanDoc>(P.plans(tid), [['showInApp', true], ['active', true]]),
      mid ? readRoster(store, tid) : Promise.resolve(null),
      store.query<{ planId: string; status: string }>(P.leads(tid), [['userId', u.id], ['status', 'OPEN']]),
    ]);
    const st = mid && roster?.members[mid] ? stateOf(roster.members[mid]) : null;
    const activePlanId = st && ['ACTIVE', 'ENDING_SOON', 'FROZEN'].includes(st.status) ? st.current?.planId ?? null : null;
    const asked = new Set(leads.map((l) => l.data.planId));
    return c.json(
      rows
        .map((r) => ({ id: r.id, name: r.data.name, months: r.data.months, price: r.data.price, joiningFee: r.data.joiningFee, freezeDays: r.data.freezeDays, features: r.data.features, active: r.id === activePlanId, interested: asked.has(r.id) }))
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
    if (b.state !== undefined || b.city !== undefined || b.pincode !== undefined) {
      const cur = { firstName: 'x', lastName: 'x', dob: '2000-01-01', state: u.state, city: u.city, country: u.country ?? 'India', pincode: u.pincode };
      const d = personDetails({ ...cur, ...Object.fromEntries(['state', 'city', 'country', 'pincode'].filter((k) => b[k] !== undefined).map((k) => [k, b[k]])) });
      Object.assign(parts, { state: d.state, city: d.city, country: d.country, pincode: d.pincode });
    }
    // Google sign-up: the extra details are done once DOB, state, city and PIN are in.
    const merged = { ...u, ...parts };
    if (u.detailsNeeded && merged.dob && merged.state && merged.city && merged.pincode) parts.detailsNeeded = false;
    const language = oneOf(b, 'language', ['en', 'hi'] as const, true);
    const roleIn = oneOf(b, 'appRole', ['MEMBER', 'OWNER', 'TRAINER', 'STAFF', 'NONE'] as const, true);
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
    // A trainer's new name shows everywhere: trainer cards and PT records in every gym.
    if (next.name !== u.name) {
      const gyms = Object.entries(u.staffOf ?? {}).filter(([, s]) => s.role === 'TRAINER').map(([tid]) => tid);
      const { store } = c.var.deps;
      await Promise.all(
        gyms.map(async (tid) => {
          const pts = await store.query<{ trainerName: string }>(P.pts(tid), [['trainerId', u.id]]);
          await store.tx(async (t) => {
            const tr = await t.get<{ name: string }>(P.trainer(tid, u.id));
            if (tr) t.set(P.trainer(tid, u.id), { ...tr, name: next.name });
            for (const r of pts) if (r.data.trainerName !== next.name) t.set(P.pt(tid, r.id), { ...r.data, trainerName: next.name });
          });
        }),
      ).catch((e) => console.error('trainer rename', e));
    }
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
    if (email && email !== u.email && email === c.var.deps.superAdminEmail) throw conflict('This email ID already exists');
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
      await t.getMany([P.user(u.id), ...Object.keys(u.memberships ?? {}).map(P.roster)]); // one round trip
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
      await t.getMany([P.user(u.id), ...Object.keys(u.memberships ?? {}).map(P.roster)]);
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
    const text = str(b, 'body', { min: 5, max: 1000, label: 'a message' });
    const { store } = c.var.deps;
    // Context for support: the person's gym (as member, owner or trainer).
    const tenantId = Object.keys(u.memberships ?? {})[0] ?? Object.entries(u.staffOf ?? {}).find(([, s]) => s.active)?.[0] ?? null;
    const memberId = tenantId ? u.memberships?.[tenantId] ?? null : null;
    const gym = tenantId ? await store.get<TenantDoc>(P.tenant(tenantId)) : null;
    const id = uuid();
    const at = nowIso();
    const t = await store.tx(async (tx) => {
      const seq = (await tx.get<{ n: number }>(P.ticketSeq))?.n ?? 1000;
      const number = `GM-${seq + 1}`;
      tx.set(P.ticketSeq, { n: seq + 1 });
      const doc: Ticket = {
        number,
        role: accountRole(u) ?? null,
        gymName: gym?.name ?? null,
        tenantId,
        memberId,
        userId: u.id,
        topic,
        subject,
        status: 'OPEN',
        routedTo: 'GYMMANTRA',
        createdAt: at,
        updatedAt: at,
        messages: [{ id: uuid(), authorId: u.id, fromStaff: false, body: text, attachmentUrl: null, createdAt: at }],
      };
      tx.create(P.ticket(id), doc);
      return doc;
    });
    superLater(c, 'tickets', 'New support ticket', `${u.name}: ${subject}`, `ticket:${id}`);
    return c.json({ id, ...t }, 201);
  });

  app.get('/api/v1/me/tickets', async (c) => {
    const u = await authenticate(c);
    const rows = await c.var.deps.store.query<Ticket>(P.tickets, [['userId', u.id]]);
    return c.json(
      rows
        .map((r) => ({ id: r.id, ...r.data, ...ticketFlags(r.data), messages: r.data.messages.slice(-1) }))
        .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1)),
    );
  });

  app.get('/api/v1/me/tickets/:id', async (c) => {
    const u = await authenticate(c);
    return c.json(await getTicket(c, c.req.param('id'), (t) => t.userId === u.id));
  });

  app.post('/api/v1/me/tickets/:id/messages', async (c) => {
    const u = await authenticate(c);
    const out = await replyTicket(c, c.req.param('id'), (t) => t.userId === u.id, false);
    superLater(c, 'tickets', 'Ticket reply', `${u.name} wrote on their ticket`, `ticket:${c.req.param('id')}`);
    return c.json(out, 201);
  });

  app.get('/api/v1/me/notifications', async (c) => {
    const u = await authenticate(c);
    const { store } = c.var.deps;
    const doc = await store.get<{ items: NoteItem[]; noticesReadAt?: string }>(P.notes(u.id));
    const notices = await noticeNotes(store, u, doc?.noticesReadAt ?? null);
    // Messages from GymMantra (super admin) to this person's role(s) and state.
    const bc = await store.get<{ items: Broadcast[] }>(P.broadcasts);
    const mine = broadcastRolesOf(u);
    const since = u.createdAt ?? '';
    const states = (bc?.items ?? []).some((x) => x.state) ? await pushStatesOf(store, u) : [];
    const readAt = doc?.noticesReadAt ?? null;
    const fromGm = (bc?.items ?? [])
      .filter((x) => x.createdAt >= since && (x.roles.includes('ALL') || x.roles.some((r) => mine.includes(r))) && (!x.state || states.includes(x.state)))
      .map((x) => ({ id: `bc_${x.id}`, tenantId: null, title: x.title, body: x.body, createdAt: x.createdAt, readAt: readAt && readAt >= x.createdAt ? readAt : null, fromGymMantra: true }));
    // Gym owners and staff see the notes of the branch they picked in the app (x-branch-id).
    const branch = c.req.header('x-branch-id');
    const items = (doc?.items ?? []).filter((n) => !branch || !n.branchId || !u.staffOf?.[n.tenantId ?? '']?.active || n.branchId === branch);
    return c.json([...items, ...notices, ...fromGm].sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)).slice(0, 60));
  });

  /** The phone's notification token (one person can use a few phones). */
  app.post('/api/v1/me/push-token', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const token = str(b, 'token', { min: 20, max: 4096, label: 'token' });
    const appName = optStr(b, 'app', { max: 20 }) ?? 'main';
    await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<PushTokensDoc>(pushTokensPath(u.id))) ?? { tokens: [] };
      t.set(pushTokensPath(u.id), { tokens: [{ token, at: nowIso(), app: appName }, ...cur.tokens.filter((x) => x.token !== token)].slice(0, 5) });
    });
    return c.json({ ok: true });
  });
  app.post('/api/v1/me/push-token/remove', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const token = str(b, 'token', { max: 4096, label: 'token' });
    await c.var.deps.store.tx(async (t) => {
      const cur = await t.get<PushTokensDoc>(pushTokensPath(u.id));
      if (cur) t.set(pushTokensPath(u.id), { tokens: cur.tokens.filter((x) => x.token !== token) });
    });
    return c.json({ ok: true });
  });
  /** Topics this phone should listen to: everyone, their roles, their state, their gyms' branches. */
  app.get('/api/v1/me/push-topics', async (c) => {
    const u = await authenticate(c);
    const { store } = c.var.deps;
    const topics = new Set<string>(['all']);
    for (const r of broadcastRolesOf(u)) topics.add(`role_${r}`);
    for (const st of await pushStatesOf(store, u)) topics.add(topicName(`state_${st}`));
    const memberGyms = Object.entries(u.memberships ?? {});
    const trainerGyms = Object.entries(u.staffOf ?? {}).filter(([, s]) => s.active && s.role === 'TRAINER').map(([t]) => t);
    const tenants = await store.getMany<TenantDoc>([...memberGyms.map(([t]) => P.tenant(t)), ...trainerGyms.map((t) => P.tenant(t))]);
    const rosters = await Promise.all(memberGyms.map(([t]) => readRoster(store, t)));
    memberGyms.forEach(([tid, mid], i) => {
      const tn = tenants[i];
      if (tn) topics.add(gymTopic(tid, branchOf(tn, rosters[i].members[mid]?.branchId), 'M'));
    });
    const profiles = await store.getMany<{ branchId?: string | null }>(trainerGyms.map((t) => P.trainer(t, u.id)));
    trainerGyms.forEach((tid, i) => {
      const tn = tenants[memberGyms.length + i];
      if (tn) topics.add(gymTopic(tid, branchOf(tn, profiles[i]?.branchId), 'T'));
    });
    return c.json({ topics: [...topics] });
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
    const b = (await c.req.json().catch(() => null)) as { password?: string } | null;
    await removeAccount(c.var.deps, u.id, { password: typeof b?.password === 'string' ? b.password : null });
    return c.json({ ok: true });
  });
}

/**
 * Deletes a person's GymMantra account (they asked, or the super admin did it).
 * - Their login is deleted too (when the password is known), so the same email and mobile can sign up again.
 * - Gyms keep their records but see the person as "No longer available" and can delete them.
 * - Gym owners and front desk staff must be removed from their gym first; trainers can go straight away.
 */
export async function removeAccount(deps: Deps, uid: string, opts: { password?: string | null; bySuper?: boolean }) {
  const { store, identity } = deps;
  const u = await store.get<UserDoc>(P.user(uid));
  if (!u || u.deleted) throw notFound('Account not found');
  if (Object.values(u.staffOf ?? {}).some((s) => s.active && s.role !== 'TRAINER')) {
    throw forbidden(opts.bySuper ? 'This person runs a gym (owner or front desk). Remove them from the gym first' : 'Gym owner and front desk accounts cannot be deleted here. Ask GymMantra support');
  }
  // Their login: proven with the password (or the gym-made first password) so it can be deleted.
  let idToken: string | null = null;
  if (u.authEmail) {
    const pw = opts.password || u.initPw || null;
    if (!pw && !opts.bySuper) throw bad('Enter your password to delete your account');
    if (pw) {
      try {
        idToken = (await identity.signIn(u.authEmail, pw)).idToken;
      } catch {
        if (!opts.bySuper && opts.password) throw bad('Wrong password');
      }
    }
  }
  // Gyms where they are a member: "No longer available".
  for (const [tid, mid] of Object.entries(u.memberships ?? {})) {
    await store.tx(async (t) => {
      const m = await t.get<MemberDoc>(P.member(tid, mid));
      const roster = await readRoster(t, tid);
      if (m) t.set(P.member(tid, mid), { ...m, userId: null, gone: true });
      if (roster.members[mid]) {
        roster.members[mid] = { ...roster.members[mid], userId: null, photoV: null, gone: true };
        writeRoster(t, tid, roster);
      }
    });
  }
  // Gyms where they are a trainer: the owner still sees them, marked "No longer available".
  for (const [tid, st] of Object.entries(u.staffOf ?? {})) {
    if (st.role !== 'TRAINER' || !st.active) continue;
    await store.tx(async (t) => {
      const [tr, sd] = await t.getMany<Record<string, unknown>>([P.trainer(tid, uid), P.staff(tid, uid)]);
      if (tr) t.set(P.trainer(tid, uid), { ...tr, gone: true, visible: false });
      if (sd) t.set(P.staff(tid, uid), { ...sd, active: false });
    });
  }
  await store.tx(async (t) => {
    const cur = (await t.get<UserDoc>(P.user(uid)))!;
    if (cur.phone) {
      const ref = await t.get<{ uid: string }>(P.phone(cur.phone));
      if (ref?.uid === uid) t.delete(P.phone(cur.phone));
    }
    if (cur.googleSub) t.delete(`googleSubs/${cur.googleSub}`);
    t.delete(P.photo(uid));
    t.delete(P.notes(uid));
    t.set(P.user(uid), {
      ...cur,
      name: 'Deleted user',
      email: null,
      phone: null,
      authEmail: null,
      googleSub: null,
      photoV: null,
      initPw: null,
      deleted: true,
      deletedAt: nowIso(),
      memberships: {},
      requested: {},
      trainerRequested: {},
      staffOf: Object.fromEntries(Object.entries(cur.staffOf ?? {}).map(([k, v]) => [k, { ...v, active: false }])),
    } as UserDoc);
  });
  if (idToken) await identity.deleteAccount(idToken).catch(() => {});
}

export { HttpError };
