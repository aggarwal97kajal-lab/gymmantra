// Local preview: runs the API with an in-memory database and fake Firebase,
// serves the built admin panel and media, and fills two demo gyms.
// Usage: pnpm --filter @gymmantra/worker build && pnpm --filter @gymmantra/worker dev
import { serve } from '@hono/node-server';
import { serveStatic } from '@hono/node-server/serve-static';
import { readFileSync } from 'fs';
import { Hono } from 'hono';
import { join, relative } from 'path';
import { createApp } from '../src/app';
import { Deps } from '../src/core';
import { FakeIdentity } from '../src/identity';
import { addDays, todayIST } from '../src/lib/dates';
import { MemoryStore } from '../src/store/store';

const PORT = Number(process.env.PORT || 8787);
const pub = join(__dirname, '..', 'public');
const deps: Deps = {
  store: new MemoryStore(),
  identity: new FakeIdentity(),
  superAdminEmail: 'owner@lifetimefitness.demo',
  googleClientId: null,
  secure: false,
  assetJson: async (p) => JSON.parse(readFileSync(join(pub, p), 'utf8')),
};
const api = createApp(() => deps);
const app = new Hono();
app.route('/', api);
app.use('/*', serveStatic({ root: relative(process.cwd(), pub), rewriteRequestPath: (p) => (p.endsWith('/') ? `${p}index.html` : p) }));
app.get('/*', (c) => c.redirect(`${c.req.path}/`));

async function call(method: string, path: string, body?: unknown, token?: string) {
  const res = await api.request(`/api/v1${path}`, { method, headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const data: any = await res.json();
  if (!res.ok) throw new Error(`${path}: ${data.message}`);
  return data;
}

const FIRST = ['Rahul', 'Priya', 'Amit', 'Neha', 'Vikram', 'Anjali', 'Rohit', 'Sneha', 'Karan', 'Pooja', 'Arjun', 'Kavya', 'Saurabh', 'Isha', 'Manish', 'Ritika', 'Deepak', 'Simran', 'Nikhil', 'Tanya'];
const LAST = ['Sharma', 'Verma', 'Gupta', 'Singh', 'Yadav', 'Malhotra', 'Chauhan', 'Arora', 'Bansal', 'Mehta'];

async function seedGym(name: string, email: string, phone: string, deskPhone: string, offset: number) {
  const o = await call('POST', '/auth/signup', { name: `${name.split(' ')[0]} Owner`, email, phone, password: 'Demo@12345' });
  await call('POST', '/gyms', { name, branchName: 'Dwarka Sector 7', address: 'Sector 7, Dwarka, New Delhi', phone }, o.token);
  await call('POST', '/gym/staff', { name: `${name.split(' ')[0]} Front Desk`, phone: deskPhone, role: 'FRONT_DESK', tempPassword: 'Demo@12345' }, o.token);
  const plans = [];
  for (const p of [
    { name: 'Monthly', months: 1, price: 1500, joiningFee: 500, freezeDays: 0, features: ['Gym floor', 'Locker'] },
    { name: 'Quarterly', months: 3, price: 4000, joiningFee: 500, freezeDays: 10, features: ['Gym floor', 'Locker', 'Diet chart'] },
    { name: 'Half-yearly', months: 6, price: 7000, joiningFee: 0, freezeDays: 20, features: ['Gym floor', 'Locker', 'Diet chart'] },
    { name: 'Annual', months: 12, price: 12000, joiningFee: 0, freezeDays: 30, features: ['Gym floor', 'Locker', 'Diet chart', '4 PT sessions'] },
  ])
    plans.push(await call('POST', '/plans', p, o.token));
  const today = todayIST();
  for (let i = 0; i < 30; i++) {
    const m = await call('POST', '/members', { name: `${FIRST[(i + offset) % 20]} ${LAST[(i * 3 + offset) % 10]}`, phone: `9${String(810000000 + offset * 1000 + i)}`, joinedOn: addDays(today, -200 + i) }, o.token);
    if (i % 10 === 9) continue;
    const plan = plans[i % 4];
    const start = addDays(today, [-10, -25, -80, -170, -5, -88, -29, -3, -360][i % 9]);
    await call('POST', `/members/${m.id}/memberships`, { planId: plan.id, startDate: start, discount: i % 4 === 0 ? 200 : 0, paymentMode: i % 7 === 0 ? 'NOT_PAID' : (['CASH', 'UPI', 'CARD', 'UPI'] as const)[i % 4], allowEntryWhileDue: i % 14 === 0 }, o.token);
  }
}

(async () => {
  await seedGym('Lifetime Fitness', 'owner@lifetimefitness.demo', '9810000001', '9810000011', 0);
  await seedGym('Athlete Gym', 'owner@athletegym.demo', '9810000002', '9810000012', 7);
  serve({ fetch: app.fetch, port: PORT });
  console.log(`GymMantra preview on http://localhost:${PORT}  (owner@lifetimefitness.demo / Demo@12345)`);
})();
