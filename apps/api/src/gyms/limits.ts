import { ForbiddenException } from '@nestjs/common';
import { PrismaService } from '../common/prisma.service';

export interface Limits {
  planName: string;
  memberLimit: number | null;
  branchLimit: number;
  staffLimit: number;
  features: string[];
}

/** During the free trial a gym gets the limits of the most generous visible plan. */
export async function gymLimits(prisma: PrismaService, tenantId: string): Promise<Limits> {
  const t = await prisma.tenant.findUniqueOrThrow({ where: { id: tenantId }, include: { saasPlan: true } });
  const inTrial = t.status === 'TRIAL' && (!t.trialEndsAt || t.trialEndsAt > new Date());
  let plan = t.saasPlan;
  if (inTrial || !plan) {
    const all = await prisma.saasPlan.findMany({ where: { visible: true }, orderBy: { sortOrder: 'desc' } });
    plan = all[0] ?? null;
  }
  if (!plan) return { planName: 'Trial', memberLimit: null, branchLimit: 3, staffLimit: 10, features: [] };
  return {
    planName: inTrial ? `Free trial (${plan.name} features)` : plan.name,
    memberLimit: plan.memberLimit,
    branchLimit: plan.branchLimit,
    staffLimit: plan.staffLimit,
    features: plan.features,
  };
}

export async function assertUnder(prisma: PrismaService, tenantId: string, what: 'members' | 'branches' | 'staff') {
  const l = await gymLimits(prisma, tenantId);
  if (what === 'members') {
    if (l.memberLimit == null) return;
    const n = await prisma.member.count({ where: { tenantId, archived: false } });
    if (n >= l.memberLimit) throw new ForbiddenException(`Your ${l.planName} plan allows ${l.memberLimit} members. Upgrade to add more`);
  } else if (what === 'branches') {
    const n = await prisma.branch.count({ where: { tenantId } });
    if (n >= l.branchLimit) throw new ForbiddenException(`Your ${l.planName} plan allows ${l.branchLimit} branch${l.branchLimit === 1 ? '' : 'es'}`);
  } else {
    const n = await prisma.staff.count({ where: { tenantId, active: true } });
    if (n >= l.staffLimit) throw new ForbiddenException(`Your ${l.planName} plan allows ${l.staffLimit} staff accounts`);
  }
}
