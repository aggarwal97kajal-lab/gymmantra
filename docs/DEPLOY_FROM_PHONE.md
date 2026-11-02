# GymMantra ko online kaise karein (sirf phone se)

Do free accounts chahiye, dono mein credit card ki zaroorat nahi:
- **Firebase** (Google ka): login aur database
- **Cloudflare**: server, website aur videos

Kul samay lagbhag 25 minute. Phone ke browser mein "Desktop site" on kar loge toh screens aasaan dikhenge.

---

## Part A — Firebase (10 minute)

**A1. Project banao**
1. **console.firebase.google.com** kholo aur apne Google account se login karo.
2. **Create a project** dabao → naam `gymmantra` → Continue.
3. Google Analytics ko **off** kar do → **Create project**.

**A2. Login on karo**
1. Left menu: **Build → Authentication → Get started**.
2. **Sign-in method** tab → **Email/Password** → pehla switch **Enable** → **Save**.

**A3. Server ka account banao**
1. Authentication ke andar **Users** tab → **Add user**.
2. Email: `server@gymmantra.internal`
3. Password: koi lamba password (kam se kam 16 akshar). Ise kahin likh lo, Part B mein lagega.

   Ye account sirf GymMantra server ke liye hai. Kisi ko mat batana.

**A4. Database banao**
1. Left menu: **Build → Firestore Database → Create database**.
2. Location: **asia-south1 (Mumbai)** → Next.
3. **Start in production mode** → **Create**.

**A5. Database ko lock karo (rules)**
1. Firestore mein **Rules** tab kholo.
2. Jo bhi likha hai sab hata ke ye paste karo:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if request.auth != null
        && request.auth.token.email == 'server@gymmantra.internal'
        && request.auth.token.firebase.sign_in_provider == 'password';
    }
  }
}
```

3. **Publish** dabao.

Isse database sirf GymMantra server khol sakta hai, koi aur nahi.

**A6. Do cheezein copy karo**
1. Upar left mein ⚙️ → **Project settings → General**.
2. **Project ID** copy karo (jaise `gymmantra-1a2b3`).
3. **Web API Key** copy karo.
   - Agar Web API Key nahi dikhti, toh neeche **Your apps** mein `</>` (Web) dabao.
   - Naam `gymmantra-web` do → Register.
   - Jo code dikhe usme `apiKey: "..."` wali value copy karo.

---

## Part B — Cloudflare (10 minute)

**B1. Account banao**
- **dash.cloudflare.com** kholo → **Sign up** (email + password) → email verify karo.

**B2. GitHub repo jodo**
1. Left menu: **Compute (Workers) → Workers & Pages → Create**.
2. **Import a repository** → **GitHub** jodo → `gymmantra` repo choose karo.
3. Ye bharo:
   - Project name: `gymmantra`
   - Build command: `pnpm run build:cf`
   - Deploy command: `npx wrangler deploy`
   - Root directory: khaali (ya `/`)
4. **Create and deploy** dabao. Pehla build 5–10 minute leta hai.

**B3. Settings daalo**
1. Worker kholo → **Settings → Variables and Secrets → Add**.
2. Ye chaar cheezein daalo:

| Naam | Type | Value |
| --- | --- | --- |
| `FIREBASE_PROJECT_ID` | Text | A6 wala Project ID |
| `FIREBASE_API_KEY` | Text | A6 wali Web API Key |
| `SERVER_PASSWORD` | **Secret** | A3 wala password |
| `SUPER_ADMIN_EMAIL` | Text | aapka apna email (isse aap super admin banoge) |

3. **Deploy** dabao.

**B4. Apna link dekho**
- Worker ke page pe link dikhega, jaise `https://gymmantra.aapka-naam.workers.dev`.
- Ye link **mujhe bhej do**, main member app ko isi link se jod ke nayi APK bana dunga.
- **Enable Preview builds** ko off rakhna; GitHub pe kuch extra branches hain jinke builds bekaar chalenge.

---

## Part C — Pehli baar use karna

1. Apna link kholo → **Create an account**.
   Wahi email use karo jo `SUPER_ADMIN_EMAIL` mein daala tha. Aapko **Super admin** milega.
2. Gym owner apna account banake **Register your gym** karein.
   Ya aap khud bana do, aur Staff page se unhe Owner bana do.
3. Har gym mein ye karo:
   - **Membership plans** banao.
   - **Gym settings** mein gym ka WhatsApp number daalo.
   - QR poster print karke front desk pe lagao.
4. Members **Releases** se `GymMantra.apk` download karke install karein.

## Free limits (pilot ke liye kaafi)

- **Cloudflare:** din ke 1,00,000 requests.
- **Firebase Firestore:** din ke 50,000 reads aur 20,000 writes, aur 1 GB data.
- **Kam reads ka intezaam:** saare members ki list ek hi record mein rakhi hai, isliye dashboard aur members page khulne pe sirf 1–2 reads lagti hain.

## Google login (baad mein, optional)

Iske liye Google Cloud mein OAuth Client ID chahiye:
- website ke liye "Web" client ID
- app ke liye "Android" client ID, package `com.gymmantra.gymmantra` aur SHA-1 `4B:43:F7:B1:5D:B9:3B:D2:FD:7E:7D:8F:36:9D:C2:8B:A9:22:67:97`

Web client ID ko Cloudflare mein `GOOGLE_CLIENT_IDS` naam se daal do. Tab tak Google button chhupa rahega.
