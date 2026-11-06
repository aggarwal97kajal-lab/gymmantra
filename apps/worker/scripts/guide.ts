// Demo gym for the user guide's screenshots (not used by the live app).
// Fills "Lifetime Fitness" (two branches) with members, a trainer with PT clients, front desk staff,
// offers, notices, ratings, lockers, salary and enquiries, then serves the API on PORT and writes
// the logins of the owner, front desk, trainer and member to GUIDE_OUT (JSON).
// Usage: GUIDE_OUT=/tmp/guide-logins.json PORT=8787 npx tsx scripts/guide.ts
import { serve } from '@hono/node-server';
import { readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
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
  superAdminEmail: 'admin@gymmantra.demo',
  googleClientId: null,
  secure: false,
  assetJson: async (p) => JSON.parse(readFileSync(join(pub, p), 'utf8')),
};
const app = createApp(() => deps);

async function call(method: string, path: string, body?: unknown, token?: string, headers: Record<string, string> = {}) {
  const res = await app.request(`/api/v1${path}`, {
    method,
    headers: { 'content-type': 'application/json', 'x-gm-client': 'mobile', 'cf-connecting-ip': `10.0.${Math.floor(Math.random() * 250)}.${Math.floor(Math.random() * 250)}`, ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data: any = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${data.message}`);
  return data;
}

const FIRST = ['Rahul', 'Priya', 'Amit', 'Neha', 'Vikram', 'Anjali', 'Rohit', 'Sneha', 'Karan', 'Pooja', 'Arjun', 'Kavya', 'Saurabh', 'Isha', 'Manish', 'Ritika', 'Deepak', 'Simran', 'Nikhil', 'Tanya'];
const LAST = ['Sharma', 'Verma', 'Gupta', 'Singh', 'Yadav', 'Malhotra', 'Chauhan', 'Arora', 'Bansal', 'Mehta'];
const ADDRESS = { addressLine: 'Plot 12, Sector 7, Dwarka', state: 'Delhi', city: 'New Delhi', pincode: '110075' };
const PW = 'Demo@12345';
let n = 0;
const phone = () => `98${String(10000000 + n++).padStart(8, '0')}`;

async function person(name: string, appRole: string) {
  const p = phone();
  const [first, ...rest] = name.split(' ');
  const r = await call('POST', '/auth/signup', { name, email: `${first.toLowerCase()}${n}@demo.in`, phone: p, password: PW, appRole, firstName: first, lastName: rest.join(' '), dob: '1995-05-10', gender: 'male', ...ADDRESS, country: 'India', agree: true });
  await call('PATCH', '/me/profile', { appRole }, r.token).catch(() => {});
  return { token: r.token as string, id: r.user.id as string, phone: p };
}

(async () => {
  const today = todayIST();
  // ---- owner and gym ----
  const owner = await person('Rakesh Kumar', 'OWNER');
  const gym = await call('POST', '/gyms', { name: 'Lifetime Fitness', phone: owner.phone, ...ADDRESS }, owner.token);
  const branch2 = await call('POST', '/gym/branches', { name: 'Boring Road', addressLine: 'Shop 4, Boring Road', state: 'Delhi', city: 'New Delhi', pincode: '110001' }, owner.token);
  const plans: any[] = [];
  for (const p of [
    { name: 'Monthly', months: 1, price: 1500, joiningFee: 500, freezeDays: 0, features: ['Gym floor', 'Locker'] },
    { name: 'Quarterly', months: 3, price: 4000, joiningFee: 500, freezeDays: 10, features: ['Gym floor', 'Locker', 'Diet chart'] },
    { name: 'Half-yearly', months: 6, price: 7000, joiningFee: 0, freezeDays: 20, features: ['Gym floor', 'Locker', 'Diet chart'] },
    { name: 'Annual', months: 12, price: 12000, joiningFee: 0, freezeDays: 30, features: ['Gym floor', 'Locker', 'Diet chart', '4 PT sessions'] },
  ])
    plans.push(await call('POST', '/plans', p, owner.token));

  // ---- members added by the gym ----
  const memberIds: string[] = [];
  for (let i = 0; i < 22; i++) {
    const m = await call('POST', '/members', { name: `${FIRST[i % 20]} ${LAST[(i * 3) % 10]}`, phone: phone(), joinedOn: addDays(today, -200 + i * 7) }, owner.token);
    memberIds.push(m.id);
    if (i % 11 === 10) continue;
    const plan = plans[i % 4];
    const start = addDays(today, [-10, -25, -80, -170, -5, -88, -29, -3, -360, -27][i % 10]);
    await call('POST', `/members/${m.id}/memberships`, { planId: plan.id, startDate: start, discount: i % 4 === 0 ? 200 : 0, paymentMode: i % 6 === 0 ? 'NOT_PAID' : (['CASH', 'UPI', 'CARD', 'UPI'] as const)[i % 4], allowEntryWhileDue: i % 12 === 0 }, owner.token);
  }
  for (const id of memberIds.slice(0, 9)) await call('POST', '/attendance/manual', { memberId: id }, owner.token).catch(() => {});

  // ---- the member who uses the app ----
  const member = await person('Suraj Thakur', 'MEMBER');
  await call('POST', '/me/join', { gymCode: gym.gymCode }, member.token);
  let jr = (await call('GET', '/join-requests', undefined, owner.token))[0];
  const mem = await call('POST', `/join-requests/${jr.id}/approve`, {}, owner.token);
  await call('POST', `/members/${mem.id}/memberships`, { planId: plans[1].id, startDate: addDays(today, -40), paymentMode: 'UPI' }, owner.token);
  await call('POST', '/attendance/manual', { memberId: mem.id }, owner.token);

  // ---- trainer with PT packages ----
  const trainer = await person('Rajeev Talwar', 'TRAINER');
  await call('POST', '/me/join', { gymCode: gym.gymCode, as: 'TRAINER', speciality: 'Strength, Weight loss', experienceYears: 6 }, trainer.token);
  jr = (await call('GET', '/join-requests', undefined, owner.token)).find((x: any) => x.kind === 'TRAINER');
  await call('POST', `/join-requests/${jr.id}/approve`, {}, owner.token);
  const pk = await call('PATCH', `/trainers/${trainer.id}`, { packages: [{ sessions: 12, days: 30, perWeek: 3, price: 6000 }, { sessions: 24, days: 60, perWeek: 3, price: 11000 }], sharePercent: 50 }, owner.token);
  const pt = await call('POST', '/me/pt', { tenantId: gym.id, trainerId: trainer.id, packageId: pk.packages[0].id }, member.token);
  await call('POST', `/pt/${pt.id}/approve`, { amountReceived: 6000, paymentMode: 'UPI', startDate: addDays(today, -6) }, owner.token);
  for (const [d, m] of [[-2, 'DONE'], [-1, 'DONE'], [0, 'DONE'], [2, 'PLANNED'], [4, 'PLANNED']] as const) await call('POST', `/pt/${pt.id}/session`, { tenantId: gym.id, date: addDays(today, d), mark: m }, trainer.token).catch(() => {});
  await call('PUT', `/programs/${mem.id}`, {
    tenantId: gym.id,
    diet: { kcal: 2200, protein: 120, notes: 'Din mein 3-4 litre paani. Raat 9 ke baad kuch heavy nahi.', meals: [
      { name: 'Breakfast', time: '8:00 AM', items: '4 egg whites, 2 brown bread, 1 banana' },
      { name: 'Lunch', time: '1:30 PM', items: '2 roti, 1 bowl dal, sabzi, salad, curd' },
      { name: 'Pre-workout', time: '5:30 PM', items: 'Black coffee, 1 apple' },
      { name: 'Dinner', time: '8:30 PM', items: 'Paneer / chicken 150 g, sabzi, 1 roti' },
    ] },
    workout: { notes: 'Har exercise se pehle 5 minute warm-up.', days: [
      { day: 'Mon', title: 'Chest + Triceps', exercises: [{ name: 'Bench press', sets: '4 x 10', weight: '40 kg' }, { name: 'Incline dumbbell press', sets: '3 x 12', weight: '14 kg' }, { name: 'Tricep pushdown', sets: '3 x 15', weight: '20 kg' }] },
      { day: 'Wed', title: 'Back + Biceps', exercises: [{ name: 'Lat pulldown', sets: '4 x 10', weight: '45 kg' }, { name: 'Seated row', sets: '3 x 12', weight: '40 kg' }, { name: 'Bicep curl', sets: '3 x 12', weight: '10 kg' }] },
      { day: 'Fri', title: 'Legs + Shoulders', exercises: [{ name: 'Squat', sets: '4 x 10', weight: '50 kg' }, { name: 'Leg press', sets: '3 x 12', weight: '100 kg' }, { name: 'Shoulder press', sets: '3 x 10', weight: '12 kg' }] },
    ] },
  }, trainer.token);
  await call('POST', '/pt-payouts', { trainerId: trainer.id, amount: 2000, mode: 'UPI' }, owner.token);

  // ---- front desk ----
  const deskPhone = phone();
  const desk = await call('POST', '/gym/staff', { name: 'Pooja Verma', phone: deskPhone, role: 'FRONT_DESK', tempPassword: PW, rights: ['members', 'memberEdit', 'payments', 'checkin', 'requests', 'enquiries', 'lockers'] }, owner.token);
  const deskLogin = await call('POST', '/auth/login', { identifier: deskPhone, password: PW });

  // ---- offers, notices ----
  await call('POST', '/offers', { title: 'Diwali offer: 20% off', details: 'On Quarterly and Annual plans till 15 Nov', validTill: addDays(today, 20), forMembers: true, memberFilter: 'ALL' }, owner.token);
  await call('POST', '/notices', { title: 'Gym closed on Sunday', message: 'The gym will stay closed this Sunday for machine service.', forMembers: true, forTrainers: true, lastDay: addDays(today, 5) }, owner.token);

  // ---- ratings ----
  await call('PUT', `/me/gyms/${gym.id}/rating`, { stars: 5, tags: ['Clean', 'Good trainers'], comment: 'Machines are well kept and the trainers really help. Best gym in Dwarka for the price!', allowShow: true }, member.token);
  await call('PUT', `/me/gyms/${gym.id}/trainers/${trainer.id}/rating`, { stars: 5, tags: ['On time', 'Explains well'], comment: 'Very patient, explains every exercise.' }, member.token);
  const rr = await call('GET', '/gym-ratings', undefined, owner.token);
  for (const r of rr.rows) await call('POST', `/gym-ratings/${r.id}/show`, { show: true }, owner.token);

  // ---- lockers, enquiries, salary ----
  await call('PUT', '/lockers/count', { count: 20 }, owner.token);
  await call('POST', '/lockers/3/assign', { memberId: mem.id, to: addDays(today, 60), fee: 600, deposit: 200, mode: 'CASH' }, owner.token);
  await call('POST', '/lockers/7/assign', { memberId: memberIds[2], to: addDays(today, 2), fee: 300, deposit: 200, mode: 'UPI' }, owner.token);
  await call('POST', '/enquiries', { name: 'Rohit Mehra', phone: phone(), interests: ['Gym', 'PT'], source: 'Instagram', temp: 'HOT', next: `${today}T18:00`, note: 'Wants evening batch, asked about fees' }, owner.token);
  await call('POST', '/enquiries', { name: 'Kavya Singh', phone: phone(), interests: ['Zumba'], source: 'Walk-in', temp: 'WARM', next: `${addDays(today, 1)}T11:00`, note: 'Will come with a friend' }, owner.token);
  await call('PUT', `/salary/${desk.id}`, { amount: 12000, mode: 'MONTH', workDays: 26, freeLeaves: 2, cutAbsent: true }, owner.token);
  await call('PUT', `/salary/${trainer.id}`, { amount: 15000, mode: 'MONTH', workDays: 26, freeLeaves: 2, cutAbsent: false }, owner.token);
  await call('POST', `/salary/${desk.id}/adjust`, { kind: 'ADVANCE', amount: 2000, note: 'Festival advance' }, owner.token).catch(() => {});
  for (const d of [-4, -3, -2, -1]) for (const uid of [desk.id, trainer.id]) await call('PUT', `/staff-attendance/${uid}/${addDays(today, d)}`, { present: true, note: 'Marked at the desk' }, owner.token).catch(() => {});

  writeFileSync(
    process.env.GUIDE_OUT || '/tmp/guide-logins.json',
    JSON.stringify({
      tenantId: gym.id,
      gymCode: gym.gymCode,
      branch2: branch2.id,
      memberId: mem.id,
      ptId: pt.id,
      owner: owner.token,
      staff: deskLogin.token,
      trainer: trainer.token,
      member: member.token,
    }),
  );
  serve({ fetch: app.fetch, port: PORT });
  console.log(`guide demo on :${PORT}`);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
