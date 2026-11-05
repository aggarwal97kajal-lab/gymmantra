import { sendPush, takePush } from './lib/push';
import { gateRoutes } from './routes/gate';
import { ownershipRoutes } from './routes/ownership';
import { staffDayRoutes } from './routes/staffdays';
import { tokenSrc } from './identity';
import { checkinRoutes } from './routes/checkin';
import { dueRoutes } from './routes/dues';
import { noticeRoutes } from './routes/notices';
import { reportRoutes } from './routes/reports';
import { adRoutes } from './routes/ads';
import { billingRoutes } from './routes/billing';
import { paymentRoutes } from './routes/payments';
import { programRoutes } from './routes/programs';
import { ptRoutes } from './routes/pt';
import { trainerRoutes } from './routes/trainers';
import { Hono } from 'hono';
import { Deps, Env, loadSecrets } from './core';
import { HttpError } from './lib/http';
import { attendanceRoutes } from './routes/attendance';
import { authRoutes } from './routes/auth';
import { gymRoutes } from './routes/gym';
import { memberRoutes } from './routes/members';
import { meRoutes } from './routes/me';
import { ensureBaseData, superRoutes } from './routes/super';
import { ticketRoutes } from './routes/tickets';
import { transferRoutes } from './routes/transfers';
import { AlreadyExists } from './store/store';

const DIAG_KEY = 'gmdiag-5c81e2a7';

async function logDiag(deps: Deps, items: Record<string, unknown>[]) {
  try {
    const path = `diag/${new Date().toISOString().slice(0, 10)}`;
    await deps.store.tx(async (t) => {
      const d = (await t.get<{ items: unknown[] }>(path)) ?? { items: [] };
      t.set(path, { items: [...items, ...d.items].slice(0, 300) });
    });
  } catch {
    /* logging must never break a request */
  }
}

let lastDiagAt = 0;

/** Builds the GymMantra API. The same app runs on Cloudflare, in tests and in the local preview. */
export function createApp(getDeps: () => Deps) {
  const app = new Hono<Env>();

  app.onError((err, c) => {
    if (err instanceof HttpError) return c.json({ statusCode: err.status, message: err.message, ...err.extra }, err.status as any);
    if (err instanceof AlreadyExists) return c.json({ statusCode: 409, message: 'This already exists' }, 409);
    console.error(err);
    // Show the first part of the error so problems can be reported from a phone screenshot.
    const detail = String((err as any)?.message ?? err).slice(0, 200);
    return c.json({ statusCode: 500, message: `Something went wrong on the server. Please try again. (${detail})` }, 500);
  });

  app.use('/api/*', async (c, next) => {
    const t0 = Date.now();
    const deps = getDeps();
    c.set('deps', deps);
    const st = deps.store as unknown as { calls?: number; callMs?: number };
    const calls0 = st.calls ?? 0;
    const ms0 = st.callMs ?? 0;
    const tk0 = (st as { tokMs?: number }).tokMs ?? 0;
    const src0 = { ...tokenSrc };
    // Both are read once per Worker instance; do them together to save a round trip.
    const [secrets] = await Promise.all([loadSecrets(deps.store), ensureBaseData(deps.store)]);
    c.set('secrets', secrets);
    await next();
    // Phone notifications queued during this request go out after the answer.
    const pushes = takePush();
    if (pushes.length && deps.serviceAccount) {
      const job = sendPush(deps.store, deps.serviceAccount, pushes);
      try {
        c.executionCtx.waitUntil(job);
      } catch {
        await job;
      }
    }
    c.header('cache-control', 'no-store');
    const ms = Date.now() - t0;
    const tokMs = ((st as { tokMs?: number }).tokMs ?? 0) - tk0;
    const tsrc = `kv${tokenSrc.kvHits - src0.kvHits}/${tokenSrc.kvTries - src0.kvTries} sign${tokenSrc.signIns - src0.signIns}`;
    c.header('server-timing', `total;dur=${ms}, db;dur=${(st.callMs ?? 0) - ms0}, tok;dur=${tokMs};desc="${tsrc}"`);
    // Slow or failed requests go to a small log, so problems on real phones can be found.
    if ((ms > 1500 || c.res.status >= 500) && !c.req.path.startsWith('/api/v1/diag') && Date.now() - lastDiagAt > 5000) {
      lastDiagAt = Date.now(); // at most one log write per 5 s per instance (keeps busy times light)
      const entry = { at: new Date().toISOString(), src: 'server', m: c.req.method, p: c.req.path, s: c.res.status, ms, db: (st.calls ?? 0) - calls0, dbMs: (st.callMs ?? 0) - ms0, tokMs, tsrc, colo: String((c.req.raw as { cf?: { colo?: string } }).cf?.colo ?? '') };
      const w = logDiag(deps, [entry]);
      try {
        c.executionCtx.waitUntil(w);
      } catch {
        await w;
      }
    }
  });

  /** App and server timing reports (slow / failed requests). Read with the private key. */
  // The app calls this at start to open a connection early (no database work).
  app.get('/api/v1/ping', (c) => c.json({ ok: true }));

  app.post('/api/v1/diag', async (c) => {
    const b = await c.req.json().catch(() => null);
    const list = Array.isArray(b?.items) ? (b.items as unknown[]).slice(0, 30) : [];
    const clean = list
      .filter((x): x is Record<string, unknown> => !!x && typeof x === 'object')
      .map((x) => ({ at: new Date().toISOString(), src: 'app', m: String(x.m ?? '').slice(0, 8), p: String(x.p ?? '').slice(0, 120), s: Number(x.s ?? 0), ms: Number(x.ms ?? 0), e: String(x.e ?? '').slice(0, 160), v: String(b?.v ?? '').slice(0, 20), net: String(b?.net ?? '').slice(0, 120), n: Number(x.n ?? 1), colo: String((c.req.raw as { cf?: { colo?: string } }).cf?.colo ?? '') }));
    if (clean.length) await logDiag(c.var.deps, clean);
    return c.json({ ok: true });
  });
  app.get('/api/v1/diag', async (c) => {
    if (c.req.query('key') !== DIAG_KEY) return c.json({ statusCode: 404, message: 'Not found' }, 404);
    const day = c.req.query('day') ?? new Date().toISOString().slice(0, 10);
    const d = await c.var.deps.store.get<{ items: unknown[] }>(`diag/${day}`);
    return c.json(d?.items ?? []);
  });

  app.get('/api/v1/health', (c) => c.json({ ok: true, name: 'GymMantra API' }));

  /** The 40 pre-rendered 3D exercise guides (files live in the static assets). */
  app.get('/api/v1/exercises', async (c) => {
    const list: { n: number; id: string; name: string; muscle: string; video: string; still: string }[] = (await c.var.deps.assetJson('/media/exercises/exercises.json')) ?? [];
    c.header('cache-control', 'public, max-age=3600');
    return c.json(list.map((e) => ({ ...e, videoUrl: `/media/exercises/${e.video}`, stillUrl: `/media/exercises/${e.still}` })));
  });

  authRoutes(app);
  gymRoutes(app);
  memberRoutes(app);
  attendanceRoutes(app);
  ticketRoutes(app);
  meRoutes(app);
  superRoutes(app);
  trainerRoutes(app);
  ptRoutes(app);
  programRoutes(app);
  billingRoutes(app);
  paymentRoutes(app);
  adRoutes(app);
  reportRoutes(app);
  noticeRoutes(app);
  transferRoutes(app);
  checkinRoutes(app);
  dueRoutes(app);
  staffDayRoutes(app);
  ownershipRoutes(app);
  gateRoutes(app);

  app.all('/api/*', (c) => c.json({ statusCode: 404, message: 'Not found' }, 404));
  return app;
}
