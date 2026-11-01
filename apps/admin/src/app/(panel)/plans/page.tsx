'use client';

import { FormEvent, useState } from 'react';
import { ErrorBox, Field, Icon, Loading, Modal, PageTop, Toggle, useAction, useApi } from '@/components/ui';
import { api, rupees } from '@/lib/api';
import { useSession } from '@/lib/session';

interface Plan { id: string; name: string; months: number; price: number; joiningFee: number; freezeDays: number; features: string[]; showInApp: boolean; active: boolean; activeMembers: number }

function PlanForm({ plan, onClose, onSaved }: { plan?: Plan; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState({
    name: plan?.name ?? '',
    months: plan?.months ?? 1,
    price: plan?.price ?? 0,
    joiningFee: plan?.joiningFee ?? 0,
    freezeDays: plan?.freezeDays ?? 0,
    features: plan?.features.join('\n') ?? '',
    showInApp: plan?.showInApp ?? true,
    active: plan?.active ?? true,
  });
  const { busy, error, run } = useAction();
  const num = (k: 'months' | 'price' | 'joiningFee' | 'freezeDays') => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: Math.max(0, Math.round(Number(e.target.value) || 0)) });
  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      const body = { ...f, features: f.features.split('\n').map((s) => s.trim()).filter(Boolean) };
      await api(plan ? `/plans/${plan.id}` : '/plans', { method: plan ? 'PATCH' : 'POST', body });
      onSaved();
    });
  };
  return (
    <Modal title={plan ? 'Edit plan' : 'New plan'} onClose={onClose}>
      <form className="stack" onSubmit={submit}>
        <Field label="Plan name">
          <input className="inp" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required placeholder="e.g. Quarterly" autoFocus />
        </Field>
        <div className="grid2">
          <Field label="Duration (months)">
            <input className="inp num" type="number" min={1} max={60} value={f.months} onChange={num('months')} required />
          </Field>
          <Field label="Price (₹)">
            <input className="inp num" type="number" min={0} value={f.price} onChange={num('price')} required />
          </Field>
          <Field label="Joining fee (₹)" hint="Charged only on a member's first membership">
            <input className="inp num" type="number" min={0} value={f.joiningFee} onChange={num('joiningFee')} />
          </Field>
          <Field label="Freeze days allowed">
            <input className="inp num" type="number" min={0} max={365} value={f.freezeDays} onChange={num('freezeDays')} />
          </Field>
        </div>
        <Field label="What's included (one per line)">
          <textarea className="inp" value={f.features} onChange={(e) => setF({ ...f, features: e.target.value })} placeholder={'Gym floor\nLocker\nDiet chart'} />
        </Field>
        <Toggle on={f.showInApp} onChange={(v) => setF({ ...f, showInApp: v })} label="Show in member app" />
        <Toggle on={f.active} onChange={(v) => setF({ ...f, active: v })} label="Active (can be assigned)" />
        {plan && plan.price !== f.price && <div className="alert note">Price changes apply to new and renewed memberships only. Existing members keep their recorded price.</div>}
        <ErrorBox error={error} />
        <button className="btn" disabled={busy}>
          {busy ? 'Saving…' : 'Save plan'}
        </button>
      </form>
    </Modal>
  );
}

export default function Plans() {
  const { gym } = useSession();
  const owner = gym?.role === 'OWNER';
  const { data, error, loading, reload } = useApi<Plan[]>('/plans');
  const [edit, setEdit] = useState<Plan | 'new' | null>(null);
  if (loading && !data) return <Loading />;
  return (
    <>
      <PageTop crumb="Your gym" title="Membership plans">
        {owner && (
          <button className="btn" onClick={() => setEdit('new')}>
            <Icon name="plus" /> New plan
          </button>
        )}
      </PageTop>
      <ErrorBox error={error} />
      {!owner && <div className="alert note" style={{ marginBottom: 14 }}>Only the gym owner can create or change plans.</div>}
      {data?.length === 0 ? (
        <div className="card empty">No plans yet. {owner ? 'Create your first plan, for example Monthly, Quarterly and Annual.' : ''}</div>
      ) : (
        <div className="grid3">
          {data?.map((p) => (
            <div key={p.id} className="card stack" style={{ opacity: p.active ? 1 : 0.55 }}>
              <div className="row sp">
                <h2>{p.name}</h2>
                <div className="row" style={{ gap: 6 }}>
                  {!p.showInApp && <span className="pill off">Hidden in app</span>}
                  {!p.active && <span className="pill off">Inactive</span>}
                </div>
              </div>
              <div>
                <span className="num" style={{ fontSize: 28, fontWeight: 800, letterSpacing: -0.8 }}>{rupees(p.price)}</span>
                <span className="mut"> / {p.months} month{p.months > 1 ? 's' : ''}</span>
              </div>
              <div className="small mut">
                {p.joiningFee ? `Joining fee ${rupees(p.joiningFee)}` : 'No joining fee'} · {p.freezeDays} freeze days
              </div>
              {p.features.length > 0 && (
                <div className="row wrap" style={{ gap: 6 }}>
                  {p.features.map((f) => (
                    <span key={f} className="pill off">{f}</span>
                  ))}
                </div>
              )}
              <div className="row sp" style={{ borderTop: '1px solid var(--line)', paddingTop: 10 }}>
                <span className="small mut">
                  <b style={{ color: 'var(--fg)' }}>{p.activeMembers}</b> active members
                </span>
                {owner && (
                  <button className="linkbtn small" onClick={() => setEdit(p)}>
                    Edit
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
      {edit && <PlanForm plan={edit === 'new' ? undefined : edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); reload(); }} />}
    </>
  );
}
