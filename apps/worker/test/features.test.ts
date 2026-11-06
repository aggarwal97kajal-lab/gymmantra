// Nov 6 features: enquiries, staff salary, lockers, trainer / gym ratings, fingerprint machines.
import { P } from '../src/core';
import { todayIST, addDays } from '../src/lib/dates';
import { cronScheduled } from '../src/lib/scheduled';
import { setup } from './helpers';

let h: ReturnType<typeof setup>;
beforeEach(() => {
  h = setup();
});

async function gymWithMember(name = 'Feature Gym') {
  const owner = await h.ownerWithGym(name);
  const mem = await h.signup('Rahul Sharma');
  await h.api.post('/me/join', { gymCode: owner.gym.gymCode }, mem.token);
  const jr = (await h.api.get('/join-requests', owner.token)).body[0];
  const memberId = (await h.api.post(`/join-requests/${jr.id}/approve`, {}, owner.token)).body.id as string;
  return { owner, mem, memberId };
}
async function addTrainer(owner: any, gymCode: string, name = 'Vikas Trainer') {
  const tr = await h.signup(name);
  await h.api.post('/me/join', { gymCode, as: 'TRAINER', speciality: 'Strength', experienceYears: 3 }, tr.token);
  const r = (await h.api.get('/join-requests', owner.token)).body.find((x: any) => x.kind === 'TRAINER');
  await h.api.post(`/join-requests/${r.id}/approve`, {}, owner.token);
  return tr;
}
async function addDesk(owner: any, rights?: string[]) {
  const ph = h.nextPhone();
  const add = await h.api.post('/gym/staff', { name: 'Pooja Desk', phone: ph, role: 'FRONT_DESK', tempPassword: 'desk12345', ...(rights ? { rights } : {}) }, owner.token);
  const tok = (await h.api.post('/auth/login', { identifier: ph, password: 'desk12345' })).body.token as string;
  return { id: add.body.id as string, token: tok };
}
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 0xff, 0xd9]).toString('base64');
const notes = async (token: string) => (await h.api.get("/me/notifications", token)).body as any[];

describe('enquiry follow-up', () => {
  it('add, follow up, remind at 9 AM, join', async () => {
    const owner = await h.ownerWithGym('Enquiry Gym');
    const today = todayIST();
    const e = await h.api.post('/enquiries', { name: 'Rohit Mehra', phone: '9876511223', interests: ['Gym', 'PT'], source: 'Instagram', temp: 'HOT', next: `${today}T11:00`, note: 'Fees zyada lagi' }, owner.token);
    expect(e.status).toBe(201);
    let list = await h.api.get('/enquiries?view=today', owner.token);
    expect([list.body.counts.today, list.body.rows[0].name, list.body.month.total]).toEqual([1, 'Rohit Mehra', 1]);
    // 9 AM: owner gets today's list
    await cronScheduled(h.deps, null, new Date(`${today}T04:00:00Z`)); // 9:30 India
    expect((await notes(owner.token)).some((n) => n.title === 'Enquiry calls today' && n.go === 'enquiries')).toBe(true);
    // a call, next follow-up tomorrow
    const l = await h.api.post(`/enquiries/${e.body.id}/log`, { kind: 'CALL', text: 'Sochke batayenge', next: addDays(today, 1) }, owner.token);
    expect([l.body.log[0].kind, l.body.next]).toEqual(['CALL', `${addDays(today, 1)}T10:00`]);
    list = await h.api.get('/enquiries?view=upcoming', owner.token);
    expect(list.body.rows).toHaveLength(1);
    // joined
    const m = (await h.api.post('/members', { name: 'Rohit Mehra', phone: '9876511223' }, owner.token)).body;
    const j = await h.api.post(`/enquiries/${e.body.id}/joined`, { memberId: m.id }, owner.token);
    expect(j.body.status).toBe('JOINED');
    expect((await h.api.get('/enquiries?view=today', owner.token)).body.month.joined).toBe(1);
  });

  it('front desk needs the enquiries right; another gym cannot see them', async () => {
    const owner = await h.ownerWithGym('Right Gym');
    const desk = await addDesk(owner, ['members']);
    expect((await h.api.get('/enquiries', desk.token)).status).toBe(403);
    const e = (await h.api.post('/enquiries', { name: 'Anjali', phone: '9876511224' }, owner.token)).body;
    const other = await h.ownerWithGym('Other Gym');
    expect((await h.api.get(`/enquiries/${e.id}`, other.token)).status).toBe(404);
  });
});

describe('staff salary', () => {
  it('owner sets salary; absent days are cut; advance and payment; staff sees only their slip', async () => {
    const owner = await h.ownerWithGym('Salary Gym');
    const desk = await addDesk(owner);
    const month = todayIST().slice(0, 7);
    expect((await h.api.put(`/salary/${desk.id}`, { amount: 13000, mode: 'MONTH', workDays: 26, freeLeaves: 2, cutAbsent: false }, owner.token)).status).toBe(200);
    await h.api.post(`/salary/${desk.id}/adjust`, { month, kind: 'ADVANCE', amount: 3000, note: 'Ghar ka kaam' }, owner.token);
    await h.api.post(`/salary/${desk.id}/adjust`, { month, kind: 'BONUS', amount: 500 }, owner.token);
    let s = (await h.api.get(`/salary?month=${month}`, owner.token)).body;
    let row = s.rows.find((r: any) => r.id === desk.id);
    expect([row.slip.total, row.slip.paid, row.slip.due]).toEqual([13500, 3000, 10500]);
    const pay = await h.api.post(`/salary/${desk.id}/pay`, { month, amount: 10500, mode: 'UPI' }, owner.token);
    expect(pay.status).toBe(201);
    row = (await h.api.get(`/salary?month=${month}`, owner.token)).body.rows.find((r: any) => r.id === desk.id);
    expect(row.slip.due).toBe(0);
    // the staff member: their slip and a notification
    const mine = (await h.api.get('/me/salary', desk.token)).body;
    expect(mine.months[0].total).toBe(13500);
    expect((await notes(desk.token)).some((n) => n.title === 'Salary paid' && n.go === 'salary')).toBe(true);
    // staff cannot see the gym's salaries
    expect((await h.api.get('/salary', desk.token)).status).toBe(403);
    // a person without the app (cleaner)
    const e = await h.api.put('/salary/new', { name: 'Ramesh Safai', amount: 8000, mode: 'MONTH', workDays: 26, freeLeaves: 2, cutAbsent: true }, owner.token);
    s = (await h.api.get(`/salary?month=${month}`, owner.token)).body;
    expect(s.rows.find((r: any) => r.id === e.body.uid).slip.total).toBe(8000);
  });

  it('absent days beyond the free leaves are cut (past month)', async () => {
    const { slip } = await import('../src/routes/salary');
    const cfg = { uid: 'x', name: 'X', role: 'FRONT_DESK', branchId: null, amount: 26000, mode: 'MONTH', workDays: 26, freeLeaves: 2, cutAbsent: true, active: true } as any;
    const days = { uid: 'x', month: '2026-09', branchId: null, days: Object.fromEntries(Array.from({ length: 20 }, (_, i) => [`2026-09-${String(i + 1).padStart(2, '0')}`, { at: '', distM: 1 }])) };
    const r = slip(cfg, null, days, '2026-09', '2026-11-06');
    expect([r.present, r.absent, r.cut, r.total]).toEqual([20, 6, 4000, 22000]);
  });
});

describe('lockers', () => {
  it('give a locker to a member, they see it, reminders, renew, empty', async () => {
    const { owner, mem, memberId } = await gymWithMember('Locker Gym');
    await h.api.put('/lockers/count', { count: 16 }, owner.token);
    const today = todayIST();
    const g = await h.api.post('/lockers/3/assign', { memberId, to: addDays(today, 3), fee: 600, deposit: 200, mode: 'CASH' }, owner.token);
    expect(g.status).toBe(201);
    expect((await h.api.post('/lockers/3/assign', { memberId, to: addDays(today, 3) }, owner.token)).status).toBe(409);
    let l = (await h.api.get('/lockers', owner.token)).body;
    expect([l.count, l.free, l.rows[2].state, l.rows[2].use.name]).toEqual([16, 15, 'ENDING', 'Rahul Sharma']);
    expect((await h.store.get<any>(P.member(owner.gym.id, memberId))).locker.n).toBe(3);
    // reminder 3 days before = today
    await cronScheduled(h.deps, null, new Date(`${today}T05:00:00Z`)); // 10:30 India
    expect((await notes(mem.token)).some((n) => n.title === 'Your locker ends soon')).toBe(true);
    expect((await notes(owner.token)).some((n) => n.title === 'Locker ending soon' && n.go === 'lockers')).toBe(true);
    // renew, then empty (deposit back)
    expect((await h.api.post('/lockers/3/renew', { to: addDays(today, 90), fee: 1200 }, owner.token)).body.use.to).toBe(addDays(today, 90));
    const f = await h.api.post('/lockers/3/free', {}, owner.token);
    expect(f.body.depositBack).toBe(200);
    l = (await h.api.get('/lockers', owner.token)).body;
    expect(l.free).toBe(16);
    expect((await h.store.get<any>(P.member(owner.gym.id, memberId))).locker).toBeUndefined();
    // cannot shrink below a given locker
    await h.api.post('/lockers/16/assign', { memberId, to: addDays(today, 30) }, owner.token);
    expect((await h.api.put('/lockers/count', { count: 10 }, owner.token)).status).toBe(409);
  });
});

describe('ratings', () => {
  it('member rates a trainer: owner sees the comment and name, the trainer only the number and tags', async () => {
    const { owner, mem } = await gymWithMember('Rating Gym');
    const tr = await addTrainer(owner, owner.gym.gymCode);
    const list = (await h.api.get(`/me/gyms/${owner.gym.id}/trainer-ratings`, mem.token)).body;
    const tid = list[0].trainerId;
    const r = await h.api.put(`/me/gyms/${owner.gym.id}/trainers/${tid}/rating`, { stars: 4, tags: ['Time pe aate hain'], comment: 'Shaam ko late aate hain' }, mem.token);
    expect(r.status).toBe(200);
    const o = (await h.api.get('/trainer-ratings', owner.token)).body[0];
    expect([o.avg, o.count, o.comments[0].comment, o.comments[0].name]).toEqual([4, 1, 'Shaam ko late aate hain', 'Rahul S.']);
    const mine = (await h.api.get('/trainer/rating', tr.token)).body;
    expect(mine).toEqual({ avg: 4, count: 1, tags: [{ tag: 'Time pe aate hain', n: 1 }] });
    // someone who is not a member of the gym cannot rate
    const x = await h.signup('Stranger');
    expect((await h.api.put(`/me/gyms/${owner.gym.id}/trainers/${tid}/rating`, { stars: 1 }, x.token)).status).toBe(403);
  });

  it('gym rating: owner shows it, it appears for members; only if the member allowed', async () => {
    const { owner, mem } = await gymWithMember('Review Gym');
    await h.api.put(`/me/gyms/${owner.gym.id}/rating`, { stars: 5, tags: ['Saaf-safai'], comment: 'Machines hamesha theek', allowShow: true }, mem.token);
    const r = (await h.api.get('/gym-ratings', owner.token)).body;
    expect([r.avg, r.count, r.rows[0].comment]).toEqual([5, 1, 'Machines hamesha theek']);
    const rid = r.rows[0].id;
    expect((await h.api.post(`/gym-ratings/${rid}/show`, { show: true }, owner.token)).status).toBe(200);
    const t = (await h.api.get(`/gyms/${owner.gym.id}/testimonials`, mem.token)).body;
    expect(t).toEqual({ avg: 5, count: 1, items: [{ name: 'Rahul S.', stars: 5, text: 'Machines hamesha theek', photoUrl: null }] });
    // the member takes back permission: it disappears
    await h.api.put(`/me/gyms/${owner.gym.id}/rating`, { stars: 4, comment: 'Machines hamesha theek', allowShow: false }, mem.token);
    expect((await h.api.get(`/gyms/${owner.gym.id}/testimonials`, mem.token)).body.items).toEqual([]);
    expect((await h.api.post(`/gym-ratings/${rid}/show`, { show: true }, owner.token)).status).toBe(400);
    const x = await h.signup('Stranger');
    expect((await h.api.get(`/gyms/${owner.gym.id}/testimonials`, x.token)).status).toBe(403);
  });
});

describe('ratings per branch (board 93)', () => {
  it('each branch has its own rating and testimonials; join page and transfers follow the branch', async () => {
    const { owner, mem, memberId } = await gymWithMember('Branch Review Gym');
    const br = (await h.api.post('/gym/branches', { name: 'Boring Road' }, owner.token)).body;
    const B = { 'x-branch-id': br.id };
    // a member of branch 2
    const m2 = await h.signup('Neha Gupta');
    await h.api.post('/me/join', { gymCode: br.code }, m2.token);
    const jr = (await h.api.get('/join-requests', owner.token, B)).body[0];
    const m2Id = (await h.api.post(`/join-requests/${jr.id}/approve`, {}, owner.token, B)).body.id as string;
    // photo for Neha
    expect((await h.api.post('/me/photo', { mime: 'image/jpeg', base64: JPEG }, m2.token)).status).toBe(201);
    await h.api.put(`/me/gyms/${owner.gym.id}/rating`, { stars: 3, comment: 'Main branch theek', allowShow: true }, mem.token);
    await h.api.put(`/me/gyms/${owner.gym.id}/rating`, { stars: 5, comment: 'Zumba batch best hai!', allowShow: true }, m2.token);
    const r = (await h.api.get('/gym-ratings', owner.token)).body;
    expect(r.branches.map((b: any) => [b.avg, b.count])).toEqual([[3, 1], [5, 1]]);
    for (const row of r.rows) await h.api.post(`/gym-ratings/${row.id}/show`, { show: true }, owner.token);
    // each member sees only their own branch
    const t1 = (await h.api.get('/me/gyms', mem.token)).body.memberships[0].testimonials;
    const t2 = (await h.api.get('/me/gyms', m2.token)).body.memberships[0].testimonials;
    expect([t1.avg, t1.items.map((x: any) => x.text)]).toEqual([3, ['Main branch theek']]);
    expect([t2.avg, t2.items.map((x: any) => x.text)]).toEqual([5, ['Zumba batch best hai!']]);
    // photo of a shown reviewer: people of the gym yes, strangers only with the gym's code
    const photo = t2.items[0].photoUrl as string;
    expect(photo).toContain(`/gyms/${owner.gym.id}/testimonials/${m2.user.id}/photo`);
    expect((await h.api.get(photo.replace('/api/v1', ''), mem.token)).status).toBe(200);
    const x = await h.signup('Stranger');
    expect((await h.api.get(photo.replace('/api/v1', ''), x.token)).status).toBe(403);
    // join page: the code's branch
    const look = (await h.api.get(`/me/gym-lookup?code=${br.code}`, x.token)).body;
    expect(look.testimonials.items.map((i: any) => i.text)).toEqual(['Zumba batch best hai!']);
    expect((await h.api.get(look.testimonials.items[0].photoUrl.replace('/api/v1', ''), x.token)).status).toBe(200);
    // owner moves Rahul to branch 2: his old review stays with the main branch; he sees branch 2's reviews
    await h.api.call('PATCH', `/members/${memberId}`, { token: owner.token, body: { branchId: br.id } });
    const after = (await h.api.get('/gym-ratings', owner.token)).body;
    expect(after.branches.map((b: any) => [b.avg, b.count])).toEqual([[3, 1], [5, 1]]);
    const t1b = (await h.api.get('/me/gyms', mem.token)).body.memberships[0].testimonials;
    expect(t1b.items.map((i: any) => i.text)).toEqual(['Zumba batch best hai!']);
    // ...and can rate the new branch afresh
    expect((await h.api.get(`/me/gyms/${owner.gym.id}/rating`, mem.token)).body).toBeNull();
    await h.api.put(`/me/gyms/${owner.gym.id}/rating`, { stars: 3, comment: 'Naya branch bhi theek', allowShow: true }, mem.token);
    const after2 = (await h.api.get('/gym-ratings', owner.token)).body;
    expect(after2.branches.map((b: any) => [b.avg, b.count])).toEqual([[3, 1], [4, 2]]);
    expect(after2.rows).toHaveLength(3);
    // staff / owner of branch 1 still see branch 1's review
    expect((await h.api.get(`/gyms/${owner.gym.id}/testimonials`, owner.token)).body.items.map((i: any) => i.text)).toEqual(['Main branch theek']);
    expect((await h.api.get(`/gyms/${owner.gym.id}/testimonials?branchId=${br.id}`, owner.token)).body.items).toHaveLength(1);
    // trainer ratings: each trainer with their branch; members rate only their branch's trainers
    const tr2 = await h.signup('Branch Two Trainer');
    await h.api.post('/me/join', { gymCode: br.code, as: 'TRAINER', speciality: 'Strength', experienceYears: 3 }, tr2.token);
    const tj = (await h.api.get('/join-requests', owner.token, B)).body.find((x: any) => x.kind === 'TRAINER');
    await h.api.post(`/join-requests/${tj.id}/approve`, {}, owner.token, B);
    const tr = (await h.api.get('/trainer-ratings', owner.token)).body;
    expect(tr.map((x: any) => [x.name, x.branchId])).toEqual([['Branch Two Trainer', br.id]]);
    // a trainer who renames shows the new name at once
    await h.api.call('PATCH', '/me/profile', { token: tr2.token, body: { name: 'Rajeev Talwar' } });
    expect((await h.api.get('/trainer-ratings', owner.token)).body[0].name).toBe('Rajeev Talwar');
    const tl = (await h.api.get(`/me/gyms/${owner.gym.id}/trainer-ratings`, mem.token)).body;
    expect(tl.map((x: any) => x.name)).toEqual(['Rajeev Talwar']);
    expect((await h.api.get(`/me/gyms/${owner.gym.id}/trainer-ratings`, m2.token)).body).toHaveLength(1);
    void m2Id;
  });
});

describe('money report (board 94)', () => {
  it('memberships, PT, lockers and salary in separate cards', async () => {
    const { owner, memberId } = await gymWithMember('Money Gym');
    const plan = (await h.api.post('/plans', { name: 'Monthly', months: 1, price: 1500 }, owner.token)).body;
    await h.api.post(`/members/${memberId}/memberships`, { planId: plan.id, paymentMode: 'CASH' }, owner.token);
    await h.api.put('/lockers/count', { count: 5 }, owner.token);
    await h.api.post('/lockers/2/assign', { memberId, to: addDays(todayIST(), 30), fee: 300, deposit: 200 }, owner.token);
    const desk = await addDesk(owner);
    await h.api.put(`/salary/${desk.id}`, { amount: 9000, mode: 'MONTH', workDays: 26, freeLeaves: 2, cutAbsent: false }, owner.token);
    const r = await h.api.get('/reports/money?days=30', owner.token);
    expect(r.status).toBe(200);
    expect([r.body.memberships.total, r.body.memberships.fresh]).toEqual([1500, 1500]);
    expect([r.body.lockers.total, r.body.lockers.depositHeld]).toEqual([300, 200]);
    expect(r.body.salary.total).toBe(9000);
    expect(r.body.net).toEqual({ income: 1800, out: 9000, left: -7200 });
    const csv = await h.app.request('/api/v1/reports/money?days=30&csv=1', { headers: { authorization: `Bearer ${owner.token}` } });
    expect(await csv.text()).toContain('Lockers');
    // front desk with the reports right sees no salaries
    const d2 = await addDesk(owner, ['reports']);
    const rd = await h.api.get('/reports/money?days=30', d2.token);
    expect([rd.status, rd.body.salary]).toEqual([200, null]);
  });
});

describe('salary and staff attendance follow the branch open on Home', () => {
  it('each branch shows only its own staff', async () => {
    const owner = await h.ownerWithGym('Cards Gym');
    const br = (await h.api.post('/gym/branches', { name: 'Kankarbagh' }, owner.token)).body;
    const desk = await addDesk(owner);
    await h.api.put(`/salary/${desk.id}`, { amount: 9000, mode: 'MONTH', workDays: 26, freeLeaves: 2, cutAbsent: false }, owner.token);
    expect((await h.api.get('/salary', owner.token)).body.rows.map((r: any) => r.id)).toEqual([desk.id]);
    expect((await h.api.get('/salary', owner.token, { 'x-branch-id': br.id })).body.rows).toEqual([]);
    expect((await h.api.get('/staff-attendance', owner.token)).body.rows).toHaveLength(1);
    expect((await h.api.get('/staff-attendance', owner.token, { 'x-branch-id': br.id })).body.rows).toEqual([]);
  });
});

describe('fingerprint machine', () => {
  const machine = (path: string, init?: RequestInit) => h.app.request(path, init);

  it('owner adds the machine; punches become check-ins and staff Present', async () => {
    const { owner, memberId } = await gymWithMember('Machine Gym');
    const desk = await addDesk(owner);
    expect((await machine('/iclock/getrequest?SN=CQZ123')).status).toBe(404); // not added yet
    expect((await h.api.post('/gym/devices', { serial: 'cqz123', name: 'Main gate' }, owner.token)).status).toBe(201);
    expect((await h.api.post('/gym/devices', { serial: 'CQZ123' }, (await h.ownerWithGym('Other')).token)).status).toBe(409);
    const opt = await machine('/iclock/cdata?SN=CQZ123&options=all');
    expect(await opt.text()).toContain('GET OPTION FROM: CQZ123');
    const now = new Date(Date.now() + 5.5 * 3600_000).toISOString().slice(0, 19).replace('T', ' ');
    // an unknown PIN is listed for the owner to link
    let r = await machine('/iclock/cdata?SN=CQZ123&table=ATTLOG', { method: 'POST', body: `101\t${now}\t0\t1\t0\n` });
    expect(await r.text()).toBe('OK: 1');
    let devs = (await h.api.get('/gym/devices', owner.token)).body;
    expect(devs[0].unknown.map((x: any) => x.pin)).toEqual(['101']);
    await h.api.put('/gym/devices/CQZ123/pins/101', { kind: 'member', id: memberId }, owner.token);
    await h.api.put('/gym/devices/CQZ123/pins/102', { kind: 'staff', id: desk.id }, owner.token);
    r = await machine('/iclock/cdata?SN=CQZ123&table=ATTLOG', { method: 'POST', body: `101\t${now}\t0\t1\t0\n102\t${now}\t0\t1\t0\n` });
    expect(await r.text()).toBe('OK: 2');
    const att = (await h.api.get('/attendance/today', owner.token)).body;
    const rows = att.events;
    expect(rows.some((x: any) => x.method === 'DEVICE' && x.memberId === memberId)).toBe(true);
    expect((await h.api.get('/me/staff-attendance', desk.token)).body.markedToday).toBe(true);
    devs = (await h.api.get('/gym/devices', owner.token)).body;
    expect([devs[0].pins.length, devs[0].unknown.length]).toEqual([2, 0]);
    // another gym cannot touch this machine
    const other = await h.ownerWithGym('Other Two');
    expect((await h.api.call('DELETE', '/gym/devices/CQZ123', { token: other.token })).status).toBe(404);
  });
});
