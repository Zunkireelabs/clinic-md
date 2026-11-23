-- migration-019-rollback.sql (CMD-100): undoes migration-019. Run on LOCAL first; never run it on production without a rehearsal (CMD-11).
--
-- ERASED PATIENTS CANNOT BE RESTORED. If any patient was erased (patient_erasures has rows) this script stops, unless you first run
-- SET clinicmd.allow_rollback_after_erase = 'yes' in the same session (the erased personal data stays gone; only the structure is removed).
-- Merged patients stay merged (their rows are gone either way; the number redirects are dropped).
-- Also stops if any family members share a phone number: the old one-phone-per-organization index cannot be recreated over them.
-- Lost on rollback: alerts, forms and their answers, families, patient numbers, the erase records, and the 019 audit rows stay in action_log.
-- Gone from the front-desk wall: front desk can read and write consultations, notes and consultation files again.

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.patient_erasures') IS NOT NULL AND EXISTS (SELECT 1 FROM public.patient_erasures)
     AND COALESCE(current_setting('clinicmd.allow_rollback_after_erase', true), '') <> 'yes' THEN
    RAISE EXCEPTION 'migration-019 rollback: patients were erased; erased data cannot be restored. Set clinicmd.allow_rollback_after_erase = ''yes'' to continue anyway.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.customers
              WHERE NULLIF(regexp_replace(COALESCE(phone, ''), '\D', '', 'g'), '') IS NOT NULL
              GROUP BY org_id, NULLIF(regexp_replace(COALESCE(phone, ''), '\D', '', 'g'), '') HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'migration-019 rollback: some patients share a phone number (family members). Give each their own number first; see migration-019-preflight.sql section 4.';
  END IF;
END $$;

-- the wall
DROP POLICY IF EXISTS frontdesk_no_clinical_notes ON public.treatment_notes;
DROP POLICY IF EXISTS frontdesk_no_consultations ON public.consultations;
DROP POLICY IF EXISTS frontdesk_no_consultation_files ON storage.objects;
DROP POLICY IF EXISTS "Owner reads erase requests" ON storage.objects;
DROP POLICY IF EXISTS "Owner uploads erase requests" ON storage.objects;
-- The erase-requests bucket stays (Supabase blocks deleting storage rows from SQL). Empty it and delete it in the Storage dashboard if wanted.

-- triggers
DROP TRIGGER IF EXISTS messages_block_inactive_patient ON public.messages;
DROP TRIGGER IF EXISTS customers_phone_family_guard ON public.customers;
DROP TRIGGER IF EXISTS customers_keep_patient_no ON public.customers;
DROP TRIGGER IF EXISTS customers_assign_patient_no ON public.customers;

-- functions that existed before 019, restored to their pre-019 definitions
DROP FUNCTION IF EXISTS public.find_customer_for_booking(uuid, text, text, text);

CREATE OR REPLACE FUNCTION public.find_customer_for_booking(p_org_id uuid, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text) RETURNS TABLE(id uuid, gender text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT c.id, c.gender
  FROM public.customers c
  WHERE c.org_id = p_org_id
    AND (
      (p_phone IS NOT NULL AND c.phone = p_phone)
      OR (p_email IS NOT NULL AND c.email = p_email)
    )
  ORDER BY (c.phone = p_phone) DESC NULLS LAST
  LIMIT 1;
$$;

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

CREATE OR REPLACE FUNCTION public.merge_customers(p_canonical_id uuid, p_duplicate_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_role       user_role;
  v_org_can    uuid;
  v_org_dup    uuid;
  v_dup_row    jsonb;
  v_nphone     text;
BEGIN
  IF p_canonical_id = p_duplicate_id THEN
    RAISE EXCEPTION 'merge_customers: canonical and duplicate are the same customer';
  END IF;

  v_role := get_user_role();
  IF v_role NOT IN ('manager', 'admin') THEN
    RAISE EXCEPTION 'merge_customers: requires manager or admin role';
  END IF;

  SELECT org_id INTO v_org_can FROM public.customers WHERE id = p_canonical_id;
  SELECT org_id INTO v_org_dup FROM public.customers WHERE id = p_duplicate_id;

  IF v_org_can IS NULL OR v_org_dup IS NULL THEN
    RAISE EXCEPTION 'merge_customers: canonical or duplicate customer not found';
  END IF;
  IF v_org_can <> v_org_dup THEN
    RAISE EXCEPTION 'merge_customers: canonical and duplicate belong to different orgs';
  END IF;
  IF v_org_can <> get_user_org_id() THEN
    RAISE EXCEPTION 'merge_customers: not authorized for this organization';
  END IF;

  -- Managers are branch-scoped elsewhere in the app; a manager may only merge customers
  -- touching their own branch. Admin merges across any branch in their org.
  IF v_role = 'manager' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.customers c
      WHERE c.id IN (p_canonical_id, p_duplicate_id) AND c.branch_id = get_user_branch_id()
    ) THEN
      RAISE EXCEPTION 'merge_customers: manager may only merge customers touching their own branch';
    END IF;
  END IF;

  SELECT to_jsonb(c) INTO v_dup_row FROM public.customers c WHERE c.id = p_duplicate_id;
  v_nphone := public.normalize_phone_e164((v_dup_row->>'phone'));

  -- Repoint every table that references customers.id. Order doesn't matter for FK
  -- validity (none of these reference each other), but outreach_messages is CASCADE —
  -- it MUST be repointed before the delete below, or its rows for the duplicate would be
  -- silently deleted instead of preserved.
  UPDATE public.bookings SET customer_id = p_canonical_id WHERE customer_id = p_duplicate_id;
  UPDATE public.customer_accounts SET customer_id = p_canonical_id WHERE customer_id = p_duplicate_id;
  UPDATE public.customer_referral_credits SET customer_id = p_canonical_id WHERE customer_id = p_duplicate_id;
  UPDATE public.customer_referral_debits SET customer_id = p_canonical_id WHERE customer_id = p_duplicate_id;
  UPDATE public.customer_referrals SET referring_customer_id = p_canonical_id WHERE referring_customer_id = p_duplicate_id;
  UPDATE public.customer_referrals SET referred_customer_id = p_canonical_id WHERE referred_customer_id = p_duplicate_id;
  UPDATE public.memberships SET customer_id = p_canonical_id WHERE customer_id = p_duplicate_id;
  UPDATE public.outreach_messages SET customer_id = p_canonical_id WHERE customer_id = p_duplicate_id;
  UPDATE public.vouchers SET customer_id = p_canonical_id WHERE customer_id = p_duplicate_id;

  -- Coalesce nullable fields onto the canonical row (extends migration-035's
  -- email/notes coalesce with gender and date_of_birth, which didn't exist in April).
  UPDATE public.customers can
     SET email         = COALESCE(can.email, dup.email),
         notes         = COALESCE(can.notes, dup.notes),
         gender        = COALESCE(can.gender, dup.gender),
         date_of_birth = COALESCE(can.date_of_birth, dup.date_of_birth)
    FROM public.customers dup
   WHERE can.id = p_canonical_id AND dup.id = p_duplicate_id;

  -- Snapshot before delete.
  INSERT INTO public.customer_merge_log (merged_id, canonical_id, org_id, nphone, merged_row)
  VALUES (p_duplicate_id, p_canonical_id, v_org_dup, v_nphone, v_dup_row);

  DELETE FROM public.customers WHERE id = p_duplicate_id;

  IF EXISTS (SELECT 1 FROM public.customers WHERE id = p_duplicate_id) THEN
    RAISE EXCEPTION 'merge_customers: duplicate row % still present after delete', p_duplicate_id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_duplicate_candidates(p_org_id uuid) RETURNS TABLE(customer_id_a uuid, customer_id_b uuid, nphone text, name_a text, name_b text, phone_a text, phone_b text, email_a text, email_b text, branch_id_a uuid, branch_id_b uuid, created_at_a timestamp with time zone, created_at_b timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF p_org_id <> get_user_org_id() THEN
    RAISE EXCEPTION 'customer_duplicate_candidates: not authorized for this organization';
  END IF;
  IF get_user_role() NOT IN ('manager', 'admin') THEN
    RAISE EXCEPTION 'customer_duplicate_candidates: requires manager or admin role';
  END IF;

  -- Column aliases below are prefixed (v_nphone, not nphone) to avoid ambiguity against
  -- this function's own RETURNS TABLE column of the same name, which plpgsql exposes as an
  -- implicit variable in scope for the whole function body.
  RETURN QUERY
  WITH norm AS (
    SELECT c.id, c.org_id, c.full_name, c.phone, c.email, c.branch_id, c.created_at,
           public.normalize_phone_e164(c.phone) AS v_nphone
    FROM public.customers c
    WHERE c.org_id = p_org_id
  ),
  grp AS (
    SELECT v_nphone, array_agg(id ORDER BY created_at, id) AS ids
    FROM norm
    WHERE v_nphone IS NOT NULL
    GROUP BY v_nphone
    HAVING count(*) > 1
  ),
  pairs AS (
    -- All groups found so far are exact pairs (verified against production), but generate
    -- every combination within a group so a future 3+ group doesn't get silently dropped.
    SELECT g.v_nphone, a.id AS id_a, b.id AS id_b
    FROM grp g,
         LATERAL unnest(g.ids) WITH ORDINALITY AS a(id, ord_a),
         LATERAL unnest(g.ids) WITH ORDINALITY AS b(id, ord_b)
    WHERE a.ord_a < b.ord_b
  )
  SELECT p.id_a, p.id_b, p.v_nphone,
         na.full_name, nb.full_name,
         na.phone, nb.phone,
         na.email, nb.email,
         na.branch_id, nb.branch_id,
         na.created_at, nb.created_at
  FROM pairs p
  JOIN norm na ON na.id = p.id_a
  JOIN norm nb ON nb.id = p.id_b
  WHERE NOT EXISTS (
    SELECT 1 FROM public.customer_duplicate_dismissals d
    WHERE d.org_id = p_org_id
      AND d.customer_id_lo = LEAST(p.id_a, p.id_b)
      AND d.customer_id_hi = GREATEST(p.id_a, p.id_b)
  );
END;
$$;


-- functions added by 019
DROP FUNCTION IF EXISTS public.public_submit_form(text, jsonb, text);
DROP FUNCTION IF EXISTS public.public_get_form(text);
DROP FUNCTION IF EXISTS public.patient_needs_attention(uuid);
DROP FUNCTION IF EXISTS public.patient_lookup(integer);
DROP FUNCTION IF EXISTS public.list_patients(uuid, text, text, integer, integer, boolean);
DROP FUNCTION IF EXISTS public.act_duplicates_link_family(uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_duplicates_dismiss(uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_duplicates_merge(uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public._merge_customer_rows(uuid, uuid, uuid);
DROP FUNCTION IF EXISTS public.act_patient_erase(uuid, text, text, jsonb);
DROP FUNCTION IF EXISTS public.act_patient_restore(uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_patient_archive(uuid, text, jsonb);
DROP FUNCTION IF EXISTS public.act_patient_undo(uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_consent_marketing_yes(uuid, text, text, text, jsonb);
DROP FUNCTION IF EXISTS public.act_form_record_typed(uuid, uuid, jsonb, jsonb);
DROP FUNCTION IF EXISTS public.act_form_start_on_device(uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_form_send_link(uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public._pt_alerts_from_answers(uuid, uuid, jsonb, jsonb);
DROP FUNCTION IF EXISTS public._pt_form_start(text, text, uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_family_set_contact(uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_family_unlink(uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_family_link(uuid, uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_alert_remove(uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_alert_update(uuid, jsonb, jsonb);
DROP FUNCTION IF EXISTS public.act_alert_confirm(uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_alert_add(uuid, text, text, text, text, jsonb);
DROP FUNCTION IF EXISTS public.act_patient_update(uuid, jsonb, jsonb);
DROP FUNCTION IF EXISTS public.act_patient_create(jsonb, uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public._pt_label(integer);
DROP FUNCTION IF EXISTS public._pt_err(jsonb);
DROP FUNCTION IF EXISTS public._pt_branch(jsonb);
DROP FUNCTION IF EXISTS public._pt_ok(jsonb, text[]);
DROP FUNCTION IF EXISTS public.patient_clinical_index(uuid);
DROP FUNCTION IF EXISTS public.patient_message_target(uuid);
DROP FUNCTION IF EXISTS public._pick_customer_for_booking(uuid, text, text, text);
DROP FUNCTION IF EXISTS public._norm_name(text);
DROP FUNCTION IF EXISTS public._messages_block_inactive_patient();
DROP FUNCTION IF EXISTS public._customers_phone_family_guard();
DROP FUNCTION IF EXISTS public._customers_keep_patient_no();
DROP FUNCTION IF EXISTS public._customers_assign_patient_no();

-- tables
DROP TABLE IF EXISTS public.patient_redirects;
DROP TABLE IF EXISTS public.patient_erasures;
DROP TABLE IF EXISTS public.form_submissions;
DROP TABLE IF EXISTS public.form_templates;
DROP TABLE IF EXISTS public.patient_alerts;

-- the phone rule as it was
DROP INDEX IF EXISTS public.customers_org_nphone_lookup;
DROP INDEX IF EXISTS public.customers_org_nphone_uniq;
ALTER TABLE public.customers
  DROP COLUMN IF EXISTS erase_request_path, DROP COLUMN IF EXISTS erased_by, DROP COLUMN IF EXISTS erased_at,
  DROP COLUMN IF EXISTS archive_reason, DROP COLUMN IF EXISTS archived_by, DROP COLUMN IF EXISTS archived_at, DROP COLUMN IF EXISTS family_id,
  DROP COLUMN IF EXISTS dob_bs, DROP COLUMN IF EXISTS emergency_contact_phone, DROP COLUMN IF EXISTS emergency_contact_name, DROP COLUMN IF EXISTS found_us,
  DROP COLUMN IF EXISTS address, DROP COLUMN IF EXISTS preferred_channel, DROP COLUMN IF EXISTS language, DROP COLUMN IF EXISTS full_name_ne,
  DROP COLUMN IF EXISTS old_file_no, DROP COLUMN IF EXISTS patient_no;
DROP TABLE IF EXISTS public.families;
DROP TABLE IF EXISTS public.patient_counters;
CREATE UNIQUE INDEX customers_org_nphone_uniq ON public.customers USING btree (org_id, NULLIF(regexp_replace(COALESCE(phone, ''::text), '\D'::text, ''::text, 'g'::text), ''::text)) WHERE (NULLIF(regexp_replace(COALESCE(phone, ''::text), '\D'::text, ''::text, 'g'::text), ''::text) IS NOT NULL);

COMMIT;
