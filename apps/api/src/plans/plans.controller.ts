import { Body, Controller, Get, NotFoundException, Param, ParseUUIDPipe, Patch, Post } from '@nestjs/common';
import { ArrayMaxSize, IsArray, IsBoolean, IsInt, IsOptional, IsString, Max, MaxLength, Min, MinLength } from 'class-validator';
import { AuditService } from '../common/audit.service';
import { AuthUser, CurrentUser, Gym, GymCtx, Staff } from '../common/auth';
import { todayIST } from '../common/dates';
import { PrismaService } from '../common/prisma.service';
import { loadSubs } from '../memberships/loader';
import { computeState } from '../memberships/status';

class PlanDto {
  @IsString() @MinLength(2) @MaxLength(60) name: string;
  @IsInt() @Min(1) @Max(60) months: number;
  @IsInt() @Min(0) @Max(10_000_000) price: number;
  @IsOptional() @IsInt() @Min(0) @Max(1_000_000) joiningFee?: number;
  @IsOptional() @IsInt() @Min(0) @Max(365) freezeDays?: number;
  @IsOptional() @IsArray() @ArrayMaxSize(12) @IsString({ each: true }) @MaxLength(80, { each: true }) features?: string[];
  @IsOptional() @IsBoolean() showInApp?: boolean;
  @IsOptional() @IsBoolean() active?: boolean;
}

class UpdatePlanDto {
  @IsOptional() @IsString() @MinLength(2) @MaxLength(60) name?: string;
  @IsOptional() @IsInt() @Min(1) @Max(60) months?: number;
  @IsOptional() @IsInt() @Min(0) @Max(10_000_000) price?: number;
  @IsOptional() @IsInt() @Min(0) @Max(1_000_000) joiningFee?: number;
  @IsOptional() @IsInt() @Min(0) @Max(365) freezeDays?: number;
  @IsOptional() @IsArray() @ArrayMaxSize(12) @IsString({ each: true }) @MaxLength(80, { each: true }) features?: string[];
  @IsOptional() @IsBoolean() showInApp?: boolean;
  @IsOptional() @IsBoolean() active?: boolean;
}

@Controller('plans')
export class PlansController {
  constructor(
    private prisma: PrismaService,
    private audit: AuditService,
  ) {}

  /** All plans of this gym, with how many members are currently on each. */
  @Staff()
  @Get()
  async list(@Gym() g: GymCtx) {
    const plans = await this.prisma.membershipPlan.findMany({ where: { tenantId: g.tenantId }, orderBy: [{ active: 'desc' }, { months: 'asc' }] });
    const members = await this.prisma.member.findMany({ where: { tenantId: g.tenantId, archived: false }, select: { id: true } });
    const subs = await loadSubs(this.prisma, g.tenantId, members.map((m) => m.id));
    const today = todayIST();
    const counts = new Map<string, number>();
    for (const list of subs.values()) {
      const st = computeState(list, today);
      const pid = st.current?.planId;
      if (pid && ['ACTIVE', 'ENDING_SOON', 'FROZEN'].includes(st.status)) {
        counts.set(pid, (counts.get(pid) ?? 0) + 1);
      }
    }
    return plans.map((p) => ({ ...p, activeMembers: counts.get(p.id) ?? 0 }));
  }

  @Staff('OWNER')
  @Post()
  async create(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Body() dto: PlanDto) {
    const p = await this.prisma.membershipPlan.create({
      data: {
        tenantId: g.tenantId,
        name: dto.name.trim(),
        months: dto.months,
        price: dto.price,
        joiningFee: dto.joiningFee ?? 0,
        freezeDays: dto.freezeDays ?? 0,
        features: dto.features ?? [],
        showInApp: dto.showInApp ?? true,
        active: dto.active ?? true,
      },
    });
    await this.audit.log({ tenantId: g.tenantId, actorId: u.id, action: 'plan.create', entity: 'plan', entityId: p.id, after: p });
    return p;
  }

  /** Price changes affect only new and renewed memberships; old rows keep their recorded price. */
  @Staff('OWNER')
  @Patch(':id')
  async update(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: UpdatePlanDto) {
    const before = await this.prisma.membershipPlan.findFirst({ where: { id, tenantId: g.tenantId } });
    if (!before) throw new NotFoundException('Plan not found');
    const after = await this.prisma.membershipPlan.update({ where: { id }, data: dto });
    await this.audit.log({ tenantId: g.tenantId, actorId: u.id, action: 'plan.update', entity: 'plan', entityId: id, before, after });
    return after;
  }
}
