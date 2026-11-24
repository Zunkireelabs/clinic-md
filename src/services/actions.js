import { supabase } from '../lib/supabase';

/**
 * Client wrapper for the server-side action layer (migration-012, CMD-78).
 *
 * An action is one thing the clinic can do, run in the database: permission check, validation against live data, the change,
 * one audit row (action_log) and, where possible, an undo. Screens and `api.js` call actions through `runAction`; they never
 * decide permissions or lifecycle rules themselves.
 *
 * Every action returns `{ ok, actionId, data, error }`; `error` is `{ code, message }` or null. `runAction` never throws for an
 * action refusal or an RPC/transport error: both come back as `ok: false` with an error object.
 */
const ACTIONS = {
  'booking.set_status': {
    rpc: 'act_booking_set_status',
    args: ({ bookingId, status, reason }) => ({ p_booking: bookingId, p_status: status, p_reason: reason ?? null }),
  },
  // `changes` may hold dentist_id and chair_id (id, or null to clear). A missing key means "leave as is".
  'booking.reschedule': {
    rpc: 'act_booking_reschedule',
    args: ({ bookingId, date, startTime, changes }) => ({ p_booking: bookingId, p_date: date, p_start_time: startTime, p_changes: changes ?? {} }),
  },
  'booking.flag_not_confirmed': {
    rpc: 'act_booking_flag_not_confirmed',
    args: ({ bookingId, reason }) => ({ p_booking: bookingId, p_reason: reason ?? null }),
  },
  // Money (migration-021, CMD-115). Part 0 only maps them; the screens that call them come in later parts. `lines` is
  // [{ booking_id, amount }] and `tenders` [{ mode, amount, package_id? }]; the tenders must add up to the lines.
  'money.collect': {
    rpc: 'act_money_collect',
    args: ({ lines, tenders, customerId, buyerName, buyerPan }) => ({ p_lines: lines, p_tenders: tenders, p_customer: customerId ?? null, p_buyer_name: buyerName ?? null, p_buyer_pan: buyerPan ?? null }),
  },
  'money.refund': {
    rpc: 'act_money_refund',
    args: ({ bookingId, amount, reason, paidBackBy, requestId }) => ({ p_booking: bookingId, p_amount: amount, p_reason: reason, p_paid_back_by: paidBackBy, p_request: requestId ?? null }),
  },
  'money.request_refund': {
    rpc: 'act_money_request_refund',
    args: ({ documentId, bookingId, amount, note }) => ({ p_document: documentId, p_booking: bookingId, p_amount: amount, p_note: note ?? null }),
  },
  'money.request_decline': {
    rpc: 'act_money_request_decline',
    args: ({ requestId, note }) => ({ p_request: requestId, p_note: note ?? null }),
  },
  'bill.cancel': {
    rpc: 'act_bill_cancel',
    args: ({ documentId, reason }) => ({ p_document: documentId, p_reason: reason }),
  },
  'document.print': {
    rpc: 'act_document_print',
    args: ({ documentId }) => ({ p_document: documentId }),
  },
  'document.send': {
    rpc: 'act_document_send',
    args: ({ documentId, channel, to }) => ({ p_document: documentId, p_channel: channel, p_to: to }),
  },
  'day.submit_count': {
    rpc: 'act_day_submit_count',
    args: ({ branchId, date, counts }) => ({ p_branch: branchId, p_date: date, p_counts: counts }),
  },
  'day.expected': {
    rpc: 'act_day_expected',
    args: ({ branchId, date }) => ({ p_branch: branchId, p_date: date }),
  },
  'day.close': {
    rpc: 'act_day_close',
    args: ({ branchId, date, differenceReason }) => ({ p_branch: branchId, p_date: date, p_difference_reason: differenceReason ?? null }),
  },
  'day.reopen': {
    rpc: 'act_day_reopen',
    args: ({ branchId, date, reason }) => ({ p_branch: branchId, p_date: date, p_reason: reason }),
  },
  'billing.set_mode': {
    rpc: 'act_billing_set_mode',
    args: ({ pan, panBillMode }) => ({ p_pan: pan ?? null, p_mode: panBillMode }),
  },
  undo: {
    rpc: 'act_undo',
    args: ({ actionId, reason }) => ({ p_action_id: actionId, p_reason: reason ?? null }),
  },
};

export const ACTION_NAMES = Object.keys(ACTIONS);

/**
 * @param {string} name - one of ACTION_NAMES
 * @param {object} inputs - the action's inputs (see ACTIONS above)
 * @returns {Promise<{ok: boolean, actionId: string|null, data: any, error: {code: string, message: string}|null}>}
 */
export async function runAction(name, inputs = {}) {
  const def = ACTIONS[name];
  if (!def) throw new Error(`Unknown action: ${name}`); // a programming error, not a runtime refusal

  const { data, error } = await supabase.rpc(def.rpc, def.args(inputs));
  if (error) {
    return { ok: false, actionId: null, data: null, error: { code: error.code || 'ACTION_FAILED', message: error.message || 'The action failed.' } };
  }
  if (!data || typeof data !== 'object') {
    return { ok: false, actionId: null, data: null, error: { code: 'ACTION_FAILED', message: 'The action returned nothing.' } };
  }
  return {
    ok: data.ok === true,
    actionId: data.action_id ?? null,
    data: data.data ?? null,
    error: data.ok === true ? null : { code: data.error?.code || 'ACTION_FAILED', message: data.error?.message || 'The action failed.' },
  };
}
