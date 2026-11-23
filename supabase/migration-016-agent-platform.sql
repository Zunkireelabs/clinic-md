-- migration-016: agent platform tables, part 1 (CMD-90). Brief: docs/briefs/CMD-90-agent-platform.md. Needs 010, 012, 013 and 014 (can_read_money).
-- Playbooks, per-clinic agent settings with the owner's ceiling, the work queue (drafts waiting for a person), the AI cost ledger and
-- monthly budget. TABLES AND ACTIONS ONLY: no agent runs, no model is called, no screen.
--
-- Design note approved by the lead 2026-11-22 (rulings kept here so they survive the session):
--   * "owner" = the admin role. admin_viewer is read-only everywhere. A manager may change a clinic-wide playbook within the owner's ceiling.
--   * A branch can only NARROW: an agent runs in a branch only if the clinic-wide row AND the branch row (when there is one) are on.
--     A scribe with no clinic-wide row counts as on (it follows the AI switch), so a clinic that has no row yet keeps its Scribe.
--   * act_work_approve runs the stored action as the AGENT with approved_by = the approving person (one-use grant in private.approval_grants,
--     matched on txid_current(); _act_resolve accepts it once and deletes it). Only content keys can be edited; customer / booking /
--     conversation always come from the stored item. The inner action's own checks (consent, STOPPED, quiet hours, scope) run as normal.
--   * 'none' (no budget row at all) blocks every agent except the Scribe and blocks switching AI ON; it never switches an org that is
--     already on to off, and the Scribe keeps running.
--   * Undo for the settings actions is one generic action_log.undo kind, 'restore', handled by act_undo (rows: table, pk, prior, expect).
--   * Replaces _act_resolve and act_undo with the CURRENT (013) bodies plus: (1) _act_resolve: the grant path, and VOLATILE (it deletes the
--     grant); (2) act_undo: a 'restore' branch, and an extra term in the scope test so a manager can undo a clinic-wide (branch NULL) action.
--     migration-016-rollback.sql restores the 013 bodies exactly.
-- Apply by hand with psql (CMD-85). Local only until the owner applies it to prod (needs 011-015 first). Rollback: migration-016-rollback.sql

BEGIN;

-- 1. tables ----------------------------------------------------------------------------------------------------------------
CREATE TABLE public.agent_settings (
  org_id      uuid NOT NULL REFERENCES public.organizations(id),
  branch_id   uuid REFERENCES public.branches(id),               -- NULL = the clinic-wide row
  agent       text NOT NULL CHECK (agent ~ '^[a-z][a-z0-9_]{1,40}$'),
  enabled     boolean NOT NULL DEFAULT false,
  max_level   smallint CHECK (max_level BETWEEN 1 AND 3),         -- the owner's ceiling; only on the clinic-wide row
  updated_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agent_settings_ceiling_org_row CHECK ((branch_id IS NULL) = (max_level IS NOT NULL)),
  CONSTRAINT agent_settings_key UNIQUE NULLS NOT DISTINCT (org_id, branch_id, agent)
);

CREATE TABLE public.playbooks (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.organizations(id),
  branch_id   uuid REFERENCES public.branches(id),               -- NULL = every branch
  agent       text NOT NULL CHECK (agent ~ '^[a-z][a-z0-9_]{1,40}$'),
  key         text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]{1,60}$'),
  name        text NOT NULL CHECK (length(btrim(name)) > 0),
  event       text NOT NULL CHECK (event IN ('booking_created', 'day_before', 'visit_completed', 'no_reply')),
  template_id uuid REFERENCES public.message_templates(id) ON DELETE SET NULL,
  channel     text CHECK (channel IN ('sms', 'whatsapp', 'viber', 'messenger', 'email')),   -- NULL = follow the sending rules
  level       smallint NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 3),
  enabled     boolean NOT NULL DEFAULT false,
  settings    jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(settings) = 'object'),
  created_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  updated_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT playbooks_key UNIQUE NULLS NOT DISTINCT (org_id, branch_id, agent, key)
);
CREATE INDEX idx_playbooks_org_agent ON public.playbooks (org_id, agent);

CREATE TABLE public.agent_work_items (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.organizations(id),
  branch_id        uuid NOT NULL REFERENCES public.branches(id),
  agent            text NOT NULL CHECK (agent ~ '^[a-z][a-z0-9_]{1,40}$'),
  playbook_id      uuid REFERENCES public.playbooks(id) ON DELETE SET NULL,
  kind             text NOT NULL CHECK (kind IN ('approval', 'exception')),
  status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'approved', 'edited', 'rejected', 'failed', 'expired')),
  urgent           boolean NOT NULL DEFAULT false,
  title            text NOT NULL CHECK (length(btrim(title)) > 0),
  summary          text NOT NULL CHECK (length(btrim(summary)) > 0),       -- the agent's first-person line
  proposed_action  text CHECK (proposed_action IN ('act_message_send', 'act_booking_set_status', 'act_booking_flag_not_confirmed')),
  proposed_inputs  jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(proposed_inputs) = 'object'),
  sources          jsonb NOT NULL DEFAULT '[]'::jsonb,                    -- the records the agent used, for "Why"
  customer_id      uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  booking_id       uuid REFERENCES public.bookings(id) ON DELETE SET NULL,
  conversation_id  uuid REFERENCES public.conversations(id) ON DELETE SET NULL,
  expires_at       timestamptz,
  decided_by       uuid REFERENCES public.users(id) ON DELETE SET NULL,
  decided_at       timestamptz,
  decision_reason  text,
  final_inputs     jsonb,                                                  -- what actually ran, when edited
  result_action_id uuid REFERENCES public.action_log(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT work_items_approval_has_action CHECK (kind <> 'approval' OR proposed_action IS NOT NULL),
  CONSTRAINT work_items_decided CHECK ((status = 'open') = (decided_at IS NULL)),
  CONSTRAINT work_items_final_only_edited CHECK (final_inputs IS NULL OR status = 'edited')
);
CREATE INDEX idx_work_items_queue ON public.agent_work_items (org_id, branch_id, status, created_at DESC);
CREATE INDEX idx_work_items_customer ON public.agent_work_items (customer_id);
CREATE INDEX idx_work_items_expiry ON public.agent_work_items (expires_at) WHERE status = 'open';

CREATE TABLE public.ai_spend (          -- the cost ledger (ai_usage from 006 is the per-user rate limit: left alone)
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.organizations(id),
  branch_id       uuid REFERENCES public.branches(id),
  agent           text NOT NULL CHECK (agent ~ '^[a-z][a-z0-9_]{1,40}$'),
  job             text NOT NULL CHECK (job IN ('text', 'transcription', 'vision')),
  provider        text NOT NULL,
  model           text NOT NULL,
  units           jsonb NOT NULL DEFAULT '{}'::jsonb,                     -- tokens in and out, audio seconds
  cost_npr        numeric(12,4) NOT NULL CHECK (cost_npr >= 0),
  work_item_id    uuid REFERENCES public.agent_work_items(id) ON DELETE SET NULL,
  consultation_id uuid REFERENCES public.consultations(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_ai_spend_org_created ON public.ai_spend (org_id, created_at DESC);

CREATE TABLE public.ai_budgets (
  org_id      uuid NOT NULL REFERENCES public.organizations(id),
  month       date NOT NULL CHECK (extract(day FROM month) = 1),          -- first of the month, Asia/Kathmandu
  amount_npr  numeric(12,2) NOT NULL CHECK (amount_npr >= 0),
  warn_pct    smallint NOT NULL DEFAULT 80 CHECK (warn_pct BETWEEN 1 AND 100),
  set_by      uuid REFERENCES public.users(id) ON DELETE SET NULL,
  set_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, month)
);

-- 2. no direct writes for any API role; reads by policy ----------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['agent_settings', 'playbooks', 'agent_work_items', 'ai_spend', 'ai_budgets'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated, service_role', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;

-- settings and playbooks are not money: every staff role reads them (a practitioner too); a branch row only inside that branch
CREATE POLICY agent_settings_read ON public.agent_settings FOR SELECT TO authenticated
  USING (
    org_id = public.get_user_org_id()
    AND public.get_user_role()::text IN ('staff', 'manager', 'admin', 'admin_viewer', 'practitioner')
    AND (branch_id IS NULL OR public.get_user_role()::text IN ('admin', 'admin_viewer') OR branch_id = ANY (public.get_user_branch_ids()))
  );
CREATE POLICY playbooks_read ON public.playbooks FOR SELECT TO authenticated
  USING (
    org_id = public.get_user_org_id()
    AND public.get_user_role()::text IN ('staff', 'manager', 'admin', 'admin_viewer', 'practitioner')
    AND (branch_id IS NULL OR public.get_user_role()::text IN ('admin', 'admin_viewer') OR branch_id = ANY (public.get_user_branch_ids()))
  );
-- the queue: admin / admin_viewer org-wide; staff and manager their branches; a practitioner only their own patients' items
CREATE POLICY agent_work_items_read ON public.agent_work_items FOR SELECT TO authenticated
  USING (
    org_id = public.get_user_org_id()
    AND (
      public.get_user_role()::text IN ('admin', 'admin_viewer')
      OR (public.get_user_role()::text IN ('staff', 'manager') AND branch_id = ANY (public.get_user_branch_ids()))
      OR (public.get_user_role()::text = 'practitioner' AND customer_id IS NOT NULL AND public.is_my_patient(customer_id))
    )
  );
-- money: practitioners never see it (CMD-83)
CREATE POLICY ai_spend_read ON public.ai_spend FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id() AND public.can_read_money());
CREATE POLICY ai_budgets_read ON public.ai_budgets FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id() AND public.can_read_money());

-- Home reads one list: open work items plus the hub's needs_person conversations. security_invoker: the tables' own RLS decides what a caller sees.
CREATE VIEW public.work_queue WITH (security_invoker = true) AS
  SELECT 'work_item'::text AS source, w.id, w.org_id, w.branch_id, w.kind, w.agent, w.urgent, w.title, w.summary,
         w.customer_id, w.booking_id, w.conversation_id, w.created_at
    FROM public.agent_work_items w WHERE w.status = 'open'
  UNION ALL
  SELECT 'conversation'::text, c.id, c.org_id, c.branch_id, 'handoff'::text, NULL::text, c.urgent,
         'Needs a person: ' || COALESCE(c.handoff_reason, 'other'), c.handoff_summary,
         c.customer_id, NULL::uuid, c.id, COALESCE(c.needs_person_since, c.updated_at)
    FROM public.conversations c WHERE c.state = 'needs_person';
REVOKE ALL ON public.work_queue FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.work_queue TO authenticated, service_role;

-- 3. the one-use approval grant ---------------------------------------------------------------------------------------------
-- private schema, no grant to any API role. act_work_approve writes a row for its own transaction; _act_resolve consumes it.
CREATE SCHEMA IF NOT EXISTS private;
CREATE TABLE private.approval_grants (
  txid        bigint NOT NULL,
  work_item   uuid NOT NULL,
  agent       text NOT NULL,
  org_id      uuid NOT NULL,
  branch_id   uuid NOT NULL,
  approved_by uuid NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE private.approval_grants ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.approval_grants FROM PUBLIC, anon, authenticated, service_role;

-- 4. _act_resolve and act_undo: the current (013) bodies plus the 016 changes ----------------------------------------------------
CREATE OR REPLACE FUNCTION public._act_resolve(p_ctx jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_kind text; v_org uuid; v_branch uuid; v_agent text; v_appr uuid; v_u record; v_jwt_role text; v_grant record;
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

  -- 016: a one-use approval grant (private.approval_grants), written by act_work_approve in THIS transaction. When a signed-in person's p_ctx asks
  -- for actor_kind 'agent' and a grant matches txid, agent, org and approved_by (= the signed-in person), the call runs as that agent, approved
  -- by that person, and the grant is deleted. Without a matching grant nothing changes: a person's p_ctx is ignored.
  IF p_ctx IS NOT NULL AND jsonb_typeof(p_ctx) = 'object' AND p_ctx ->> 'actor_kind' = 'agent' AND auth.uid() IS NOT NULL THEN
    BEGIN
      v_org := (p_ctx ->> 'org_id')::uuid;
      v_appr := (p_ctx ->> 'approved_by')::uuid;
    EXCEPTION WHEN others THEN
      v_org := NULL; v_appr := NULL;
    END;
    v_agent := p_ctx ->> 'agent';
    IF v_org IS NOT NULL AND v_appr IS NOT NULL AND v_appr = auth.uid() AND v_agent IS NOT NULL THEN
      DELETE FROM private.approval_grants g
       WHERE g.txid = txid_current() AND g.agent = v_agent AND g.org_id = v_org AND g.approved_by = v_appr
      RETURNING g.branch_id, g.work_item INTO v_grant;
      IF FOUND THEN
        RETURN jsonb_build_object('ok', true, 'kind', 'agent', 'user_id', NULL, 'role', NULL, 'org_id', v_org, 'branch_id', v_grant.branch_id,
                                  'branch_ids', NULL, 'agent', v_agent, 'approved_by', v_appr,
                                  'reason_source', 'work_item:' || v_grant.work_item, 'service', true, 'ctx_ignored', false);
      END IF;
    END IF;
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

CREATE OR REPLACE FUNCTION public.act_undo(p_action_id uuid, p_reason text DEFAULT NULL::text, p_ctx jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  ctx jsonb; a public.action_log; v_inputs jsonb; u jsonb; b public.bookings; v_res jsonb; v_code text; v_msg text; r jsonb; cv public.conversations; v_ev uuid; v_row jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('action_id', p_action_id, 'reason', p_reason) || public._act_ctx_inputs(p_ctx, ctx);

  SELECT * INTO a FROM public.action_log WHERE id = p_action_id FOR UPDATE;
  IF a.id IS NULL OR a.org_id IS DISTINCT FROM (ctx ->> 'org_id')::uuid OR NOT (public._act_in_scope(ctx, a.org_id, a.branch_id)
                                                 OR (a.branch_id IS NULL AND a.target_table = 'conversations' AND public._hub_scope(ctx, a.org_id, NULL, NULL))
                                                 OR (a.branch_id IS NULL AND a.target_table IN ('agent_settings', 'playbooks', 'ai_budgets', 'organizations')
                                                     AND ctx ->> 'kind' = 'person' AND ctx ->> 'role' IN ('admin', 'manager'))) THEN
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

  -- 016: generic restore of settings rows (agent / playbook / AI switch / budget). Who may undo is the action's own rule (u.min_role).
  IF u ->> 'kind' = 'restore' THEN
    IF ctx ->> 'kind' <> 'person' OR NOT (ctx ->> 'role' = 'admin' OR (u ->> 'min_role' = 'manager' AND ctx ->> 'role' = 'manager')) THEN
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot undo this change.', a.target_id, NULL, a.target_table);
    END IF;
    FOR v_row IN SELECT x FROM jsonb_array_elements(u -> 'rows') x LOOP
      IF COALESCE(public._agent_snap(v_row ->> 'table', v_row -> 'pk'), 'null'::jsonb) IS DISTINCT FROM (v_row -> 'expect') THEN
        RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_STALE', 'This was changed again after the action, so it can''t be undone.', a.target_id, NULL, a.target_table);
      END IF;
    END LOOP;
    FOR v_row IN SELECT x FROM jsonb_array_elements(u -> 'rows') x LOOP
      PERFORM public._agent_apply(v_row ->> 'table', v_row -> 'pk', NULLIF(v_row -> 'prior', 'null'::jsonb));
    END LOOP;
    v_res := public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, true,
      jsonb_build_object('undone_action', a.id, 'kind', 'restore'), NULL, NULL, a.target_id, NULL, a.target_table);
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

-- 5. internal helpers (not callable by API roles) -----------------------------------------------------------------------------
-- month start (first day, Asia/Kathmandu)
CREATE FUNCTION public._ai_month_start() RETURNS date
    LANGUAGE sql STABLE SET search_path = public
    AS $$ SELECT date_trunc('month', now() AT TIME ZONE 'Asia/Kathmandu')::date $$;

-- the owner's ceiling for an agent (no clinic-wide row = level 1)
CREATE FUNCTION public._agent_ceiling(p_org uuid, p_agent text) RETURNS integer
    LANGUAGE sql STABLE SET search_path = public
    AS $$ SELECT COALESCE((SELECT s.max_level FROM public.agent_settings s WHERE s.org_id = p_org AND s.branch_id IS NULL AND s.agent = p_agent), 1)::integer $$;

-- clinic-wide switch: the row, or (Scribe only, no row) on
CREATE FUNCTION public._agent_org_enabled(p_org uuid, p_agent text) RETURNS boolean
    LANGUAGE sql STABLE SET search_path = public
    AS $$ SELECT COALESCE((SELECT s.enabled FROM public.agent_settings s WHERE s.org_id = p_org AND s.branch_id IS NULL AND s.agent = p_agent), p_agent = 'scribe') $$;

-- the branch can only narrow
CREATE FUNCTION public._agent_enabled(p_org uuid, p_branch uuid, p_agent text) RETURNS boolean
    LANGUAGE sql STABLE SET search_path = public
    AS $$
  SELECT public._agent_org_enabled(p_org, p_agent)
     AND COALESCE((SELECT s.enabled FROM public.agent_settings s WHERE s.org_id = p_org AND s.branch_id = p_branch AND s.agent = p_agent), true) $$;

-- why an agent may not run now: NULL = it may
CREATE FUNCTION public._ai_block_reason(p_org uuid, p_branch uuid, p_agent text) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_state text;
BEGIN
  IF NOT COALESCE((SELECT o.ai_consultation_enabled FROM public.organizations o WHERE o.id = p_org), false) THEN RETURN 'AI_OFF'; END IF;
  IF NOT public._agent_enabled(p_org, p_branch, p_agent) THEN RETURN 'AGENT_OFF'; END IF;
  IF p_agent <> 'scribe' THEN
    v_state := public.ai_budget_status(p_org) ->> 'state';
    IF v_state IN ('none', 'used_up') THEN RETURN 'BUDGET_USED_UP'; END IF;
  END IF;
  RETURN NULL;
END $$;

-- tracked columns of a settings row, for undo ('restore'): the row now, or NULL when there is none
CREATE FUNCTION public._agent_snap(p_table text, p_pk jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v jsonb;
BEGIN
  IF p_table = 'agent_settings' THEN
    SELECT to_jsonb(s) INTO v FROM (SELECT enabled, max_level, updated_by, updated_at FROM public.agent_settings
      WHERE org_id = (p_pk ->> 'org_id')::uuid AND branch_id IS NOT DISTINCT FROM (p_pk ->> 'branch_id')::uuid AND agent = p_pk ->> 'agent') s;
  ELSIF p_table = 'playbooks' THEN
    SELECT to_jsonb(s) INTO v FROM (SELECT level, enabled, updated_by, updated_at FROM public.playbooks
      WHERE id = (p_pk ->> 'id')::uuid AND org_id = (p_pk ->> 'org_id')::uuid) s;
  ELSIF p_table = 'ai_budgets' THEN
    SELECT to_jsonb(s) INTO v FROM (SELECT amount_npr, warn_pct, set_by, set_at FROM public.ai_budgets
      WHERE org_id = (p_pk ->> 'org_id')::uuid AND month = (p_pk ->> 'month')::date) s;
  ELSIF p_table = 'organizations' THEN
    SELECT to_jsonb(s) INTO v FROM (SELECT ai_consultation_enabled FROM public.organizations WHERE id = (p_pk ->> 'org_id')::uuid) s;
  ELSE
    RAISE EXCEPTION 'unknown restore table %', p_table;
  END IF;
  RETURN v;
END $$;

-- put a snapshot back (NULL prior = the row did not exist, so delete it)
CREATE FUNCTION public._agent_apply(p_table text, p_pk jsonb, p_prior jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
BEGIN
  IF p_table = 'agent_settings' THEN
    IF p_prior IS NULL THEN
      DELETE FROM public.agent_settings WHERE org_id = (p_pk ->> 'org_id')::uuid AND branch_id IS NOT DISTINCT FROM (p_pk ->> 'branch_id')::uuid AND agent = p_pk ->> 'agent';
    ELSE
      UPDATE public.agent_settings SET enabled = (p_prior ->> 'enabled')::boolean, max_level = (p_prior ->> 'max_level')::smallint,
             updated_by = (p_prior ->> 'updated_by')::uuid, updated_at = (p_prior ->> 'updated_at')::timestamptz
       WHERE org_id = (p_pk ->> 'org_id')::uuid AND branch_id IS NOT DISTINCT FROM (p_pk ->> 'branch_id')::uuid AND agent = p_pk ->> 'agent';
    END IF;
  ELSIF p_table = 'playbooks' THEN
    UPDATE public.playbooks SET level = (p_prior ->> 'level')::smallint, enabled = (p_prior ->> 'enabled')::boolean,
           updated_by = (p_prior ->> 'updated_by')::uuid, updated_at = (p_prior ->> 'updated_at')::timestamptz
     WHERE id = (p_pk ->> 'id')::uuid AND org_id = (p_pk ->> 'org_id')::uuid;
  ELSIF p_table = 'ai_budgets' THEN
    IF p_prior IS NULL THEN
      DELETE FROM public.ai_budgets WHERE org_id = (p_pk ->> 'org_id')::uuid AND month = (p_pk ->> 'month')::date;
    ELSE
      UPDATE public.ai_budgets SET amount_npr = (p_prior ->> 'amount_npr')::numeric, warn_pct = (p_prior ->> 'warn_pct')::smallint,
             set_by = (p_prior ->> 'set_by')::uuid, set_at = (p_prior ->> 'set_at')::timestamptz
       WHERE org_id = (p_pk ->> 'org_id')::uuid AND month = (p_pk ->> 'month')::date;
    END IF;
  ELSIF p_table = 'organizations' THEN
    UPDATE public.organizations SET ai_consultation_enabled = (p_prior ->> 'ai_consultation_enabled')::boolean WHERE id = (p_pk ->> 'org_id')::uuid;
  ELSE
    RAISE EXCEPTION 'unknown restore table %', p_table;
  END IF;
END $$;

-- one { table, pk, prior, expect } entry of an undo
CREATE FUNCTION public._agent_undo_row(p_table text, p_pk jsonb, p_prior jsonb) RETURNS jsonb
    LANGUAGE sql STABLE SET search_path = public
    AS $$ SELECT jsonb_build_object('table', p_table, 'pk', p_pk, 'prior', p_prior, 'expect', public._agent_snap(p_table, p_pk)) $$;

-- editable and storable keys per allow-listed action (target ids are NEVER keys: they come from the stored item)
CREATE FUNCTION public._work_keys(p_action text, p_edit_only boolean) RETURNS text[]
    LANGUAGE sql IMMUTABLE SET search_path = public
    AS $$
  SELECT CASE
    WHEN p_action = 'act_message_send' THEN CASE WHEN p_edit_only THEN ARRAY['text', 'fields', 'template']
                                                 ELSE ARRAY['text', 'fields', 'template', 'channel', 'purpose', 'language', 'on_quiet_hours'] END
    WHEN p_action = 'act_booking_set_status' THEN CASE WHEN p_edit_only THEN ARRAY['reason'] ELSE ARRAY['status', 'reason'] END
    WHEN p_action = 'act_booking_flag_not_confirmed' THEN ARRAY['reason']
    ELSE ARRAY[]::text[] END $$;

-- is the work item inside the signed-in person's reach? admin: org; admin_viewer: no actions; staff / manager: their branches; practitioner: own patients
CREATE FUNCTION public._work_in_scope(p_ctx jsonb, w public.agent_work_items) RETURNS boolean
    LANGUAGE sql STABLE SET search_path = public
    AS $$
  SELECT COALESCE(
    w.org_id = (p_ctx ->> 'org_id')::uuid
    AND CASE p_ctx ->> 'role'
      WHEN 'admin' THEN true
      WHEN 'practitioner' THEN public.is_my_patient(w.customer_id)
      WHEN 'staff' THEN COALESCE(p_ctx -> 'branch_ids', '[]'::jsonb) ? w.branch_id::text
      WHEN 'manager' THEN COALESCE(p_ctx -> 'branch_ids', '[]'::jsonb) ? w.branch_id::text
      ELSE false END, false) $$;

-- 6. service functions (service role only) -----------------------------------------------------------------------------------
CREATE FUNCTION public.ai_budget_status(p_org uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_month date := public._ai_month_start(); v_amount numeric; v_warn smallint; v_spent numeric; v_pct numeric; v_state text; v_ratio numeric;
BEGIN
  SELECT b.amount_npr, b.warn_pct INTO v_amount, v_warn FROM public.ai_budgets b WHERE b.org_id = p_org AND b.month <= v_month ORDER BY b.month DESC LIMIT 1;   -- last month's amount carries over
  SELECT COALESCE(sum(s.cost_npr), 0) INTO v_spent FROM public.ai_spend s
   WHERE s.org_id = p_org AND s.created_at >= (v_month::timestamp AT TIME ZONE 'Asia/Kathmandu') AND s.created_at < ((v_month + interval '1 month')::timestamp AT TIME ZONE 'Asia/Kathmandu');
  IF v_amount IS NULL THEN
    v_state := 'none'; v_pct := NULL;
  ELSIF v_amount = 0 THEN
    v_state := 'used_up'; v_pct := 100;
  ELSE
    v_ratio := v_spent / v_amount * 100;   -- the state uses the exact ratio: 99.999% is not 100%
    v_pct := round(v_ratio, 2);
    v_state := CASE WHEN v_ratio >= 100 THEN 'used_up' WHEN v_ratio >= v_warn THEN 'warn' ELSE 'ok' END;
  END IF;
  RETURN jsonb_build_object('spent', v_spent, 'amount', v_amount, 'pct', v_pct, 'state', v_state, 'month', v_month);
END $$;

CREATE FUNCTION public.ai_may_run(p_org uuid, p_branch uuid, p_agent text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$ SELECT public._ai_block_reason(p_org, p_branch, p_agent) IS NULL $$;

CREATE FUNCTION public.ai_record_spend(p_org uuid, p_branch uuid, p_agent text, p_job text, p_provider text, p_model text, p_units jsonb, p_cost_npr numeric,
                                       p_work_item uuid DEFAULT NULL, p_consultation uuid DEFAULT NULL) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.organizations WHERE id = p_org) THEN RAISE EXCEPTION 'ai_record_spend: unknown organization' USING ERRCODE = '22023'; END IF;
  IF p_branch IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch AND org_id = p_org) THEN
    RAISE EXCEPTION 'ai_record_spend: the branch is not in that organization' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.ai_spend (org_id, branch_id, agent, job, provider, model, units, cost_npr, work_item_id, consultation_id)
  VALUES (p_org, p_branch, p_agent, p_job, p_provider, p_model, COALESCE(p_units, '{}'::jsonb), p_cost_npr, p_work_item, p_consultation)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION public.agent_expire_work_items() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE n integer;
BEGIN
  UPDATE public.agent_work_items SET status = 'expired', decided_at = now() WHERE status = 'open' AND expires_at IS NOT NULL AND expires_at < now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

DO $$
BEGIN
  IF to_regnamespace('cron') IS NULL THEN
    RAISE NOTICE 'pg_cron is not installed here: agent-expire-work-items was NOT scheduled (enable pg_cron, then run migration-016 section 6 again).';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'agent-expire-work-items') THEN PERFORM cron.unschedule('agent-expire-work-items'); END IF;
  PERFORM cron.schedule('agent-expire-work-items', '*/5 * * * *', 'SELECT public.agent_expire_work_items()');
END $$;

-- 7. actions (the 012 pattern: _act_resolve, scope, ONE action_log row, undo where possible) --------------------------------------
-- 7.1 act_agent_set_enabled: admin anywhere; manager only in their own branches
CREATE FUNCTION public.act_agent_set_enabled(p_agent text, p_branch uuid, p_enabled boolean, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; v_inputs jsonb; v_org uuid; v_role text; v_uid uuid; v_pk jsonb; v_prior jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid; v_role := ctx ->> 'role'; v_uid := (ctx ->> 'user_id')::uuid;
  v_inputs := jsonb_build_object('agent', p_agent, 'branch_id', p_branch, 'enabled', p_enabled) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR v_role NOT IN ('admin', 'manager') THEN
    RETURN public._act_finish(ctx, 'agent.set_enabled', v_org, p_branch, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot switch an agent on or off.', NULL, NULL, 'agent_settings');
  END IF;
  IF p_agent IS NULL OR p_agent !~ '^[a-z][a-z0-9_]{1,40}$' OR p_enabled IS NULL THEN
    RETURN public._act_finish(ctx, 'agent.set_enabled', v_org, p_branch, v_inputs, false, NULL, 'INVALID_INPUT', 'An agent name and on / off are required.', NULL, NULL, 'agent_settings');
  END IF;
  IF p_branch IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch AND org_id = v_org) THEN
    RETURN public._act_finish(ctx, 'agent.set_enabled', v_org, NULL, v_inputs, false, NULL, 'BRANCH_NOT_FOUND', 'Branch not found.', NULL, NULL, 'agent_settings');
  END IF;
  IF v_role = 'manager' AND (p_branch IS NULL OR NOT COALESCE(ctx -> 'branch_ids', '[]'::jsonb) ? p_branch::text) THEN
    RETURN public._act_finish(ctx, 'agent.set_enabled', v_org, p_branch, v_inputs, false, NULL, 'FORBIDDEN', 'A manager can switch an agent only in their own branches.', NULL, NULL, 'agent_settings');
  END IF;
  IF p_branch IS NOT NULL AND p_enabled AND NOT public._agent_org_enabled(v_org, p_agent) THEN
    RETURN public._act_finish(ctx, 'agent.set_enabled', v_org, p_branch, v_inputs, false, NULL, 'CLINIC_AGENT_OFF', 'The owner has not switched this agent on for the clinic.', NULL, NULL, 'agent_settings');
  END IF;

  v_pk := jsonb_build_object('org_id', v_org, 'branch_id', p_branch, 'agent', p_agent);
  v_prior := public._agent_snap('agent_settings', v_pk);
  INSERT INTO public.agent_settings (org_id, branch_id, agent, enabled, max_level, updated_by)
  VALUES (v_org, p_branch, p_agent, p_enabled, CASE WHEN p_branch IS NULL THEN 1 END, v_uid)
  ON CONFLICT ON CONSTRAINT agent_settings_key DO UPDATE SET enabled = EXCLUDED.enabled, updated_by = EXCLUDED.updated_by, updated_at = now();
  RETURN public._act_finish(ctx, 'agent.set_enabled', v_org, p_branch, v_inputs, true,
    jsonb_build_object('agent', p_agent, 'branch_id', p_branch, 'enabled', p_enabled), NULL, NULL, NULL,
    jsonb_build_object('kind', 'restore', 'expires_at', now() + interval '24 hours', 'min_role', CASE WHEN p_branch IS NULL THEN 'admin' ELSE 'manager' END,
                       'rows', jsonb_build_array(public._agent_undo_row('agent_settings', v_pk, v_prior))),
    'agent_settings');
END $$;

-- 7.2 act_agent_set_ceiling: the owner's highest allowed level; lowering it lowers every playbook above it, in the same action
CREATE FUNCTION public.act_agent_set_ceiling(p_agent text, p_max_level integer, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; v_inputs jsonb; v_org uuid; v_uid uuid; v_pk jsonb; v_prior jsonb; v_rows jsonb := '[]'::jsonb; v_n integer := 0; pb record; v_ppk jsonb; v_pprior jsonb; v_srow jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid; v_uid := (ctx ->> 'user_id')::uuid;
  v_inputs := jsonb_build_object('agent', p_agent, 'max_level', p_max_level) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' <> 'admin' THEN
    RETURN public._act_finish(ctx, 'agent.set_ceiling', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Only the owner can change the ceiling.', NULL, NULL, 'agent_settings');
  END IF;
  IF p_agent IS NULL OR p_agent !~ '^[a-z][a-z0-9_]{1,40}$' OR p_max_level IS NULL OR p_max_level NOT BETWEEN 1 AND 3 THEN
    RETURN public._act_finish(ctx, 'agent.set_ceiling', v_org, NULL, v_inputs, false, NULL, 'INVALID_INPUT', 'An agent name and a level from 1 to 3 are required.', NULL, NULL, 'agent_settings');
  END IF;

  v_pk := jsonb_build_object('org_id', v_org, 'branch_id', NULL, 'agent', p_agent);
  v_prior := public._agent_snap('agent_settings', v_pk);
  INSERT INTO public.agent_settings (org_id, branch_id, agent, enabled, max_level, updated_by)
  VALUES (v_org, NULL, p_agent, public._agent_org_enabled(v_org, p_agent), p_max_level, v_uid)   -- a new row keeps the agent's effective on / off
  ON CONFLICT ON CONSTRAINT agent_settings_key DO UPDATE SET max_level = EXCLUDED.max_level, updated_by = EXCLUDED.updated_by, updated_at = now();
  v_srow := public._agent_undo_row('agent_settings', v_pk, v_prior);

  FOR pb IN SELECT id FROM public.playbooks WHERE org_id = v_org AND agent = p_agent AND level > p_max_level ORDER BY id FOR UPDATE LOOP
    v_ppk := jsonb_build_object('id', pb.id, 'org_id', v_org);
    v_pprior := public._agent_snap('playbooks', v_ppk);
    UPDATE public.playbooks SET level = p_max_level, updated_by = v_uid, updated_at = now() WHERE id = pb.id;
    v_rows := v_rows || jsonb_build_array(public._agent_undo_row('playbooks', v_ppk, v_pprior));
    v_n := v_n + 1;
  END LOOP;
  v_rows := jsonb_build_array(v_srow) || v_rows;
  RETURN public._act_finish(ctx, 'agent.set_ceiling', v_org, NULL, v_inputs, true,
    jsonb_build_object('agent', p_agent, 'max_level', p_max_level, 'playbooks_lowered', v_n), NULL, NULL, NULL,
    jsonb_build_object('kind', 'restore', 'expires_at', now() + interval '24 hours', 'min_role', 'admin', 'rows', v_rows), 'agent_settings');
END $$;

-- 7.3 / 7.4 playbooks: level (within the ceiling) and on / off. admin and manager (a manager only in their own branches; a clinic-wide playbook is allowed)
CREATE FUNCTION public.act_playbook_set_level(p_playbook uuid, p_level integer, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; v_inputs jsonb; v_org uuid; v_uid uuid; pb public.playbooks; v_pk jsonb; v_prior jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid; v_uid := (ctx ->> 'user_id')::uuid;
  v_inputs := jsonb_build_object('playbook_id', p_playbook, 'level', p_level) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('admin', 'manager') THEN
    RETURN public._act_finish(ctx, 'playbook.set_level', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot change a playbook.', p_playbook, NULL, 'playbooks');
  END IF;
  SELECT * INTO pb FROM public.playbooks WHERE id = p_playbook AND org_id = v_org FOR UPDATE;
  IF pb.id IS NULL OR (ctx ->> 'role' = 'manager' AND pb.branch_id IS NOT NULL AND NOT COALESCE(ctx -> 'branch_ids', '[]'::jsonb) ? pb.branch_id::text) THEN
    RETURN public._act_finish(ctx, 'playbook.set_level', v_org, NULL, v_inputs, false, NULL, 'PLAYBOOK_NOT_FOUND', 'Playbook not found.', NULL, NULL, 'playbooks');
  END IF;
  IF p_level IS NULL OR p_level NOT BETWEEN 1 AND 3 THEN
    RETURN public._act_finish(ctx, 'playbook.set_level', v_org, pb.branch_id, v_inputs, false, NULL, 'INVALID_INPUT', 'A level from 1 to 3 is required.', pb.id, NULL, 'playbooks');
  END IF;
  IF p_level > public._agent_ceiling(v_org, pb.agent) THEN
    RETURN public._act_finish(ctx, 'playbook.set_level', v_org, pb.branch_id, v_inputs, false, NULL, 'LEVEL_ABOVE_CEILING',
      'The owner allows level ' || public._agent_ceiling(v_org, pb.agent) || ' at most for this agent.', pb.id, NULL, 'playbooks');
  END IF;
  v_pk := jsonb_build_object('id', pb.id, 'org_id', v_org);
  v_prior := public._agent_snap('playbooks', v_pk);
  UPDATE public.playbooks SET level = p_level, updated_by = v_uid, updated_at = now() WHERE id = pb.id;
  RETURN public._act_finish(ctx, 'playbook.set_level', v_org, pb.branch_id, v_inputs, true,
    jsonb_build_object('playbook_id', pb.id, 'level', p_level, 'from', pb.level), NULL, NULL, pb.id,
    jsonb_build_object('kind', 'restore', 'expires_at', now() + interval '24 hours', 'min_role', 'manager',
                       'rows', jsonb_build_array(public._agent_undo_row('playbooks', v_pk, v_prior))), 'playbooks');
END $$;

CREATE FUNCTION public.act_playbook_set_enabled(p_playbook uuid, p_enabled boolean, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; v_inputs jsonb; v_org uuid; v_uid uuid; pb public.playbooks; v_pk jsonb; v_prior jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid; v_uid := (ctx ->> 'user_id')::uuid;
  v_inputs := jsonb_build_object('playbook_id', p_playbook, 'enabled', p_enabled) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('admin', 'manager') THEN
    RETURN public._act_finish(ctx, 'playbook.set_enabled', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot change a playbook.', p_playbook, NULL, 'playbooks');
  END IF;
  SELECT * INTO pb FROM public.playbooks WHERE id = p_playbook AND org_id = v_org FOR UPDATE;
  IF pb.id IS NULL OR (ctx ->> 'role' = 'manager' AND pb.branch_id IS NOT NULL AND NOT COALESCE(ctx -> 'branch_ids', '[]'::jsonb) ? pb.branch_id::text) THEN
    RETURN public._act_finish(ctx, 'playbook.set_enabled', v_org, NULL, v_inputs, false, NULL, 'PLAYBOOK_NOT_FOUND', 'Playbook not found.', NULL, NULL, 'playbooks');
  END IF;
  IF p_enabled IS NULL THEN
    RETURN public._act_finish(ctx, 'playbook.set_enabled', v_org, pb.branch_id, v_inputs, false, NULL, 'INVALID_INPUT', 'On or off is required.', pb.id, NULL, 'playbooks');
  END IF;
  v_pk := jsonb_build_object('id', pb.id, 'org_id', v_org);
  v_prior := public._agent_snap('playbooks', v_pk);
  UPDATE public.playbooks SET enabled = p_enabled, updated_by = v_uid, updated_at = now() WHERE id = pb.id;
  RETURN public._act_finish(ctx, 'playbook.set_enabled', v_org, pb.branch_id, v_inputs, true,
    jsonb_build_object('playbook_id', pb.id, 'enabled', p_enabled), NULL, NULL, pb.id,
    jsonb_build_object('kind', 'restore', 'expires_at', now() + interval '24 hours', 'min_role', 'manager',
                       'rows', jsonb_build_array(public._agent_undo_row('playbooks', v_pk, v_prior))), 'playbooks');
END $$;

-- 7.5 act_work_propose: an agent or a rule (service role) puts a draft or an exception in the queue
CREATE FUNCTION public.act_work_propose(p_agent text, p_kind text, p_branch uuid, p_title text, p_summary text, p_action text DEFAULT NULL,
                                        p_inputs jsonb DEFAULT '{}'::jsonb, p_playbook uuid DEFAULT NULL, p_sources jsonb DEFAULT '[]'::jsonb,
                                        p_customer uuid DEFAULT NULL, p_booking uuid DEFAULT NULL, p_conversation uuid DEFAULT NULL,
                                        p_urgent boolean DEFAULT false, p_expires_at timestamptz DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
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
END $$;

-- 7.6 act_work_approve: a PERSON approves (optionally editing the content); the stored action runs as the agent with approved_by = that person
CREATE FUNCTION public.act_work_approve(p_item uuid, p_edited_inputs jsonb DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
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
END $$;

-- 7.7 act_work_reject: a reason is required; no undo
CREATE FUNCTION public.act_work_reject(p_item uuid, p_reason text, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; v_inputs jsonb; v_org uuid; v_uid uuid; w public.agent_work_items;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid; v_uid := (ctx ->> 'user_id')::uuid;
  v_inputs := jsonb_build_object('item_id', p_item, 'reason', p_reason) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('admin', 'manager', 'staff', 'practitioner') THEN
    RETURN public._act_finish(ctx, 'work.reject', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot reject this.', p_item, NULL, 'agent_work_items');
  END IF;
  SELECT * INTO w FROM public.agent_work_items WHERE id = p_item AND org_id = v_org FOR UPDATE;
  IF w.id IS NULL OR NOT public._work_in_scope(ctx, w) THEN
    RETURN public._act_finish(ctx, 'work.reject', v_org, NULL, v_inputs, false, NULL, 'ITEM_NOT_FOUND', 'Item not found.', NULL, NULL, 'agent_work_items');
  END IF;
  IF w.status <> 'open' THEN
    RETURN public._act_finish(ctx, 'work.reject', v_org, w.branch_id, v_inputs, false, NULL, 'ITEM_NOT_OPEN', 'This item was already decided.', w.id, NULL, 'agent_work_items');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN public._act_finish(ctx, 'work.reject', v_org, w.branch_id, v_inputs, false, NULL, 'REASON_REQUIRED', 'Say why you are rejecting this.', w.id, NULL, 'agent_work_items');
  END IF;
  UPDATE public.agent_work_items SET status = 'rejected', decided_by = v_uid, decided_at = now(), decision_reason = btrim(p_reason) WHERE id = w.id;
  RETURN public._act_finish(ctx, 'work.reject', v_org, w.branch_id, v_inputs, true, jsonb_build_object('item_id', w.id, 'status', 'rejected'), NULL, NULL, w.id, NULL, 'agent_work_items');
END $$;

-- 7.8 act_ai_budget_set: the owner sets this month's budget
CREATE FUNCTION public.act_ai_budget_set(p_amount_npr numeric, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; v_inputs jsonb; v_org uuid; v_uid uuid; v_month date := public._ai_month_start(); v_pk jsonb; v_prior jsonb; v_warn smallint;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid; v_uid := (ctx ->> 'user_id')::uuid;
  v_inputs := jsonb_build_object('amount_npr', p_amount_npr) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' <> 'admin' THEN
    RETURN public._act_finish(ctx, 'ai.budget_set', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Only the owner can set the AI budget.', NULL, NULL, 'ai_budgets');
  END IF;
  IF p_amount_npr IS NULL OR p_amount_npr < 0 OR p_amount_npr > 1000000000 THEN
    RETURN public._act_finish(ctx, 'ai.budget_set', v_org, NULL, v_inputs, false, NULL, 'INVALID_INPUT', 'The budget must be an amount of zero or more.', NULL, NULL, 'ai_budgets');
  END IF;
  v_pk := jsonb_build_object('org_id', v_org, 'month', v_month);
  v_prior := public._agent_snap('ai_budgets', v_pk);
  SELECT b.warn_pct INTO v_warn FROM public.ai_budgets b WHERE b.org_id = v_org AND b.month <= v_month ORDER BY b.month DESC LIMIT 1;
  INSERT INTO public.ai_budgets (org_id, month, amount_npr, warn_pct, set_by) VALUES (v_org, v_month, p_amount_npr, COALESCE(v_warn, 80), v_uid)
  ON CONFLICT (org_id, month) DO UPDATE SET amount_npr = EXCLUDED.amount_npr, set_by = EXCLUDED.set_by, set_at = now();
  RETURN public._act_finish(ctx, 'ai.budget_set', v_org, NULL, v_inputs, true, jsonb_build_object('month', v_month, 'amount_npr', p_amount_npr), NULL, NULL, NULL,
    jsonb_build_object('kind', 'restore', 'expires_at', now() + interval '24 hours', 'min_role', 'admin',
                       'rows', jsonb_build_array(public._agent_undo_row('ai_budgets', v_pk, v_prior))), 'ai_budgets');
END $$;

-- 7.9 act_ai_set_enabled: the clinic's AI switch, the owner only (organizations has no UPDATE policy, and still has none).
-- Turning on needs a budget (this month's, or last month's carried over, above zero). 'none' never switches an org that is on to off.
CREATE FUNCTION public.act_ai_set_enabled(p_enabled boolean, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; v_inputs jsonb; v_org uuid; v_pk jsonb; v_prior jsonb; v_status jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('enabled', p_enabled) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' <> 'admin' THEN
    RETURN public._act_finish(ctx, 'ai.set_enabled', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Only the owner can switch AI on or off.', NULL, NULL, 'organizations');
  END IF;
  IF p_enabled IS NULL THEN
    RETURN public._act_finish(ctx, 'ai.set_enabled', v_org, NULL, v_inputs, false, NULL, 'INVALID_INPUT', 'On or off is required.', NULL, NULL, 'organizations');
  END IF;
  IF p_enabled THEN
    v_status := public.ai_budget_status(v_org);
    IF v_status ->> 'state' = 'none' OR COALESCE((v_status ->> 'amount')::numeric, 0) <= 0 THEN
      RETURN public._act_finish(ctx, 'ai.set_enabled', v_org, NULL, v_inputs, false, NULL, 'NO_BUDGET', 'Set an AI budget for this month before switching AI on.', NULL, NULL, 'organizations');
    END IF;
  END IF;
  v_pk := jsonb_build_object('org_id', v_org);
  v_prior := public._agent_snap('organizations', v_pk);
  UPDATE public.organizations SET ai_consultation_enabled = p_enabled WHERE id = v_org;
  RETURN public._act_finish(ctx, 'ai.set_enabled', v_org, NULL, v_inputs, true, jsonb_build_object('enabled', p_enabled), NULL, NULL, NULL,
    jsonb_build_object('kind', 'restore', 'expires_at', now() + interval '24 hours', 'min_role', 'admin',
                       'rows', jsonb_build_array(public._agent_undo_row('organizations', v_pk, v_prior))), 'organizations');
END $$;

-- 8. grants: the actions for signed-in users and the service role; propose and the service functions for the service role only; helpers for nobody
REVOKE ALL ON FUNCTION public._ai_month_start(), public._agent_ceiling(uuid, text), public._agent_org_enabled(uuid, text), public._agent_enabled(uuid, uuid, text),
  public._ai_block_reason(uuid, uuid, text), public._agent_snap(text, jsonb), public._agent_apply(text, jsonb, jsonb), public._agent_undo_row(text, jsonb, jsonb),
  public._work_keys(text, boolean), public._work_in_scope(jsonb, public.agent_work_items) FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.act_agent_set_enabled(text, uuid, boolean, jsonb), public.act_agent_set_ceiling(text, integer, jsonb),
  public.act_playbook_set_level(uuid, integer, jsonb), public.act_playbook_set_enabled(uuid, boolean, jsonb),
  public.act_work_approve(uuid, jsonb, jsonb), public.act_work_reject(uuid, text, jsonb),
  public.act_ai_budget_set(numeric, jsonb), public.act_ai_set_enabled(boolean, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_agent_set_enabled(text, uuid, boolean, jsonb), public.act_agent_set_ceiling(text, integer, jsonb),
  public.act_playbook_set_level(uuid, integer, jsonb), public.act_playbook_set_enabled(uuid, boolean, jsonb),
  public.act_work_approve(uuid, jsonb, jsonb), public.act_work_reject(uuid, text, jsonb),
  public.act_ai_budget_set(numeric, jsonb), public.act_ai_set_enabled(boolean, jsonb) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.act_work_propose(text, text, uuid, text, text, text, jsonb, uuid, jsonb, uuid, uuid, uuid, boolean, timestamptz, jsonb),
  public.ai_record_spend(uuid, uuid, text, text, text, text, jsonb, numeric, uuid, uuid), public.ai_budget_status(uuid), public.ai_may_run(uuid, uuid, text),
  public.agent_expire_work_items() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.act_work_propose(text, text, uuid, text, text, text, jsonb, uuid, jsonb, uuid, uuid, uuid, boolean, timestamptz, jsonb),
  public.ai_record_spend(uuid, uuid, text, text, text, text, jsonb, numeric, uuid, uuid), public.ai_budget_status(uuid), public.ai_may_run(uuid, uuid, text),
  public.agent_expire_work_items() TO service_role;
-- _act_resolve and act_undo keep the grants 012 gave them (CREATE OR REPLACE does not change them)

-- 9. seed (decision f): an explicit clinic-wide row per organization for each agent.
--    The scribe row is ENABLED (CMD-109, lead QC 2026-11-23): the AI switch alone keeps the Scribe off (_ai_block_reason returns AI_OFF while
--    organizations.ai_consultation_enabled is false), exactly as with no row (_agent_org_enabled defaults the Scribe to on). Seeding it = the
--    AI switch left a clinic with AI off a scribe row that is OFF, and act_ai_set_enabled(true) only updates organizations, so its Scribe stayed
--    blocked with AGENT_OFF after the owner switched AI on. follow_up starts DISABLED. Migration 018 seeds new organizations the same way.
INSERT INTO public.agent_settings (org_id, branch_id, agent, enabled, max_level)
SELECT o.id, NULL, 'scribe', true, 1 FROM public.organizations o
ON CONFLICT ON CONSTRAINT agent_settings_key DO NOTHING;
INSERT INTO public.agent_settings (org_id, branch_id, agent, enabled, max_level)
SELECT o.id, NULL, 'follow_up', false, 1 FROM public.organizations o
ON CONFLICT ON CONSTRAINT agent_settings_key DO NOTHING;

COMMIT;
