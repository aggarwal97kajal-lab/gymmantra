import {
  CanActivate,
  createParamDecorator,
  ExecutionContext,
  ForbiddenException,
  Injectable,
  SetMetadata,
  UnauthorizedException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { StaffRole } from '@prisma/client';
import type { Request } from 'express';
import { PrismaService } from './prisma.service';

export const SESSION_COOKIE = 'gm_session';

export interface AuthUser {
  id: string;
  name: string;
  email: string | null;
  isSuperAdmin: boolean;
}

/** The gym the signed-in staff member is working in. Resolved on the server. */
export interface GymCtx {
  tenantId: string;
  staffId: string;
  role: StaffRole;
  branchIds: string[];
}

const PUBLIC = 'gm:public';
const STAFF = 'gm:staff';
const SUPER = 'gm:super';

export const Public = () => SetMetadata(PUBLIC, true);
/** Requires the user to be staff of a gym. Pass roles to restrict further. */
export const Staff = (...roles: StaffRole[]) => SetMetadata(STAFF, roles.length ? roles : ['ANY']);
export const SuperAdmin = () => SetMetadata(SUPER, true);

export const CurrentUser = createParamDecorator((_: unknown, ctx: ExecutionContext): AuthUser => {
  return ctx.switchToHttp().getRequest().user;
});

export const Gym = createParamDecorator((_: unknown, ctx: ExecutionContext): GymCtx => {
  const g = ctx.switchToHttp().getRequest().gym;
  if (!g) throw new ForbiddenException('Not a staff member of a gym');
  return g;
});

function tokenFrom(req: Request): { token: string | null; viaCookie: boolean } {
  const h = req.headers.authorization;
  if (h && h.startsWith('Bearer ')) return { token: h.slice(7), viaCookie: false };
  const c = (req as any).cookies?.[SESSION_COOKIE];
  return { token: c || null, viaCookie: !!c };
}

@Injectable()
export class AuthGuard implements CanActivate {
  constructor(
    private reflector: Reflector,
    private jwt: JwtService,
    private prisma: PrismaService,
  ) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const handlers = [ctx.getHandler(), ctx.getClass()];
    if (this.reflector.getAllAndOverride<boolean>(PUBLIC, handlers)) return true;

    const req = ctx.switchToHttp().getRequest<Request & { user?: AuthUser; gym?: GymCtx }>();
    const { token, viaCookie } = tokenFrom(req);
    if (!token) throw new UnauthorizedException('Please log in');

    // Cookie sessions must send a custom header on writes. Browsers cannot add
    // it cross-site without CORS approval, which blocks CSRF.
    if (viaCookie && !['GET', 'HEAD', 'OPTIONS'].includes(req.method) && !req.headers['x-gm-client']) {
      throw new ForbiddenException('Missing client header');
    }

    let payload: { sub: string };
    try {
      payload = await this.jwt.verifyAsync(token);
    } catch {
      throw new UnauthorizedException('Session expired. Please log in again');
    }
    const user = await this.prisma.user.findUnique({
      where: { id: payload.sub },
      select: { id: true, name: true, email: true, isSuperAdmin: true },
    });
    if (!user) throw new UnauthorizedException('Please log in');
    req.user = user;

    if (this.reflector.getAllAndOverride<boolean>(SUPER, handlers) && !user.isSuperAdmin) {
      throw new ForbiddenException('Super admin only');
    }

    const roles = this.reflector.getAllAndOverride<string[]>(STAFF, handlers);
    if (roles) {
      // The client may say which of its gyms it is working in, but we only
      // accept a gym where this user really is active staff.
      const wanted = typeof req.headers['x-gym-id'] === 'string' ? req.headers['x-gym-id'] : undefined;
      const staff = await this.prisma.staff.findFirst({
        where: {
          userId: user.id,
          active: true,
          ...(wanted && /^[0-9a-f-]{36}$/i.test(wanted) ? { tenantId: wanted } : {}),
        },
        include: { tenant: { select: { status: true } } },
        orderBy: { createdAt: 'asc' },
      });
      if (!staff) throw new ForbiddenException('You are not staff of this gym');
      if (staff.tenant.status === 'SUSPENDED') throw new ForbiddenException('This gym is suspended. Contact GymMantra support');
      if (!roles.includes('ANY') && !roles.includes(staff.role)) {
        throw new ForbiddenException('Only the gym owner can do this');
      }
      req.gym = { tenantId: staff.tenantId, staffId: staff.id, role: staff.role, branchIds: staff.branchIds };
    }
    return true;
  }
}
