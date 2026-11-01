import { BadRequestException, Body, Controller, Delete, ForbiddenException, Get, NotFoundException, Param, ParseUUIDPipe, Post, Res } from '@nestjs/common';
import { IsIn, IsString, MaxLength } from 'class-validator';
import type { Response } from 'express';
import { existsSync, readFileSync } from 'fs';
import { join, resolve } from 'path';
import { AuthUser, CurrentUser, Public } from '../common/auth';
import { PrismaService } from '../common/prisma.service';

const MAX_BYTES = 400 * 1024;

class PhotoDto {
  @IsIn(['image/jpeg', 'image/png']) mime: string;
  @IsString() @MaxLength(600_000) base64: string;
}

function looksLikeImage(buf: Buffer, mime: string) {
  if (mime === 'image/jpeg') return buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff;
  return buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
}

@Controller()
export class PhotosController {
  constructor(private prisma: PrismaService) {}

  @Post('me/photo')
  async upload(@CurrentUser() u: AuthUser, @Body() dto: PhotoDto) {
    const buf = Buffer.from(dto.base64, 'base64');
    if (!buf.length || buf.length > MAX_BYTES) throw new BadRequestException('Photo must be smaller than 400 KB');
    if (!looksLikeImage(buf, dto.mime)) throw new BadRequestException('This file is not a JPEG or PNG image');
    await this.prisma.userPhoto.upsert({ where: { userId: u.id }, create: { userId: u.id, mime: dto.mime, data: buf }, update: { mime: dto.mime, data: buf } });
    const photoUrl = `/api/v1/photos/${u.id}?v=${Date.now()}`;
    await this.prisma.user.update({ where: { id: u.id }, data: { photoUrl } });
    return { photoUrl };
  }

  @Delete('me/photo')
  async remove(@CurrentUser() u: AuthUser) {
    await this.prisma.userPhoto.deleteMany({ where: { userId: u.id } });
    await this.prisma.user.update({ where: { id: u.id }, data: { photoUrl: null } });
    return { ok: true };
  }

  /** Visible only to the person and to staff of a gym they belong to. */
  @Get('photos/:userId')
  async get(@CurrentUser() u: AuthUser, @Param('userId', ParseUUIDPipe) userId: string, @Res() res: Response) {
    if (u.id !== userId && !u.isSuperAdmin) {
      const gyms = await this.prisma.staff.findMany({ where: { userId: u.id, active: true }, select: { tenantId: true } });
      const tenantIds = gyms.map((g) => g.tenantId);
      const ok =
        tenantIds.length > 0 &&
        ((await this.prisma.member.count({ where: { userId, tenantId: { in: tenantIds } } })) > 0 ||
          (await this.prisma.joinRequest.count({ where: { userId, tenantId: { in: tenantIds } } })) > 0 ||
          (await this.prisma.staff.count({ where: { userId, tenantId: { in: tenantIds } } })) > 0);
      if (!ok) throw new ForbiddenException('Not allowed');
    }
    const p = await this.prisma.userPhoto.findUnique({ where: { userId } });
    if (!p) throw new NotFoundException('No photo');
    res.setHeader('Content-Type', p.mime);
    res.setHeader('Cache-Control', 'private, max-age=86400');
    res.send(Buffer.from(p.data));
  }

  /** The 40 pre-rendered 3D exercise guides from media/exercises. */
  @Public()
  @Get('exercises')
  exercises() {
    const file = join(mediaDir(), 'exercises.json');
    if (!existsSync(file)) return [];
    const list = JSON.parse(readFileSync(file, 'utf8')) as { n: number; id: string; name: string; muscle: string; video: string; still: string }[];
    return list.map((e) => ({ ...e, videoUrl: `/media/exercises/${e.video}`, stillUrl: `/media/exercises/${e.still}` }));
  }
}

export function mediaDir() {
  return resolve(process.env.MEDIA_DIR || join(__dirname, '..', '..', '..', '..', 'media', 'exercises'));
}
