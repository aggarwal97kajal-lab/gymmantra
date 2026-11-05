'use client';

import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { FormEvent, Suspense, useEffect, useState } from 'react';
import { Avatar, ErrorBox, Field, Icon, Loading, Modal, StatusPill, Toggle, useAction, useApi } from '@/components/ui';
import { api, fmtDate, fmtDateTime, PAY_MODES, plural, rupees, todayIST } from '@/lib/api';

interface Payment { id: string; amount: number; mode: string; receivedAt: string; receivedByName: string; note: string | null }
interface FreezeRow { id: string; startDate: string; days: number; endedOn: string | null; reason: string | null }
interface Sub {
  id: string; planId: string | null; planName: string; months: number; startDate: string; endDate: string; price: number; joiningFee: number; discount: number;
  total: number; paid: number; due: number; kind: string; note: string | null; createdAt: string; createdByName: string; superseded: boolean;
  allowEntryWhileDue: boolean; freezeDaysAllowed: number; payments: Payment[]; freezes: FreezeRow[];
}
interface Detail {
  member: { id: string; name: string; phone: string; email: string | null; gender: string | null; memberCode: string; joinedOn: string; notes: string | null; photoUrl: string | null; hasApp: boolean; branchId: string | null; archived: boolean };
  state: { status: string; daysLeft: number | null; endsOn: string | null; due: number; frozenUntil: string | null; currentId: string | null; upcomingId: string | null; freezeDaysLeft: number; entry: { result: string; reason: string | null } };
  history: Sub[];
  attendance: { id: string; scannedAt: string; result: string; reason: string | null }[];
}
interface Plan { id: string; name: string; months: number; price: number; joiningFee: number; freezeDays: number; active: boolean }

const modeLabel = (m: string) => PAY_MODES.find((p) => p.v === m)?.l ?? m;

function addMonths(ymd: string, months: number) {
  const [y, m, d] = ymd.split('-').map(Number);
  const total = y * 12 + (m - 1) + months;
  const ty = Math.floor(total / 12);
  const tm = total % 12;
  const last = new Date(Date.UTC(ty, tm + 1, 0)).getUTCDate();
  return `${ty}-${String(tm + 1).padStart(2, '0')}-${String(Math.min(d, last)).padStart(2, '0')}`;
}
function planEnd(start: string, months: number) {
  const d = new Date(`${addMonths(start, months)}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

function MembershipForm({ memberId, correcting, onClose, onSaved }: { memberId: string; correcting?: Sub; onClose: () => void; onSaved: (receipt: string | null) => void }) {
  const plans = useApi<Plan[]>('/plans');
  const [planId, setPlanId] = useState(correcting?.planId ?? '');
  const [f, setF] = useState({ startDate: '', endDate: '', price: 0, joiningFee: 0, discount: 0, received: 0, mode: 'CASH', allow: false, note: '', whatsapp: true });
  const [kind, setKind] = useState<string>(correcting ? 'CORRECTION' : '');
  const { busy, error, run } = useAction();
  const alreadyPaid = correcting?.paid ?? 0;
  const total = Math.max(0, f.price + f.joiningFee - f.discount);
  const due = Math.max(0, total - alreadyPaid - (f.mode === 'NOT_PAID' ? 0 : f.received));

  useEffect(() => {
    if (!planId) return;
    const plan = plans.data?.find((p) => p.id === planId);
    if (correcting) {
      const months = plan?.months ?? correcting.months;
      const start = f.startDate || correcting.startDate;
      setF((x) => ({
        ...x,
        startDate: start,
        endDate: planId === correcting.planId && !x.startDate ? correcting.endDate : planEnd(start, months),
        price: planId === correcting.planId ? correcting.price : plan?.price ?? 0,
        joiningFee: correcting.joiningFee,
        discount: correcting.discount,
        received: 0,
        mode: correcting.due > 0 ? 'NOT_PAID' : 'CASH',
        allow: correcting.allowEntryWhileDue,
      }));
      return;
    }
    api<{ kind: string; startDate: string; endDate: string; price: number; joiningFee: number; allowEntryWhileDue: boolean }>(`/members/${memberId}/membership-preview?planId=${planId}`).then((p) => {
      setKind(p.kind);
      setF((x) => ({ ...x, startDate: p.startDate, endDate: p.endDate, price: p.price, joiningFee: p.joiningFee, discount: 0, received: p.price + p.joiningFee, allow: p.allowEntryWhileDue }));
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [planId, plans.data]);

  const plan = plans.data?.find((p) => p.id === planId);
  const setNum = (k: 'price' | 'discount' | 'received') => (e: React.ChangeEvent<HTMLInputElement>) => {
    const v = Math.max(0, Math.round(Number(e.target.value) || 0));
    setF((x) => {
      const n = { ...x, [k]: v };
      if (k !== 'received' && x.mode !== 'NOT_PAID') n.received = Math.max(0, n.price + n.joiningFee - n.discount - alreadyPaid);
      return n;
    });
  };

  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      const body = {
        planId,
        startDate: f.startDate,
        endDate: f.endDate,
        price: f.price,
        discount: f.discount,
        amountReceived: f.mode === 'NOT_PAID' ? 0 : f.received,
        paymentMode: f.mode,
        allowEntryWhileDue: due > 0 ? f.allow : undefined,
        note: f.note || undefined,
      };
      const r = await api<{ whatsappReceipt: string }>(correcting ? `/memberships/${correcting.id}/correct` : `/members/${memberId}/memberships`, { body });
      void r; // no WhatsApp receipt any more: the member gets the receipt as a notification in the app
      onSaved('saved');
    });
  };

  return (
    <Modal title={correcting ? 'Correct membership' : kind === 'NEW' ? 'Add membership' : 'Renew membership'} onClose={onClose} wide>
      <form className="stack" onSubmit={submit}>
        {correcting && <div className="alert note">The old entry stays in history. This saves a new, corrected entry. Money already received ({rupees(alreadyPaid)}) carries over.</div>}
        <Field label="Plan">
          <select className="inp" value={planId} onChange={(e) => setPlanId(e.target.value)} required>
            <option value="">Choose a plan</option>
            {plans.data?.filter((p) => p.active || p.id === planId).map((p) => (
              <option key={p.id} value={p.id}>
                {p.name} · {p.months} month{p.months > 1 ? 's' : ''} · {rupees(p.price)}
              </option>
            ))}
          </select>
        </Field>
        {plans.data?.length === 0 && (
          <div className="alert note">
            No plans yet. <Link href="/plans">Create your plans first</Link>.
          </div>
        )}
        {planId && f.startDate && (
          <>
            <div className="grid3">
              <Field label="Start date">
                <input className="inp" type="date" value={f.startDate} onChange={(e) => setF({ ...f, startDate: e.target.value, endDate: e.target.value && plan ? planEnd(e.target.value, plan.months) : f.endDate })} required />
              </Field>
              <Field label="End date" hint="Filled in automatically. You can change it.">
                <input className="inp" type="date" value={f.endDate} min={f.startDate} onChange={(e) => setF({ ...f, endDate: e.target.value })} required />
              </Field>
              <Field label="Plan price (₹)">
                <input className="inp num" type="number" min={0} value={f.price} onChange={setNum('price')} />
              </Field>
              <Field label="Discount (₹)">
                <input className="inp num" type="number" min={0} value={f.discount} onChange={setNum('discount')} />
              </Field>
              <Field label="Joining fee (₹)" hint={f.joiningFee ? 'First membership only' : 'Not charged on renewals'}>
                <input className="inp num" value={f.joiningFee} disabled />
              </Field>
              <Field label="Total (₹)">
                <input className="inp num" value={total} disabled style={{ fontWeight: 700 }} />
              </Field>
            </div>
            <Field label="Payment mode">
              <div className="seg">
                {PAY_MODES.map((m) => (
                  <button type="button" key={m.v} className={f.mode === m.v ? 'on' : ''} onClick={() => setF({ ...f, mode: m.v, received: m.v === 'NOT_PAID' ? 0 : f.received || Math.max(0, total - alreadyPaid) })}>
                    {m.l}
                  </button>
                ))}
              </div>
            </Field>
            <div className="grid2">
              {f.mode !== 'NOT_PAID' && (
                <Field label="Amount received now (₹)">
                  <input className="inp num" type="number" min={0} max={Math.max(0, total - alreadyPaid)} value={f.received} onChange={setNum('received')} />
                </Field>
              )}
              <Field label="Due after this">
                <input className="inp num" value={rupees(due)} disabled style={{ color: due > 0 ? 'var(--red)' : undefined, fontWeight: 700 }} />
              </Field>
            </div>
            {due > 0 && (
              <div className="card" style={{ background: 'var(--field)', padding: 14 }}>
                <Toggle on={f.allow} onChange={(v) => setF({ ...f, allow: v })} label="Allow gym entry until the due amount is paid" />
                <div className="small mut" style={{ marginTop: 6 }}>
                  {f.allow ? 'Front desk will see a "payment due" warning but the member can enter.' : 'Check-in will be blocked until the payment is recorded.'}
                </div>
              </div>
            )}
            <Field label="Note (optional)">
              <input className="inp" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} placeholder="e.g. Diwali offer" />
            </Field>
            <div className="small mut">The member app updates as soon as you save, and the member gets a notification.</div>
          </>
        )}
        <ErrorBox error={error} />
        <div className="row">
          <button className="btn" disabled={busy || !planId || !f.startDate}>
            {busy ? 'Saving…' : correcting ? 'Save correction' : 'Save membership'}
          </button>
          <button type="button" className="btn ghost" onClick={onClose}>
            Cancel
          </button>
        </div>
      </form>
    </Modal>
  );
}

function PaymentForm({ sub, onClose, onSaved }: { sub: Sub; onClose: () => void; onSaved: () => void }) {
  const [amount, setAmount] = useState(sub.due);
  const [mode, setMode] = useState('CASH');
  const [note, setNote] = useState('');
  const { busy, error, run } = useAction();
  return (
    <Modal title="Record payment" onClose={onClose}>
      <form
        className="stack"
        onSubmit={(e) => {
          e.preventDefault();
          run(async () => {
            await api(`/memberships/${sub.id}/payments`, { body: { amount, mode, note: note || undefined } });
            onSaved();
          });
        }}
      >
        <div className="mut">
          {sub.planName} · due <b style={{ color: 'var(--red)' }}>{rupees(sub.due)}</b>
        </div>
        <Field label="Amount (₹)">
          <input className="inp num" type="number" min={1} max={sub.due} value={amount} onChange={(e) => setAmount(Math.round(Number(e.target.value) || 0))} required autoFocus />
        </Field>
        <Field label="Paid by">
          <div className="seg">
            {PAY_MODES.filter((m) => m.v !== 'NOT_PAID').map((m) => (
              <button type="button" key={m.v} className={mode === m.v ? 'on' : ''} onClick={() => setMode(m.v)}>
                {m.l}
              </button>
            ))}
          </div>
        </Field>
        <Field label="Note (optional)">
          <input className="inp" value={note} onChange={(e) => setNote(e.target.value)} />
        </Field>
        <ErrorBox error={error} />
        <button className="btn" disabled={busy}>
          {busy ? 'Saving…' : `Record ${rupees(amount)}`}
        </button>
      </form>
    </Modal>
  );
}

function FreezeForm({ sub, daysLeft, onClose, onSaved }: { sub: Sub; daysLeft: number; onClose: () => void; onSaved: () => void }) {
  const [days, setDays] = useState(Math.min(7, daysLeft));
  const [start, setStart] = useState(todayIST());
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  return (
    <Modal title="Freeze membership" onClose={onClose}>
      <form
        className="stack"
        onSubmit={(e) => {
          e.preventDefault();
          run(async () => {
            await api(`/memberships/${sub.id}/freeze`, { body: { days, startDate: start, reason: reason || undefined } });
            onSaved();
          });
        }}
      >
        <div className="alert note">
          {daysLeft} freeze day{daysLeft === 1 ? '' : 's'} left on this {sub.planName} membership. The member cannot check in while frozen, and the end date moves ahead by the same number of days.
        </div>
        <div className="grid2">
          <Field label="Start date">
            <input className="inp" type="date" min={todayIST()} value={start} onChange={(e) => setStart(e.target.value)} required />
          </Field>
          <Field label="Days">
            <input className="inp num" type="number" min={1} max={daysLeft} value={days} onChange={(e) => setDays(Math.round(Number(e.target.value) || 0))} required />
          </Field>
        </div>
        <Field label="Reason (optional)">
          <input className="inp" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Travelling, injury" />
        </Field>
        <ErrorBox error={error} />
        <button className="btn" disabled={busy}>
          {busy ? 'Saving…' : `Freeze for ${days} day${days === 1 ? '' : 's'}`}
        </button>
      </form>
    </Modal>
  );
}

function EditMember({ d, onClose, onSaved }: { d: Detail; onClose: () => void; onSaved: () => void }) {
  const m = d.member;
  const [f, setF] = useState({ name: m.name, phone: m.phone.replace('+91', ''), email: m.email ?? '', gender: m.gender ?? '', notes: m.notes ?? '' });
  const { busy, error, run } = useAction();
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => setF({ ...f, [k]: e.target.value });
  return (
    <Modal title="Edit member" onClose={onClose}>
      <form
        className="stack"
        onSubmit={(e) => {
          e.preventDefault();
          run(async () => {
            await api(`/members/${m.id}`, { method: 'PATCH', body: { ...f, email: f.email || undefined, gender: f.gender || undefined } });
            onSaved();
          });
        }}
      >
        <div className="grid2">
          <Field label="Name">
            <input className="inp" value={f.name} onChange={set('name')} required />
          </Field>
          <Field label="Mobile">
            <input className="inp" value={f.phone} onChange={set('phone')} required />
          </Field>
          <Field label="Email">
            <input className="inp" type="email" value={f.email} onChange={set('email')} />
          </Field>
          <Field label="Gender">
            <select className="inp" value={f.gender} onChange={set('gender')}>
              <option value="">—</option>
              <option value="male">Male</option>
              <option value="female">Female</option>
              <option value="other">Other</option>
            </select>
          </Field>
        </div>
        <Field label="Notes">
          <textarea className="inp" value={f.notes} onChange={set('notes')} />
        </Field>
        <ErrorBox error={error} />
        <div className="row sp">
          <button className="btn" disabled={busy}>
            Save
          </button>
          <button
            type="button"
            className="btn danger sm"
            onClick={() =>
              run(async () => {
                await api(`/members/${m.id}`, { method: 'PATCH', body: { archived: !m.archived } });
                onSaved();
              })
            }
          >
            {m.archived ? 'Restore member' : 'Archive member'}
          </button>
        </div>
      </form>
    </Modal>
  );
}

function MemberPage() {
  const params = useSearchParams();
  const id = params.get('id') ?? '';
  const { data: d, error, loading, reload } = useApi<Detail>(id ? `/members/${id}` : null);
  const [modal, setModal] = useState<null | { t: 'add' } | { t: 'correct'; sub: Sub } | { t: 'pay'; sub: Sub } | { t: 'freeze'; sub: Sub } | { t: 'edit' }>(null);
  const [receipt, setReceipt] = useState<string | null>(null);
  const act = useAction();

  useEffect(() => {
    if (params.get('new') === '1') setModal({ t: 'add' });
  }, [params]);

  if (loading && !d) return <Loading />;
  if (!d) return <ErrorBox error={error} />;
  const m = d.member;
  const s = d.state;
  const current = d.history.find((h) => h.id === s.currentId);
  const activeFreeze = current?.freezes.find((f) => {
    const until = new Date(`${f.startDate}T00:00:00Z`);
    const used = f.endedOn ? Math.min(f.days, Math.round((new Date(`${f.endedOn}T00:00:00Z`).getTime() - until.getTime()) / 86400000)) : f.days;
    until.setUTCDate(until.getUTCDate() + used);
    return until.toISOString().slice(0, 10) > todayIST() && !f.endedOn;
  });
  const saved = () => {
    setModal(null);
    reload();
  };

  return (
    <>
      <div className="row" style={{ marginBottom: 10 }}>
        <Link href="/members" className="small mut row" style={{ gap: 4 }}>
          <Icon name="back" size={14} /> Members
        </Link>
      </div>
      <div className="top">
        <div className="row" style={{ gap: 14 }}>
          <Avatar name={m.name} url={m.photoUrl} size="lg" />
          <div>
            <h1>{m.name}</h1>
            <div className="mut">
              {m.memberCode} · {m.phone.replace('+91', '+91 ')} {m.hasApp ? <span className="lime">· using the app</span> : <span>· not on the app yet</span>}
              {m.archived && <span className="pill off" style={{ marginLeft: 8 }}>Archived</span>}
            </div>
          </div>
        </div>
        <div className="row wrap">
          <a className="btn ghost" href={`tel:${m.phone}`}>
            <Icon name="phone" /> Call
          </a>
          <a className="btn wa" href={`https://wa.me/${m.phone.replace(/\D/g, '')}`} target="_blank" rel="noreferrer">
            <Icon name="wa" /> WhatsApp
          </a>
          <button className="btn ghost" onClick={() => setModal({ t: 'edit' })}>
            Edit
          </button>
        </div>
      </div>

      {receipt && (
        <div className="alert okk" style={{ marginBottom: 14, alignItems: 'center' }}>
          <span className="grow">Membership saved. The member app is updated.</span>
        </div>
      )}
      <ErrorBox error={act.error} />

      <div className="grid2" style={{ alignItems: 'start' }}>
        <div className="stack">
          <div className="card stack">
            <div className="row sp">
              <h2>Current membership</h2>
              <StatusPill status={s.status} />
            </div>
            {current ? (
              <div className="grid2">
                <div>
                  <div className="small mut">Plan</div>
                  <div style={{ fontWeight: 700, fontSize: 16 }}>{current.planName}</div>
                </div>
                <div>
                  <div className="small mut">Ends on</div>
                  <div style={{ fontWeight: 700, fontSize: 16 }}>{fmtDate(s.endsOn)}</div>
                  {s.daysLeft != null && s.daysLeft >= 0 && <div className="small mut">{plural(s.daysLeft, 'day')} left</div>}
                </div>
                {s.frozenUntil && (
                  <div>
                    <div className="small mut">Frozen until</div>
                    <div style={{ fontWeight: 700 }}>{fmtDate(s.frozenUntil)}</div>
                  </div>
                )}
                <div>
                  <div className="small mut">Freeze days left</div>
                  <div style={{ fontWeight: 700 }}>{s.freezeDaysLeft}</div>
                </div>
              </div>
            ) : (
              <div className="mut">{s.status === 'EXPIRED' ? `Expired on ${fmtDate(s.endsOn)}` : s.status === 'UPCOMING' ? 'A membership starts later' : 'No membership yet'}</div>
            )}
            {s.due > 0 && (
              <div className="alert err">
                {rupees(s.due)} payment due
              </div>
            )}
            <div className={`alert ${s.entry.result === 'ALLOWED' ? 'okk' : s.entry.result === 'WARNED' ? 'note' : 'err'}`}>
              Gym entry today: <b>{s.entry.result === 'BLOCKED' ? 'Blocked' : 'Allowed'}</b>
              {s.entry.reason ? ` · ${s.entry.reason}` : ''}
            </div>
            <div className="row wrap">
              <button className="btn" onClick={() => setModal({ t: 'add' })} disabled={m.archived}>
                <Icon name="plus" /> {d.history.length ? 'Renew / add membership' : 'Add membership'}
              </button>
              {current && current.due > 0 && (
                <button className="btn ghost" onClick={() => setModal({ t: 'pay', sub: current })}>
                  <Icon name="rupee" /> Record payment
                </button>
              )}
              {current && !activeFreeze && s.freezeDaysLeft > 0 && (
                <button className="btn ghost" onClick={() => setModal({ t: 'freeze', sub: current })}>
                  <Icon name="snow" /> Freeze
                </button>
              )}
              {activeFreeze && (
                <button
                  className="btn ghost"
                  disabled={act.busy}
                  onClick={() =>
                    act.run(async () => {
                      await api(`/freezes/${activeFreeze.id}/end`, { body: {} });
                      reload();
                    })
                  }
                >
                  <Icon name="snow" /> End freeze now
                </button>
              )}
            </div>
          </div>

          <div className="card">
            <h2 style={{ marginBottom: 6 }}>Recent check-ins</h2>
            {d.attendance.length === 0 ? (
              <div className="empty">No check-ins yet.</div>
            ) : (
              <div className="list">
                {d.attendance.map((a) => (
                  <div className="li" key={a.id}>
                    <span className="grow">{fmtDateTime(a.scannedAt)}</span>
                    <span className={`pill ${a.result === 'ALLOWED' ? 'ok' : a.result === 'WARNED' ? 'warn' : 'bad'}`}>{a.result === 'BLOCKED' ? 'Blocked' : 'In'}</span>
                    {a.reason && <span className="small mut">{a.reason}</span>}
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>

        <div className="card">
          <h2 style={{ marginBottom: 6 }}>Membership history</h2>
          <div className="small mut" style={{ marginBottom: 8 }}>
            Entries are never edited or deleted. A correction adds a new entry.
          </div>
          {d.history.length === 0 ? (
            <div className="empty">Nothing yet.</div>
          ) : (
            <div className="list">
              {d.history.map((h) => (
                <div key={h.id} style={{ padding: '14px 0', opacity: h.superseded ? 0.5 : 1 }}>
                  <div className="row sp">
                    <div style={{ fontWeight: 700, textDecoration: h.superseded ? 'line-through' : undefined }}>{h.planName}</div>
                    <span className={`pill ${h.kind === 'CORRECTION' ? 'info' : h.kind === 'NEW' ? 'ok' : 'off'}`}>{h.superseded ? 'Corrected' : h.kind === 'NEW' ? 'New' : h.kind === 'RENEWAL' ? 'Renewal' : 'Correction'}</span>
                  </div>
                  <div className="small mut" style={{ marginTop: 3 }}>
                    {fmtDate(h.startDate)} – {fmtDate(h.endDate)}
                  </div>
                  <div className="row wrap small" style={{ marginTop: 6, gap: 14 }}>
                    <span>
                      Total <b className="num">{rupees(h.total)}</b>
                    </span>
                    {h.discount > 0 && <span>Discount {rupees(h.discount)}</span>}
                    {h.joiningFee > 0 && <span>Joining {rupees(h.joiningFee)}</span>}
                    <span>Paid {rupees(h.paid)}</span>
                    {!h.superseded && h.due > 0 && <span style={{ color: 'var(--red)', fontWeight: 700 }}>Due {rupees(h.due)}</span>}
                  </div>
                  {h.payments.map((p) => (
                    <div key={p.id} className="small mut" style={{ marginTop: 4 }}>
                      ✓ {rupees(p.amount)} by {modeLabel(p.mode)} · {p.receivedByName} · {fmtDateTime(p.receivedAt)}
                    </div>
                  ))}
                  {h.freezes.map((f) => (
                    <div key={f.id} className="small" style={{ marginTop: 4, color: 'var(--blue)' }}>
                      ❄ Frozen {f.days} days from {fmtDate(f.startDate)}
                      {f.endedOn ? ` (ended ${fmtDate(f.endedOn)})` : ''}
                      {f.reason ? ` · ${f.reason}` : ''}
                    </div>
                  ))}
                  {h.note && <div className="small" style={{ marginTop: 4 }}>“{h.note}”</div>}
                  <div className="row sp" style={{ marginTop: 6 }}>
                    <span className="small dim">
                      Added by {h.createdByName} · {fmtDateTime(h.createdAt)}
                    </span>
                    {!h.superseded && (
                      <span className="row" style={{ gap: 12 }}>
                        {h.due > 0 && (
                          <button className="linkbtn small" onClick={() => setModal({ t: 'pay', sub: h })}>
                            Record payment
                          </button>
                        )}
                        <button className="linkbtn small" onClick={() => setModal({ t: 'correct', sub: h })}>
                          Correct
                        </button>
                      </span>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {modal?.t === 'add' && (
        <MembershipForm
          memberId={m.id}
          onClose={() => setModal(null)}
          onSaved={(r) => {
            setReceipt(r);
            saved();
          }}
        />
      )}
      {modal?.t === 'correct' && (
        <MembershipForm
          memberId={m.id}
          correcting={modal.sub}
          onClose={() => setModal(null)}
          onSaved={(r) => {
            setReceipt(r);
            saved();
          }}
        />
      )}
      {modal?.t === 'pay' && <PaymentForm sub={modal.sub} onClose={() => setModal(null)} onSaved={saved} />}
      {modal?.t === 'freeze' && <FreezeForm sub={modal.sub} daysLeft={s.freezeDaysLeft} onClose={() => setModal(null)} onSaved={saved} />}
      {modal?.t === 'edit' && <EditMember d={d} onClose={() => setModal(null)} onSaved={saved} />}
    </>
  );
}

export default function Page() {
  return (
    <Suspense>
      <MemberPage />
    </Suspense>
  );
}
