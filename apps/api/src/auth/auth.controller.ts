import { Body, Controller, Get, HttpCode, Post, Res } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { IsEmail, IsNotEmpty, IsOptional, IsString, MaxLength, MinLength } from 'class-validator';
import type { Response } from 'express';
import { AuthUser, CurrentUser, Public, SESSION_COOKIE } from '../common/auth';
import { config } from '../common/config';
import { AuthService } from './auth.service';

class SignupDto {
  @IsString() @MinLength(2) @MaxLength(80) name: string;
  @IsEmail({}, { message: 'Enter a valid email address' }) email: string;
  @IsString() @IsNotEmpty() phone: string;
  @IsString() @MinLength(8, { message: 'Password must be at least 8 characters' }) @MaxLength(100) password: string;
}

class LoginDto {
  @IsString() @IsNotEmpty({ message: 'Enter your email or mobile number' }) identifier: string;
  @IsString() @IsNotEmpty({ message: 'Enter your password' }) @MaxLength(100) password: string;
}

class GoogleDto {
  @IsString() @IsNotEmpty() idToken: string;
  @IsOptional() @IsString() phone?: string;
}

class ChangePasswordDto {
  @IsOptional() @IsString() current?: string;
  @IsString() @MinLength(8, { message: 'Password must be at least 8 characters' }) @MaxLength(100) next: string;
}

// Per-IP limits on auth endpoints. Relaxed under Jest so tests can create many users.
const L = (n: number) => (process.env.NODE_ENV === 'test' ? 100_000 : n);

@Controller('auth')
export class AuthController {
  constructor(private auth: AuthService) {}

  private setCookie(res: Response, token: string) {
    res.cookie(SESSION_COOKIE, token, {
      httpOnly: true,
      sameSite: 'lax',
      secure: config.isProd,
      maxAge: config.sessionDays * 86_400_000,
      path: '/',
    });
  }

  @Public()
  @Get('config')
  cfg() {
    return { googleClientId: config.googleClientIds[0] ?? null, maxLoginAttempts: config.maxLoginAttempts, lockMinutes: config.lockMinutes };
  }

  @Public()
  @Throttle({ default: { limit: L(10), ttl: 60_000 } })
  @Post('signup')
  async signup(@Body() dto: SignupDto, @Res({ passthrough: true }) res: Response) {
    const r = await this.auth.signup(dto);
    this.setCookie(res, r.token);
    return r;
  }

  @Public()
  @Throttle({ default: { limit: L(20), ttl: 60_000 } })
  @HttpCode(200)
  @Post('login')
  async login(@Body() dto: LoginDto, @Res({ passthrough: true }) res: Response) {
    const r = await this.auth.login(dto.identifier, dto.password);
    this.setCookie(res, r.token);
    return r;
  }

  @Public()
  @Throttle({ default: { limit: L(10), ttl: 60_000 } })
  @Post('google/signup')
  async googleSignup(@Body() dto: GoogleDto, @Res({ passthrough: true }) res: Response) {
    const r = await this.auth.googleSignup(dto.idToken, dto.phone);
    this.setCookie(res, r.token);
    return r;
  }

  @Public()
  @Throttle({ default: { limit: L(20), ttl: 60_000 } })
  @HttpCode(200)
  @Post('google/login')
  async googleLogin(@Body() dto: GoogleDto, @Res({ passthrough: true }) res: Response) {
    const r = await this.auth.googleLogin(dto.idToken);
    this.setCookie(res, r.token);
    return r;
  }

  @Public()
  @HttpCode(200)
  @Post('logout')
  logout(@Res({ passthrough: true }) res: Response) {
    res.clearCookie(SESSION_COOKIE, { path: '/' });
    return { ok: true };
  }

  @Get('me')
  me(@CurrentUser() u: AuthUser) {
    return this.auth.me(u.id);
  }

  @HttpCode(200)
  @Post('change-password')
  changePassword(@CurrentUser() u: AuthUser, @Body() dto: ChangePasswordDto) {
    return this.auth.changePassword(u.id, dto.current, dto.next);
  }
}
