-- migration-011-rollback (CMD-79): undo migration-011.
-- Postgres cannot drop an enum value, so 'practitioner' STAYS in public.user_role (unused after this runs).
-- Practitioner logins are moved back to 'staff' first. Run as postgres, NOT against production without the owner.

BEGIN;

-- outreach_enqueue_for_completed back to migration 009's body
DO $outreach$
BEGIN
  IF to_regprocedure('public.outreach_enqueue_for_completed(uuid)') IS NOT NULL THEN
    EXECUTE $q$
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
    $q$;
  END IF;
END $outreach$;

-- who loses the role: back to staff (this is the only data change)
UPDATE public.users SET role = 'staff' WHERE role::text = 'practitioner';

DROP POLICY IF EXISTS "Practitioner delete own consultation files" ON storage.objects;
DROP POLICY IF EXISTS "Practitioner upload own consultation files" ON storage.objects;
DROP POLICY IF EXISTS "Practitioner can update own consultations" ON public.consultations;
DROP POLICY IF EXISTS "Practitioner can create own consultations" ON public.consultations;
DROP POLICY IF EXISTS practitioner_own_treatment_note_update ON public.treatment_notes;
DROP POLICY IF EXISTS practitioner_own_treatment_note_insert ON public.treatment_notes;
DROP POLICY IF EXISTS practitioner_no_customer_delete ON public.customers;
DROP POLICY IF EXISTS practitioner_no_customer_insert ON public.customers;
DROP POLICY IF EXISTS practitioner_no_booking_dentists_delete ON public.booking_dentists;
DROP POLICY IF EXISTS practitioner_no_booking_dentists_update ON public.booking_dentists;
DROP POLICY IF EXISTS practitioner_no_booking_dentists_write ON public.booking_dentists;
DROP POLICY IF EXISTS practitioner_own_booking_update ON public.bookings;
DROP POLICY IF EXISTS practitioner_no_booking_delete ON public.bookings;
DROP POLICY IF EXISTS practitioner_no_booking_insert ON public.bookings;
-- policies on tables that may not exist in this database (see migration-011 section 4b)
DO $guarded$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['payment_refunds', 'memberships', 'membership_transactions', 'vouchers', 'voucher_claims', 'voucher_types',
                           'membership_tiers', 'reward_catalog', 'outreach_rules', 'outreach_templates',
                           'daily_reports', 'customer_referrals', 'customer_referral_credits', 'customer_referral_debits']
  LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'practitioner_no_' || t, t);
    END IF;
  END LOOP;
END $guarded$;

DROP POLICY IF EXISTS practitioner_no_payments ON public.payments;

DROP FUNCTION IF EXISTS public.set_user_access(uuid, public.user_role, uuid);
DROP FUNCTION IF EXISTS public.is_my_booking_row(uuid, uuid);
DROP FUNCTION IF EXISTS public.is_my_booking(uuid);
DROP FUNCTION IF EXISTS public.get_user_dentist_id();

DROP INDEX IF EXISTS public.users_dentist_id_key;
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_dentist_same_org_fkey;
ALTER TABLE public.users DROP COLUMN IF EXISTS dentist_id;
ALTER TABLE public.dentists DROP CONSTRAINT IF EXISTS dentists_id_org_id_key;

COMMIT;
