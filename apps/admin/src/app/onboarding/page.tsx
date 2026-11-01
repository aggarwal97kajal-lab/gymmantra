'use client';

import { useRouter } from 'next/navigation';
import { FormEvent, useEffect, useState } from 'react';
import { AuthFrame } from '@/components/AuthFrame';
import { ErrorBox, Field, Loading, useAction } from '@/components/ui';
import { api, setGymId } from '@/lib/api';
import { useSession } from '@/lib/session';

export default function Onboarding() {
  const s = useSession();
  const router = useRouter();
  const [f, setF] = useState({ name: '', branchName: '', address: '', phone: '', whatsappNumber: '' });
  const { busy, error, run } = useAction();
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value });

  useEffect(() => {
    if (!s.loading && !s.me) router.replace('/login');
  }, [s.loading, s.me, router]);
  if (s.loading || !s.me) return <Loading />;

  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      const t = await api<{ id: string }>('/gyms', { body: { ...f, whatsappNumber: f.whatsappNumber || undefined, phone: f.phone || undefined } });
      setGymId(t.id);
      window.location.href = '/dashboard';
    });
  };

  return (
    <AuthFrame title="Register your gym">
      <p className="mut" style={{ margin: 0 }}>
        Your first 3 months are free. You can add more branches and staff later.
      </p>
      <form className="stack" onSubmit={submit}>
        <Field label="Gym name">
          <input className="inp" value={f.name} onChange={set('name')} required minLength={2} autoFocus placeholder="e.g. Lifetime Fitness" />
        </Field>
        <Field label="Branch name" hint="Leave empty if you have one location">
          <input className="inp" value={f.branchName} onChange={set('branchName')} placeholder="e.g. Dwarka Sector 7" />
        </Field>
        <Field label="Address">
          <input className="inp" value={f.address} onChange={set('address')} />
        </Field>
        <div className="grid2">
          <Field label="Gym phone">
            <input className="inp" type="tel" value={f.phone} onChange={set('phone')} />
          </Field>
          <Field label="Gym WhatsApp number" hint="Members see this; reminders go from it">
            <input className="inp" type="tel" value={f.whatsappNumber} onChange={set('whatsappNumber')} />
          </Field>
        </div>
        <ErrorBox error={error} />
        <button className="btn block" disabled={busy}>
          {busy ? 'Creating…' : 'Create gym'}
        </button>
        {s.me.user.isSuperAdmin && (
          <button type="button" className="btn ghost block" onClick={() => router.push('/super')}>
            Go to super admin instead
          </button>
        )}
      </form>
    </AuthFrame>
  );
}
