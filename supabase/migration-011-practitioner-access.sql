-- migration-011 (CMD-79): practitioner access level + login-to-practitioner link.
--
-- Access level and practitioner profile are separate (docs/SITEMAP.md section 7):
--   * new access level `practitioner`: front-desk read access for their branch, no money / payroll / settings;
--   * any login can be linked to ONE dentists row via users.dentist_id (owner+profile, manager+profile, ...).
--
-- NOT applied to production. Apply to prod by hand BEFORE the code reaches main (CLAUDE.md, Database).
-- Rollback: migration-011-rollback.sql.
--
-- ENUM NOTE: a value added with ALTER TYPE ... ADD VALUE cannot be USED in the same transaction. Everything below
-- therefore compares the role as text (`get_user_role()::text`), never as the literal enum value, so this whole
-- file also applies cleanly inside one transaction (psql -1, as scripts/local-db-bootstrap.sh does). If you apply it
-- by hand you may instead run step 1 on its own first; the rest is unchanged.
--
-- WHY RESTRICTIVE POLICIES: most existing read/write policies carry no role test (branch/org scope only), so a new
-- role inherits them. No existing policy is edited (no role is widened). Where practitioner must be denied we add
-- AS RESTRICTIVE policies, which are ANDed with the existing permissive ones. They test
-- `get_user_role()::text IS DISTINCT FROM 'practitioner'` (NOT `<>`): patient and phone-pair sessions have no
-- users row, get_user_role() is NULL, and `NULL <> 'x'` would silently block them.

BEGIN;

-- 1. the role -----------------------------------------------------------------------------------------------------
ALTER TYPE public.user_role ADD VALUE IF NOT EXISTS 'practitioner';

-- 2. the link: users.dentist_id -> dentists, same org -----------------------------------------------------------------
ALTER TABLE public.dentists ADD CONSTRAINT dentists_id_org_id_key UNIQUE (id, org_id);

ALTER TABLE public.users ADD COLUMN dentist_id uuid NULL;

-- Composite FK keeps the link inside one org. ON DELETE SET NULL (dentist_id) nulls only dentist_id (org_id is NOT NULL).
ALTER TABLE public.users
  ADD CONSTRAINT users_dentist_same_org_fkey
  FOREIGN KEY (dentist_id, org_id) REFERENCES public.dentists (id, org_id) ON DELETE SET NULL (dentist_id);

-- One profile, at most one login.
CREATE UNIQUE INDEX users_dentist_id_key ON public.users (dentist_id) WHERE dentist_id IS NOT NULL;

-- 3. helpers ------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_user_dentist_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = public
    AS $$
  SELECT dentist_id FROM public.users WHERE id = auth.uid();
$$;
REVOKE ALL ON FUNCTION public.get_user_dentist_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_user_dentist_id() TO authenticated;

-- "My booking": the caller's linked dentist is the booking's dentist, or one of its booking_dentists, and the booking
-- is in the caller's org. One place for the rule (bookings, treatment_notes, consultations, storage, outreach).
CREATE OR REPLACE FUNCTION public.is_my_booking(p_booking uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = public
    AS $$
  SELECT public.get_user_dentist_id() IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.bookings bk
       WHERE bk.id = p_booking
         AND public.branch_in_my_org(bk.branch_id)
         AND (bk.dentist_id = public.get_user_dentist_id()
              OR EXISTS (SELECT 1 FROM public.booking_dentists bd
                         WHERE bd.booking_id = bk.id AND bd.dentist_id = public.get_user_dentist_id()))
     );
$$;
REVOKE ALL ON FUNCTION public.is_my_booking(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_my_booking(uuid) TO authenticated;

-- Same rule as is_my_booking(), but for the NEW row of an UPDATE: takes the row's dentist_id as it would be after the
-- update, so a booking cannot be handed to another dentist. A SECURITY DEFINER function (not an inline subquery) because
-- booking_dentists' own read policy points back at bookings, which would make the policy recurse (42P17).
CREATE OR REPLACE FUNCTION public.is_my_booking_row(p_booking uuid, p_dentist uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = public
    AS $$
  SELECT public.get_user_dentist_id() IS NOT NULL
     AND (p_dentist = public.get_user_dentist_id()
          OR EXISTS (SELECT 1 FROM public.booking_dentists bd
                     WHERE bd.booking_id = p_booking AND bd.dentist_id = public.get_user_dentist_id()));
$$;
REVOKE ALL ON FUNCTION public.is_my_booking_row(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_my_booking_row(uuid, uuid) TO authenticated;

-- set_user_access: admin-only way to set a login's access level and practitioner link (no UI in this ticket).
CREATE OR REPLACE FUNCTION public.set_user_access(p_user_id uuid, p_role public.user_role, p_dentist_id uuid)
    RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = public
    AS $fn$
DECLARE
  v_org uuid;
BEGIN
  IF auth.uid() IS NULL OR public.get_user_role()::text IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'set_user_access: admin role required';
  END IF;

  SELECT org_id INTO v_org FROM public.users WHERE id = p_user_id;
  IF v_org IS NULL OR v_org IS DISTINCT FROM public.get_user_org_id() THEN
    RAISE EXCEPTION 'set_user_access: user not found in your organization';
  END IF;

  IF p_dentist_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.dentists WHERE id = p_dentist_id AND org_id = v_org) THEN
    RAISE EXCEPTION 'set_user_access: dentist not found in your organization';
  END IF;

  IF p_role IS NULL THEN
    RAISE EXCEPTION 'set_user_access: role is required';
  END IF;

  UPDATE public.users SET role = p_role, dentist_id = p_dentist_id WHERE id = p_user_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.set_user_access(uuid, public.user_role, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_user_access(uuid, public.user_role, uuid) TO authenticated;

-- 4. RLS (policy table approved by the lead 2026-11-22) ----------------------------------------------------------------

-- 4a. Money tables: practitioner gets nothing (read or write).
CREATE POLICY practitioner_no_payments ON public.payments AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner')
  WITH CHECK (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_payment_refunds ON public.payment_refunds AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner')
  WITH CHECK (public.get_user_role()::text IS DISTINCT FROM 'practitioner');

-- 4b. Role-free org reads of money / marketing config: practitioner cannot read them.
CREATE POLICY practitioner_no_memberships ON public.memberships AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_membership_transactions ON public.membership_transactions AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_vouchers ON public.vouchers AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_voucher_claims ON public.voucher_claims AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_voucher_types ON public.voucher_types AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_membership_tiers ON public.membership_tiers AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_reward_catalog ON public.reward_catalog AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_outreach_rules ON public.outreach_rules AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_outreach_templates ON public.outreach_templates AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');

-- Found while testing (not in the first policy table): these also have role-free reads of money data.
-- daily_reports: the two "Manager can read ... daily reports" SELECT policies check branch/org only (admin OR branch).
CREATE POLICY practitioner_no_daily_reports ON public.daily_reports AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_customer_referrals ON public.customer_referrals AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_customer_referral_credits ON public.customer_referral_credits AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_customer_referral_debits ON public.customer_referral_debits AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');

-- 4c. Bookings: read inherits. Practitioner cannot create or delete; may UPDATE only their own bookings and must
-- keep them theirs (WITH CHECK reads the NEW row's columns, so they cannot hand a booking to another dentist).
-- RLS cannot limit WHICH columns change; status-only comes with the action layer (CMD-78).
CREATE POLICY practitioner_no_booking_insert ON public.bookings AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_booking_delete ON public.bookings AS RESTRICTIVE FOR DELETE TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_own_booking_update ON public.bookings AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner' OR public.is_my_booking(id))
  WITH CHECK (
    public.get_user_role()::text IS DISTINCT FROM 'practitioner'
    OR public.is_my_booking_row(id, dentist_id)
  );

-- booking_dentists decides who counts as "my booking", so a practitioner must not edit it (front desk assigns).
CREATE POLICY practitioner_no_booking_dentists_write ON public.booking_dentists AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_booking_dentists_update ON public.booking_dentists AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner')
  WITH CHECK (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_booking_dentists_delete ON public.booking_dentists AS RESTRICTIVE FOR DELETE TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');

-- 4d. Customers (patients): practitioner may read and UPDATE (medical alerts/allergies, CMD-56); no INSERT/DELETE.
CREATE POLICY practitioner_no_customer_insert ON public.customers AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (public.get_user_role()::text IS DISTINCT FROM 'practitioner');
CREATE POLICY practitioner_no_customer_delete ON public.customers AS RESTRICTIVE FOR DELETE TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner');

-- 4e. Treatment notes: read inherits; write only on their own bookings.
CREATE POLICY practitioner_own_treatment_note_insert ON public.treatment_notes AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (public.get_user_role()::text IS DISTINCT FROM 'practitioner' OR public.is_my_booking(booking_id));
CREATE POLICY practitioner_own_treatment_note_update ON public.treatment_notes AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'practitioner' OR public.is_my_booking(booking_id))
  WITH CHECK (public.get_user_role()::text IS DISTINCT FROM 'practitioner' OR public.is_my_booking(booking_id));

-- 4f. Consultations and their files: the existing write policies list ('staff','manager','admin'), which excludes
-- practitioner, so ADD permissive write policies for practitioner on their own bookings only.
-- can_access_consultation_booking() is left as it is (reads use it).
CREATE POLICY "Practitioner can create own consultations" ON public.consultations FOR INSERT TO authenticated
  WITH CHECK (
    public.get_user_role()::text = 'practitioner'
    AND org_id = public.get_user_org_id()
    AND public.is_my_booking(booking_id)
    AND public.can_access_consultation_booking(booking_id)
    AND public.consultation_refs_ok(org_id, branch_id, customer_id, dentist_id)
  );
CREATE POLICY "Practitioner can update own consultations" ON public.consultations FOR UPDATE TO authenticated
  USING (public.get_user_role()::text = 'practitioner' AND org_id = public.get_user_org_id()
         AND public.is_my_booking(booking_id) AND public.can_access_consultation_booking(booking_id))
  WITH CHECK (
    public.get_user_role()::text = 'practitioner'
    AND org_id = public.get_user_org_id()
    AND public.is_my_booking(booking_id)
    AND public.can_access_consultation_booking(booking_id)
    AND public.consultation_refs_ok(org_id, branch_id, customer_id, dentist_id)
  );

CREATE POLICY "Practitioner upload own consultation files" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id IN ('consultation-audio', 'consultation-images')
              AND (storage.foldername(name))[1] = public.get_user_org_id()::text
              AND public.get_user_role()::text = 'practitioner'
              AND public.is_my_booking(public.consultation_object_booking(name))
              AND public.can_access_consultation_booking(public.consultation_object_booking(name)));
CREATE POLICY "Practitioner delete own consultation files" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id IN ('consultation-audio', 'consultation-images')
         AND (storage.foldername(name))[1] = public.get_user_org_id()::text
         AND public.get_user_role()::text = 'practitioner'
         AND public.is_my_booking(public.consultation_object_booking(name))
         AND public.can_access_consultation_booking(public.consultation_object_booking(name)));

-- 5. outreach_enqueue_for_completed: a practitioner completing THEIR OWN visit triggers the same follow-up as front
-- desk. Body is migration 009's, with only the role check changed (practitioner allowed, own booking only).
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
          OR (public.get_user_role()::text NOT IN ('staff', 'manager', 'admin', 'practitioner'))
          OR (public.get_user_role()::text = 'practitioner' AND NOT public.is_my_booking(p_booking_id))
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

COMMIT;
