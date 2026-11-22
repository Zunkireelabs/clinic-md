-- Migration 014 (CMD-83): guard the money SECURITY DEFINER functions against roles that may not touch money.
-- Needs 011, 012 and 013 applied first. NOT applied to prod. Rollback: migration-014-rollback.sql.
--
-- 011 closed the money TABLES to `practitioner` through RLS, but SECURITY DEFINER functions skip RLS. These
-- functions checked only the organisation, so practitioner (and admin_viewer, for writes) could run them.
--   can_read_money()  : staff, manager, admin, admin_viewer      (allow-list: unknown/future roles get false)
--   can_write_money() : staff, manager, admin
-- Write functions raise (42501, same RAISE EXCEPTION style as before). Read functions (language sql) return no
-- rows / NULL for a refused role. Bodies are otherwise unchanged (copied from pg_get_functiondef).

BEGIN;

CREATE OR REPLACE FUNCTION public.can_read_money() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(public.get_user_role()::text IN ('staff', 'manager', 'admin', 'admin_viewer'), false);
$$;
CREATE OR REPLACE FUNCTION public.can_write_money() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(public.get_user_role()::text IN ('staff', 'manager', 'admin'), false);
$$;
REVOKE ALL ON FUNCTION public.can_read_money()  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.can_write_money() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_read_money()  TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_write_money() TO authenticated;

-- Referral credit: the body moves, unchanged, to an internal function that nobody signed in can call. The
-- act_booking_set_status action (SECURITY DEFINER; used by staff, practitioners and agents) calls it directly, so a
-- practitioner or agent completing a booking still credits the referrer. The public name stays (src/services/api.js)
-- as a thin wrapper: same-org callers with a booking-capable role only, otherwise the existing no-op (NULL).
CREATE OR REPLACE FUNCTION public._credit_pending_referral_for_booking(p_booking_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_referral_id   uuid;
  v_org_id        uuid;
  v_referrer      uuid;
  v_status        text;
  v_reward_type   text;
  v_requested     numeric(12,2);
  v_requires_manual boolean;
  v_booking_status booking_status;
  v_payment_status text;
  v_amount        numeric(12,2);
  v_credit_id     uuid;
BEGIN
  SELECT id, org_id, referring_customer_id, reward_status, reward_type, requested_reward_amount, requires_manual_reward
    INTO v_referral_id, v_org_id, v_referrer, v_status, v_reward_type, v_requested, v_requires_manual
  FROM public.customer_referrals
  WHERE booking_id = p_booking_id
  FOR UPDATE;

  IF v_referral_id IS NULL THEN
    RETURN NULL; -- no referral attached to this booking; normal case
  END IF;

  IF v_status <> 'pending' THEN
    RETURN NULL; -- already credited or voided; idempotent no-op
  END IF;

  IF v_requires_manual THEN
    RETURN NULL; -- customer self-treatment referral — awaits an explicit staff decision
                 -- via resolve_customer_referral_reward, not auto-credited here
  END IF;

  SELECT status, payment_status INTO v_booking_status, v_payment_status
  FROM public.bookings WHERE id = p_booking_id;

  IF v_booking_status IS DISTINCT FROM 'Completed' THEN
    RETURN NULL; -- treatment not yet completed
  END IF;

  IF v_payment_status IS DISTINCT FROM 'paid' THEN
    RETURN NULL; -- payment not yet fully settled
  END IF;

  -- Gift card / voucher rewards are fulfilled by staff outside the system — mark credited
  -- for reporting, but never touch the wallet ledger.
  IF v_reward_type IN ('gift_card', 'voucher') THEN
    UPDATE public.customer_referrals
       SET reward_status = 'credited',
           reward_amount = v_requested,
           credited_at   = now(),
           credited_by   = auth.uid()
     WHERE id = v_referral_id;
    RETURN NULL;
  END IF;

  -- Wallet: staff-entered amount wins; fall back to the org-wide default.
  v_amount := v_requested;
  IF v_amount IS NULL THEN
    SELECT referral_reward_amount INTO v_amount FROM public.organizations WHERE id = v_org_id;
  END IF;

  IF v_amount IS NULL OR v_amount = 0 THEN
    UPDATE public.customer_referrals
       SET reward_status = 'credited',
           reward_amount = 0,
           credited_at   = now(),
           credited_by   = auth.uid()
     WHERE id = v_referral_id;
    RETURN NULL; -- confirmed, but no reward configured — nothing to ledger
  END IF;

  INSERT INTO public.customer_referral_credits (org_id, referral_id, customer_id, amount)
  VALUES (v_org_id, v_referral_id, v_referrer, v_amount)
  RETURNING id INTO v_credit_id;

  UPDATE public.customer_referrals
     SET reward_status = 'credited',
         reward_amount = v_amount,
         credited_at   = now(),
         credited_by   = auth.uid()
   WHERE id = v_referral_id;

  RETURN v_credit_id;
END;
$function$;

REVOKE ALL ON FUNCTION public._credit_pending_referral_for_booking(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.credit_pending_referral_for_booking(p_booking_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_org uuid;
BEGIN
  IF COALESCE(public.get_user_role()::text NOT IN ('staff', 'manager', 'admin', 'practitioner'), true) THEN
    RETURN NULL;
  END IF;
  SELECT br.org_id INTO v_org
  FROM public.bookings b JOIN public.branches br ON br.id = b.branch_id
  WHERE b.id = p_booking_id;
  IF v_org IS NULL OR v_org IS DISTINCT FROM public.get_user_org_id() THEN
    RETURN NULL;
  END IF;
  RETURN public._credit_pending_referral_for_booking(p_booking_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.act_booking_set_status(p_booking uuid, p_status booking_status, p_reason text DEFAULT NULL::text, p_ctx jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    BEGIN PERFORM public._credit_pending_referral_for_booking(p_booking);
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
END $function$;

CREATE OR REPLACE FUNCTION public.get_referral_credit_balance(p_customer_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT (
  SELECT
      COALESCE((SELECT SUM(amount) FROM public.customer_referral_credits
                WHERE customer_id = p_customer_id AND org_id = get_user_org_id()), 0)
      -
      COALESCE((SELECT SUM(amount) FROM public.customer_referral_debits
                WHERE customer_id = p_customer_id AND org_id = get_user_org_id()), 0)
  ) WHERE public.can_read_money();
$function$;

CREATE OR REPLACE FUNCTION public.list_discount_approvers()
 RETURNS TABLE(id uuid, full_name text, role user_role, branch_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT u.id, u.full_name, u.role, u.branch_id
  FROM public.users u
  WHERE u.is_active = true
    AND u.pin IS NOT NULL AND u.pin <> ''
    AND u.id <> auth.uid()
    AND public.can_read_money()
    AND u.org_id = (SELECT org_id FROM public.users WHERE id = auth.uid())
    AND (
      u.role = 'admin'
      OR (u.role = 'manager'
          AND u.branch_id = (SELECT branch_id FROM public.users WHERE id = auth.uid()))
    )
  ORDER BY u.role DESC, u.full_name;
$function$;

CREATE OR REPLACE FUNCTION public.list_membership_status_for_org(p_customer_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(customer_id uuid, membership_id uuid, membership_number text, tier_name text, status text, usable boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH ranked AS (
    SELECT
      m.customer_id, m.id, m.membership_number, t.name AS tier_name,
      m.balance, m.total_deposited, m.activation_date, m.expiry_date, t.advance_amount,
      ROW_NUMBER() OVER (PARTITION BY m.customer_id ORDER BY m.created_at DESC) AS rn
    FROM public.memberships m
    JOIN public.membership_tiers t ON t.id = m.tier_id
    WHERE m.org_id = get_user_org_id()
      AND (p_customer_id IS NULL OR m.customer_id = p_customer_id)
  ), computed AS (
    SELECT
      customer_id, id AS membership_id, membership_number, tier_name,
      CASE
        WHEN activation_date IS NULL THEN
          CASE
            WHEN balance <= 0 AND total_deposited > 0 THEN 'depleted'
            WHEN total_deposited >= advance_amount THEN 'active'
            ELSE 'pending'
          END
        WHEN balance <= 0 THEN 'depleted'
        WHEN expiry_date IS NOT NULL AND expiry_date < (now() AT TIME ZONE 'Asia/Kathmandu')::date THEN 'lapsed'
        ELSE 'active'
      END AS status
    FROM ranked
    WHERE rn = 1
  )
  SELECT
    customer_id, membership_id, membership_number, tier_name, status,
    (status IN ('active', 'lapsed')) AS usable
  FROM computed
  WHERE public.can_read_money();
$function$;

CREATE OR REPLACE FUNCTION public.list_vouchers_for_customer(p_customer_id uuid)
 RETURNS TABLE(voucher_id uuid, voucher_code text, guest_name text, guest_info text, expiry_date date, remaining_balance numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT
    v.id,
    v.voucher_code,
    v.guest_name,
    v.guest_info,
    v.expiry_date,
    (v.total_amount_issued - COALESCE(c.total_claimed, 0)) AS remaining_balance
  FROM public.vouchers v
  LEFT JOIN (
    SELECT voucher_id, SUM(amount_claimed) AS total_claimed
    FROM public.voucher_claims
    GROUP BY voucher_id
  ) c ON c.voucher_id = v.id
  WHERE v.org_id = get_user_org_id()
    AND public.can_read_money()
    AND v.customer_id = p_customer_id
    AND v.expiry_date >= (now() AT TIME ZONE 'Asia/Kathmandu')::date
    AND (v.total_amount_issued - COALESCE(c.total_claimed, 0)) > 0
  ORDER BY v.created_at DESC;
$function$;

CREATE OR REPLACE FUNCTION public.record_customer_referral(p_referring_customer_id uuid, p_referred_customer_id uuid, p_booking_id uuid, p_notes text DEFAULT NULL::text, p_reward_type text DEFAULT 'wallet'::text, p_reward_amount numeric DEFAULT NULL::numeric, p_reward_catalog_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_org   uuid := get_user_org_id();
  v_referrer_org uuid;
  v_referred_org uuid;
  v_booking_customer uuid;
  v_booking_branch   uuid;
  v_booking_org      uuid;
  v_referral_id  uuid;
BEGIN
  IF NOT public.can_write_money() THEN
    RAISE EXCEPTION 'record_customer_referral: your role cannot record money' USING ERRCODE = '42501';
  END IF;

  IF v_caller_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: caller has no organization';
  END IF;

  IF p_referring_customer_id = p_referred_customer_id THEN
    RAISE EXCEPTION 'record_customer_referral: a customer cannot refer themselves';
  END IF;

  IF p_reward_type IS DISTINCT FROM 'wallet' THEN
    RAISE EXCEPTION 'record_customer_referral: only wallet rewards are supported';
  END IF;

  IF p_reward_amount IS NOT NULL AND p_reward_amount < 0 THEN
    RAISE EXCEPTION 'record_customer_referral: reward_amount cannot be negative';
  END IF;

  SELECT org_id INTO v_referrer_org FROM public.customers WHERE id = p_referring_customer_id;
  SELECT org_id INTO v_referred_org FROM public.customers WHERE id = p_referred_customer_id;

  IF v_referrer_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: referring customer % not found', p_referring_customer_id;
  END IF;
  IF v_referred_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: referred customer % not found', p_referred_customer_id;
  END IF;
  IF v_referrer_org IS DISTINCT FROM v_caller_org OR v_referred_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_customer_referral: customers must be in your organization';
  END IF;

  SELECT b.customer_id, b.branch_id, br.org_id
    INTO v_booking_customer, v_booking_branch, v_booking_org
  FROM public.bookings b
  JOIN public.branches br ON br.id = b.branch_id
  WHERE b.id = p_booking_id;

  IF v_booking_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: booking % not found', p_booking_id;
  END IF;
  IF v_booking_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_customer_referral: booking is not in your organization';
  END IF;
  IF v_booking_customer IS DISTINCT FROM p_referred_customer_id THEN
    RAISE EXCEPTION 'record_customer_referral: booking does not belong to the referred customer';
  END IF;

  IF EXISTS (SELECT 1 FROM public.customer_referrals WHERE referred_customer_id = p_referred_customer_id) THEN
    RAISE EXCEPTION 'record_customer_referral: this customer has already been referred once';
  END IF;

  -- p_reward_catalog_id is accepted for signature compatibility with existing
  -- callers but ignored — only wallet rewards are supported now, so there's no
  -- catalog item to look up or link.
  INSERT INTO public.customer_referrals
    (org_id, referring_customer_id, referred_customer_id, booking_id, created_by, notes,
     reward_type, requested_reward_amount)
  VALUES
    (v_caller_org, p_referring_customer_id, p_referred_customer_id, p_booking_id, auth.uid(), p_notes,
     p_reward_type, p_reward_amount)
  RETURNING id INTO v_referral_id;

  RETURN v_referral_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_customer_referral(p_referring_customer_id uuid, p_referred_customer_id uuid, p_booking_id uuid, p_notes text DEFAULT NULL::text, p_reward_type text DEFAULT 'wallet'::text, p_reward_amount numeric DEFAULT NULL::numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_org   uuid := get_user_org_id();
  v_referrer_org uuid;
  v_referred_org uuid;
  v_booking_customer uuid;
  v_booking_branch   uuid;
  v_booking_org      uuid;
  v_referral_id  uuid;
BEGIN
  IF NOT public.can_write_money() THEN
    RAISE EXCEPTION 'record_customer_referral: your role cannot record money' USING ERRCODE = '42501';
  END IF;

  IF v_caller_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: caller has no organization';
  END IF;

  IF p_referring_customer_id = p_referred_customer_id THEN
    RAISE EXCEPTION 'record_customer_referral: a customer cannot refer themselves';
  END IF;

  IF p_reward_type IS DISTINCT FROM 'wallet' THEN
    RAISE EXCEPTION 'record_customer_referral: only wallet rewards are supported';
  END IF;

  IF p_reward_amount IS NOT NULL AND p_reward_amount < 0 THEN
    RAISE EXCEPTION 'record_customer_referral: reward_amount cannot be negative';
  END IF;

  SELECT org_id INTO v_referrer_org FROM public.customers WHERE id = p_referring_customer_id;
  SELECT org_id INTO v_referred_org FROM public.customers WHERE id = p_referred_customer_id;

  IF v_referrer_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: referring customer % not found', p_referring_customer_id;
  END IF;
  IF v_referred_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: referred customer % not found', p_referred_customer_id;
  END IF;
  IF v_referrer_org IS DISTINCT FROM v_caller_org OR v_referred_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_customer_referral: customers must be in your organization';
  END IF;

  SELECT b.customer_id, b.branch_id, br.org_id
    INTO v_booking_customer, v_booking_branch, v_booking_org
  FROM public.bookings b
  JOIN public.branches br ON br.id = b.branch_id
  WHERE b.id = p_booking_id;

  IF v_booking_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: booking % not found', p_booking_id;
  END IF;
  IF v_booking_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_customer_referral: booking is not in your organization';
  END IF;
  IF v_booking_customer IS DISTINCT FROM p_referred_customer_id THEN
    RAISE EXCEPTION 'record_customer_referral: booking does not belong to the referred customer';
  END IF;

  IF EXISTS (SELECT 1 FROM public.customer_referrals WHERE referred_customer_id = p_referred_customer_id) THEN
    RAISE EXCEPTION 'record_customer_referral: this customer has already been referred once';
  END IF;

  INSERT INTO public.customer_referrals
    (org_id, referring_customer_id, referred_customer_id, booking_id, created_by, notes,
     reward_type, requested_reward_amount)
  VALUES
    (v_caller_org, p_referring_customer_id, p_referred_customer_id, p_booking_id, auth.uid(), p_notes,
     p_reward_type, p_reward_amount)
  RETURNING id INTO v_referral_id;

  RETURN v_referral_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_customer_referral(p_referring_customer_id uuid, p_referred_customer_id uuid, p_booking_id uuid, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_org   uuid := get_user_org_id();
  v_referrer_org uuid;
  v_referred_org uuid;
  v_booking_customer uuid;
  v_booking_branch   uuid;
  v_booking_org      uuid;
  v_referral_id  uuid;
BEGIN
  IF NOT public.can_write_money() THEN
    RAISE EXCEPTION 'record_customer_referral: your role cannot record money' USING ERRCODE = '42501';
  END IF;

  IF v_caller_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: caller has no organization';
  END IF;

  IF p_referring_customer_id = p_referred_customer_id THEN
    RAISE EXCEPTION 'record_customer_referral: a customer cannot refer themselves';
  END IF;

  SELECT org_id INTO v_referrer_org FROM public.customers WHERE id = p_referring_customer_id;
  SELECT org_id INTO v_referred_org FROM public.customers WHERE id = p_referred_customer_id;

  IF v_referrer_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: referring customer % not found', p_referring_customer_id;
  END IF;
  IF v_referred_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: referred customer % not found', p_referred_customer_id;
  END IF;
  IF v_referrer_org IS DISTINCT FROM v_caller_org OR v_referred_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_customer_referral: customers must be in your organization';
  END IF;

  SELECT b.customer_id, b.branch_id, br.org_id
    INTO v_booking_customer, v_booking_branch, v_booking_org
  FROM public.bookings b
  JOIN public.branches br ON br.id = b.branch_id
  WHERE b.id = p_booking_id;

  IF v_booking_org IS NULL THEN
    RAISE EXCEPTION 'record_customer_referral: booking % not found', p_booking_id;
  END IF;
  IF v_booking_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_customer_referral: booking is not in your organization';
  END IF;
  IF v_booking_customer IS DISTINCT FROM p_referred_customer_id THEN
    RAISE EXCEPTION 'record_customer_referral: booking does not belong to the referred customer';
  END IF;

  IF EXISTS (SELECT 1 FROM public.customer_referrals WHERE referred_customer_id = p_referred_customer_id) THEN
    RAISE EXCEPTION 'record_customer_referral: this customer has already been referred once';
  END IF;

  INSERT INTO public.customer_referrals
    (org_id, referring_customer_id, referred_customer_id, booking_id, created_by, notes)
  VALUES
    (v_caller_org, p_referring_customer_id, p_referred_customer_id, p_booking_id, auth.uid(), p_notes)
  RETURNING id INTO v_referral_id;

  RETURN v_referral_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_membership_payment(p_booking_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_org    uuid := get_user_org_id();
  v_actor         uuid := auth.uid();
  v_customer_id   uuid;
  v_booking_org   uuid;
  v_booking_branch uuid;
  v_membership_id uuid;
  v_balance       numeric(12,2);
  v_payment_id    uuid;
BEGIN
  IF NOT public.can_write_money() THEN
    RAISE EXCEPTION 'record_membership_payment: your role cannot record money' USING ERRCODE = '42501';
  END IF;

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'record_membership_payment: must be signed in';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'record_membership_payment: amount must be positive';
  END IF;

  -- Resolve the booking → customer → org. Walk-ins (NULL customer_id) cannot
  -- use a wallet because there's nothing to bill against.
  SELECT b.customer_id, br.org_id, b.branch_id
    INTO v_customer_id, v_booking_org, v_booking_branch
  FROM public.bookings b
  JOIN public.branches br ON br.id = b.branch_id
  WHERE b.id = p_booking_id;

  IF v_booking_org IS NULL THEN
    RAISE EXCEPTION 'record_membership_payment: booking % not found', p_booking_id;
  END IF;

  IF v_booking_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_membership_payment: booking is not in your organization';
  END IF;

  IF v_customer_id IS NULL THEN
    RAISE EXCEPTION 'record_membership_payment: booking has no linked customer (walk-in cannot use a wallet)';
  END IF;

  -- Find the most recent membership for this customer in the org and lock it.
  -- (One non-depleted membership per customer is enforced by the partial unique
  -- index in migration-045, so this is unambiguous in practice.)
  SELECT id, balance
    INTO v_membership_id, v_balance
  FROM public.memberships
  WHERE org_id = v_caller_org AND customer_id = v_customer_id
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_membership_id IS NULL THEN
    RAISE EXCEPTION 'record_membership_payment: customer has no membership';
  END IF;

  IF v_balance < p_amount THEN
    RAISE EXCEPTION 'record_membership_payment: insufficient wallet balance (have %, need %)',
      v_balance, p_amount;
  END IF;

  -- Atomic pair: payments INSERT first so we can link the deduction back to it.
  INSERT INTO public.payments (booking_id, amount, payment_mode, recorded_by, notes)
  VALUES (p_booking_id, p_amount, 'Membership', v_actor, p_notes)
  RETURNING id INTO v_payment_id;

  INSERT INTO public.membership_transactions
    (membership_id, org_id, kind, amount, payment_mode, booking_id, payment_id, performed_by, notes, branch_id)
  VALUES
    (v_membership_id, v_caller_org, 'deduction', -p_amount, NULL, p_booking_id, v_payment_id, v_actor,
     COALESCE(p_notes, 'Booking checkout'), v_booking_branch);

  RETURN v_payment_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_referral_wallet_payment(p_booking_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_org    uuid := get_user_org_id();
  v_actor         uuid := auth.uid();
  v_customer_id   uuid;
  v_booking_org   uuid;
  v_is_locked     boolean;
  v_balance       numeric(12,2);
  v_payment_id    uuid;
BEGIN
  IF NOT public.can_write_money() THEN
    RAISE EXCEPTION 'record_referral_wallet_payment: your role cannot record money' USING ERRCODE = '42501';
  END IF;

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'record_referral_wallet_payment: must be signed in';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'record_referral_wallet_payment: amount must be positive';
  END IF;

  SELECT b.customer_id, br.org_id, b.is_locked
    INTO v_customer_id, v_booking_org, v_is_locked
  FROM public.bookings b
  JOIN public.branches br ON br.id = b.branch_id
  WHERE b.id = p_booking_id
  FOR UPDATE OF b;

  IF v_booking_org IS NULL THEN
    RAISE EXCEPTION 'record_referral_wallet_payment: booking % not found', p_booking_id;
  END IF;

  IF v_booking_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_referral_wallet_payment: booking is not in your organization';
  END IF;

  IF v_is_locked THEN
    RAISE EXCEPTION 'record_referral_wallet_payment: this day has been closed, no further modifications allowed';
  END IF;

  IF v_customer_id IS NULL THEN
    RAISE EXCEPTION 'record_referral_wallet_payment: booking has no linked customer';
  END IF;

  -- Lock the customer row so a concurrent wallet payment on a DIFFERENT
  -- booking for the same customer can't race the balance check below —
  -- the booking-row lock above only serializes calls on this booking_id.
  PERFORM 1 FROM public.customers WHERE id = v_customer_id FOR UPDATE;

  -- Re-derive the balance server-side rather than trusting the client's read —
  -- never trust a client-computed balance for a spend.
  v_balance := public.get_referral_credit_balance(v_customer_id);

  IF v_balance < p_amount THEN
    RAISE EXCEPTION 'record_referral_wallet_payment: insufficient referral wallet balance (have %, need %)',
      v_balance, p_amount;
  END IF;

  INSERT INTO public.payments (booking_id, amount, payment_mode, recorded_by, notes)
  VALUES (p_booking_id, p_amount, 'ReferralWallet', v_actor, p_notes)
  RETURNING id INTO v_payment_id;

  INSERT INTO public.customer_referral_debits
    (org_id, customer_id, amount, booking_id, payment_id, created_by)
  VALUES
    (v_caller_org, v_customer_id, p_amount, p_booking_id, v_payment_id, v_actor);

  RETURN v_payment_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_voucher_wallet_payment_pooled(p_booking_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_org        uuid := get_user_org_id();
  v_actor             uuid := auth.uid();
  v_booking_org       uuid;
  v_branch_id         uuid;
  v_customer_id       uuid;
  v_customer_name     text;
  v_is_locked         boolean;
  v_payment_id        uuid;
  v_remaining         numeric(10,2);
  v_take              numeric(10,2);
  v_voucher_id        uuid;
  v_total_issued      numeric(10,2);
  v_already_claimed   numeric(10,2);
  v_voucher_remaining numeric(10,2);
BEGIN
  IF NOT public.can_write_money() THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment_pooled: your role cannot record money' USING ERRCODE = '42501';
  END IF;

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment_pooled: must be signed in';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment_pooled: amount must be positive';
  END IF;

  SELECT br.org_id, b.branch_id, b.customer_id, b.customer_name, b.is_locked
    INTO v_booking_org, v_branch_id, v_customer_id, v_customer_name, v_is_locked
  FROM public.bookings b
  JOIN public.branches br ON br.id = b.branch_id
  WHERE b.id = p_booking_id
  FOR UPDATE OF b;

  IF v_booking_org IS NULL THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment_pooled: booking % not found', p_booking_id;
  END IF;
  IF v_booking_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment_pooled: booking is not in your organization';
  END IF;
  IF v_is_locked THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment_pooled: this day has been closed, no further modifications allowed';
  END IF;
  IF v_customer_id IS NULL THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment_pooled: this booking has no linked customer account';
  END IF;

  INSERT INTO public.payments (booking_id, amount, payment_mode, recorded_by, notes)
  VALUES (p_booking_id, p_amount, 'VoucherWallet', v_actor, p_notes)
  RETURNING id INTO v_payment_id;

  v_remaining := p_amount;

  -- Lock soonest-expiring vouchers first (so nothing is left to expire
  -- unused), one row at a time via the cursor's FOR UPDATE -- no join here,
  -- so the lock is acquired against the bare voucher row, exactly like
  -- record_voucher_wallet_payment's single-voucher lock.
  FOR v_voucher_id, v_total_issued IN
    SELECT v.id, v.total_amount_issued
    FROM public.vouchers v
    WHERE v.customer_id = v_customer_id
      AND v.org_id = v_caller_org
      AND v.expiry_date >= (now() AT TIME ZONE 'Asia/Kathmandu')::date
    ORDER BY v.expiry_date ASC, v.created_at ASC
    FOR UPDATE OF v
  LOOP
    EXIT WHEN v_remaining <= 0;

    -- Row is locked now -- re-derive the balance server-side rather than
    -- trusting anything computed before the lock. Any concurrent claim
    -- against this voucher (pooled or single) must already have committed
    -- (and released the lock) or be blocked waiting behind us, so this SUM
    -- is guaranteed accurate.
    SELECT COALESCE(SUM(amount_claimed), 0) INTO v_already_claimed
    FROM public.voucher_claims
    WHERE voucher_id = v_voucher_id;

    v_voucher_remaining := v_total_issued - v_already_claimed;
    IF v_voucher_remaining <= 0 THEN
      CONTINUE;
    END IF;

    v_take := LEAST(v_remaining, v_voucher_remaining);

    INSERT INTO public.voucher_claims (
      voucher_id, org_id, redeemed_date, guest_name_used_by, treatment_claimed,
      branch_claimed_id, amount_claimed, notes, performed_by, booking_id, payment_id
    )
    VALUES (
      v_voucher_id, v_caller_org, (now() AT TIME ZONE 'Asia/Kathmandu')::date, v_customer_name, NULL,
      v_branch_id, v_take, p_notes, v_actor, p_booking_id, v_payment_id
    );

    v_remaining := round(v_remaining - v_take, 2);
  END LOOP;

  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment_pooled: amount % exceeds combined voucher balance (short by %)',
      p_amount, v_remaining;
  END IF;

  RETURN v_payment_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_voucher_wallet_payment(p_booking_id uuid, p_voucher_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_org      uuid := get_user_org_id();
  v_actor           uuid := auth.uid();
  v_booking_org     uuid;
  v_branch_id       uuid;
  v_customer_name   text;
  v_is_locked       boolean;
  v_voucher_org     uuid;
  v_total_issued    numeric(10,2);
  v_expiry_date     date;
  v_already_claimed numeric(10,2);
  v_payment_id      uuid;
  v_claim_id        uuid;
BEGIN
  IF NOT public.can_write_money() THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment: your role cannot record money' USING ERRCODE = '42501';
  END IF;

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment: must be signed in';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment: amount must be positive';
  END IF;

  SELECT br.org_id, b.branch_id, b.customer_name, b.is_locked
    INTO v_booking_org, v_branch_id, v_customer_name, v_is_locked
  FROM public.bookings b
  JOIN public.branches br ON br.id = b.branch_id
  WHERE b.id = p_booking_id
  FOR UPDATE OF b;

  IF v_booking_org IS NULL THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment: booking % not found', p_booking_id;
  END IF;

  IF v_booking_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment: booking is not in your organization';
  END IF;

  IF v_is_locked THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment: this day has been closed, no further modifications allowed';
  END IF;

  -- Lock the voucher row so a concurrent claim/payment can't race the balance check.
  SELECT org_id, total_amount_issued, expiry_date
    INTO v_voucher_org, v_total_issued, v_expiry_date
  FROM public.vouchers
  WHERE id = p_voucher_id
  FOR UPDATE;

  IF v_voucher_org IS NULL THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment: voucher % not found', p_voucher_id;
  END IF;
  IF v_voucher_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment: voucher is not in your organization';
  END IF;

  IF v_expiry_date < (now() AT TIME ZONE 'Asia/Kathmandu')::date THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment: voucher expired on %', v_expiry_date;
  END IF;

  -- Re-derive the balance server-side rather than trusting the client's read —
  -- never trust a client-computed balance for a spend.
  SELECT COALESCE(SUM(amount_claimed), 0) INTO v_already_claimed
  FROM public.voucher_claims
  WHERE voucher_id = p_voucher_id;

  IF p_amount > (v_total_issued - v_already_claimed) THEN
    RAISE EXCEPTION 'record_voucher_wallet_payment: amount % exceeds remaining voucher balance %',
      p_amount, (v_total_issued - v_already_claimed);
  END IF;

  INSERT INTO public.payments (booking_id, amount, payment_mode, recorded_by, notes)
  VALUES (p_booking_id, p_amount, 'VoucherWallet', v_actor, p_notes)
  RETURNING id INTO v_payment_id;

  INSERT INTO public.voucher_claims (
    voucher_id, org_id, redeemed_date, guest_name_used_by, treatment_claimed,
    branch_claimed_id, amount_claimed, notes, performed_by, booking_id, payment_id
  )
  VALUES (
    p_voucher_id, v_caller_org, (now() AT TIME ZONE 'Asia/Kathmandu')::date, v_customer_name, NULL,
    v_branch_id, p_amount, p_notes, v_actor, p_booking_id, v_payment_id
  )
  RETURNING id INTO v_claim_id;

  RETURN v_payment_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.redeem_referral_voucher(p_referral_id uuid, p_booking_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_org      uuid := get_user_org_id();
  v_actor           uuid := auth.uid();
  v_referral_org    uuid;
  v_referring_cust  uuid;
  v_reward_type     text;
  v_reward_status   text;
  v_redeemed_at     timestamptz;
  v_catalog_value   numeric(12,2);
  v_requested       numeric(12,2);
  v_value           numeric(12,2);
  v_booking_org     uuid;
  v_booking_customer uuid;
  v_is_locked       boolean;
  v_payment_id      uuid;
BEGIN
  IF NOT public.can_write_money() THEN
    RAISE EXCEPTION 'redeem_referral_voucher: your role cannot record money' USING ERRCODE = '42501';
  END IF;

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'redeem_referral_voucher: must be signed in';
  END IF;

  SELECT cr.org_id, cr.referring_customer_id, cr.reward_type, cr.reward_status,
         cr.redeemed_at, rc.value, cr.requested_reward_amount
    INTO v_referral_org, v_referring_cust, v_reward_type, v_reward_status,
         v_redeemed_at, v_catalog_value, v_requested
  FROM public.customer_referrals cr
  LEFT JOIN public.reward_catalog rc ON rc.id = cr.reward_catalog_id
  WHERE cr.id = p_referral_id
  FOR UPDATE OF cr;

  IF v_referral_org IS NULL THEN
    RAISE EXCEPTION 'redeem_referral_voucher: referral % not found', p_referral_id;
  END IF;
  IF v_referral_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'redeem_referral_voucher: referral is not in your organization';
  END IF;
  IF v_reward_type IS DISTINCT FROM 'voucher' THEN
    RAISE EXCEPTION 'redeem_referral_voucher: referral % is not a voucher reward', p_referral_id;
  END IF;
  IF v_reward_status IS DISTINCT FROM 'credited' THEN
    RAISE EXCEPTION 'redeem_referral_voucher: reward has not been credited yet';
  END IF;
  IF v_redeemed_at IS NOT NULL THEN
    RAISE EXCEPTION 'redeem_referral_voucher: voucher has already been redeemed';
  END IF;

  SELECT b.customer_id, br.org_id, b.is_locked
    INTO v_booking_customer, v_booking_org, v_is_locked
  FROM public.bookings b
  JOIN public.branches br ON br.id = b.branch_id
  WHERE b.id = p_booking_id
  FOR UPDATE OF b;

  IF v_booking_org IS NULL THEN
    RAISE EXCEPTION 'redeem_referral_voucher: booking % not found', p_booking_id;
  END IF;
  IF v_booking_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'redeem_referral_voucher: booking is not in your organization';
  END IF;
  IF v_is_locked THEN
    RAISE EXCEPTION 'redeem_referral_voucher: this day has been closed, no further modifications allowed';
  END IF;
  IF v_booking_customer IS DISTINCT FROM v_referring_cust THEN
    RAISE EXCEPTION 'redeem_referral_voucher: voucher belongs to a different customer than this booking';
  END IF;

  v_value := COALESCE(v_catalog_value, v_requested);
  IF v_value IS NULL OR v_value <= 0 THEN
    RAISE EXCEPTION 'redeem_referral_voucher: voucher has no redeemable value';
  END IF;

  INSERT INTO public.payments (booking_id, amount, payment_mode, recorded_by, notes)
  VALUES (p_booking_id, v_value, 'ReferralVoucher', v_actor, NULL)
  RETURNING id INTO v_payment_id;

  UPDATE public.customer_referrals
     SET redeemed_at         = now(),
         redeemed_booking_id = p_booking_id,
         redeemed_by         = v_actor
   WHERE id = p_referral_id;

  RETURN v_payment_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.search_vouchers_for_payment(p_query text)
 RETURNS TABLE(voucher_id uuid, voucher_code text, guest_name text, guest_info text, expiry_date date, remaining_balance numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT
    v.id,
    v.voucher_code,
    v.guest_name,
    v.guest_info,
    v.expiry_date,
    (v.total_amount_issued - COALESCE(c.total_claimed, 0)) AS remaining_balance
  FROM public.vouchers v
  LEFT JOIN (
    SELECT voucher_id, SUM(amount_claimed) AS total_claimed
    FROM public.voucher_claims
    GROUP BY voucher_id
  ) c ON c.voucher_id = v.id
  WHERE v.org_id = get_user_org_id()
    AND public.can_read_money()
    AND v.expiry_date >= (now() AT TIME ZONE 'Asia/Kathmandu')::date
    AND (v.total_amount_issued - COALESCE(c.total_claimed, 0)) > 0
    AND (
      p_query IS NULL OR btrim(p_query) = '' OR
      v.voucher_code ILIKE '%' || p_query || '%' OR
      v.guest_name   ILIKE '%' || p_query || '%' OR
      v.guest_info   ILIKE '%' || p_query || '%'
    )
  ORDER BY v.guest_name
  LIMIT 10;
$function$;

COMMIT;
