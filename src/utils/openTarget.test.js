import { describe, it, expect } from 'vitest';
import { parseOpenTarget } from './openTarget';

describe('parseOpenTarget', () => {
  it('reads a notification link', () => {
    expect(parseOpenTarget('?booking=b1&autostart=1&verify=1')).toEqual({ bookingId: 'b1', autoStart: true, verify: true });
  });
  it('defaults the flags to off', () => {
    expect(parseOpenTarget('?booking=b1')).toEqual({ bookingId: 'b1', autoStart: false, verify: false });
  });
  it('returns null without a booking', () => {
    expect(parseOpenTarget('?autostart=1')).toBeNull();
    expect(parseOpenTarget('')).toBeNull();
  });
  it('accepts URLSearchParams too', () => {
    expect(parseOpenTarget(new URLSearchParams({ booking: 'x' }))).toEqual({ bookingId: 'x', autoStart: false, verify: false });
  });
});
