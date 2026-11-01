import { BadRequestException, Body, Controller, Get, NotFoundException, Post } from '@nestjs/common';
import { IsOptional, IsString, IsUUID, MaxLength } from 'class-validator';
import { AuthUser, CurrentUser, Gym, GymCtx, Staff } from '../common/auth';
import { config } from '../common/config';
import { todayIST } from '../common/dates';
import { PrismaService } from '../common/prisma.service';
import { MembershipsService } from '../memberships/memberships.service';
import { entryDecision } from '../memberships/status';
import { verifyQrToken } from './qr-token';

class ScanDto {
  @IsString() @MaxLength(200) token: string;
  @IsOptional() @IsUUID() branchId?: string;
}
class ManualDto {
  @IsUUID() memberId: string;
  @IsOptional() @IsUUID() branchId?: string;
}

const DUPLICATE_WINDOW_MS = 2 * 60_000;

@Staff()
@Controller('attendance')
export class AttendanceController {
  constructor(
    private prisma: PrismaService,
    private memberships: MembershipsService,
  ) {}

  @Post('scan')
  async scan(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Body() dto: ScanDto) {
    const memberId = verifyQrToken(config.qrSecret, dto.token);
    if (!memberId) throw new BadRequestException('QR code expired or not valid. Ask the member to refresh it');
    return this.checkIn(g, u, memberId, 'QR', dto.branchId);
  }

  @Post('manual')
  manual(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Body() dto: ManualDto) {
    return this.checkIn(g, u, dto.memberId, 'MANUAL', dto.branchId);
  }

  private async checkIn(g: GymCtx, u: AuthUser, memberId: string, method: 'QR' | 'MANUAL', branchId?: string) {
    // getMember scopes to this gym (and branch), so a QR from another gym is rejected.
    const member = await this.memberships.getMember(g, memberId).catch(() => {
      throw new NotFoundException('This member is not part of your gym');
    });
    if (branchId && !(await this.prisma.branch.findFirst({ where: { id: branchId, tenantId: g.tenantId } }))) {
      throw new BadRequestException('Unknown branch');
    }
    const { state } = await this.memberships.state(g.tenantId, memberId);
    const decision = entryDecision(state);
    const view = {
      member: { id: member.id, name: member.name, memberCode: member.memberCode, phone: member.phone },
      status: state.status,
      planName: state.current?.planName ?? null,
      endsOn: state.endsOn,
      daysLeft: state.daysLeft,
      due: state.due,
    };

    const recent = await this.prisma.attendanceEvent.findFirst({
      where: { tenantId: g.tenantId, memberId, scannedAt: { gte: new Date(Date.now() - DUPLICATE_WINDOW_MS) }, result: { not: 'BLOCKED' } },
      orderBy: { scannedAt: 'desc' },
    });
    if (recent && decision.result !== 'BLOCKED') {
      return { ...view, result: recent.result, reason: 'Already checked in', duplicate: true, eventId: recent.id };
    }
    const ev = await this.prisma.attendanceEvent.create({
      data: {
        tenantId: g.tenantId,
        memberId,
        branchId: branchId ?? member.branchId,
        result: decision.result,
        reason: decision.reason,
        method,
        scannedById: u.id,
      },
    });
    return { ...view, result: decision.result, reason: decision.reason, duplicate: false, eventId: ev.id };
  }

  @Get('today')
  async today(@Gym() g: GymCtx) {
    const start = new Date(`${todayIST()}T00:00:00+05:30`);
    const events = await this.prisma.attendanceEvent.findMany({
      where: { tenantId: g.tenantId, scannedAt: { gte: start } },
      include: { member: { select: { id: true, name: true, memberCode: true } } },
      orderBy: { scannedAt: 'desc' },
    });
    const twoHoursAgo = Date.now() - 2 * 3600_000;
    const inNow = new Set(events.filter((e) => e.result !== 'BLOCKED' && e.scannedAt.getTime() > twoHoursAgo).map((e) => e.memberId));
    return {
      checkins: events.filter((e) => e.result !== 'BLOCKED').length,
      inGymNow: inNow.size,
      blocked: events.filter((e) => e.result === 'BLOCKED').length,
      events,
    };
  }
}
