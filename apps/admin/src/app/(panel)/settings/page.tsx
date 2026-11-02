'use client';

import QRCode from 'qrcode';
import { FormEvent, useEffect, useState } from 'react';
import { ErrorBox, Field, Icon, Loading, PageTop, Toggle, useAction, useApi } from '@/components/ui';
import { api, fmtDate } from '@/lib/api';

interface Gym {
  id: string; name: string; gymCode: string; phone: string | null; whatsappNumber: string | null; address: string | null; logoUrl: string | null;
  allowEntryWhenDue: boolean; memberCodePrefix: string; status: string; trialEndsAt: string | null;
  branches: { id: string; name: string; address: string | null; hours: string | null }[];
  limits: { planName: string; memberLimit: number | null; branchLimit: number; staffLimit: number };
}

/** The QR on the poster holds the gym code; the member app reads it to send a join request. */
const joinQrText = (code: string) => `gymmantra-join:${code}`;

export default function Settings() {
  const { data, error, loading, reload } = useApi<Gym>('/gym');
  const [f, setF] = useState<any>(null);
  const [qr, setQr] = useState('');
  const [branch, setBranch] = useState({ name: '', address: '', hours: '' });
  const act = useAction();
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    if (!data) return;
    setF({ name: data.name, phone: data.phone?.replace('+91', '') ?? '', whatsappNumber: data.whatsappNumber?.replace('+91', '') ?? '', address: data.address ?? '', allowEntryWhenDue: data.allowEntryWhenDue, memberCodePrefix: data.memberCodePrefix });
    QRCode.toDataURL(joinQrText(data.gymCode), { width: 560, margin: 1, color: { dark: '#0F1110', light: '#FFFFFF' } }).then(setQr);
  }, [data]);

  if ((loading && !data) || !f) return error ? <ErrorBox error={error} /> : <Loading />;

  const save = (e: FormEvent) => {
    e.preventDefault();
    setSaved(false);
    act.run(async () => {
      await api('/gym', { method: 'PATCH', body: f });
      setSaved(true);
      reload();
    });
  };

  return (
    <>
      <PageTop crumb="Your gym" title="Gym settings" />
      <ErrorBox error={act.error} />
      <div className="grid2" style={{ alignItems: 'start', marginTop: 10 }}>
        <div className="stack">
          <form className="card stack" onSubmit={save}>
            <h2>Gym profile</h2>
            <Field label="Gym name">
              <input className="inp" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required />
            </Field>
            <Field label="Address">
              <input className="inp" value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} />
            </Field>
            <div className="grid2">
              <Field label="Gym phone">
                <input className="inp" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} />
              </Field>
              <Field label="Gym WhatsApp Business number" hint="Shown to members. Reminders and receipts go from this number.">
                <input className="inp" value={f.whatsappNumber} onChange={(e) => setF({ ...f, whatsappNumber: e.target.value })} />
              </Field>
            </div>
            <Field label="Member ID prefix" hint={`New members get IDs like ${f.memberCodePrefix}-1001`}>
              <input className="inp" value={f.memberCodePrefix} maxLength={5} onChange={(e) => setF({ ...f, memberCodePrefix: e.target.value.toUpperCase().replace(/[^A-Z]/g, '') })} />
            </Field>
            <div className="card" style={{ background: 'var(--field)', padding: 14 }}>
              <Toggle on={f.allowEntryWhenDue} onChange={(v) => setF({ ...f, allowEntryWhenDue: v })} label='"Not paid yet" members can enter by default' />
              <div className="small mut" style={{ marginTop: 6 }}>This is only the starting choice. Staff can change it for each membership when they save it.</div>
            </div>
            {saved && <div className="alert okk">Saved.</div>}
            <button className="btn" style={{ justifySelf: 'start' }} disabled={act.busy}>
              Save changes
            </button>
          </form>

          <div className="card stack">
            <div className="row sp">
              <h2>Branches</h2>
              <span className="small mut">
                {data!.branches.length} of {data!.limits.branchLimit} on your plan
              </span>
            </div>
            <div className="list">
              {data!.branches.map((b) => (
                <div className="li" key={b.id}>
                  <div className="grow">
                    <div style={{ fontWeight: 650 }}>{b.name}</div>
                    <div className="small mut">{[b.address, b.hours].filter(Boolean).join(' · ') || '—'}</div>
                  </div>
                </div>
              ))}
            </div>
            <form
              className="row wrap"
              onSubmit={(e) => {
                e.preventDefault();
                act.run(async () => {
                  await api('/gym/branches', { body: { name: branch.name, address: branch.address || undefined, hours: branch.hours || undefined } });
                  setBranch({ name: '', address: '', hours: '' });
                  reload();
                });
              }}
            >
              <input className="inp grow" placeholder="New branch name" value={branch.name} onChange={(e) => setBranch({ ...branch, name: e.target.value })} required minLength={2} />
              <input className="inp grow" placeholder="Address" value={branch.address} onChange={(e) => setBranch({ ...branch, address: e.target.value })} />
              <button className="btn ghost">Add branch</button>
            </form>
          </div>

          <div className="card stack">
            <h2>GymMantra plan</h2>
            <div>
              <b>{data!.limits.planName}</b>
              {data!.status === 'TRIAL' && data!.trialEndsAt && <span className="mut"> · free until {fmtDate(data!.trialEndsAt)}</span>}
            </div>
            <div className="small mut">
              {data!.limits.memberLimit ? `Up to ${data!.limits.memberLimit}` : 'Unlimited'} members · {data!.limits.branchLimit} branch{data!.limits.branchLimit > 1 ? 'es' : ''} · {data!.limits.staffLimit} staff accounts
            </div>
          </div>
        </div>

        <div className="card stack" id="poster">
          <div className="row sp noprint">
            <h2>Join poster</h2>
            <button className="btn ghost sm" onClick={() => window.print()}>
              <Icon name="print" size={15} /> Print
            </button>
          </div>
          <div style={{ background: '#fff', color: '#0F1110', borderRadius: 16, padding: 28, textAlign: 'center' }}>
            <div style={{ fontWeight: 900, fontSize: 26, letterSpacing: -0.6 }}>{data!.name}</div>
            <div style={{ fontWeight: 600, marginTop: 4 }}>Join us on the GymMantra app</div>
            {qr && <img src={qr} alt={`QR code for gym code ${data!.gymCode}`} style={{ width: '70%', maxWidth: 280, margin: '18px auto', display: 'block' }} />}
            <div style={{ fontSize: 14 }}>or enter gym code</div>
            <div style={{ fontWeight: 900, fontSize: 34, letterSpacing: 2, marginTop: 4 }}>{data!.gymCode}</div>
            <div style={{ marginTop: 14, fontSize: 13, color: '#F04E12', fontWeight: 700 }}>GymMantra · Fitness ka sahi mantra.</div>
          </div>
        </div>
      </div>
    </>
  );
}
