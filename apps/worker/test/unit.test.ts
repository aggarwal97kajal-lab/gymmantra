import { addMonths, planEndDate, todayIST } from '../src/lib/dates';
import { computeState, entryDecision, renewalStart, SubLike } from '../src/lib/status';
import { makeQrToken, verifyQrToken } from '../src/lib/qr';

const sub = (o: Partial<SubLike>): SubLike => ({
  id: 's1', startDate: '2026-10-01', endDate: '2026-10-31', total: 1500, paid: 1500, allowEntryWhileDue: false,
  freezeDaysAllowed: 10, createdAt: new Date().toISOString(), freezes: [], replacesId: null, ...o,
});

describe('dates', () => {
  it('end date = start + months - 1 day', () => {
    expect(planEndDate('2026-01-15', 1)).toBe('2026-02-14');
    expect(planEndDate('2026-01-01', 12)).toBe('2026-12-31');
    expect(planEndDate('2026-01-31', 1)).toBe('2026-02-27');
  });
  it('addMonths clamps to month end', () => expect(addMonths('2024-01-31', 1)).toBe('2024-02-29'));
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
  });
  it('not paid yet: blocked unless the admin allowed entry', () => {
    expect(entryDecision(computeState([sub({ paid: 0 })], '2026-10-10'))).toEqual({ result: 'BLOCKED', reason: 'Payment due ₹1,500' });
    expect(entryDecision(computeState([sub({ paid: 0, allowEntryWhileDue: true })], '2026-10-10')).result).toBe('WARNED');
  });
  it('renewal of active starts the day after end; of expired starts today', () => {
    expect(renewalStart(computeState([sub({})], '2026-10-25'), '2026-10-25')).toBe('2026-11-01');
    expect(renewalStart(computeState([sub({})], '2026-11-20'), '2026-11-20')).toBe('2026-11-20');
  });
});

describe('qr token', () => {
  it('is valid now and in the previous window, not after a minute', async () => {
    const t0 = 1_800_000_000_000;
    const { token } = await makeQrToken('s', 'mem-1', t0);
    expect(await verifyQrToken('s', token, t0)).toBe('mem-1');
    expect(await verifyQrToken('s', token, t0 + 30_000)).toBe('mem-1');
    expect(await verifyQrToken('s', token, t0 + 90_000)).toBeNull();
    expect(await verifyQrToken('other', token, t0)).toBeNull();
    expect(await verifyQrToken('s', token.replace('mem-1', 'mem-2'), t0)).toBeNull();
  });
});

describe('freeze moves the renewals after it', () => {
  const base = { id: 'a', replacesId: null, total: 1000, paid: 1000, allowEntryWhileDue: false, freezeDaysAllowed: 30, createdAt: '2026-01-01' };
  it('a 7-day freeze on this year moves next year too (owner and member see the later date)', () => {
    const y1 = { ...base, id: 'y1', startDate: '2026-11-04', endDate: '2027-11-03', freezes: [{ id: 'f', startDate: '2026-11-05', days: 7, endedOn: null }] };
    const y2 = { ...base, id: 'y2', startDate: '2027-11-04', endDate: '2028-11-03', freezes: [] };
    const st = computeState([y1, y2] as SubLike[], '2026-11-05');
    expect(st.status).toBe('FROZEN');
    expect(st.endsOn).toBe('2028-11-10');
    expect(st.frozenDays).toBe(7);
    // a year later, on the (moved) renewal, the end stays moved
    expect(computeState([y1, y2] as SubLike[], '2027-11-08').endsOn).toBe('2028-11-10');
    expect(computeState([y1, y2] as SubLike[], '2028-11-05').status).toBe('ENDING_SOON');
  });
});
