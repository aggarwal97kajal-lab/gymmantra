'use client';

import { useRouter } from 'next/navigation';
import { useEffect } from 'react';
import { Loading } from '@/components/ui';
import { useSession } from '@/lib/session';

export default function Home() {
  const s = useSession();
  const router = useRouter();
  useEffect(() => {
    if (s.loading) return;
    if (!s.me) router.replace('/login');
    else if (s.gym) router.replace('/dashboard');
    else router.replace(s.me.user.isSuperAdmin ? '/super' : '/onboarding');
  }, [s.loading, s.me, s.gym, router]);
  return <Loading />;
}
