import { App, authenticate, C, MemberDoc, notify, P, TenantDoc, UserDoc } from '../core';
import { bad, forbidden, notFound, nowIso } from '../lib/http';
import { body, str } from '../lib/validate';
import type { PtDoc } from './pt';
import { ptState } from './pt';
import { requireFeature } from './billing';

// ---------- Diet chart and workout plan a trainer makes for a PT client ----------

export interface Meal {
  name: string;
  time: string | null;
  items: string;
}
export interface Exercise {
  name: string;
  sets: string | null;
  weight: string | null;
}
export interface WorkoutDay {
  day: string;
  title: string | null;
  exercises: Exercise[];
}
export interface ProgramDoc {
  memberId: string;
  diet: { kcal: number | null; protein: number | null; meals: Meal[]; notes: string | null; updatedAt: string; updatedBy: string } | null;
  workout: { days: WorkoutDay[]; notes: string | null; updatedAt: string; updatedBy: string } | null;
}

const s = (v: unknown, max: number) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, max) : null);
const n = (v: unknown, max: number) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= max ? Math.round(v) : null);

function readDiet(v: unknown, by: string) {
  if (v === null) return null;
  if (!v || typeof v !== 'object') throw bad('Diet chart is not valid');
  const d = v as Record<string, unknown>;
  const meals = Array.isArray(d.meals) ? d.meals : [];
  if (meals.length > 12) throw bad('Up to 12 meals');
  return {
    kcal: n(d.kcal, 10000),
    protein: n(d.protein, 1000),
    notes: s(d.notes, 500),
    meals: meals
      .map((m) => {
        const x = (m ?? {}) as Record<string, unknown>;
        return { name: s(x.name, 40) ?? 'Meal', time: s(x.time, 20), items: s(x.items, 400) ?? '' };
      })
      .filter((m) => m.items),
    updatedAt: nowIso(),
    updatedBy: by,
  };
}

function readWorkout(v: unknown, by: string) {
  if (v === null) return null;
  if (!v || typeof v !== 'object') throw bad('Workout plan is not valid');
  const d = v as Record<string, unknown>;
  const days = Array.isArray(d.days) ? d.days : [];
  if (days.length > 7) throw bad('Up to 7 days');
  return {
    notes: s(d.notes, 500),
    days: days.map((x) => {
      const day = (x ?? {}) as Record<string, unknown>;
      const ex = Array.isArray(day.exercises) ? day.exercises : [];
      if (ex.length > 20) throw bad('Up to 20 exercises a day');
      return {
        day: s(day.day, 12) ?? 'Day',
        title: s(day.title, 40),
        exercises: ex
          .map((e) => {
            const y = (e ?? {}) as Record<string, unknown>;
            return { name: s(y.name, 60) ?? '', sets: s(y.sets, 30), weight: s(y.weight, 20) };
          })
          .filter((e) => e.name),
      };
    }),
    updatedAt: nowIso(),
    updatedBy: by,
  };
}

/** The trainer of an active PT with this member, or the gym owner, may write the plan. */
async function canWrite(c: C, tenantId: string, memberId: string) {
  const u = c.var.user;
  const role = u.staffOf?.[tenantId];
  if (!role?.active) throw forbidden('Not allowed');
  if (role.role === 'OWNER') return;
  if (role.role !== 'TRAINER') throw forbidden('Only the trainer or the owner can change the plan');
  const pts = (await c.var.deps.store.query<PtDoc>(P.pts(tenantId), [['memberId', memberId]])).map((r) => r.data);
  if (!pts.some((p) => p.trainerId === u.id && p.status === 'ACTIVE' && ptState(p).state !== 'EXPIRED')) throw forbidden('This member is not your PT client');
}

export function programRoutes(app: App) {
  app.get('/api/v1/programs/:memberId', async (c) => {
    await authenticate(c);
    const tenantId = c.req.query('tenantId') ?? '';
    const memberId = c.req.param('memberId');
    await canWrite(c, tenantId, memberId);
    const p = await c.var.deps.store.get<ProgramDoc>(P.program(tenantId, memberId));
    return c.json(p ?? { memberId, diet: null, workout: null });
  });

  app.put('/api/v1/programs/:memberId', async (c) => {
    const u = await authenticate(c);
    const b = body(await c.req.json().catch(() => null));
    const tenantId = str(b, 'tenantId', { label: 'the gym' });
    const memberId = c.req.param('memberId');
    await canWrite(c, tenantId, memberId);
    const { store } = c.var.deps;
    const gymDoc = await store.get<TenantDoc>(P.tenant(tenantId));
    if (gymDoc) await requireFeature(store, gymDoc, 'pt');
    const out = await store.tx(async (t) => {
      const m = await t.get<MemberDoc>(P.member(tenantId, memberId));
      if (!m) throw notFound('Member not found');
      const cur = (await t.get<ProgramDoc>(P.program(tenantId, memberId))) ?? { memberId, diet: null, workout: null };
      const next: ProgramDoc = {
        ...cur,
        diet: b.diet !== undefined ? readDiet(b.diet, u.name) : cur.diet,
        workout: b.workout !== undefined ? readWorkout(b.workout, u.name) : cur.workout,
      };
      t.set(P.program(tenantId, memberId), JSON.parse(JSON.stringify(next)));
      const what = b.diet !== undefined && b.workout !== undefined ? 'diet chart and workout plan' : b.diet !== undefined ? 'diet chart' : 'workout plan';
      await notify(t, m.userId, tenantId, 'Your plan is updated', `${u.name} updated your ${what}.`);
      return next;
    });
    return c.json(out);
  });

  /** Member: their plans from every gym. */
  app.get('/api/v1/me/program', async (c) => {
    const u = await authenticate(c);
    const { store } = c.var.deps;
    const entries = Object.entries(u.memberships ?? {});
    const [docs, tenants] = await Promise.all([store.getMany<ProgramDoc>(entries.map(([t, m]) => P.program(t, m))), store.getMany<TenantDoc>(entries.map(([t]) => P.tenant(t)))]);
    return c.json(
      entries
        .map(([tid, mid], i) => ({ gym: { id: tid, name: tenants[i]?.name ?? '' }, memberId: mid, diet: docs[i]?.diet ?? null, workout: docs[i]?.workout ?? null }))
        .filter((x) => x.diet || x.workout),
    );
  });
}

export type { UserDoc };
