-- migration-017-rollback (CMD-95): undo migration-017. Drops the job queue, reply rules, the scanners and read functions, the three triggers and
-- the cron jobs, and DELETES the five clinic-wide follow_up playbooks that 017 seeded (booking_confirmation, day_before_reminder, reply_to_confirm,
-- not_confirmed_by_6pm, aftercare_check_in), including any a clinic has since configured; work items that point at them keep their rows with the
-- playbook cleared (016 sets the link to NULL). Restores migration-016's
-- act_work_propose (without p_uses_ai) and act_work_approve (without ORDER_REQUIRED) exactly. Agent jobs are LOST: export first. Run as postgres, local first.

BEGIN;

DO $$
BEGIN
  IF to_regnamespace('cron') IS NOT NULL THEN
    PERFORM cron.unschedule(jobname) FROM cron.job WHERE jobname IN ('agent-scan-day-before', 'agent-scan-no-reply', 'agent-kick');
  END IF;
END $$;

DROP TRIGGER IF EXISTS trg_agent_patient_reply ON public.messages;
DROP TRIGGER IF EXISTS trg_agent_visit_completed ON public.bookings;
DROP TRIGGER IF EXISTS trg_agent_booking_created ON public.bookings;
DROP FUNCTION IF EXISTS public.trg_agent_patient_reply();
DROP FUNCTION IF EXISTS public.trg_agent_visit_completed();
DROP FUNCTION IF EXISTS public.trg_agent_booking_created();
DROP FUNCTION IF EXISTS public.ai_usage_summary(date);
DROP FUNCTION IF EXISTS public.agent_scorecard(text, uuid, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public._agent_metrics(uuid[], text, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public._agent_rates(jsonb);
DROP FUNCTION IF EXISTS public.agent_step_result(uuid, text);
DROP INDEX IF EXISTS public.idx_action_log_step_key;
DROP FUNCTION IF EXISTS public.agent_get_reply_rules(uuid);
DROP FUNCTION IF EXISTS public.agent_finish_job(uuid, text, jsonb, text);
DROP FUNCTION IF EXISTS public.agent_claim_jobs(integer);
DROP FUNCTION IF EXISTS public.agent_kick_runner();
DROP FUNCTION IF EXISTS public.agent_scan_not_confirmed();
DROP FUNCTION IF EXISTS public.agent_scan_day_before();
DROP FUNCTION IF EXISTS public._agent_enqueue(uuid, uuid, text, uuid, uuid, timestamptz, uuid, uuid, text);
DROP TABLE IF EXISTS public.agent_reply_rules;
DROP TABLE IF EXISTS public.agent_jobs;

-- 016's two functions, exactly
DROP FUNCTION IF EXISTS public.act_work_propose(text, text, uuid, text, text, text, jsonb, uuid, jsonb, uuid, uuid, uuid, boolean, timestamptz, jsonb, boolean);
CREATE OR REPLACE FUNCTION public.act_work_propose(p_agent text, p_kind text, p_branch uuid, p_title text, p_summary text, p_action text DEFAULT NULL::text, p_inputs jsonb DEFAULT '{}'::jsonb, p_playbook uuid DEFAULT NULL::uuid, p_sources jsonb DEFAULT '[]'::jsonb, p_customer uuid DEFAULT NULL::uuid, p_booking uuid DEFAULT NULL::uuid, p_conversation uuid DEFAULT NULL::uuid, p_urgent boolean DEFAULT false, p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ctx jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  ctx jsonb; v_inputs jsonb; v_org uuid; v_reason text; v_id uuid; pb public.playbooks; k text; v_in jsonb := COALESCE(p_inputs, '{}'::jsonb);
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('agent', p_agent, 'kind', p_kind, 'branch_id', p_branch, 'title', p_title, 'proposed_action', p_action, 'input_keys',
                                 CASE WHEN jsonb_typeof(v_in) = 'object' THEN (SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM jsonb_object_keys(v_in) x) END,
                                 'playbook_id', p_playbook, 'customer_id', p_customer, 'booking_id', p_booking, 'conversation_id', p_conversation)
              || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT COALESCE((ctx ->> 'service')::boolean, false) OR ctx ->> 'kind' NOT IN ('agent', 'rule') THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'FORBIDDEN', 'Only an agent or a rule can propose work.', NULL, NULL, 'agent_work_items');
  END IF;
  IF ctx ->> 'kind' = 'agent' AND ctx ->> 'agent' IS DISTINCT FROM p_agent THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'FORBIDDEN', 'An agent can propose only as itself.', NULL, NULL, 'agent_work_items');
  END IF;
  IF p_branch IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch AND org_id = v_org) OR NOT public._act_in_scope(ctx, v_org, p_branch) THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, NULL, v_inputs, false, NULL, 'BRANCH_NOT_FOUND', 'Branch not found.', NULL, NULL, 'agent_work_items');
  END IF;
  IF p_agent IS NULL OR p_agent !~ '^[a-z][a-z0-9_]{1,40}$' OR p_kind IS NULL OR p_kind NOT IN ('approval', 'exception')
     OR COALESCE(btrim(p_title), '') = '' OR COALESCE(btrim(p_summary), '') = '' OR jsonb_typeof(v_in) <> 'object'
     OR (p_kind = 'approval' AND p_action IS NULL) THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'INVALID_INPUT', 'Agent, kind, title, summary and (for an approval) an action are required.', NULL, NULL, 'agent_work_items');
  END IF;
  IF p_action IS NOT NULL THEN
    IF p_action NOT IN ('act_message_send', 'act_booking_set_status', 'act_booking_flag_not_confirmed') THEN
      RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'ACTION_NOT_ALLOWED', 'That action cannot be proposed.', NULL, NULL, 'agent_work_items');
    END IF;
    FOR k IN SELECT jsonb_object_keys(v_in) LOOP
      IF NOT k = ANY (public._work_keys(p_action, false)) THEN
        RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'INVALID_INPUT', 'Unknown input key: ' || k, NULL, NULL, 'agent_work_items');
      END IF;
    END LOOP;
    IF (p_action = 'act_message_send' AND p_customer IS NULL AND p_conversation IS NULL AND p_booking IS NULL)
       OR (p_action <> 'act_message_send' AND p_booking IS NULL) THEN
      RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'INVALID_INPUT', 'The action needs its target (patient, conversation or booking).', NULL, NULL, 'agent_work_items');
    END IF;
  END IF;
  IF (p_customer IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer AND org_id = v_org))
     OR (p_booking IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.bookings WHERE id = p_booking AND branch_id = p_branch))
     OR (p_conversation IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.conversations WHERE id = p_conversation AND org_id = v_org AND (branch_id IS NULL OR branch_id = p_branch))) THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'TARGET_NOT_FOUND', 'The patient, booking or conversation is not in this branch.', NULL, NULL, 'agent_work_items');
  END IF;
  IF p_playbook IS NOT NULL THEN
    SELECT * INTO pb FROM public.playbooks WHERE id = p_playbook AND org_id = v_org AND agent = p_agent AND (branch_id IS NULL OR branch_id = p_branch);
    IF pb.id IS NULL THEN
      RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'PLAYBOOK_NOT_FOUND', 'Playbook not found for this agent and branch.', NULL, NULL, 'agent_work_items');
    END IF;
    IF NOT pb.enabled THEN
      RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'PLAYBOOK_OFF', 'This playbook is switched off.', NULL, NULL, 'agent_work_items');
    END IF;
  END IF;
  v_reason := public._ai_block_reason(v_org, p_branch, p_agent);
  IF v_reason IS NOT NULL THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, v_reason,
      CASE v_reason WHEN 'AI_OFF' THEN 'AI is switched off for this clinic.' WHEN 'AGENT_OFF' THEN 'This agent is switched off for this branch.'
                    ELSE 'The AI budget for this month is used up.' END, NULL, NULL, 'agent_work_items');
  END IF;

  INSERT INTO public.agent_work_items (org_id, branch_id, agent, playbook_id, kind, urgent, title, summary, proposed_action, proposed_inputs, sources,
                                       customer_id, booking_id, conversation_id, expires_at)
  VALUES (v_org, p_branch, p_agent, p_playbook, p_kind, COALESCE(p_urgent, false), btrim(p_title), btrim(p_summary), p_action, v_in, COALESCE(p_sources, '[]'::jsonb),
          p_customer, p_booking, p_conversation, COALESCE(p_expires_at, now() + interval '48 hours'))
  RETURNING id INTO v_id;
  RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, true, jsonb_build_object('item_id', v_id), NULL, NULL, v_id, NULL, 'agent_work_items');
END $function$;
REVOKE ALL ON FUNCTION public.act_work_propose(text, text, uuid, text, text, text, jsonb, uuid, jsonb, uuid, uuid, uuid, boolean, timestamptz, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.act_work_propose(text, text, uuid, text, text, text, jsonb, uuid, jsonb, uuid, uuid, uuid, boolean, timestamptz, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.act_work_approve(p_item uuid, p_edited_inputs jsonb DEFAULT NULL::jsonb, p_ctx jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  ctx jsonb; v_inputs jsonb; v_org uuid; v_uid uuid; w public.agent_work_items; v_final jsonb; v_edited boolean := false; k text; v_ictx jsonb; r jsonb;
  v_ok boolean; v_code text; v_msg text; v_status text;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid; v_uid := (ctx ->> 'user_id')::uuid;
  v_inputs := jsonb_build_object('item_id', p_item, 'edited', p_edited_inputs IS NOT NULL,
                                 'edited_keys', CASE WHEN jsonb_typeof(p_edited_inputs) = 'object' THEN (SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM jsonb_object_keys(p_edited_inputs) x) END)
              || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('admin', 'manager', 'staff', 'practitioner') THEN
    RETURN public._act_finish(ctx, 'work.approve', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot approve this.', p_item, NULL, 'agent_work_items');
  END IF;
  SELECT * INTO w FROM public.agent_work_items WHERE id = p_item AND org_id = v_org FOR UPDATE;
  IF w.id IS NULL OR NOT public._work_in_scope(ctx, w) THEN
    RETURN public._act_finish(ctx, 'work.approve', v_org, NULL, v_inputs, false, NULL, 'ITEM_NOT_FOUND', 'Item not found.', NULL, NULL, 'agent_work_items');
  END IF;
  IF w.status <> 'open' THEN
    RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, NULL, 'ITEM_NOT_OPEN', 'This item was already decided.', w.id, NULL, 'agent_work_items');
  END IF;
  IF w.kind <> 'approval' OR w.proposed_action IS NULL THEN
    RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, NULL, 'NOT_APPROVABLE', 'This item has nothing to approve.', w.id, NULL, 'agent_work_items');
  END IF;
  IF w.expires_at IS NOT NULL AND w.expires_at < now() THEN
    UPDATE public.agent_work_items SET status = 'expired', decided_at = now() WHERE id = w.id;
    RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, NULL, 'ITEM_EXPIRED', 'This item expired before it was approved.', w.id, NULL, 'agent_work_items');
  END IF;

  -- edits: content keys only; customer, conversation and booking always come from the stored item
  v_final := w.proposed_inputs;
  IF p_edited_inputs IS NOT NULL THEN
    IF jsonb_typeof(p_edited_inputs) <> 'object' THEN
      RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, NULL, 'INVALID_INPUT', 'Edits must be an object.', w.id, NULL, 'agent_work_items');
    END IF;
    FOR k IN SELECT jsonb_object_keys(p_edited_inputs) LOOP
      IF NOT k = ANY (public._work_keys(w.proposed_action, true)) THEN
        RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, NULL, 'EDIT_NOT_ALLOWED', 'You cannot edit "' || k || '" on this item.', w.id, NULL, 'agent_work_items');
      END IF;
    END LOOP;
    v_final := w.proposed_inputs || p_edited_inputs;
    v_edited := v_final IS DISTINCT FROM w.proposed_inputs;
  END IF;

  -- the grant, then the stored action as the agent, approved by this person. A raised error inside it is caught: the item is marked failed.
  v_ictx := jsonb_build_object('actor_kind', 'agent', 'agent', w.agent, 'org_id', w.org_id, 'branch_id', w.branch_id, 'approved_by', v_uid,
                               'reason_source', 'work_item:' || w.id);
  INSERT INTO private.approval_grants (txid, work_item, agent, org_id, branch_id, approved_by) VALUES (txid_current(), w.id, w.agent, w.org_id, w.branch_id, v_uid);
  BEGIN
    IF w.proposed_action = 'act_message_send' THEN
      r := public.act_message_send(p_conversation => w.conversation_id, p_customer => w.customer_id, p_channel => v_final ->> 'channel',
                                   p_template => (v_final ->> 'template')::uuid, p_text => v_final ->> 'text', p_fields => COALESCE(v_final -> 'fields', '{}'::jsonb),
                                   p_purpose => COALESCE(v_final ->> 'purpose', 'service'), p_booking => w.booking_id, p_language => v_final ->> 'language',
                                   p_on_quiet_hours => COALESCE(v_final ->> 'on_quiet_hours', 'refuse'), p_ctx => v_ictx);
    ELSIF w.proposed_action = 'act_booking_set_status' THEN
      r := public.act_booking_set_status(w.booking_id, (v_final ->> 'status')::public.booking_status, v_final ->> 'reason', v_ictx);
    ELSIF w.proposed_action = 'act_booking_flag_not_confirmed' THEN
      r := public.act_booking_flag_not_confirmed(w.booking_id, v_final ->> 'reason', v_ictx);
    ELSE
      r := jsonb_build_object('ok', false, 'error', jsonb_build_object('code', 'ACTION_NOT_ALLOWED', 'message', 'That action cannot be run from the queue.'));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    r := jsonb_build_object('ok', false, 'error', jsonb_build_object('code', 'ACTION_ERROR', 'message', 'The action could not be run.'));
  END;
  DELETE FROM private.approval_grants WHERE txid = txid_current();   -- never leave a grant behind

  v_ok := COALESCE((r ->> 'ok')::boolean, false);
  IF v_ok THEN
    v_status := CASE WHEN v_edited THEN 'edited' ELSE 'approved' END;
    UPDATE public.agent_work_items SET status = v_status, decided_by = v_uid, decided_at = now(), final_inputs = CASE WHEN v_edited THEN v_final END,
           result_action_id = (r ->> 'action_id')::uuid WHERE id = w.id;
    RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, true,
      jsonb_build_object('item_id', w.id, 'status', v_status, 'result_action_id', r ->> 'action_id', 'result', r -> 'data'), NULL, NULL, w.id, NULL, 'agent_work_items');
  END IF;
  v_code := COALESCE(r #>> '{error,code}', 'ACTION_ERROR'); v_msg := COALESCE(r #>> '{error,message}', 'The action could not be run.');
  UPDATE public.agent_work_items SET status = 'failed', decided_by = v_uid, decided_at = now(), decision_reason = v_code,
         result_action_id = (r ->> 'action_id')::uuid WHERE id = w.id;
  RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, jsonb_build_object('item_id', w.id, 'status', 'failed'), v_code, v_msg, w.id, NULL, 'agent_work_items');
END $function$;

-- the playbooks 017 seeded (agent_jobs, which pointed at them, is already dropped); then the old CHECK can come back
DELETE FROM public.playbooks WHERE agent = 'follow_up' AND branch_id IS NULL
  AND key IN ('booking_confirmation', 'day_before_reminder', 'reply_to_confirm', 'not_confirmed_by_6pm', 'aftercare_check_in');
DELETE FROM public.playbooks WHERE event = 'patient_reply';
ALTER TABLE public.playbooks DROP CONSTRAINT playbooks_event_check;
ALTER TABLE public.playbooks ADD CONSTRAINT playbooks_event_check CHECK (event IN ('booking_created', 'day_before', 'visit_completed', 'no_reply'));

COMMIT;
