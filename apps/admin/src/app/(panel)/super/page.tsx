'use client';

import { FormEvent, useState } from 'react';
import { ErrorBox, Field, Loading, Modal, PageTop, Toggle, useAction, useApi } from '@/components/ui';
import { TicketDesk } from '@/components/TicketDesk';
import { api, fmtDate, rupees } from '@/lib/api';
import { useSession } from '@/lib/session';

interface SaasPlan { id: string; name: string; monthlyPrice: number; annualPrice: number; memberLimit: number | null; branchLimit: number; staffLimit: number; whatsappLimit: number; features: string[]; visible: boolean; sortOrder: number; _count: { tenants: number } }
interface GymRow { id: string; name: string; gymCode: string; status: string; verified: boolean; trialEndsAt: string | null; saasPlan: { id: string; name: string } | null; customMonthlyPrice: number | null; createdAt: string; _count: { members: number; branches: number }; owners: { name: string; phone: string | null; email: string | null }[] }

function PlanEditor({ plan, onClose, onSaved }: { plan?: SaasPlan; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState({
    name: plan?.name ?? '', monthlyPrice: plan?.monthlyPrice ?? 0, annualPrice: plan?.annualPrice ?? 0, memberLimit: plan?.memberLimit ?? null as number | null,
    branchLimit: plan?.branchLimit ?? 1, staffLimit: plan?.staffLimit ?? 5, whatsappLimit: plan?.whatsappLimit ?? 0, features: plan?.features.join('\n') ?? '', visible: plan?.visible ?? true, sortOrder: plan?.sortOrder ?? 0,
  });
  const { busy, error, run } = useAction();
  const n = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: Math.max(0, Math.round(Number(e.target.value) || 0)) });
  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      await api(plan ? `/super/saas-plans/${plan.id}` : '/super/saas-plans', { method: plan ? 'PATCH' : 'POST', body: { ...f, features: f.features.split('\n').map((s) => s.trim()).filter(Boolean) } });
      onSaved();
    });
  };
  return (
    <Modal title={plan ? `Edit ${plan.name}` : 'New SaaS plan'} onClose={onClose}>
      <form className="stack" onSubmit={submit}>
        <Field label="Name"><input className="inp" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required /></Field>
        <div className="grid2">
          <Field label="Monthly price (₹, before GST)"><input className="inp num" type="number" value={f.monthlyPrice} onChange={n('monthlyPrice')} /></Field>
          <Field label="Annual price (₹, before GST)"><input className="inp num" type="number" value={f.annualPrice} onChange={n('annualPrice')} /></Field>
          <Field label="Member limit" hint="Leave empty for unlimited">
            <input className="inp num" type="number" value={f.memberLimit ?? ''} onChange={(e) => setF({ ...f, memberLimit: e.target.value ? Math.max(1, Math.round(Number(e.target.value))) : null })} />
          </Field>
          <Field label="Branches"><input className="inp num" type="number" value={f.branchLimit} onChange={n('branchLimit')} /></Field>
          <Field label="Staff accounts"><input className="inp num" type="number" value={f.staffLimit} onChange={n('staffLimit')} /></Field>
          <Field label="WhatsApp messages / month"><input className="inp num" type="number" value={f.whatsappLimit} onChange={n('whatsappLimit')} /></Field>
          <Field label="Order"><input className="inp num" type="number" value={f.sortOrder} onChange={n('sortOrder')} /></Field>
        </div>
        <Field label="Features (one per line)"><textarea className="inp" value={f.features} onChange={(e) => setF({ ...f, features: e.target.value })} /></Field>
        <Toggle on={f.visible} onChange={(v) => setF({ ...f, visible: v })} label="Visible to gyms" />
        {plan && <div className="alert note">Changes go live without an app update. Existing gyms move to a new price at their next renewal.</div>}
        <ErrorBox error={error} />
        <button className="btn" disabled={busy}>Save plan</button>
      </form>
    </Modal>
  );
}

export default function Super() {
  const { me } = useSession();
  const [tab, setTab] = useState<'gyms' | 'plans' | 'support'>('gyms');
  const overview = useApi<Record<string, number>>(me?.user.isSuperAdmin ? '/super/overview' : null);
  const gyms = useApi<GymRow[]>(me?.user.isSuperAdmin && tab === 'gyms' ? '/super/gyms' : null, [tab]);
  const plans = useApi<{ trialMonths: number; plans: SaasPlan[] }>(me?.user.isSuperAdmin && tab === 'plans' ? '/super/saas-plans' : null, [tab]);
  const [edit, setEdit] = useState<SaasPlan | 'new' | null>(null);
  const [trial, setTrial] = useState<number | null>(null);
  const act = useAction();

  if (!me) return <Loading />;
  if (!me.user.isSuperAdmin) return <div className="alert err">Only the GymMantra team can open this page.</div>;
  const o = overview.data;
  const patchGym = (id: string, body: object) => act.run(async () => { await api(`/super/gyms/${id}`, { method: 'PATCH', body }); gyms.reload(); overview.reload(); });

  return (
    <>
      <PageTop crumb="GymMantra" title="Super admin" />
      {o && (
        <div className="kpis" style={{ marginBottom: 14 }}>
          <div className="card kpi"><div className="k">Gyms</div><div className="v num">{o.gyms}</div><div className="s">{o.trial} trial · {o.active} paying · {o.suspended} suspended</div></div>
          <div className="card kpi"><div className="k">Members</div><div className="v num">{o.members}</div></div>
          <div className="card kpi"><div className="k">User accounts</div><div className="v num">{o.users}</div></div>
          <div className="card kpi"><div className="k">Open app tickets</div><div className="v num" style={{ color: 'var(--org)' }}>{o.openTickets}</div></div>
        </div>
      )}
      <div className="tabs" style={{ marginBottom: 14 }}>
        <button className={`tab ${tab === 'gyms' ? 'on' : ''}`} onClick={() => setTab('gyms')}>Gyms</button>
        <button className={`tab ${tab === 'plans' ? 'on' : ''}`} onClick={() => setTab('plans')}>SaaS plans</button>
        <button className={`tab ${tab === 'support' ? 'on' : ''}`} onClick={() => setTab('support')}>App support</button>
      </div>
      <ErrorBox error={act.error} />

      {tab === 'gyms' && (
        <div className="card" style={{ padding: '6px 12px' }}>
          {!gyms.data ? <Loading /> : (
            <div className="tblwrap">
              <table>
                <thead><tr><th>GYM</th><th>OWNER</th><th>MEMBERS</th><th>PLAN</th><th>STATUS</th><th></th></tr></thead>
                <tbody>
                  {gyms.data.map((g) => (
                    <tr key={g.id}>
                      <td><div style={{ fontWeight: 650 }}>{g.name} {g.verified && <span className="lime" title="Verified">✓</span>}</div><div className="small mut">{g.gymCode} · since {fmtDate(g.createdAt)}</div></td>
                      <td>{g.owners.map((x) => <div key={x.phone ?? x.email}>{x.name}<div className="small mut">{x.phone?.replace('+91', '')}</div></div>)}</td>
                      <td className="num">{g._count.members}</td>
                      <td>
                        {g.status === 'TRIAL' ? <>Trial<div className="small mut">till {fmtDate(g.trialEndsAt)}</div></> : g.saasPlan?.name ?? '—'}
                        {g.customMonthlyPrice != null && <div className="small lime">Custom {rupees(g.customMonthlyPrice)}/mo</div>}
                      </td>
                      <td><span className={`pill ${g.status === 'ACTIVE' ? 'ok' : g.status === 'TRIAL' ? 'info' : 'bad'}`}>{g.status.toLowerCase()}</span></td>
                      <td className="row" style={{ gap: 6 }}>
                        {!g.verified && <button className="btn ghost sm" onClick={() => patchGym(g.id, { verified: true })}>Verify</button>}
                        <button className="btn ghost sm" onClick={() => patchGym(g.id, { status: g.status === 'SUSPENDED' ? 'ACTIVE' : 'SUSPENDED' })}>{g.status === 'SUSPENDED' ? 'Reactivate' : 'Suspend'}</button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      {tab === 'plans' && (
        <div className="stack">
          {!plans.data ? <Loading /> : (
            <>
              <div className="row sp wrap">
                <div className="alert okk grow" style={{ maxWidth: 640 }}>Changes go live without an app update. Existing gyms move to a new price at their next renewal.</div>
                <button className="btn" onClick={() => setEdit('new')}>+ New plan</button>
              </div>
              <div className="grid3">
                {plans.data.plans.map((p) => (
                  <div key={p.id} className="card stack" style={{ opacity: p.visible ? 1 : 0.55 }}>
                    <div className="row sp"><h2>{p.name}</h2><span className={`pill ${p.visible ? 'ok' : 'off'}`}>{p.visible ? 'Live' : 'Hidden'}</span></div>
                    <div><span className="num" style={{ fontSize: 28, fontWeight: 800 }}>{rupees(p.monthlyPrice)}</span><span className="mut"> / month</span></div>
                    <div className="small mut">{rupees(p.annualPrice)} / year · + 18% GST</div>
                    <div className="small" style={{ fontWeight: 600 }}>{p.memberLimit ?? 'Unlimited'} members · {p.branchLimit} branch{p.branchLimit > 1 ? 'es' : ''} · {p.staffLimit} staff</div>
                    <div className="row wrap" style={{ gap: 6 }}>{p.features.map((f) => <span key={f} className="pill off">{f}</span>)}</div>
                    <div className="row sp" style={{ borderTop: '1px solid var(--line)', paddingTop: 10 }}>
                      <span className="small mut"><b style={{ color: 'var(--fg)' }}>{p._count.tenants}</b> gyms</span>
                      <button className="linkbtn small" onClick={() => setEdit(p)}>Edit</button>
                    </div>
                  </div>
                ))}
              </div>
              <form className="card row wrap sp" onSubmit={(e) => { e.preventDefault(); act.run(async () => { await api('/super/settings', { method: 'PATCH', body: { trialMonths: trial ?? plans.data!.trialMonths } }); plans.reload(); }); }}>
                <div><h2>Free trial for new gyms</h2><div className="small mut">New gyms get the top plan's features during the trial</div></div>
                <div className="row">
                  <input className="inp num" type="number" min={0} max={24} style={{ width: 90 }} value={trial ?? plans.data.trialMonths} onChange={(e) => setTrial(Math.round(Number(e.target.value) || 0))} />
                  <span className="mut">months</span>
                  <button className="btn ghost">Save</button>
                </div>
              </form>
            </>
          )}
        </div>
      )}

      {tab === 'support' && <TicketDesk base="/super/tickets" />}
      {edit && <PlanEditor plan={edit === 'new' ? undefined : edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); plans.reload(); }} />}
    </>
  );
}
