'use client';

import { PageTop } from '@/components/ui';
import { TicketDesk } from '@/components/TicketDesk';

export default function Support() {
  return (
    <>
      <PageTop crumb="Members" title="Member support" />
      <p className="mut" style={{ marginTop: -8 }}>Questions about membership, payments, check-in and the gym. App problems go to GymMantra support automatically.</p>
      <TicketDesk base="/tickets" />
    </>
  );
}
