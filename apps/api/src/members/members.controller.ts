import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  Get,
  NotFoundException,
  Param,
  ParseUUIDPipe,
  Patch,
  Post,
  Query,
} from '@nestjs/common';
import { Type } from 'class-transformer';
import { ArrayMaxSize, IsArray, IsBoolean, IsEmail, IsIn, IsOptional, IsString, IsUUID, MaxLength, MinLength, ValidateNested } from 'class-validator';
import { AuditService } from '../common/audit.service';
import { AuthUser, CurrentUser, Gym, GymCtx, Staff } from '../common/auth';
import { isYmd, toDbDate, todayIST, toYmd } from '../common/dates';
import { normalizeEmail, normalizePhone } from '../common/phone';
import { PrismaService } from '../common/prisma.service';
import { assertUnder } from '../gyms/limits';
import { loadSubs } from '../memberships/loader';
import { MembershipsService } from '../memberships/memberships.service';
import { computeState, entryDecision, freezeDaysLeft, MembershipStatus } from '../memberships/status';
import { NotificationsService, prettyDate, rupees, whatsappLink } from '../notifications/notifications';

class MemberDto {
  @IsString() @MinLength(2) @MaxLength(80) name: string;
  @IsString() phone: string;
  @IsOptional() @IsEmail() email?: string;
  @IsOptional() @IsIn(['male', 'female', 'other']) gender?: string;
  @IsOptional() @IsUUID() branchId?: string;
  @IsOptional() @IsString() joinedOn?: string;
  @IsOptional() @IsString() @MaxLength(500) notes?: string;
}

class UpdateMemberDto {
  @IsOptional() @IsString() @MinLength(2) @MaxLength(80) name?: string;
  @IsOptional() @IsString() phone?: string;
  @IsOptional() @IsEmail() email?: string;
  @IsOptional() @IsIn(['male', 'female', 'other']) gender?: string;
  @IsOptional() @IsUUID() branchId?: string;
  @IsOptional() @IsString() @MaxLength(500) notes?: string;
  @IsOptional() @IsBoolean() archived?: boolean;
}

class ImportRow {
  @IsString() name: string;
  @IsString() phone: string;
  @IsOptional() @IsString() email?: string;
  @IsOptional() @IsString() gender?: string;
  @IsOptional() @IsString() joinedOn?: string;
}
class ImportDto {
  @IsArray() @ArrayMaxSize(2000) @ValidateNested({ each: true }) @Type(() => ImportRow) rows: ImportRow[];
  @IsOptional() @IsUUID() branchId?: string;
}

class RemindDto {
  @IsArray() @ArrayMaxSize(500) @IsUUID('all', { each: true }) memberIds: string[];
}

class ApproveDto {
  @IsOptional() @IsUUID() branchId?: string;
}

const TABS = ['all', 'active', 'ending', 'expired', 'frozen', 'due', 'noplan'] as const;
type Tab = (typeof TABS)[number];

function inTab(tab: Tab, status: MembershipStatus, due: number) {
  switch (tab) {
    case 'all':
      return true;
    case 'active':
      return status === 'ACTIVE';
    case 'ending':
      return status === 'ENDING_SOON';
    case 'expired':
      return status === 'EXPIRED';
    case 'frozen':
      return status === 'FROZEN';
    case 'due':
      return due > 0;
    case 'noplan':
      return status === 'NO_PLAN' || status === 'UPCOMING';
  }
}

@Staff()
@Controller()
export class MembersController {
  constructor(
    private prisma: PrismaService,
    private audit: AuditService,
    private memberships: MembershipsService,
    private notifications: NotificationsService,
  ) {}

  private async summaries(g: GymCtx, includeArchived = false) {
    const members = await this.prisma.member.findMany({
      where: { tenantId: g.tenantId, ...(includeArchived ? {} : { archived: false }), ...this.memberships.branchFilter(g) },
      include: { user: { select: { photoUrl: true } } },
      orderBy: { name: 'asc' },
    });
    const subs = await loadSubs(this.prisma, g.tenantId, members.map((m) => m.id));
    const today = todayIST();
    return members.map((m) => {
      const st = computeState(subs.get(m.id) ?? [], today);
      return {
        id: m.id,
        name: m.name,
        phone: m.phone,
        email: m.email,
        memberCode: m.memberCode,
        branchId: m.branchId,
        photoUrl: m.user?.photoUrl ?? null,
        hasApp: !!m.userId,
        archived: m.archived,
        status: st.status,
        planName: st.current?.planName ?? st.upcoming?.planName ?? null,
        endsOn: st.endsOn,
        daysLeft: st.daysLeft,
        due: st.due,
      };
    });
  }

  @Get('dashboard')
  async dashboard(@Gym() g: GymCtx) {
    const all = await this.summaries(g);
    const today = todayIST();
    const startOfDayUtc = new Date(`${today}T00:00:00+05:30`);
    const [payments, joinPending, checkins, openTickets] = await Promise.all([
      this.prisma.payment.aggregate({ where: { tenantId: g.tenantId, receivedAt: { gte: startOfDayUtc } }, _sum: { amount: true }, _count: true }),
      this.prisma.joinRequest.count({ where: { tenantId: g.tenantId, status: 'PENDING' } }),
      this.prisma.attendanceEvent.count({ where: { tenantId: g.tenantId, scannedAt: { gte: startOfDayUtc }, result: { not: 'BLOCKED' } } }),
      this.prisma.ticket.count({ where: { tenantId: g.tenantId, routedTo: 'GYM', status: 'OPEN' } }),
    ]);
    const count = (s: MembershipStatus) => all.filter((m) => m.status === s).length;
    return {
      totals: {
        members: all.length,
        active: count('ACTIVE'),
        endingSoon: count('ENDING_SOON'),
        expired: count('EXPIRED'),
        frozen: count('FROZEN'),
        noPlan: count('NO_PLAN') + count('UPCOMING'),
        dueAmount: all.reduce((n, m) => n + m.due, 0),
        dueMembers: all.filter((m) => m.due > 0).length,
      },
      today: { collected: payments._sum.amount ?? 0, payments: payments._count, checkins },
      joinPending,
      openTickets,
      renewalsDue: all
        .filter((m) => m.status === 'ENDING_SOON' || (m.status === 'EXPIRED' && (m.daysLeft ?? -999) >= -30))
        .sort((a, b) => (a.daysLeft ?? 0) - (b.daysLeft ?? 0))
        .slice(0, 20),
    };
  }

  @Get('members')
  async list(@Gym() g: GymCtx, @Query('tab') tab = 'all', @Query('q') q = '') {
    if (!TABS.includes(tab as Tab)) throw new BadRequestException('Unknown tab');
    const all = await this.summaries(g);
    const needle = q.trim().toLowerCase();
    const digits = needle.replace(/[^\d]/g, '');
    const rows = all.filter(
      (m) =>
        inTab(tab as Tab, m.status, m.due) &&
        (!needle ||
          m.name.toLowerCase().includes(needle) ||
          m.memberCode.toLowerCase().includes(needle) ||
          (digits.length >= 3 && m.phone.includes(digits))),
    );
    const counts = Object.fromEntries(TABS.map((t) => [t, all.filter((m) => inTab(t, m.status, m.due)).length]));
    return { rows, counts };
  }

  @Post('members')
  async create(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Body() dto: MemberDto) {
    await assertUnder(this.prisma, g.tenantId, 'members');
    const phone = normalizePhone(dto.phone);
    if (!phone) throw new BadRequestException('Enter a valid 10-digit mobile number');
    if (dto.joinedOn && !isYmd(dto.joinedOn)) throw new BadRequestException('Joining date is not valid');
    await this.checkBranch(g, dto.branchId);
    if (await this.prisma.member.findUnique({ where: { tenantId_phone: { tenantId: g.tenantId, phone } } })) {
      throw new ConflictException('A member with this mobile number already exists');
    }
    const user = await this.prisma.user.findUnique({ where: { phone } });
    const m = await this.prisma.$transaction(async (tx) => {
      const t = await tx.tenant.update({ where: { id: g.tenantId }, data: { nextMemberNumber: { increment: 1 } } });
      const created = await tx.member.create({
        data: {
          tenantId: g.tenantId,
          userId: user?.id ?? null,
          memberCode: `${t.memberCodePrefix}-${t.nextMemberNumber - 1}`,
          name: dto.name.trim(),
          phone,
          email: dto.email ? normalizeEmail(dto.email) : null,
          gender: dto.gender,
          branchId: dto.branchId ?? (g.role === 'FRONT_DESK' && g.branchIds.length ? g.branchIds[0] : null),
          joinedOn: toDbDate(dto.joinedOn ?? todayIST()),
          notes: dto.notes,
        },
      });
      await this.audit.log({ tenantId: g.tenantId, actorId: u.id, action: 'member.create', entity: 'member', entityId: created.id, after: created }, tx);
      return created;
    });
    return m;
  }

  @Post('members/import')
  async import(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Body() dto: ImportDto) {
    await this.checkBranch(g, dto.branchId);
    const results: { row: number; ok: boolean; error?: string; memberCode?: string }[] = [];
    for (const [i, r] of dto.rows.entries()) {
      try {
        const m = await this.create(g, u, { name: r.name, phone: r.phone, email: normalizeEmail(r.email) ?? undefined, branchId: dto.branchId, joinedOn: isYmd(r.joinedOn) ? r.joinedOn : undefined, gender: ['male', 'female', 'other'].includes((r.gender ?? '').toLowerCase()) ? r.gender!.toLowerCase() : undefined });
        results.push({ row: i + 1, ok: true, memberCode: m.memberCode });
      } catch (e: any) {
        results.push({ row: i + 1, ok: false, error: e?.response?.message ?? e?.message ?? 'Failed' });
      }
    }
    return { added: results.filter((r) => r.ok).length, failed: results.filter((r) => !r.ok).length, results };
  }

  @Get('members/:id')
  async detail(@Gym() g: GymCtx, @Param('id', ParseUUIDPipe) id: string) {
    const m = await this.memberships.getMember(g, id);
    const { subs, state } = await this.memberships.state(g.tenantId, id);
    const staffIds = new Set<string>();
    subs.forEach((s) => {
      staffIds.add(s.createdById);
      s.payments.forEach((p) => staffIds.add(p.receivedById));
    });
    const people = await this.prisma.user.findMany({ where: { id: { in: [...staffIds] } }, select: { id: true, name: true } });
    const nameOf = (uid: string) => people.find((p) => p.id === uid)?.name ?? 'Staff';
    const replaced = new Set(subs.map((s) => s.replacesId).filter(Boolean));
    const attendance = await this.prisma.attendanceEvent.findMany({ where: { tenantId: g.tenantId, memberId: id }, orderBy: { scannedAt: 'desc' }, take: 30 });
    const user = m.userId ? await this.prisma.user.findUnique({ where: { id: m.userId }, select: { photoUrl: true } }) : null;
    return {
      member: { ...m, joinedOn: toYmd(m.joinedOn), photoUrl: user?.photoUrl ?? null, hasApp: !!m.userId },
      state: {
        status: state.status,
        daysLeft: state.daysLeft,
        endsOn: state.endsOn,
        due: state.due,
        frozenUntil: state.frozenUntil,
        currentId: state.current?.id ?? null,
        upcomingId: state.upcoming?.id ?? null,
        freezeDaysLeft: state.current ? freezeDaysLeft(state.current) : 0,
        entry: entryDecision(state),
      },
      history: [...subs]
        .sort((a, b) => (new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()))
        .map((s) => ({
          ...s,
          createdByName: nameOf(s.createdById),
          superseded: replaced.has(s.id),
          due: Math.max(0, s.total - s.paid),
          payments: s.payments.map((p) => ({ ...p, receivedByName: nameOf(p.receivedById) })),
        })),
      attendance,
    };
  }

  @Patch('members/:id')
  async update(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: UpdateMemberDto) {
    const before = await this.memberships.getMember(g, id);
    const data: Record<string, unknown> = { ...dto };
    if (dto.phone !== undefined) {
      const phone = normalizePhone(dto.phone);
      if (!phone) throw new BadRequestException('Enter a valid 10-digit mobile number');
      const clash = await this.prisma.member.findUnique({ where: { tenantId_phone: { tenantId: g.tenantId, phone } } });
      if (clash && clash.id !== id) throw new ConflictException('Another member has this mobile number');
      data.phone = phone;
    }
    if (dto.email !== undefined) data.email = dto.email ? normalizeEmail(dto.email) : null;
    if (dto.branchId) await this.checkBranch(g, dto.branchId);
    const after = await this.prisma.member.update({ where: { id }, data });
    await this.audit.log({ tenantId: g.tenantId, actorId: u.id, action: 'member.update', entity: 'member', entityId: id, before, after });
    return after;
  }

  /** WhatsApp renewal reminders from the gym's own WhatsApp: one ready-to-send link per member. */
  @Post('members/reminders')
  async remind(@Gym() g: GymCtx, @Body() dto: RemindDto) {
    const tenant = await this.prisma.tenant.findUniqueOrThrow({ where: { id: g.tenantId } });
    const all = await this.summaries(g);
    const picked = all.filter((m) => dto.memberIds.includes(m.id));
    return picked.map((m) => {
      const lines =
        m.status === 'EXPIRED'
          ? `Hi ${m.name}, your ${m.planName ?? ''} membership at ${tenant.name} ended on ${prettyDate(m.endsOn!)}. Renew today to keep training!`
          : m.status === 'ENDING_SOON'
            ? `Hi ${m.name}, your ${m.planName ?? ''} membership at ${tenant.name} ends on ${prettyDate(m.endsOn!)} (${m.daysLeft} day${m.daysLeft === 1 ? '' : 's'} left). Visit the front desk to renew.`
            : `Hi ${m.name}, a reminder from ${tenant.name}.`;
      const dueLine = m.due > 0 ? `\nPayment due: ${rupees(m.due)}` : '';
      return { memberId: m.id, name: m.name, link: whatsappLink(m.phone, `${lines.replace(/\s+/g, ' ')}${dueLine}\n- ${tenant.name}`) };
    });
  }

  // ---- Join requests from the member app ----

  @Get('join-requests')
  async joinRequests(@Gym() g: GymCtx, @Query('status') status = 'PENDING') {
    const s = ['PENDING', 'APPROVED', 'DECLINED'].includes(status) ? (status as 'PENDING') : 'PENDING';
    return this.prisma.joinRequest.findMany({
      where: { tenantId: g.tenantId, status: s },
      include: { user: { select: { id: true, name: true, phone: true, email: true, photoUrl: true } } },
      orderBy: { createdAt: 'desc' },
    });
  }

  @Post('join-requests/:id/approve')
  async approve(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: ApproveDto) {
    const jr = await this.prisma.joinRequest.findFirst({ where: { id, tenantId: g.tenantId }, include: { user: true } });
    if (!jr) throw new NotFoundException('Request not found');
    if (jr.status !== 'PENDING') throw new BadRequestException('This request was already handled');
    const branchId = dto.branchId ?? jr.branchId ?? undefined;
    await this.checkBranch(g, branchId);
    const tenant = await this.prisma.tenant.findUniqueOrThrow({ where: { id: g.tenantId } });

    // If the gym already added this person by hand, link that record.
    let member = jr.user.phone ? await this.prisma.member.findUnique({ where: { tenantId_phone: { tenantId: g.tenantId, phone: jr.user.phone } } }) : null;
    if (member?.userId && member.userId !== jr.userId) throw new ConflictException('This mobile number belongs to another member');
    if (member) {
      member = await this.prisma.member.update({ where: { id: member.id }, data: { userId: jr.userId } });
    } else {
      if (!jr.user.phone) throw new BadRequestException('This person has no mobile number on their account');
      member = await this.create(g, u, { name: jr.user.name, phone: jr.user.phone, email: jr.user.email ?? undefined, branchId });
      member = await this.prisma.member.update({ where: { id: member.id }, data: { userId: jr.userId } });
    }
    await this.prisma.joinRequest.update({ where: { id }, data: { status: 'APPROVED', decidedById: u.id, decidedAt: new Date() } });
    await this.audit.log({ tenantId: g.tenantId, actorId: u.id, action: 'join.approve', entity: 'join_request', entityId: id, after: { memberId: member.id } });
    await this.notifications.notify(jr.userId, g.tenantId, 'Welcome!', `${tenant.name} approved your request. Your member ID is ${member.memberCode}.`);
    return member;
  }

  @Post('join-requests/:id/decline')
  async decline(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string) {
    const jr = await this.prisma.joinRequest.findFirst({ where: { id, tenantId: g.tenantId } });
    if (!jr) throw new NotFoundException('Request not found');
    if (jr.status !== 'PENDING') throw new BadRequestException('This request was already handled');
    await this.prisma.joinRequest.update({ where: { id }, data: { status: 'DECLINED', decidedById: u.id, decidedAt: new Date() } });
    await this.audit.log({ tenantId: g.tenantId, actorId: u.id, action: 'join.decline', entity: 'join_request', entityId: id });
    return { ok: true };
  }

  private async checkBranch(g: GymCtx, branchId?: string) {
    if (!branchId) return;
    const b = await this.prisma.branch.findFirst({ where: { id: branchId, tenantId: g.tenantId } });
    if (!b) throw new BadRequestException('Unknown branch');
    if (g.role === 'FRONT_DESK' && g.branchIds.length && !g.branchIds.includes(branchId)) {
      throw new BadRequestException('You can only add members to your own branch');
    }
  }
}
