-- migration-009: close SECURITY DEFINER functions that were callable by anyone on the internet.
--
-- Why: every public SECURITY DEFINER function was EXECUTE-able by PUBLIC/anon (the default grant) and
-- bypasses RLS. 32 of them had no caller check at all (e.g. platform_org_sales_base returned any
-- clinic's revenue, outreach_ai_consume let anyone burn a clinic's AI quota).
--
-- What this does (one transaction, idempotent):
--   1. Revokes EXECUTE from PUBLIC and anon on EVERY public SECURITY DEFINER function, then
--      re-grants anon only on the explicit public-booking allow-list below.
--   2. Trigger functions and internal/cron/edge-function-only functions are also revoked from
--      `authenticated`; internal ones are granted to service_role (pg_cron runs as postgres, edge
--      functions use the service role; triggers do not check EXECUTE when they fire).
--   3. Tightens five function bodies (same signatures and return types):
--        public_search_booking        exact booking number / exact phone only (was substring match)
--        public_get_booking_by_id     only a booking created in the last 15 min, or one in your org
--        upsert_customer_for_booking  org/branch must match; staff keep full update, anon/patients
--                                     can only fill in blanks (cannot overwrite an existing patient)
--        create_customer_account      must be signed in, and p_email must be the caller's own email
--        outreach_enqueue_for_completed  signed-in callers must be staff of the booking's org
--   4. Future-proofing: functions created by postgres from now on are not executable by
--      PUBLIC/anon/authenticated until granted explicitly.
-- Rollback: migration-009-rollback.sql restores the exact grants and bodies.

BEGIN;

-- 1 + 2: grants
DO $$
DECLARE
  f record;
  v_public_allow text[] := ARRAY[
    'public_check_branch_bookings_range', 'public_check_customer_exists', 'public_check_slot_availability',
    'public_find_customer_match', 'public_get_booking_by_id', 'public_lookup_referrer_by_phone',
    'public_record_customer_referral', 'public_search_booking',
    'find_customer_for_booking', 'upsert_customer_for_booking'
  ];
  v_internal text[] := ARRAY[
    'apply_due_staff_reverts', 'apply_due_staff_transfers', 'notify_left_behind_bookings',
    'notify_outreach_review', 'outreach_ai_consume', 'outreach_drain_outbox', 'outreach_scan_winback',
    'consume_ai_quota', 'phone_pairing_create', 'phone_pairing_redeem', 'phone_pairing_verify',
    'sync_booking_payment_status', 'platform_org_sales_base', 'platform_org_branch_breakdown',
    'platform_org_category_breakdown', 'login_with_pin', 'verify_pin',
    'can_delete_chair', 'can_delete_dentist', 'can_delete_treatment'
  ];
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname, (p.prorettype = 'trigger'::regtype) AS is_trigger
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f.sig);

    IF f.is_trigger OR f.proname = ANY (v_internal) THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', f.sig);
      IF NOT f.is_trigger THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig);
      END IF;
    ELSE
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
    END IF;

    IF f.proname = ANY (v_public_allow) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon', f.sig);
    END IF;
  END LOOP;
END $$;

-- 3a: public booking lookup: exact match only
CREATE OR REPLACE FUNCTION public.public_search_booking(p_branch_id uuid, p_query text)
 RETURNS SETOF bookings
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT b.*
  FROM public.bookings b
  WHERE b.branch_id = p_branch_id
    AND length(btrim(coalesce(p_query, ''))) > 0
    AND (
      upper(b.booking_number) = upper(btrim(p_query))
      OR (
        length(regexp_replace(p_query, '\D', '', 'g')) >= 9
        AND right(regexp_replace(coalesce(b.customer_phone, ''), '\D', '', 'g'), 10)
            = right(regexp_replace(p_query, '\D', '', 'g'), 10)
      )
    )
  ORDER BY b.date DESC
  LIMIT 20;
$function$;

-- 3b: public get-booking-by-id: only a just-created booking, or one in the caller's own org
CREATE OR REPLACE FUNCTION public.public_get_booking_by_id(p_booking_id uuid)
 RETURNS SETOF bookings
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT b.*
  FROM public.bookings b
  WHERE b.id = p_booking_id
    AND (b.created_at > now() - interval '15 minutes' OR public.branch_in_my_org(b.branch_id));
$function$;

-- 3c: customer upsert from the booking flow
CREATE OR REPLACE FUNCTION public.upsert_customer_for_booking(p_org_id uuid, p_branch_id uuid, p_full_name text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_gender text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
  v_existing_gender text;
  v_caller_org uuid := public.get_user_org_id();
  v_is_staff boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.org_id = p_org_id) THEN
    RAISE EXCEPTION 'upsert_customer_for_booking: branch does not belong to this organization';
  END IF;
  IF v_caller_org IS NOT NULL AND v_caller_org <> p_org_id THEN
    RAISE EXCEPTION 'upsert_customer_for_booking: not your organization';
  END IF;
  -- Staff of this org may update an existing patient; anonymous visitors and patient accounts may not
  -- overwrite someone else's details (they can only fill in blanks).
  v_is_staff := v_caller_org IS NOT NULL;

  SELECT c.id, c.gender INTO v_id, v_existing_gender
  FROM public.customers c
  WHERE c.org_id = p_org_id
    AND (
      (p_phone IS NOT NULL AND c.phone = p_phone)
      OR (p_email IS NOT NULL AND c.email = p_email)
    )
  ORDER BY (c.phone = p_phone) DESC NULLS LAST
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    IF v_is_staff THEN
      UPDATE public.customers
      SET full_name = p_full_name,
          phone = COALESCE(p_phone, phone),
          email = COALESCE(p_email, email),
          gender = CASE WHEN v_existing_gender IS NULL THEN COALESCE(p_gender, gender) ELSE gender END
      WHERE id = v_id;
    ELSE
      UPDATE public.customers
      SET email = COALESCE(email, p_email),
          gender = COALESCE(gender, p_gender)
      WHERE id = v_id;
    END IF;
    RETURN v_id;
  END IF;

  BEGIN
    INSERT INTO public.customers (org_id, branch_id, full_name, phone, email, gender)
    VALUES (p_org_id, p_branch_id, p_full_name, p_phone, p_email, p_gender)
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    -- Lost a race against customers_org_nphone_uniq: the winner is now visible.
    SELECT c.id INTO v_id
    FROM public.customers c
    WHERE c.org_id = p_org_id
      AND (
        (p_phone IS NOT NULL AND c.phone = p_phone)
        OR (p_email IS NOT NULL AND c.email = p_email)
      )
    ORDER BY (c.phone = p_phone) DESC NULLS LAST
    LIMIT 1;
  END;

  RETURN v_id;
END;
$function$;

-- 3d: patient account creation: only for the signed-in user's own (verified) email
CREATE OR REPLACE FUNCTION public.create_customer_account(p_org_id uuid, p_email text, p_phone text, p_full_name text)
 RETURNS customer_accounts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account customer_accounts;
  v_customer_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'create_customer_account: must be signed in';
  END IF;
  IF lower(p_email) IS DISTINCT FROM lower(auth.jwt() ->> 'email') THEN
    RAISE EXCEPTION 'create_customer_account: email must match the signed-in account';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = p_org_id AND is_active) THEN
    RAISE EXCEPTION 'create_customer_account: organization not found';
  END IF;

  SELECT id INTO v_customer_id
  FROM customers
  WHERE org_id = p_org_id AND lower(email) = lower(p_email)
  LIMIT 1;

  INSERT INTO customer_accounts (org_id, auth_user_id, email, phone, full_name, customer_id)
  VALUES (p_org_id, auth.uid(), p_email, p_phone, p_full_name, v_customer_id)
  RETURNING * INTO v_account;

  UPDATE bookings
  SET customer_account_id = v_account.id
  WHERE branch_id IN (SELECT id FROM branches WHERE org_id = p_org_id)
    AND customer_email = p_email
    AND customer_account_id IS NULL;

  RETURN v_account;
END;
$function$;

-- 3e: queue a review-request message: staff of the booking's org only
CREATE OR REPLACE FUNCTION public.outreach_enqueue_for_completed(p_booking_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_booking  public.bookings;
  v_rule     public.outreach_rules;
  v_template public.outreach_templates;
  v_customer public.customers;
  v_delay_hours integer;
BEGIN
  SELECT * INTO v_booking FROM public.bookings WHERE id = p_booking_id;
  IF v_booking IS NULL THEN
    RETURN;
  END IF;

  -- Signed-in callers must be staff of the booking's own organization. Cron and the service role
  -- have no JWT (auth.uid() IS NULL) and are not restricted; anon cannot reach this function.
  IF auth.uid() IS NOT NULL
     AND (public.get_user_role() IS NULL
          OR public.get_user_role() NOT IN ('staff', 'manager', 'admin')
          OR NOT public.branch_in_my_org(v_booking.branch_id)) THEN
    RAISE EXCEPTION 'outreach_enqueue_for_completed: not authorized for this booking';
  END IF;

  IF v_booking.customer_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_rule
  FROM public.outreach_rules
  WHERE org_id = (SELECT org_id FROM public.branches WHERE id = v_booking.branch_id)
    AND trigger_type = 'review_request'
    AND enabled = true;

  IF v_rule IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_template FROM public.outreach_templates WHERE id = v_rule.template_id;
  IF v_template IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_customer FROM public.customers WHERE id = v_booking.customer_id;
  IF v_customer IS NULL OR v_customer.email IS NULL OR btrim(v_customer.email) = '' THEN
    RETURN;
  END IF;

  v_delay_hours := COALESCE(v_rule.review_delay_hours, 24);

  INSERT INTO public.outreach_messages (
    org_id, rule_id, customer_id, booking_id, channel, to_address,
    subject, body, status, source, dedupe_key, scheduled_for
  )
  VALUES (
    v_rule.org_id,
    v_rule.id,
    v_customer.id,
    v_booking.id,
    v_rule.channel,
    v_customer.email,
    replace(v_template.subject, '{{customer_name}}', v_customer.full_name),
    replace(v_template.body, '{{customer_name}}', v_customer.full_name),
    CASE WHEN v_rule.send_mode = 'auto' THEN 'queued' ELSE 'review' END,
    'template',
    'review_request:' || p_booking_id,
    now() + (v_delay_hours || ' hours')::interval
  )
  ON CONFLICT (org_id, dedupe_key) DO NOTHING;
END;
$function$;

-- 4: future functions created by postgres are closed by default (grant explicitly per function)
-- (the global entry drops the implicit PUBLIC grant; the schema entry drops Supabase's explicit anon/authenticated grants)
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated;

COMMIT;
