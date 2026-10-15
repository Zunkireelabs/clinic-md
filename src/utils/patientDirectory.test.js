import { describe, it, expect } from 'vitest';
import {
  buildPatientDirectory, matchesSearch, phoneSearchDigits, relativeDayLabel, sortPatients, segmentCounts, SEGMENTS, initials, monthsSince,
} from './patientDirectory';

const NOW = new Date(2026, 9, 14, 11, 0); // Wed 14 Oct 2026, 11:00 local
const cust = (id, extra = {}) => ({ id, full_name: `P ${id}`, phone: '+9779841234567', email: '', gender: '', created_at: '2026-01-01T00:00:00Z', ...extra });
const bk = (customer_id, extra = {}) => {
  const b = { customer_id, status: 'Completed', payment_status: 'paid', final_amount: 1000, date: '2026-10-01', start_time: '10:00:00', treatment_name_snapshot: 'Cleaning', dentist_id: 'd1', ...extra };
  // Money comes from payments (never payment_status): a 'paid' fixture without explicit payments gets a full payment.
  return { ...b, payments: extra.payments ?? (b.payment_status === 'paid' ? [{ amount: b.final_amount }] : []) };
};
const one = (bookings, c = cust('a')) => buildPatientDirectory({ customers: [c], bookings, now: NOW })[0];

describe('lastVisit', () => {
  it('is the latest Completed/In-Progress booking on or before today, never a future one', () => {
    const p = one([
      bk('a', { date: '2026-09-01', treatment_name_snapshot: 'Old' }),
      bk('a', { date: '2026-10-14', status: 'In-Progress', treatment_name_snapshot: 'Today' }),
      bk('a', { date: '2026-10-20', status: 'Completed', treatment_name_snapshot: 'Future' }),
      bk('a', { date: '2026-10-10', status: 'Cancelled' }),
    ]);
    expect(p.lastVisit).toEqual({ date: '2026-10-14', treatment: 'Today' });
  });
  it('is null with no visits', () => expect(one([]).lastVisit).toBeNull());
});

describe('nextAppointment', () => {
  it('is the earliest Pending/Confirmed booking in the future', () => {
    const p = one([
      bk('a', { status: 'Confirmed', date: '2026-10-19', start_time: '11:30:00', treatment_name_snapshot: 'B' }),
      bk('a', { status: 'Pending', date: '2026-10-16', start_time: '09:30:00', treatment_name_snapshot: 'A' }),
      bk('a', { status: 'Cancelled', date: '2026-10-15' }),
      bk('a', { status: 'No Show', date: '2026-10-15' }),
    ]);
    expect(p.nextAppointment).toEqual({ date: '2026-10-16', time: '09:30', treatment: 'A' });
  });
  it('today counts only when its start time is later than now', () => {
    expect(one([bk('a', { status: 'Confirmed', date: '2026-10-14', start_time: '15:00:00' })]).nextAppointment?.time).toBe('15:00');
    expect(one([bk('a', { status: 'Confirmed', date: '2026-10-14', start_time: '09:00:00' })]).nextAppointment).toBeNull();
  });
  it('uses the local date, not UTC (Nepal late evening)', () => {
    const late = new Date(2026, 9, 14, 23, 30); // local 23:30 is already 14 Oct UTC-wise differently; must still be 14 Oct
    const p = buildPatientDirectory({ customers: [cust('a')], bookings: [bk('a', { status: 'Confirmed', date: '2026-10-15', start_time: '09:00:00' })], now: late })[0];
    expect(p.nextAppointment.date).toBe('2026-10-15');
  });
});

describe('inClinic / visits / isNew', () => {
  it('inClinic needs an In-Progress booking today', () => {
    expect(one([bk('a', { status: 'In-Progress', date: '2026-10-14' })]).inClinic).toBe(true);
    expect(one([bk('a', { status: 'In-Progress', date: '2026-10-13' })]).inClinic).toBe(false);
  });
  it('visits counts Completed + In-Progress only', () => {
    expect(one([bk('a'), bk('a', { status: 'In-Progress' }), bk('a', { status: 'Confirmed', date: '2026-11-01' }), bk('a', { status: 'Cancelled' })]).visits).toBe(2);
  });
  it('isNew when created this month', () => {
    expect(one([], cust('a', { created_at: '2026-10-02T05:00:00Z' })).isNew).toBe(true);
    expect(one([], cust('a', { created_at: '2026-09-30T05:00:00Z' })).isNew).toBe(false);
  });
});

describe('today view / first-time', () => {
  it('todayTime is the earliest non-cancelled booking today', () => {
    const p = one([
      bk('a', { status: 'Confirmed', date: '2026-10-14', start_time: '16:00:00' }),
      bk('a', { status: 'Completed', date: '2026-10-14', start_time: '09:00:00' }),
      bk('a', { status: 'Cancelled', date: '2026-10-14', start_time: '08:00:00' }),
      bk('a', { status: 'Confirmed', date: '2026-10-15', start_time: '07:00:00' }),
    ]);
    expect(p.todayTime).toBe('09:00');
    expect(SEGMENTS.today(p)).toBe(true);
  });
  it('is not in Today with only cancelled/no-show bookings today', () => {
    expect(SEGMENTS.today(one([bk('a', { status: 'Cancelled', date: '2026-10-14' }), bk('a', { status: 'No Show', date: '2026-10-14' })]))).toBe(false);
  });
  it('sorts the today view by appointment time', () => {
    const rows = [{ fullName: 'B', todayTime: '16:00' }, { fullName: 'A', todayTime: '09:00' }, { fullName: 'C', todayTime: null }];
    expect(sortPatients(rows, 'today').map((r) => r.fullName)).toEqual(['A', 'B', 'C']);
  });
  it('exposes the in-progress booking id and a later-today confirmed flag', () => {
    const p = one([bk('a', { id: 'b1', status: 'In-Progress', date: '2026-10-14' }), bk('a', { id: 'b2', status: 'Confirmed', date: '2026-10-14', start_time: '15:00:00' })]);
    expect(p.inProgressId).toBe('b1');
    expect(p.laterTodayConfirmedId).toBe('b2');
    expect(one([bk('a', { status: 'Confirmed', date: '2026-10-14', start_time: '09:00:00' })]).laterTodayConfirmedId).toBeNull();
  });
  it('isFirstTime only while there is no Completed/In-Progress visit', () => {
    expect(one([bk('a', { status: 'Confirmed', date: '2026-10-20' })]).isFirstTime).toBe(true);
    expect(one([bk('a', { status: 'Completed' })]).isFirstTime).toBe(false);
    expect(one([bk('a', { status: 'In-Progress', date: '2026-10-14' })]).isFirstTime).toBe(false);
  });
});

describe('money (from bookingMoney)', () => {
  const p = one([
    bk('a', { payment_status: 'unpaid', final_amount: 5000 }),                                                      // due 5000
    bk('a', { payment_status: 'partial', final_amount: 3000, payments: [{ amount: 1000 }] }),                        // due 2000
    bk('a', { payment_status: 'unpaid', final_amount: 9999, status: 'Cancelled' }),                                 // void
    bk('a', { payment_status: 'paid', final_amount: 2000 }),                                                        // paid 2000
    bk('a', { status: 'Confirmed', date: '2026-10-19', payment_status: 'partial', final_amount: 3000, payments: [{ amount: 1000 }] }), // upcoming 2000, deposit 1000
    bk('a', { status: 'Confirmed', date: '2026-10-12', payment_status: 'unpaid', final_amount: 700, treatment_name_snapshot: 'Filling' }), // unclosed
  ]);
  it('balance is what is owed for rendered visits only', () => {
    expect(p.balance).toBe(7000);
    expect(p.unpaidVisits).toBe(2);
  });
  it('splits upcoming, deposit and unclosed out of the balance', () => {
    expect(p.upcoming).toBe(2000);
    expect(p.deposit).toBe(1000);
    expect(p.credit).toBe(0);
    expect(p.unclosed).toEqual([{ id: undefined, date: '2026-10-12', treatment: 'Filling', status: 'Confirmed', atStake: 700 }]);
  });
  it('flags a previous-day In-Progress visit as stale without adding to at-stake', () => {
    const q = one([bk('a', { status: 'In-Progress', date: '2026-10-13', payment_status: 'unpaid', final_amount: 800, id: 'ip' })]);
    expect(q.staleInProgress).toEqual([{ id: 'ip', date: '2026-10-13', treatment: 'Cleaning', status: 'In-Progress' }]);
    expect(q.balance).toBe(800);
    expect(q.unclosed).toEqual([]);
  });
  it('lifetime (paid to date) is every payment recorded, deposits included', () => {
    expect(p.lifetime).toBe(4000);
  });
  it('a future unpaid booking is not owed', () => {
    const q = one([bk('a', { status: 'Confirmed', date: '2026-10-19', payment_status: 'unpaid', final_amount: 3000 })]);
    expect(q.balance).toBe(0);
    expect(q.upcoming).toBe(3000);
    expect(SEGMENTS.owes(q)).toBe(false);
  });
});

describe('lapsed', () => {
  it('needs a last visit older than 180 days and no next appointment', () => {
    expect(one([bk('a', { date: '2026-03-11' })]).lapsed).toBe(true);
    expect(one([bk('a', { date: '2026-08-11' })]).lapsed).toBe(false);
    expect(one([bk('a', { date: '2026-03-11' }), bk('a', { status: 'Confirmed', date: '2026-10-20' })]).lapsed).toBe(false);
    expect(one([]).lapsed).toBe(false);
  });
});

describe('filters', () => {
  it('collects dentists and treatments', () => {
    const p = one([bk('a', { dentist_id: 'd1' }), bk('a', { dentist_id: 'd2', treatment_name_snapshot: 'Whitening' })]);
    expect(p.dentistIds.sort()).toEqual(['d1', 'd2']);
    expect(p.treatments.sort()).toEqual(['Cleaning', 'Whitening']);
  });
  it('segment counts', () => {
    const list = buildPatientDirectory({
      customers: [cust('a'), cust('b')],
      bookings: [bk('a', { payment_status: 'unpaid' }), bk('b', { status: 'In-Progress', date: '2026-10-14' })],
      now: NOW,
    });
    const c = segmentCounts(list);
    expect(c).toMatchObject({ all: 2, today: 1, owes: 1 });
    expect(list.filter(SEGMENTS.today)).toHaveLength(1);
  });
});

describe('search', () => {
  const p = { fullName: 'Hari Maharjan', email: 'p35@busy.seed.test', phone: '+977 984-276-1543' };
  it('matches name and email', () => {
    expect(matchesSearch(p, 'maharj')).toBe(true);
    expect(matchesSearch(p, 'BUSY.seed')).toBe(true);
    expect(matchesSearch(p, 'zzz')).toBe(false);
  });
  it('matches phone ignoring spaces, dashes and +977', () => {
    expect(matchesSearch(p, '984 276')).toBe(true);
    expect(matchesSearch(p, '+977 984-276')).toBe(true);
    expect(matchesSearch(p, '9842761543')).toBe(true);
    expect(matchesSearch(p, '985')).toBe(false);
  });
  it('phoneSearchDigits strips +977 and a trunk zero', () => {
    expect(phoneSearchDigits('+977 984')).toBe('984');
    expect(phoneSearchDigits('0984')).toBe('984');
  });
});

describe('sort & labels', () => {
  it('next appointment sorts soonest first with none last', () => {
    const rows = [
      { fullName: 'C', nextAppointment: null, visits: 0, balance: 0 },
      { fullName: 'B', nextAppointment: { date: '2026-10-16', time: '09:00' }, visits: 0, balance: 0 },
      { fullName: 'A', nextAppointment: { date: '2026-10-15', time: '10:00' }, visits: 0, balance: 0 },
    ];
    expect(sortPatients(rows, 'next').map((r) => r.fullName)).toEqual(['A', 'B', 'C']);
    expect(sortPatients(rows, 'next', 'desc').map((r) => r.fullName)).toEqual(['B', 'A', 'C']);
  });
  it('relative day labels', () => {
    expect(relativeDayLabel('2026-10-14', '2026-10-14')).toBe('Today');
    expect(relativeDayLabel('2026-10-15', '2026-10-14')).toBe('Tomorrow');
    expect(relativeDayLabel('2026-10-13', '2026-10-14')).toBe('Yesterday');
    expect(relativeDayLabel('2026-10-16', '2026-10-14')).toBe('Fri 16 Oct');
    expect(relativeDayLabel('2026-10-02', '2026-10-14')).toBe('2 Oct');
    expect(relativeDayLabel('2025-03-11', '2026-10-14')).toBe('11 Mar 2025');
  });
  it('monthsSince and initials', () => {
    expect(monthsSince('2026-03-11', '2026-10-14')).toBe(7);
    expect(initials('Hari Maharjan')).toBe('HM');
    expect(initials('Sunita')).toBe('S');
  });
});
