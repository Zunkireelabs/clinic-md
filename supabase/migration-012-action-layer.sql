-- migration-012 (CMD-78): the action layer, first slice (bookings).
--
-- Requires 011 (CMD-79): uses get_user_dentist_id() / is_my_booking_row() and the 'practitioner' role. The two must reach
-- prod in order. NOT applied to production. Prod: rehearse on a prod-schema copy first (CMD-11).
-- Rollback: migration-012-rollback.sql (drops action_log and booking_flags, so the audit rows are lost: export them first).
--
-- WHAT: an action is one thing the clinic can do, run on the server as a Postgres function: permission check, validation
-- against live data, the change, ONE audit row (action_log) and, where possible, an undo. Staff call them with their JWT, agents
-- through an edge function with the service role. Slice 1: booking.set_status, booking.reschedule, booking.flag_not_confirmed
-- and the generic act_undo. See docs/briefs/CMD-78-action-layer.md and docs/PRODUCT-BRIEF.md sections 7.1, 7.5, 7.7.
--
-- WHY SECURITY DEFINER: one transaction for check + change + audit, the same rules for every caller. It also means these
-- functions BYPASS RLS (including 011's restrictive practitioner policies), so every permission check is inside them.
--
-- When the agent platform lands, approved_by can also be satisfied by the playbook's autonomy level; see PRODUCT-BRIEF §7.5.
--
-- Actor resolution (_act_resolve):
--   * service role: current_setting('role') = 'service_role' AND the JWT role claim = 'service_role'. Inside a SECURITY DEFINER
--     function current_user is the function owner, so it can't be used; the `role` setting is the real database role that
--     PostgREST switched to, and a forged JWT claim can't change it. Only then is p_ctx honoured.
--   * signed-in staff: actor = auth.uid() with an active users row. Every actor field in p_ctx is ignored.
--   * anyone else (patients, anon): refused. EXECUTE is revoked from PUBLIC and anon as well.

BEGIN;

-- 1. action_log -------------------------------------------------------------------------------------------------------
CREATE TABLE public.action_log (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL REFERENCES public.organizations(id),
  branch_id         uuid REFERENCES public.branches(id),
  action            text NOT NULL,
  actor_kind        text NOT NULL CHECK (actor_kind IN ('person', 'agent', 'rule', 'system', 'patient')),
  actor_user_id     uuid,
  actor_agent       text,
  approved_by       uuid,
  inputs            jsonb NOT NULL DEFAULT '{}'::jsonb,
  result            jsonb,
  ok                boolean NOT NULL,
  error_code        text,
  target_table      text,
  target_id         uuid,
  undo              jsonb,
  undone_by_action  uuid REFERENCES public.action_log(id),
  undone_reason     text,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_action_log_branch_created ON public.action_log (branch_id, created_at DESC);
CREATE INDEX idx_action_log_org_created    ON public.action_log (org_id, created_at DESC);
CREATE INDEX idx_action_log_target         ON public.action_log (target_table, target_id, created_at DESC);

ALTER TABLE public.action_log ENABLE ROW LEVEL SECURITY;
-- Nobody writes directly: no write policies, and no write privileges for any API role.
REVOKE ALL ON public.action_log FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.action_log TO authenticated, service_role;

-- Read: admin / admin_viewer org-wide; staff and manager in their branches; a practitioner ONLY rows whose target is one of their
-- own bookings (money actions will land in this table later and must never leak to them).
CREATE POLICY action_log_read ON public.action_log FOR SELECT TO authenticated
  USING (
    org_id = public.get_user_org_id()
    AND (
      public.get_user_role()::text IN ('admin', 'admin_viewer')
      OR (public.get_user_role()::text IN ('staff', 'manager') AND branch_id = ANY (public.get_user_branch_ids()))
      OR (public.get_user_role()::text = 'practitioner' AND target_table = 'bookings' AND target_id IS NOT NULL
          AND public.is_my_booking(target_id))
    )
  );

-- Append-only, even for the owner role: no DELETE / TRUNCATE; an UPDATE may only stamp undone_by_action / undone_reason once.
CREATE FUNCTION public._action_log_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' OR TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'action_log is append-only' USING ERRCODE = '42501';
  END IF;
  IF OLD.undone_by_action IS NOT NULL
     OR (to_jsonb(NEW) - 'undone_by_action' - 'undone_reason') IS DISTINCT FROM (to_jsonb(OLD) - 'undone_by_action' - 'undone_reason') THEN
    RAISE EXCEPTION 'action_log is append-only (only the undo stamp can be set, once)' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_action_log_guard_row BEFORE UPDATE OR DELETE ON public.action_log FOR EACH ROW EXECUTE FUNCTION public._action_log_guard();
CREATE TRIGGER trg_action_log_guard_truncate BEFORE TRUNCATE ON public.action_log FOR EACH STATEMENT EXECUTE FUNCTION public._action_log_guard();

-- 2. booking_flags: "front desk, look at this" (the 6 pm not-confirmed rule). Its own table so flagging never touches
-- bookings.updated_at (undo uses it to detect later changes) or the lock / immutability triggers. ----------------------------
CREATE TABLE public.booking_flags (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.organizations(id),
  branch_id        uuid NOT NULL REFERENCES public.branches(id),
  booking_id       uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  kind             text NOT NULL CHECK (kind IN ('not_confirmed')),
  reason           text,
  raised_by_action uuid REFERENCES public.action_log(id),
  raised_at        timestamptz NOT NULL DEFAULT now(),
  cleared_at       timestamptz
);
CREATE UNIQUE INDEX booking_flags_one_open ON public.booking_flags (booking_id, kind) WHERE cleared_at IS NULL;
CREATE INDEX idx_booking_flags_branch ON public.booking_flags (branch_id, raised_at DESC);

ALTER TABLE public.booking_flags ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.booking_flags FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.booking_flags TO authenticated, service_role;
CREATE POLICY booking_flags_read ON public.booking_flags FOR SELECT TO authenticated
  USING (
    org_id = public.get_user_org_id()
    AND (
      public.get_user_role()::text IN ('admin', 'admin_viewer')
      OR (public.get_user_role()::text IN ('staff', 'manager') AND branch_id = ANY (public.get_user_branch_ids()))
      OR (public.get_user_role()::text = 'practitioner' AND public.is_my_booking(booking_id))
    )
  );

-- 3. internal helpers (not callable by API roles) ------------------------------------------------------------------------
CREATE FUNCTION public._act_resolve(p_ctx jsonb) RETURNS jsonb
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

-- Is a row of this org / branch inside the actor's reach?
CREATE FUNCTION public._act_in_scope(p_ctx jsonb, p_org uuid, p_branch uuid) RETURNS boolean
    LANGUAGE sql IMMUTABLE SET search_path = public
    AS $$
  SELECT COALESCE(p_org = (p_ctx ->> 'org_id')::uuid
     AND CASE WHEN (p_ctx ->> 'service')::boolean
              THEN (p_ctx ->> 'branch_id') IS NULL OR (p_ctx ->> 'branch_id')::uuid = p_branch
              ELSE (p_ctx ->> 'role') IN ('admin', 'admin_viewer') OR COALESCE(p_ctx -> 'branch_ids', '[]'::jsonb) ? p_branch::text
         END, false);   -- strictly true / false: a NULL here would let a row with no branch slip past `NOT in_scope`
$$;

CREATE FUNCTION public._act_ctx_inputs(p_raw jsonb, p_ctx jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE SET search_path = public
    AS $$
  SELECT CASE WHEN (p_ctx ->> 'service')::boolean THEN jsonb_build_object('ctx', p_raw)
              WHEN p_raw IS NOT NULL THEN jsonb_build_object('ctx_ignored', true)   -- a signed-in user's p_ctx actor fields are ignored
              ELSE '{}'::jsonb END;
$$;

-- Writes the ONE action_log row and builds the standard result { ok, action_id, data, error }. Called after any exception block,
-- so the row survives the rollback of failed work.
CREATE FUNCTION public._act_finish(p_ctx jsonb, p_action text, p_org uuid, p_branch uuid, p_inputs jsonb, p_ok boolean, p_data jsonb,
                                   p_code text, p_message text, p_target uuid, p_undo jsonb, p_table text DEFAULT 'bookings') RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  v_id uuid;
  v_result jsonb;
BEGIN
  v_result := jsonb_build_object('ok', p_ok, 'action_id', NULL, 'data', p_data,
                                 'error', CASE WHEN p_ok THEN NULL ELSE jsonb_build_object('code', p_code, 'message', p_message) END);
  INSERT INTO public.action_log (org_id, branch_id, action, actor_kind, actor_user_id, actor_agent, approved_by, inputs, result, ok,
                                 error_code, target_table, target_id, undo)
  VALUES (p_org, p_branch, p_action, p_ctx ->> 'kind', (p_ctx ->> 'user_id')::uuid, p_ctx ->> 'agent', (p_ctx ->> 'approved_by')::uuid,
          p_inputs, v_result, p_ok, CASE WHEN p_ok THEN NULL ELSE p_code END, p_table, p_target, CASE WHEN p_ok THEN p_undo END)
  RETURNING id INTO v_id;
  RETURN jsonb_set(v_result, '{action_id}', to_jsonb(v_id));
END $$;

-- 4. booking.set_status -----------------------------------------------------------------------------------------------------
-- Lifecycle rules moved from api.js (VALID_TRANSITIONS, TERMINAL_STATUSES, validateBookingMutation, REASON_REQUIRED).
-- Error codes and messages match what updateBookingStatus returned; an unmapped database error keeps its own code and message.
CREATE FUNCTION public.act_booking_set_status(p_booking uuid, p_status public.booking_status, p_reason text DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; b public.bookings; v_org uuid; v_inputs jsonb; v_upd timestamptz; v_pay text; v_code text; v_msg text;
  v_allowed public.booking_status[]; v_undoable boolean;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('booking_id', p_booking, 'status', p_status, 'reason', p_reason) || public._act_ctx_inputs(p_ctx, ctx);
  IF p_status IS NULL THEN
    RETURN public._act_finish(ctx, 'booking.set_status', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'INVALID_INPUT', 'A status is required.', p_booking, NULL);
  END IF;

  SELECT * INTO b FROM public.bookings WHERE id = p_booking FOR UPDATE;
  IF b.id IS NOT NULL THEN SELECT org_id INTO v_org FROM public.branches WHERE id = b.branch_id; END IF;
  IF b.id IS NULL OR NOT public._act_in_scope(ctx, v_org, b.branch_id) THEN
    RETURN public._act_finish(ctx, 'booking.set_status', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'BOOKING_NOT_FOUND', 'Booking not found.', p_booking, NULL);
  END IF;

  -- who may do what
  IF ctx ->> 'kind' = 'person' THEN
    IF ctx ->> 'role' NOT IN ('staff', 'manager', 'admin', 'practitioner') THEN
      RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot change bookings.', p_booking, NULL);
    END IF;
    IF ctx ->> 'role' = 'practitioner' THEN
      IF NOT COALESCE(public.is_my_booking_row(b.id, b.dentist_id), false) THEN   -- is_my_booking_row can return NULL (no dentist on the booking): treat as not mine
        RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'You can only change your own bookings.', p_booking, NULL);
      END IF;
      IF NOT ((b.status = 'Confirmed' AND p_status = 'In-Progress') OR (b.status = 'In-Progress' AND p_status = 'Completed')) THEN
        RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'A practitioner can start and complete their own visits; confirming and cancelling are done by the front desk.', p_booking, NULL);
      END IF;
    END IF;
  ELSIF ctx ->> 'kind' = 'agent' THEN
    IF p_status IN ('No Show', 'In-Progress', 'Completed') THEN
      RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Agents cannot set this status: it is recorded by people in the clinic.', p_booking, NULL);
    END IF;
    IF p_status = 'Cancelled'
       AND NOT (b.payment_status = 'unpaid' AND COALESCE(ctx ->> 'reason_source', '') = 'patient_reply')   -- never NULL: no reason_source must mean "needs approval"
       AND (ctx ->> 'approved_by') IS NULL THEN
      RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, false, NULL, 'APPROVAL_REQUIRED', 'Cancelling needs a person''s approval unless the booking is unpaid and the patient said no.', p_booking, NULL);
    END IF;
  ELSE
    RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'This kind of caller cannot change booking status.', p_booking, NULL);
  END IF;

  -- lifecycle (from validateBookingMutation / validateStatusTransition)
  IF b.is_locked THEN
    RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, false, NULL, 'DAY_LOCKED', 'This day has been closed. No further modifications allowed.', p_booking, NULL);
  END IF;
  IF b.status IN ('Completed', 'Cancelled', 'No Show') THEN
    RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, false, NULL, 'BOOKING_IMMUTABLE', b.status || ' bookings cannot be modified.', p_booking, NULL);
  END IF;
  v_allowed := CASE b.status
    WHEN 'Pending'     THEN ARRAY['Confirmed', 'Cancelled', 'No Show']::public.booking_status[]
    WHEN 'Confirmed'   THEN ARRAY['In-Progress', 'Cancelled', 'No Show']::public.booking_status[]
    WHEN 'In-Progress' THEN ARRAY['Completed']::public.booking_status[]
    ELSE ARRAY[]::public.booking_status[] END;
  IF NOT (p_status = ANY (v_allowed)) THEN
    RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, false, NULL, 'INVALID_STATUS_TRANSITION', 'Cannot transition from ' || b.status || ' to ' || p_status || '.', p_booking, NULL);
  END IF;
  IF p_status IN ('Cancelled', 'No Show') AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
    RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, false, NULL, 'REASON_REQUIRED', 'A reason is required when cancelling or marking a booking as no-show.', p_booking, NULL);
  END IF;

  -- the change (an exception block rolls back its own work; the log row is written after it)
  BEGIN
    UPDATE public.bookings
       SET status = p_status,
           cancellation_reason = CASE WHEN p_status IN ('Cancelled', 'No Show') THEN p_reason ELSE cancellation_reason END
     WHERE id = p_booking
     RETURNING updated_at, payment_status INTO v_upd, v_pay;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, false, NULL, v_code, v_msg, p_booking, NULL);
  END;

  -- same non-blocking side effects the client ran (referral credit, review-request outreach): a failure must never block Completed
  IF p_status = 'Completed' THEN
    BEGIN PERFORM public.credit_pending_referral_for_booking(p_booking);
    EXCEPTION WHEN others THEN RAISE WARNING 'credit_pending_referral_for_booking failed: %', SQLERRM; END;
    IF to_regprocedure('public.outreach_enqueue_for_completed(uuid)') IS NOT NULL THEN
      BEGIN PERFORM public.outreach_enqueue_for_completed(p_booking);
      EXCEPTION WHEN others THEN RAISE WARNING 'outreach_enqueue_for_completed failed: %', SQLERRM; END;
    END IF;
  END IF;

  -- undo: Completed never (immutable); a cancel / no-show only when nothing was refunded (payment untouched)
  v_undoable := p_status IN ('Confirmed', 'In-Progress') OR (p_status IN ('Cancelled', 'No Show') AND b.payment_status = 'unpaid' AND v_pay = 'unpaid');
  RETURN public._act_finish(ctx, 'booking.set_status', v_org, b.branch_id, v_inputs, true,
    jsonb_build_object('booking_id', p_booking, 'from_status', b.status, 'status', p_status), NULL, NULL, p_booking,
    CASE WHEN v_undoable THEN jsonb_build_object('kind', 'set_status', 'from', b.status, 'to', p_status,
           'prior_cancellation_reason', b.cancellation_reason, 'expect_updated_at', v_upd, 'expires_at', now() + interval '24 hours') END);
END $$;

-- 5. booking.reschedule -----------------------------------------------------------------------------------------------------
-- p_changes may hold dentist_id and chair_id (uuid, null or 'unassigned' = clear). An absent key means unchanged.
-- Ported from rescheduleBooking in api.js, plus org / branch checks on the new dentist and chair (this function bypasses RLS).
CREATE FUNCTION public.act_booking_reschedule(p_booking uuid, p_date date, p_start_time time, p_changes jsonb DEFAULT '{}'::jsonb, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; b public.bookings; v_org uuid; v_inputs jsonb; v_dur integer; v_end time;
  has_d boolean; has_c boolean; v_nd uuid; v_nc uuid; v_den record;
  v_set_d boolean := false; v_dname text; v_set_c boolean := false; v_cname text;
  v_eff_chair uuid; v_cap integer; v_cn text; v_conf integer; v_checkout timestamptz;
  v_row record; v_upd timestamptz; v_code text; v_msg text; v_prior_bd jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  p_changes := COALESCE(p_changes, '{}'::jsonb);
  v_inputs := jsonb_build_object('booking_id', p_booking, 'date', p_date, 'start_time', p_start_time, 'changes', p_changes) || public._act_ctx_inputs(p_ctx, ctx);

  SELECT * INTO b FROM public.bookings WHERE id = p_booking FOR UPDATE;
  IF b.id IS NOT NULL THEN SELECT org_id INTO v_org FROM public.branches WHERE id = b.branch_id; END IF;
  IF b.id IS NULL OR NOT public._act_in_scope(ctx, v_org, b.branch_id) THEN
    RETURN public._act_finish(ctx, 'booking.reschedule', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'BOOKING_NOT_FOUND', 'Booking not found.', p_booking, NULL);
  END IF;

  IF ctx ->> 'kind' = 'person' THEN
    IF ctx ->> 'role' NOT IN ('staff', 'manager', 'admin') THEN
      RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot reschedule bookings.', p_booking, NULL);
    END IF;
  ELSIF ctx ->> 'kind' = 'agent' THEN
    IF (ctx ->> 'approved_by') IS NULL THEN
      RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'APPROVAL_REQUIRED', 'Rescheduling needs a person''s approval.', p_booking, NULL);
    END IF;
  ELSE
    RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'This kind of caller cannot reschedule bookings.', p_booking, NULL);
  END IF;

  IF b.is_locked THEN
    RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'DAY_LOCKED', 'This day has been closed. No further modifications allowed.', p_booking, NULL);
  END IF;
  IF b.status IN ('Completed', 'Cancelled', 'No Show') THEN
    RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'BOOKING_IMMUTABLE', b.status || ' bookings cannot be modified.', p_booking, NULL);
  END IF;
  IF b.payment_status = 'paid' THEN
    RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'BOOKING_IMMUTABLE', 'Cannot reschedule a paid booking.', p_booking, NULL);
  END IF;
  IF p_date IS NULL OR p_start_time IS NULL THEN
    RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'INVALID_INPUT', 'A date and a start time are required.', p_booking, NULL);
  END IF;

  SELECT duration_minutes INTO v_dur FROM public.treatments WHERE id = b.treatment_id;
  IF v_dur IS NULL THEN
    RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'TREATMENT_NOT_FOUND', 'Could not determine treatment duration for this booking.', p_booking, NULL);
  END IF;
  v_end := p_start_time + (v_dur * interval '1 minute');   -- time + interval wraps at midnight, like addMinutesToTime

  has_d := p_changes ? 'dentist_id';
  has_c := p_changes ? 'chair_id';
  BEGIN
    v_nd := CASE WHEN p_changes ->> 'dentist_id' = 'unassigned' THEN NULL ELSE (p_changes ->> 'dentist_id')::uuid END;
    v_nc := CASE WHEN p_changes ->> 'chair_id' = 'unassigned' THEN NULL ELSE (p_changes ->> 'chair_id')::uuid END;
  EXCEPTION WHEN others THEN
    RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'INVALID_INPUT', 'dentist_id and chair_id must be a uuid, null or "unassigned".', p_booking, NULL);
  END;

  -- dentist: a reassignment is validated; otherwise the CURRENT dentist is re-validated against the new date and time
  IF has_d THEN
    v_set_d := true;
    IF v_nd IS NOT NULL THEN
      SELECT d.name, d.is_active, d.branch_id, d.org_id INTO v_den FROM public.dentists d WHERE d.id = v_nd;
      IF v_den.name IS NULL OR v_den.org_id IS DISTINCT FROM v_org THEN
        RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'INVALID_DENTIST', 'Dentist not found.', p_booking, NULL);
      END IF;
      IF v_den.is_active IS NOT TRUE THEN
        RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'DENTIST_INACTIVE', 'Cannot assign an inactive dentist.', p_booking, NULL);
      END IF;
      IF v_den.branch_id IS DISTINCT FROM b.branch_id THEN
        RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'INVALID_DENTIST', v_den.name || ' is not available in this branch.', p_booking, NULL);
      END IF;
      SELECT check_out_time INTO v_checkout FROM public.dentist_attendance WHERE dentist_id = v_nd AND date = p_date LIMIT 1;
      IF v_checkout IS NOT NULL AND ((p_date + p_start_time) AT TIME ZONE 'Asia/Kathmandu') >= v_checkout THEN
        RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'DENTIST_CHECKED_OUT', v_den.name || ' already checked out for this date.', p_booking, NULL);
      END IF;
      v_dname := v_den.name;
    END IF;
  ELSIF b.dentist_id IS NOT NULL THEN
    SELECT d.name, d.branch_id INTO v_den FROM public.dentists d WHERE d.id = b.dentist_id;
    IF v_den.name IS NOT NULL THEN
      IF v_den.branch_id IS DISTINCT FROM b.branch_id THEN
        RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'INVALID_DENTIST', v_den.name || ' is not available in this branch. Reassign or choose a different date.', p_booking, NULL);
      END IF;
      SELECT check_out_time INTO v_checkout FROM public.dentist_attendance WHERE dentist_id = b.dentist_id AND date = p_date LIMIT 1;
      IF v_checkout IS NOT NULL AND ((p_date + p_start_time) AT TIME ZONE 'Asia/Kathmandu') >= v_checkout THEN
        RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'DENTIST_CHECKED_OUT', v_den.name || ' already checked out for this date. Reassign or choose a different time.', p_booking, NULL);
      END IF;
    END IF;
  END IF;

  -- chair
  IF has_c THEN
    v_set_c := true;
    IF v_nc IS NOT NULL THEN
      SELECT name INTO v_cname FROM public.chairs WHERE id = v_nc AND branch_id = b.branch_id;
      IF v_cname IS NULL THEN
        RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'INVALID_CHAIR', 'Chair not found in this branch.', p_booking, NULL);
      END IF;
    END IF;
    v_eff_chair := v_nc;
  ELSE
    v_eff_chair := b.chair_id;
  END IF;

  IF v_eff_chair IS NOT NULL THEN
    SELECT name, COALESCE(capacity, 1) INTO v_cn, v_cap FROM public.chairs WHERE id = v_eff_chair;
    v_cap := COALESCE(v_cap, 1);
    SELECT count(*) INTO v_conf FROM public.bookings x
     WHERE x.chair_id = v_eff_chair AND x.branch_id = b.branch_id AND x.date = p_date
       AND x.status NOT IN ('Cancelled', 'No Show') AND x.id <> p_booking
       AND x.start_time < v_end AND x.end_time > p_start_time;
    IF v_conf >= v_cap THEN
      RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, 'CHAIR_CONFLICT',
        format('Chair %s is fully booked at this time (%s/%s slots used). Change the chair or pick a different time.', COALESCE(v_cn, 'unknown'), v_conf, v_cap), p_booking, NULL);
    END IF;
  END IF;

  -- the change
  v_prior_bd := COALESCE((SELECT jsonb_agg(jsonb_build_object('dentist_id', dentist_id, 'start_time', start_time, 'end_time', end_time))
                            FROM public.booking_dentists WHERE booking_id = p_booking), '[]'::jsonb);
  BEGIN
    UPDATE public.bookings
       SET date = p_date, start_time = p_start_time, end_time = v_end,
           dentist_id = CASE WHEN v_set_d THEN v_nd ELSE dentist_id END,
           dentist_name_snapshot = CASE WHEN v_set_d THEN v_dname ELSE dentist_name_snapshot END,
           chair_id = CASE WHEN v_set_c THEN v_nc ELSE chair_id END,
           chair_name_snapshot = CASE WHEN v_set_c THEN v_cname ELSE chair_name_snapshot END
     WHERE id = p_booking
     RETURNING date, start_time, end_time, dentist_id, chair_id INTO v_row;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_code = '23P01' THEN
      v_code := 'DENTIST_CONFLICT'; v_msg := 'Dentist is already booked during this time slot.';
    ELSIF v_code = 'P0003' AND v_msg NOT LIKE 'DENTIST_REQUIRED%' THEN
      v_code := 'CHAIR_CONFLICT'; v_msg := 'Chair is fully booked at this time. Change the chair or pick a different time.';
    END IF;
    RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, false, NULL, v_code, v_msg, p_booking, NULL);
  END;

  -- keep the booking_dentists junction in step (the calendar reads the dentist name from it); best effort, as before
  BEGIN
    IF has_d THEN
      DELETE FROM public.booking_dentists WHERE booking_id = p_booking;
      IF v_nd IS NOT NULL THEN
        INSERT INTO public.booking_dentists (booking_id, dentist_id, start_time, end_time) VALUES (p_booking, v_nd, v_row.start_time, v_row.end_time);
      END IF;
    ELSE
      UPDATE public.booking_dentists SET start_time = v_row.start_time, end_time = v_row.end_time WHERE booking_id = p_booking;
    END IF;
  EXCEPTION WHEN others THEN
    RAISE WARNING 'act_booking_reschedule booking_dentists sync failed: %', SQLERRM;
  END;

  SELECT updated_at INTO v_upd FROM public.bookings WHERE id = p_booking;
  RETURN public._act_finish(ctx, 'booking.reschedule', v_org, b.branch_id, v_inputs, true,
    jsonb_build_object('booking_id', p_booking, 'date', v_row.date, 'start_time', v_row.start_time, 'end_time', v_row.end_time,
                       'dentist_id', v_row.dentist_id, 'chair_id', v_row.chair_id), NULL, NULL, p_booking,
    jsonb_build_object('kind', 'reschedule',
      'prior', jsonb_build_object('date', b.date, 'start_time', b.start_time, 'end_time', b.end_time, 'dentist_id', b.dentist_id,
                                  'dentist_name_snapshot', b.dentist_name_snapshot, 'chair_id', b.chair_id, 'chair_name_snapshot', b.chair_name_snapshot),
      'prior_booking_dentists', v_prior_bd, 'expect_updated_at', v_upd, 'expires_at', now() + interval '24 hours'));
END $$;

-- 6. booking.flag_not_confirmed ----------------------------------------------------------------------------------------------
-- Marks a Pending booking for front-desk attention (the 6 pm rule). People (staff, manager, admin), agents and rules may flag.
CREATE FUNCTION public.act_booking_flag_not_confirmed(p_booking uuid, p_reason text DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; b public.bookings; v_org uuid; v_inputs jsonb; v_flag uuid := gen_random_uuid(); v_res jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('booking_id', p_booking, 'reason', p_reason) || public._act_ctx_inputs(p_ctx, ctx);

  SELECT * INTO b FROM public.bookings WHERE id = p_booking FOR UPDATE;
  IF b.id IS NOT NULL THEN SELECT org_id INTO v_org FROM public.branches WHERE id = b.branch_id; END IF;
  IF b.id IS NULL OR NOT public._act_in_scope(ctx, v_org, b.branch_id) THEN
    RETURN public._act_finish(ctx, 'booking.flag_not_confirmed', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'BOOKING_NOT_FOUND', 'Booking not found.', p_booking, NULL);
  END IF;
  IF ctx ->> 'kind' = 'person' AND ctx ->> 'role' NOT IN ('staff', 'manager', 'admin') THEN
    RETURN public._act_finish(ctx, 'booking.flag_not_confirmed', v_org, b.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot flag bookings.', p_booking, NULL);
  END IF;
  IF b.is_locked THEN
    RETURN public._act_finish(ctx, 'booking.flag_not_confirmed', v_org, b.branch_id, v_inputs, false, NULL, 'DAY_LOCKED', 'This day has been closed. No further modifications allowed.', p_booking, NULL);
  END IF;
  IF b.status <> 'Pending' THEN
    RETURN public._act_finish(ctx, 'booking.flag_not_confirmed', v_org, b.branch_id, v_inputs, false, NULL, 'NOT_PENDING', 'Only a booking that is still Pending can be flagged as not confirmed.', p_booking, NULL);
  END IF;

  IF EXISTS (SELECT 1 FROM public.booking_flags WHERE booking_id = p_booking AND kind = 'not_confirmed' AND cleared_at IS NULL) THEN
    RETURN public._act_finish(ctx, 'booking.flag_not_confirmed', v_org, b.branch_id, v_inputs, true,
      jsonb_build_object('booking_id', p_booking, 'already_flagged', true), NULL, NULL, p_booking, NULL);   -- nothing changed, so nothing to undo
  END IF;

  INSERT INTO public.booking_flags (id, org_id, branch_id, booking_id, kind, reason) VALUES (v_flag, v_org, b.branch_id, p_booking, 'not_confirmed', p_reason);
  v_res := public._act_finish(ctx, 'booking.flag_not_confirmed', v_org, b.branch_id, v_inputs, true,
    jsonb_build_object('booking_id', p_booking, 'flag_id', v_flag, 'already_flagged', false), NULL, NULL, p_booking,
    jsonb_build_object('kind', 'flag', 'flag_id', v_flag, 'expires_at', now() + interval '24 hours'));
  UPDATE public.booking_flags SET raised_by_action = (v_res ->> 'action_id')::uuid WHERE id = v_flag;
  RETURN v_res;
END $$;

-- 7. act_undo ----------------------------------------------------------------------------------------------------------------
-- Restores the PRIOR state directly (it does not go through the forward lifecycle rules: Confirmed -> Pending is not a normal
-- transition). It re-checks that the undoer may act on that booking, refuses when the booking changed since (updated_at), when
-- the 24 h window has passed, when it was already undone, or when the old slot is no longer free. It is logged as its own action.
CREATE FUNCTION public.act_undo(p_action_id uuid, p_reason text DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
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

-- 8. grants: the four actions are callable by signed-in users and the service role only; the helpers by nobody but the owner ------
REVOKE ALL ON FUNCTION public.act_booking_set_status(uuid, public.booking_status, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.act_booking_reschedule(uuid, date, time, jsonb, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.act_booking_flag_not_confirmed(uuid, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.act_undo(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_booking_set_status(uuid, public.booking_status, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.act_booking_reschedule(uuid, date, time, jsonb, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.act_booking_flag_not_confirmed(uuid, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.act_undo(uuid, text, jsonb) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public._act_resolve(jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._act_in_scope(jsonb, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._act_ctx_inputs(jsonb, jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._act_finish(jsonb, text, uuid, uuid, jsonb, boolean, jsonb, text, text, uuid, jsonb, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._action_log_guard() FROM PUBLIC, anon, authenticated, service_role;

COMMIT;
