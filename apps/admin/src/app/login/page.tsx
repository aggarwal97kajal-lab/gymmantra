'use client';

import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { FormEvent, Suspense, useState } from 'react';
import { AuthFrame } from '@/components/AuthFrame';
import { GoogleButton } from '@/components/GoogleButton';
import { ErrorBox, Field, useAction } from '@/components/ui';
import { api } from '@/lib/api';

function LoginForm() {
  const params = useSearchParams();
  const [identifier, setIdentifier] = useState('');
  const [password, setPassword] = useState('');
  const { busy, error, run } = useAction();

  const done = () => {
    const next = params.get('next');
    window.location.href = next && next.startsWith('/') && !next.startsWith('//') ? next : '/';
  };

  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      await api('/auth/login', { body: { identifier, password } });
      done();
    });
  };

  return (
    <AuthFrame title="Log in">
      <form className="stack" onSubmit={submit}>
        <Field label="Email or mobile number">
          <input className="inp" value={identifier} onChange={(e) => setIdentifier(e.target.value)} autoComplete="username" required autoFocus />
        </Field>
        <Field label="Password">
          <input className="inp" type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" required />
        </Field>
        <Link href="/forgot" className="small" style={{ justifySelf: 'end', fontWeight: 700 }}>
          Forgot password?
        </Link>
        <ErrorBox error={error} />
        <button className="btn block" disabled={busy}>
          {busy ? 'Logging in…' : 'Log in'}
        </button>
      </form>
      <GoogleButton text="signin_with" onToken={(idToken) => run(async () => { await api('/auth/google/login', { body: { idToken } }); done(); })} />
      <p className="small mut" style={{ textAlign: 'center', margin: 0 }}>
        New to GymMantra? <Link href="/signup">Create an account</Link>
      </p>
    </AuthFrame>
  );
}

export default function LoginPage() {
  return (
    <Suspense>
      <LoginForm />
    </Suspense>
  );
}
