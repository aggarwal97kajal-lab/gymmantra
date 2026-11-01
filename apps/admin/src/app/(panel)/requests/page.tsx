'use client';

import Link from 'next/link';
import { Avatar, ErrorBox, Loading, PageTop, useAction, useApi } from '@/components/ui';
import { api, fmtDateTime } from '@/lib/api';
import { useSession } from '@/lib/session';

interface JR { id: string; createdAt: string; user: { id: string; name: string; phone: string | null; email: string | null; photoUrl: string | null } }

export default function Requests() {
  const { gym } = useSession();
  const { data, error, loading, reload } = useApi<JR[]>('/join-requests');
  const act = useAction();
  return (
    <>
      <PageTop crumb="Members" title="Join requests" />
      <div className="card stack" style={{ maxWidth: 760 }}>
        <p className="mut" style={{ margin: 0 }}>
          Members send a request from the app with your gym code <b className="lime">{gym?.gymCode}</b>. If you already added them by hand with the same mobile number, approving links that record.
        </p>
        <ErrorBox error={error ?? act.error} />
        {loading && !data ? (
          <Loading />
        ) : !data?.length ? (
          <div className="empty">No pending requests.</div>
        ) : (
          <div className="list">
            {data.map((r) => (
              <div className="li" key={r.id}>
                <Avatar name={r.user.name} url={r.user.photoUrl} />
                <div className="grow">
                  <div style={{ fontWeight: 650 }}>{r.user.name}</div>
                  <div className="small mut">
                    {r.user.phone?.replace('+91', '') ?? 'No phone'} · {fmtDateTime(r.createdAt)}
                  </div>
                </div>
                <button className="btn ghost sm" disabled={act.busy} onClick={() => act.run(async () => { await api(`/join-requests/${r.id}/decline`, { body: {} }); reload(); })}>
                  Decline
                </button>
                <button
                  className="btn sm"
                  disabled={act.busy}
                  onClick={() =>
                    act.run(async () => {
                      const m = await api<{ id: string }>(`/join-requests/${r.id}/approve`, { body: {} });
                      window.location.href = `/members/view?id=${m.id}&new=1`;
                    })
                  }
                >
                  Approve
                </button>
              </div>
            ))}
          </div>
        )}
        <Link href="/settings#poster" className="small">Print the QR poster for your front desk</Link>
      </div>
    </>
  );
}
