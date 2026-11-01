import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  ForbiddenException,
  Get,
  NotFoundException,
  Param,
  ParseUUIDPipe,
  Patch,
  Post,
} from '@nestjs/common';
import * as bcrypt from 'bcryptjs';
import { ArrayMaxSize, IsArray, IsBoolean, IsEmail, IsEnum, IsOptional, IsString, IsUUID, Matches, MaxLength, MinLength } from 'class-validator';
import { randomInt } from 'crypto';
import { StaffRole } from '@prisma/client';
import { AuditService } from '../common/audit.service';
import { AuthUser, CurrentUser, Gym, GymCtx, Staff } from '../common/auth';
import { addMonths, todayIST } from '../common/dates';
import { normalizeEmail, normalizePhone } from '../common/phone';
import { PrismaService } from '../common/prisma.service';
import { assertUnder, gymLimits } from './limits';

class CreateGymDto {
  @IsString() @MinLength(2) @MaxLength(80) name: string;
  @IsOptional() @IsString() @MaxLength(60) branchName?: string;
  @IsOptional() @IsString() @MaxLength(300) address?: string;
  @IsOptional() @IsString() phone?: string;
  @IsOptional() @IsString() whatsappNumber?: string;
}

class UpdateGymDto {
  @IsOptional() @IsString() @MinLength(2) @MaxLength(80) name?: string;
  @IsOptional() @IsString() @MaxLength(300) address?: string;
  @IsOptional() @IsString() phone?: string;
  @IsOptional() @IsString() whatsappNumber?: string;
  @IsOptional() @IsString() @MaxLength(500) logoUrl?: string;
  @IsOptional() @IsBoolean() allowEntryWhenDue?: boolean;
  @IsOptional() @IsString() @Matches(/^[A-Z]{1,5}$/, { message: 'Member code prefix must be 1-5 capital letters' }) memberCodePrefix?: string;
}

class BranchDto {
  @IsString() @MinLength(2) @MaxLength(60) name: string;
  @IsOptional() @IsString() @MaxLength(300) address?: string;
  @IsOptional() @IsString() @MaxLength(120) hours?: string;
}

class AddStaffDto {
  @IsString() @MinLength(2) @MaxLength(80) name: string;
  @IsString() phone: string;
  @IsOptional() @IsEmail() email?: string;
  @IsOptional() @IsString() @MinLength(8) tempPassword?: string;
  @IsEnum(StaffRole) role: StaffRole;
  @IsOptional() @IsArray() @ArrayMaxSize(20) @IsUUID('all', { each: true }) branchIds?: string[];
}

class UpdateStaffDto {
  @IsOptional() @IsEnum(StaffRole) role?: StaffRole;
  @IsOptional() @IsArray() @IsUUID('all', { each: true }) branchIds?: string[];
  @IsOptional() @IsBoolean() active?: boolean;
}

async function uniqueGymCode(prisma: PrismaService, name: string): Promise<string> {
  const base = name.toUpperCase().replace(/[^A-Z]/g, '').slice(0, 4).padEnd(3, 'X');
  for (let i = 0; i < 20; i++) {
    const code = `${base}${randomInt(100, 1000)}`;
    if (!(await prisma.tenant.findUnique({ where: { gymCode: code } }))) return code;
  }
  return `GM${randomInt(100000, 1000000)}`;
}

function prefixFrom(name: string) {
  const words = name.toUpperCase().replace(/[^A-Z ]/g, '').split(/\s+/).filter(Boolean);
  const p = words.map((w) => w[0]).join('').slice(0, 3);
  return p.length >= 2 ? p : (words[0] ?? 'GM').slice(0, 3);
}

@Controller()
export class GymsController {
  constructor(
    private prisma: PrismaService,
    private audit: AuditService,
  ) {}

  /** Any signed-in user can register their gym. It starts on the free trial. */
  @Post('gyms')
  async create(@CurrentUser() u: AuthUser, @Body() dto: CreateGymDto) {
    const settings = await this.prisma.platformSetting.findUnique({ where: { id: 1 } });
    const months = settings?.trialMonths ?? 3;
    const phone = dto.phone ? normalizePhone(dto.phone) : null;
    if (dto.phone && !phone) throw new BadRequestException('Enter a valid gym phone number');
    const wa = dto.whatsappNumber ? normalizePhone(dto.whatsappNumber) : phone;
    if (dto.whatsappNumber && !wa) throw new BadRequestException('Enter a valid WhatsApp number');
    const gymCode = await uniqueGymCode(this.prisma, dto.name);
    const trialEnd = addMonths(todayIST(), months);
    const tenant = await this.prisma.$transaction(async (tx) => {
      const t = await tx.tenant.create({
        data: {
          name: dto.name.trim(),
          gymCode,
          phone,
          whatsappNumber: wa,
          address: dto.address,
          trialEndsAt: new Date(`${trialEnd}T18:29:59.000Z`),
          memberCodePrefix: prefixFrom(dto.name),
        },
      });
      const b = await tx.branch.create({ data: { tenantId: t.id, name: dto.branchName?.trim() || 'Main', address: dto.address } });
      await tx.staff.create({ data: { tenantId: t.id, userId: u.id, role: 'OWNER', branchIds: [b.id] } });
      await this.audit.log({ tenantId: t.id, actorId: u.id, action: 'gym.create', entity: 'tenant', entityId: t.id, after: t }, tx);
      return t;
    });
    return tenant;
  }

  @Staff()
  @Get('gym')
  async get(@Gym() g: GymCtx) {
    const t = await this.prisma.tenant.findUniqueOrThrow({
      where: { id: g.tenantId },
      include: { branches: { orderBy: { createdAt: 'asc' } }, saasPlan: true },
    });
    return { ...t, myRole: g.role, myBranchIds: g.branchIds, limits: await gymLimits(this.prisma, g.tenantId) };
  }

  @Staff('OWNER')
  @Patch('gym')
  async update(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Body() dto: UpdateGymDto) {
    const before = await this.prisma.tenant.findUniqueOrThrow({ where: { id: g.tenantId } });
    const data: Record<string, unknown> = { ...dto };
    if (dto.phone !== undefined) {
      data.phone = dto.phone ? normalizePhone(dto.phone) : null;
      if (dto.phone && !data.phone) throw new BadRequestException('Enter a valid gym phone number');
    }
    if (dto.whatsappNumber !== undefined) {
      data.whatsappNumber = dto.whatsappNumber ? normalizePhone(dto.whatsappNumber) : null;
      if (dto.whatsappNumber && !data.whatsappNumber) throw new BadRequestException('Enter a valid WhatsApp number');
    }
    const after = await this.prisma.tenant.update({ where: { id: g.tenantId }, data });
    await this.audit.log({ tenantId: g.tenantId, actorId: u.id, action: 'gym.update', entity: 'tenant', entityId: g.tenantId, before, after });
    return after;
  }

  @Staff('OWNER')
  @Post('gym/branches')
  async addBranch(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Body() dto: BranchDto) {
    await assertUnder(this.prisma, g.tenantId, 'branches');
    const b = await this.prisma.branch.create({ data: { tenantId: g.tenantId, ...dto } });
    await this.audit.log({ tenantId: g.tenantId, actorId: u.id, action: 'branch.create', entity: 'branch', entityId: b.id, after: b });
    return b;
  }

  @Staff('OWNER')
  @Patch('gym/branches/:id')
  async updateBranch(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: BranchDto) {
    const before = await this.prisma.branch.findFirst({ where: { id, tenantId: g.tenantId } });
    if (!before) throw new NotFoundException('Branch not found');
    const after = await this.prisma.branch.update({ where: { id }, data: dto });
    await this.audit.log({ tenantId: g.tenantId, actorId: u.id, action: 'branch.update', entity: 'branch', entityId: id, before, after });
    return after;
  }

  @Staff('OWNER')
  @Get('gym/staff')
  async staff(@Gym() g: GymCtx) {
    const rows = await this.prisma.staff.findMany({
      where: { tenantId: g.tenantId },
      include: { user: { select: { id: true, name: true, email: true, phone: true, photoUrl: true } } },
      orderBy: { createdAt: 'asc' },
    });
    return rows;
  }

  /** Owner adds a front desk (or co-owner) account. */
  @Staff('OWNER')
  @Post('gym/staff')
  async addStaff(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Body() dto: AddStaffDto) {
    await assertUnder(this.prisma, g.tenantId, 'staff');
    const phone = normalizePhone(dto.phone);
    if (!phone) throw new BadRequestException('Enter a valid 10-digit mobile number');
    const email = dto.email ? normalizeEmail(dto.email) : null;
    const branchIds = await this.checkBranches(g.tenantId, dto.branchIds ?? []);
    let user = await this.prisma.user.findFirst({ where: { OR: [{ phone }, ...(email ? [{ email }] : [])] } });
    if (!user) {
      if (!dto.tempPassword) throw new BadRequestException('Set a temporary password for the new staff account');
      user = await this.prisma.user.create({
        data: { name: dto.name.trim(), phone, email, passwordHash: await bcrypt.hash(dto.tempPassword, 10) },
      });
    }
    const exists = await this.prisma.staff.findUnique({ where: { tenantId_userId: { tenantId: g.tenantId, userId: user.id } } });
    if (exists) throw new ConflictException('This person is already staff at your gym');
    const s = await this.prisma.staff.create({ data: { tenantId: g.tenantId, userId: user.id, role: dto.role, branchIds } });
    await this.audit.log({ tenantId: g.tenantId, actorId: u.id, action: 'staff.create', entity: 'staff', entityId: s.id, after: s });
    return s;
  }

  @Staff('OWNER')
  @Patch('gym/staff/:id')
  async updateStaff(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: UpdateStaffDto) {
    const before = await this.prisma.staff.findFirst({ where: { id, tenantId: g.tenantId } });
    if (!before) throw new NotFoundException('Staff not found');
    const demotingOwner = before.role === 'OWNER' && (dto.role === 'FRONT_DESK' || dto.active === false);
    if (demotingOwner) {
      const owners = await this.prisma.staff.count({ where: { tenantId: g.tenantId, role: 'OWNER', active: true } });
      if (owners <= 1) throw new ForbiddenException('A gym needs at least one owner');
    }
    const data: { role?: StaffRole; active?: boolean; branchIds?: string[] } = { role: dto.role, active: dto.active };
    if (dto.branchIds) data.branchIds = await this.checkBranches(g.tenantId, dto.branchIds);
    const after = await this.prisma.staff.update({ where: { id }, data });
    await this.audit.log({ tenantId: g.tenantId, actorId: u.id, action: 'staff.update', entity: 'staff', entityId: id, before, after });
    return after;
  }

  @Staff('OWNER')
  @Get('gym/audit')
  audit_(@Gym() g: GymCtx) {
    return this.prisma.auditLog.findMany({ where: { tenantId: g.tenantId }, orderBy: { createdAt: 'desc' }, take: 200 });
  }

  private async checkBranches(tenantId: string, ids: string[]) {
    if (!ids.length) return [];
    const n = await this.prisma.branch.count({ where: { tenantId, id: { in: ids } } });
    if (n !== new Set(ids).size) throw new BadRequestException('Unknown branch');
    return [...new Set(ids)];
  }
}

