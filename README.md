# GymMantra

**Fitness ka sahi mantra.**

GymMantra is gym management software for Indian gyms. It has three parts:

- **Admin panel (web):** gym owners and front desk staff manage members, plans, manual memberships, attendance and support tickets.
- **Member app (Android and iOS):** members see their membership and their gym's plans, check in with a rotating QR code, track workouts with 3D exercise guides, and get help inside the app.
- **Super admin:** the GymMantra team manages gyms and the SaaS plans that gyms pay for.

Pilot gyms: **Lifetime Fitness** and **Athlete Gym**, both in Dwarka Sector 7, New Delhi.

## Status

Design and planning are done. The code has not been written yet. Building it is the next step. See [`CLAUDE.md`](CLAUDE.md) for the build plan.

## What's in this repo

| Folder | Contents |
| --- | --- |
| `docs/MVP_SPEC.md` | The MVP spec: roles, screens, business rules, data model, stack, pricing |
| `docs/ORIGINAL_BRIEF.md` | The full original product brief (long-term vision, beyond the MVP) |
| `design/screens/` | 28 screen designs (PNG) for the admin panel, member app and super admin |
| `design/prototypes/admin-prototype.html` | Clickable admin panel prototype. Open it in a browser |
| `design/prototypes/form-check-3d.html` | 3D exercise guide with all 40 exercises (three.js) |
| `design/logo/` | The three logo directions. **B (Dumbbell M) is final** |
| `brand/` | Final app icons (Android, iOS, web), logo SVGs, splash screen, colors |
| `media/exercises/` | 40 pre-rendered 3D exercise videos and stills, plus `exercises.json` |
| `media/promo/` | Promo and reel videos (older ones still say "RepForge", the earlier working name) |

## Brand

| Token | Hex |
| --- | --- |
| Ink (background) | `#0F1110` |
| Lime (accent) | `#C8FF3E` |
| Off-white (text) | `#F3F6F1` |
| Dark lime (accent on light backgrounds) | `#4D7C0F` |

Font: **Archivo** (Google Fonts).

## Pricing for gyms

Every gym gets 3 months free. After that:

| Plan | Monthly | Annual |
| --- | --- | --- |
| Starter | ₹399 | ₹3,990 |
| Growth | ₹799 | ₹7,990 |
| Pro | ₹1,399 | ₹13,990 |

Prices exclude 18% GST. The super admin can change plans, prices, limits and features at any time.
