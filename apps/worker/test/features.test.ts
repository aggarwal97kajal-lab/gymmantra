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
    expect((await h.api.post(`/gym-ratings/${mem.user.id}/show`, { show: true }, owner.token)).status).toBe(200);
    const t = (await h.api.get(`/gyms/${owner.gym.id}/testimonials`, mem.token)).body;
    expect(t).toEqual({ avg: 5, count: 1, items: [{ name: 'Rahul S.', stars: 5, text: 'Machines hamesha theek' }] });
    // the member takes back permission: it disappears
    await h.api.put(`/me/gyms/${owner.gym.id}/rating`, { stars: 4, comment: 'Machines hamesha theek', allowShow: false }, mem.token);
    expect((await h.api.get(`/gyms/${owner.gym.id}/testimonials`, mem.token)).body.items).toEqual([]);
    expect((await h.api.post(`/gym-ratings/${mem.user.id}/show`, { show: true }, owner.token)).status).toBe(400);
    const x = await h.signup('Stranger');
    expect((await h.api.get(`/gyms/${owner.gym.id}/testimonials`, x.token)).status).toBe(403);
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
