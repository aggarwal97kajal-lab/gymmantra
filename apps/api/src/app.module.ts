import { Controller, Get, Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { JwtModule } from '@nestjs/jwt';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { AttendanceController } from './attendance/attendance.controller';
import { AuthController } from './auth/auth.controller';
import { AuthService } from './auth/auth.service';
import { AuditModule } from './common/audit.service';
import { AuthGuard, Public } from './common/auth';
import { config } from './common/config';
import { PrismaModule } from './common/prisma.service';
import { GymsController } from './gyms/gyms.controller';
import { MeController } from './me/me.controller';
import { PhotosController } from './me/photos.controller';
import { MembersController } from './members/members.controller';
import { MembershipsController } from './memberships/memberships.controller';
import { MembershipsService } from './memberships/memberships.service';
import { NotificationsModule } from './notifications/notifications';
import { PlansController } from './plans/plans.controller';
import { SuperController } from './super/super.controller';
import { GymTicketsController, SuperTicketsController, TicketsService } from './tickets/tickets';

@Controller()
class HealthController {
  @Public()
  @Get('health')
  health() {
    return { ok: true, name: 'GymMantra API' };
  }
}

@Module({
  imports: [
    PrismaModule,
    AuditModule,
    NotificationsModule,
    JwtModule.registerAsync({ global: true, useFactory: () => ({ secret: config.jwtSecret }) }),
    ThrottlerModule.forRoot([{ name: 'default', ttl: 60_000, limit: 300 }]),
  ],
  controllers: [
    HealthController,
    AuthController,
    GymsController,
    PlansController,
    MembersController,
    MembershipsController,
    AttendanceController,
    GymTicketsController,
    SuperTicketsController,
    MeController,
    PhotosController,
    SuperController,
  ],
  providers: [
    AuthService,
    MembershipsService,
    TicketsService,
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    { provide: APP_GUARD, useClass: AuthGuard },
  ],
})
export class AppModule {}
