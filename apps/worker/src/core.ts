import { queuePush } from './lib/push';
import type { ServiceAccount } from './lib/gauth';
import type { Context, Hono } from 'hono';
import { edgeGet, edgePut } from './lib/edge';
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
  sessionV?: number; // goes up when the password changes: older logins on other phones stop working
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
  appRole?: 'MEMBER' | 'OWNER' | 'TRAINER' | 'STAFF' | null; // what the person chose in the app
  firstName?: string | null;
  middleName?: string | null;
  lastName?: string | null;
  dob?: string | null; // YYYY-MM-DD
  gender?: 'male' | 'female' | 'other' | null;
  address?: string | null;
  state?: string | null;
  city?: string | null;
  country?: string | null;
  pincode?: string | null;
  createdByGym?: { tenantId: string; gymName: string } | null; // gym owner added this member; they set a password from the email link
  mustSetPassword?: boolean; // gym-made account: first login (e.g. Google) asks for a password
  initPw?: string | null; // server-only random first password of a gym-made account (never sent to apps)
  detailsNeeded?: boolean; // signed up with Google: DOB, state, city, PIN still to fill
  staffOf: Record<string, { role: Role; branchIds: string[]; active: boolean; rights?: string[] }>;
}

export interface Branch {
  id: string;
  code?: string; // join code of this branch (the first branch uses the gym code)
  name: string;
  address: string | null;
  hours: string | null;
  createdAt: string;
  // Full address and GST of this branch (each branch may have its own GSTIN)
  addressLine?: string | null;
  city?: string | null;
  state?: string | null;
  stateCode?: string | null;
  pincode?: string | null;
  gstin?: string | null;
  logoUrl?: string | null; // own logo; null → the gym's logo
  appCheckin?: boolean; // false: this branch uses its own entry system (no check-in from the app)
}

export interface TenantDoc {
  name: string;
  gymCode: string;
  logoUrl: string | null;
  phone: string | null;
  address: string | null;
  whatsappNumber: string | null;
  status: 'TRIAL' | 'ACTIVE' | 'SUSPENDED' | 'CLOSED';
  ratingSum?: { total: number; count: number }; // old: whole-gym rating (now ratingSums per branch; this counts for the main branch until then)
  ratingSums?: Record<string, { total: number; count: number }>; // gym rating per branch (routes/ratings.ts)
  testimonials?: { userId: string; name: string; stars: number; text: string; branchId?: string | null; photoV?: number | null }[]; // ratings the owner chose to show (each in its branch)
  closedAt?: string | null; // super admin closed the gym (can reopen within 30 days)
  closedStaff?: { uid: string; role: Role; branchIds: string[]; rights?: string[] }[];
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
  // Full address (required for new gyms; decides CGST+SGST or IGST once GymMantra charges GST)
  addressLine?: string | null;
  city?: string | null;
  state?: string | null;
  stateCode?: string | null;
  pincode?: string | null;
  gstin?: string | null;
  // GymMantra subscription
  planCycle?: 'MONTHLY' | 'ANNUAL' | null;
  planEndsAt?: string | null;
  allowTransfer?: boolean; // members may ask to move their membership to another branch
  dueRemindedAt?: string | null; // last time the owner sent due reminders
  payFails?: string[]; // times plan payments were rejected (last 24 h decide the lock)
  payLockedUntil?: string | null; // 3 failed payments in 24 h stop new payments till then
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
  firstName?: string | null;
  middleName?: string | null;
  lastName?: string | null;
  locker?: { branchId: string; n: number; from: string; to: string }; // routes/lockers.ts
  dob?: string | null;
  state?: string | null;
  city?: string | null;
  country?: string | null;
  pincode?: string | null;
  gone?: boolean; // the person deleted their GymMantra account ("No longer available")
  removed?: boolean; // the gym deleted this member (kept only for money records)
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
  gone?: boolean; // the person deleted their GymMantra account
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
  notices: (t: string) => `tenants/${t}/notices`,
  program: (t: string, memberId: string) => `tenants/${t}/programs/${memberId}`,
  pts: (t: string) => `tenants/${t}/pt`,
  pt: (t: string, id: string) => `tenants/${t}/pt/${id}`,
  payouts: (t: string) => `tenants/${t}/ptPayouts`,
  payout: (t: string, id: string) => `tenants/${t}/ptPayouts/${id}`,
  offer: (t: string, id: string) => `tenants/${t}/offers/${id}`,
  notice: (t: string, id: string) => `tenants/${t}/notices/${id}`,
  leads: (t: string) => `tenants/${t}/leads`,
  lead: (t: string, id: string) => `tenants/${t}/leads/${id}`,
  checkin: (t: string) => `tenants/${t}/private/checkin`,
  transfers: (t: string) => `tenants/${t}/transfers`,
  transfer: (t: string, id: string) => `tenants/${t}/transfers/${id}`,
  trainerDays: (t: string, uid: string) => `tenants/${t}/trainerDays/${uid}`,
  file: (t: string, id: string) => `tenants/${t}/files/${id}`,
  filePart: (t: string, id: string, n: number) => `tenants/${t}/files/${id}/parts/${n}`,
  join: (t: string, j: string) => `tenants/${t}/joinRequests/${j}`,
  attendance: (t: string) => `tenants/${t}/attendance`,
  attendanceEv: (t: string, e: string) => `tenants/${t}/attendance/${e}`,
  lastScan: (t: string, m: string) => `tenants/${t}/lastScan/${m}`,
  daily: (t: string, day: string) => `tenants/${t}/daily/${day}`,
  audit: (t: string) => `tenants/${t}/audit`,
  tickets: 'tickets',
  ticket: (id: string) => `tickets/${id}`,
  ticketSeq: 'settings/ticketSeq',
  offerImage: (t: string, id: string) => `tenants/${t}/offerImages/${id}`,
  logo: (t: string, key: string) => `tenants/${t}/logos/${key}`, // key = 'gym' or a branch id
  notes: (uid: string) => `notifications/${uid}`,
  photo: (uid: string) => `photos/${uid}`,
  saasPlans: 'saasPlans',
  bills: (t: string) => `tenants/${t}/bills`,
  bill: (t: string, id: string) => `tenants/${t}/bills/${id}`,
  ads: 'ads',
  ad: (id: string) => `ads/${id}`,
  adImage: (id: string) => `adImages/${id}`,
  saasPlan: (id: string) => `saasPlans/${id}`,
  platform: 'settings/platform',
  secrets: 'settings/secrets',
  stats: 'settings/stats',
  platformAudit: 'platformAudit',
  broadcasts: 'settings/broadcasts',
  coupons: 'coupons',
  coupon: (id: string) => `coupons/${id}`,
  couponCode: (code: string) => `couponCodes/${code}`,
  planPayments: 'planPayments',
  planPayment: (id: string) => `planPayments/${id}`,
  signature: 'settings/signature',
  platformDaily: (day: string) => `platformDaily/${day}`,
  enquiries: (t: string) => `tenants/${t}/enquiries`,
  enquiry: (t: string, id: string) => `tenants/${t}/enquiries/${id}`,
  salaryCfg: (t: string, uid: string) => `tenants/${t}/salary/${uid}`,
  salaryCfgs: (t: string) => `tenants/${t}/salary`,
  salaryMonth: (t: string, uid: string, month: string) => `tenants/${t}/salaryMonths/${uid}_${month}`,
  lockers: (t: string, branchId: string) => `tenants/${t}/lockers/${branchId}`,
  trainerRatings: (t: string) => `tenants/${t}/trainerRatings`,
  trainerRating: (t: string, trainerId: string, userId: string, month: string) => `tenants/${t}/trainerRatings/${trainerId}_${userId}_${month}`,
  gymRatings: (t: string) => `tenants/${t}/gymRatings`,
  gymRating: (t: string, userId: string) => `tenants/${t}/gymRatings/${userId}`,
  devices: 'devices',
  device: (serial: string) => `devices/${serial}`,
  scheduled: 'scheduled',
  scheduledItem: (id: string) => `scheduled/${id}`,
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
  /** Firebase service account for phone notifications (null = off). */
  serviceAccount?: ServiceAccount | null;
  /** Nightly backup to GitHub (routes/backup.ts): checks the GitHub Actions login and gives the encryption key. */
  backup?: { verify(token: string, workflow: 'backup' | 'restore' | 'migrate'): Promise<boolean>; key(): Promise<CryptoKey> } | null;
  /** Moving the data from Firestore into D1 (routes/backup.ts, .github/workflows/migrate.yml). */
  migrate?: { from: Store; to: { load(rows: { p: string; d: Record<string, unknown> }[], keepNewer: boolean): Promise<void> } } | null;
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
  const shared = await edgeGet<Secrets>('secrets');
  if (shared?.jwt) {
    secretCache = shared;
    return shared;
  }
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
  await edgePut('secrets', s, 3600);
  return s;
}
export function resetSecretCache() {
  secretCache = null;
}

// ---------- Sessions ----------

export const SESSION_COOKIE = 'gm_session';
export const SESSION_DAYS = 30;
const key = (s: string) => new TextEncoder().encode(s);

export async function issueSession(c: C, uid: string, sessionV?: number) {
  const v = sessionV ?? (await c.var.deps.store.get<UserDoc>(P.user(uid)))?.sessionV ?? 0;
  const token = await new SignJWT({ v }).setProtectedHeader({ alg: 'HS256' }).setSubject(uid).setIssuedAt().setExpirationTime(`${SESSION_DAYS}d`).sign(key(c.var.secrets.jwt));
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
  let v = 0;
  try {
    const { payload } = await jwtVerify(token, key(c.var.secrets.jwt));
    uid = String(payload.sub);
    v = typeof payload.v === 'number' ? payload.v : 0;
  } catch {
    throw unauthorized('Session expired. Please log in again');
  }
  const u = await c.var.deps.store.get<UserDoc>(P.user(uid));
  if (!u || u.deleted) throw unauthorized();
  // The password was changed after this login: this phone has to log in again.
  if ((u.sessionV ?? 0) !== v) throw unauthorized('Your password was changed. Please log in again');
  const user = { ...u, id: uid };
  // Owner decision: the GymMantra admin uses the website (and later the admin app), not the gym app.
  if (isMobile(c) && isWebOnly(user)) throw unauthorized(WEB_ONLY_MESSAGE);
  if (isAdminApp(c) && !user.isSuperAdmin) throw unauthorized(ADMIN_ONLY_MESSAGE);
  c.set('user', user);
  return user;
}

export const WEB_ONLY_MESSAGE = 'This is the GymMantra super admin account. Please use the GymMantra website to log in.';
export const isMobile = (c: C) => c.req.header('x-gm-client') === 'mobile';
/** The separate GymMantra Admin app (super admin only). */
export const isAdminApp = (c: C) => c.req.header('x-gm-client') === 'admin-app';
export const ADMIN_ONLY_MESSAGE = 'This app is only for the GymMantra admin. Gym owners, trainers and members use the GymMantra app.';
export const isWebOnly = (u: Pick<UserDoc, 'isSuperAdmin' | 'staffOf'>) => u.isSuperAdmin;

/** True if the person runs a gym (owner or front desk) anywhere. */
export const isDeskStaff = (u: Pick<UserDoc, 'staffOf'>) => Object.values(u.staffOf ?? {}).some((s) => s.active && DESK_ROLES.includes(s.role));
/** True if the person is a trainer at any gym. */
export const isTrainer = (u: Pick<UserDoc, 'staffOf'>) => Object.values(u.staffOf ?? {}).some((s) => s.active && s.role === 'TRAINER');
export type AppRole = 'MEMBER' | 'OWNER' | 'TRAINER' | 'STAFF';
const ROLE_LABEL: Record<AppRole, string> = { MEMBER: 'Member', OWNER: 'Gym owner', TRAINER: 'Trainer', STAFF: 'Gym staff' };

/**
 * What a front desk person may do. The owner switches these on/off per staff (board 58).
 * members: see members · memberEdit: add/edit members · payments: memberships and payments ·
 * checkin: attendance, scan, gate · requests: join/transfer requests · offers: offers and notices ·
 * reports: money reports and dues · plans: plans and gym settings.
 */
export const RIGHTS = ['members', 'memberEdit', 'payments', 'checkin', 'requests', 'transfers', 'offers', 'reports', 'plans', 'enquiries', 'lockers'] as const;
export type Right = (typeof RIGHTS)[number];
export const RIGHT_PRESETS: Record<string, Right[]> = {
  RECEPTION: ['members', 'memberEdit', 'payments', 'checkin', 'requests', 'enquiries', 'lockers'],
  CHECKIN: ['members', 'checkin'],
  MANAGER: ['members', 'memberEdit', 'payments', 'checkin', 'requests', 'transfers', 'offers', 'reports', 'plans', 'enquiries', 'lockers'],
};
/** Front desk added before rights existed: what they could always do. */
export const DEFAULT_DESK_RIGHTS: Right[] = ['members', 'memberEdit', 'payments', 'checkin', 'requests', 'offers', 'enquiries', 'lockers'];
export function cleanRights(list: unknown): Right[] {
  return Array.isArray(list) ? RIGHTS.filter((r) => list.includes(r)) : [...DEFAULT_DESK_RIGHTS];
}
const nonEmpty = (o?: Record<string, unknown>) => !!o && Object.keys(o).length > 0;
/** The role this account belongs to, worked out from what it really is in gyms. null = not decided yet. */
export function accountRole(u: UserDoc): AppRole | null {
  const live = Object.values(u.staffOf ?? {}).filter((s) => s.active);
  if (live.some((s) => s.role === 'OWNER')) return 'OWNER';
  if (live.some((s) => s.role === 'FRONT_DESK')) return 'STAFF';
  if (u.appRole === 'STAFF') return 'STAFF'; // removed from a gym: still a staff account, waiting to be added again
  if (isTrainer(u) || nonEmpty(u.trainerRequested)) return 'TRAINER';
  if (u.appRole) return u.appRole;
  if (nonEmpty(u.memberships) || nonEmpty(u.requested)) return 'MEMBER';
  return null;
}
/** True when the account is tied to a gym, so its role can no longer change. */
export const roleLocked = (u: UserDoc) =>
  isDeskStaff(u) || isTrainer(u) || nonEmpty(u.trainerRequested) || nonEmpty(u.memberships) || nonEmpty(u.requested) || nonEmpty(u.staffOf);
export const wrongRoleMessage = (have: AppRole) =>
  `This account is registered as a ${ROLE_LABEL[have]}. Go back and choose "${ROLE_LABEL[have]}" to log in`;


export function requireSuper(c: C) {
  if (!c.var.user.isSuperAdmin) throw forbidden('Super admin only');
}

export interface GymCtx {
  tenantId: string;
  role: Role;
  branchIds: string[];
  tenant: TenantDoc;
  /** The branch the staff app is looking at (x-branch-id); lists, dashboards and new offers follow it. */
  branchId: string;
  /** What this person may do here (owners: everything). */
  rights: Right[];
}

/** Stops front desk staff from doing what their owner has not allowed. */
export function need(g: GymCtx, right: Right) {
  if (g.role === 'OWNER' || g.role === 'TRAINER') return;
  if (!g.rights.includes(right)) throw forbidden('Your gym owner has not given you access to this');
}

/** Branch a record belongs to; old records without one belong to the first branch. */
export const branchOf = (t: Pick<TenantDoc, 'branches'>, id: string | null | undefined) => id ?? t.branches[0]?.id ?? null;
export const branchCode = (t: Pick<TenantDoc, 'branches' | 'gymCode'>, b: Branch) => b.code ?? (b.id === t.branches[0]?.id ? t.gymCode : null);
/** Member ID after moving to another branch: the new branch's code + the same number (LIFE951-1004 → ATHE482-1004). */
export function memberCodeFor(t: Pick<TenantDoc, 'branches' | 'gymCode'>, branchId: string | null | undefined, oldCode: string) {
  const b = t.branches.find((x) => x.id === branchId) ?? t.branches[0];
  const code = b ? branchCode(t, b) : null;
  const num = oldCode.split('-').pop() ?? oldCode;
  return code ? `${code}-${num}` : oldCode;
}
/** Is this record part of the branch the staff app is looking at? */
/** How a member or trainer sees their gym: with the branch name, address and code when the gym has branches. */
export function gymFace(t: TenantDoc, branchId: string | null | undefined) {
  const id = branchOf(t, branchId);
  const b = t.branches.find((x) => x.id === id) ?? null;
  const multi = t.branches.length > 1;
  return {
    // Main (first) branch shows the gym's name; any other branch shows only its own name.
    name: multi && b && b.id !== t.branches[0]?.id ? b.name : t.name,
    gymName: t.name,
    branchId: b?.id ?? null,
    branchName: b?.name ?? null,
    code: (b && branchCode(t, b)) ?? t.gymCode,
    address: (multi && b?.address) || t.address,
    // A branch shows only its own logo; the main (first) branch shows the gym's logo.
    logoUrl: b?.logoUrl || (!b || b.id === t.branches[0]?.id ? t.logoUrl : null) || null,
    state: b?.state || t.state || null,
    appCheckin: b?.appCheckin !== false,
  };
}
export const inBranch = (g: GymCtx, id: string | null | undefined) => branchOf(g.tenant, id) === g.branchId;

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
  if (tenant.status === 'CLOSED') throw forbidden('This gym is closed');
  if (roles.length && !roles.includes(s.role)) throw forbidden('Only the gym owner can do this');
  const allowed = s.role === 'OWNER' || !(s.branchIds ?? []).length ? tenant.branches.map((b) => b.id) : tenant.branches.map((b) => b.id).filter((id) => s.branchIds.includes(id));
  const askedBranch = c.req.header('x-branch-id');
  const branchId = askedBranch && allowed.includes(askedBranch) ? askedBranch : allowed[0] ?? tenant.branches[0]?.id ?? '';
  const rights: Right[] = s.role === 'OWNER' ? [...RIGHTS] : cleanRights(s.rights);
  return { tenantId, role: s.role, branchIds: s.branchIds ?? [], tenant, branchId, rights };
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
  branchId?: string | null; // for gym staff: which branch it is about
  title: string;
  body: string;
  createdAt: string;
  readAt: string | null;
  go?: string | null; // what the app opens on tap ("due", "requests", "ticket:<id>", …)
}

/**
 * What a notification opens in the app, from its title (the app turns it into the page for the person's
 * role). Every title the server sends must match a rule here — test/api.test.ts checks the full list.
 * The app has the same list (session.dart goFromTitle) for notifications saved before "go" existed.
 */
export const GO_RULES: [RegExp, string][] = [
  [/^Payment due/, 'due'],
  [/^(Payment received|Membership (added|updated|frozen)|Branch changed|Transfer not approved)/, 'membership'],
  [/^(Plan activated|Payment not received)$/, 'subscription'],
  [/(ends in \d+ days$|ends tomorrow$|^Last day of your|has ended$)/, 'subscription'],
  [/^Branch transfer request/, 'requests:move'],
  [/^PT request to approve/, 'requests:pt'],
  [/^New (join|trainer) request/, 'requests'],
  [/^New member added/, 'members'],
  [/^PT payment received/, 'pt-pay'],
  [/^(New PT request|New PT client|PT approved|PT planned|PT sessions ending|PT request declined)/, 'pt'],
  [/^Staff attendance/, 'staffdays'],
  [/^Enquiry calls today/, 'enquiries'],
  [/^Salary paid/, 'salary'],
  [/^(Locker given|Your locker ends|Your locker has ended)/, 'membership'],
  [/^Locker (ending|ended)/, 'lockers'],
  [/^Staff invite/, 'home'],
  [/^(Mark your attendance|Still not marked)/, 'attendance'],
  [/^(Your plan is updated|New diet chart|New workout plan)/, 'program'],
  [/^(New support ticket|Ticket reply|Reply on ticket|Ticket GM-)/, 'tickets'],
  [/^Plan payment/, 'payments'],
  [/^New gym registered|gym plans? ended/i, 'gyms'],
  [/^(Welcome!|Request declined|Removed from gym|You are gym staff now|Gym transferred|You own a gym now|Gym closed|Gym reopened)/, 'home'],
];
export function goOf(title: string): string | null {
  return GO_RULES.find(([re]) => re.test(title))?.[1] ?? null;
}

/** A super admin message to everyone or to some roles (read live, not copied per person). */
export interface Broadcast {
  id: string;
  title: string;
  body: string;
  roles: string[]; // ALL | OWNER | STAFF | TRAINER | MEMBER
  state: string | null;
  createdAt: string;
  byId: string;
}

/** Which broadcast roles a person belongs to. */
export function broadcastRolesOf(u: UserDoc): string[] {
  const live = Object.values(u.staffOf ?? {}).filter((s) => s.active);
  const out = new Set<string>();
  if (live.some((s) => s.role === 'OWNER') || u.appRole === 'OWNER') out.add('OWNER');
  if (live.some((s) => s.role === 'FRONT_DESK') || u.appRole === 'STAFF') out.add('STAFF');
  if (live.some((s) => s.role === 'TRAINER') || u.appRole === 'TRAINER') out.add('TRAINER');
  if (Object.keys(u.memberships ?? {}).length || u.appRole === 'MEMBER') out.add('MEMBER');
  return [...out];
}

/**
 * States a person counts in for GymMantra notifications: their own (from their address), else the
 * state of the gyms they belong to (old and gym-made members often have no state of their own).
 */
export async function pushStatesOf(r: Reader, u: UserDoc): Promise<string[]> {
  if (u.state) return [u.state];
  const ids = [...new Set([...Object.keys(u.memberships ?? {}), ...Object.entries(u.staffOf ?? {}).filter(([, s]) => s.active).map(([t]) => t)])];
  if (!ids.length) return [];
  const ts = await r.getMany<TenantDoc>(ids.map(P.tenant));
  return [...new Set(ts.map((t) => t?.state ?? null).filter((x): x is string => !!x))];
}

/** In-app notification (kept as the last 50 per user in one document). */
export async function notify(t: Tx, userId: string | null | undefined, tenantId: string | null, title: string, body: string, branchId: string | null = null, go?: string | null) {
  if (!userId) return;
  const to = go ?? goOf(title);
  const doc = (await t.get<{ items: NoteItem[] }>(P.notes(userId))) ?? { items: [] };
  t.set(P.notes(userId), { ...doc, items: [{ id: uuid(), tenantId, branchId, title, body, createdAt: nowIso(), readAt: null, go: to }, ...doc.items].slice(0, 50) });
  queuePush({ uid: userId, title, body, data: { kind: 'note', ...(tenantId ? { tenantId } : {}), ...(branchId ? { branchId } : {}), ...(to ? { go: to } : {}) } });
}

/**
 * Tells the gym's owners (and front desk of that branch who have [right]) about something that happened,
 * except the person who did it. Used for payments, new members, join requests, staff attendance…
 */
export async function notifyDesk(t: Tx, g: Pick<GymCtx, 'tenantId'> & { tenant: TenantDoc }, actorId: string | null, title: string, body: string, branchId: string | null, right?: Right, go?: string) {
  const staff = await t.query<{ role: Role; active: boolean; branchIds: string[]; rights?: string[] }>(P.staffCol(g.tenantId), [['active', true]]);
  const first = g.tenant.branches[0]?.id ?? null;
  for (const s of staff) {
    if (s.id === actorId) continue;
    const d = s.data;
    const owner = d.role === 'OWNER';
    const desk = d.role === 'FRONT_DESK' && !!right && cleanRights(d.rights).includes(right) && (!branchId || (d.branchIds[0] ?? first) === branchId);
    if (owner || desk) await notify(t, s.id, g.tenantId, title, body, branchId, go);
  }
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

/**
 * The roster is split into parts once it grows big: Firestore allows at most 1 MB per document.
 * roster/main holds part 0 and `parts` (how many there are); part k > 0 is roster/p<k>. A member is
 * in part (hash of id) % parts. Only the parts that changed are written. When a part gets too big,
 * the parts are doubled and everything is written once.
 */
export const ROSTER_PART = { maxChars: 600_000 }; // well under 1 MB (Hindi names take more bytes)
const rosterPartPath = (t: string, k: number) => (k === 0 ? P.roster(t) : `tenants/${t}/roster/p${k}`);
function partOf(memberId: string, parts: number) {
  let h = 0;
  for (let i = 0; i < memberId.length; i++) h = (h * 31 + memberId.charCodeAt(i)) >>> 0;
  return h % parts;
}
type RosterPart = { members: Record<string, RosterEntry>; parts?: number };
const rosterMeta = new WeakMap<Roster, { tenantId: string; parts: number; json: string[] }>();

export async function readRoster(r: Reader, tenantId: string): Promise<Roster> {
  const main = await r.get<RosterPart>(P.roster(tenantId));
  const parts = main?.parts ?? 1;
  const rest = parts > 1 ? await r.getMany<RosterPart>(Array.from({ length: parts - 1 }, (_, i) => rosterPartPath(tenantId, i + 1))) : [];
  const all = [main, ...rest];
  const roster: Roster = { members: {} };
  for (const p of all) Object.assign(roster.members, p?.members ?? {});
  rosterMeta.set(roster, { tenantId, parts, json: all.map((p) => JSON.stringify(p?.members ?? {})) });
  return roster;
}

/** Several gyms' rosters with few round trips (main parts together, then any extra parts together). */
export async function readRosters(r: Reader, tenantIds: string[]): Promise<Roster[]> {
  const mains = await r.getMany<RosterPart>(tenantIds.map((t) => P.roster(t)));
  const extra = tenantIds.flatMap((t, i) => Array.from({ length: (mains[i]?.parts ?? 1) - 1 }, (_, k) => rosterPartPath(t, k + 1)));
  const got = extra.length ? await r.getMany<RosterPart>(extra) : [];
  const byPath = new Map(extra.map((p, i) => [p, got[i]]));
  return tenantIds.map((t, i) => {
    const roster: Roster = { members: { ...(mains[i]?.members ?? {}) } };
    for (let k = 1; k < (mains[i]?.parts ?? 1); k++) Object.assign(roster.members, byPath.get(rosterPartPath(t, k))?.members ?? {});
    return roster;
  });
}

/** Saves a roster read with readRoster (only the parts that changed). */
export function writeRoster(t: Pick<Tx, 'set'>, tenantId: string, roster: Roster) {
  const meta = rosterMeta.get(roster);
  let parts = meta && meta.tenantId === tenantId ? meta.parts : 1;
  const split = (n: number) => {
    const out: Record<string, RosterEntry>[] = Array.from({ length: n }, () => ({}));
    for (const [id, e] of Object.entries(roster.members)) out[partOf(id, n)][id] = e;
    return out.map((m) => JSON.stringify(m));
  };
  let json = split(parts);
  while (json.some((j) => j.length > ROSTER_PART.maxChars)) json = split((parts *= 2));
  const grew = !meta || parts !== meta.parts;
  json.forEach((j, k) => {
    if (!grew && meta && meta.json[k] === j) return;
    t.set(rosterPartPath(tenantId, k), k === 0 ? { members: JSON.parse(j), ...(parts > 1 ? { parts } : {}) } : { members: JSON.parse(j) });
  });
  rosterMeta.set(roster, { tenantId, parts, json });
}

/** Copies a user's photo version into every gym roster where they are a member. */
export async function syncRosterPhoto(t: Tx, u: Pick<UserDoc, 'memberships'>, photoV: number | null) {
  for (const [tid, mid] of Object.entries(u.memberships ?? {})) {
    const r = await readRoster(t, tid);
    if (!r.members[mid]) continue;
    r.members[mid] = { ...r.members[mid], photoV };
    writeRoster(t, tid, r);
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
  return { name: m.name, phone: m.phone, memberCode: m.memberCode, branchId: m.branchId, userId: m.userId, archived: m.archived, ...(m.gone ? { gone: true } : {}), subs: [] };
}

export function stateOf(e: RosterEntry, today = todayIST()): MemberState<RosterSub> {
  return computeState(e.subs, today);
}

/** Today's counters for the dashboard. */
export async function bumpDaily(t: Tx, tenantId: string, patch: Partial<Record<'collected' | 'payments' | 'checkins' | 'blocked', number>>, branchId?: string | null) {
  const day = todayIST();
  const cur = (await t.get<Record<string, number>>(P.daily(tenantId, day))) ?? { collected: 0, payments: 0, checkins: 0, blocked: 0 };
  for (const [k, v] of Object.entries(patch)) {
    cur[k] = (cur[k] ?? 0) + (v ?? 0);
    // Each branch also has its own counters ("b.<branchId>.checkins").
    if (branchId) cur[`b.${branchId}.${k}`] = (cur[`b.${branchId}.${k}`] ?? 0) + (v ?? 0);
  }
  t.set(P.daily(tenantId, day), cur);
}

/** One branch's numbers from a daily counter document. Days before branch counters existed count for the first branch. */
export function dailyFor(g: GymCtx, d: Record<string, number> | null | undefined) {
  const has = d && Object.keys(d).some((k) => k.startsWith('b.'));
  const first = g.branchId === g.tenant.branches[0]?.id;
  const v = (k: string) => (!d ? 0 : has ? d[`b.${g.branchId}.${k}`] ?? 0 : first ? d[k] ?? 0 : 0);
  return { collected: v('collected'), payments: v('payments'), checkins: v('checkins'), blocked: v('blocked') };
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
