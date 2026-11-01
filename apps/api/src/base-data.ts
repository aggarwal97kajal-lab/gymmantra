import { PrismaClient } from '@prisma/client';

/** Starting SaaS plans. Created once; after that the super admin edits them in the panel. */
export const DEFAULT_SAAS_PLANS = [
  {
    name: 'Starter',
    monthlyPrice: 399,
    annualPrice: 3990,
    memberLimit: 150,
    branchLimit: 1,
    staffLimit: 3,
    whatsappLimit: 0,
    features: ['Admin panel', 'Member app', 'Plans & manual memberships', 'QR attendance', 'Support inbox'],
    sortOrder: 1,
  },
  {
    name: 'Growth',
    monthlyPrice: 799,
    annualPrice: 7990,
    memberLimit: 500,
    branchLimit: 1,
    staffLimit: 5,
    whatsappLimit: 1000,
    features: ['Everything in Starter', 'WhatsApp reminders & receipts', 'Excel import', 'Reports'],
    sortOrder: 2,
  },
  {
    name: 'Pro',
    monthlyPrice: 1399,
    annualPrice: 13990,
    memberLimit: null,
    branchLimit: 3,
    staffLimit: 15,
    whatsappLimit: 5000,
    features: ['Everything in Growth', '3D exercise guides', 'Multi-branch view', 'Priority support'],
    sortOrder: 3,
  },
];

export async function ensureBaseData(prisma: PrismaClient) {
  await prisma.platformSetting.upsert({ where: { id: 1 }, create: { id: 1, trialMonths: 3 }, update: {} });
  if ((await prisma.saasPlan.count()) === 0) {
    for (const p of DEFAULT_SAAS_PLANS) await prisma.saasPlan.create({ data: p });
  }
}
