import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  HttpCode,
  NotFoundException,
  Param,
  ParseUUIDPipe,
  Patch,
  Post,
  Query,
} from '@nestjs/common';
import { IsIn, IsOptional, IsString, IsUUID, MaxLength, MinLength } from 'class-validator';
import { AuthUser, CurrentUser } from '../common/auth';
import { config } from '../common/config';
import { todayIST, toYmd } from '../common/dates';
import { PrismaService } from '../common/prisma.service';
import { makeQrToken } from '../attendance/qr-token';
import { loadSubs } from '../memberships/loader';
import { computeState, freezeDaysLeft } from '../memberships/status';
import { MessageDto, TICKET_TOPICS, TicketsService } from '../tickets/tickets';

class JoinDto {
  @IsString() @MinLength(3) @MaxLength(20) gymCode: string;
  @IsOptional() @IsUUID() branchId?: string;
}
class ProfileDto {
  @IsOptional() @IsString() @MinLength(2) @MaxLength(80) name?: string;
  @IsOptional() @IsIn(['en', 'hi']) language?: string;
  @IsOptional() @IsString() @MaxLength(500) photoUrl?: string;
}
class NewTicketDto {
  @IsIn(Object.keys(TICKET_TOPICS)) topic: string;
  @IsString() @MinLength(3) @MaxLength(120) subject: string;
  @IsString() @MinLength(1) @MaxLength(4000) body: string;
  @IsOptional() @IsUUID() memberId?: string;
  @IsOptional() @IsString() @MaxLength(500) attachmentUrl?: string;
}

/** Endpoints for the member app. A member only ever sees their own data. */
@Controller('me')
export class MeController {
  constructor(
    private prisma: PrismaService,
    private tickets: TicketsService,
  ) {}

  private async myMember(userId: string, memberId: string) {
    const m = await this.prisma.member.findFirst({ where: { id: memberId, userId, archived: false }, include: { tenant: true } });
    if (!m) throw new NotFoundException('Membership not found');
    return m;
  }

  @Get('gyms')
  async gyms(@CurrentUser() u: AuthUser) {
    const members = await this.prisma.member.findMany({ where: { userId: u.id, archived: false }, include: { tenant: true } });
    const today = todayIST();
    const out = [];
    for (const m of members) {
      const subs = (await loadSubs(this.prisma, m.tenantId, [m.id])).get(m.id) ?? [];
      const st = computeState(subs, today);
      out.push({
        memberId: m.id,
        memberCode: m.memberCode,
        gym: { id: m.tenant.id, name: m.tenant.name, logoUrl: m.tenant.logoUrl, phone: m.tenant.phone, whatsappNumber: m.tenant.whatsappNumber, address: m.tenant.address },
        status: st.status,
        planName: st.current?.planName ?? st.upcoming?.planName ?? null,
        daysLeft: st.daysLeft,
        endsOn: st.endsOn,
      });
    }
    const pending = await this.prisma.joinRequest.findMany({ where: { userId: u.id, status: 'PENDING' }, include: { tenant: { select: { id: true, name: true } } } });
    return { memberships: out, pendingRequests: pending.map((p) => ({ id: p.id, gym: p.tenant, createdAt: p.createdAt })) };
  }

  @Get('gym-lookup')
  async lookup(@Query('code') code = '') {
    const t = await this.prisma.tenant.findUnique({ where: { gymCode: code.trim().toUpperCase() }, include: { branches: { select: { id: true, name: true, address: true } } } });
    if (!t || t.status === 'SUSPENDED') throw new NotFoundException('No gym found with this code');
    return { id: t.id, name: t.name, logoUrl: t.logoUrl, address: t.address, branches: t.branches };
  }

  @Post('join')
  async join(@CurrentUser() u: AuthUser, @Body() dto: JoinDto) {
    const t = await this.prisma.tenant.findUnique({ where: { gymCode: dto.gymCode.trim().toUpperCase() } });
    if (!t || t.status === 'SUSPENDED') throw new NotFoundException('No gym found with this code');
    if (dto.branchId && !(await this.prisma.branch.findFirst({ where: { id: dto.branchId, tenantId: t.id } }))) {
      throw new BadRequestException('Unknown branch');
    }
    if (await this.prisma.member.findFirst({ where: { tenantId: t.id, userId: u.id } })) throw new ConflictException('You are already a member of this gym');
    const user = await this.prisma.user.findUniqueOrThrow({ where: { id: u.id } });
    if (!user.phone) throw new BadRequestException('Add your mobile number in Profile first, so the gym can find you');
    const existing = await this.prisma.joinRequest.findFirst({ where: { tenantId: t.id, userId: u.id, status: 'PENDING' } });
    if (existing) return existing;
    return this.prisma.joinRequest.create({ data: { tenantId: t.id, userId: u.id, branchId: dto.branchId } });
  }

  /** "My membership" screen. Shows what the gym entered, and who updated it. */
  @Get('memberships/:memberId')
  async membership(@CurrentUser() u: AuthUser, @Param('memberId', ParseUUIDPipe) memberId: string) {
    const m = await this.myMember(u.id, memberId);
    const subs = (await loadSubs(this.prisma, m.tenantId, [m.id])).get(m.id) ?? [];
    const st = computeState(subs, todayIST());
    const cur = st.current;
    const staffIds = [...new Set(subs.map((s) => s.createdById))];
    const staff = await this.prisma.user.findMany({ where: { id: { in: staffIds } }, select: { id: true, name: true } });
    const nameOf = (id: string) => staff.find((s) => s.id === id)?.name ?? 'Gym staff';
    const replaced = new Set(subs.map((s) => s.replacesId).filter(Boolean));
    const visible = subs.filter((s) => !replaced.has(s.id));
    return {
      gym: { id: m.tenant.id, name: m.tenant.name, phone: m.tenant.phone, whatsappNumber: m.tenant.whatsappNumber, address: m.tenant.address },
      memberCode: m.memberCode,
      status: st.status,
      daysLeft: st.daysLeft,
      endsOn: st.endsOn,
      due: st.due,
      frozenUntil: st.frozenUntil,
      current: cur
        ? {
            planName: cur.planName,
            startDate: cur.startDate,
            endDate: cur.endDate,
            total: cur.total,
            discount: cur.discount,
            paid: cur.paid,
            paymentModes: [...new Set(cur.payments.map((p) => p.mode))],
            freezeDaysLeft: freezeDaysLeft(cur),
            freezes: cur.freezes,
            updatedBy: nameOf(cur.createdById),
            updatedAt: cur.createdAt,
          }
        : null,
      history: visible
        .sort((a, b) => (a.startDate < b.startDate ? 1 : -1))
        .map((s) => ({ planName: s.planName, startDate: s.startDate, endDate: s.endDate, total: s.total, paid: s.paid, updatedBy: nameOf(s.createdById), updatedAt: s.createdAt })),
    };
  }

  @Get('gyms/:tenantId/plans')
  async plans(@CurrentUser() u: AuthUser, @Param('tenantId', ParseUUIDPipe) tenantId: string) {
    const isMember = await this.prisma.member.findFirst({ where: { tenantId, userId: u.id } });
    const pending = await this.prisma.joinRequest.findFirst({ where: { tenantId, userId: u.id } });
    if (!isMember && !pending) throw new ForbiddenException('Join this gym to see its plans');
    return this.prisma.membershipPlan.findMany({
      where: { tenantId, showInApp: true, active: true },
      select: { id: true, name: true, months: true, price: true, joiningFee: true, freezeDays: true, features: true },
      orderBy: { months: 'asc' },
    });
  }

  @Get('qr/:memberId')
  async qr(@CurrentUser() u: AuthUser, @Param('memberId', ParseUUIDPipe) memberId: string) {
    const m = await this.myMember(u.id, memberId);
    const start = new Date(`${todayIST().slice(0, 7)}-01T00:00:00+05:30`);
    const visits = await this.prisma.attendanceEvent.count({ where: { memberId: m.id, result: { not: 'BLOCKED' }, scannedAt: { gte: start } } });
    return { ...makeQrToken(config.qrSecret, m.id), memberCode: m.memberCode, visitsThisMonth: visits };
  }

  @Get('attendance/:memberId')
  async attendance(@CurrentUser() u: AuthUser, @Param('memberId', ParseUUIDPipe) memberId: string) {
    const m = await this.myMember(u.id, memberId);
    return this.prisma.attendanceEvent.findMany({
      where: { memberId: m.id, result: { not: 'BLOCKED' } },
      select: { id: true, scannedAt: true, result: true },
      orderBy: { scannedAt: 'desc' },
      take: 100,
    });
  }

  @Patch('profile')
  async profile(@CurrentUser() u: AuthUser, @Body() dto: ProfileDto) {
    const user = await this.prisma.user.update({ where: { id: u.id }, data: dto });
    return { id: user.id, name: user.name, language: user.language, photoUrl: user.photoUrl };
  }

  // ---- Help & Support (no email address is ever shown) ----

  @Post('tickets')
  async newTicket(@CurrentUser() u: AuthUser, @Body() dto: NewTicketDto) {
    const route = TICKET_TOPICS[dto.topic];
    let tenantId: string | null = null;
    let memberId: string | null = null;
    if (route === 'GYM') {
      if (!dto.memberId) throw new BadRequestException('Choose your gym');
      const m = await this.myMember(u.id, dto.memberId);
      tenantId = m.tenantId;
      memberId = m.id;
    }
    return this.prisma.ticket.create({
      data: {
        tenantId,
        memberId,
        userId: u.id,
        topic: dto.topic,
        subject: dto.subject.trim(),
        routedTo: route,
        messages: { create: { authorId: u.id, body: dto.body.trim(), attachmentUrl: dto.attachmentUrl } },
      },
    });
  }

  @Get('tickets')
  myTickets(@CurrentUser() u: AuthUser) {
    return this.tickets.list({ userId: u.id });
  }

  @Get('tickets/:id')
  ticket(@CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string) {
    return this.tickets.get({ id, userId: u.id });
  }

  @Post('tickets/:id/messages')
  reply(@CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: MessageDto) {
    return this.tickets.reply({ id, userId: u.id }, u.id, false, dto);
  }

  @Get('notifications')
  notifications(@CurrentUser() u: AuthUser) {
    return this.prisma.notification.findMany({ where: { userId: u.id }, orderBy: { createdAt: 'desc' }, take: 50 });
  }

  @HttpCode(200)
  @Post('notifications/read')
  async readAll(@CurrentUser() u: AuthUser) {
    await this.prisma.notification.updateMany({ where: { userId: u.id, readAt: null }, data: { readAt: new Date() } });
    return { ok: true };
  }

  // ---- Privacy ----

  @Get('export')
  async export(@CurrentUser() u: AuthUser) {
    const user = await this.prisma.user.findUniqueOrThrow({
      where: { id: u.id },
      select: { name: true, email: true, phone: true, language: true, createdAt: true },
    });
    const members = await this.prisma.member.findMany({ where: { userId: u.id }, include: { tenant: { select: { name: true } } } });
    const subs = await this.prisma.subscription.findMany({ where: { memberId: { in: members.map((m) => m.id) } }, include: { payments: true } });
    const attendance = await this.prisma.attendanceEvent.findMany({ where: { memberId: { in: members.map((m) => m.id) } }, select: { scannedAt: true, result: true } });
    const tickets = await this.prisma.ticket.findMany({ where: { userId: u.id }, include: { messages: true } });
    return {
      user,
      gyms: members.map((m) => ({ gym: m.tenant.name, memberCode: m.memberCode, joinedOn: toYmd(m.joinedOn) })),
      memberships: subs.map((s) => ({ plan: s.planName, start: toYmd(s.startDate), end: toYmd(s.endDate), total: s.total, payments: s.payments.map((p) => ({ amount: p.amount, mode: p.mode, at: p.receivedAt })) })),
      attendance,
      tickets,
    };
  }

  /** Deletes the login account. Gym records stay with the gym but are unlinked. */
  @Delete()
  async deleteAccount(@CurrentUser() u: AuthUser) {
    const staff = await this.prisma.staff.count({ where: { userId: u.id, active: true } });
    if (staff) throw new ForbiddenException('Gym staff accounts cannot be deleted here. Ask the gym owner to remove you first');
    await this.prisma.$transaction([
      this.prisma.member.updateMany({ where: { userId: u.id }, data: { userId: null } }),
      this.prisma.joinRequest.deleteMany({ where: { userId: u.id } }),
      this.prisma.notification.deleteMany({ where: { userId: u.id } }),
      this.prisma.user.update({
        where: { id: u.id },
        data: { name: 'Deleted user', email: null, phone: null, passwordHash: null, googleSub: null, photoUrl: null },
      }),
    ]);
    return { ok: true };
  }
}
