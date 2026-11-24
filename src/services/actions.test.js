import { describe, it, expect, vi, beforeEach } from 'vitest';

// The action layer runs in the database (migration-012). Here the RPC is mocked: these tests pin down what the client sends,
// how the standard result { ok, action_id, data, error } is mapped, and that the two api.js functions that moved onto actions
// (updateBookingStatus, rescheduleBooking) keep their old signatures, result shapes and error codes.
const rpc = vi.fn();
vi.mock('lib/supabase', () => ({
  supabase: { rpc: (...a) => rpc(...a) },
  supabaseCustomer: {},
  supabasePlatform: {},
}));
vi.mock('lib/analytics', () => ({ capture: vi.fn(), identify: vi.fn(), reset: vi.fn(), setGroup: vi.fn() }));

const { runAction, ACTION_NAMES } = await import('./actions');
const { updateBookingStatus, rescheduleBooking } = await import('./api');

const ok = (data, action_id = 'act-1') => ({ data: { ok: true, action_id, data, error: null }, error: null });
const refused = (code, message, action_id = 'act-2') => ({ data: { ok: false, action_id, data: null, error: { code, message } }, error: null });

beforeEach(() => { rpc.mockReset(); vi.spyOn(console, 'error').mockImplementation(() => {}); });

describe('runAction', () => {
  it('knows the slice-1 actions and the twelve money actions', () => {
    expect(ACTION_NAMES.sort()).toEqual(['billing.set_mode', 'bill.cancel', 'booking.flag_not_confirmed', 'booking.reschedule', 'booking.set_status', 'day.close', 'day.expected', 'day.reopen', 'day.submit_count', 'document.print', 'document.send', 'money.collect', 'money.refund', 'money.request_decline', 'money.request_refund', 'undo'].sort());
  });

  it('maps each money action to its RPC and named arguments', async () => {
    rpc.mockResolvedValue(ok({}));
    const lines = [{ booking_id: 'b1', amount: 100 }]; const tenders = [{ mode: 'Cash', amount: 100 }];
    const cases = [
      ['money.collect', { lines, tenders, customerId: 'c1', buyerName: 'N', buyerPan: '123' }, 'act_money_collect', { p_lines: lines, p_tenders: tenders, p_customer: 'c1', p_buyer_name: 'N', p_buyer_pan: '123' }],
      ['money.collect', { lines, tenders }, 'act_money_collect', { p_lines: lines, p_tenders: tenders, p_customer: null, p_buyer_name: null, p_buyer_pan: null }],
      ['money.refund', { bookingId: 'b1', amount: 50, reason: 'r', paidBackBy: 'cash', requestId: 'q1' }, 'act_money_refund', { p_booking: 'b1', p_amount: 50, p_reason: 'r', p_paid_back_by: 'cash', p_request: 'q1' }],
      ['money.refund', { bookingId: 'b1', amount: 50, reason: 'r', paidBackBy: 'cash' }, 'act_money_refund', { p_booking: 'b1', p_amount: 50, p_reason: 'r', p_paid_back_by: 'cash', p_request: null }],
      ['money.request_refund', { documentId: 'd1', bookingId: 'b1', amount: 10 }, 'act_money_request_refund', { p_document: 'd1', p_booking: 'b1', p_amount: 10, p_note: null }],
      ['money.request_decline', { requestId: 'q1', note: 'no' }, 'act_money_request_decline', { p_request: 'q1', p_note: 'no' }],
      ['bill.cancel', { documentId: 'd1', reason: 'wrong patient' }, 'act_bill_cancel', { p_document: 'd1', p_reason: 'wrong patient' }],
      ['document.print', { documentId: 'd1' }, 'act_document_print', { p_document: 'd1' }],
      ['document.send', { documentId: 'd1', channel: 'sms', to: '+977' }, 'act_document_send', { p_document: 'd1', p_channel: 'sms', p_to: '+977' }],
      ['day.submit_count', { branchId: 'br', date: '2031-01-02', counts: { cash: 100 } }, 'act_day_submit_count', { p_branch: 'br', p_date: '2031-01-02', p_counts: { cash: 100 } }],
      ['day.expected', { branchId: 'br', date: '2031-01-02' }, 'act_day_expected', { p_branch: 'br', p_date: '2031-01-02' }],
      ['day.close', { branchId: 'br', date: '2031-01-02', differenceReason: 'short' }, 'act_day_close', { p_branch: 'br', p_date: '2031-01-02', p_difference_reason: 'short' }],
      ['day.close', { branchId: 'br', date: '2031-01-02' }, 'act_day_close', { p_branch: 'br', p_date: '2031-01-02', p_difference_reason: null }],
      ['day.reopen', { branchId: 'br', date: '2031-01-02', reason: 'missed' }, 'act_day_reopen', { p_branch: 'br', p_date: '2031-01-02', p_reason: 'missed' }],
      ['billing.set_mode', { pan: '123', panBillMode: true }, 'act_billing_set_mode', { p_pan: '123', p_mode: true }],
    ];
    for (const [name, inputs, fn, args] of cases) {
      await runAction(name, inputs);
      expect(rpc).toHaveBeenLastCalledWith(fn, args);
    }
  });

  it('hands a money refusal (with its data, e.g. the close blockers) back as ok:false', async () => {
    rpc.mockResolvedValue({ data: { ok: false, action_id: 'a9', data: [{ code: 'IN_CHAIR', booking_id: 'b1' }], error: { code: 'BLOCKERS', message: 'The day cannot be closed yet.' } }, error: null });
    const r = await runAction('day.close', { branchId: 'br', date: '2031-01-02' });
    expect(r.ok).toBe(false);
    expect(r.error).toEqual({ code: 'BLOCKERS', message: 'The day cannot be closed yet.' });
    expect(r.data).toEqual([{ code: 'IN_CHAIR', booking_id: 'b1' }]);
  });

  it('calls the matching RPC with named p_ arguments and maps a success', async () => {
    rpc.mockResolvedValue(ok({ status: 'Confirmed' }));
    const r = await runAction('booking.set_status', { bookingId: 'b1', status: 'Confirmed' });
    expect(rpc).toHaveBeenCalledWith('act_booking_set_status', { p_booking: 'b1', p_status: 'Confirmed', p_reason: null });
    expect(r).toEqual({ ok: true, actionId: 'act-1', data: { status: 'Confirmed' }, error: null });
  });

  it('maps each action to its RPC and arguments', async () => {
    rpc.mockResolvedValue(ok({}));
    await runAction('booking.reschedule', { bookingId: 'b1', date: '2031-01-02', startTime: '10:00', changes: { chair_id: 'c1' } });
    expect(rpc).toHaveBeenLastCalledWith('act_booking_reschedule', { p_booking: 'b1', p_date: '2031-01-02', p_start_time: '10:00', p_changes: { chair_id: 'c1' } });
    await runAction('booking.reschedule', { bookingId: 'b1', date: '2031-01-02', startTime: '10:00' });
    expect(rpc).toHaveBeenLastCalledWith('act_booking_reschedule', expect.objectContaining({ p_changes: {} }));
    await runAction('booking.flag_not_confirmed', { bookingId: 'b1', reason: '6 pm' });
    expect(rpc).toHaveBeenLastCalledWith('act_booking_flag_not_confirmed', { p_booking: 'b1', p_reason: '6 pm' });
    await runAction('undo', { actionId: 'a9', reason: 'oops' });
    expect(rpc).toHaveBeenLastCalledWith('act_undo', { p_action_id: 'a9', p_reason: 'oops' });
  });

  it('maps a refusal to ok:false with the server error code and message', async () => {
    rpc.mockResolvedValue(refused('FORBIDDEN', 'You can only change your own bookings.'));
    const r = await runAction('booking.set_status', { bookingId: 'b1', status: 'In-Progress' });
    expect(r).toEqual({ ok: false, actionId: 'act-2', data: null, error: { code: 'FORBIDDEN', message: 'You can only change your own bookings.' } });
  });

  it('maps an RPC / transport error to ok:false (it does not throw)', async () => {
    rpc.mockResolvedValue({ data: null, error: { code: '42501', message: 'permission denied for function act_undo' } });
    const r = await runAction('undo', { actionId: 'a9' });
    expect(r).toEqual({ ok: false, actionId: null, data: null, error: { code: '42501', message: 'permission denied for function act_undo' } });
  });

  it('treats an empty result as a failure', async () => {
    rpc.mockResolvedValue({ data: null, error: null });
    const r = await runAction('undo', { actionId: 'a9' });
    expect(r.ok).toBe(false);
    expect(r.error.code).toBe('ACTION_FAILED');
  });

  it('throws on an unknown action name (a programming error)', async () => {
    await expect(runAction('booking.teleport', {})).rejects.toThrow(/Unknown action/);
  });
});

describe('updateBookingStatus (moved onto booking.set_status)', () => {
  it('keeps its result shape', async () => {
    rpc.mockResolvedValue(ok({ booking_id: 'b1', from_status: 'Pending', status: 'Confirmed' }));
    const r = await updateBookingStatus({ bookingId: 'b1', newStatus: 'Confirmed' });
    expect(rpc).toHaveBeenCalledWith('act_booking_set_status', { p_booking: 'b1', p_status: 'Confirmed', p_reason: null });
    expect(r).toEqual({ data: { success: true, bookingId: 'b1', status: 'Confirmed' }, error: null });
  });

  it('passes the reason for a cancellation', async () => {
    rpc.mockResolvedValue(ok({ booking_id: 'b1', from_status: 'Pending', status: 'Cancelled' }));
    await updateBookingStatus({ bookingId: 'b1', newStatus: 'Cancelled', reason: 'patient asked' });
    expect(rpc).toHaveBeenCalledWith('act_booking_set_status', { p_booking: 'b1', p_status: 'Cancelled', p_reason: 'patient asked' });
  });

  it.each([
    ['REASON_REQUIRED', 'A reason is required when cancelling or marking a booking as no-show.'],
    ['INVALID_STATUS_TRANSITION', 'Cannot transition from Confirmed to Completed.'],
    ['DAY_LOCKED', 'This day has been closed. No further modifications allowed.'],
    ['BOOKING_IMMUTABLE', 'Cancelled bookings cannot be modified.'],
    ['BOOKING_NOT_FOUND', 'Booking not found.'],
  ])('returns the old error code %s with the same message', async (code, message) => {
    rpc.mockResolvedValue(refused(code, message));
    const r = await updateBookingStatus({ bookingId: 'b1', newStatus: 'Completed' });
    expect(r).toEqual({ data: null, error: { code, message } });
  });

  it('returns a refused-by-permission error as an error, not a throw', async () => {
    rpc.mockResolvedValue(refused('FORBIDDEN', 'Your role cannot change bookings.'));
    const r = await updateBookingStatus({ bookingId: 'b1', newStatus: 'Confirmed' });
    expect(r.data).toBeNull();
    expect(r.error.code).toBe('FORBIDDEN');
  });
});

describe('rescheduleBooking (moved onto booking.reschedule)', () => {
  it('sends only the changes that were asked for: undefined = leave as is', async () => {
    rpc.mockResolvedValue(ok({ booking_id: 'b1', date: '2031-01-02', start_time: '10:00:00', end_time: '10:30:00', dentist_id: 'd1', chair_id: 'c1' }));
    await rescheduleBooking({ bookingId: 'b1', newDate: '2031-01-02', newStartTime: '10:00' });
    expect(rpc).toHaveBeenLastCalledWith('act_booking_reschedule', { p_booking: 'b1', p_date: '2031-01-02', p_start_time: '10:00', p_changes: {} });
    await rescheduleBooking({ bookingId: 'b1', newDate: '2031-01-02', newStartTime: '10:00', newDentistId: 'd2', newChairId: 'c2' });
    expect(rpc).toHaveBeenLastCalledWith('act_booking_reschedule', expect.objectContaining({ p_changes: { dentist_id: 'd2', chair_id: 'c2' } }));
  });

  it("maps 'unassigned' and null to a clear", async () => {
    rpc.mockResolvedValue(ok({}));
    await rescheduleBooking({ bookingId: 'b1', newDate: '2031-01-02', newStartTime: '10:00', newDentistId: 'unassigned', newChairId: null });
    expect(rpc).toHaveBeenLastCalledWith('act_booking_reschedule', expect.objectContaining({ p_changes: { dentist_id: null, chair_id: null } }));
  });

  it('keeps its result shape', async () => {
    rpc.mockResolvedValue(ok({ booking_id: 'b1', date: '2031-01-02', start_time: '10:00:00', end_time: '10:30:00', dentist_id: 'd1', chair_id: 'c1' }));
    const r = await rescheduleBooking({ bookingId: 'b1', newDate: '2031-01-02', newStartTime: '10:00' });
    expect(r).toEqual({ data: { success: true, bookingId: 'b1', bookingDate: '2031-01-02', startTime: '10:00:00', endTime: '10:30:00', dentistId: 'd1', chairId: 'c1' }, error: null });
  });

  it.each([
    ['CHAIR_CONFLICT', 'Chair Z is fully booked at this time (1/1 slots used). Change the chair or pick a different time.'],
    ['DENTIST_CONFLICT', 'Dentist is already booked during this time slot.'],
    ['DENTIST_CHECKED_OUT', 'Dr A already checked out for this date.'],
    ['BOOKING_IMMUTABLE', 'Cannot reschedule a paid booking.'],
  ])('returns the old error code %s with the same message', async (code, message) => {
    rpc.mockResolvedValue(refused(code, message));
    const r = await rescheduleBooking({ bookingId: 'b1', newDate: '2031-01-02', newStartTime: '10:00' });
    expect(r).toEqual({ data: null, error: { code, message } });
  });
});
