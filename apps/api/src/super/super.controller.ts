import { Body, Controller, Get, NotFoundException, Param, ParseUUIDPipe, Patch, Post } from '@nestjs/common';
import { TenantStatus } from '@prisma/client';
import { ArrayMaxSize, IsArray, IsBoolean, IsEnum, IsInt, IsOptional, IsString, IsUUID, Max, MaxLength, Min, MinLength, ValidateIf } from 'class-validator';
import { AuditService } from '../common/audit.service';
import { AuthUser, CurrentUser, Public, SuperAdmin } from '../common/auth';
import { PrismaService } from '../common/prisma.service';

class SaasPlanDto {
  @IsString() @MinLength(2) @MaxLength(40) name: string;
  @IsInt() @Min(0) @Max(1_000_000) monthlyPrice: number;
  @IsInt() @Min(0) @Max(10_000_000) annualPrice: number;
  @IsOptional() @ValidateIf((_, v) => v !== null) @IsInt() @Min(1) memberLimit?: number | null;
  @IsOptional() @IsInt() @Min(1) @Max(100) branchLimit?: number;
  @IsOptional() @IsInt() @Min(1) @Max(500) staffLimit?: number;
  @IsOptional() @IsInt() @Min(0) whatsappLimit?: number;
  @IsOptional() @IsArray() @ArrayMaxSize(30) @IsString({ each: true }) features?: string[];
  @IsOptional() @IsBoolean() visible?: boolean;
  @IsOptional() @IsInt() sortOrder?: number;
}

class UpdateSaasPlanDto {
  @IsOptional() @IsString() @MinLength(2) @MaxLength(40) name?: string;
  @IsOptional() @IsInt() @Min(0) @Max(1_000_000) monthlyPrice?: number;
  @IsOptional() @IsInt() @Min(0) @Max(10_000_000) annualPrice?: number;
  @IsOptional() @ValidateIf((_, v) => v !== null) @IsInt() @Min(1) memberLimit?: number | null;
  @IsOptional() @IsInt() @Min(1) @Max(100) branchLimit?: number;
  @IsOptional() @IsInt() @Min(1) @Max(500) staffLimit?: number;
  @IsOptional() @IsInt() @Min(0) whatsappLimit?: number;
  @IsOptional() @IsArray() @ArrayMaxSize(30) @IsString({ each: true }) features?: string[];
  @IsOptional() @IsBoolean() visible?: boolean;
  @IsOptional() @IsInt() sortOrder?: number;
}

class UpdateGymDto {
  @IsOptional() @IsEnum(TenantStatus) status?: TenantStatus;
  @IsOptional() @IsBoolean() verified?: boolean;
  @IsOptional() @ValidateIf((_, v) => v !== null) @IsUUID() saasPlanId?: string | null;
  @IsOptional() @ValidateIf((_, v) => v !== null) @IsInt() @Min(0) customMonthlyPrice?: number | null;
  @IsOptional() @IsString() trialEndsAt?: string;
}

class SettingsDto {
  @IsInt() @Min(0) @Max(24) trialMonths: number;
}

@Controller()
export class SuperController {
  constructor(
    private prisma: PrismaService,
    private audit: AuditService,
  ) {}

  /** Public pricing, for the website and the admin panel billing page. */
  @Public()
  @Get('saas-plans')
  async publicPlans() {
    const [plans, s] = await Promise.all([
      this.prisma.saasPlan.findMany({ where: { visible: true }, orderBy: { sortOrder: 'asc' } }),
      this.prisma.platformSetting.findUnique({ where: { id: 1 } }),
    ]);
    return { trialMonths: s?.trialMonths ?? 3, plans };
  }

  @SuperAdmin()
  @Get('super/overview')
  async overview() {
    const [gyms, trial, active, suspended, members, users, openTickets] = await Promise.all([
      this.prisma.tenant.count(),
      this.prisma.tenant.count({ where: { status: 'TRIAL' } }),
      this.prisma.tenant.count({ where: { status: 'ACTIVE' } }),
      this.prisma.tenant.count({ where: { status: 'SUSPENDED' } }),
      this.prisma.member.count({ where: { archived: false } }),
      this.prisma.user.count(),
      this.prisma.ticket.count({ where: { routedTo: 'GYMMANTRA', status: 'OPEN' } }),
    ]);
    return { gyms, trial, active, suspended, members, users, openTickets };
  }

  @SuperAdmin()
  @Get('super/gyms')
  async gyms() {
    const rows = await this.prisma.tenant.findMany({
      include: { saasPlan: { select: { id: true, name: true } }, _count: { select: { members: true, branches: true } } },
      orderBy: { createdAt: 'desc' },
    });
    const owners = await this.prisma.staff.findMany({
      where: { role: 'OWNER', tenantId: { in: rows.map((r) => r.id) } },
      include: { user: { select: { name: true, phone: true, email: true } } },
    });
    return rows.map((r) => ({ ...r, owners: owners.filter((o) => o.tenantId === r.id).map((o) => o.user) }));
  }

  @SuperAdmin()
  @Patch('super/gyms/:id')
  async updateGym(@CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: UpdateGymDto) {
    const before = await this.prisma.tenant.findUnique({ where: { id } });
    if (!before) throw new NotFoundException('Gym not found');
    const after = await this.prisma.tenant.update({
      where: { id },
      data: {
        status: dto.status,
        verified: dto.verified,
        saasPlanId: dto.saasPlanId,
        customMonthlyPrice: dto.customMonthlyPrice,
        trialEndsAt: dto.trialEndsAt ? new Date(`${dto.trialEndsAt}T18:29:59.000Z`) : undefined,
      },
    });
    await this.audit.log({ tenantId: id, actorId: u.id, action: 'super.gym.update', entity: 'tenant', entityId: id, before, after });
    return after;
  }

  @SuperAdmin()
  @Get('super/saas-plans')
  async plans() {
    const plans = await this.prisma.saasPlan.findMany({ orderBy: { sortOrder: 'asc' }, include: { _count: { select: { tenants: true } } } });
    const s = await this.prisma.platformSetting.findUnique({ where: { id: 1 } });
    return { trialMonths: s?.trialMonths ?? 3, plans };
  }

  @SuperAdmin()
  @Post('super/saas-plans')
  async createPlan(@CurrentUser() u: AuthUser, @Body() dto: SaasPlanDto) {
    const p = await this.prisma.saasPlan.create({ data: { ...dto, features: dto.features ?? [] } });
    await this.audit.log({ tenantId: null, actorId: u.id, action: 'saas_plan.create', entity: 'saas_plan', entityId: p.id, after: p });
    return p;
  }

  /** Price changes apply to new gyms now and to existing gyms at their next renewal. */
  @SuperAdmin()
  @Patch('super/saas-plans/:id')
  async updatePlan(@CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: UpdateSaasPlanDto) {
    const before = await this.prisma.saasPlan.findUnique({ where: { id } });
    if (!before) throw new NotFoundException('Plan not found');
    const after = await this.prisma.saasPlan.update({ where: { id }, data: dto });
    await this.audit.log({ tenantId: null, actorId: u.id, action: 'saas_plan.update', entity: 'saas_plan', entityId: id, before, after });
    return after;
  }

  @SuperAdmin()
  @Patch('super/settings')
  async settings(@CurrentUser() u: AuthUser, @Body() dto: SettingsDto) {
    const before = await this.prisma.platformSetting.findUnique({ where: { id: 1 } });
    const after = await this.prisma.platformSetting.upsert({ where: { id: 1 }, create: { id: 1, trialMonths: dto.trialMonths }, update: { trialMonths: dto.trialMonths } });
    await this.audit.log({ tenantId: null, actorId: u.id, action: 'settings.update', entity: 'platform_settings', entityId: '1', before, after });
    return after;
  }

  @SuperAdmin()
  @Get('super/audit')
  audit_() {
    return this.prisma.auditLog.findMany({ orderBy: { createdAt: 'desc' }, take: 300 });
  }
}
