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
  undo: {
    rpc: 'act_undo',
    args: ({ actionId, reason }) => ({ p_action_id: actionId, p_reason: reason ?? null }),
  },

  // ── Patients (migration-019, CMD-100). Every write is an action with an audit row; nothing here writes the tables directly. ──
  // `data` is the patient's fields (full_name, phone, ...). An existing phone comes back as ok:false, error.code PHONE_EXISTS and
  // data.matches (the screen asks "same family?"); call again with joinCustomerId to add the new patient to that family.
  'patient.create': {
    rpc: 'act_patient_create',
    args: ({ data, branchId, joinCustomerId }) => ({ p_data: data ?? {}, p_branch: branchId ?? null, p_join_customer: joinCustomerId ?? null }),
  },
  'patient.update': {
    rpc: 'act_patient_update',
    args: ({ customerId, changes }) => ({ p_customer: customerId, p_changes: changes ?? {} }),
  },
  'alert.add': {
    rpc: 'act_alert_add',
    args: ({ customerId, type, text, details, severity }) => ({ p_customer: customerId, p_type: type, p_text: text, p_details: details ?? null, p_severity: severity ?? 'note' }),
  },
  'alert.confirm': { rpc: 'act_alert_confirm', args: ({ alertId }) => ({ p_alert: alertId }) },
  'alert.update': { rpc: 'act_alert_update', args: ({ alertId, changes }) => ({ p_alert: alertId, p_changes: changes ?? {} }) },
  'alert.remove': { rpc: 'act_alert_remove', args: ({ alertId }) => ({ p_alert: alertId }) },
  // give familyId (an existing family) or withCustomerId (a patient to start or join a family with)
  'family.link': {
    rpc: 'act_family_link',
    args: ({ customerId, familyId, withCustomerId }) => ({ p_customer: customerId, p_family: familyId ?? null, p_with_customer: withCustomerId ?? null }),
  },
  'family.unlink': { rpc: 'act_family_unlink', args: ({ customerId }) => ({ p_customer: customerId }) },
  'family.set_contact': { rpc: 'act_family_set_contact', args: ({ familyId, customerId }) => ({ p_family: familyId, p_customer: customerId }) },
  // send_link / start_on_device return data.token ONCE (the server keeps only its hash); build the URL from it and show it, never store it
  'form.send_link': { rpc: 'act_form_send_link', args: ({ customerId, templateId }) => ({ p_customer: customerId, p_template: templateId }) },
  'form.start_on_device': { rpc: 'act_form_start_on_device', args: ({ customerId, templateId }) => ({ p_customer: customerId, p_template: templateId }) },
  'form.record_typed': {
    rpc: 'act_form_record_typed',
    args: ({ customerId, templateId, answers }) => ({ p_customer: customerId, p_template: templateId, p_answers: answers ?? {} }),
  },
  // `evidence` is what the patient said, in their words (required)
  'consent.record_marketing_yes': {
    rpc: 'act_consent_marketing_yes',
    args: ({ customerId, channel, address, evidence }) => ({ p_customer: customerId, p_channel: channel ?? 'sms', p_address: address ?? null, p_evidence: evidence ?? '' }),
  },
  'patient.archive': { rpc: 'act_patient_archive', args: ({ customerId, reason }) => ({ p_customer: customerId, p_reason: reason ?? null }) },
  'patient.restore': { rpc: 'act_patient_restore', args: ({ customerId }) => ({ p_customer: customerId }) },
  // Erase goes through the `patient-erase` edge function: it deletes the recordings through the Storage API, then runs act_patient_erase.
  // The owner uploads the written request to the erase-requests bucket first (path "<org>/<customer>/<file>"), then passes that path.
  'patient.erase': {
    fn: 'patient-erase',
    args: ({ customerId, requestPath, typedName }) => ({ customerId, requestPath, typedName }),
  },
  'duplicates.merge': { rpc: 'act_duplicates_merge', args: ({ keepId, dropId }) => ({ p_keep: keepId, p_drop: dropId }) },
  'duplicates.dismiss': { rpc: 'act_duplicates_dismiss', args: ({ aId, bId }) => ({ p_a: aId, p_b: bId }) },
  'duplicates.link_family': { rpc: 'act_duplicates_link_family', args: ({ aId, bId }) => ({ p_a: aId, p_b: bId }) },
  // Undo for the patient actions above (alert add / confirm / remove, family link / unlink), within 24 hours. Booking actions use `undo`.
  'patient.undo': { rpc: 'act_patient_undo', args: ({ actionId }) => ({ p_action_id: actionId }) },
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

  let data; let error;
  if (def.fn) {
    ({ data, error } = await supabase.functions.invoke(def.fn, { body: def.args(inputs) }));
    if (error) {   // a non-2xx reply still carries the action's JSON body
      let body = null;
      try { body = await error.context?.json?.(); } catch { /* not JSON */ }
      if (body && typeof body === 'object' && 'ok' in body) { data = body; error = null; }
    }
  } else {
    ({ data, error } = await supabase.rpc(def.rpc, def.args(inputs)));
  }
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
