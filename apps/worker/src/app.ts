import { checkinRoutes } from './routes/checkin';
import { dueRoutes } from './routes/dues';
import { noticeRoutes } from './routes/notices';
import { reportRoutes } from './routes/reports';
import { adRoutes } from './routes/ads';
import { billingRoutes } from './routes/billing';
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
    const deps = getDeps();
    c.set('deps', deps);
    c.set('secrets', await loadSecrets(deps.store));
    await ensureBaseData(deps.store);
    await next();
    c.header('cache-control', 'no-store');
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
  adRoutes(app);
  reportRoutes(app);
  noticeRoutes(app);
  transferRoutes(app);
  checkinRoutes(app);
  dueRoutes(app);

  app.all('/api/*', (c) => c.json({ statusCode: 404, message: 'Not found' }, 404));
  return app;
}
