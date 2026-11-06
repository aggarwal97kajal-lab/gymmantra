# CLAUDE.md — GymMantra

Read this first, then `docs/MVP_SPEC.md` (features and business rules). The owner does not have a computer and works from a phone; reply in simple Hinglish.

## What is built

| Part | Folder | Stack | Status |
| --- | --- | --- | --- |
| Server (API) | `apps/worker` | Cloudflare Worker (Hono) + Firebase Auth + Firestore | Done, 57 tests |
| Admin panel + super admin | `apps/admin` | Next.js 14 (static export), served by the Worker | Done |
| App (members, trainers, gym owners) + GM Admin app | `apps/mobile` | Flutter, Riverpod, GoRouter, Dio | Done (v3), both APKs built by CI |

One Cloudflare Worker (`wrangler.jsonc` at the repo root) runs the API and serves the admin panel and the 3D exercise videos as static assets. Firebase Authentication stores and checks passwords (via the Identity Toolkit REST API); Firestore is the database. The Worker reaches Firestore as the Firebase user `server@gymmantra.internal`, and `firestore.rules` lets only that user in. Apps never talk to Firebase directly. Setup: `docs/DEPLOY_FROM_PHONE.md`.

### Data layout (Firestore)

- `users/{uid}` holds profile, lockout counters, `memberships {tenantId: memberId}`, `requested`, and `staffOf {tenantId: {role, branchIds, active}}`. One read per request gives identity and gym access.
- `phones/{+91…}` and `gymCodes/{code}` are unique indexes.
- `tenants/{t}` has the gym and its branches. Under it: `members`, `subs` (memberships with embedded payments and freezes), `plans`, `staff`, `joinRequests`, `attendance`, `lastScan/{memberId}` (duplicate scans, recent visits, monthly count), `daily/{date}` (dashboard counters) and `audit`.
- `tenants/{t}/roster/main` keeps every member's summary and membership terms in **one document**. Lists, dashboards and status checks read only this, to stay inside Firestore's free read quota. Keep it in sync whenever members or memberships change (`rosterPutSub`).
- Top-level: `tickets` (messages embedded), `notifications/{uid}`, `photos/{uid}`, `saasPlans`, `settings/{platform,secrets,stats}`, `platformAudit`.
- Queries are equality-only (no composite indexes needed). Sort in code.

## Decisions from the owner (Nov 2026)

- **Login:** normal sign-up (name, email, mobile, password) and log-in with email or mobile. Google sign-up creates an account; Google log-in only works for accounts that signed up with Google. Phone OTP is later.
- **Lockout:** 3 wrong passwords lock the account for 15 minutes (`config.maxLoginAttempts`, `config.lockMinutes`).
- **Not paid yet:** the admin decides per membership whether the member may enter (`allowEntryWhileDue`), with a gym default (`tenants.allowEntryWhenDue`).
- **Freeze:** in the MVP. Up to the plan's freeze days; blocks check-in; extends the end date; ending early returns unused days.
- **WhatsApp:** each gym uses its own number. Messages open `wa.me` links on the staff phone with text ready.
- **One app, three roles:** the person picks Member, Gym owner or Trainer (`users.appRole`). Members and trainers join with the gym code and the owner must approve (`joinRequests.kind`). A trainer cannot own or run a gym and an owner cannot be a trainer. Trainers are staff with role `TRAINER`; `gymOf()` never lets them into desk endpoints unless the route asks for `'TRAINER'`.
- **Super admin** uses the website or the separate **GM Admin** app (`--dart-define=APP=admin`, header `x-gm-client: admin-app`, app id `com.gymmantra.admin`, crown logo). The normal app refuses the super admin; the admin app refuses everyone else.
- **PT:** owner sets each trainer's packages and share % (`tenants/{t}/trainers`). Member requests PT → trainer and owner are notified → only the owner approves. Trainer marks sessions on a calendar (`pt.log`); member and owner see the same. PT money is kept apart from memberships; the owner pays trainers (`ptPayouts`). Diet chart and workout per client in `programs/{memberId}`.
- **Offers** (owner → members with a status filter and/or trainers) and **ads** (super admin → members / trainers / owners, by state) show on dashboards.
- **Plans lock features** (`billing.ts`: `offers`, `pt`, `reports`, `branches`; trial unlocks all). Owner photo gets a glowing ring in the plan colour. Plan payments are recorded by the super admin (no gateway yet) and make a receipt in `tenants/{t}/bills`.
- **GST:** GymMantra is not registered, so bills have no GST and signup says nothing about tax. The super admin turns it on in GM Admin → GST (`settings/platform.gst`); new bills then get CGST+SGST for Delhi gyms and IGST for others (from the gym's state). New gyms must give address, state, city and a PIN that fits the state (`lib/india.ts`, `assets/india.json`).
- **Look:** logo C (dumbbell + heartbeat), orange `#FF5A1F`, font Plus Jakarta Sans. App has Light/Dark/Auto theme and English/Hindi (`lib/strings_hi.dart`, English text is the key).
- **Owner tools in the app:** Reports (`GET /reports?days=7|30|90`, feature `reports`), membership plans and gym settings (branches, join poster) are in the owner app, not only on the website. A trainer with no gym yet still lands on the trainer dashboard with a "Join your gym" card. Login checks the role picked on the first screen against the account (`accountRole`).
- **Notices:** owner or front desk sends a notice (`tenants/{t}/notices`) to members (all / active / expired) and/or trainers, with a last day. Not copied per person: `/me/gyms`, `/trainer/home` and `/me/notifications` read the gym's live notices (`routes/notices.ts`); read state is `notifications/{uid}.noticesReadAt`.
- **Support tickets:** every ticket goes to GymMantra support (super admin only), with a unique number (`GM-1001…`, counter `settings/ticketSeq`). Statuses (English everywhere): OPEN → IN_PROGRESS (super admin) → WAITING (support replied, person's turn) → RESOLVED (person can reply for 7 days, which reopens it) → CLOSED (auto 7 days after RESOLVED, or super admin; no more messages). Computed by `ticketStatus()`; super admin sets with `PATCH /super/tickets/:id`. The person cannot write again on a ticket until support replies (`waiting`). FAQ is per role; Terms & Privacy are in the app (`screens/legal.dart`) and on the website (`/terms`, `/privacy`); signup needs the "I agree" tick.
- **Check-in QR:** separate from the join QR; members/trainers scan it (`POST /me/checkin`). Gym location radius 20 m (+ GPS accuracy up to 30 m). Owner can delete offers (with banner pictures), unused plans, empty branches; super admin can delete ads.
- **Branches:** each branch has its own join code (`gymCodes/{code}` → `{tenantId, branchId}`; the old gym code is the first branch's), its own check-in QR and location (`CheckinDoc.branches`), and its own numbers. The owner app sends `x-branch-id`; `gymOf()` sets `g.branchId` and lists, dashboard (`dailyFor`), reports, attendance, offers/notices (`branchIds`, default the current branch, `"ALL"` for every branch), leads and owner notifications follow it. No "all branches" view. A member is in one branch per gym (other gyms are fine): joining another branch of the same gym gives 409 `ALREADY_MEMBER`; the owner moves members (`PATCH /members/:id {branchId}`) or approves member requests (`/transfers`, only when `tenants.allowTransfer` is on).
- **Speed (Nov 3):** Worker uses Cloudflare Smart Placement (runs near Firestore). The app reuses a screen's data for 10 s (`Api._isFresh`, cleared by any write), saves phone copies off the main thread, and saves simple edits in the background (`saveInBackground`: screen closes at once, red drip toast if it fails). Ticket replies and super admin gym changes show instantly.
- **PDFs** go up and down in pieces of ≤350k base64 characters (`PUT /programs/:m/pdf/:kind/parts/:n`, then `PUT …/pdf/:kind {uploadId, parts, size}`; read with `?meta=1` and `?part=n`). One 2 MB request is too much CPU for the free Worker plan.
- **Names:** a trainer's new name is copied to their trainer cards and PT records; PT lists also read live names. Members and trainers see their gym as "Gym – Branch" with the branch's code and address (`gymFace`). Old branches without a code get one when the gym is opened (`ensureBranchCodes`).
- **Speed:** `FirestoreStore` keeps users, gyms, rosters and platform settings in memory for 8 s per Worker instance and reuses documents read inside a transaction; batch reads with `t.getMany` at the start of transactions.
- **Forgot password:** `POST /auth/forgot` sends the Firebase reset email (not for Google-only accounts).
- **Plan payment (Nov 3, no gateway yet):** owner taps Pay → `POST /subscription/payments {key}` (idempotency key from the app; same key = same payment; payment ID `GM-<code>-NNNN` goes in the UPI note) → the app opens a UPI app chosen from the apps really installed (native channel `gymmantra/upi`, real icons) → back from the UPI app `POST /subscription/payments/:key/done` turns the plan on at once and makes the receipt (unless the UPI app said FAILURE). No UTR. Super admin sees every payment (GM Admin → Plan payments) and can cancel one whose money never came (`/super/payments/:id/cancel`: plan undone, receipt CANCELLED). 3 failed/cancelled in 24 h pause payments 24 h. Coupons (`coupons`, `couponCodes`) by super admin, optionally on ads.
- **Rate limit:** login, sign-up, forgot/reset, Google and password changes: 5 a minute per email/mobile and per IP (`lib/ratelimit.ts`, `rateLimits/*`), 429 "Too many requests".
- **Google + gym-made members:** Google login/sign-up with a verified email opens the account with that email (linked via `googleSubs/{sub}`). A member the owner added (`createdByGym`, `mustSetPassword`, server-only `initPw`) sets a password once (`/auth/set-password`). Google sign-up then asks DOB/state/city/PIN (`detailsNeeded`).
- **Branch names:** the main (first) branch shows the gym name; any other branch shows only its own name (`gymFace`, app `withBranch`). Branch codes start with the branch's name; old ones are re-made and keep working 30 days (`gymCodes.expiresAt`).
- **Check-in scanner:** `camera` (Camera2 via `camera_android`) + pure-Dart `zxing2` (`lib/qr_scan.dart`); no ML Kit. Photo of the QR uses the same reader.
- **App speed:** GETs share one request per path, retry with exponential backoff + jitter (`Api.backoff`), and every tab's data is prefetched at start (GM Admin too).
- **Deleted accounts (Nov 4):** members and trainers can delete their account (password asked; Firebase login deleted too). Gyms keep the record marked `gone` → app shows "No longer available" (members tab, trainer card); owner can `DELETE /members/:id` (gone only; roster entry removed, member doc `removed`) or remove the trainer. A returning member who joins again is linked to the old record (gone cleared) unless the owner deleted it. Super admin: GM Admin → People (`GET /super/users?q=`, `POST /super/users/:id/delete`). Sign-up never says "email taken" for a dead login: same password reuses it, otherwise a `name+gmNNNN@domain` login is made (`aliasEmail`). Owners/front desk cannot be deleted while they run a gym (`removeAccount` in `routes/me.ts`).
- **Staff, rights, attendance, gate (Nov 4, boards 50–62):**
  - 4th role on the first screen: **Gym staff** (`appRole: 'STAFF'`, `accountRole` → STAFF for active FRONT_DESK). Staff never sign up (400); the owner adds them like a member (`POST /gym/staff` with person details → gym-made account, `mustSetPassword`, Google → set password). Website still sends `tempPassword`.
  - Each FRONT_DESK works in one branch (`branchIds[0]`); `GET /gym/staff` lists the current branch's front desk + owners. Rights per staff (`RIGHTS` in core: members, memberEdit, payments, checkin, requests, offers, reports, plans; presets RECEPTION/CHECKIN/MANAGER) stored on the staff doc and `users.staffOf[t].rights`; routes call `need(g, right)`. Old front desk default = `DEFAULT_DESK_RIGHTS`.
  - Owner removing a member (`DELETE /members/:id`), trainer or staff (`DELETE /gym/staff/:id`) only takes them out of the gym; their login stays. Only the person or the super admin deletes an account.
  - Staff attendance: no check-in; "Present" once a day at their branch's check-in location (20 m + accuracy ≤30 m, mocked GPS refused) → `tenants/{t}/staffDays/{uid}_{YYYY-MM}` (`routes/staffdays.ts`); owner sees/corrects the month (`/staff-attendance`).
  - Gate (`routes/gate.ts`, `tenants/{t}/private/gate`): per branch, a WiFi relay called by web link (webhook) or Shelly Cloud; opened after an ALLOWED check-in (member self, trainer, desk scan/manual) and by "Open now". Needs hardware at the gym.
  - Gym transfer (`POST /gym/transfer`, `/super/gyms/:id/transfer`) and close/reopen (`/super/gyms/:id/close|reopen`, status `CLOSED`, 30 days to reopen, `closedStaff` restored).
  - Notifications: `notifyDesk()` tells owners (+ front desk with the right, same branch) about payments, members added by staff, join requests, staff attendance; members get payment receipts. Super admin broadcasts (`settings/broadcasts`, GM Admin → Send notification) by role and state, read live in `/me/notifications`. Phone push: `lib/push.ts` (FCM HTTP v1 with the `FIREBASE_SERVICE_ACCOUNT` secret, token signed in `lib/gauth.ts`); every `notify()` is also pushed (queued, sent after the answer), gym notices / broadcasts go to topics (`/me/push-topics`), filtered notices go member by member (`pushJobs`, every-minute cron). App: `lib/push.dart` (Firebase options in code, one app id per Android app). GM Admin gets new tickets/replies, plan payments, new gyms, failed payments, ended plans (`lib/superpush.ts`, switches in `settings/adminPush`). Plan reminders: 7 days before the plan/trial ends, daily 10 AM IST to owners; after it ends daily for 30 days, then weekly up to 6 months (`reminderFor`, `cronReminders`).
- **Branches, logos, password, People (Nov 5, boards 65–68):** branches keep `addressLine/state/city/pincode/gstin` (same checks as the gym, `readAddress`) and an own `logoUrl`. Logos: `PUT/DELETE /gym/logo {branchId?}` (owner, JPEG/PNG ≤300 KB) stored in `tenants/{t}/logos/{gym|branchId}`, read at `GET /logos/:t/:key` only by people linked to the gym or the super admin; `POST /gyms` takes `logo`. `gymFace().logoUrl` = the branch's own logo; only the main branch falls back to the gym logo (members, trainers, owner branch switch via `withBranch`). Logo uploads show a % ring (`UploadRing`, `Api.put/postProgress` with `onSendProgress`); editing a branch uploads the logo as soon as it is picked. Branches list shows the gym name for the main branch. Change password always asks the current one unless the account is Google-only (no password yet). Log-out is instant (server and push clean-up run in the background with the old token, `Api.postAs`). State broadcasts: a person counts in their own state, else their gyms' states (`pushStatesOf`, also the push topics); `GET /super/broadcasts/reach`. GM Admin People is gym wise: `GET /super/gyms/:id/people[?kind=members|trainers|staff]`, `GET /super/users/:id`.
- **Nov 5 evening (boards 69–75):** every notification has `go` (`goOf(title)` or explicit, e.g. `ticket:<id>`, `due`, `requests`, `attendance`); push data carries it and the app opens the page (`noteRoute` in `session.dart`, `Push.onOpen`, list tap `openNote`); bell shows the unread count (`NotificationBell`). Due reminders are also pushed. Per-branch `Branch.appCheckin` (`PUT /gym/checkin-mode`): off → no check-in QR in the owner app, `/me/checkin` 403 `CHECKIN_OFF`, member sees "App check-in is off". Manual check-in stays; "Scan member QR" (desk) and trainer gate scan are gone from the app. Every member check-in is kept (only repeats within 2 min are ignored; visits count once a day); `GET /attendance/today?day=`, `GET /attendance/export?kind=members|staff&from&to` (CSV, staff kind owner only), `GET /me/memberships/:id/checkins`. Staff: no plan page/ring/branch switch; new right `transfers` (move members, approve move requests). PT packages owner-only. Freeze days push later renewals in the chain too (`computeState` shifted ranges, `frozenDays`). Staff/trainer attendance reminders at 11 AM and 5 PM IST if not Present (`lib/attendrem.ts`). Plan receipts: Download / Share PDF (picture of the receipt on A4). Website no longer offers "WhatsApp receipt".
- **Notification pages (Nov 5 night):** server `GO_RULES` in core.ts gives every title a `go` (unit test lists every title); the app has the same rules (`goFromTitle`) for old notifications. Member membership notes open the member's membership page (`@membership` → `membershipPath(tenantId)`), desk payment/new-member notes open that member (`member:<id>`), tickets open the ticket in every app. Bell is a plain icon with a red count. One Attendance page (`AttendanceHubScreen`, `/o/attendance-hub`, desk tab): Members (day history + Excel), Staff & trainers (owner, month + Excel), My attendance (staff). Check-in switch flips at once (optimistic). A member's `/me/checkin` with another branch's QR is refused (403 `OTHER_BRANCH`).
- **Security hardening (Nov 6):** JWT carries `v` = `users.sessionV`; change-password / set-password / reset bump it (other phones and browsers are logged out; change/set return a fresh `token` the app saves). 500 errors show only `Error ID: XXXX` (detail in `console.error` + diag log). `GET /api/v1/diag` is super-admin only (no key in code); `POST /diag` limited to 20/min per IP. `/api/setup-check` shows only which steps pass (no error text). Member `/me/checkin` refuses `mocked: true` (fake-location app).
- **Backup (Nov 6):** `.github/workflows/backup.yml` runs nightly (2 AM IST): `.github/scripts/backup.py` calls `POST /backup/page` page by page (whole database via a kindless `allDescendants` query, `Store.dump`), encrypted on the server with AES-GCM (key = HKDF of `SERVER_PASSWORD`; changing that password makes old backups unreadable), kept as a 30-day artifact. `restore.yml` (manual, run ID + type RESTORE) sends pages to `POST /backup/restore` (`Store.load`, overwrites). Both routes accept only GitHub's OIDC token for that workflow on main of this repo (`backupDeps` in `worker.ts`).
- **Pen-test fixes (Nov 6):** a gym adding a member/staff whose mobile or email already has an account does NOT link it (members: linked when they join with the code and are approved; staff: `invite` on the staff doc + notification `go: staff-invite:<t>` → `POST /me/staff-invites/:t/accept|decline`). Plan payment `/done` turns the plan on only for UPI `SUCCESS`; otherwise status `CHECKING` until super admin `POST /super/payments/:id/confirm` (GM Admin → Plan payments → To check). Rate limits and login lockout live in memory + Cloudflare cache (`lib/ratelimit.ts`), never Firestore; lockout is per account + IP (key includes `sessionV`, so a reset clears it); unknown accounts get the same login/forgot answers. `ADDED_BY_GYM` no longer shows gym name or email. Google links by email only to accounts without their own password. Profile email cannot be `SUPER_ADMIN_EMAIL`; promotion uses `authEmail`. App diag writes max 1 per 10 s per instance. Gym-code lookups/joins 20/min per person. CSV cells starting with = @ + - (not numbers) get a `'`. Gate links https + public host only; gate opens from the app only where the branch location is set. Offer/ad pictures checked by their first bytes (`isImage`).
- **Load simulation (Nov 6):** `apps/worker/test/load/*.sim.ts` (not in the normal test run): `users.sim.ts` (1100 people, counts reads/writes/CPU per request; `SIM_GYMS`, `SIM_MEMBERS`, `SIM_BIG`), `renew.sim.ts` (roster size as members renew), `contention.sim.ts` (same-second check-ins; needs the Firestore emulator on :8080). Run with `jest --runInBand --testRegex 'test/load/<name>\.sim\.ts$'`. Found (and fixed, Nov 6): roster/main passed Firestore's 1 MB limit (~250 members after a year of monthly renewals) → the roster now splits into parts (`readRoster`/`writeRoster`/`readRosters`, `roster/main.parts`, `roster/p<k>`, ≤600k chars each, only changed parts written; always use these, never `t.set(P.roster…)` directly); same-second check-ins failed on the shared `daily` doc → check-ins write only the person's own docs and `countCheckIn` bumps the counter afterwards, and `FirestoreStore.tx` retries up to 8 times with a random growing wait. Still true: free Firestore reads (~30 per active member a day) cap at ~1500 active members a day; a very big roster (several MB) costs more than 10 ms CPU to read (paid Workers plan).
- **Database on Cloudflare D1 (Nov 6):** `DB_BACKEND: "d1"` (wrangler.jsonc vars) makes the Worker use `D1Store` (`src/store/d1.ts`) on D1 `gymmantra-db` (binding `GM_DB`, Asia Pacific) instead of Firestore. One row per document (`docs`: path, parent, coll, JSON data, random version `v`); queries `json_extract … IS ?` on the parent, with partial field indexes for growing collections (`INDEXED` list: add a field there when a new query on a big collection appears) and `INDEXED BY`; transactions = one atomic `batch` whose first statement fails (`json('database clash')`) if a read row's `v` changed, then re-run (8 tries, random wait). Free D1: 5M rows read / 100k written a day. Data was moved with `migrate.yml` (`POST /backup/migrate`, Firestore → D1, rows already in D1 kept). Firebase is now only for login (Auth) and phone push. Tests: `TEST_STORE=d1` runs the API tests on D1Store over `node:sqlite` (`test/d1shim.ts`); `test/d1.test.ts`. Placement is Smart. Going back to Firestore = remove `DB_BACKEND` (Firestore keeps the data as of the move only). App: screens reuse data for 60 s; start-up loading skipped if done in the last 10 minutes.
- **Nov 6 features (boards 84–89):** enquiry follow-up (`routes/enquiries.ts`, `tenants/{t}/enquiries`, right `enquiries`, 9 AM "Enquiry calls today"), staff salary (`routes/salary.ts`, `salary/{uid}` config incl. people without the app `e_…`, `salaryMonths/{uid}_{YYYY-MM}` with adjustments + payments, pay cut from staffDays; PT money stays in PT accounts), lockers (`routes/lockers.ts`, one doc per branch `lockers/{branchId}`, member doc `locker`, right `lockers`, reminders 3 days before + last day), trainer ratings (`trainerRatings/{trainer}_{user}_{month}`, trainer sees only stars + tags) and gym ratings (`gymRatings/{user}`, owner picks testimonials kept on the tenant doc `testimonials`/`ratingSum`, shown on member and trainer homes), fingerprint machines (`routes/devices.ts`, top-level `devices/{serial}`, public ADMS routes `/iclock/cdata|getrequest|devicecmd` for added serials only, PIN → member check-in `DEVICE` or staff Present). Day-later reminders: `lib/scheduled.ts` (`scheduled/{id}` by day + hour, sent by the every-minute cron, checked again when sent). App: `screens/extras.dart`. Supplement shop: not built (owner said later).
- **Nov 6 fixes (boards 90–94):** More menu has no Fingerprint machine / website rows (routes stay). `StatTile` shrinks the number to fit and always keeps 2 label lines (tiles in a row same height). `/my-salary` is a shared route (staff and trainers). Gym ratings are per branch: `gymRatings.branchId`, `tenants.ratingSums[branchId]` (old `ratingSum` = main branch), testimonials carry `branchId` + `photoV`; `testimonialsFor()` gives a branch its rating and reviews (`/me/gyms`, `/trainer/home` (`testimonials` list + `rating`), `/gyms/:t/testimonials` (viewer's branch, owner `?branchId=`), `/me/gym-lookup` (code's branch)). Reviewer photos via `/gyms/:t/testimonials/:uid/photo` (only while shown; people of the gym, or `?code=` of that gym). A member moved to another branch takes their rating along (`moveGymRating`). `GET /reports/money` (Reports → Money): memberships, PT, lockers, staff salary (owner only), net; `?csv=1`.
- **Pricing:** first 3 months free; Starter ₹399/₹3,990, Growth ₹799/₹7,990, Pro ₹1,399/₹13,990. Seed data only; the super admin edits plans in the panel.

## Rules that must not break

- Every gym-owned read and write uses the tenant from the server-side session (`gymOf()` in `apps/worker/src/core.ts`). The client may send `x-gym-id` only to choose among gyms where the user really is staff. Never trust a client tenant id.
- Membership terms are never edited. A correction is a new `subs` document with `replacesId`; money already received (`carriedPaid`) and freezes carry over.
- Membership status and the door decision live in `apps/worker/src/lib/status.ts` (pure functions, unit tested).
- Member QR tokens are HMAC-signed and change every 30 s (`lib/qr.ts`; secrets are generated once and stored in `settings/secrets`). A second scan within 2 minutes is ignored.
- Cookie sessions require the `x-gm-client` header on writes (CSRF). Mobile uses Bearer tokens.
- Settings and secrets live in Cloudflare variables (`FIREBASE_API_KEY`, `FIREBASE_PROJECT_ID`, `SERVER_PASSWORD` as a secret, `SUPER_ADMIN_EMAIL`, optional `GOOGLE_CLIENT_IDS`). Never commit them.
- Workers free plan: 10 ms CPU and 50 sub-requests per request. Keep Firestore calls per request small (batch reads with `getMany`).
- Every change to memberships, plans, staff and SaaS plans writes `audit_logs`.
- **Security guard (Nov 5):** `test/security.test.ts` calls every registered route without login (only the `PUBLIC` list may answer) and tries other gyms' / members' ids from another account. A new route must pass it; add to `PUBLIC` only for data that is truly public. The Cloudflare deploy runs the worker tests first (`build:cf`), so a failing test stops the deploy. `.github/workflows/security-probe.yml` checks the live database is closed to everyone but the server (weekly).

## Working in this sandbox

npm and PyPI are blocked here; GitHub works. The `deps-snapshot` workflow installs `node_modules` on GitHub and pushes it to the `devdeps` branch as split tarballs; extract them to work offline. Tests and the local preview use `MemoryStore` and `FakeIdentity`, so no Firebase account is needed to develop. CI also runs the same tests with `FIREBASE_EMULATOR=1` against the Firebase emulators (real adapters + `firestore.rules`); the `devtools-snapshot` workflow puts firebase-tools and the Firestore emulator jar on the `devtools` branch for local use. `FirestoreStore.tx` does not use Firestore server transactions (real Firebase answers PERMISSION_DENIED to `beginTransaction` for a signed-in user over REST). It reads with `batchGet`, remembers each document's `updateTime`, and commits with those as preconditions, re-running on a clash. `/api/setup-check` on the live site tells which setup step is missing. Flutter is not available locally; the app keeps each screen's last data on the phone (`Api.cachedGet`) so screens open instantly, and the `mobile` workflow analyzes, tests, builds and publishes the APK as a GitHub release.

## How to work (Karpathy guidelines, from github.com/multica-ai/andrej-karpathy-skills)

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

## Commands

```
pnpm install
pnpm --filter @gymmantra/worker test        # API tests (in-memory Firebase)
pnpm run build:cf                           # admin panel + static assets
pnpm --filter @gymmantra/worker dev         # preview on :8787 with two demo gyms
npx wrangler deploy --dry-run --outdir /tmp/w   # check the Cloudflare bundle
```

## Next

- Push notifications (FCM) for membership updates and ticket replies.
- Online plan payment (Razorpay) instead of the super admin recording it.
- QR scan for check-in inside the owner app.
- Phone OTP login.
- SaaS billing for gyms (card/UPI) after the free trial.
