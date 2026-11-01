'use client';

import { FormEvent, useState } from 'react';
import { ErrorBox, Field, PageTop, useAction } from '@/components/ui';
import { api } from '@/lib/api';
import { useSession } from '@/lib/session';

export default function Account() {
  const { me, logout } = useSession();
  const [f, setF] = useState({ current: '', next: '', confirm: '' });
  const [ok, setOk] = useState(false);
  const { busy, error, setError, run } = useAction();
  if (!me) return null;
  const submit = (e: FormEvent) => {
    e.preventDefault();
    setOk(false);
    if (f.next !== f.confirm) return setError('New passwords do not match');
    run(async () => {
      await api('/auth/change-password', { body: { current: f.current || undefined, next: f.next } });
      setOk(true);
      setF({ current: '', next: '', confirm: '' });
    });
  };
  return (
    <>
      <PageTop crumb="You" title="Account" />
      <div className="card stack" style={{ maxWidth: 520 }}>
        <div>
          <div style={{ fontWeight: 700, fontSize: 16 }}>{me.user.name}</div>
          <div className="mut">{[me.user.email, me.user.phone].filter(Boolean).join(' · ')}</div>
          {me.user.hasGoogle && <div className="small lime" style={{ marginTop: 4 }}>Google sign-in is linked</div>}
        </div>
        <form className="stack" onSubmit={submit}>
          <h2>{me.user.hasPassword ? 'Change password' : 'Set a password'}</h2>
          {me.user.hasPassword && (
            <Field label="Current password">
              <input className="inp" type="password" value={f.current} onChange={(e) => setF({ ...f, current: e.target.value })} required autoComplete="current-password" />
            </Field>
          )}
          <Field label="New password" hint="At least 8 characters">
            <input className="inp" type="password" value={f.next} onChange={(e) => setF({ ...f, next: e.target.value })} required minLength={8} autoComplete="new-password" />
          </Field>
          <Field label="Confirm new password">
            <input className="inp" type="password" value={f.confirm} onChange={(e) => setF({ ...f, confirm: e.target.value })} required autoComplete="new-password" />
          </Field>
          <ErrorBox error={error} />
          {ok && <div className="alert okk">Password updated.</div>}
          <button className="btn" disabled={busy} style={{ justifySelf: 'start' }}>
            Save password
          </button>
        </form>
        <button className="btn ghost" onClick={logout} style={{ justifySelf: 'start' }}>
          Log out
        </button>
      </div>
    </>
  );
}
