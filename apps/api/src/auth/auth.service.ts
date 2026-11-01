import {
  BadRequestException,
  ConflictException,
  HttpException,
  HttpStatus,
  Injectable,
  NotFoundException,
  UnauthorizedException,
} from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import * as bcrypt from 'bcryptjs';
import { OAuth2Client } from 'google-auth-library';
import { config } from '../common/config';
import { normalizeEmail, normalizePhone } from '../common/phone';
import { PrismaService } from '../common/prisma.service';

const DUMMY_HASH = bcrypt.hashSync('gymmantra-timing-pad', 10);

export interface GoogleProfile {
  sub: string;
  email: string | null;
  name: string | null;
  picture: string | null;
}

@Injectable()
export class AuthService {
  private google = new OAuth2Client();
  /** Replaced in tests. */
  verifyGoogle: (idToken: string) => Promise<GoogleProfile> = async (idToken) => {
    const ids = config.googleClientIds;
    if (!ids.length) throw new BadRequestException('Google sign-in is not set up yet');
    try {
      const ticket = await this.google.verifyIdToken({ idToken, audience: ids });
      const p = ticket.getPayload();
      if (!p?.sub) throw new Error('no sub');
      return { sub: p.sub, email: p.email_verified ? (p.email ?? null) : null, name: p.name ?? null, picture: p.picture ?? null };
    } catch {
      throw new UnauthorizedException('Google sign-in failed. Please try again');
    }
  };

  constructor(
    private prisma: PrismaService,
    private jwt: JwtService,
  ) {}

  private isSuper(email: string | null) {
    return !!email && !!config.superAdminEmail && email === config.superAdminEmail;
  }

  async issue(userId: string) {
    return this.jwt.signAsync({ sub: userId }, { expiresIn: `${config.sessionDays}d` });
  }

  publicUser(u: { id: string; name: string; email: string | null; phone: string | null; photoUrl: string | null; isSuperAdmin: boolean; googleSub?: string | null; passwordHash?: string | null; language?: string }) {
    return {
      id: u.id,
      name: u.name,
      email: u.email,
      phone: u.phone,
      photoUrl: u.photoUrl,
      isSuperAdmin: u.isSuperAdmin,
      language: u.language ?? 'en',
      hasPassword: !!u.passwordHash,
      hasGoogle: !!u.googleSub,
    };
  }

  async signup(input: { name: string; email: string; phone: string; password: string }) {
    const email = normalizeEmail(input.email);
    const phone = normalizePhone(input.phone);
    if (!email) throw new BadRequestException('Enter a valid email address');
    if (!phone) throw new BadRequestException('Enter a valid 10-digit mobile number');
    const name = input.name.trim();
    if (name.length < 2) throw new BadRequestException('Enter your name');
    const clash = await this.prisma.user.findFirst({ where: { OR: [{ email }, { phone }] } });
    if (clash) {
      throw new ConflictException(
        clash.email === email ? 'An account with this email already exists. Please log in' : 'An account with this mobile number already exists. Please log in',
      );
    }
    const user = await this.prisma.user.create({
      data: { name, email, phone, passwordHash: await bcrypt.hash(input.password, 10), isSuperAdmin: this.isSuper(email) },
    });
    return { token: await this.issue(user.id), user: this.publicUser(user) };
  }

  async login(identifier: string, password: string) {
    const id = identifier.trim();
    const email = normalizeEmail(id);
    const phone = email ? null : normalizePhone(id);
    const user = email
      ? await this.prisma.user.findUnique({ where: { email } })
      : phone
        ? await this.prisma.user.findUnique({ where: { phone } })
        : null;

    if (!user) {
      await bcrypt.compare(password, DUMMY_HASH); // same timing as a real check
      throw new UnauthorizedException('Wrong email/mobile or password');
    }
    const now = new Date();
    if (user.lockedUntil && user.lockedUntil > now) {
      throw this.tooMany(user.lockedUntil, now);
    }
    if (!user.passwordHash) {
      throw new BadRequestException('This account was created with Google. Use "Continue with Google" to log in');
    }
    const ok = await bcrypt.compare(password, user.passwordHash);
    if (!ok) {
      const updated = await this.prisma.user.update({
        where: { id: user.id },
        data: { failedLoginCount: { increment: 1 } },
        select: { failedLoginCount: true },
      });
      if (updated.failedLoginCount >= config.maxLoginAttempts) {
        const until = new Date(now.getTime() + config.lockMinutes * 60_000);
        await this.prisma.user.update({ where: { id: user.id }, data: { lockedUntil: until, failedLoginCount: 0 } });
        throw this.tooMany(until, now);
      }
      const left = config.maxLoginAttempts - updated.failedLoginCount;
      throw new UnauthorizedException(`Wrong password. ${left} attempt${left === 1 ? '' : 's'} left`);
    }
    const promote = !user.isSuperAdmin && this.isSuper(user.email);
    const fresh = await this.prisma.user.update({
      where: { id: user.id },
      data: { failedLoginCount: 0, lockedUntil: null, ...(promote ? { isSuperAdmin: true } : {}) },
    });
    return { token: await this.issue(user.id), user: this.publicUser(fresh) };
  }

  private tooMany(until: Date, now: Date) {
    const mins = Math.max(1, Math.ceil((until.getTime() - now.getTime()) / 60_000));
    return new HttpException(
      { statusCode: 429, message: `Too many attempts. Try again in ${mins} minute${mins === 1 ? '' : 's'}`, retryAfterMinutes: mins },
      HttpStatus.TOO_MANY_REQUESTS,
    );
  }

  /** Google sign-up. Creates a new account linked to this Google account. */
  async googleSignup(idToken: string, phoneInput?: string) {
    const g = await this.verifyGoogle(idToken);
    if (await this.prisma.user.findUnique({ where: { googleSub: g.sub } })) {
      throw new ConflictException('You already signed up with this Google account. Please log in with Google');
    }
    if (g.email && (await this.prisma.user.findUnique({ where: { email: g.email } }))) {
      throw new ConflictException('This email is already registered with a password. Log in with your email and password');
    }
    let phone: string | null = null;
    if (phoneInput) {
      phone = normalizePhone(phoneInput);
      if (!phone) throw new BadRequestException('Enter a valid 10-digit mobile number');
      if (await this.prisma.user.findUnique({ where: { phone } })) {
        throw new ConflictException('An account with this mobile number already exists. Please log in');
      }
    }
    const user = await this.prisma.user.create({
      data: {
        name: g.name || (g.email ? g.email.split('@')[0] : 'GymMantra user'),
        email: g.email,
        phone,
        googleSub: g.sub,
        photoUrl: g.picture,
        isSuperAdmin: this.isSuper(g.email),
      },
    });
    return { token: await this.issue(user.id), user: this.publicUser(user) };
  }

  /** Google log-in. Only works for accounts that signed up with Google first. */
  async googleLogin(idToken: string) {
    const g = await this.verifyGoogle(idToken);
    const user = await this.prisma.user.findUnique({ where: { googleSub: g.sub } });
    if (!user) {
      throw new NotFoundException('No GymMantra account for this Google account. Please sign up with Google first');
    }
    if (user.lockedUntil && user.lockedUntil > new Date()) throw this.tooMany(user.lockedUntil, new Date());
    return { token: await this.issue(user.id), user: this.publicUser(user) };
  }

  async changePassword(userId: string, current: string | undefined, next: string) {
    const user = await this.prisma.user.findUniqueOrThrow({ where: { id: userId } });
    if (user.passwordHash) {
      if (!current || !(await bcrypt.compare(current, user.passwordHash))) {
        throw new UnauthorizedException('Current password is wrong');
      }
    }
    await this.prisma.user.update({ where: { id: userId }, data: { passwordHash: await bcrypt.hash(next, 10) } });
    return { ok: true };
  }

  async me(userId: string) {
    const user = await this.prisma.user.findUniqueOrThrow({ where: { id: userId } });
    const staff = await this.prisma.staff.findMany({
      where: { userId, active: true },
      include: { tenant: { select: { id: true, name: true, gymCode: true, status: true, logoUrl: true } } },
      orderBy: { createdAt: 'asc' },
    });
    return {
      user: this.publicUser(user),
      gyms: staff.map((s) => ({ ...s.tenant, role: s.role, branchIds: s.branchIds })),
    };
  }
}
