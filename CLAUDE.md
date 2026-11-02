# CLAUDE.md — GymMantra

Read this first, then `docs/MVP_SPEC.md` (features and business rules). The owner does not have a computer and works from a phone; reply in simple Hinglish.

## What is built

| Part | Folder | Stack | Status |
| --- | --- | --- | --- |
| Server (API) | `apps/worker` | Cloudflare Worker (Hono) + Firebase Auth + Firestore | Done, 46 tests |
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
- **Forgot password:** `POST /auth/forgot` sends the Firebase reset email (not for Google-only accounts).
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

## Working in this sandbox

npm and PyPI are blocked here; GitHub works. The `deps-snapshot` workflow installs `node_modules` on GitHub and pushes it to the `devdeps` branch as split tarballs; extract them to work offline. Tests and the local preview use `MemoryStore` and `FakeIdentity`, so no Firebase account is needed to develop. CI also runs the same tests with `FIREBASE_EMULATOR=1` against the Firebase emulators (real adapters + `firestore.rules`); the `devtools-snapshot` workflow puts firebase-tools and the Firestore emulator jar on the `devtools` branch for local use. `FirestoreStore.tx` does not use Firestore server transactions (real Firebase answers PERMISSION_DENIED to `beginTransaction` for a signed-in user over REST). It reads with `batchGet`, remembers each document's `updateTime`, and commits with those as preconditions, re-running on a clash. `/api/setup-check` on the live site tells which setup step is missing. Flutter is not available locally; the app keeps each screen's last data on the phone (`Api.cachedGet`) so screens open instantly, and the `mobile` workflow analyzes, tests, builds and publishes the APK as a GitHub release.

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
