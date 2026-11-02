import { App, authenticate, C, MemberDoc, notify, P, TenantDoc, UserDoc } from '../core';
import { bad, forbidden, notFound, nowIso, uuid } from '../lib/http';
import type { Reader } from '../store/store';
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
export interface PdfMeta {
  id: string;
  name: string;
  size: number; // bytes
  parts: number;
  uploadedAt: string;
  uploadedBy: string;
}
export interface ProgramDoc {
  memberId: string;
  dietPdf?: PdfMeta | null;
  workoutPdf?: PdfMeta | null;
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

const PDF_MAX_BYTES = 2 * 1024 * 1024;
const PART_CHARS = 700_000; // base64 characters per Firestore document (documents are limited to 1 MiB)
// The app sends and reads PDFs in small pieces. One big 2 MB request is too much work for a
// single Worker request on the free plan (10 ms CPU), which is why a 1.7 MB PDF failed.
const UP_PART_CHARS = 350_000;
const MAX_UP_PARTS = Math.ceil((PDF_MAX_BYTES * 4) / 3 / UP_PART_CHARS) + 1;
const PDF_KINDS = ['diet', 'workout'] as const;
type PdfKind = (typeof PDF_KINDS)[number];
const pdfKey = (k: PdfKind) => (k === 'diet' ? 'dietPdf' : 'workoutPdf') as 'dietPdf' | 'workoutPdf';
function kindOf(v: string): PdfKind {
  if (!(PDF_KINDS as readonly string[]).includes(v)) throw notFound('Unknown plan type');
  return v as PdfKind;
}

/** "?part=n" gives one piece, "?meta=1" the list of pieces, nothing the whole file (older apps). */
async function readPdfFor(c: C, r: Reader, tenantId: string, meta: PdfMeta | null | undefined) {
  if (!meta) throw notFound('No PDF uploaded yet');
  const q = c.req.query('part');
  if (c.req.query('meta')) return { id: meta.id, name: meta.name, size: meta.size, uploadedAt: meta.uploadedAt, parts: meta.parts };
  if (q !== undefined) {
    const n = Number(q);
    if (!Number.isInteger(n) || n < 0 || n >= meta.parts) throw notFound('No such piece');
    const part = await r.get<{ data: string }>(P.filePart(tenantId, meta.id, n));
    if (!part) throw notFound('This PDF could not be read. Ask the trainer to upload it again');
    return { n, data: part.data };
  }
  return readPdf(r, tenantId, meta);
}

async function readPdf(r: Reader, tenantId: string, meta: PdfMeta | null | undefined) {
  if (!meta) throw notFound('No PDF uploaded yet');
  const parts = await r.getMany<{ data: string }>(Array.from({ length: meta.parts }, (_, i) => P.filePart(tenantId, meta.id, i)));
  if (parts.some((x) => !x)) throw notFound('This PDF could not be read. Ask the trainer to upload it again');
  return { name: meta.name, size: meta.size, uploadedAt: meta.uploadedAt, base64: parts.map((x) => x!.data).join('') };
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
    const { store } = c.var.deps;
    const [, gymDoc] = await Promise.all([canWrite(c, tenantId, memberId), store.get<TenantDoc>(P.tenant(tenantId))]);
    if (gymDoc) await requireFeature(store, gymDoc, 'pt');
    const out = await store.tx(async (t) => {
      const [m, prog] = await t.getMany<MemberDoc | ProgramDoc>([P.member(tenantId, memberId), P.program(tenantId, memberId)]) as [MemberDoc | null, ProgramDoc | null];
      if (!m) throw notFound('Member not found');
      const cur = prog ?? { memberId, diet: null, workout: null };
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

  // ---- PDF diet chart / workout (member reads it inside the app only) ----
  /** One piece of a PDF being uploaded (base64 text). Pieces are saved as they come. */
  app.put('/api/v1/programs/:memberId/pdf/:kind/parts/:n', async (c) => {
    await authenticate(c);
    kindOf(c.req.param('kind'));
    const n = Number(c.req.param('n'));
    if (!Number.isInteger(n) || n < 0 || n >= MAX_UP_PARTS) throw bad('PDF is too big. Upload a PDF up to 2 MB');
    const b = body(await c.req.json().catch(() => null));
    const tenantId = str(b, 'tenantId', { label: 'the gym' });
    const uploadId = str(b, 'uploadId', { max: 40 });
    if (!/^[0-9a-f-]{36}$/i.test(uploadId)) throw bad('Upload failed. Try again');
    const data = typeof b.data === 'string' ? b.data : '';
    if (!data || data.length > UP_PART_CHARS) throw bad('Upload failed. Try again');
    if (n === 0 && !data.startsWith('JVBER')) throw bad('Only PDF files can be uploaded');
    await canWrite(c, tenantId, c.req.param('memberId'));
    await c.var.deps.store.set(P.filePart(tenantId, uploadId, n), { data });
    return c.json({ ok: true, n });
  });

  app.put('/api/v1/programs/:memberId/pdf/:kind', async (c) => {
    const u = await authenticate(c);
    const kind = kindOf(c.req.param('kind'));
    const b = body(await c.req.json().catch(() => null));
    const tenantId = str(b, 'tenantId', { label: 'the gym' });
    const memberId = c.req.param('memberId');
    await canWrite(c, tenantId, memberId);
    const name = (str(b, 'name', { max: 120, label: 'the file name' }).replace(/[\\/]/g, '_') || 'plan.pdf').slice(0, 120);
    const { store } = c.var.deps;
    const gymDoc = await store.get<TenantDoc>(P.tenant(tenantId));
    if (gymDoc) await requireFeature(store, gymDoc, 'pt');
    let meta: PdfMeta;
    let b64 = '';
    if (typeof b.uploadId === 'string') {
      // Pieces were sent first (PUT .../parts/:n); this only links them to the member.
      const uploadId = b.uploadId;
      if (!/^[0-9a-f-]{36}$/i.test(uploadId)) throw bad('Upload failed. Try again');
      const parts = Number(b.parts);
      const size = Number(b.size);
      if (!Number.isInteger(parts) || parts < 1 || parts > MAX_UP_PARTS) throw bad('Upload failed. Try again');
      if (!Number.isFinite(size) || size <= 0 || size > PDF_MAX_BYTES) throw bad('PDF is too big. Upload a PDF up to 2 MB');
      meta = { id: uploadId, name, size, parts, uploadedAt: nowIso(), uploadedBy: u.name };
    } else {
      // Older app versions send the whole file at once.
      b64 = str(b, 'base64', { max: Math.ceil((PDF_MAX_BYTES * 4) / 3) + 8, label: 'the PDF' }).replace(/\s/g, '');
      if (!b64.startsWith('JVBER')) throw bad('Only PDF files can be uploaded');
      const size = Math.floor((b64.length * 3) / 4) - (b64.endsWith('==') ? 2 : b64.endsWith('=') ? 1 : 0);
      if (size > PDF_MAX_BYTES) throw bad('PDF is too big. Upload a PDF up to 2 MB');
      meta = { id: uuid(), name, size, parts: Math.ceil(b64.length / PART_CHARS), uploadedAt: nowIso(), uploadedBy: u.name };
    }
    const out = await store.tx(async (t) => {
      const [m, prog] = await t.getMany<MemberDoc | ProgramDoc>([P.member(tenantId, memberId), P.program(tenantId, memberId)]) as [MemberDoc | null, ProgramDoc | null];
      if (!m) throw notFound('Member not found');
      const cur = prog ?? { memberId, diet: null, workout: null };
      const old = cur[pdfKey(kind)];
      if (old) {
        for (let i = 0; i < old.parts; i++) t.delete(P.filePart(tenantId, old.id, i));
        t.delete(P.file(tenantId, old.id));
      }
      if (b64) for (let i = 0; i < meta.parts; i++) t.set(P.filePart(tenantId, meta.id, i), { data: b64.slice(i * PART_CHARS, (i + 1) * PART_CHARS) });
      t.set(P.file(tenantId, meta.id), { ...meta, memberId, kind });
      const next = { ...cur, [pdfKey(kind)]: meta };
      t.set(P.program(tenantId, memberId), JSON.parse(JSON.stringify(next)));
      await notify(t, m.userId, tenantId, kind === 'diet' ? 'New diet chart' : 'New workout plan', `${u.name} sent you a ${kind === 'diet' ? 'diet chart' : 'workout plan'} (PDF). Open My plan to read it.`);
      return next;
    });
    return c.json(out);
  });

  app.delete('/api/v1/programs/:memberId/pdf/:kind', async (c) => {
    await authenticate(c);
    const kind = kindOf(c.req.param('kind'));
    const tenantId = c.req.query('tenantId') ?? '';
    const memberId = c.req.param('memberId');
    await canWrite(c, tenantId, memberId);
    const out = await c.var.deps.store.tx(async (t) => {
      const cur = await t.get<ProgramDoc>(P.program(tenantId, memberId));
      const old = cur?.[pdfKey(kind)];
      if (!cur || !old) throw notFound('No PDF uploaded');
      for (let i = 0; i < old.parts; i++) t.delete(P.filePart(tenantId, old.id, i));
      t.delete(P.file(tenantId, old.id));
      const next = { ...cur, [pdfKey(kind)]: null };
      t.set(P.program(tenantId, memberId), next);
      return next;
    });
    return c.json(out);
  });

  app.get('/api/v1/programs/:memberId/pdf/:kind', async (c) => {
    await authenticate(c);
    const kind = kindOf(c.req.param('kind'));
    const tenantId = c.req.query('tenantId') ?? '';
    const memberId = c.req.param('memberId');
    await canWrite(c, tenantId, memberId);
    const { store } = c.var.deps;
    const p = await store.get<ProgramDoc>(P.program(tenantId, memberId));
    return c.json(await readPdfFor(c, store, tenantId, p?.[pdfKey(kind)]));
  });

  /** Member reads their own PDF (the app shows it with their name on it; no download). */
  app.get('/api/v1/me/program/:tenantId/pdf/:kind', async (c) => {
    const u = await authenticate(c);
    const kind = kindOf(c.req.param('kind'));
    const tenantId = c.req.param('tenantId');
    const memberId = u.memberships?.[tenantId];
    if (!memberId) throw forbidden('Not your gym');
    const { store } = c.var.deps;
    const p = await store.get<ProgramDoc>(P.program(tenantId, memberId));
    return c.json(await readPdfFor(c, store, tenantId, p?.[pdfKey(kind)]));
  });

  /** Member: their plans from every gym. */
  app.get('/api/v1/me/program', async (c) => {
    const u = await authenticate(c);
    const { store } = c.var.deps;
    const entries = Object.entries(u.memberships ?? {});
    const [docs, tenants] = await Promise.all([store.getMany<ProgramDoc>(entries.map(([t, m]) => P.program(t, m))), store.getMany<TenantDoc>(entries.map(([t]) => P.tenant(t)))]);
    return c.json(
      entries
        .map(([tid, mid], i) => ({
          gym: { id: tid, name: tenants[i]?.name ?? '' },
          memberId: mid,
          diet: docs[i]?.diet ?? null,
          workout: docs[i]?.workout ?? null,
          dietPdf: docs[i]?.dietPdf ?? null,
          workoutPdf: docs[i]?.workoutPdf ?? null,
        }))
        .filter((x) => x.diet || x.workout || x.dietPdf || x.workoutPdf),
    );
  });
}

export type { UserDoc };
