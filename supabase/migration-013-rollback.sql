-- migration-013-rollback (CMD-88): undo migration-013. Drops the hub tables, so conversations, messages, consent rows and channel accounts are LOST:
-- export them first. Restores migration-012's _act_resolve and act_undo. Run as postgres. Not for production without the owner.
-- action_log rows written by the hub actions stay (the log is append-only); they just refer to tables that no longer exist.

BEGIN;

-- the two 012 functions, exactly as migration-012 defined them
CREATE OR REPLACE FUNCTION public._act_resolve(p_ctx jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  v_kind text; v_org uuid; v_branch uuid; v_agent text; v_appr uuid; v_u record; v_jwt_role text;
BEGIN
  -- the JWT role claim, read directly (auth.role() differs between Supabase auth versions)
  v_jwt_role := coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role');
  IF current_setting('role', true) = 'service_role' AND v_jwt_role = 'service_role' THEN
    IF p_ctx IS NULL OR jsonb_typeof(p_ctx) <> 'object' THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'A service-role call needs a p_ctx object.');
    END IF;
    BEGIN
      v_org := (p_ctx ->> 'org_id')::uuid;
      v_branch := (p_ctx ->> 'branch_id')::uuid;
      v_appr := (p_ctx ->> 'approved_by')::uuid;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'p_ctx has an invalid id.');
    END;
    v_kind := p_ctx ->> 'actor_kind';
    v_agent := p_ctx ->> 'agent';
    IF v_kind IS NULL OR v_kind NOT IN ('agent', 'rule', 'system') THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'actor_kind must be agent, rule or system.');
    END IF;
    IF v_kind = 'agent' AND (v_agent IS NULL OR v_agent !~ '^[a-z][a-z0-9_]{1,40}$') THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'An agent call needs a valid agent name.');
    END IF;
    IF v_org IS NULL OR NOT EXISTS (SELECT 1 FROM public.organizations WHERE id = v_org) THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'org_id is required and must exist.');
    END IF;
    IF v_branch IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.branches WHERE id = v_branch AND org_id = v_org) THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'branch_id is not in that organization.');
    END IF;
    IF v_appr IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_appr AND org_id = v_org AND is_active IS NOT FALSE) THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'approved_by is not an active user of that organization.');
    END IF;
    RETURN jsonb_build_object('ok', true, 'kind', v_kind, 'user_id', NULL, 'role', NULL, 'org_id', v_org, 'branch_id', v_branch,
                              'branch_ids', NULL, 'agent', CASE WHEN v_kind = 'agent' THEN v_agent END, 'approved_by', v_appr,
                              'reason_source', p_ctx ->> 'reason_source', 'service', true, 'ctx_ignored', false);
  END IF;

  IF auth.uid() IS NOT NULL THEN
    SELECT id, role::text AS role, org_id, is_active INTO v_u FROM public.users WHERE id = auth.uid();
    IF v_u.id IS NOT NULL AND v_u.is_active IS NOT FALSE THEN
      RETURN jsonb_build_object('ok', true, 'kind', 'person', 'user_id', v_u.id, 'role', v_u.role, 'org_id', v_u.org_id, 'branch_id', NULL,
                                'branch_ids', to_jsonb(public.get_user_branch_ids()), 'agent', NULL, 'approved_by', NULL,
                                'reason_source', NULL, 'service', false, 'ctx_ignored', p_ctx IS NOT NULL);
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', false, 'code', 'FORBIDDEN', 'message', 'Your account cannot run this action.');
END $$;

CREATE OR REPLACE FUNCTION public.act_undo(p_action_id uuid, p_reason text DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; a public.action_log; v_inputs jsonb; u jsonb; b public.bookings; v_res jsonb; v_code text; v_msg text; r jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('action_id', p_action_id, 'reason', p_reason) || public._act_ctx_inputs(p_ctx, ctx);

  SELECT * INTO a FROM public.action_log WHERE id = p_action_id FOR UPDATE;
  IF a.id IS NULL OR a.org_id IS DISTINCT FROM (ctx ->> 'org_id')::uuid OR NOT public._act_in_scope(ctx, a.org_id, a.branch_id) THEN
    RETURN public._act_finish(ctx, 'undo', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'ACTION_NOT_FOUND', 'Action not found.', NULL, NULL, NULL);
  END IF;

  -- who may undo: anyone who may run bookings actions in that branch; a practitioner only a status change THEY made on their own booking; an agent only with approval
  IF ctx ->> 'kind' = 'person' THEN
    IF ctx ->> 'role' = 'practitioner' THEN
      IF NOT COALESCE(a.action = 'booking.set_status' AND a.actor_user_id = (ctx ->> 'user_id')::uuid AND a.target_id IS NOT NULL AND public.is_my_booking(a.target_id), false) THEN
        RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'You can only undo your own status changes.', a.target_id, NULL, a.target_table);
      END IF;
    ELSIF ctx ->> 'role' NOT IN ('staff', 'manager', 'admin') THEN
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot undo actions.', a.target_id, NULL, a.target_table);
    END IF;
  ELSIF ctx ->> 'kind' = 'agent' THEN
    IF (ctx ->> 'approved_by') IS NULL THEN
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'APPROVAL_REQUIRED', 'Undoing needs a person''s approval.', a.target_id, NULL, a.target_table);
    END IF;
  ELSE
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'This kind of caller cannot undo actions.', a.target_id, NULL, a.target_table);
  END IF;

  IF a.undone_by_action IS NOT NULL THEN
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_ALREADY', 'This action was already undone.', a.target_id, NULL, a.target_table);
  END IF;
  u := a.undo;
  IF NOT a.ok OR u IS NULL THEN
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_NOT_POSSIBLE', 'This action cannot be undone.', a.target_id, NULL, a.target_table);
  END IF;
  IF (u ->> 'expires_at')::timestamptz < now() THEN
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_EXPIRED', 'The time to undo this action has passed.', a.target_id, NULL, a.target_table);
  END IF;

  IF u ->> 'kind' = 'flag' THEN
    UPDATE public.booking_flags SET cleared_at = now() WHERE id = (u ->> 'flag_id')::uuid AND cleared_at IS NULL;
    IF NOT FOUND THEN
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_STALE', 'The flag was already cleared.', a.target_id, NULL, a.target_table);
    END IF;
    v_res := public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, true,
      jsonb_build_object('undone_action', a.id, 'kind', 'flag'), NULL, NULL, a.target_id, NULL, a.target_table);
    UPDATE public.action_log SET undone_by_action = (v_res ->> 'action_id')::uuid, undone_reason = p_reason WHERE id = a.id;
    RETURN v_res;
  END IF;

  -- booking-level undo (set_status, reschedule): the booking must be exactly as the action left it
  SELECT * INTO b FROM public.bookings WHERE id = a.target_id FOR UPDATE;
  IF b.id IS NULL OR b.updated_at IS DISTINCT FROM (u ->> 'expect_updated_at')::timestamptz THEN
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_STALE', 'This booking changed after the action, so it can''t be undone.', a.target_id, NULL, a.target_table);
  END IF;
  IF b.is_locked THEN
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'DAY_LOCKED', 'This day has been closed. No further modifications allowed.', a.target_id, NULL, a.target_table);
  END IF;

  IF u ->> 'kind' = 'set_status' THEN
    IF u ->> 'to' = 'In-Progress' AND EXISTS (SELECT 1 FROM public.consultations WHERE booking_id = b.id) THEN
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_NOT_POSSIBLE', 'A consultation was already started for this booking.', a.target_id, NULL, a.target_table);
    END IF;
    BEGIN
      UPDATE public.bookings
         SET status = (u ->> 'from')::public.booking_status,
             cancellation_reason = CASE WHEN u ->> 'to' IN ('Cancelled', 'No Show') THEN u ->> 'prior_cancellation_reason' ELSE cancellation_reason END
       WHERE id = b.id;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      IF v_code IN ('P0003', '23P01') THEN v_code := 'UNDO_BLOCKED'; v_msg := 'The slot or chair is no longer free, so this can''t be undone.'; END IF;
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, v_code, v_msg, a.target_id, NULL, a.target_table);
    END;
  ELSIF u ->> 'kind' = 'reschedule' THEN
    r := u -> 'prior';
    BEGIN
      UPDATE public.bookings
         SET date = (r ->> 'date')::date, start_time = (r ->> 'start_time')::time, end_time = (r ->> 'end_time')::time,
             dentist_id = (r ->> 'dentist_id')::uuid, dentist_name_snapshot = r ->> 'dentist_name_snapshot',
             chair_id = (r ->> 'chair_id')::uuid, chair_name_snapshot = r ->> 'chair_name_snapshot'
       WHERE id = b.id;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      IF v_code IN ('P0003', '23P01') THEN v_code := 'UNDO_BLOCKED'; v_msg := 'The old slot is no longer free, so this can''t be undone.'; END IF;
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, v_code, v_msg, a.target_id, NULL, a.target_table);
    END;
    BEGIN
      DELETE FROM public.booking_dentists WHERE booking_id = b.id;
      INSERT INTO public.booking_dentists (booking_id, dentist_id, start_time, end_time)
        SELECT b.id, (x ->> 'dentist_id')::uuid, (x ->> 'start_time')::time, (x ->> 'end_time')::time
          FROM jsonb_array_elements(COALESCE(u -> 'prior_booking_dentists', '[]'::jsonb)) x;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'act_undo booking_dentists restore failed: %', SQLERRM;
    END;
  ELSE
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_NOT_POSSIBLE', 'This action cannot be undone.', a.target_id, NULL, a.target_table);
  END IF;

  v_res := public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, true,
    jsonb_build_object('undone_action', a.id, 'kind', u ->> 'kind'), NULL, NULL, a.target_id, NULL, a.target_table);
  UPDATE public.action_log SET undone_by_action = (v_res ->> 'action_id')::uuid, undone_reason = p_reason WHERE id = a.id;
  RETURN v_res;
END $$;

-- the clock
DO $$
BEGIN
  IF to_regnamespace('cron') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'hub-send-kick') THEN PERFORM cron.unschedule('hub-send-kick'); END IF;
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'hub-status-poll') THEN PERFORM cron.unschedule('hub-status-poll'); END IF;
  END IF;
END $$;

-- actions and functions
DROP FUNCTION IF EXISTS public.act_message_send(uuid, uuid, text, uuid, text, jsonb, text, uuid, text, text, jsonb);
DROP FUNCTION IF EXISTS public.act_message_retry(uuid, text, text, jsonb);
DROP FUNCTION IF EXISTS public.act_message_receive(uuid, text, text, text, timestamptz, jsonb);
DROP FUNCTION IF EXISTS public.act_conversation_take_over(uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_conversation_hand_back(uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_conversation_assign(uuid, uuid, text, jsonb);
DROP FUNCTION IF EXISTS public.act_conversation_handoff(uuid, text, text, boolean, uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_consent_record(uuid, text, text, text, text, text, jsonb);
DROP FUNCTION IF EXISTS public.hub_mark_read(uuid);
DROP FUNCTION IF EXISTS public.hub_kick_sender(text);
DROP FUNCTION IF EXISTS public.hub_backfill_booking_consent(uuid, boolean);
DROP FUNCTION IF EXISTS public.hub_claim_messages(integer);
DROP FUNCTION IF EXISTS public.hub_record_send_result(uuid, boolean, text, numeric, text);
DROP FUNCTION IF EXISTS public.hub_apply_delivery_status(uuid, text, text, timestamptz, text);
DROP FUNCTION IF EXISTS public.hub_poll_accounts();
DROP FUNCTION IF EXISTS public.hub_pending_delivery(uuid, interval);
DROP FUNCTION IF EXISTS public.hub_mark_polled(uuid);
DROP FUNCTION IF EXISTS public.hub_find_account(text, text);
DROP FUNCTION IF EXISTS public.hub_list_accounts(text);
DROP FUNCTION IF EXISTS public.hub_rate_check(uuid, integer);
DROP FUNCTION IF EXISTS public._hub_send_core(jsonb, uuid, uuid, text, uuid, text, jsonb, text, uuid, text, text, uuid, text);
DROP FUNCTION IF EXISTS public._hub_provider_idempotent(text);

DROP FUNCTION IF EXISTS public._hub_quiet_end(public.channel_accounts, timestamptz);   -- takes the channel_accounts row type: must go before the table

-- tables (their policies, indexes, triggers and realtime membership go with them)
DROP TABLE IF EXISTS public.messages;
DROP TABLE IF EXISTS public.conversation_reads;
DROP TABLE IF EXISTS public.conversations;
DROP TABLE IF EXISTS public.message_templates;
DROP TABLE IF EXISTS public.patient_channels;
DROP TABLE IF EXISTS public.hub_inbound_rate;
DROP TABLE IF EXISTS public.hub_test_outbox;
DROP TABLE IF EXISTS public.channel_accounts;

-- helpers (after the policies that used them are gone with their tables)
DROP FUNCTION IF EXISTS public._hub_booking_fields(uuid, uuid);
DROP FUNCTION IF EXISTS public._hub_render(text, jsonb);
DROP FUNCTION IF EXISTS public._hub_consent(uuid, text, text, text);
DROP FUNCTION IF EXISTS public._hub_event(uuid, text, text, jsonb, text, uuid, text);
DROP FUNCTION IF EXISTS public._hub_user_name(uuid);
DROP FUNCTION IF EXISTS public._hub_fail(text, text, uuid, uuid);
DROP FUNCTION IF EXISTS public._hub_scope(jsonb, uuid, uuid, uuid);
DROP FUNCTION IF EXISTS public.hub_can_read_consent(uuid, uuid);
DROP FUNCTION IF EXISTS public.hub_can_read_conversation(uuid, uuid, uuid);
DROP FUNCTION IF EXISTS public.is_my_patient(uuid);

DROP INDEX IF EXISTS public.idx_bookings_customer;

COMMIT;
