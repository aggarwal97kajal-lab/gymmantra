import { BadRequestException, ForbiddenException, Injectable, NotFoundException } from '@nestjs/common';
import { PaymentMode, Prisma } from '@prisma/client';
import { AuditService } from '../common/audit.service';
import { GymCtx } from '../common/auth';
import { addDays, diffDays, isYmd, planEndDate, toDbDate, todayIST, Ymd } from '../common/dates';
import { PrismaService } from '../common/prisma.service';
import { NotificationsService, prettyDate, rupees, whatsappLink } from '../notifications/notifications';
import { LoadedSub, loadSubs } from './loader';
import { activeFreeze, computeState, effectiveEnd, entryDecision, freezeDaysLeft, MemberState, renewalStart, validSubs } from './status';

export interface MembershipInput {
  planId: string;
  startDate?: string;
  endDate?: string;
  price?: number;
  discount?: number;
  amountReceived?: number;
  paymentMode: PaymentMode;
  allowEntryWhileDue?: boolean;
  note?: string;
}

@Injectable()
export class MembershipsService {
  constructor(
    private prisma: PrismaService,
    private audit: AuditService,
    private notifications: NotificationsService,
  ) {}

  /** Members a staff user may see: owners see all; front desk see their branches. */
  branchFilter(g: GymCtx): Prisma.MemberWhereInput {
    if (g.role === 'OWNER' || !g.branchIds.length) return {};
    return { OR: [{ branchId: null }, { branchId: { in: g.branchIds } }] };
  }

  async getMember(g: GymCtx, memberId: string) {
    const m = await this.prisma.member.findFirst({ where: { id: memberId, tenantId: g.tenantId, ...this.branchFilter(g) } });
    if (!m) throw new NotFoundException('Member not found');
    return m;
  }

  async state(tenantId: string, memberId: string, today = todayIST()): Promise<{ subs: LoadedSub[]; state: MemberState<LoadedSub> }> {
    const subs = (await loadSubs(this.prisma, tenantId, [memberId])).get(memberId) ?? [];
    return { subs, state: computeState(subs, today) };
  }

  /** What the Add/Renew form should show before staff edit anything. */
  async preview(g: GymCtx, memberId: string, planId: string) {
    await this.getMember(g, memberId);
    const plan = await this.prisma.membershipPlan.findFirst({ where: { id: planId, tenantId: g.tenantId } });
    if (!plan) throw new NotFoundException('Plan not found');
    const today = todayIST();
    const { subs, state } = await this.state(g.tenantId, memberId, today);
    const first = validSubs(subs).length === 0;
    const start = renewalStart(state, today);
    const tenant = await this.prisma.tenant.findUniqueOrThrow({ where: { id: g.tenantId } });
    return {
      kind: first ? 'NEW' : 'RENEWAL',
      startDate: start,
      endDate: planEndDate(start, plan.months),
      price: plan.price,
      joiningFee: first ? plan.joiningFee : 0,
      freezeDays: plan.freezeDays,
      allowEntryWhileDue: tenant.allowEntryWhenDue,
    };
  }

  async create(g: GymCtx, actorId: string, memberId: string, input: MembershipInput, opts: { replacesId?: string } = {}) {
    const member = await this.getMember(g, memberId);
    const plan = await this.prisma.membershipPlan.findFirst({ where: { id: input.planId, tenantId: g.tenantId } });
    if (!plan) throw new NotFoundException('Plan not found');
    const today = todayIST();
    const { subs, state } = await this.state(g.tenantId, memberId, today);
    const valid = validSubs(subs);

    let replaced: LoadedSub | undefined;
    if (opts.replacesId) {
      replaced = valid.find((s) => s.id === opts.replacesId);
      if (!replaced) throw new NotFoundException('Membership to correct not found');
    }
    // Joining fee only on the first membership ever (a correction of the first keeps it).
    const isFirst = replaced ? valid.filter((s) => s.id !== replaced!.id && s.startDate < replaced!.startDate).length === 0 : valid.length === 0;

    const startDate = input.startDate ?? (replaced ? replaced.startDate : renewalStart(state, today));
    if (!isYmd(startDate)) throw new BadRequestException('Start date is not valid');
    const endDate = input.endDate ?? planEndDate(startDate, plan.months);
    if (!isYmd(endDate)) throw new BadRequestException('End date is not valid');
    if (endDate < startDate) throw new BadRequestException('End date must be on or after the start date');

    const price = input.price ?? plan.price;
    const joiningFee = isFirst ? (replaced ? replaced.joiningFee : plan.joiningFee) : 0;
    const discount = input.discount ?? 0;
    if (price < 0 || discount < 0) throw new BadRequestException('Amounts cannot be negative');
    if (discount > price + joiningFee) throw new BadRequestException('Discount cannot be more than the price');
    const total = price + joiningFee - discount;
    const alreadyPaid = replaced ? replaced.paid : 0;

    let received = input.amountReceived ?? (input.paymentMode === 'NOT_PAID' ? 0 : total - alreadyPaid);
    if (input.paymentMode === 'NOT_PAID') received = 0;
    if (received < 0) throw new BadRequestException('Amount received cannot be negative');
    if (received + alreadyPaid > total) throw new BadRequestException(`Amount received cannot be more than ${rupees(total - alreadyPaid)}`);
    if (received === 0 && input.paymentMode !== 'NOT_PAID' && total - alreadyPaid > 0) {
      throw new BadRequestException('Enter the amount received, or choose "Not paid yet"');
    }

    const tenant = await this.prisma.tenant.findUniqueOrThrow({ where: { id: g.tenantId } });
    const due = total - alreadyPaid - received;
    const allowEntryWhileDue = due > 0 ? (input.allowEntryWhileDue ?? tenant.allowEntryWhenDue) : false;

    const sub = await this.prisma.$transaction(async (tx) => {
      const s = await tx.subscription.create({
        data: {
          tenantId: g.tenantId,
          memberId,
          planId: plan.id,
          planName: plan.name,
          months: plan.months,
          startDate: toDbDate(startDate),
          endDate: toDbDate(endDate),
          price,
          joiningFee,
          discount,
          total,
          freezeDaysAllowed: replaced ? replaced.freezeDaysAllowed : plan.freezeDays,
          allowEntryWhileDue,
          kind: replaced ? 'CORRECTION' : isFirst ? 'NEW' : 'RENEWAL',
          replacesId: replaced?.id ?? null,
          note: input.note?.trim() || null,
          createdById: actorId,
        },
      });
      if (received > 0) {
        await tx.payment.create({ data: { tenantId: g.tenantId, subscriptionId: s.id, amount: received, mode: input.paymentMode, receivedById: actorId } });
      }
      await this.audit.log(
        { tenantId: g.tenantId, actorId, action: replaced ? 'membership.correct' : 'membership.create', entity: 'subscription', entityId: s.id, before: replaced ?? undefined, after: { ...s, received } },
        tx,
      );
      await this.notifications.notify(
        member.userId,
        g.tenantId,
        replaced ? 'Membership updated' : 'Membership added',
        `${tenant.name} ${replaced ? 'updated' : 'added'} your ${plan.name} membership: ${prettyDate(startDate)} to ${prettyDate(endDate)}.`,
        tx,
      );
      return s;
    });

    const receipt = [
      `Hi ${member.name}, your ${plan.name} membership at ${tenant.name} is confirmed.`,
      `Valid: ${prettyDate(startDate)} to ${prettyDate(endDate)}`,
      `Amount: ${rupees(total)}${discount ? ` (discount ${rupees(discount)})` : ''}`,
      received > 0 ? `Received: ${rupees(received)} by ${input.paymentMode.replace('_', ' ').toLowerCase()}` : null,
      due > 0 ? `Due: ${rupees(due)}` : null,
      `Member ID: ${member.memberCode}`,
      `- ${tenant.name}`,
    ]
      .filter(Boolean)
      .join('\n');
    return { subscription: sub, due, whatsappReceipt: whatsappLink(member.phone, receipt) };
  }

  async correct(g: GymCtx, actorId: string, subId: string, input: MembershipInput) {
    const sub = await this.prisma.subscription.findFirst({ where: { id: subId, tenantId: g.tenantId }, select: { memberId: true } });
    if (!sub) throw new NotFoundException('Membership not found');
    return this.create(g, actorId, sub.memberId, input, { replacesId: subId });
  }

  async addPayment(g: GymCtx, actorId: string, subId: string, amount: number, mode: PaymentMode, note?: string) {
    if (mode === 'NOT_PAID') throw new BadRequestException('Choose how the money was paid');
    const sub = await this.prisma.subscription.findFirst({ where: { id: subId, tenantId: g.tenantId } });
    if (!sub) throw new NotFoundException('Membership not found');
    await this.getMember(g, sub.memberId);
    const { subs } = await this.state(g.tenantId, sub.memberId);
    const s = validSubs(subs).find((x) => x.id === subId);
    if (!s) throw new BadRequestException('This membership was corrected. Add the payment to the corrected entry');
    const due = s.total - s.paid;
    if (amount <= 0) throw new BadRequestException('Enter an amount');
    if (amount > due) throw new BadRequestException(`Only ${rupees(due)} is due`);
    const p = await this.prisma.payment.create({ data: { tenantId: g.tenantId, subscriptionId: subId, amount, mode, receivedById: actorId, note } });
    await this.audit.log({ tenantId: g.tenantId, actorId, action: 'payment.create', entity: 'payment', entityId: p.id, after: p });
    return { payment: p, due: due - amount };
  }

  async freeze(g: GymCtx, actorId: string, subId: string, days: number, startDate?: string, reason?: string) {
    const sub = await this.prisma.subscription.findFirst({ where: { id: subId, tenantId: g.tenantId } });
    if (!sub) throw new NotFoundException('Membership not found');
    const member = await this.getMember(g, sub.memberId);
    const today = todayIST();
    const { state } = await this.state(g.tenantId, sub.memberId, today);
    const cur = state.current;
    if (!cur || cur.id !== subId || !['ACTIVE', 'ENDING_SOON', 'FROZEN'].includes(state.status)) {
      throw new BadRequestException('Only the current, running membership can be frozen');
    }
    if (activeFreeze(cur, today) || cur.freezes.some((f) => f.startDate > today && !f.endedOn)) {
      throw new BadRequestException('This membership already has a freeze. End it first');
    }
    const start = startDate ?? today;
    if (!isYmd(start)) throw new BadRequestException('Start date is not valid');
    if (start < today) throw new BadRequestException('A freeze cannot start in the past');
    if (start > effectiveEnd(cur)) throw new BadRequestException('A freeze must start before the membership ends');
    if (!Number.isInteger(days) || days < 1) throw new BadRequestException('Freeze for at least 1 day');
    const left = freezeDaysLeft(cur);
    if (left <= 0) throw new ForbiddenException('No freeze days left on this membership');
    if (days > left) throw new BadRequestException(`Only ${left} freeze day${left === 1 ? '' : 's'} left on this membership`);

    const f = await this.prisma.$transaction(async (tx) => {
      const fr = await tx.freeze.create({
        data: { tenantId: g.tenantId, subscriptionId: subId, memberId: sub.memberId, startDate: toDbDate(start), days, reason: reason?.trim() || null, createdById: actorId },
      });
      await this.audit.log({ tenantId: g.tenantId, actorId, action: 'membership.freeze', entity: 'freeze', entityId: fr.id, after: fr }, tx);
      await this.notifications.notify(
        member.userId,
        g.tenantId,
        'Membership frozen',
        `Your membership is frozen for ${days} day${days === 1 ? '' : 's'} from ${prettyDate(start)}. Your end date moves ahead by the same days.`,
        tx,
      );
      return fr;
    });
    return { freeze: f, newEndDate: addDays(effectiveEnd(cur), days) };
  }

  /** Ends a freeze early. Unused freeze days go back to the member. */
  async endFreeze(g: GymCtx, actorId: string, freezeId: string) {
    const f = await this.prisma.freeze.findFirst({ where: { id: freezeId, tenantId: g.tenantId } });
    if (!f) throw new NotFoundException('Freeze not found');
    await this.getMember(g, f.memberId);
    if (f.endedOn) throw new BadRequestException('This freeze has already ended');
    const today = todayIST();
    const start = f.startDate.toISOString().slice(0, 10) as Ymd;
    if (diffDays(start, today) >= f.days) throw new BadRequestException('This freeze has already ended');
    const after = await this.prisma.freeze.update({ where: { id: freezeId }, data: { endedOn: toDbDate(today < start ? start : today) } });
    await this.audit.log({ tenantId: g.tenantId, actorId, action: 'membership.unfreeze', entity: 'freeze', entityId: freezeId, before: f, after });
    return after;
  }

  entryFor(state: MemberState) {
    return entryDecision(state);
  }
}
