'use client';

import { useEffect, useRef, useState } from 'react';
import { api } from '@/lib/api';

declare global {
  interface Window {
    google?: any;
  }
}

/**
 * Google Identity Services button. Shown only when the API has a Google
 * client ID configured. Hands the Google ID token to onToken.
 */
export function GoogleButton({ text, onToken }: { text: 'signin_with' | 'signup_with' | 'continue_with'; onToken: (idToken: string) => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [clientId, setClientId] = useState<string | null | undefined>(undefined);
  const cb = useRef(onToken);
  cb.current = onToken;

  useEffect(() => {
    api<{ googleClientId: string | null }>('/auth/config')
      .then((c) => setClientId(c.googleClientId))
      .catch(() => setClientId(null));
  }, []);

  useEffect(() => {
    if (!clientId || !ref.current) return;
    const render = () => {
      if (!window.google || !ref.current) return;
      window.google.accounts.id.initialize({ client_id: clientId, callback: (r: { credential: string }) => cb.current(r.credential) });
      window.google.accounts.id.renderButton(ref.current, { theme: 'filled_black', size: 'large', shape: 'pill', text, width: 320 });
    };
    if (window.google) return render();
    const s = document.createElement('script');
    s.src = 'https://accounts.google.com/gsi/client';
    s.async = true;
    s.onload = render;
    document.head.appendChild(s);
  }, [clientId, text]);

  if (!clientId) return null;
  return (
    <>
      <div className="or">or</div>
      <div ref={ref} style={{ display: 'flex', justifyContent: 'center', minHeight: 44 }} />
    </>
  );
}
