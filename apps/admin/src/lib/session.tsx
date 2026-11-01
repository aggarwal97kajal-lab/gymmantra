'use client';

import { usePathname, useRouter } from 'next/navigation';
import { createContext, ReactNode, useCallback, useContext, useEffect, useState } from 'react';
import { api, getGymId, setGymId } from './api';

export interface MeGym {
  id: string;
  name: string;
  gymCode: string;
  status: string;
  logoUrl: string | null;
  role: 'OWNER' | 'FRONT_DESK';
  branchIds: string[];
}
export interface Me {
  user: { id: string; name: string; email: string | null; phone: string | null; photoUrl: string | null; isSuperAdmin: boolean; hasPassword: boolean; hasGoogle: boolean };
  gyms: MeGym[];
}

interface Ctx {
  me: Me | null;
  gym: MeGym | null;
  loading: boolean;
  refresh: () => Promise<Me | null>;
  switchGym: (id: string) => void;
  logout: () => Promise<void>;
}

const SessionCtx = createContext<Ctx>(null as unknown as Ctx);
export const useSession = () => useContext(SessionCtx);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [me, setMe] = useState<Me | null>(null);
  const [gymId, setGym] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const m = await api<Me>('/auth/me');
      setMe(m);
      const saved = getGymId();
      const pick = m.gyms.find((g) => g.id === saved) ?? m.gyms[0] ?? null;
      setGymId(pick?.id ?? null);
      setGym(pick?.id ?? null);
      return m;
    } catch {
      setMe(null);
      return null;
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const switchGym = (id: string) => {
    setGymId(id);
    setGym(id);
    window.location.href = '/dashboard';
  };

  const logout = async () => {
    await api('/auth/logout', { method: 'POST', body: {} }).catch(() => null);
    setGymId(null);
    setMe(null);
    window.location.href = '/login';
  };

  const gym = me?.gyms.find((g) => g.id === gymId) ?? null;
  return <SessionCtx.Provider value={{ me, gym, loading, refresh, switchGym, logout }}>{children}</SessionCtx.Provider>;
}

/** Redirects to login (or onboarding) when needed. */
export function useRequireGym() {
  const s = useSession();
  const router = useRouter();
  const path = usePathname();
  useEffect(() => {
    if (s.loading) return;
    if (!s.me) router.replace(`/login?next=${encodeURIComponent(path)}`);
    else if (!s.gym && !path.startsWith('/super') && !path.startsWith('/account')) router.replace(s.me.user.isSuperAdmin ? '/super' : '/onboarding');
  }, [s.loading, s.me, s.gym, router, path]);
  return s;
}
