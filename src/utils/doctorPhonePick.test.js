import { describe, it, expect } from 'vitest';
import { decideOpenAction } from './doctorPhonePick';

const b = (id) => ({ id });

describe('decideOpenAction', () => {
  it('opens the only patient in progress', () => {
    expect(decideOpenAction({ bookings: [b('1')], suppressAuto: false })).toEqual({ type: 'auto', bookingId: '1' });
  });

  it('shows a list when several are in progress', () => {
    expect(decideOpenAction({ bookings: [b('1'), b('2')], suppressAuto: false })).toEqual({ type: 'list' });
  });

  it('waits when nobody is in progress', () => {
    expect(decideOpenAction({ bookings: [], suppressAuto: false })).toEqual({ type: 'none' });
  });

  it('does not re-open after the doctor pressed Done', () => {
    expect(decideOpenAction({ bookings: [b('1')], suppressAuto: true })).toEqual({ type: 'list' });
  });
});
