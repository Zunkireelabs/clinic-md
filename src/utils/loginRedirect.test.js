import { describe, it, expect } from 'vitest';
import { safeNextPath, loginPathWithNext } from './loginRedirect';

describe('safeNextPath', () => {
  it('allows a path inside the same org', () => {
    expect(safeNextPath('/bright-smile-dental/bookings/1/consultation', 'bright-smile-dental'))
      .toBe('/bright-smile-dental/bookings/1/consultation');
  });

  it('rejects other orgs, external URLs and protocol-relative links', () => {
    expect(safeNextPath('/other/dashboard', 'bright-smile-dental')).toBeNull();
    expect(safeNextPath('https://evil.test/bright-smile-dental/x', 'bright-smile-dental')).toBeNull();
    expect(safeNextPath('//evil.test/bright-smile-dental/x', 'bright-smile-dental')).toBeNull();
    expect(safeNextPath('/bright-smile-dental/\\evil', 'bright-smile-dental')).toBeNull();
  });

  it('handles missing values', () => {
    expect(safeNextPath(null, 'a')).toBeNull();
    expect(safeNextPath('/a/x', null)).toBeNull();
  });
});

describe('loginPathWithNext', () => {
  it('encodes the page to return to', () => {
    expect(loginPathWithNext('o', '/o/bookings/1/consultation', '?x=1'))
      .toBe('/o/login?next=%2Fo%2Fbookings%2F1%2Fconsultation%3Fx%3D1');
  });
});
