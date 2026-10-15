import { describe, it, expect } from 'vitest';
import { formatVisitDate, lastVisitLabel } from './visitDates';

describe('formatVisitDate', () => {
  it('formats a date-only string without shifting the day', () => {
    expect(formatVisitDate('2026-10-04')).toBe('4 Oct 2026');
    expect(formatVisitDate('2026-01-01')).toBe('1 Jan 2026');
  });
  it('handles timestamps and empty or invalid input', () => {
    expect(formatVisitDate('2026-10-04T09:30:00')).toBe('4 Oct 2026');
    expect(formatVisitDate(null)).toBe('');
    expect(formatVisitDate('not a date')).toBe('');
  });
});

describe('lastVisitLabel', () => {
  it('shows the date of the previous visit', () => {
    expect(lastVisitLabel({ date: '2026-09-29' })).toMatch(/^29 Sep(t)? 2026$/); // some ICU versions write "Sept"
  });
  it('says First visit when there is none', () => {
    expect(lastVisitLabel(null)).toBe('First visit');
    expect(lastVisitLabel({})).toBe('First visit');
  });
});
