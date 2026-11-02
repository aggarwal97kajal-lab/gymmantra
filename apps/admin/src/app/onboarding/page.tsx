'use client';

import { useRouter } from 'next/navigation';
import { FormEvent, useEffect, useState } from 'react';
import { AuthFrame } from '@/components/AuthFrame';
import { ErrorBox, Field, Loading, useAction } from '@/components/ui';
import { api, setGymId } from '@/lib/api';
import { useSession } from '@/lib/session';
import india from '@/lib/india.json';

const STATES = (india as { states: { name: string; code: string; pins: string[]; cities: string[] }[] }).states;

export default function Onboarding() {
  const s = useSession();
  const router = useRouter();
  const [f, setF] = useState({ name: '', branchName: '', addressLine: '', state: '', city: '', otherCity: '', pincode: '', gstin: '', phone: '', whatsappNumber: '' });
  const st = STATES.find((x) => x.name === f.state);
  const pinBad = !!st && /^\d{6}$/.test(f.pincode) && !st.pins.includes(f.pincode.slice(0, 2));
  const { busy, error, run } = useAction();
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });

  useEffect(() => {
    if (!s.loading && !s.me) router.replace('/login');
  }, [s.loading, s.me, router]);
  if (s.loading || !s.me) return <Loading />;

  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      const city = f.city === '__other' ? f.otherCity.trim() : f.city;
      const t = await api<{ id: string }>('/gyms', {
        body: {
          name: f.name,
          branchName: f.branchName || undefined,
          addressLine: f.addressLine,
          state: f.state,
          city,
          pincode: f.pincode,
          gstin: f.gstin || undefined,
          whatsappNumber: f.whatsappNumber || undefined,
          phone: f.phone || undefined,
        },
      });
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
        <Field label="Address (building / plot, area)">
          <input className="inp" value={f.addressLine} onChange={set('addressLine')} required minLength={3} placeholder="e.g. Plot 12, Sector 7, Dwarka" />
        </Field>
        <div className="grid2">
          <Field label="State">
            <select className="inp" value={f.state} onChange={(e) => setF({ ...f, state: e.target.value, city: '' })} required>
              <option value="">Choose state</option>
              {STATES.map((x) => (
                <option key={x.name}>{x.name}</option>
              ))}
            </select>
          </Field>
          <Field label="City">
            <select className="inp" value={f.city} onChange={set('city')} required disabled={!st}>
              <option value="">{st ? 'Choose city' : 'Choose state first'}</option>
              {st?.cities.map((x) => (
                <option key={x}>{x}</option>
              ))}
              {st && <option value="__other">Other city…</option>}
            </select>
          </Field>
        </div>
        {f.city === '__other' && (
          <Field label="City name">
            <input className="inp" value={f.otherCity} onChange={set('otherCity')} required minLength={2} />
          </Field>
        )}
        <div className="grid2">
          <Field label="PIN code" hint={pinBad ? `This PIN is not from ${f.state}` : undefined}>
            <input className="inp" inputMode="numeric" maxLength={6} pattern="[1-9][0-9]{5}" value={f.pincode} onChange={set('pincode')} required style={pinBad ? { borderColor: 'var(--red, #ef4444)' } : undefined} />
          </Field>
          <Field label="GSTIN (if you have one)">
            <input className="inp" value={f.gstin} onChange={(e) => setF({ ...f, gstin: e.target.value.toUpperCase() })} maxLength={15} />
          </Field>
        </div>
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
