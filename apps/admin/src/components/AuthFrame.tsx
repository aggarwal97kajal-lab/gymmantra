import { ReactNode } from 'react';

export function AuthFrame({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="auth">
      <div className="authcard">
        <div className="authlogo">
          <img src="/mark.svg" alt="" />
          <b>
            Gym<span>Mantra</span>
          </b>
          <span className="mut">Fitness ka sahi mantra.</span>
        </div>
        <div className="card stack" style={{ padding: 24 }}>
          <h2 style={{ fontSize: 20 }}>{title}</h2>
          {children}
        </div>
      </div>
    </div>
  );
}
