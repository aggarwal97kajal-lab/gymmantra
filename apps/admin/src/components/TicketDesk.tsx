'use client';

import { useState } from 'react';
import { ErrorBox, Loading, useAction, useApi } from './ui';
import { api, fmtDateTime } from '@/lib/api';

interface TicketRow { id: string; subject: string; topic: string; status: string; updatedAt: string; messages: { body: string }[] }
interface Ticket extends TicketRow {
  member: { id: string; name: string; memberCode: string; phone: string } | null;
  authors: { id: string; name: string }[];
  userId: string;
  messages: { id: string; body: string; fromStaff: boolean; authorId: string; createdAt: string; attachmentUrl: string | null }[];
}

const TOPIC: Record<string, string> = {
  membership: 'Membership', payment: 'Payment', checkin: 'Check-in', facility: 'Gym facility', trainer: 'Trainer', other_gym: 'Other',
  app_login: 'Login problem', app_bug: 'App problem', app_other: 'App – other',
};

const QUICK = ['Thanks, we are checking this.', 'This is fixed now. Please check the app.', 'Please visit the front desk and we will help you.'];

/** Shared by the gym support inbox and the GymMantra support inbox. */
export function TicketDesk({ base }: { base: '/tickets' | '/super/tickets' }) {
  const [status, setStatus] = useState<'OPEN' | 'RESOLVED'>('OPEN');
  const list = useApi<TicketRow[]>(`${base}?status=${status}`);
  const [openId, setOpenId] = useState<string | null>(null);
  const t = useApi<Ticket>(openId ? `${base}/${openId}` : null);
  const [body, setBody] = useState('');
  const { busy, error, run } = useAction();
  const name = (id: string) => t.data?.authors.find((a) => a.id === id)?.name ?? '';

  const send = (text: string) =>
    run(async () => {
      await api(`${base}/${openId}/messages`, { body: { body: text } });
      setBody('');
      t.reload();
      list.reload();
    });

  return (
    <div className="grid2" style={{ gridTemplateColumns: 'minmax(0,2fr) minmax(0,3fr)', alignItems: 'start' }}>
      <div className="card">
        <div className="tabs" style={{ marginBottom: 8 }}>
          {(['OPEN', 'RESOLVED'] as const).map((s) => (
            <button key={s} className={`tab ${status === s ? 'on' : ''}`} onClick={() => setStatus(s)}>
              {s === 'OPEN' ? 'Open' : 'Resolved'}
            </button>
          ))}
        </div>
        {list.loading && !list.data ? (
          <Loading />
        ) : !list.data?.length ? (
          <div className="empty">No {status === 'OPEN' ? 'open' : 'resolved'} tickets.</div>
        ) : (
          <div className="list">
            {list.data.map((x) => (
              <button key={x.id} className="li" style={{ width: '100%', background: openId === x.id ? 'var(--card2)' : 'none', border: 0, textAlign: 'left', borderRadius: 10, padding: 10 }} onClick={() => setOpenId(x.id)}>
                <div className="grow">
                  <div style={{ fontWeight: 650 }}>{x.subject}</div>
                  <div className="small mut" style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>
                    {TOPIC[x.topic] ?? x.topic} · {fmtDateTime(x.updatedAt)}
                  </div>
                </div>
              </button>
            ))}
          </div>
        )}
      </div>
      <div className="card">
        {!openId ? (
          <div className="empty">Pick a ticket to read and reply.</div>
        ) : !t.data ? (
          <Loading />
        ) : (
          <div className="stack">
            <div className="row sp">
              <div>
                <h2>{t.data.subject}</h2>
                <div className="small mut">
                  {TOPIC[t.data.topic]} · {t.data.member ? `${t.data.member.name} (${t.data.member.memberCode})` : name(t.data.userId)}
                </div>
              </div>
              {t.data.status === 'OPEN' ? (
                <button className="btn ghost sm" disabled={busy} onClick={() => run(async () => { await api(`${base}/${openId}/resolve`, { body: {} }); t.reload(); list.reload(); })}>
                  Mark resolved
                </button>
              ) : (
                <span className="pill ok">Resolved</span>
              )}
            </div>
            <div className="chat">
              {t.data.messages.map((m) => (
                <div key={m.id} className={`bubble ${m.fromStaff ? 'me' : ''}`}>
                  <div className="small" style={{ opacity: 0.7, marginBottom: 3 }}>
                    {m.fromStaff ? name(m.authorId) || 'Staff' : name(m.authorId)} · {fmtDateTime(m.createdAt)}
                  </div>
                  {m.body}
                  {m.attachmentUrl && (
                    <div>
                      <a href={m.attachmentUrl} target="_blank" rel="noreferrer">Attachment</a>
                    </div>
                  )}
                </div>
              ))}
            </div>
            <div className="row wrap" style={{ gap: 6 }}>
              {QUICK.map((q) => (
                <button key={q} className="tab" style={{ fontSize: 12 }} onClick={() => setBody(q)}>
                  {q}
                </button>
              ))}
            </div>
            <form className="row" onSubmit={(e) => { e.preventDefault(); if (body.trim()) send(body); }}>
              <input className="inp grow" value={body} onChange={(e) => setBody(e.target.value)} placeholder="Write a reply" />
              <button className="btn" disabled={busy || !body.trim()}>Send</button>
            </form>
            <ErrorBox error={error} />
          </div>
        )}
      </div>
    </div>
  );
}
