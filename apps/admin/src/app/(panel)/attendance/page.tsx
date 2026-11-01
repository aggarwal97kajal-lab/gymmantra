'use client';

import Link from 'next/link';
import { useCallback, useEffect, useRef, useState } from 'react';
import { ErrorBox, Icon, PageTop, StatusPill, useAction, useApi } from '@/components/ui';
import { api, fmtDate, fmtTime, rupees } from '@/lib/api';

interface ScanResult {
  member: { id: string; name: string; memberCode: string };
  status: string;
  planName: string | null;
  endsOn: string | null;
  daysLeft: number | null;
  due: number;
  result: 'ALLOWED' | 'WARNED' | 'BLOCKED';
  reason: string | null;
  duplicate: boolean;
}
interface Today { checkins: number; inGymNow: number; blocked: number; events: { id: string; scannedAt: string; result: string; reason: string | null; method: string; member: { id: string; name: string; memberCode: string } }[] }

function Scanner({ onCode }: { onCode: (text: string) => void }) {
  const ref = useRef<any>(null);
  const [on, setOn] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const last = useRef<{ t: string; at: number }>({ t: '', at: 0 });
  const cb = useRef(onCode);
  cb.current = onCode;

  const stop = useCallback(async () => {
    try {
      await ref.current?.stop();
    } catch {
      /* already stopped */
    }
    ref.current = null;
    setOn(false);
  }, []);

  const start = async () => {
    setErr(null);
    try {
      const { Html5Qrcode } = await import('html5-qrcode');
      const q = new Html5Qrcode('qr-reader', { verbose: false } as any);
      ref.current = q;
      await q.start(
        { facingMode: 'environment' },
        { fps: 10, qrbox: { width: 240, height: 240 } },
        (text: string) => {
          const now = Date.now();
          if (text === last.current.t && now - last.current.at < 4000) return;
          last.current = { t: text, at: now };
          cb.current(text);
        },
        () => undefined,
      );
      setOn(true);
    } catch (e: any) {
      setErr('Could not open the camera. Allow camera access for this site, or use manual check-in.');
      ref.current = null;
    }
  };
  useEffect(() => () => void stop(), [stop]);

  return (
    <div className="stack">
      <div id="qr-reader" style={{ width: '100%', maxWidth: 420, borderRadius: 16, overflow: 'hidden', background: '#000', minHeight: on ? 260 : 0 }} />
      {err && <div className="alert err">{err}</div>}
      <button className={`btn ${on ? 'ghost' : ''}`} onClick={on ? stop : start} style={{ justifySelf: 'start' }}>
        <Icon name="camera" /> {on ? 'Stop camera' : 'Start camera to scan'}
      </button>
    </div>
  );
}

export default function Attendance() {
  const today = useApi<Today>('/attendance/today');
  const [result, setResult] = useState<ScanResult | null>(null);
  const [q, setQ] = useState('');
  const [matches, setMatches] = useState<{ id: string; name: string; memberCode: string; phone: string; status: string }[]>([]);
  const { busy, error, setError, run } = useAction();

  const scan = (token: string) =>
    run(async () => {
      setResult(await api<ScanResult>('/attendance/scan', { body: { token } }));
      today.reload();
    });
  const manual = (memberId: string) =>
    run(async () => {
      setResult(await api<ScanResult>('/attendance/manual', { body: { memberId } }));
      setMatches([]);
      setQ('');
      today.reload();
    });
  const search = async (text: string) => {
    setQ(text);
    if (text.trim().length < 2) return setMatches([]);
    try {
      const r = await api<{ rows: any[] }>(`/members?tab=all&q=${encodeURIComponent(text)}`);
      setMatches(r.rows.slice(0, 6));
    } catch (e: any) {
      setError(e.message);
    }
  };

  return (
    <>
      <PageTop crumb="Front desk" title="Attendance" />
      <div className="kpis" style={{ marginBottom: 14 }}>
        <div className="card kpi">
          <div className="k">Check-ins today</div>
          <div className="v num">{today.data?.checkins ?? '·'}</div>
        </div>
        <div className="card kpi">
          <div className="k">In the gym now</div>
          <div className="v num lime">{today.data?.inGymNow ?? '·'}</div>
          <div className="s">Checked in within 2 hours</div>
        </div>
        <div className="card kpi">
          <div className="k">Blocked today</div>
          <div className="v num" style={{ color: 'var(--red)' }}>{today.data?.blocked ?? '·'}</div>
        </div>
      </div>
      <div className="grid2" style={{ alignItems: 'start' }}>
        <div className="stack">
          <div className="card stack">
            <h2>Scan member QR</h2>
            <p className="small mut" style={{ margin: 0 }}>
              Members open “QR check-in” in the GymMantra app. The code changes every 30 seconds, so screenshots do not work.
            </p>
            <Scanner onCode={scan} />
          </div>
          <div className="card stack">
            <h2>Manual check-in</h2>
            <div className="search">
              <Icon name="search" size={16} color="var(--mut)" />
              <input placeholder="Name, phone or member ID" value={q} onChange={(e) => search(e.target.value)} />
            </div>
            {matches.map((m) => (
              <div className="li" key={m.id} style={{ borderTop: '1px solid var(--line)' }}>
                <div className="grow">
                  <div style={{ fontWeight: 650 }}>{m.name}</div>
                  <div className="small mut">{m.memberCode}</div>
                </div>
                <StatusPill status={m.status} />
                <button className="btn sm" disabled={busy} onClick={() => manual(m.id)}>
                  Check in
                </button>
              </div>
            ))}
          </div>
        </div>
        <div className="stack">
          <ErrorBox error={error} />
          {result && (
            <div className={`result ${result.result}`}>
              <div style={{ fontSize: 44, lineHeight: 1 }}>{result.result === 'BLOCKED' ? '✕' : '✓'}</div>
              <div style={{ fontSize: 24, fontWeight: 800, marginTop: 8 }}>
                {result.duplicate ? 'Already checked in' : result.result === 'BLOCKED' ? 'Blocked' : result.result === 'WARNED' ? 'Allowed · check note' : 'Allowed'}
              </div>
              <div style={{ fontSize: 18, fontWeight: 700, marginTop: 10 }}>{result.member.name}</div>
              <div className="mut">
                {result.member.memberCode} · {result.planName ?? 'No plan'}
                {result.endsOn ? ` · ends ${fmtDate(result.endsOn)}` : ''}
              </div>
              {result.reason && <div style={{ marginTop: 10, fontWeight: 650 }}>{result.reason}</div>}
              <div className="row" style={{ justifyContent: 'center', marginTop: 14 }}>
                <Link className="btn ghost sm" href={`/members/view?id=${result.member.id}`}>
                  Open profile
                </Link>
                {result.result === 'BLOCKED' && (
                  <Link className="btn sm" href={`/members/view?id=${result.member.id}&new=1`}>
                    {result.due > 0 ? `Collect ${rupees(result.due)}` : 'Renew now'}
                  </Link>
                )}
              </div>
            </div>
          )}
          <div className="card">
            <h2 style={{ marginBottom: 6 }}>Today</h2>
            {!today.data?.events.length ? (
              <div className="empty">No check-ins yet today.</div>
            ) : (
              <div className="list">
                {today.data.events.map((e) => (
                  <Link key={e.id} href={`/members/view?id=${e.member.id}`} className="li" style={{ color: 'inherit' }}>
                    <span className="num mut" style={{ width: 70 }}>{fmtTime(e.scannedAt)}</span>
                    <span className="grow" style={{ fontWeight: 600 }}>{e.member.name}</span>
                    <span className={`pill ${e.result === 'ALLOWED' ? 'ok' : e.result === 'WARNED' ? 'warn' : 'bad'}`}>{e.result === 'BLOCKED' ? 'Blocked' : 'In'}</span>
                  </Link>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
    </>
  );
}
