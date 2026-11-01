import { execSync } from 'child_process';

export default async function () {
  const url = process.env.TEST_DATABASE_URL || process.env.DATABASE_URL;
  if (!url) throw new Error('Set TEST_DATABASE_URL (or DATABASE_URL) to a Postgres database for tests');
  process.env.DATABASE_URL = url;
  execSync('npx prisma migrate reset --force --skip-seed --skip-generate', { stdio: 'inherit', env: { ...process.env, DATABASE_URL: url } });
}
