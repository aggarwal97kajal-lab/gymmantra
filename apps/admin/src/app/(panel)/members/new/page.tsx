'use client';

import { useRouter } from 'next/navigation';
import { FormEvent, useState } from 'react';
import { ErrorBox, Field, PageTop, useAction, useApi } from '@/components/ui';
import { api, todayIST } from '@/lib/api';

export default function NewMember() {
  const router = useRouter();
  const gym = useApi<{ branches: { id: string; name: string }[] }>('/gym');
  const [f, setF] = useState({ name: '', phone: '', email: '', gender: '', branchId: '', joinedOn: todayIST(), notes: '' });
  const { busy, error, run } = useAction();
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => setF({ ...f, [k]: e.target.value });

  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      const m = await api<{ id: string }>('/members', {
        body: { name: f.name, phone: f.phone, email: f.email || undefined, gender: f.gender || undefined, branchId: f.branchId || undefined, joinedOn: f.joinedOn, notes: f.notes || undefined },
      });
      router.replace(`/members/view?id=${m.id}&new=1`);
    });
  };

  return (
    <>
      <PageTop crumb="Members" title="Add member" />
      <form className="card stack" style={{ maxWidth: 640 }} onSubmit={submit}>
        <div className="grid2">
          <Field label="Full name">
            <input className="inp" value={f.name} onChange={set('name')} required minLength={2} autoFocus />
          </Field>
          <Field label="Mobile number" hint="Used to link the member app">
            <input className="inp" type="tel" inputMode="numeric" value={f.phone} onChange={set('phone')} required />
          </Field>
          <Field label="Email (optional)">
            <input className="inp" type="email" value={f.email} onChange={set('email')} />
          </Field>
          <Field label="Gender (optional)">
            <select className="inp" value={f.gender} onChange={set('gender')}>
              <option value="">—</option>
              <option value="male">Male</option>
              <option value="female">Female</option>
              <option value="other">Other</option>
            </select>
          </Field>
          {(gym.data?.branches.length ?? 0) > 1 && (
            <Field label="Branch">
              <select className="inp" value={f.branchId} onChange={set('branchId')}>
                <option value="">—</option>
                {gym.data!.branches.map((b) => (
                  <option key={b.id} value={b.id}>
                    {b.name}
                  </option>
                ))}
              </select>
            </Field>
          )}
          <Field label="Joining date">
            <input className="inp" type="date" value={f.joinedOn} onChange={set('joinedOn')} required />
          </Field>
        </div>
        <Field label="Notes (optional)">
          <textarea className="inp" value={f.notes} onChange={set('notes')} />
        </Field>
        <ErrorBox error={error} />
        <div className="row">
          <button className="btn" disabled={busy}>
            {busy ? 'Saving…' : 'Save and add membership'}
          </button>
          <button type="button" className="btn ghost" onClick={() => router.back()}>
            Cancel
          </button>
        </div>
      </form>
    </>
  );
}
