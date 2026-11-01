// Copies the built admin panel and the exercise media into public/ for Cloudflare.
import { cpSync, existsSync, rmSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..', '..');
const out = join(here, '..', 'public');
const admin = join(root, 'apps', 'admin', 'out');
if (!existsSync(join(admin, 'index.html'))) throw new Error('Build the admin panel first (pnpm --filter @gymmantra/admin build)');
rmSync(out, { recursive: true, force: true });
cpSync(admin, out, { recursive: true });
cpSync(join(root, 'media', 'exercises'), join(out, 'media', 'exercises'), { recursive: true });
console.log('Static assets ready in', out);
