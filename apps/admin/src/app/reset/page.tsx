'use client';

import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { FormEvent, Suspense, useEffect, useState } from 'react';
import { AuthFrame } from '@/components/AuthFrame';
import { ErrorBox, Field, useAction } from '@/components/ui';
import { api } from '@/lib/api';

/** The link in the password reset email opens this page (Firebase "action URL"). */
function ResetForm() {
  const params = useSearchParams();
  const mode = params.get('mode') ?? 'resetPassword';
  const code = params.get('oobCode') ?? '';
  const [email, setEmail] = useState<string | null>(null);
  const [linkError, setLinkError] = useState<string | null>(null);
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [done, setDone] = useState(false);
  const { busy, error, run } = useAction();

  useEffect(() => {
    if (mode !== 'resetPassword' || !code) return;
    api<{ email: string }>('/auth/reset/check', { body: { oobCode: code } })
      .then((r) => setEmail(r.email))
      .catch((e) => setLinkError(e instanceof Error ? e.message : String(e)));
  }, [mode, code]);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      if (pw !== pw2) throw new Error('Passwords do not match');
      await api('/auth/reset', { body: { oobCode: code, password: pw } });
      setDone(true);
    });
  };

  if (mode !== 'resetPassword' || !code) {
    return (
      <AuthFrame title="Link not valid">
        <p className="mut" style={{ margin: 0 }}>This link is incomplete. Open the latest email from GymMantra, or ask for a new link.</p>
        <Link className="btn block" href="/forgot">Get a new link</Link>
      </AuthFrame>
    );
  }
  if (done) {
    return (
      <AuthFrame title="Password changed ✓">
        <div className="alert okk">Your new password is set. Log in with it on the GymMantra app or website.</div>
        <Link className="btn block" href="/login">Log in</Link>
      </AuthFrame>
    );
  }
  if (linkError) {
    return (
      <AuthFrame title="Link expired">
        <ErrorBox error={linkError} />
        <Link className="btn block" href="/forgot">Get a new link</Link>
      </AuthFrame>
    );
  }
  return (
    <AuthFrame title="Set a new password">
      <p className="mut" style={{ margin: 0 }}>{email ? `For ${email}` : 'Checking your link…'}</p>
      <form className="stack" onSubmit={submit}>
        <Field label="New password (at least 8 characters)">
          <input className="inp" type="password" autoComplete="new-password" minLength={8} value={pw} onChange={(e) => setPw(e.target.value)} required autoFocus />
        </Field>
        <Field label="Confirm new password">
          <input className="inp" type="password" autoComplete="new-password" minLength={8} value={pw2} onChange={(e) => setPw2(e.target.value)} required />
        </Field>
        <ErrorBox error={error} />
        <button className="btn block" disabled={busy || !email}>{busy ? 'Saving…' : 'Save new password'}</button>
      </form>
    </AuthFrame>
  );
}

export default function ResetPage() {
  return (
    <Suspense>
      <ResetForm />
    </Suspense>
  );
}
