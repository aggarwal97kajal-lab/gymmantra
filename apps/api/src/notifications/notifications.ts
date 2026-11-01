import { Global, Injectable, Module } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../common/prisma.service';

type Tx = Prisma.TransactionClient | PrismaService;

@Injectable()
export class NotificationsService {
  constructor(private prisma: PrismaService) {}

  /** In-app notification. Push (FCM) is added with the member app. */
  notify(userId: string | null | undefined, tenantId: string | null, title: string, body: string, tx: Tx = this.prisma) {
    if (!userId) return Promise.resolve(null);
    return tx.notification.create({ data: { userId, tenantId, title, body } });
  }
}

/**
 * WhatsApp messages go out from each gym's own WhatsApp Business number.
 * The admin panel opens a wa.me link on the staff phone, which is logged into
 * the gym's WhatsApp, with the message already typed.
 */
export function whatsappLink(memberPhone: string, text: string): string {
  const digits = memberPhone.replace(/[^\d]/g, '');
  return `https://wa.me/${digits}?text=${encodeURIComponent(text)}`;
}

export function rupees(n: number) {
  return `₹${n.toLocaleString('en-IN')}`;
}

export function prettyDate(ymd: string) {
  const d = new Date(`${ymd}T00:00:00Z`);
  return d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
}

@Global()
@Module({ providers: [NotificationsService], exports: [NotificationsService] })
export class NotificationsModule {}
