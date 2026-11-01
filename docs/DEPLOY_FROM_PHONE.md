# GymMantra ko online kaise karein (sirf phone se)

Kul samay: lagbhag 20–30 minute. Do free accounts chahiye: **Neon** (database) aur **Render** (server). Credit card ki zaroorat nahi.

## Step 1 — Database (Neon)

1. Phone ke browser mein **neon.com** kholo → **Sign up** → "Continue with Google".
2. Project name: `gymmantra`. Region: **Asia Pacific (Singapore)**. **Create project** dabao.
3. Dashboard pe **Connect** button dabao.
4. **Connection pooling** ka switch **OFF** karo.
5. Jo link dikhe use **Copy** karo. Woh `postgresql://...neon.tech/neondb?sslmode=require` jaisa dikhega.
   Is link ko kisi ke saath share mat karna.

## Step 2 — Server (Render)

1. **render.com** kholo → **Get started** → "GitHub" se sign up karo.
2. GitHub poochega ki kaunsi repositories dikhani hain → `gymmantra` choose karo.
3. Render mein **New +** → **Blueprint** dabao.
4. `aggarwal97kajal-lab/gymmantra` choose karo. Render khud `render.yaml` padh lega.
5. Ye teen cheezein bharni hongi:
   - **DATABASE_URL**: Step 1 wala Neon link paste karo.
   - **SUPER_ADMIN_EMAIL**: apna email (isi email se signup karoge to aap super admin banoge).
   - **GOOGLE_CLIENT_IDS**: abhi khaali chhod do.
6. **Apply** dabao. Pehli baar build mein 10–15 minute lagte hain.
7. Jab "Live" dikhe, upar aapka link hoga, jaise `https://gymmantra.onrender.com`.

## Step 3 — Pehli baar login

1. Render wala link kholo → **Create an account**.
   Usi email se karo jo SUPER_ADMIN_EMAIL mein dala tha.
2. Aapko **Super admin** dikhega. Wahan se saare gyms aur SaaS plans manage hote hain.
3. Pilot gyms ke liye do raaste hain:
   - Gym owner khud signup karke **Register your gym** karein.
   - Ya aap unke liye account bana do, aur Staff page se unhe Owner bana do.
4. Har gym mein ye karna hai:
   - **Membership plans** banao.
   - **Gym settings** mein WhatsApp number daalo.
   - QR poster print karke front desk pe lagao.

## Step 4 — Member app (Android)

1. GitHub app ya browser mein repo kholo → **Releases** → sabse upar wali release → **GymMantra.apk** download karo.
2. Install karte waqt phone "unknown apps" ki permission maangega → allow karo.
3. App apne aap `https://gymmantra.onrender.com` se judti hai.
   Agar aapka Render link alag hai, toh do raaste hain:
   - Login screen pe **logo ko dabaye rakho** (long-press) aur apna link daalo.
   - Ya mujhe link batao, main app dobara bana dunga.

## Dhyaan rakhne wali baatein

- **Free server so jaata hai:** agar 15 minute tak koi use na kare, toh Render ka free server so jaata hai. Agla khulna ~1 minute leta hai. Pilot shuru hone pe Render ka **Starter** plan (~$7/month) le lo, taaki server hamesha chalu rahe.
- **Free hours ki limit:** free plan mein mahine ke 750 ghante milte hain. Ek hi service hai, toh normal use mein kaafi hai.
- **Neon database:** free plan permanent hai (expire nahi hota), 1 GB tak data — hazaaron members ke liye kaafi.
- **Updates:** GitHub pe naya code aate hi Render khud update ho jaata hai.

## Google login (baad mein, optional)

Iske liye Google Cloud mein OAuth Client ID banana padta hai:
- website ke liye "Web" client ID
- app ke liye "Android" client ID, package `com.gymmantra.gymmantra` aur SHA-1 `4B:43:F7:B1:5D:B9:3B:D2:FD:7E:7D:8F:36:9D:C2:8B:A9:22:67:97`

Web client ID ko Render ke **GOOGLE_CLIENT_IDS** mein daal do. Jab tak ye nahi hota, Google button chhupa rahega aur email/mobile + password login chalta rahega.
