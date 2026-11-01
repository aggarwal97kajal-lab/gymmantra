'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { ReactNode, useEffect, useState } from 'react';
import { api } from '@/lib/api';
import { useRequireGym } from '@/lib/session';
import { Icon, Loading } from './ui';

const GYM_NAV = [
  { href: '/dashboard', label: 'Dashboard', icon: 'grid' },
  { href: '/members', label: 'Members', icon: 'users' },
  { href: '/requests', label: 'Join requests', icon: 'inbox', badge: 'join' },
  { href: '/plans', label: 'Membership plans', icon: 'card' },
  { href: '/attendance', label: 'Attendance', icon: 'qr' },
  { href: '/support', label: 'Member support', icon: 'msg', badge: 'tickets' },
  { href: '/staff', label: 'Staff', icon: 'staff', owner: true },
  { href: '/settings', label: 'Gym settings', icon: 'gear', owner: true },
];

export function Shell({ children }: { children: ReactNode }) {
  const s = useRequireGym();
  const path = usePathname();
  const [open, setOpen] = useState(false);
  const [badges, setBadges] = useState<{ join: number; tickets: number }>({ join: 0, tickets: 0 });

  useEffect(() => setOpen(false), [path]);
  useEffect(() => {
    if (!s.gym) return;
    api<{ joinPending: number; openTickets: number }>('/dashboard')
      .then((d) => setBadges({ join: d.joinPending, tickets: d.openTickets }))
      .catch(() => null);
  }, [s.gym, path]);

  const inSuper = path.startsWith('/super');
  if (s.loading || !s.me || (!s.gym && !inSuper && !path.startsWith('/account'))) return <Loading />;
  const isOwner = s.gym?.role === 'OWNER';

  return (
    <div className="shell">
      <aside className={`side ${open ? 'open' : ''}`}>
        <div className="brand">
          <img src="/mark.svg" alt="" />
          <div>
            <b>
              Gym<span>Mantra</span>
            </b>
            <small>{inSuper ? 'Platform admin' : s.gym?.name}</small>
          </div>
        </div>
        {s.gym &&
          GYM_NAV.filter((n) => !n.owner || isOwner).map((n) => {
            const count = n.badge === 'join' ? badges.join : n.badge === 'tickets' ? badges.tickets : 0;
            return (
              <Link key={n.href} href={n.href} className={`nav ${path.startsWith(n.href) ? 'on' : ''}`}>
                <Icon name={n.icon} />
                {n.label}
                {count > 0 && <span className="badge">{count}</span>}
              </Link>
            );
          })}
        {s.me.user.isSuperAdmin && (
          <Link href="/super" className={`nav ${inSuper ? 'on' : ''}`} style={{ marginTop: 10 }}>
            <Icon name="shield" />
            Super admin
          </Link>
        )}
        <div className="sidefoot">
          <div style={{ color: 'var(--fg)', fontWeight: 650 }}>{s.me.user.name}</div>
          <div>{s.gym ? (isOwner ? 'Owner' : 'Front desk') : 'GymMantra team'}</div>
          {s.me.gyms.length > 1 && (
            <select className="inp" style={{ height: 34, marginTop: 8, fontSize: 12.5 }} value={s.gym?.id ?? ''} onChange={(e) => s.switchGym(e.target.value)} aria-label="Switch gym">
              {s.me.gyms.map((g) => (
                <option key={g.id} value={g.id}>
                  {g.name}
                </option>
              ))}
            </select>
          )}
          <div className="row" style={{ marginTop: 10, gap: 6 }}>
            <Link href="/account" className="btn ghost sm">
              Account
            </Link>
            <button className="btn ghost sm" onClick={s.logout}>
              <Icon name="logout" size={14} /> Log out
            </button>
          </div>
        </div>
      </aside>
      <div style={{ minWidth: 0 }}>
        <div className="mobilebar">
          <button className="btn ghost sm" onClick={() => setOpen(true)} aria-label="Open menu">
            <Icon name="menu" />
          </button>
          <img src="/mark.svg" alt="" width={26} height={26} />
          <b style={{ fontWeight: 800 }}>{inSuper ? 'Super admin' : s.gym?.name}</b>
        </div>
        <main className="main">{children}</main>
      </div>
    </div>
  );
}
