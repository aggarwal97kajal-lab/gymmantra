import { App, C } from '../core';
import { bad, HttpError, unauthorized } from '../lib/http';
import type { Doc } from '../store/store';

// Nightly backup to GitHub (.github/workflows/backup.yml) and restore (restore.yml).
// Only those two GitHub workflows of this repo can call these routes: they log in with
// GitHub's own signed token (OIDC), so there is no password to keep anywhere.
// Pages are encrypted here (AES-GCM, key from SERVER_PASSWORD), so the files on GitHub
// cannot be read without the server's password.

const PAGE = 200;

function b64(bytes: Uint8Array) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
function unb64(s: string) {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function backupRoutes(app: App) {
  async function caller(c: C, workflow: 'backup' | 'restore') {
    const b = c.var.deps.backup;
    if (!b) throw new HttpError(503, 'Backup is not set up on this server');
    const tok = (c.req.header('authorization') ?? '').replace(/^Bearer\s+/i, '');
    if (!tok || !(await b.verify(tok, workflow).catch(() => false))) throw unauthorized();
    return b;
  }

  /** One page of the whole database, encrypted. `next` is the cursor for the next page (null = done). */
  app.post('/api/v1/backup/page', async (c) => {
    const b = await caller(c, 'backup');
    const body = await c.req.json().catch(() => ({}));
    const after = typeof body?.after === 'string' && body.after ? body.after : null;
    const rows = await c.var.deps.store.dump(after, PAGE);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await b.key(), new TextEncoder().encode(JSON.stringify(rows))));
    const out = new Uint8Array(12 + ct.length);
    out.set(iv);
    out.set(ct, 12);
    return c.json({ n: rows.length, data: b64(out), next: rows.length === PAGE ? rows[rows.length - 1].p : null });
  });

  /** Writes one backup page back into the database (documents in it are overwritten). */
  app.post('/api/v1/backup/restore', async (c) => {
    const b = await caller(c, 'restore');
    const body = await c.req.json().catch(() => ({}));
    if (typeof body?.data !== 'string') throw bad('data is missing');
    let rows: { p: string; d: Doc }[];
    try {
      const raw = unb64(body.data);
      const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: raw.subarray(0, 12) }, await b.key(), raw.subarray(12));
      rows = JSON.parse(new TextDecoder().decode(plain));
    } catch {
      throw bad('This backup cannot be opened with this server’s password');
    }
    if (!Array.isArray(rows) || rows.some((r) => typeof r?.p !== 'string' || !r.p || typeof r.d !== 'object' || r.d === null)) throw bad('This backup page is damaged');
    await c.var.deps.store.load(rows);
    return c.json({ ok: true, n: rows.length });
  });
}
