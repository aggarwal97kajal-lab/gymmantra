'use client';

import { FormEvent, useState } from 'react';
import { Avatar, ErrorBox, Field, Icon, Loading, Modal, PageTop, useAction, useApi } from '@/components/ui';
import { api } from '@/lib/api';
import { useSession } from '@/lib/session';

interface StaffRow { id: string; role: 'OWNER' | 'FRONT_DESK'; active: boolean; branchIds: string[]; user: { id: string; name: string; email: string | null; phone: string | null; photoUrl: string | null } }

export default function StaffPage() {
  const { me } = useSession();
  const { data, error, loading, reload } = useApi<StaffRow[]>('/gym/staff');
  const gym = useApi<{ branches: { id: string; name: string }[] }>('/gym');
  const [adding, setAdding] = useState(false);
  const [f, setF] = useState({ name: '', phone: '', email: '', tempPassword: '', role: 'FRONT_DESK', branchIds: [] as string[] });
  const act = useAction();

  const submit = (e: FormEvent) => {
    e.preventDefault();
    act.run(async () => {
      await api('/gym/staff', { body: { ...f, email: f.email || undefined, tempPassword: f.tempPassword || undefined } });
      setAdding(false);
      setF({ name: '', phone: '', email: '', tempPassword: '', role: 'FRONT_DESK', branchIds: [] });
      reload();
    });
  };
  const update = (id: string, body: object) => act.run(async () => { await api(`/gym/staff/${id}`, { method: 'PATCH', body }); reload(); });

  if (loading && !data) return <Loading />;
  return (
    <>
      <PageTop crumb="Your gym" title="Staff">
        <button className="btn" onClick={() => setAdding(true)}>
          <Icon name="plus" /> Add staff
        </button>
      </PageTop>
      <ErrorBox error={error ?? act.error} />
      <div className="card" style={{ maxWidth: 860 }}>
        <div className="small mut" style={{ marginBottom: 6 }}>
          Front desk can add members, add and renew memberships, give discounts, take payments, freeze and run attendance. Only owners can change plans, prices, staff and gym settings.
        </div>
        <div className="list">
          {data?.map((s) => (
            <div className="li" key={s.id} style={{ opacity: s.active ? 1 : 0.5 }}>
              <Avatar name={s.user.name} url={s.user.photoUrl} />
              <div className="grow">
                <div style={{ fontWeight: 650 }}>
                  {s.user.name} {s.user.id === me?.user.id && <span className="small mut">(you)</span>}
                </div>
                <div className="small mut">{[s.user.phone?.replace('+91', ''), s.user.email].filter(Boolean).join(' · ')}</div>
              </div>
              <select className="inp" style={{ width: 140, height: 36 }} value={s.role} onChange={(e) => update(s.id, { role: e.target.value })} aria-label="Role">
                <option value="OWNER">Owner</option>
                <option value="FRONT_DESK">Front desk</option>
              </select>
              {s.user.id !== me?.user.id && (
                <button className="btn ghost sm" onClick={() => update(s.id, { active: !s.active })}>
                  {s.active ? 'Remove access' : 'Give access'}
                </button>
              )}
            </div>
          ))}
        </div>
      </div>
      {adding && (
        <Modal title="Add staff" onClose={() => setAdding(false)}>
          <form className="stack" onSubmit={submit}>
            <div className="grid2">
              <Field label="Name">
                <input className="inp" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required />
              </Field>
              <Field label="Mobile number">
                <input className="inp" type="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} required />
              </Field>
              <Field label="Email (optional)">
                <input className="inp" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} />
              </Field>
              <Field label="Temporary password" hint="Needed if they don't have a GymMantra account yet">
                <input className="inp" value={f.tempPassword} onChange={(e) => setF({ ...f, tempPassword: e.target.value })} minLength={8} />
              </Field>
            </div>
            <Field label="Role">
              <div className="seg">
                <button type="button" className={f.role === 'FRONT_DESK' ? 'on' : ''} onClick={() => setF({ ...f, role: 'FRONT_DESK' })}>Front desk</button>
                <button type="button" className={f.role === 'OWNER' ? 'on' : ''} onClick={() => setF({ ...f, role: 'OWNER' })}>Owner</button>
              </div>
            </Field>
            {(gym.data?.branches.length ?? 0) > 1 && (
              <Field label="Branches they work at">
                <div className="row wrap">
                  {gym.data!.branches.map((b) => (
                    <label key={b.id} className="chk">
                      <input type="checkbox" checked={f.branchIds.includes(b.id)} onChange={(e) => setF({ ...f, branchIds: e.target.checked ? [...f.branchIds, b.id] : f.branchIds.filter((x) => x !== b.id) })} /> {b.name}
                    </label>
                  ))}
                </div>
              </Field>
            )}
            <ErrorBox error={act.error} />
            <button className="btn" disabled={act.busy}>
              {act.busy ? 'Adding…' : 'Add staff'}
            </button>
            <div className="small mut">They log in at this same website with their mobile number and the temporary password.</div>
          </form>
        </Modal>
      )}
    </>
  );
}
