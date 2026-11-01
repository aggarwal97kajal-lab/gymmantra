'use client';

import Link from 'next/link';
import { FormEvent, useState } from 'react';
import { AuthFrame } from '@/components/AuthFrame';
import { GoogleButton } from '@/components/GoogleButton';
import { ErrorBox, Field, useAction } from '@/components/ui';
import { api } from '@/lib/api';

export default function SignupPage() {
  const [f, setF] = useState({ name: '', email: '', phone: '', password: '', confirm: '' });
  const { busy, error, setError, run } = useAction();
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value });

  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (f.password !== f.confirm) return setError('Passwords do not match');
    run(async () => {
      await api('/auth/signup', { body: { name: f.name, email: f.email, phone: f.phone, password: f.password } });
      window.location.href = '/';
    });
  };

  return (
    <AuthFrame title="Create your account">
      <form className="stack" onSubmit={submit}>
        <Field label="Full name">
          <input className="inp" value={f.name} onChange={set('name')} autoComplete="name" required minLength={2} autoFocus />
        </Field>
        <Field label="Email">
          <input className="inp" type="email" value={f.email} onChange={set('email')} autoComplete="email" required />
        </Field>
        <Field label="Mobile number">
          <input className="inp" type="tel" inputMode="numeric" value={f.phone} onChange={set('phone')} autoComplete="tel" placeholder="10-digit number" required />
        </Field>
        <div className="grid2">
          <Field label="Password" hint="At least 8 characters">
            <input className="inp" type="password" value={f.password} onChange={set('password')} autoComplete="new-password" required minLength={8} />
          </Field>
          <Field label="Confirm password">
            <input className="inp" type="password" value={f.confirm} onChange={set('confirm')} autoComplete="new-password" required />
          </Field>
        </div>
        <ErrorBox error={error} />
        <button className="btn block" disabled={busy}>
          {busy ? 'Creating account…' : 'Sign up'}
        </button>
      </form>
      <GoogleButton
        text="signup_with"
        onToken={(idToken) =>
          run(async () => {
            await api('/auth/google/signup', { body: { idToken, phone: f.phone || undefined } });
            window.location.href = '/';
          })
        }
      />
      <p className="small mut" style={{ textAlign: 'center', margin: 0 }}>
        Already have an account? <Link href="/login">Log in</Link>
      </p>
    </AuthFrame>
  );
}
