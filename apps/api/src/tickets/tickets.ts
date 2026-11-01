import { BadRequestException, Body, Controller, Get, Injectable, NotFoundException, Param, ParseUUIDPipe, Post, Query } from '@nestjs/common';
import { Prisma, TicketRoute } from '@prisma/client';
import { IsOptional, IsString, MaxLength, MinLength } from 'class-validator';
import { AuthUser, CurrentUser, Gym, GymCtx, Staff, SuperAdmin } from '../common/auth';
import { PrismaService } from '../common/prisma.service';
import { NotificationsService } from '../notifications/notifications';

/** Topics members pick in the app. App problems go to GymMantra, the rest to the gym. */
export const TICKET_TOPICS: Record<string, TicketRoute> = {
  membership: 'GYM',
  payment: 'GYM',
  checkin: 'GYM',
  facility: 'GYM',
  trainer: 'GYM',
  other_gym: 'GYM',
  app_login: 'GYMMANTRA',
  app_bug: 'GYMMANTRA',
  app_other: 'GYMMANTRA',
};

export class MessageDto {
  @IsString() @MinLength(1) @MaxLength(4000) body: string;
  @IsOptional() @IsString() @MaxLength(500) attachmentUrl?: string;
}

@Injectable()
export class TicketsService {
  constructor(
    private prisma: PrismaService,
    private notifications: NotificationsService,
  ) {}

  list(where: Prisma.TicketWhereInput) {
    return this.prisma.ticket.findMany({
      where,
      include: { messages: { orderBy: { createdAt: 'desc' }, take: 1 } },
      orderBy: { updatedAt: 'desc' },
      take: 200,
    });
  }

  async get(where: Prisma.TicketWhereInput) {
    const t = await this.prisma.ticket.findFirst({ where, include: { messages: { orderBy: { createdAt: 'asc' } } } });
    if (!t) throw new NotFoundException('Ticket not found');
    const authors = await this.prisma.user.findMany({ where: { id: { in: [...new Set(t.messages.map((m) => m.authorId)), t.userId] } }, select: { id: true, name: true, photoUrl: true } });
    const member = t.memberId ? await this.prisma.member.findUnique({ where: { id: t.memberId }, select: { id: true, name: true, memberCode: true, phone: true } }) : null;
    return { ...t, member, authors };
  }

  async reply(where: Prisma.TicketWhereInput, authorId: string, fromStaff: boolean, dto: MessageDto) {
    const t = await this.prisma.ticket.findFirst({ where });
    if (!t) throw new NotFoundException('Ticket not found');
    const msg = await this.prisma.ticketMessage.create({ data: { ticketId: t.id, authorId, fromStaff, body: dto.body.trim(), attachmentUrl: dto.attachmentUrl } });
    await this.prisma.ticket.update({ where: { id: t.id }, data: { status: 'OPEN', updatedAt: new Date() } });
    if (fromStaff) await this.notifications.notify(t.userId, t.tenantId, 'New reply on your ticket', t.subject);
    return msg;
  }

  async resolve(where: Prisma.TicketWhereInput) {
    const t = await this.prisma.ticket.findFirst({ where });
    if (!t) throw new NotFoundException('Ticket not found');
    if (t.status === 'RESOLVED') throw new BadRequestException('Already resolved');
    await this.notifications.notify(t.userId, t.tenantId, 'Ticket resolved', t.subject);
    return this.prisma.ticket.update({ where: { id: t.id }, data: { status: 'RESOLVED' } });
  }
}

/** Gym staff see only tickets from their own gym's members about gym topics. */
@Staff()
@Controller('tickets')
export class GymTicketsController {
  constructor(private svc: TicketsService) {}

  @Get()
  list(@Gym() g: GymCtx, @Query('status') status?: string) {
    return this.svc.list({ tenantId: g.tenantId, routedTo: 'GYM', ...(status === 'OPEN' || status === 'RESOLVED' ? { status } : {}) });
  }

  @Get(':id')
  get(@Gym() g: GymCtx, @Param('id', ParseUUIDPipe) id: string) {
    return this.svc.get({ id, tenantId: g.tenantId, routedTo: 'GYM' });
  }

  @Post(':id/messages')
  reply(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: MessageDto) {
    return this.svc.reply({ id, tenantId: g.tenantId, routedTo: 'GYM' }, u.id, true, dto);
  }

  @Post(':id/resolve')
  resolve(@Gym() g: GymCtx, @Param('id', ParseUUIDPipe) id: string) {
    return this.svc.resolve({ id, tenantId: g.tenantId, routedTo: 'GYM' });
  }
}

/** GymMantra support sees only app-problem tickets. */
@SuperAdmin()
@Controller('super/tickets')
export class SuperTicketsController {
  constructor(private svc: TicketsService) {}

  @Get()
  list(@Query('status') status?: string) {
    return this.svc.list({ routedTo: 'GYMMANTRA', ...(status === 'OPEN' || status === 'RESOLVED' ? { status } : {}) });
  }

  @Get(':id')
  get(@Param('id', ParseUUIDPipe) id: string) {
    return this.svc.get({ id, routedTo: 'GYMMANTRA' });
  }

  @Post(':id/messages')
  reply(@CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: MessageDto) {
    return this.svc.reply({ id, routedTo: 'GYMMANTRA' }, u.id, true, dto);
  }

  @Post(':id/resolve')
  resolve(@Param('id', ParseUUIDPipe) id: string) {
    return this.svc.resolve({ id, routedTo: 'GYMMANTRA' });
  }
}
