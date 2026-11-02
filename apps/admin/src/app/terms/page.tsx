import Link from 'next/link';

// Same text as in the app (lib/screens/legal.dart). Public page for the Play Store listing.
const SECTIONS: [string, string][] = [["Who we are", "GymMantra is an app that helps gyms manage members, memberships, payments, check-ins, trainers and personal training. Gyms (owners) use it to run their gym; members and trainers use it to see their own details."], ["Your account", "Give your correct name, mobile number and email. Keep your password secret; you are responsible for what happens in your account. One person, one account. Pick the right role (member, trainer or gym owner) — an account cannot switch roles once it is linked to a gym."], ["You and your gym", "Your membership, its price, fees, freezes, refunds and the gym rules are agreed between you and your gym. GymMantra keeps the records the gym enters and is not a party to that agreement."], ["Payments", "Money you pay at the gym (cash, UPI, card or bank) is received by the gym, not by GymMantra. The app shows what the gym recorded. If something looks wrong, ask your gym or raise a ticket."], ["Gym owners", "Owners must have the right to add the people they add, keep their data correct, and use it only to run their gym. The free trial and GymMantra plans, prices and features are shown in the app; plans can change with notice."], ["Trainers", "Trainers see only their own clients. Diet charts and workout plans are general fitness guidance by the trainer, not medical advice. Check with a doctor before starting any programme if you have a health condition."], ["Fair use", "Do not create fake accounts, check in for someone else, share or copy a trainer’s PDF, misuse the check-in QR, or try to break or overload the app. We may suspend accounts that do."], ["Health and safety", "Exercise carries risk. GymMantra is not responsible for injuries in the gym. Follow your trainer and the gym’s safety rules."], ["Changes and ending", "We may improve or change the app and these terms; we will show the new date here. You can stop using the app and delete your account any time (Profile). Gym records may be kept by the gym as the law requires."], ["Contact", "Questions: FAQ & Support → Mail us, or support@gymmantra.app. These terms follow the laws of India; courts in New Delhi have jurisdiction."]];

export const metadata = { title: 'Terms & Conditions · GymMantra' };

export default function Page() {
  return (
    <main style={{ maxWidth: 760, margin: '0 auto', padding: '40px 20px 60px', lineHeight: 1.6 }}>
      <Link href="/" className="small">← GymMantra</Link>
      <h1 style={{ fontSize: 30, margin: '14px 0 4px' }}>Terms & Conditions</h1>
      <div className="mut small">Last updated: 2 Nov 2026</div>
      {SECTIONS.map(([h, p], i) => (
        <section key={h} style={{ marginTop: 22 }}>
          <h2 style={{ fontSize: 18, marginBottom: 4 }}>{i + 1}. {h}</h2>
          <p className="mut">{p}</p>
        </section>
      ))}
      <p className="small mut" style={{ marginTop: 30 }}>
        See also: <Link href="/privacy">Privacy Policy</Link>
      </p>
    </main>
  );
}
