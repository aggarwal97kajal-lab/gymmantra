# GymMantra

**Fitness ka sahi mantra.**

Gym management software for Indian gyms: an admin panel for gym owners and front desk, a member app for Android, and a super admin for the GymMantra team.

Pilot gyms: **Lifetime Fitness** and **Athlete Gym**, Dwarka Sector 7, New Delhi.

## What's here

| Folder | Contents |
| --- | --- |
| `apps/worker` | Server: Cloudflare Worker with Firebase login and Firestore database. Also serves the admin panel and exercise videos |
| `apps/admin` | Admin panel and super admin (Next.js) |
| `apps/mobile` | Member app (Flutter). Each push builds an APK under **Releases** |
| `docs/MVP_SPEC.md` | What the MVP does and its business rules |
| `docs/DEPLOY_FROM_PHONE.md` | How to put GymMantra online using only a phone |
| `design/` | Screen designs, clickable prototypes, logos |
| `brand/` | App icons, logo files, splash screen |
| `media/exercises/` | 39 exercise guide videos (wrong vs correct form) in 7 categories, with stills |

## Get the member app

Open the repository's **Releases** page on your Android phone, download `GymMantra.apk` from the latest release and install it.

## Pricing for gyms

First 3 months free, then Starter ₹399/month (₹3,990/year), Growth ₹799 (₹7,990), Pro ₹1,399 (₹13,990), plus 18% GST. The super admin can change these at any time.
