# CLAUDE.md — GymMantra

Read this first, then `docs/MVP_SPEC.md` (features and business rules). The owner does not have a computer and works from a phone; reply in simple Hinglish.

## What is built

| Part | Folder | Stack | Status |
| --- | --- | --- | --- |
| Backend API | `apps/api` | NestJS 10, Prisma 5, PostgreSQL | Done, 30 tests |
| Admin panel + super admin | `apps/admin` | Next.js 14 (static export), served by the API | Done |
| Member app | `apps/mobile` | Flutter, Riverpod, GoRouter, Dio | Done (v1), APK built by CI |

One web service runs everything: the API serves the admin panel from `apps/admin/out` and the 3D exercise videos from `media/exercises`. Deploy with `render.yaml` (Render) and a Neon Postgres database. See `docs/DEPLOY_FROM_PHONE.md`.

## Decisions from the owner (Nov 2026)

- **Login:** normal sign-up (name, email, mobile, password) and log-in with email or mobile. Google sign-up creates an account; Google log-in only works for accounts that signed up with Google. Phone OTP is later.
- **Lockout:** 3 wrong passwords lock the account for 15 minutes (`config.maxLoginAttempts`, `config.lockMinutes`).
- **Not paid yet:** the admin decides per membership whether the member may enter (`allowEntryWhileDue`), with a gym default (`tenants.allowEntryWhenDue`).
- **Freeze:** in the MVP. Up to the plan's freeze days; blocks check-in; extends the end date; ending early returns unused days.
- **WhatsApp:** each gym uses its own number. Messages open `wa.me` links on the staff phone with text ready.
- **Pricing:** first 3 months free; Starter ₹399/₹3,990, Growth ₹799/₹7,990, Pro ₹1,399/₹13,990. Seed data only; the super admin edits plans in the panel.

## Rules that must not break

- Every gym-owned query is scoped by `tenantId` from the server-side session (`@Gym()` in `common/auth.ts`). The client may send `x-gym-id` only to choose among gyms where the user really is staff. Never trust a client tenant id.
- `member_subscriptions` is insert-only. A correction is a new row with `replacesId`; payments and freezes carry over (`memberships/loader.ts`).
- Membership status and the door decision live in `memberships/status.ts` (pure functions, unit tested).
- Member QR tokens are HMAC-signed and change every 30 s (`attendance/qr-token.ts`). A second scan within 2 minutes is ignored.
- Cookie sessions require the `x-gm-client` header on writes (CSRF). Mobile uses Bearer tokens.
- Secrets only in environment variables (`apps/api/.env.example`).
- Every change to memberships, plans, staff and SaaS plans writes `audit_logs`.

## Working in this sandbox

npm and PyPI are blocked here; GitHub works. The `deps-snapshot` workflow installs `node_modules` on GitHub and pushes it to the `devdeps` branch as split tarballs; extract them to work offline. Postgres binaries come from the `@embedded-postgres/linux-x64` package (run `initdb`/`pg_ctl` as a non-root user). Prisma engines are in `node_modules/@prisma/engines`; set `PRISMA_QUERY_ENGINE_LIBRARY` and `PRISMA_SCHEMA_ENGINE_BINARY`. Flutter is not available locally; the `mobile` workflow analyzes, tests, builds and publishes the APK as a GitHub release.

## Commands

```
pnpm install
pnpm --filter @gymmantra/api exec prisma migrate dev
pnpm --filter @gymmantra/api seed          # demo data for the two pilot gyms
TEST_DATABASE_URL=... pnpm --filter @gymmantra/api test
pnpm --filter @gymmantra/admin build && pnpm --filter @gymmantra/api build
cd apps/api && node dist/main.js           # API + admin on :4000
```

## Next

- Push notifications (FCM) for membership updates and ticket replies.
- Workout tracker (sets, reps, rest timer) and assigned plans in the member app.
- Hindi translations (the language choice is already stored).
- Phone OTP login.
- SaaS billing for gyms (card/UPI) after the free trial.
