-- migration-016-rollback (CMD-90): undo migration-016. Drops the agent platform tables (settings, playbooks, work items, AI spend and budgets are LOST:
-- export first), the 016 functions and the cron job, and restores migration-013's _act_resolve and act_undo exactly. Leaves
-- organizations.ai_consultation_enabled as it is. action_log rows written by the 016 actions stay (append-only). Run as postgres, local first.

BEGIN;

DO $$
BEGIN
  IF to_regnamespace('cron') IS NOT NULL THEN PERFORM cron.unschedule(jobname) FROM cron.job WHERE jobname = 'agent-expire-work-items'; END IF;
END $$;

DROP FUNCTION IF EXISTS public.act_ai_set_enabled(boolean, jsonb);
DROP FUNCTION IF EXISTS public.act_ai_budget_set(numeric, jsonb);
DROP FUNCTION IF EXISTS public.act_work_reject(uuid, text, jsonb);
DROP FUNCTION IF EXISTS public.act_work_approve(uuid, jsonb, jsonb);
DROP FUNCTION IF EXISTS public.act_work_propose(text, text, uuid, text, text, text, jsonb, uuid, jsonb, uuid, uuid, uuid, boolean, timestamptz, jsonb);
DROP FUNCTION IF EXISTS public.act_playbook_set_enabled(uuid, boolean, jsonb);
DROP FUNCTION IF EXISTS public.act_playbook_set_level(uuid, integer, jsonb);
DROP FUNCTION IF EXISTS public.act_agent_set_ceiling(text, integer, jsonb);
DROP FUNCTION IF EXISTS public.act_agent_set_enabled(text, uuid, boolean, jsonb);
DROP FUNCTION IF EXISTS public.agent_expire_work_items();
DROP FUNCTION IF EXISTS public.ai_record_spend(uuid, uuid, text, text, text, text, jsonb, numeric, uuid, uuid);
DROP FUNCTION IF EXISTS public.ai_may_run(uuid, uuid, text);
DROP FUNCTION IF EXISTS public._ai_block_reason(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.ai_budget_status(uuid);
DROP VIEW IF EXISTS public.work_queue;
DROP FUNCTION IF EXISTS public._work_in_scope(jsonb, public.agent_work_items);

-- the two functions as migration-013 left them (act_undo first: it has no 016 dependency left once the restore branch is gone)
CREATE OR REPLACE FUNCTION public.act_undo(p_action_id uuid, p_reason text DEFAULT NULL::text, p_ctx jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  ctx jsonb; a public.action_log; v_inputs jsonb; u jsonb; b public.bookings; v_res jsonb; v_code text; v_msg text; r jsonb; cv public.conversations; v_ev uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('action_id', p_action_id, 'reason', p_reason) || public._act_ctx_inputs(p_ctx, ctx);

  SELECT * INTO a FROM public.action_log WHERE id = p_action_id FOR UPDATE;
  IF a.id IS NULL OR a.org_id IS DISTINCT FROM (ctx ->> 'org_id')::uuid OR NOT (public._act_in_scope(ctx, a.org_id, a.branch_id)
                                                 OR (a.branch_id IS NULL AND a.target_table = 'conversations' AND public._hub_scope(ctx, a.org_id, NULL, NULL))) THEN
    RETURN public._act_finish(ctx, 'undo', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'ACTION_NOT_FOUND', 'Action not found.', NULL, NULL, NULL);
  END IF;

  -- who may undo: anyone who may run bookings actions in that branch; a practitioner only a status change THEY made on their own booking; an agent only with approval
  IF ctx ->> 'kind' = 'person' THEN
    IF ctx ->> 'role' = 'practitioner' THEN
      IF NOT COALESCE((a.action = 'booking.set_status' AND a.actor_user_id = (ctx ->> 'user_id')::uuid AND a.target_id IS NOT NULL AND public.is_my_booking(a.target_id))
                       OR (a.action = 'conversation.hand_back' AND a.actor_user_id = (ctx ->> 'user_id')::uuid AND a.target_id IS NOT NULL
                           AND public.is_my_patient((SELECT c.customer_id FROM public.conversations c WHERE c.id = a.target_id))), false) THEN
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

  IF u ->> 'kind' = 'hand_back' THEN
    SELECT * INTO cv FROM public.conversations WHERE id = a.target_id FOR UPDATE;
    IF cv.id IS NULL OR cv.updated_at IS DISTINCT FROM (u ->> 'expect_updated_at')::timestamptz THEN
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_STALE', 'This conversation changed after the hand-back, so it can''t be undone.', a.target_id, NULL, a.target_table);
    END IF;
    UPDATE public.conversations
       SET state = u #>> '{prior,state}', handled_by = (u #>> '{prior,handled_by}')::uuid,
           needs_person_since = (u #>> '{prior,needs_person_since}')::timestamptz, urgent = COALESCE((u #>> '{prior,urgent}')::boolean, false)
     WHERE id = cv.id;
    v_ev := public._hub_event(cv.id, 'handed_back_undone', public._hub_user_name((ctx ->> 'user_id')::uuid) || ' undid the hand-back',
                              jsonb_build_object('undone_action', a.id), 'person', (ctx ->> 'user_id')::uuid, NULL);
    v_res := public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, true,
      jsonb_build_object('undone_action', a.id, 'kind', 'hand_back'), NULL, NULL, a.target_id, NULL, a.target_table);
    UPDATE public.messages SET action_id = (v_res ->> 'action_id')::uuid WHERE id = v_ev;
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
END $function$;

CREATE OR REPLACE FUNCTION public._act_resolve(p_ctx jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    IF v_kind IS NULL OR v_kind NOT IN ('agent', 'rule', 'system', 'patient') THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'actor_kind must be agent, rule, system or patient.');
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
END $function$;

DROP FUNCTION IF EXISTS public._work_keys(text, boolean);
DROP FUNCTION IF EXISTS public._agent_undo_row(text, jsonb, jsonb);
DROP FUNCTION IF EXISTS public._agent_apply(text, jsonb, jsonb);
DROP FUNCTION IF EXISTS public._agent_snap(text, jsonb);
DROP FUNCTION IF EXISTS public._agent_enabled(uuid, uuid, text);
DROP FUNCTION IF EXISTS public._agent_org_enabled(uuid, text);
DROP FUNCTION IF EXISTS public._agent_ceiling(uuid, text);
DROP FUNCTION IF EXISTS public._ai_month_start();

DROP TABLE IF EXISTS private.approval_grants;
DROP TABLE IF EXISTS public.ai_spend;
DROP TABLE IF EXISTS public.ai_budgets;
DROP TABLE IF EXISTS public.agent_work_items;
DROP TABLE IF EXISTS public.playbooks;
DROP TABLE IF EXISTS public.agent_settings;

COMMIT;
