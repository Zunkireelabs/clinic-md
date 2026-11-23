import { describe, it, expect, vi, beforeEach } from 'vitest';

// The action layer runs in the database (migration-012). Here the RPC is mocked: these tests pin down what the client sends,
// how the standard result { ok, action_id, data, error } is mapped, and that the two api.js functions that moved onto actions
// (updateBookingStatus, rescheduleBooking) keep their old signatures, result shapes and error codes.
const rpc = vi.fn();
const invoke = vi.fn();
vi.mock('lib/supabase', () => ({
  supabase: { rpc: (...a) => rpc(...a), functions: { invoke: (...a) => invoke(...a) } },
  supabaseCustomer: {},
  supabasePlatform: {},
}));
vi.mock('lib/analytics', () => ({ capture: vi.fn(), identify: vi.fn(), reset: vi.fn(), setGroup: vi.fn() }));

const { runAction, ACTION_NAMES } = await import('./actions');
const { updateBookingStatus, rescheduleBooking } = await import('./api');

const ok = (data, action_id = 'act-1') => ({ data: { ok: true, action_id, data, error: null }, error: null });
const refused = (code, message, action_id = 'act-2') => ({ data: { ok: false, action_id, data: null, error: { code, message } }, error: null });

beforeEach(() => { rpc.mockReset(); invoke.mockReset(); vi.spyOn(console, 'error').mockImplementation(() => {}); });

describe('runAction', () => {
  it('knows the booking actions and the patient actions', () => {
    expect([...ACTION_NAMES].sort()).toEqual([
      'alert.add', 'alert.confirm', 'alert.remove', 'alert.update',
      'booking.flag_not_confirmed', 'booking.reschedule', 'booking.set_status',
      'consent.record_marketing_yes',
      'duplicates.dismiss', 'duplicates.link_family', 'duplicates.merge',
      'family.link', 'family.set_contact', 'family.unlink',
      'form.record_typed', 'form.send_link', 'form.start_on_device',
      'patient.archive', 'patient.create', 'patient.erase', 'patient.restore', 'patient.undo', 'patient.update',
      'undo',
    ]);
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

describe('patient actions (migration-019)', () => {
  const cases = [
    ['patient.create', { data: { full_name: 'A' }, branchId: 'br', joinCustomerId: 'c2' }, 'act_patient_create', { p_data: { full_name: 'A' }, p_branch: 'br', p_join_customer: 'c2' }],
    ['patient.create', { data: { full_name: 'A' } }, 'act_patient_create', { p_data: { full_name: 'A' }, p_branch: null, p_join_customer: null }],
    ['patient.update', { customerId: 'c1', changes: { address: 'x' } }, 'act_patient_update', { p_customer: 'c1', p_changes: { address: 'x' } }],
    ['alert.add', { customerId: 'c1', type: 'allergy', text: 'Penicillin', severity: 'danger' }, 'act_alert_add', { p_customer: 'c1', p_type: 'allergy', p_text: 'Penicillin', p_details: null, p_severity: 'danger' }],
    ['alert.add', { customerId: 'c1', type: 'other', text: 't' }, 'act_alert_add', { p_customer: 'c1', p_type: 'other', p_text: 't', p_details: null, p_severity: 'note' }],
    ['alert.confirm', { alertId: 'a1' }, 'act_alert_confirm', { p_alert: 'a1' }],
    ['alert.update', { alertId: 'a1', changes: { severity: 'caution' } }, 'act_alert_update', { p_alert: 'a1', p_changes: { severity: 'caution' } }],
    ['alert.remove', { alertId: 'a1' }, 'act_alert_remove', { p_alert: 'a1' }],
    ['family.link', { customerId: 'c1', withCustomerId: 'c2' }, 'act_family_link', { p_customer: 'c1', p_family: null, p_with_customer: 'c2' }],
    ['family.link', { customerId: 'c1', familyId: 'f1' }, 'act_family_link', { p_customer: 'c1', p_family: 'f1', p_with_customer: null }],
    ['family.unlink', { customerId: 'c1' }, 'act_family_unlink', { p_customer: 'c1' }],
    ['family.set_contact', { familyId: 'f1', customerId: 'c1' }, 'act_family_set_contact', { p_family: 'f1', p_customer: 'c1' }],
    ['form.send_link', { customerId: 'c1', templateId: 't1' }, 'act_form_send_link', { p_customer: 'c1', p_template: 't1' }],
    ['form.start_on_device', { customerId: 'c1', templateId: 't1' }, 'act_form_start_on_device', { p_customer: 'c1', p_template: 't1' }],
    ['form.record_typed', { customerId: 'c1', templateId: 't1', answers: { a: 1 } }, 'act_form_record_typed', { p_customer: 'c1', p_template: 't1', p_answers: { a: 1 } }],
    ['consent.record_marketing_yes', { customerId: 'c1', address: '+977', evidence: 'said yes' }, 'act_consent_marketing_yes', { p_customer: 'c1', p_channel: 'sms', p_address: '+977', p_evidence: 'said yes' }],
    ['consent.record_marketing_yes', { customerId: 'c1' }, 'act_consent_marketing_yes', { p_customer: 'c1', p_channel: 'sms', p_address: null, p_evidence: '' }],
    ['patient.archive', { customerId: 'c1', reason: 'moved' }, 'act_patient_archive', { p_customer: 'c1', p_reason: 'moved' }],
    ['patient.restore', { customerId: 'c1' }, 'act_patient_restore', { p_customer: 'c1' }],
    ['duplicates.merge', { keepId: 'k', dropId: 'd' }, 'act_duplicates_merge', { p_keep: 'k', p_drop: 'd' }],
    ['duplicates.dismiss', { aId: 'a', bId: 'b' }, 'act_duplicates_dismiss', { p_a: 'a', p_b: 'b' }],
    ['duplicates.link_family', { aId: 'a', bId: 'b' }, 'act_duplicates_link_family', { p_a: 'a', p_b: 'b' }],
    ['patient.undo', { actionId: 'x9' }, 'act_patient_undo', { p_action_id: 'x9' }],
  ];
  it.each(cases)('%s sends the right RPC and arguments', async (name, inputs, fn, args) => {
    rpc.mockResolvedValue(ok({}));
    const r = await runAction(name, inputs);
    expect(rpc).toHaveBeenCalledWith(fn, args);
    expect(r.ok).toBe(true);
  });

  it('returns the matches when the phone already exists (the screen asks "same family?")', async () => {
    rpc.mockResolvedValue({ data: { ok: false, action_id: null, data: { matches: [{ id: 'c9', patient_no: 12, full_name: 'B', family_id: null }] }, error: { code: 'PHONE_EXISTS', message: 'exists' } }, error: null });
    const r = await runAction('patient.create', { data: { full_name: 'A', phone: '980' } });
    expect(r.ok).toBe(false);
    expect(r.error.code).toBe('PHONE_EXISTS');
    expect(r.data.matches[0].id).toBe('c9');
  });

  it('passes a form token through once, as data', async () => {
    rpc.mockResolvedValue(ok({ submission_id: 's1', token: 'a'.repeat(64) }));
    const r = await runAction('form.send_link', { customerId: 'c1', templateId: 't1' });
    expect(r.data.token).toHaveLength(64);
  });

  it('maps a front-desk refusal (alert.confirm)', async () => {
    rpc.mockResolvedValue(refused('FORBIDDEN', 'Only a practitioner can confirm an alert.'));
    const r = await runAction('alert.confirm', { alertId: 'a1' });
    expect(r).toEqual({ ok: false, actionId: 'act-2', data: null, error: { code: 'FORBIDDEN', message: 'Only a practitioner can confirm an alert.' } });
  });

  it('patient.erase calls the patient-erase edge function, not an RPC', async () => {
    invoke.mockResolvedValue({ data: { ok: true, action_id: 'e1', data: { label: 'Erased patient P-00012' }, error: null }, error: null });
    const r = await runAction('patient.erase', { customerId: 'c1', requestPath: 'o/c1/req.pdf', typedName: 'A B' });
    expect(invoke).toHaveBeenCalledWith('patient-erase', { body: { customerId: 'c1', requestPath: 'o/c1/req.pdf', typedName: 'A B' } });
    expect(rpc).not.toHaveBeenCalled();
    expect(r).toEqual({ ok: true, actionId: 'e1', data: { label: 'Erased patient P-00012' }, error: null });
  });

  it('patient.erase: a non-2xx edge reply still returns the action refusal', async () => {
    invoke.mockResolvedValue({ data: null, error: { context: { json: async () => ({ ok: false, action_id: null, data: null, error: { code: 'REQUEST_FILE_MISSING', message: 'Upload the request first.' } }) } } });
    const r = await runAction('patient.erase', { customerId: 'c1', requestPath: 'x', typedName: 'A' });
    expect(r.ok).toBe(false);
    expect(r.error.code).toBe('REQUEST_FILE_MISSING');
  });

  it('patient.erase: a transport failure with no JSON body is ok:false, not a throw', async () => {
    invoke.mockResolvedValue({ data: null, error: { message: 'Failed to send a request to the Edge Function' } });
    const r = await runAction('patient.erase', { customerId: 'c1', requestPath: 'x', typedName: 'A' });
    expect(r).toEqual({ ok: false, actionId: null, data: null, error: { code: 'ACTION_FAILED', message: 'Failed to send a request to the Edge Function' } });
  });
});
