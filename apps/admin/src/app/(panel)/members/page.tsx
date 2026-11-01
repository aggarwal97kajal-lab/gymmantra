'use client';

import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import { Suspense, useState } from 'react';
import { Avatar, ErrorBox, Icon, Loading, Modal, PageTop, StatusPill, useAction, useApi } from '@/components/ui';
import { api, fmtDate, plural, rupees } from '@/lib/api';

interface Row {
  id: string;
  name: string;
  phone: string;
  memberCode: string;
  photoUrl: string | null;
  hasApp: boolean;
  status: string;
  planName: string | null;
  endsOn: string | null;
  daysLeft: number | null;
  due: number;
}

const TABS = [
  ['all', 'All'],
  ['active', 'Active'],
  ['ending', 'Ending in 7 days'],
  ['expired', 'Expired'],
  ['frozen', 'Frozen'],
  ['due', 'Payment due'],
  ['noplan', 'No plan'],
] as const;

function Members() {
  const params = useSearchParams();
  const router = useRouter();
  const tab = params.get('tab') ?? 'all';
  const [q, setQ] = useState('');
  const [query, setQuery] = useState('');
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [links, setLinks] = useState<{ memberId: string; name: string; link: string }[] | null>(null);
  const [sent, setSent] = useState<Set<string>>(new Set());
  const { data, error, loading } = useApi<{ rows: Row[]; counts: Record<string, number> }>(`/members?tab=${tab}&q=${encodeURIComponent(query)}`);
  const act = useAction();

  const toggle = (id: string) => {
    const n = new Set(sel);
    n.has(id) ? n.delete(id) : n.add(id);
    setSel(n);
  };
  const remind = () =>
    act.run(async () => {
      setLinks(await api('/members/reminders', { body: { memberIds: [...sel] } }));
      setSent(new Set());
    });

  return (
    <>
      <PageTop crumb="Members" title="Members">
        <Link className="btn ghost" href="/members/import">
          <Icon name="upload" /> Import from Excel
        </Link>
        <Link className="btn" href="/members/new">
          <Icon name="plus" /> Add member
        </Link>
      </PageTop>
      <div className="stack">
        <div className="tabs">
          {TABS.map(([k, l]) => (
            <button key={k} className={`tab ${tab === k ? 'on' : ''}`} onClick={() => { setSel(new Set()); router.replace(`/members?tab=${k}`); }}>
              {l} <span className="num">{data?.counts[k] ?? '·'}</span>
            </button>
          ))}
        </div>
        <div className="row wrap sp">
          <form className="search grow" style={{ maxWidth: 420 }} onSubmit={(e) => { e.preventDefault(); setQuery(q); }}>
            <Icon name="search" size={16} color="var(--mut)" />
            <input placeholder="Search name, phone or member ID" value={q} onChange={(e) => { setQ(e.target.value); if (!e.target.value) setQuery(''); }} />
          </form>
          {sel.size > 0 && (
            <button className="btn wa" onClick={remind} disabled={act.busy}>
              <Icon name="wa" /> WhatsApp reminder ({sel.size})
            </button>
          )}
        </div>
        <ErrorBox error={error ?? act.error} />
        <div className="card" style={{ padding: '6px 12px' }}>
          {loading && !data ? (
            <Loading />
          ) : !data?.rows.length ? (
            <div className="empty">{query ? 'No members match your search.' : 'No members here yet.'}</div>
          ) : (
            <div className="tblwrap">
              <table>
                <thead>
                  <tr>
                    <th style={{ width: 30 }}>
                      <input type="checkbox" aria-label="Select all" checked={sel.size === data.rows.length} onChange={(e) => setSel(e.target.checked ? new Set(data.rows.map((r) => r.id)) : new Set())} />
                    </th>
                    <th>MEMBER</th>
                    <th>PHONE</th>
                    <th>PLAN</th>
                    <th>ENDS</th>
                    <th>DUE</th>
                    <th>STATUS</th>
                  </tr>
                </thead>
                <tbody>
                  {data.rows.map((m) => (
                    <tr key={m.id} className="click" onClick={() => router.push(`/members/view?id=${m.id}`)}>
                      <td onClick={(e) => e.stopPropagation()}>
                        <input type="checkbox" aria-label={`Select ${m.name}`} checked={sel.has(m.id)} onChange={() => toggle(m.id)} />
                      </td>
                      <td>
                        <div className="row">
                          <Avatar name={m.name} url={m.photoUrl} />
                          <div>
                            <div style={{ fontWeight: 650 }}>{m.name}</div>
                            <div className="small mut">
                              {m.memberCode}
                              {m.hasApp && <span className="lime"> · on app</span>}
                            </div>
                          </div>
                        </div>
                      </td>
                      <td className="num">{m.phone.replace('+91', '')}</td>
                      <td>{m.planName ?? <span className="dim">—</span>}</td>
                      <td>
                        {fmtDate(m.endsOn)}
                        {m.daysLeft != null && m.daysLeft >= 0 && <div className="small mut">{plural(m.daysLeft, 'day')} left</div>}
                      </td>
                      <td className="num">{m.due > 0 ? <span style={{ color: 'var(--red)', fontWeight: 650 }}>{rupees(m.due)}</span> : <span className="dim">—</span>}</td>
                      <td>
                        <StatusPill status={m.status} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>
      {links && (
        <Modal title="Send WhatsApp reminders" onClose={() => setLinks(null)}>
          <p className="mut small" style={{ marginTop: 0 }}>
            Tap each member to open WhatsApp with the message ready. It sends from the gym WhatsApp on this phone.
          </p>
          <div className="list">
            {links.map((l) => (
              <div className="li" key={l.memberId}>
                <div className="grow" style={{ fontWeight: 600 }}>{l.name}</div>
                <a className={`btn sm ${sent.has(l.memberId) ? 'ghost' : 'wa'}`} href={l.link} target="_blank" rel="noreferrer" onClick={() => setSent(new Set(sent).add(l.memberId))}>
                  {sent.has(l.memberId) ? 'Opened ✓' : 'Open WhatsApp'}
                </a>
              </div>
            ))}
          </div>
        </Modal>
      )}
    </>
  );
}

export default function MembersPage() {
  return (
    <Suspense>
      <Members />
    </Suspense>
  );
}
