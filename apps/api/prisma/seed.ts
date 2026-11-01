/**
 * Demo data: the two pilot gyms with sample plans and members.
 * Run with `pnpm --filter @gymmantra/api seed`. Do not run on production
 * after the real gyms have started using the app.
 */
import { PrismaClient } from '@prisma/client';
import * as bcrypt from 'bcryptjs';
import { ensureBaseData } from '../src/base-data';
import { addDays, planEndDate, toDbDate, todayIST } from '../src/common/dates';

const prisma = new PrismaClient();
const DEMO_PASSWORD = process.env.DEMO_PASSWORD || 'Demo@12345';

const FIRST = ['Rahul', 'Priya', 'Amit', 'Neha', 'Vikram', 'Anjali', 'Rohit', 'Sneha', 'Karan', 'Pooja', 'Arjun', 'Kavya', 'Saurabh', 'Isha', 'Manish', 'Ritika', 'Deepak', 'Simran', 'Nikhil', 'Tanya'];
const LAST = ['Sharma', 'Verma', 'Gupta', 'Singh', 'Yadav', 'Malhotra', 'Chauhan', 'Arora', 'Bansal', 'Mehta'];

async function gym(name: string, code: string, prefix: string, ownerName: string, ownerEmail: string, ownerPhone: string, deskPhone: string, offset: number) {
  if (await prisma.tenant.findUnique({ where: { gymCode: code } })) {
    console.log(`${name} already seeded`);
    return;
  }
  const hash = await bcrypt.hash(DEMO_PASSWORD, 10);
  const owner = await prisma.user.upsert({ where: { email: ownerEmail }, create: { name: ownerName, email: ownerEmail, phone: ownerPhone, passwordHash: hash }, update: {} });
  const desk = await prisma.user.upsert({
    where: { phone: deskPhone },
    create: { name: `${name.split(' ')[0]} Front Desk`, phone: deskPhone, email: `desk.${code.toLowerCase()}@gymmantra.demo`, passwordHash: hash },
    update: {},
  });
  const today = todayIST();
  const t = await prisma.tenant.create({
    data: {
      name,
      gymCode: code,
      phone: ownerPhone,
      whatsappNumber: ownerPhone,
      address: 'Sector 7, Dwarka, New Delhi',
      memberCodePrefix: prefix,
      trialEndsAt: new Date(`${planEndDate(today, 3)}T18:29:59.000Z`),
    },
  });
  const b = await prisma.branch.create({ data: { tenantId: t.id, name: 'Dwarka Sector 7', address: 'Sector 7, Dwarka, New Delhi', hours: '5:30 AM – 10:30 PM' } });
  await prisma.staff.create({ data: { tenantId: t.id, userId: owner.id, role: 'OWNER', branchIds: [b.id] } });
  await prisma.staff.create({ data: { tenantId: t.id, userId: desk.id, role: 'FRONT_DESK', branchIds: [b.id] } });
  const plans = await Promise.all(
    [
      { name: 'Monthly', months: 1, price: 1500, joiningFee: 500, freezeDays: 0, features: ['Gym floor', 'Locker'] },
      { name: 'Quarterly', months: 3, price: 4000, joiningFee: 500, freezeDays: 10, features: ['Gym floor', 'Locker', 'Diet chart'] },
      { name: 'Half-yearly', months: 6, price: 7000, joiningFee: 0, freezeDays: 20, features: ['Gym floor', 'Locker', 'Diet chart', '1 PT session'] },
      { name: 'Annual', months: 12, price: 12000, joiningFee: 0, freezeDays: 30, features: ['Gym floor', 'Locker', 'Diet chart', '4 PT sessions'] },
      { name: 'Student Monthly', months: 1, price: 1100, joiningFee: 0, freezeDays: 0, features: ['Gym floor'], showInApp: false },
    ].map((p) => prisma.membershipPlan.create({ data: { tenantId: t.id, ...p } })),
  );

  let n = 1001;
  for (let i = 0; i < 30; i++) {
    const name_ = `${FIRST[(i + offset) % FIRST.length]} ${LAST[(i * 3 + offset) % LAST.length]}`;
    const phone = `+919${String(810000000 + offset * 1000 + i).padStart(9, '0')}`;
    const m = await prisma.member.create({
      data: { tenantId: t.id, memberCode: `${prefix}-${n++}`, name: name_, phone, branchId: b.id, joinedOn: toDbDate(addDays(today, -200 + i)), gender: i % 2 ? 'female' : 'male' },
    });
    if (i % 10 === 9) continue; // a few with no plan
    const plan = plans[i % 4];
    // Spread end dates: some active, some ending soon, some expired.
    const startShift = [-10, -25, -80, -170, -5, -88, -29, -3, -360][i % 9];
    const start = addDays(today, startShift);
    const end = planEndDate(start, plan.months);
    const discount = i % 4 === 0 ? 200 : 0;
    const total = plan.price + plan.joiningFee - discount;
    const sub = await prisma.subscription.create({
      data: {
        tenantId: t.id, memberId: m.id, planId: plan.id, planName: plan.name, months: plan.months,
        startDate: toDbDate(start), endDate: toDbDate(end), price: plan.price, joiningFee: plan.joiningFee, discount, total,
        freezeDaysAllowed: plan.freezeDays, allowEntryWhileDue: i % 7 === 0, kind: 'NEW', createdById: i % 2 ? owner.id : desk.id,
      },
    });
    const unpaid = i % 7 === 0;
    if (!unpaid) {
      await prisma.payment.create({ data: { tenantId: t.id, subscriptionId: sub.id, amount: total, mode: (['CASH', 'UPI', 'CARD', 'UPI'] as const)[i % 4], receivedById: sub.createdById, receivedAt: new Date(`${start}T10:00:00+05:30`) } });
    }
  }
  await prisma.tenant.update({ where: { id: t.id }, data: { nextMemberNumber: n } });
  console.log(`Seeded ${name}: owner ${ownerEmail}, front desk ${deskPhone}, password ${DEMO_PASSWORD}, gym code ${code}`);
}

async function main() {
  await ensureBaseData(prisma);
  await gym('Lifetime Fitness', 'LIFE701', 'LF', 'Lifetime Owner', 'owner@lifetimefitness.demo', '+919810000001', '+919810000011', 0);
  await gym('Athlete Gym', 'ATHL702', 'AG', 'Athlete Owner', 'owner@athletegym.demo', '+919810000002', '+919810000012', 7);
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
