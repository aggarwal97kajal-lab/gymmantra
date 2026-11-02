import Link from 'next/link';

// Same text as in the app (lib/screens/legal.dart). Public page for the Play Store listing.
const SECTIONS: [string, string][] = [["What we collect", "Name, mobile number, email, password (stored securely by Google Firebase, never readable by us), profile photo, and — only if you add them — date of birth, gender and address. Gyms add membership, payment, freeze and check-in records. Trainers add session marks, diet charts and workout plans."], ["Why we use it", "To run your membership and check-ins, show your plan, PT sessions and dues, send you reminders and notices from your gym, give support, and keep the app safe."], ["Who can see it", "You. Your gym’s owner and front desk see their own members. Your trainer sees only their PT clients. GymMantra support sees what is needed to help you. We do not sell your data and we do not show it to other gyms."], ["Location", "Used only at the moment you scan the gym’s check-in QR, to confirm you are inside the gym. We do not track you and we do not keep your location history."], ["Camera and photos", "The camera is used only to scan the check-in QR and to take a profile photo. Photos are used only as your profile picture."], ["Where it is stored", "On Google Firebase and Cloudflare servers with encryption in transit. Trainer PDFs open only inside the app with your name on them."], ["How long", "As long as your account is active. When you delete your account, your login and profile are removed; your gym may keep its membership and payment records as the law requires."], ["Your rights", "See and correct your details in Profile. Download your data or delete your account in Profile → Privacy. Ask us anything at support@gymmantra.app."], ["Children", "Members under 18 should use the app with a parent’s or guardian’s consent."], ["Changes", "If we change this policy we will update the date at the top and tell you in the app."]];

export const metadata = { title: 'Privacy Policy · GymMantra' };

export default function Page() {
  return (
    <main style={{ maxWidth: 760, margin: '0 auto', padding: '40px 20px 60px', lineHeight: 1.6 }}>
      <Link href="/" className="small">← GymMantra</Link>
      <h1 style={{ fontSize: 30, margin: '14px 0 4px' }}>Privacy Policy</h1>
      <div className="mut small">Last updated: 2 Nov 2026</div>
      {SECTIONS.map(([h, p], i) => (
        <section key={h} style={{ marginTop: 22 }}>
          <h2 style={{ fontSize: 18, marginBottom: 4 }}>{i + 1}. {h}</h2>
          <p className="mut">{p}</p>
        </section>
      ))}
      <p className="small mut" style={{ marginTop: 30 }}>
        See also: <Link href="/terms">Terms & Conditions</Link>
      </p>
    </main>
  );
}
