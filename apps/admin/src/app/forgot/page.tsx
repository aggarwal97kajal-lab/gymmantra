'use client';

import Link from 'next/link';
import { FormEvent, useState } from 'react';
import { AuthFrame } from '@/components/AuthFrame';
import { ErrorBox, Field, useAction } from '@/components/ui';
import { api } from '@/lib/api';

export default function ForgotPage() {
  const [email, setEmail] = useState('');
  const [sentTo, setSentTo] = useState<string | null>(null);
  const { busy, error, run } = useAction();

  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      const r = await api<{ to: string }>('/auth/forgot', { body: { identifier: email.trim() } });
      setSentTo(r.to);
    });
  };

  return (
    <AuthFrame title={sentTo ? 'Check your email' : 'Forgot password?'}>
      {sentTo ? (
        <>
          <div className="alert okk">We sent a password reset link to {sentTo}. Open it, set a new password, then log in here.</div>
          <p className="mut small" style={{ margin: 0 }}>Not in your inbox? Check the Spam folder and mark it &quot;Not spam&quot;.</p>
          <Link className="btn block" href="/login">
            Back to login
          </Link>
        </>
      ) : (
        <form className="stack" onSubmit={submit}>
          <p className="mut" style={{ margin: 0 }}>
            Enter the email you signed up with. We will email you a link to set a new password.
          </p>
          <Field label="Email">
            <input className="inp" type="email" inputMode="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required autoFocus />
          </Field>
          <ErrorBox error={error} />
          <button className="btn block" disabled={busy}>
            {busy ? 'Sending…' : 'Send reset link'}
          </button>
          <Link href="/login" className="small" style={{ textAlign: 'center' }}>
            Back to login
          </Link>
        </form>
      )}
    </AuthFrame>
  );
}
