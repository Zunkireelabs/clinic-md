-- migration-009 rollback: restores the exact function grants and the five function bodies as they were
-- before migration-009 (grants captured from the local DB, which matches the production-schema copy).
-- Functions that do not exist in the target database are skipped.
BEGIN;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('_staff_transfer_can_manage(uuid)', false, false, false, true),
    ('apply_due_staff_reverts()', false, false, false, true),
    ('apply_due_staff_transfers()', false, false, false, true),
    ('branch_in_my_org(uuid)', false, true, true, true),
    ('can_access_consultation_booking(uuid)', true, true, true, true),
    ('can_delete_chair(uuid)', true, true, true, true),
    ('can_delete_dentist(uuid)', true, true, true, true),
    ('can_delete_treatment(uuid)', true, true, true, true),
    ('cancel_scheduled_transfer(uuid)', false, false, true, true),
    ('check_branch_online_capacity()', true, true, true, true),
    ('check_chair_capacity()', true, true, true, true),
    ('claim_voucher(uuid,numeric,date,text,text,uuid,text)', true, true, true, true),
    ('consultation_guard_columns()', true, true, true, true),
    ('consultation_refs_ok(uuid,uuid,uuid,uuid)', true, true, true, true),
    ('consultation_remote_topic_ok(text)', true, true, true, true),
    ('consultation_track_attendee()', true, true, true, true),
    ('consume_ai_quota(uuid,integer)', false, false, false, true),
    ('create_customer_account(uuid,text,text,text)', true, true, true, true),
    ('credit_pending_referral_for_booking(uuid)', true, true, true, true),
    ('customer_duplicate_candidates(uuid)', true, true, true, true),
    ('enqueue_notification(uuid,text,text,text,uuid)', true, true, true, true),
    ('enroll_member(uuid,uuid,numeric,text,text,uuid)', true, true, true, true),
    ('extend_membership(uuid,date,text,uuid)', true, true, true, true),
    ('extend_staff_transfer(uuid,integer,text)', false, false, true, true),
    ('find_customer_for_booking(uuid,text,text)', true, true, true, true),
    ('generate_booking_number()', true, true, true, true),
    ('get_referral_credit_balance(uuid)', true, true, true, true),
    ('get_user_branch_id()', true, true, true, true),
    ('get_user_branch_ids()', true, true, true, true),
    ('get_user_org_id()', true, true, true, true),
    ('get_user_role()', true, true, true, true),
    ('is_platform_admin()', true, true, true, true),
    ('issue_package(uuid,uuid,uuid,uuid,text,text,date,date,numeric,integer,text)', true, true, true, true),
    ('issue_voucher(uuid,uuid,text,text,numeric,numeric,date,date,text,uuid,jsonb,text)', true, true, true, true),
    ('list_discount_approvers()', true, true, true, true),
    ('list_membership_status_for_org(uuid)', true, true, true, true),
    ('list_vouchers_for_customer(uuid)', true, true, true, true),
    ('login_with_pin(text,text,text)', true, true, true, true),
    ('manual_block_scope_ok(uuid,uuid,uuid,uuid)', false, true, true, true),
    ('membership_recompute()', true, true, true, true),
    ('merge_customers(uuid,uuid)', true, true, true, true),
    ('notify_left_behind_bookings()', false, false, false, true),
    ('notify_outreach_review(uuid)', true, true, true, true),
    ('outreach_ai_consume(uuid,integer)', true, true, true, true),
    ('outreach_approve_message(uuid,text,text)', true, true, true, true),
    ('outreach_bulk_approve_messages(uuid[])', true, true, true, true),
    ('outreach_cancel_message(uuid)', true, true, true, true),
    ('outreach_drain_outbox()', true, true, true, true),
    ('outreach_enqueue_for_completed(uuid)', true, true, true, true),
    ('outreach_scan_winback()', true, true, true, true),
    ('outreach_send_manual(uuid,uuid,text,text,text,text,text)', true, true, true, true),
    ('phone_pairing_create(uuid,text,text,text,timestamp with time zone)', false, false, false, true),
    ('phone_pairing_redeem(text)', false, false, false, true),
    ('phone_pairing_verify(uuid,text,text)', false, false, false, true),
    ('platform_collect_commission(uuid,date,date,numeric,text,numeric,date,text,numeric)', true, true, true, true),
    ('platform_commission_for_range(uuid,date,date)', true, true, true, true),
    ('platform_get_org_bookings(uuid,date,date)', true, true, true, true),
    ('platform_get_org_membership_deposits(uuid,date,date)', true, true, true, true),
    ('platform_get_org_voucher_sales(uuid,date,date)', true, true, true, true),
    ('platform_get_revenue_rollup(date,date)', true, true, true, true),
    ('platform_list_collections(uuid)', true, true, true, true),
    ('platform_list_rates(uuid)', true, true, true, true),
    ('platform_org_branch_breakdown(uuid,date,date)', true, true, true, true),
    ('platform_org_category_breakdown(uuid,date,date)', true, true, true, true),
    ('platform_org_sales_base(uuid,date,date)', true, true, true, true),
    ('platform_preview_blended_commission(uuid,date,date)', true, true, true, true),
    ('platform_record_collection(uuid,date,date,numeric,date,text)', true, true, true, true),
    ('platform_set_commission_rate(uuid,numeric,text,numeric,date)', true, true, true, true),
    ('public_check_branch_bookings_range(uuid,date,date)', false, true, true, true),
    ('public_check_customer_exists(text,text)', true, true, true, true),
    ('public_check_slot_availability(uuid,date)', true, true, true, true),
    ('public_find_customer_match(text,text,text,text)', true, true, true, true),
    ('public_get_booking_by_id(uuid)', true, true, true, true),
    ('public_lookup_referrer_by_phone(text,text)', true, true, true, true),
    ('public_record_customer_referral(text,uuid,uuid,uuid)', true, true, true, true),
    ('public_search_booking(uuid,text)', true, true, true, true),
    ('record_customer_referral(uuid,uuid,uuid,text,text,numeric,uuid)', true, true, true, true),
    ('record_customer_referral(uuid,uuid,uuid,text,text,numeric)', true, true, true, true),
    ('record_customer_referral(uuid,uuid,uuid,text)', true, true, true, true),
    ('record_membership_payment(uuid,numeric,text)', true, true, true, true),
    ('record_membership_transaction(uuid,text,numeric,text,uuid,uuid,text,uuid)', true, true, true, true),
    ('record_referral_wallet_payment(uuid,numeric,text)', true, true, true, true),
    ('record_voucher_wallet_payment_pooled(uuid,numeric,text)', true, true, true, true),
    ('record_voucher_wallet_payment(uuid,uuid,numeric,text)', true, true, true, true),
    ('redeem_package_session(uuid,uuid,uuid,text,text)', true, true, true, true),
    ('redeem_referral_voucher(uuid,uuid)', true, true, true, true),
    ('renew_membership(uuid,numeric,text,uuid,text,uuid)', true, true, true, true),
    ('reschedule_staff_transfer_return(uuid,timestamp with time zone)', false, false, true, true),
    ('resolve_customer_referral_reward(uuid,text,numeric,uuid)', true, true, true, true),
    ('revert_staff_transfer_now(uuid,timestamp with time zone)', false, false, true, true),
    ('search_vouchers_for_payment(text)', true, true, true, true),
    ('set_membership_number()', true, true, true, true),
    ('sync_booking_payment_status(uuid)', true, true, true, true),
    ('transfer_dentist(uuid,uuid,time without time zone,integer,text,text,date,boolean)', false, false, true, true),
    ('trg_sync_payment_status_on_price()', true, true, true, true),
    ('update_booking_payment_status()', true, true, true, true),
    ('update_org_payment_methods(jsonb)', true, true, true, true),
    ('upsert_customer_for_booking(uuid,uuid,text,text,text,text)', true, true, true, true),
    ('verify_pin(text,text,text)', true, true, true, true)
  ) AS t(sig, g_public, g_anon, g_auth, g_service)
  LOOP
    IF to_regprocedure(r.sig) IS NULL THEN CONTINUE; END IF;
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role', r.sig);
    IF r.g_public  THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO PUBLIC', r.sig); END IF;
    IF r.g_anon    THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon', r.sig); END IF;
    IF r.g_auth    THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig); END IF;
    IF r.g_service THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig); END IF;
  END LOOP;
END $$;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.public_search_booking(p_branch_id uuid, p_query text)
 RETURNS SETOF bookings
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT b.*
  FROM public.bookings b
  WHERE b.branch_id = p_branch_id
    AND (
      b.booking_number ILIKE '%' || regexp_replace(p_query, '[,.()"\\%_]', '', 'g') || '%'
      OR b.customer_phone ILIKE '%' || regexp_replace(p_query, '[,.()"\\%_]', '', 'g') || '%'
    )
  ORDER BY b.date DESC
  LIMIT 20;
$function$;

CREATE OR REPLACE FUNCTION public.public_get_booking_by_id(p_booking_id uuid)
 RETURNS SETOF bookings
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT * FROM public.bookings WHERE id = p_booking_id;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_customer_for_booking(p_org_id uuid, p_branch_id uuid, p_full_name text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_gender text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
  v_existing_gender text;
BEGIN
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
    UPDATE public.customers
    SET full_name = p_full_name,
        phone = COALESCE(p_phone, phone),
        email = COALESCE(p_email, email),
        gender = CASE WHEN v_existing_gender IS NULL THEN COALESCE(p_gender, gender) ELSE gender END
    WHERE id = v_id;
    RETURN v_id;
  END IF;

  BEGIN
    INSERT INTO public.customers (org_id, branch_id, full_name, phone, email, gender)
    VALUES (p_org_id, p_branch_id, p_full_name, p_phone, p_email, p_gender)
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    -- Lost a race against customers_org_nphone_uniq — the winner is now visible.
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

COMMIT;
