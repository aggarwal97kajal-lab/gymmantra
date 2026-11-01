import { addMonths, planEndDate, todayIST } from '../src/common/dates';
import { computeState, entryDecision, renewalStart, SubLike } from '../src/memberships/status';
import { makeQrToken, verifyQrToken } from '../src/attendance/qr-token';

const sub = (o: Partial<SubLike>): SubLike => ({
  id: 's1', startDate: '2026-10-01', endDate: '2026-10-31', total: 1500, paid: 1500, allowEntryWhileDue: false,
  freezeDaysAllowed: 10, createdAt: new Date(), freezes: [], replacesId: null, ...o,
});

describe('dates', () => {
  it('end date = start + months - 1 day', () => {
    expect(planEndDate('2026-01-15', 1)).toBe('2026-02-14');
    expect(planEndDate('2026-01-01', 12)).toBe('2026-12-31');
    expect(planEndDate('2026-01-31', 1)).toBe('2026-02-27');
  });
  it('addMonths clamps to month end', () => {
    expect(addMonths('2024-01-31', 1)).toBe('2024-02-29');
  });
  it('today is in IST', () => {
    expect(todayIST(new Date('2026-11-01T19:00:00Z'))).toBe('2026-11-02');
    expect(todayIST(new Date('2026-11-01T18:00:00Z'))).toBe('2026-11-01');
  });
});

describe('status', () => {
  it('no plan', () => expect(computeState([], '2026-10-10').status).toBe('NO_PLAN'));
  it('active > 7 days, ending soon 0-7, expired after', () => {
    expect(computeState([sub({})], '2026-10-10').status).toBe('ACTIVE');
    expect(computeState([sub({})], '2026-10-24').status).toBe('ENDING_SOON');
    expect(computeState([sub({})], '2026-10-31').status).toBe('ENDING_SOON');
    expect(computeState([sub({})], '2026-11-01').status).toBe('EXPIRED');
  });
  it('freeze blocks entry and pushes the end date', () => {
    const s = sub({ freezes: [{ startDate: '2026-10-10', days: 5 }] });
    const st = computeState([s], '2026-10-12');
    expect(st.status).toBe('FROZEN');
    expect(st.endsOn).toBe('2026-11-05');
    expect(entryDecision(st).result).toBe('BLOCKED');
    expect(computeState([s], '2026-10-15').status).toBe('ACTIVE');
  });
  it('ending a freeze early returns the unused days', () => {
    const s = sub({ freezes: [{ startDate: '2026-10-10', days: 5, endedOn: '2026-10-12' }] });
    expect(computeState([s], '2026-10-12').endsOn).toBe('2026-11-02');
    expect(computeState([s], '2026-10-12').status).toBe('ACTIVE');
  });
  it('not paid yet: blocked unless the admin allowed entry', () => {
    const due = sub({ paid: 0 });
    expect(entryDecision(computeState([due], '2026-10-10'))).toEqual({ result: 'BLOCKED', reason: 'Payment due ₹1500' });
    const allowed = sub({ paid: 0, allowEntryWhileDue: true });
    expect(entryDecision(computeState([allowed], '2026-10-10')).result).toBe('WARNED');
  });
  it('renewal of active starts the day after end; of expired starts today', () => {
    expect(renewalStart(computeState([sub({})], '2026-10-25'), '2026-10-25')).toBe('2026-11-01');
    expect(renewalStart(computeState([sub({})], '2026-11-20'), '2026-11-20')).toBe('2026-11-20');
  });
  it('a renewal chain counts days to the end of the last one', () => {
    const a = sub({});
    const b = sub({ id: 's2', startDate: '2026-11-01', endDate: '2026-11-30' });
    const st = computeState([a, b], '2026-10-28');
    expect(st.status).toBe('ACTIVE');
    expect(st.endsOn).toBe('2026-11-30');
  });
  it('a corrected row is ignored', () => {
    const a = sub({ endDate: '2026-10-05' });
    const fix = sub({ id: 's2', replacesId: 's1', endDate: '2026-12-31' });
    expect(computeState([a, fix], '2026-10-20').status).toBe('ACTIVE');
  });
});

describe('qr token', () => {
  it('is valid now and in the previous window, not after a minute', () => {
    const t0 = 1_800_000_000_000;
    const { token } = makeQrToken('s', 'mem-1', t0);
    expect(verifyQrToken('s', token, t0)).toBe('mem-1');
    expect(verifyQrToken('s', token, t0 + 30_000)).toBe('mem-1');
    expect(verifyQrToken('s', token, t0 + 90_000)).toBeNull();
    expect(verifyQrToken('other', token, t0)).toBeNull();
    expect(verifyQrToken('s', token.replace('mem-1', 'mem-2'), t0)).toBeNull();
  });
});
