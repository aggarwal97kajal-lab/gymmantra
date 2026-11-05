import Link from 'next/link';
import { LEGAL_UPDATED, TERMS } from '../legal-text';

// Same text as in the app (lib/legal_text.dart). Public page for the Play Store listing.
export const metadata = { title: 'Terms & Conditions · GymMantra' };

const updated = new Date(`${LEGAL_UPDATED}T00:00:00Z`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });

export default function Page() {
  return (
    <main style={{ maxWidth: 760, margin: '0 auto', padding: '40px 20px 60px', lineHeight: 1.6 }}>
      <Link href="/" className="small">← GymMantra</Link>
      <h1 style={{ fontSize: 30, margin: '14px 0 4px' }}>Terms & Conditions</h1>
      <div className="mut small">Last updated: {updated}</div>
      {TERMS.map(([h, paras], i) => (
        <section key={h} style={{ marginTop: 22 }}>
          <h2 style={{ fontSize: 18, marginBottom: 4 }}>
            {i + 1}. {h}
          </h2>
          {paras.map((t, j) => (
            <p key={j} className="mut" style={{ margin: '6px 0', paddingLeft: t.startsWith('• ') ? 8 : 0 }}>
              {t}
            </p>
          ))}
        </section>
      ))}
      <p className="small mut" style={{ marginTop: 30 }}>
        See also: <Link href="/privacy">Privacy Policy</Link>
      </p>
    </main>
  );
}
