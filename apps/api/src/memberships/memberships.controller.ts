import { Body, Controller, Get, Param, ParseUUIDPipe, Post, Query } from '@nestjs/common';
import { PaymentMode } from '@prisma/client';
import { IsBoolean, IsEnum, IsInt, IsOptional, IsString, IsUUID, Max, MaxLength, Min } from 'class-validator';
import { AuthUser, CurrentUser, Gym, GymCtx, Staff } from '../common/auth';
import { MembershipsService } from './memberships.service';

class MembershipDto {
  @IsUUID() planId: string;
  @IsOptional() @IsString() startDate?: string;
  @IsOptional() @IsString() endDate?: string;
  @IsOptional() @IsInt() @Min(0) @Max(10_000_000) price?: number;
  @IsOptional() @IsInt() @Min(0) @Max(10_000_000) discount?: number;
  @IsOptional() @IsInt() @Min(0) @Max(10_000_000) amountReceived?: number;
  @IsEnum(PaymentMode) paymentMode: PaymentMode;
  @IsOptional() @IsBoolean() allowEntryWhileDue?: boolean;
  @IsOptional() @IsString() @MaxLength(500) note?: string;
}

class PaymentDto {
  @IsInt() @Min(1) @Max(10_000_000) amount: number;
  @IsEnum(PaymentMode) mode: PaymentMode;
  @IsOptional() @IsString() @MaxLength(300) note?: string;
}

class FreezeDto {
  @IsInt() @Min(1) @Max(365) days: number;
  @IsOptional() @IsString() startDate?: string;
  @IsOptional() @IsString() @MaxLength(300) reason?: string;
}

/** Owner and front desk can both add, renew, discount, take payments and freeze. */
@Staff()
@Controller()
export class MembershipsController {
  constructor(private svc: MembershipsService) {}

  @Get('members/:id/membership-preview')
  preview(@Gym() g: GymCtx, @Param('id', ParseUUIDPipe) id: string, @Query('planId', ParseUUIDPipe) planId: string) {
    return this.svc.preview(g, id, planId);
  }

  @Post('members/:id/memberships')
  create(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: MembershipDto) {
    return this.svc.create(g, u.id, id, dto);
  }

  /** Records a correction as a new entry. The old entry is kept in history. */
  @Post('memberships/:id/correct')
  correct(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: MembershipDto) {
    return this.svc.correct(g, u.id, id, dto);
  }

  @Post('memberships/:id/payments')
  pay(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: PaymentDto) {
    return this.svc.addPayment(g, u.id, id, dto.amount, dto.mode, dto.note);
  }

  @Post('memberships/:id/freeze')
  freeze(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() dto: FreezeDto) {
    return this.svc.freeze(g, u.id, id, dto.days, dto.startDate, dto.reason);
  }

  @Post('freezes/:id/end')
  endFreeze(@Gym() g: GymCtx, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string) {
    return this.svc.endFreeze(g, u.id, id);
  }
}
