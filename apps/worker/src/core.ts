import type { Context, Hono } from 'hono';
import { getCookie, setCookie, deleteCookie } from 'hono/cookie';
import { jwtVerify, SignJWT } from 'jose';
import type { Identity } from './identity';
import { addDays, todayIST } from './lib/dates';
import { forbidden, HttpError, nowIso, unauthorized, uuid } from './lib/http';
import { computeState, MemberState, SubLike } from './lib/status';
import type { Doc, Reader, Store, Tx } from './store/store';

// ---------- Data shapes (Firestore documents) ----------

export type Role = 'OWNER' | 'FRONT_DESK' | 'TRAINER';
/** Staff who run the gym desk (trainers are staff too, but see only their own PT clients). */
export const DESK_ROLES: Role[] = ['OWNER', 'FRONT_DESK'];

export interface UserDoc {
  name: string;
  email: string | null;
  authEmail: string | null; // email used for the Firebase password account
  fbUid: string | null;
  phone: string | null;
  googleSub: string | null;
  photoV: number | null; // photo version; null = no photo
  language: string;
  isSuperAdmin: boolean;
  failed: number;
  lockedUntil: string | null;
  deleted?: boolean;
  createdAt: string;
  memberships: Record<string, string>; // tenantId -> memberId
  requested: Record<string, boolean>; // tenantIds with join requests (as a member)
  trainerRequested?: Record<string, boolean>; // tenantIds with join requests as a trainer
  appRole?: 'MEMBER' | 'OWNER' | 'TRAINER' | null; // what the person chose in the app
  staffOf: Record<string, { role: Role; branchIds: string[]; active: boolean }>;
}

export interface Branch {
  id: string;
  name: string;
  address: string | null;
  hours: string | null;
  createdAt: string;
}

export interface TenantDoc {
  name: string;
  gymCode: string;
  logoUrl: string | null;
  phone: string | null;
  address: string | null;
  whatsappNumber: string | null;
  status: 'TRIAL' | 'ACTIVE' | 'SUSPENDED';
  verified: boolean;
  trialEndsAt: string | null;
  saasPlanId: string | null;
  customMonthlyPrice: number | null;
  allowEntryWhenDue: boolean;
  memberCodePrefix: string;
  nextMemberNumber: number;
  memberCount: number;
  branches: Branch[];
  createdAt: string;
}

export interface MemberDoc {
  id: string;
  userId: string | null;
  memberCode: string;
  name: string;
  phone: string;
  email: string | null;
  gender: string | null;
  branchId: string | null;
  joinedOn: string;
  notes: string | null;
  archived: boolean;
  createdAt: string;
}

export interface Payment {
  id: string;
  amount: number;
  mode: string;
  receivedById: string;
  receivedAt: string;
  note: string | null;
}
export interface Freeze {
  id: string;
  startDate: string;
  days: number;
  endedOn: string | null;
  reason: string | null;
  createdById: string;
  createdAt: string;
}

/** A membership. Its terms never change; payments and freezes are appended. */
export interface SubDoc {
  id: string;
  memberId: string;
  planId: string | null;
  planName: string;
  months: number;
  startDate: string;
  endDate: string;
  price: number;
  joiningFee: number;
  discount: number;
  total: number;
  freezeDaysAllowed: number;
  allowEntryWhileDue: boolean;
  kind: 'NEW' | 'RENEWAL' | 'CORRECTION';
  replacesId: string | null;
  note: string | null;
  createdById: string;
  createdAt: string;
  carriedPaid: number; // money received on the entry this one corrected
  payments: Payment[];
  freezes: Freeze[];
}

/** Member list for one gym in a single document, so lists and dashboards cost one read. */
export interface RosterEntry {
  name: string;
  phone: string;
  memberCode: string;
  branchId: string | null;
  userId: string | null;
  archived: boolean;
  photoV?: number | null; // the linked app user's photo version, so lists can show photos
  subs: RosterSub[];
}
export type RosterSub = SubLike & { planId: string | null; planName: string; months: number };
export interface Roster {
  members: Record<string, RosterEntry>;
}

// ---------- Paths ----------

export const P = {
  user: (uid: string) => `users/${uid}`,
  phone: (phone: string) => `phones/${phone}`,
  gymCode: (code: string) => `gymCodes/${code}`,
  tenant: (t: string) => `tenants/${t}`,
  roster: (t: string) => `tenants/${t}/roster/main`,
  members: (t: string) => `tenants/${t}/members`,
  member: (t: string, m: string) => `tenants/${t}/members/${m}`,
  subs: (t: string) => `tenants/${t}/subs`,
  sub: (t: string, s: string) => `tenants/${t}/subs/${s}`,
  plans: (t: string) => `tenants/${t}/plans`,
  plan: (t: string, p: string) => `tenants/${t}/plans/${p}`,
  staffCol: (t: string) => `tenants/${t}/staff`,
  staff: (t: string, uid: string) => `tenants/${t}/staff/${uid}`,
  joins: (t: string) => `tenants/${t}/joinRequests`,
  trainers: (t: string) => `tenants/${t}/trainers`,
  trainer: (t: string, uid: string) => `tenants/${t}/trainers/${uid}`,
  offers: (t: string) => `tenants/${t}/offers`,
  program: (t: string, memberId: string) => `tenants/${t}/programs/${memberId}`,
  pts: (t: string) => `tenants/${t}/pt`,
  pt: (t: string, id: string) => `tenants/${t}/pt/${id}`,
  payouts: (t: string) => `tenants/${t}/ptPayouts`,
  payout: (t: string, id: string) => `tenants/${t}/ptPayouts/${id}`,
  offer: (t: string, id: string) => `tenants/${t}/offers/${id}`,
  join: (t: string, j: string) => `tenants/${t}/joinRequests/${j}`,
  attendance: (t: string) => `tenants/${t}/attendance`,
  attendanceEv: (t: string, e: string) => `tenants/${t}/attendance/${e}`,
  lastScan: (t: string, m: string) => `tenants/${t}/lastScan/${m}`,
  daily: (t: string, day: string) => `tenants/${t}/daily/${day}`,
  audit: (t: string) => `tenants/${t}/audit`,
  tickets: 'tickets',
  ticket: (id: string) => `tickets/${id}`,
  notes: (uid: string) => `notifications/${uid}`,
  photo: (uid: string) => `photos/${uid}`,
  saasPlans: 'saasPlans',
  saasPlan: (id: string) => `saasPlans/${id}`,
  platform: 'settings/platform',
  secrets: 'settings/secrets',
  stats: 'settings/stats',
  platformAudit: 'platformAudit',
};

// ---------- Request context ----------

export interface Deps {
  store: Store;
  identity: Identity;
  superAdminEmail: string;
  googleClientId: string | null;
  secure: boolean;
  /** Reads a JSON file from the static assets (exercise list). */
  assetJson: (path: string) => Promise<any>;
}

export interface Secrets {
  jwt: string;
  qr: string;
}

export type AuthUser = UserDoc & { id: string };
export type Env = { Variables: { deps: Deps; secrets: Secrets; user: AuthUser } };
export type C = Context<Env>;
export type App = Hono<Env>;

const randomSecret = () => {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b));
};

let secretCache: Secrets | null = null;
/** Signing secrets are created once and kept in Firestore, so setup needs no extra keys. */
export async function loadSecrets(store: Store): Promise<Secrets> {
  if (secretCache) return secretCache;
  let s = await store.get<Secrets>(P.secrets);
  if (!s) {
    s = await store.tx(async (t) => {
      const cur = await t.get<Secrets>(P.secrets);
      if (cur) return cur;
      const fresh = { jwt: randomSecret(), qr: randomSecret() };
      t.set(P.secrets, fresh);
      return fresh;
    });
  }
  secretCache = s;
  return s;
}
export function resetSecretCache() {
  secretCache = null;
}

// ---------- Sessions ----------

export const SESSION_COOKIE = 'gm_session';
export const SESSION_DAYS = 30;
const key = (s: string) => new TextEncoder().encode(s);

export async function issueSession(c: C, uid: string) {
  const token = await new SignJWT({}).setProtectedHeader({ alg: 'HS256' }).setSubject(uid).setIssuedAt().setExpirationTime(`${SESSION_DAYS}d`).sign(key(c.var.secrets.jwt));
  setCookie(c, SESSION_COOKIE, token, { httpOnly: true, sameSite: 'Lax', secure: c.var.deps.secure, path: '/', maxAge: SESSION_DAYS * 86400 });
  return token;
}
export function clearSession(c: C) {
  deleteCookie(c, SESSION_COOKIE, { path: '/' });
}

/** Loads the signed-in user. Cookie sessions must send x-gm-client on writes (CSRF). */
export async function authenticate(c: C): Promise<AuthUser> {
  const h = c.req.header('authorization');
  let token: string | undefined;
  let viaCookie = false;
  if (h?.startsWith('Bearer ')) token = h.slice(7);
  else {
    token = getCookie(c, SESSION_COOKIE);
    viaCookie = !!token;
  }
  if (!token) throw unauthorized();
  if (viaCookie && !['GET', 'HEAD', 'OPTIONS'].includes(c.req.method) && !c.req.header('x-gm-client')) throw forbidden('Missing client header');
  let uid: string;
  try {
    const { payload } = await jwtVerify(token, key(c.var.secrets.jwt));
    uid = String(payload.sub);
  } catch {
    throw unauthorized('Session expired. Please log in again');
  }
  const u = await c.var.deps.store.get<UserDoc>(P.user(uid));
  if (!u || u.deleted) throw unauthorized();
  const user = { ...u, id: uid };
  // Owner decision: the GymMantra admin uses the website (and later the admin app), not the gym app.
  if (isMobile(c) && isWebOnly(user)) throw unauthorized(WEB_ONLY_MESSAGE);
  c.set('user', user);
  return user;
}

export const WEB_ONLY_MESSAGE = 'This is the GymMantra super admin account. Please use the GymMantra website to log in.';
export const isMobile = (c: C) => c.req.header('x-gm-client') === 'mobile';
export const isWebOnly = (u: Pick<UserDoc, 'isSuperAdmin' | 'staffOf'>) => u.isSuperAdmin;

/** True if the person runs a gym (owner or front desk) anywhere. */
export const isDeskStaff = (u: Pick<UserDoc, 'staffOf'>) => Object.values(u.staffOf ?? {}).some((s) => s.active && DESK_ROLES.includes(s.role));
/** True if the person is a trainer at any gym. */
export const isTrainer = (u: Pick<UserDoc, 'staffOf'>) => Object.values(u.staffOf ?? {}).some((s) => s.active && s.role === 'TRAINER');

export function requireSuper(c: C) {
  if (!c.var.user.isSuperAdmin) throw forbidden('Super admin only');
}

export interface GymCtx {
  tenantId: string;
  role: Role;
  branchIds: string[];
  tenant: TenantDoc;
}

/**
 * The gym this staff user is working in. The client may name one of its gyms
 * with x-gym-id, but only gyms where the user really is active staff count.
 */
export async function gymOf(c: C, ...roles: Role[]): Promise<GymCtx> {
  const u = c.var.user;
  // Trainers reach only endpoints that ask for 'TRAINER' explicitly.
  const active = Object.entries(u.staffOf ?? {}).filter(([, s]) => s.active && (s.role !== 'TRAINER' || roles.includes('TRAINER')));
  if (!active.length) throw forbidden('You are not staff of this gym');
  const wanted = c.req.header('x-gym-id');
  const pick = wanted ? active.find(([t]) => t === wanted) : active[0];
  if (!pick) throw forbidden('You are not staff of this gym');
  const [tenantId, s] = pick;
  const tenant = await c.var.deps.store.get<TenantDoc>(P.tenant(tenantId));
  if (!tenant) throw forbidden('Gym not found');
  if (tenant.status === 'SUSPENDED') throw forbidden('This gym is suspended. Contact GymMantra support');
  if (roles.length && !roles.includes(s.role)) throw forbidden('Only the gym owner can do this');
  return { tenantId, role: s.role, branchIds: s.branchIds ?? [], tenant };
}

export function canSeeBranch(g: GymCtx, branchId: string | null) {
  return g.role === 'OWNER' || !g.branchIds.length || branchId === null || g.branchIds.includes(branchId);
}

// ---------- Audit and notifications ----------

export function audit(t: Tx, tenantId: string | null, actorId: string, action: string, entity: string, entityId: string, before?: unknown, after?: unknown) {
  const id = uuid();
  const at = nowIso();
  const doc: Doc = { tenantId, actorId, action, entity, entityId, before: before ?? null, after: after ?? null, createdAt: at, month: at.slice(0, 7) };
  t.set(tenantId ? `${P.audit(tenantId)}/${id}` : `${P.platformAudit}/${id}`, JSON.parse(JSON.stringify(doc)));
}

export interface NoteItem {
  id: string;
  tenantId: string | null;
  title: string;
  body: string;
  createdAt: string;
  readAt: string | null;
}

/** In-app notification (kept as the last 50 per user in one document). */
export async function notify(t: Tx, userId: string | null | undefined, tenantId: string | null, title: string, body: string) {
  if (!userId) return;
  const cur = (await t.get<{ items: NoteItem[] }>(P.notes(userId)))?.items ?? [];
  t.set(P.notes(userId), { items: [{ id: uuid(), tenantId, title, body, createdAt: nowIso(), readAt: null }, ...cur].slice(0, 50) });
}

// ---------- Roster ----------

export function paidOf(s: Pick<SubDoc, 'carriedPaid' | 'payments'>) {
  return (s.carriedPaid ?? 0) + s.payments.reduce((n, p) => n + p.amount, 0);
}

export function toRosterSub(s: SubDoc): RosterSub {
  return {
    id: s.id,
    replacesId: s.replacesId,
    planId: s.planId,
    planName: s.planName,
    months: s.months,
    startDate: s.startDate,
    endDate: s.endDate,
    total: s.total,
    paid: paidOf(s),
    allowEntryWhileDue: s.allowEntryWhileDue,
    freezeDaysAllowed: s.freezeDaysAllowed,
    createdAt: s.createdAt,
    freezes: s.freezes.map((f) => ({ id: f.id, startDate: f.startDate, days: f.days, endedOn: f.endedOn })),
  };
}

export async function readRoster(r: Reader, tenantId: string): Promise<Roster> {
  return (await r.get<Roster>(P.roster(tenantId))) ?? { members: {} };
}

/** Copies a user's photo version into every gym roster where they are a member. */
export async function syncRosterPhoto(t: Tx, u: Pick<UserDoc, 'memberships'>, photoV: number | null) {
  for (const [tid, mid] of Object.entries(u.memberships ?? {})) {
    const r = await t.get<Roster>(P.roster(tid));
    if (!r?.members[mid]) continue;
    r.members[mid] = { ...r.members[mid], photoV };
    t.set(P.roster(tid), r);
  }
}

/** Puts a membership into the roster. A correction removes the entry it replaces; very old entries are dropped. */
export function rosterPutSub(roster: Roster, memberId: string, s: SubDoc) {
  const e = roster.members[memberId];
  if (!e) return;
  const rs = toRosterSub(s);
  let subs = e.subs.filter((x) => x.id !== s.id && x.id !== s.replacesId);
  subs.push(rs);
  const cutoff = addDays(todayIST(), -730);
  subs.sort((a, b) => (a.startDate < b.startDate ? -1 : 1));
  if (subs.length > 1) subs = subs.filter((x, i) => i === subs.length - 1 || x.endDate >= cutoff);
  e.subs = subs;
}

export function rosterEntry(m: MemberDoc): RosterEntry {
  return { name: m.name, phone: m.phone, memberCode: m.memberCode, branchId: m.branchId, userId: m.userId, archived: m.archived, subs: [] };
}

export function stateOf(e: RosterEntry, today = todayIST()): MemberState<RosterSub> {
  return computeState(e.subs, today);
}

/** Today's counters for the dashboard. */
export async function bumpDaily(t: Tx, tenantId: string, patch: Partial<Record<'collected' | 'payments' | 'checkins' | 'blocked', number>>) {
  const day = todayIST();
  const cur = (await t.get<Record<string, number>>(P.daily(tenantId, day))) ?? { collected: 0, payments: 0, checkins: 0, blocked: 0 };
  for (const [k, v] of Object.entries(patch)) cur[k] = (cur[k] ?? 0) + (v ?? 0);
  t.set(P.daily(tenantId, day), cur);
}

export async function userNames(r: Reader, ids: string[]): Promise<Map<string, string>> {
  const uniq = [...new Set(ids.filter(Boolean))];
  const docs = await r.getMany<UserDoc>(uniq.map(P.user));
  return new Map(uniq.map((id, i) => [id, docs[i]?.name ?? 'Staff']));
}

export function json(c: C, data: unknown, status = 200) {
  return c.json(data as any, status as any);
}

export { HttpError };
