import { describe, it, expect } from 'vitest';
import { phoneDestination, buildPairingUrl, secondsLeft, formatShortCode, normalizeShortCode, isCompleteShortCode } from './phonePairing';

describe('phoneDestination', () => {
  it('opens the clinic phone page, with the patient when given', () => {
    expect(phoneDestination({ org: 'bright', booking: 'b1' })).toBe('/bright/phone?booking=b1');
    expect(phoneDestination({ org: 'bright' })).toBe('/bright/phone');
  });
  it('falls back to login without a clinic', () => {
    expect(phoneDestination({})).toBe('/login');
  });
});

describe('buildPairingUrl', () => {
  it('builds the sign-in link with the code', () => {
    expect(buildPairingUrl('https://x.test/', { orgSlug: 'bright', bookingId: 'b1', code: 'abc' }))
      .toBe('https://x.test/phone/pair?code=abc&org=bright&booking=b1');
  });
  it('falls back to the normal phone link without a code', () => {
    expect(buildPairingUrl('https://x.test', { orgSlug: 'bright', bookingId: 'b1' }))
      .toBe('https://x.test/bright/phone?booking=b1');
  });
});

describe('secondsLeft', () => {
  it('counts down and never goes negative', () => {
    const now = Date.parse('2026-10-04T10:00:00Z');
    expect(secondsLeft('2026-10-04T10:03:00Z', now)).toBe(180);
    expect(secondsLeft('2026-10-04T09:59:00Z', now)).toBe(0);
  });
});

describe('short code helpers', () => {
  it('formats for reading', () => {
    expect(formatShortCode('687028')).toBe('687 028');
    expect(formatShortCode(null)).toBe('');
  });
  it('accepts what a person types', () => {
    expect(normalizeShortCode('687 028')).toBe('687028');
    expect(normalizeShortCode('68-70x28999')).toBe('687028');
    expect(isCompleteShortCode('687 02')).toBe(false);
    expect(isCompleteShortCode('687 028')).toBe(true);
  });
});
