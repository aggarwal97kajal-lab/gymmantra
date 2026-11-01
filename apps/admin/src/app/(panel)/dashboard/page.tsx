'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { ErrorBox, Icon, Loading, PageTop, StatusPill, useApi } from '@/components/ui';
import { fmtDate, plural, rupees } from '@/lib/api';
import { useSession } from '@/lib/session';

interface Dash {
  totals: { members: number; active: number; endingSoon: number; expired: number; frozen: number; noPlan: number; dueAmount: number; dueMembers: number };
  today: { collected: number; payments: number; checkins: number };
  joinPending: number;
  openTickets: number;
  renewalsDue: { id: string; name: string; memberCode: string; planName: string | null; endsOn: string | null; daysLeft: number | null; status: string; due: number }[];
}

export default function Dashboard() {
  const { gym } = useSession();
  const router = useRouter();
  const { data, error, loading } = useApi<Dash>('/dashboard');
  if (loading && !data) return <Loading />;
  return (
    <>
      <PageTop crumb={gym?.name} title="Dashboard">
        <Link className="btn ghost" href="/attendance">
          <Icon name="qr" /> Scan check-in
        </Link>
        <Link className="btn" href="/members/new">
          <Icon name="plus" /> Add member
        </Link>
      </PageTop>
      <ErrorBox error={error} />
      {data && (
        <div className="stack">
          <div className="kpis">
            <Link href="/members?tab=active" className="card kpi" style={{ color: 'inherit' }}>
              <div className="k">Active members</div>
              <div className="v num">{data.totals.active}</div>
              <div className="s">of {data.totals.members} total</div>
            </Link>
            <Link href="/members?tab=ending" className="card kpi" style={{ color: 'inherit' }}>
              <div className="k">Ending in 7 days</div>
              <div className="v num" style={{ color: 'var(--org)' }}>{data.totals.endingSoon}</div>
              <div className="s">Remind them to renew</div>
            </Link>
            <Link href="/members?tab=expired" className="card kpi" style={{ color: 'inherit' }}>
              <div className="k">Expired</div>
              <div className="v num" style={{ color: 'var(--red)' }}>{data.totals.expired}</div>
              <div className="s">{data.totals.frozen} frozen · {data.totals.noPlan} no plan</div>
            </Link>
            <div className="card kpi">
              <div className="k">Collected today</div>
              <div className="v num lime">{rupees(data.today.collected)}</div>
              <div className="s">{data.today.payments} payments · {data.today.checkins} check-ins</div>
            </div>
          </div>
          {(data.joinPending > 0 || data.totals.dueAmount > 0 || data.openTickets > 0) && (
            <div className="row wrap">
              {data.joinPending > 0 && (
                <Link href="/requests" className="pill warn">
                  {data.joinPending} join request{data.joinPending > 1 ? 's' : ''} waiting
                </Link>
              )}
              {data.totals.dueAmount > 0 && (
                <Link href="/members?tab=due" className="pill bad">
                  {rupees(data.totals.dueAmount)} due from {data.totals.dueMembers} member{data.totals.dueMembers > 1 ? 's' : ''}
                </Link>
              )}
              {data.openTickets > 0 && (
                <Link href="/support" className="pill info">
                  {data.openTickets} open support ticket{data.openTickets > 1 ? 's' : ''}
                </Link>
              )}
            </div>
          )}
          <div className="card">
            <div className="row sp" style={{ marginBottom: 6 }}>
              <h2>Renewals due</h2>
              <Link href="/members?tab=ending" className="small">
                See all
              </Link>
            </div>
            {data.renewalsDue.length === 0 ? (
              <div className="empty">No renewals due. Nice!</div>
            ) : (
              <div className="tblwrap">
                <table>
                  <thead>
                    <tr>
                      <th>MEMBER</th>
                      <th>PLAN</th>
                      <th>ENDS</th>
                      <th>STATUS</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.renewalsDue.map((m) => (
                      <tr key={m.id} className="click" onClick={() => router.push(`/members/view?id=${m.id}`)}>
                        <td>
                          <div style={{ fontWeight: 650 }}>{m.name}</div>
                          <div className="small mut">{m.memberCode}</div>
                        </td>
                        <td>{m.planName ?? '—'}</td>
                        <td>
                          {fmtDate(m.endsOn)}
                          <div className="small mut">{m.daysLeft != null && (m.daysLeft >= 0 ? `${plural(m.daysLeft, 'day')} left` : `${plural(-m.daysLeft, 'day')} ago`)}</div>
                        </td>
                        <td>
                          <StatusPill status={m.status} />
                        </td>
                        <td style={{ textAlign: 'right' }}>
                          <span className="btn sm">Renew</span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>
      )}
    </>
  );
}
