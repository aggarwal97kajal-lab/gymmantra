import { App, audit, authenticate, gymOf, P, TenantDoc, UserDoc } from '../core';
import { bad, forbidden, isUuid, notFound, nowIso } from '../lib/http';
import { body, oneOf, optStr, str } from '../lib/validate';

const MAX_LOGO_BYTES = 300 * 1024;

function toBytes(b64: string) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Checks an uploaded logo (JPEG/PNG, ≤ 300 KB). */
export function readLogo(b: Record<string, unknown>) {
  const mime = oneOf(b, 'mime', ['image/jpeg', 'image/png'] as const)!;
  const b64 = str(b, 'base64', { max: 420_000 });
  let bytes: Uint8Array;
  try {
    bytes = toBytes(b64);
  } catch {
    throw bad('This file is not a JPEG or PNG image');
  }
  if (!bytes.length || bytes.length > MAX_LOGO_BYTES) throw bad('Logo must be smaller than 300 KB');
  const isJpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const isPng = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  if ((mime === 'image/jpeg' && !isJpeg) || (mime === 'image/png' && !isPng)) throw bad('This file is not a JPEG or PNG image');
  return { mime, b64 };
}

export const logoUrlFor = (tenantId: string, key: string) => `/api/v1/logos/${tenantId}/${key}?v=${Date.now()}`;

/** Is this person linked to the gym (member, staff, trainer, asked to join)? */
function linked(u: UserDoc, tenantId: string) {
  return !!(
    u.isSuperAdmin ||
    u.memberships?.[tenantId] ||
    u.requested?.[tenantId] ||
    (u as { trainerRequested?: Record<string, unknown> }).trainerRequested?.[tenantId] ||
    u.staffOf?.[tenantId]
  );
}

/**
 * Gym and branch logos. The owner uploads one for the gym and, if they like, one per branch.
 * A branch without its own logo shows the gym's (gymFace().logoUrl).
 */
export function logoRoutes(app: App) {
  app.put('/api/v1/gym/logo', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const b = body(await c.req.json().catch(() => null));
    const { mime, b64 } = readLogo(b);
    const branchId = optStr(b, 'branchId', { max: 60 }) ?? null;
    const key = branchId ?? 'gym';
    const url = logoUrlFor(g.tenantId, key);
    await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<TenantDoc>(P.tenant(g.tenantId)))!;
      if (branchId && !cur.branches.some((x) => x.id === branchId)) throw notFound('Branch not found');
      t.set(P.logo(g.tenantId, key), { mime, b64, at: nowIso() });
      const next: TenantDoc = branchId ? { ...cur, branches: cur.branches.map((x) => (x.id === branchId ? { ...x, logoUrl: url } : x)) } : { ...cur, logoUrl: url };
      t.set(P.tenant(g.tenantId), next);
      audit(t, g.tenantId, u.id, 'logo.set', branchId ? 'branch' : 'tenant', branchId ?? g.tenantId, null, { logoUrl: url });
    });
    return c.json({ logoUrl: url }, 201);
  });

  app.delete('/api/v1/gym/logo', async (c) => {
    const u = await authenticate(c);
    const g = await gymOf(c, 'OWNER');
    const branchId = c.req.query('branchId') || null;
    const key = branchId ?? 'gym';
    await c.var.deps.store.tx(async (t) => {
      const cur = (await t.get<TenantDoc>(P.tenant(g.tenantId)))!;
      if (branchId && !cur.branches.some((x) => x.id === branchId)) throw notFound('Branch not found');
      t.delete(P.logo(g.tenantId, key));
      const next: TenantDoc = branchId ? { ...cur, branches: cur.branches.map((x) => (x.id === branchId ? { ...x, logoUrl: null } : x)) } : { ...cur, logoUrl: null };
      t.set(P.tenant(g.tenantId), next);
      audit(t, g.tenantId, u.id, 'logo.remove', branchId ? 'branch' : 'tenant', branchId ?? g.tenantId, null, null);
    });
    return c.json({ ok: true });
  });

  /** Only people linked to the gym (and the super admin) can load its logos. */
  app.get('/api/v1/logos/:tenantId/:key', async (c) => {
    const u = await authenticate(c);
    const tid = c.req.param('tenantId');
    const key = c.req.param('key');
    if (!isUuid(tid) || (key !== 'gym' && !isUuid(key))) throw notFound('No logo');
    if (!linked(u, tid)) throw forbidden('Not allowed');
    const img = await c.var.deps.store.get<{ mime: string; b64: string }>(P.logo(tid, key));
    if (!img) throw notFound('No logo');
    return new Response(toBytes(img.b64), { headers: { 'content-type': img.mime, 'cache-control': 'private, max-age=604800' } });
  });
}
