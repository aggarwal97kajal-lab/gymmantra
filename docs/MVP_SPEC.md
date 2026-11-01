# GymMantra MVP Spec

Nov 1, 2026

## Overview

The first release of GymMantra is a gym admin web panel plus a member mobile app, launched with 1–2 pilot gyms in India. The gym admin controls everything about memberships by hand; the member app only shows what the gym has entered.

- **Who pays:** gym owners, through a monthly or annual GymMantra subscription.
- **Who uses it daily:** front desk staff on the admin panel, members on the app.
- **Goal of the MVP:** a pilot gym runs its members, plans, renewals and attendance on GymMantra for 30 days without going back to registers or spreadsheets.
- **Design reference:** the clickable admin prototype and the screen images shared in chat on 1 Nov 2026.

**Brand:** GymMantra · tagline "Fitness ka sahi mantra." The tagline appears on the splash screen, the login screen and the app store listing.

## Users and roles

The MVP has four roles. One person can hold more than one role, and a member can belong to more than one gym.

| Role | Uses | Can do | Cannot do |
| --- | --- | --- | --- |
| Gym owner | Admin panel | Everything for their own gym: plans, prices, staff, members, memberships, reports | See any other gym's data |
| Front desk | Admin panel | Approve join requests, add and renew memberships, record payments, run attendance, answer member tickets | Create or edit plans, change prices, add staff |
| Member | Mobile app | Log in, join a gym, see their membership and the gym's plans, check in by QR, track workouts, raise tickets | Change their own membership or pay online |
| GymMantra support | Super admin panel | Answer app-problem tickets, suspend or verify gyms | Edit a gym's members or payments without an audit log entry |

## Admin panel (web)

Six screens cover the MVP. Each matches a page in the clickable prototype.

| Screen | What it does |
| --- | --- |
| Dashboard | Counts of active, ending in 7 days and expired members; money collected today; a renewals-due list with a Renew button; pending join requests |
| Members | Search by name, phone or member ID. Tabs: All, Active, Ending in 7 days, Expired, Join requests. Select several members and send a WhatsApp renewal reminder. Add a member by hand. Bulk import from Excel |
| Member profile | Profile, current membership, and the Add or Renew membership form: plan, start date, auto end date (editable), price, discount, amount received, payment mode, received by, note, WhatsApp receipt, in-app notification. Full membership history with who added each entry |
| Membership plans | Create and edit plans: name, months, price, joining fee, freeze days, what's included, Show in app toggle. Shows how many active members are on each plan |
| Attendance | Scan a member's QR on a phone or tablet camera. Shows Allowed, Allowed · ends soon, or Blocked with a Renew now button. Manual check-in. Today's check-ins, people in the gym now, blocked count |
| Member support | Tickets from members of this gym only. Chat replies, quick replies, mark resolved, open the member's profile |

Also needed: staff accounts (owner adds front desk users), gym profile (name, logo, address, hours, branches) and a gym code plus a printable QR poster for members to join.

## Member app (Android and iOS)

The app has no online payment and no buy button. Members see their gym's data and contact the gym to renew.

| Screen | What it does |
| --- | --- |
| Login | Mobile number and 6-digit SMS OTP. English and Hindi |
| Join gym | Enter the gym code or scan the gym's QR poster, pick a branch, send a join request. Skip to use the app without a gym |
| Home | Today's workout, streak, weight trend, membership days left |
| My membership | Plan, days left, start and end dates, amount paid, payment mode, "Updated by your gym" with staff name and date. Call gym and WhatsApp buttons. Expired and no-plan states |
| Gym plans | Plans the gym has set to Show in app, view only, with an Ask gym enquiry button |
| QR check-in | Rotating QR code for the front desk to scan, visits this month |
| Workouts | Assigned plan, set and rep tracker with rest timer, workout history, 3D exercise guide videos |
| Profile | Profile photo (camera or gallery, crop, remove), edit name and details, notifications, language, privacy |
| Help & Support | Search, FAQ by topic, in-app chat, raise a ticket with a screenshot, my tickets with status. No email address is shown anywhere |

Push notifications in the MVP: membership added or renewed, membership ending in 7, 3 and 1 days, ticket reply, gym announcement.

## Business rules

**Plans**

- Each gym creates its own plans. Plans of one gym are never visible to another gym.
- A plan hidden from the app can still be assigned by staff (for example a student plan given on request).
- Changing a plan's price affects only new and renewed memberships. Existing memberships keep the price that was recorded.

**Memberships (manual only)**

- Only gym staff can create, renew or change a membership. Members cannot.
- End date = start date + plan months − 1 day, filled in automatically and editable by staff.
- Renewal of an active membership starts the day after the current end date. Renewal of an expired one starts today.
- Joining fee is added only to a member's first membership.
- Amount received defaults to price − discount and can be changed. Payment modes: Cash, UPI, Card, Bank transfer, Not paid yet.
- "Not paid yet" saves the membership with the amount shown as due.
- Every save writes a history entry with the staff name and time. Entries are never edited or deleted; a correction is a new entry.
- Saving updates the member's app immediately and, if ticked, sends a WhatsApp receipt and an in-app notification.

**Status**

| Status | Rule |
| --- | --- |
| Active | End date is more than 7 days away |
| Ending soon | End date is 0–7 days away |
| Expired | End date has passed |
| No plan | Member approved but no membership added yet |

**Attendance**

- Active and Ending soon members are allowed in. Ending soon shows a warning to staff.
- Expired and No plan members are blocked, and staff see a Renew now button.
- A second scan within 2 minutes is ignored, so one visit is not counted twice.
- The member's QR changes every 30 seconds so a screenshot cannot be reused.

**Support tickets**

- Membership, check-in and gym facility topics go to the member's gym.
- App problems (login, sync, crashes) go to GymMantra support.
- No email address is shown to members; all support happens in the app.

## Data model

Twelve PostgreSQL tables cover the MVP. Every gym-owned table carries `tenant_id`, and row-level security limits each query to the signed-in user's gym. All primary keys are UUIDs.

| Table | Key fields |
| --- | --- |
| users | id, phone, name, photo\_url, language, created\_at |
| tenants | id, gym\_name, logo\_url, gym\_code, status (trial, active, suspended) |
| gym\_branches | id, tenant\_id, name, address, hours |
| gym\_staff | id, tenant\_id, user\_id, role (owner, front\_desk), branch\_ids |
| gym\_members | id, tenant\_id, user\_id, member\_code (IRF-20418), branch\_id, joined\_on, status |
| join\_requests | id, tenant\_id, user\_id, branch\_id, status (pending, approved, declined), decided\_by |
| membership\_plans | id, tenant\_id, name, months, price, joining\_fee, freeze\_days, features, show\_in\_app |
| member\_subscriptions | id, tenant\_id, member\_id, plan\_id, start\_date, end\_date, price, discount, amount\_received, payment\_mode, received\_by, note, created\_by, created\_at (insert only) |
| attendance\_events | id, tenant\_id, member\_id, branch\_id, scanned\_at, result (allowed, warned, blocked), scanned\_by |
| support\_tickets | id, tenant\_id (empty for app problems), member\_id, topic, subject, status, routed\_to (gym, gymmantra) |
| ticket\_messages | id, ticket\_id, author\_id, body, attachment\_url, created\_at |
| audit\_logs | id, tenant\_id, actor\_id, action, entity, entity\_id, before, after, created\_at |

The full schema in the original brief (trainers, nutrition, marketplace, finance, SaaS billing) is added in later phases on top of these tables.

## Tech stack, integrations and security

The stack follows the original brief, trimmed to what the MVP uses.

| Part | Choice |
| --- | --- |
| Member app | Flutter, Riverpod, GoRouter, Dio, secure storage, offline cache for QR and workouts |
| Admin panel | Next.js, TypeScript, Tailwind CSS |
| Backend | NestJS modular monolith, REST under /api/v1, background jobs on Redis |
| Database | PostgreSQL with Prisma, migrations, row-level security per gym |
| Login | Firebase Authentication with phone OTP |
| Push | Firebase Cloud Messaging |
| WhatsApp | Official WhatsApp Business API for receipts and renewal reminders |
| Files | S3-compatible storage with signed URLs for profile photos and ticket screenshots |
| Errors | Sentry |
| 3D exercise guides | Pre-rendered MP4 videos stored as exercise media |

**Security rules**

- The server decides which gym a user belongs to from their login. A gym ID sent by the app is never trusted.
- Front desk staff see only their assigned branches.
- Profile photos are visible only to the member, their gym's staff and their trainer.
- MFA for owners and GymMantra staff. Every change to memberships, plans and staff is written to the audit log.
- All secrets and API keys live in environment variables, never in code.
- Members can export or delete their account from Profile › Privacy.

## Not in the MVP

These features from the original brief move to later phases, so the pilot can launch sooner.

- **Phase 2:** trainer app (clients, sessions, commissions), diet and nutrition with the Indian food database, group class booking, body measurements and progress photos, expenses and profit and loss reports, inventory and equipment.
- **Phase 3:** marketplace for gym, trainer and nutritionist discovery, AI workout and diet planners, camera-based AI form check, super admin revenue analytics, SaaS billing by card or UPI.
- **Not planned:** online membership payment by members, since the gym records every payment by hand.

## Build plan

The build runs in four phases, admin side first, because the member app only shows data the gym has entered.

1. **Phase 1 — Backend (NestJS + PostgreSQL):** auth (phone OTP), tenants, branches, staff, members, join requests, plans, manual memberships, attendance, tickets, audit log.
2. **Phase 2 — Admin panel (Next.js):** the six admin screens plus staff, gym profile, gym code/QR poster, and the super admin SaaS plans screen.
3. **Phase 3 — Pilot:** Lifetime Fitness and Athlete Gym (Dwarka Sector 7) use the admin panel daily.
4. **Gate:** 30 days of daily use by a pilot gym.
5. **Phase 4 — Member app (Flutter):** login, join gym, membership, plans, QR check-in, workouts with 3D guides, profile, Help & Support.

The member app starts after a pilot gym has used the admin panel daily for 30 days. Dates are set once the developer or Claude Code environment is ready.

## Pricing for gyms (proposal)

Every gym gets its first 3 months free. After that, a gym picks one of three plans; annual billing gives 2 months free. Prices are before 18% GST.

| Plan | Monthly | Annual | Members | Branches | Includes |
| --- | --- | --- | --- | --- | --- |
| Starter | ₹399 | ₹3,990 | Up to 150 | 1 | Admin panel, member app, plans, manual memberships, QR attendance, support inbox |
| Growth | ₹799 | ₹7,990 | Up to 500 | 1 | Starter + WhatsApp reminders and receipts, Excel import, reports |
| Pro | ₹1,399 | ₹13,990 | Unlimited | Up to 3 | Growth + 3D exercise guides, multi-branch view, priority support |

These are starting prices. The super admin can change any of them at any time from the super admin panel (see below).

WhatsApp message charges from Meta are passed on at cost. Larger chains get a custom quote.

For comparison, cloud gym software for a small Indian gym typically costs ₹1,000–₹3,500 a month ([Easy Gym Software](https://easygymsoftware.com/blog/gym-software-pricing-in-india)), and listed products range from about ₹500 to ₹6,000 a month ([Codingclave](https://codingclave.com/blog/best-gym-management-software-india-2026)).

**Super admin controls SaaS plans**

The GymMantra super admin manages the plans gyms pay for, whenever and however they choose, with no code change or app release.

- Create, edit, rename, hide or retire a plan.
- Set the monthly and annual price, GST shown, and an optional launch discount.
- Set limits per plan: members, branches, staff accounts, WhatsApp messages.
- Turn features on or off per plan, for example 3D exercise guides or Excel import.
- Set the free trial length (currently 3 months) for all new gyms or extend it for one gym.
- Give a gym a custom price or move it to another plan.
- A price change applies to new gyms and to existing gyms at their next renewal; gyms are told in the admin panel 7 days before. Every change is written to the audit log.

## Open questions

- [x] Pilot gyms: Lifetime Fitness and Athlete Gym, both in Dwarka Sector 7, New Delhi.
- [x] Discounts: both the owner and front desk staff can give discounts.
- [x] Gym pricing: first 3 months free, then the plans in Pricing above.
- [ ] App name chosen: GymMantra. Still to check: the .in and .com domains, Play Store and App Store listings, and a trademark search.
- [ ] Are "Not paid yet" members allowed in at the door?
- [ ] Freeze membership: needed in the MVP or Phase 2?
- [ ] Who owns the WhatsApp Business number: GymMantra or each gym?
