# CLAUDE.md — GymMantra build instructions

Read this file first, then `docs/MVP_SPEC.md`. The spec is the source of truth for features and business rules. The screen designs in `design/screens/` and the clickable prototype `design/prototypes/admin-prototype.html` show how each screen should look and behave.

The owner speaks Hinglish. Reply in simple Hinglish, keep explanations short, and explain any command they need to run.

## Product in one paragraph

GymMantra is multi-tenant gym software for India. Each gym (tenant) has its own plans, members and staff. **Memberships are manual:** gym staff add or renew a membership in the admin panel (plan, dates, price, discount, amount received, payment mode). The member app only *shows* what the gym entered. Members never pay online in the MVP. Attendance is by a rotating QR code that front desk staff scan.

## Build order

Build admin side first. Do not start the member app until Phase 3 is done.

### Phase 1 — Backend (`apps/api`)
- NestJS modular monolith, TypeScript, REST under `/api/v1`, OpenAPI docs at `/api/docs`.
- PostgreSQL + Prisma. All 12 MVP tables from the spec: users, tenants, gym_branches, gym_staff, gym_members, join_requests, membership_plans, member_subscriptions, attendance_events, support_tickets, ticket_messages, audit_logs. Add `saas_plans` and `tenant_subscriptions` for the super admin plans.
- Auth: Firebase phone OTP on the client, verify the Firebase ID token on the server, then issue our own session (JWT access + refresh).
- Modules: auth, tenants, branches, staff, members, join-requests, plans, memberships, attendance, tickets, audit, saas-plans (super admin).
- Seed script with the two pilot gyms (Lifetime Fitness, Athlete Gym — Dwarka Sector 7), sample plans and about 30 sample members.
- Tests for every business rule below (Jest). Run them before saying a phase is done.

### Phase 2 — Admin panel (`apps/admin`)
- Next.js (App Router), TypeScript, Tailwind. Dark theme with the brand colors below.
- Screens: Login (phone OTP), Dashboard, Members (tabs + search + bulk WhatsApp reminder + Excel import), Member profile with Add/Renew membership form and history, Membership plans, Attendance (camera QR scan + manual check-in), Member support inbox, Staff, Gym profile + gym code + printable QR poster.
- Super admin area (`/super`): gyms list, verify/suspend gym, SaaS plans editor (price, limits, features, trial length, custom price per gym), app-problem tickets.
- Match `design/prototypes/admin-prototype.html` closely. Make it work on a phone-sized screen too (front desk often uses a phone).

### Phase 3 — Pilot
- Deploy backend + admin panel. Help the owner onboard Lifetime Fitness and Athlete Gym.
- Gate: a pilot gym uses the admin panel daily for 30 days.

### Phase 4 — Member app (`apps/mobile`)
- Flutter, Riverpod, GoRouter, Dio, flutter_secure_storage. English + Hindi.
- Screens from the spec: Login, Join gym, Home, My membership, Gym plans (view only), QR check-in, Workouts (with 3D guide videos from `media/exercises/`), Profile (photo upload), Help & Support (FAQ + in-app chat + tickets; **never show an email address**).
- Use the app icons and splash screen from `brand/`.

## Business rules (must be enforced on the server and covered by tests)

- **Status:** Active = end date more than 7 days away · Ending soon = 0–7 days · Expired = end date passed · No plan = approved member with no membership.
- **End date** = start date + plan months − 1 day (staff can edit).
- **Renewal:** if current membership is active, new one starts the day after current end date; if expired, starts today.
- **Joining fee** only on a member's first membership.
- **Amount received** defaults to price − discount. Both owner and front desk can give a discount.
- **Payment modes:** Cash, UPI, Card, Bank transfer, Not paid yet (shown as due).
- **member_subscriptions is insert-only.** Never update or delete a row. A correction is a new row.
- **Plan price change** affects only new and renewed memberships.
- **Attendance:** Active and Ending soon → allowed (Ending soon shows a warning). Expired and No plan → blocked. A second scan by the same member within 2 minutes is ignored. The member QR is a signed token that changes every 30 seconds; reject old tokens.
- **Tickets:** membership / check-in / facility → the member's gym. App problems (login, sync, crash) → GymMantra support.
- **Roles:** owner can do everything for their gym; front desk cannot create/edit plans, change prices or add staff; front desk sees only assigned branches.
- **Audit log:** every change to memberships, plans, staff and SaaS plans writes before/after to `audit_logs`.
- **SaaS plans:** Starter ₹399/₹3,990 (150 members, 1 branch), Growth ₹799/₹7,990 (500 members, 1 branch), Pro ₹1,399/₹13,990 (unlimited, 3 branches). 3-month free trial with Pro features. These are seed data only; the super admin edits them from the panel. A price change applies to new gyms now and to existing gyms at their next renewal, with a notice 7 days before.

## Security rules (never break these)

- **Tenant isolation:** every gym-owned table has `tenant_id`. Turn on PostgreSQL row-level security and set the tenant per request. The server works out the user's tenant from their session. **Never trust a `tenant_id` sent by the client.**
- Write a test that proves gym A cannot read or change gym B's data through any endpoint.
- All secrets (database URL, Firebase service account, WhatsApp token, S3 keys, JWT secret) come from environment variables. Commit only `.env.example`. Never commit `.env`.
- Validate every request body (class-validator / zod). Rate-limit OTP and login endpoints.
- Profile photos and ticket screenshots go to S3-compatible storage with short-lived signed URLs.
- Members can export or delete their account.

## Repo layout to create

```
apps/
  api/        NestJS backend
  admin/      Next.js admin panel + super admin
  mobile/     Flutter member app (Phase 4)
packages/
  shared/     shared TypeScript types (API DTOs, status enums)
docs/  design/  brand/  media/   (already here)
docker-compose.yml   Postgres + Redis for local dev
```

Use pnpm workspaces for the TypeScript apps.

## Brand

- Colors: Ink `#0F1110`, Lime `#C8FF3E`, Off-white `#F3F6F1`, Dark lime `#4D7C0F` (on light backgrounds), card `#161917`, line `#262B27`, orange warning `#FF7A2F`.
- Font: Archivo.
- Name: GymMantra. Tagline: "Fitness ka sahi mantra." (splash, login, store listing).
- Logo: B (Dumbbell M). SVGs in `brand/logo/`.

## Exercise media

`media/exercises/exercises.json` lists all 40 exercises with name, target muscle, video and still paths. Upload these to storage and seed an `exercises` table from this file in Phase 4.

## Working style

- Work one phase at a time. At the end of each phase, run the tests and lint, then tell the owner in plain Hinglish what works and how to try it.
- Ask the owner before adding any paid service or changing a business rule.
- Open questions still waiting on the owner are listed at the end of `docs/MVP_SPEC.md`. Use the safest default and note it until they answer.
