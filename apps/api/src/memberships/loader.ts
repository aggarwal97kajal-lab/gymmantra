import { Prisma } from '@prisma/client';
import { toYmd } from '../common/dates';
import { PrismaService } from '../common/prisma.service';
import { SubLike } from './status';

export type LoadedSub = SubLike & {
  planId: string | null;
  planName: string;
  months: number;
  price: number;
  joiningFee: number;
  discount: number;
  kind: string;
  note: string | null;
  createdById: string;
  freezes: { id: string; startDate: string; days: number; endedOn: string | null; reason: string | null; createdAt: Date }[];
  payments: { id: string; amount: number; mode: string; receivedById: string; receivedAt: Date; note: string | null }[];
};

type Client = PrismaService | Prisma.TransactionClient;

/**
 * Loads memberships for members of one gym, with payments and freezes.
 * Payments made against a row that was later corrected count towards the
 * correction, so a correction never loses money already received.
 */
export async function loadSubs(prisma: Client, tenantId: string, memberIds: string[]): Promise<Map<string, LoadedSub[]>> {
  const out = new Map<string, LoadedSub[]>();
  for (const id of memberIds) out.set(id, []);
  if (!memberIds.length) return out;
  const rows = await prisma.subscription.findMany({
    where: { tenantId, memberId: { in: memberIds } },
    include: { payments: true, freezes: true },
    orderBy: { createdAt: 'asc' },
  });
  const byId = new Map(rows.map((r) => [r.id, r]));
  const ownPaid = (id: string) => (byId.get(id)?.payments ?? []).reduce((n, p) => n + p.amount, 0);
  const chainPaid = (id: string, seen = new Set<string>()): number => {
    if (seen.has(id)) return 0;
    seen.add(id);
    const r = byId.get(id);
    if (!r) return 0;
    return ownPaid(id) + (r.replacesId ? chainPaid(r.replacesId, seen) : 0);
  };
  const chainFreezes = (id: string, seen = new Set<string>()): typeof rows[number]['freezes'] => {
    if (seen.has(id)) return [];
    seen.add(id);
    const r = byId.get(id);
    if (!r) return [];
    return [...r.freezes, ...(r.replacesId ? chainFreezes(r.replacesId, seen) : [])];
  };
  for (const r of rows) {
    const freezes = chainFreezes(r.id);
    out.get(r.memberId)!.push({
      id: r.id,
      replacesId: r.replacesId,
      planId: r.planId,
      planName: r.planName,
      months: r.months,
      startDate: toYmd(r.startDate),
      endDate: toYmd(r.endDate),
      price: r.price,
      joiningFee: r.joiningFee,
      discount: r.discount,
      total: r.total,
      allowEntryWhileDue: r.allowEntryWhileDue,
      freezeDaysAllowed: r.freezeDaysAllowed,
      kind: r.kind,
      note: r.note,
      createdById: r.createdById,
      createdAt: r.createdAt,
      paid: chainPaid(r.id),
      freezes: freezes.map((f) => ({ id: f.id, startDate: toYmd(f.startDate), days: f.days, endedOn: f.endedOn ? toYmd(f.endedOn) : null, reason: f.reason, createdAt: f.createdAt })),
      payments: r.payments.map((p) => ({ id: p.id, amount: p.amount, mode: p.mode, receivedById: p.receivedById, receivedAt: p.receivedAt, note: p.note })),
    });
  }
  return out;
}
