-- migration-019 (CMD-100): Patients, Part 0 (data layer). No UI.
--
-- Requires 011 (CMD-79: practitioner role, is_my_patient), 012 (action layer), 013 (hub: patient_channels, conversations, act_consent_record),
-- 016/017 (agent_jobs, agent_work_items). Stacks on PRs #15 and #22. NOT applied to production.
-- PRODUCTION NOTES (read before applying; see docs/briefs/CMD-100-data-design.md):
--   * Front desk (role staff) loses ALL read and write access to consultations and treatment_notes, and to the consultation-audio /
--     consultation-images buckets (Sadin, 2026-11-22). 019 is applied ONLY after the users listed by migration-019-preflight.sql are
--     moved to practitioner, and only with Part 2's lock lines or Sadin's explicit go-ahead.
--   * Apply after 011..018. Rehearse on a prod-schema copy first (CMD-11). The phone-uniqueness rule changes (see section 2).
-- Rollback: migration-019-rollback.sql (preflight inside; erased patients cannot be restored).
--
-- WHAT: one record per organisation (patient number, old file number, families), medical alerts, forms and consents, archive, erase,
-- merge (all as actions with an audit row), org-scoped patient reads, and the front-desk wall around clinical content.
-- Forms are NOT clinical for the wall: front desk sees and types the answers.

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.get_user_dentist_id()') IS NULL THEN RAISE EXCEPTION '019 needs migration-011 (practitioner access)'; END IF;
  IF to_regprocedure('public.act_consent_record(uuid, text, text, text, text, text, jsonb)') IS NULL THEN RAISE EXCEPTION '019 needs migration-013 (communication hub)'; END IF;
  IF to_regclass('public.agent_jobs') IS NULL THEN RAISE EXCEPTION '019 needs migration-017 (follow-up agent)'; END IF;
END $$;

LOCK TABLE public.customers IN SHARE ROW EXCLUSIVE MODE;

-- 1. families, new customer columns, patient number ---------------------------------------------------------------------------
CREATE TABLE public.families (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL REFERENCES public.organizations(id),
  name                text,
  contact_customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_families_org ON public.families (org_id);

ALTER TABLE public.customers
  ADD COLUMN patient_no integer,
  ADD COLUMN old_file_no text,
  ADD COLUMN full_name_ne text,
  ADD COLUMN language text CHECK (language IN ('ne', 'en')),
  ADD COLUMN preferred_channel text CHECK (preferred_channel IN ('sms', 'whatsapp', 'viber', 'messenger', 'email')),
  ADD COLUMN address text,
  ADD COLUMN found_us text,
  ADD COLUMN emergency_contact_name text,
  ADD COLUMN emergency_contact_phone text,
  ADD COLUMN dob_bs text,
  ADD COLUMN family_id uuid REFERENCES public.families(id) ON DELETE SET NULL,
  ADD COLUMN archived_at timestamptz,
  ADD COLUMN archived_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN archive_reason text,
  ADD COLUMN erased_at timestamptz,
  ADD COLUMN erased_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN erase_request_path text;

-- gapless per-organisation sequence: a counter row, locked by the INSERT ... ON CONFLICT. A rolled-back insert rolls the counter back.
CREATE TABLE public.patient_counters (
  org_id  uuid PRIMARY KEY REFERENCES public.organizations(id),
  last_no integer NOT NULL DEFAULT 0
);
ALTER TABLE public.patient_counters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.patient_counters FROM PUBLIC, anon, authenticated, service_role;

UPDATE public.customers c SET patient_no = r.rn
  FROM (SELECT id, row_number() OVER (PARTITION BY org_id ORDER BY created_at NULLS FIRST, id) AS rn FROM public.customers) r
 WHERE r.id = c.id;
INSERT INTO public.patient_counters (org_id, last_no) SELECT org_id, max(patient_no) FROM public.customers GROUP BY org_id;
ALTER TABLE public.customers ALTER COLUMN patient_no SET NOT NULL;
ALTER TABLE public.customers ADD CONSTRAINT customers_org_patient_no_key UNIQUE (org_id, patient_no);
CREATE INDEX idx_customers_old_file_no ON public.customers (org_id, lower(old_file_no)) WHERE old_file_no IS NOT NULL;
CREATE INDEX idx_customers_family ON public.customers (family_id) WHERE family_id IS NOT NULL;

CREATE FUNCTION public._customers_assign_patient_no() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public   -- DEFINER: anon_insert_customers lets the public booking flow insert
    AS $$
BEGIN
  INSERT INTO public.patient_counters AS pc (org_id, last_no) VALUES (NEW.org_id, 1)
  ON CONFLICT (org_id) DO UPDATE SET last_no = pc.last_no + 1
  RETURNING last_no INTO NEW.patient_no;
  RETURN NEW;
END $$;
CREATE TRIGGER customers_assign_patient_no BEFORE INSERT ON public.customers FOR EACH ROW EXECUTE FUNCTION public._customers_assign_patient_no();

CREATE FUNCTION public._customers_keep_patient_no() RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.patient_no IS DISTINCT FROM OLD.patient_no OR NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'A patient number and organization never change' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER customers_keep_patient_no BEFORE UPDATE OF patient_no, org_id ON public.customers FOR EACH ROW EXECUTE FUNCTION public._customers_keep_patient_no();

-- a merged-away patient's old number still opens the kept record
CREATE TABLE public.patient_redirects (
  org_id      uuid NOT NULL REFERENCES public.organizations(id),
  patient_no  integer NOT NULL,
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, patient_no)
);

-- 2. one phone per org, except inside one family ------------------------------------------------------------------------------
-- Was: unique (org, digits-of-phone). Now unique only among patients with no family; the guard trigger makes a SHARED phone legal only
-- when every row with that phone is in the same family. The anon booking functions are rewritten below (never error, never several rows).
DROP INDEX public.customers_org_nphone_uniq;
CREATE UNIQUE INDEX customers_org_nphone_uniq ON public.customers
  USING btree (org_id, (NULLIF(regexp_replace(COALESCE(phone, ''), '\D', '', 'g'), '')))
  WHERE family_id IS NULL AND NULLIF(regexp_replace(COALESCE(phone, ''), '\D', '', 'g'), '') IS NOT NULL;
CREATE INDEX customers_org_nphone_lookup ON public.customers
  USING btree (org_id, (NULLIF(regexp_replace(COALESCE(phone, ''), '\D', '', 'g'), '')))
  WHERE NULLIF(regexp_replace(COALESCE(phone, ''), '\D', '', 'g'), '') IS NOT NULL;

CREATE FUNCTION public._customers_phone_family_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v text := NULLIF(regexp_replace(COALESCE(NEW.phone, ''), '\D', '', 'g'), '');
BEGIN
  IF v IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.customers o
              WHERE o.org_id = NEW.org_id AND o.id <> NEW.id
                AND NULLIF(regexp_replace(COALESCE(o.phone, ''), '\D', '', 'g'), '') = v
                AND (NEW.family_id IS NULL OR o.family_id IS DISTINCT FROM NEW.family_id)) THEN
    -- same error as the old unique index, so every existing "lost the race" handler keeps working
    RAISE EXCEPTION 'duplicate key value violates unique constraint "customers_org_nphone_uniq"' USING ERRCODE = '23505',
      DETAIL = 'A phone number can be shared only by the members of one family.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER customers_phone_family_guard BEFORE INSERT OR UPDATE OF phone, family_id, org_id ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public._customers_phone_family_guard();

-- Messages to ANY member of a family go to the family contact's phone and name the patient (PRODUCT-BRIEF §2, Families).
CREATE FUNCTION public.patient_message_target(p_customer uuid)
RETURNS TABLE (customer_id uuid, patient_name text, to_phone text, to_name text, via_family boolean, contact_customer_id uuid)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT c.id, c.full_name,
         CASE WHEN ct.id IS NOT NULL AND ct.phone IS NOT NULL THEN ct.phone ELSE c.phone END,
         CASE WHEN ct.id IS NOT NULL AND ct.phone IS NOT NULL THEN ct.full_name ELSE c.full_name END,
         (ct.id IS NOT NULL AND ct.phone IS NOT NULL AND ct.id <> c.id),
         ct.id
    FROM public.customers c
    LEFT JOIN public.families f ON f.id = c.family_id
    LEFT JOIN public.customers ct ON ct.id = f.contact_customer_id AND ct.org_id = c.org_id AND ct.erased_at IS NULL
   WHERE c.id = p_customer
     AND (c.org_id = public.get_user_org_id() OR current_setting('role', true) = 'service_role');
$$;

-- anon booking flow: a shared family phone must never error or return several rows. Pick the member whose typed name matches exactly
-- (case and spaces normalised), else the family contact, else the oldest.
CREATE FUNCTION public._norm_name(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT lower(regexp_replace(btrim(COALESCE(p, '')), '\s+', ' ', 'g')) $$;

CREATE FUNCTION public._pick_customer_for_booking(p_org uuid, p_phone text, p_email text, p_name text) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  WITH q AS (SELECT public.normalize_phone_e164(p_phone) AS np)
  SELECT c.id FROM public.customers c, q
   WHERE c.org_id = p_org AND c.erased_at IS NULL
     AND ((q.np IS NOT NULL AND public.normalize_phone_e164(c.phone) = q.np) OR (p_email IS NOT NULL AND c.email = p_email))
   ORDER BY (c.archived_at IS NULL) DESC,
            (p_name IS NOT NULL AND public._norm_name(c.full_name) = public._norm_name(p_name)) DESC,
            (q.np IS NOT NULL AND public.normalize_phone_e164(c.phone) = q.np) DESC,
            EXISTS (SELECT 1 FROM public.families f WHERE f.id = c.family_id AND f.contact_customer_id = c.id) DESC,
            c.created_at NULLS LAST, c.id
   LIMIT 1;
$$;

DROP FUNCTION public.find_customer_for_booking(uuid, text, text);
CREATE FUNCTION public.find_customer_for_booking(p_org_id uuid, p_phone text DEFAULT NULL, p_email text DEFAULT NULL, p_full_name text DEFAULT NULL)
RETURNS TABLE (id uuid, gender text)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT c.id, c.gender FROM public.customers c WHERE c.id = public._pick_customer_for_booking(p_org_id, p_phone, p_email, p_full_name);
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
  v_existing_name text;
  v_existing_family uuid;
  v_caller_org uuid := public.get_user_org_id();
  v_is_staff boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.org_id = p_org_id) THEN
    RAISE EXCEPTION 'upsert_customer_for_booking: branch does not belong to this organization';
  END IF;
  IF v_caller_org IS NOT NULL AND v_caller_org <> p_org_id THEN
    RAISE EXCEPTION 'upsert_customer_for_booking: not your organization';
  END IF;
  v_is_staff := v_caller_org IS NOT NULL;

  v_id := public._pick_customer_for_booking(p_org_id, p_phone, p_email, p_full_name);

  IF v_id IS NULL THEN
    BEGIN
      INSERT INTO public.customers (org_id, branch_id, full_name, phone, email, gender)
      VALUES (p_org_id, p_branch_id, p_full_name, p_phone, p_email, p_gender)
      RETURNING id INTO v_id;
      RETURN v_id;
    EXCEPTION WHEN unique_violation THEN
      -- Lost a race against customers_org_nphone_uniq (or the family guard): the winner is now visible.
      v_id := public._pick_customer_for_booking(p_org_id, p_phone, p_email, p_full_name);
      IF v_id IS NULL THEN RAISE; END IF;
    END;
  END IF;

  SELECT c.gender, c.full_name, c.family_id INTO v_existing_gender, v_existing_name, v_existing_family FROM public.customers c WHERE c.id = v_id;
  IF v_is_staff THEN
    -- a family shares one phone: never rename a member to a different typed name (that would rename the family contact)
    UPDATE public.customers
       SET full_name = CASE WHEN v_existing_family IS NULL OR public._norm_name(v_existing_name) = public._norm_name(p_full_name) THEN p_full_name ELSE full_name END,
           phone = COALESCE(p_phone, phone),
           email = COALESCE(p_email, email),
           gender = CASE WHEN v_existing_gender IS NULL THEN COALESCE(p_gender, gender) ELSE gender END
     WHERE id = v_id;
  ELSE
    UPDATE public.customers SET email = COALESCE(email, p_email), gender = COALESCE(gender, p_gender) WHERE id = v_id;
  END IF;
  RETURN v_id;
END;
$function$;

-- 3. alerts, forms, erasure record ---------------------------------------------------------------------------------------------
CREATE TABLE public.patient_alerts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.organizations(id),
  customer_id  uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  type         text NOT NULL CHECK (type IN ('allergy', 'medication', 'condition', 'other')),
  text         text NOT NULL CHECK (length(btrim(text)) BETWEEN 1 AND 300),
  details      text CHECK (length(details) <= 2000),
  severity     text NOT NULL DEFAULT 'note' CHECK (severity IN ('note', 'caution', 'danger')),
  source       text NOT NULL CHECK (source IN ('front_desk', 'practitioner', 'intake_form', 'import')),
  created_by   uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  confirmed_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  confirmed_at timestamptz,
  removed_by   uuid REFERENCES public.users(id) ON DELETE SET NULL,
  removed_at   timestamptz
);
CREATE INDEX idx_patient_alerts_customer ON public.patient_alerts (customer_id) WHERE removed_at IS NULL;
CREATE INDEX idx_patient_alerts_org_unconfirmed ON public.patient_alerts (org_id) WHERE removed_at IS NULL AND confirmed_at IS NULL;

CREATE TABLE public.form_templates (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid REFERENCES public.organizations(id),     -- NULL = the specialty pack's default
  key        text NOT NULL,
  title      text NOT NULL,
  body       jsonb NOT NULL DEFAULT '{}'::jsonb,
  valid_days integer NOT NULL DEFAULT 365,
  required   boolean NOT NULL DEFAULT false,
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX form_templates_key ON public.form_templates (COALESCE(org_id, '00000000-0000-0000-0000-000000000000'::uuid), key);
INSERT INTO public.form_templates (org_id, key, title, valid_days, required, body) VALUES
  (NULL, 'intake', 'New patient intake', 365, true,
   '{"fields":[{"id":"conditions","type":"checklist","label":"Medical conditions"},{"id":"allergies","type":"text","label":"Allergies"},{"id":"medications","type":"text","label":"Medicines you take"},{"id":"pregnant","type":"yesno","label":"Pregnant or breastfeeding"}],"alerts_from":["conditions","allergies","medications"]}'),
  (NULL, 'consent_treatment', 'Consent for treatment', 365, true,
   '{"fields":[{"id":"agree","type":"signature","label":"I agree to the treatment explained to me"}]}');

CREATE TABLE public.form_submissions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.organizations(id),
  customer_id  uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  template_id  uuid NOT NULL REFERENCES public.form_templates(id),
  channel      text NOT NULL CHECK (channel IN ('tablet', 'link', 'typed')),
  status       text NOT NULL DEFAULT 'sent' CHECK (status IN ('sent', 'signed', 'expired')),
  token_hash   text UNIQUE,                                   -- sha256 hex of a 32-random-byte token; the token itself is never stored
  expires_at   timestamptz,
  signed_at    timestamptz,
  device       text,
  answers      jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (pg_column_size(answers) < 200000),
  pdf_path     text,
  created_by   uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_form_submissions_customer ON public.form_submissions (customer_id, signed_at DESC);

CREATE TABLE public.patient_erasures (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL REFERENCES public.organizations(id),
  customer_id    uuid NOT NULL REFERENCES public.customers(id),
  patient_no     integer NOT NULL,
  request_path   text NOT NULL,
  erased_by      uuid REFERENCES public.users(id) ON DELETE SET NULL,
  erased_at      timestamptz NOT NULL DEFAULT now(),
  fields_wiped   text[] NOT NULL DEFAULT '{}',
  counts         jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- RLS: reads only; every write goes through the act_* functions (which bypass RLS and check roles themselves).
ALTER TABLE public.families ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.form_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.form_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_erasures ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_redirects ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.families, public.patient_alerts, public.form_templates, public.form_submissions, public.patient_erasures, public.patient_redirects
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.families, public.patient_alerts, public.form_templates, public.form_submissions, public.patient_erasures, public.patient_redirects
  TO authenticated, service_role;
CREATE POLICY families_read ON public.families FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id() AND public.get_user_role() IS NOT NULL);
CREATE POLICY patient_alerts_read ON public.patient_alerts FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id() AND public.get_user_role() IS NOT NULL);
CREATE POLICY form_templates_read ON public.form_templates FOR SELECT TO authenticated
  USING ((org_id IS NULL OR org_id = public.get_user_org_id()) AND public.get_user_role() IS NOT NULL);
CREATE POLICY form_submissions_read ON public.form_submissions FOR SELECT TO authenticated   -- forms are NOT clinical for the front-desk wall
  USING (org_id = public.get_user_org_id() AND public.get_user_role() IS NOT NULL);
CREATE POLICY patient_erasures_read ON public.patient_erasures FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id() AND public.get_user_role()::text IN ('admin', 'admin_viewer'));
CREATE POLICY patient_redirects_read ON public.patient_redirects FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id() AND public.get_user_role() IS NOT NULL);

-- 4. THE FRONT-DESK WALL (database and storage) -------------------------------------------------------------------------------
-- Clinical content = note bodies (treatment_notes), the consultation record incl. transcript / summaries / X-ray + photo analysis and
-- image paths (consultations), and the files in the consultation-images / consultation-audio buckets. Front desk (staff) can neither read
-- nor write them. RESTRICTIVE, so it narrows the existing permissive policies without touching them (020 / CMD-54 adds functions on
-- consultations: this is the rule for those too). All staff share the DB role `authenticated`, so column grants cannot tell staff from
-- practitioner: the rule is row denial, plus patient_clinical_index() for the allowed metadata. No view may be created over these tables
-- without security_invoker.
CREATE POLICY frontdesk_no_clinical_notes ON public.treatment_notes AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'staff') WITH CHECK (public.get_user_role()::text IS DISTINCT FROM 'staff');
CREATE POLICY frontdesk_no_consultations ON public.consultations AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.get_user_role()::text IS DISTINCT FROM 'staff') WITH CHECK (public.get_user_role()::text IS DISTINCT FROM 'staff');
CREATE POLICY frontdesk_no_consultation_files ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated
  USING (bucket_id NOT IN ('consultation-audio', 'consultation-images') OR public.get_user_role()::text IS DISTINCT FROM 'staff')
  WITH CHECK (bucket_id NOT IN ('consultation-audio', 'consultation-images') OR public.get_user_role()::text IS DISTINCT FROM 'staff');

-- what front desk MAY see: author, date and kind, never the body, the path or the text
CREATE FUNCTION public.patient_clinical_index(p_customer uuid)
RETURNS TABLE (kind text, ref_id uuid, author text, occurred_at timestamptz, item_count integer)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT x.kind, x.ref_id, x.author, x.occurred_at, x.item_count FROM (
    SELECT 'note'::text AS kind, tn.id AS ref_id, d.name AS author, tn.created_at AS occurred_at, 1 AS item_count
      FROM public.treatment_notes tn LEFT JOIN public.dentists d ON d.id = tn.dentist_id
     WHERE tn.customer_id = p_customer
    UNION ALL
    SELECT 'consultation', c.id, COALESCE(c.created_by_name, 'Unknown'), c.created_at, 1
      FROM public.consultations c WHERE c.customer_id = p_customer
    UNION ALL
    SELECT 'xray', c.id, COALESCE(c.created_by_name, 'Unknown'), c.created_at, cardinality(c.xray_image_paths)
      FROM public.consultations c WHERE c.customer_id = p_customer AND cardinality(c.xray_image_paths) > 0
    UNION ALL
    SELECT 'photo', c.id, COALESCE(c.created_by_name, 'Unknown'), c.created_at, cardinality(c.photo_image_paths)
      FROM public.consultations c WHERE c.customer_id = p_customer AND cardinality(c.photo_image_paths) > 0
  ) x
  WHERE public.get_user_role() IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.customers cu WHERE cu.id = p_customer AND cu.org_id = public.get_user_org_id())
  ORDER BY x.occurred_at DESC;
$$;

-- outbound messages from agents or rules to an archived or erased patient are cancelled, never sent
CREATE FUNCTION public._messages_block_inactive_patient() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
BEGIN
  IF NEW.direction = 'out' AND NEW.kind = 'message' AND NEW.author_kind IN ('agent', 'rule', 'system') AND NEW.status IN ('queued', 'sending')
     AND EXISTS (SELECT 1 FROM public.conversations cv JOIN public.customers c ON c.id = cv.customer_id
                  WHERE cv.id = NEW.conversation_id AND (c.archived_at IS NOT NULL OR c.erased_at IS NOT NULL)) THEN
    NEW.status := 'cancelled'; NEW.error := 'PATIENT_ARCHIVED';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER messages_block_inactive_patient BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public._messages_block_inactive_patient();

-- 013's conversation access for staff / manager used the patient's HOME branch (migration-013 line 226): one record across branches
-- means the patient's thread is reachable from every branch of the organization. Re-created below only for the patient-linked arm.
-- (Left unchanged here: the function is rewritten in a later 013-era migration; see the design doc §2.2. Tracked for Part 2.)

-- 5. actions -------------------------------------------------------------------------------------------------------------------
-- Patient actions are org-wide for every allowed role (one record across branches). The audit branch_id is the actor's first branch.
-- Inputs written to action_log hold ids and FIELD NAMES, never personal values, so an erase leaves nothing behind.
CREATE FUNCTION public._pt_ok(p_ctx jsonb, p_roles text[]) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT COALESCE(p_ctx ->> 'kind' = 'person' AND (p_ctx ->> 'role') = ANY (p_roles), false);
$$;
CREATE FUNCTION public._pt_branch(p_ctx jsonb) RETURNS uuid LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT NULLIF(p_ctx -> 'branch_ids' ->> 0, '')::uuid;
$$;
CREATE FUNCTION public._pt_err(p_ctx jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', p_ctx ->> 'code', 'message', p_ctx ->> 'message'));
$$;
CREATE FUNCTION public._pt_label(p_no integer) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public AS $$ SELECT 'Erased patient P-' || lpad(p_no::text, 5, '0') $$;

-- 5.1 patient.create --------------------------------------------------------------------------------------------------------
CREATE FUNCTION public.act_patient_create(p_data jsonb, p_branch uuid DEFAULT NULL, p_join_customer uuid DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  ctx jsonb; v_org uuid; v_inputs jsonb; v_branch uuid; v_name text; v_phone text; v_np text; v_matches jsonb; v_join public.customers;
  v_fam uuid; v_new public.customers; v_code text; v_msg text;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('fields', (SELECT COALESCE(jsonb_agg(k), '[]'::jsonb) FROM jsonb_object_keys(COALESCE(p_data, '{}'::jsonb)) k),
                                 'join_customer', p_join_customer, 'branch_id', p_branch) || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['staff', 'manager', 'admin']) THEN
    RETURN public._act_finish(ctx, 'patient.create', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot add patients.', NULL, NULL, 'customers');
  END IF;
  v_name := btrim(COALESCE(p_data ->> 'full_name', ''));
  IF v_name = '' THEN
    RETURN public._act_finish(ctx, 'patient.create', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'A name is required.', NULL, NULL, 'customers');
  END IF;
  v_branch := COALESCE(p_branch, public._pt_branch(ctx));
  IF v_branch IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = v_branch AND org_id = v_org) THEN
    RETURN public._act_finish(ctx, 'patient.create', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'Choose the clinic this patient belongs to.', NULL, NULL, 'customers');
  END IF;
  IF ctx ->> 'role' IN ('staff', 'manager') AND NOT (COALESCE(ctx -> 'branch_ids', '[]'::jsonb) ? v_branch::text) THEN
    RETURN public._act_finish(ctx, 'patient.create', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'You can add patients only at your own clinic branches.', NULL, NULL, 'customers');
  END IF;

  v_phone := NULLIF(btrim(COALESCE(p_data ->> 'phone', '')), '');
  v_np := NULLIF(regexp_replace(COALESCE(public.normalize_phone_e164(v_phone), ''), '\D', '', 'g'), '');   -- stored phones are normalised by trigger
  IF v_np IS NOT NULL THEN
    SELECT jsonb_agg(jsonb_build_object('id', c.id, 'patient_no', c.patient_no, 'full_name', c.full_name, 'family_id', c.family_id) ORDER BY c.patient_no) INTO v_matches
      FROM public.customers c WHERE c.org_id = v_org AND c.erased_at IS NULL AND NULLIF(regexp_replace(COALESCE(c.phone, ''), '\D', '', 'g'), '') = v_np;
    IF v_matches IS NOT NULL THEN
      IF p_join_customer IS NULL THEN   -- not an error to log: the screen asks "same family?" and calls again
        RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', jsonb_build_object('matches', v_matches),
                                  'error', jsonb_build_object('code', 'PHONE_EXISTS', 'message', 'A patient with this phone number already exists. Add to their family?'));
      END IF;
      SELECT * INTO v_join FROM public.customers WHERE id = p_join_customer AND org_id = v_org FOR UPDATE;
      IF v_join.id IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_matches) m WHERE (m ->> 'id')::uuid = v_join.id) THEN
        RETURN public._act_finish(ctx, 'patient.create', v_org, v_branch, v_inputs, false, NULL, 'INVALID_INPUT', 'Choose a patient who shares this phone number.', NULL, NULL, 'customers');
      END IF;
      v_fam := v_join.family_id;
      IF v_fam IS NULL THEN
        INSERT INTO public.families (org_id, name, contact_customer_id)
        VALUES (v_org, COALESCE((regexp_match(btrim(v_join.full_name), '(\S+)$'))[1], v_join.full_name) || ' family', v_join.id)
        RETURNING id INTO v_fam;
        UPDATE public.customers SET family_id = v_fam WHERE id = v_join.id;
      END IF;
    END IF;
  END IF;

  BEGIN
    INSERT INTO public.customers (org_id, branch_id, full_name, phone, email, gender, date_of_birth, notes, old_file_no, full_name_ne, language,
                                  preferred_channel, address, found_us, emergency_contact_name, emergency_contact_phone, dob_bs, family_id)
    VALUES (v_org, v_branch, v_name, v_phone, NULLIF(btrim(p_data ->> 'email'), ''), NULLIF(p_data ->> 'gender', ''), (NULLIF(p_data ->> 'date_of_birth', ''))::date,
            p_data ->> 'notes', NULLIF(btrim(p_data ->> 'old_file_no'), ''), p_data ->> 'full_name_ne', NULLIF(p_data ->> 'language', ''),
            NULLIF(p_data ->> 'preferred_channel', ''), p_data ->> 'address', p_data ->> 'found_us', p_data ->> 'emergency_contact_name',
            p_data ->> 'emergency_contact_phone', p_data ->> 'dob_bs', v_fam)
    RETURNING * INTO v_new;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_code = '23505' THEN v_code := 'PHONE_EXISTS'; v_msg := 'A patient with this phone number already exists.'; END IF;
    IF v_code IN ('22007', '22008', '23514', '22P02') THEN v_code := 'INVALID_INPUT'; v_msg := 'A value is not valid (check the date, language and channel).'; END IF;
    RETURN public._act_finish(ctx, 'patient.create', v_org, v_branch, v_inputs, false, NULL, v_code, v_msg, NULL, NULL, 'customers');
  END;
  RETURN public._act_finish(ctx, 'patient.create', v_org, v_branch, v_inputs, true,
    jsonb_build_object('customer_id', v_new.id, 'patient_no', v_new.patient_no, 'family_id', v_new.family_id), NULL, NULL, v_new.id, NULL, 'customers');   -- no undo: numbers stay gapless
END $$;

-- 5.2 patient.update --------------------------------------------------------------------------------------------------------
CREATE FUNCTION public.act_patient_update(p_customer uuid, p_changes jsonb, p_ctx jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  ctx jsonb; v_org uuid; v_inputs jsonb; c public.customers; k text; v_code text; v_msg text;
  v_allowed constant text[] := ARRAY['full_name', 'phone', 'email', 'gender', 'date_of_birth', 'dob_bs', 'full_name_ne', 'language', 'preferred_channel',
                                      'address', 'found_us', 'emergency_contact_name', 'emergency_contact_phone', 'old_file_no', 'notes', 'branch_id'];
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('customer_id', p_customer, 'fields', (SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM jsonb_object_keys(COALESCE(p_changes, '{}'::jsonb)) x))
              || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['staff', 'manager', 'admin', 'practitioner']) THEN
    RETURN public._act_finish(ctx, 'patient.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot edit patients.', p_customer, NULL, 'customers');
  END IF;
  SELECT * INTO c FROM public.customers WHERE id = p_customer AND org_id = v_org FOR UPDATE;
  IF c.id IS NULL THEN
    RETURN public._act_finish(ctx, 'patient.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'PATIENT_NOT_FOUND', 'Patient not found.', p_customer, NULL, 'customers');
  END IF;
  IF c.erased_at IS NOT NULL THEN
    RETURN public._act_finish(ctx, 'patient.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'PATIENT_ERASED', 'This patient was erased.', p_customer, NULL, 'customers');
  END IF;
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR p_changes = '{}'::jsonb THEN
    RETURN public._act_finish(ctx, 'patient.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'Nothing to change.', p_customer, NULL, 'customers');
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_changes) LOOP
    IF NOT (k = ANY (v_allowed)) THEN
      RETURN public._act_finish(ctx, 'patient.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'This field cannot be changed here: ' || k, p_customer, NULL, 'customers');
    END IF;
  END LOOP;
  IF p_changes ? 'full_name' AND btrim(COALESCE(p_changes ->> 'full_name', '')) = '' THEN
    RETURN public._act_finish(ctx, 'patient.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'A name is required.', p_customer, NULL, 'customers');
  END IF;
  IF p_changes ? 'branch_id' AND NOT EXISTS (SELECT 1 FROM public.branches WHERE id = (p_changes ->> 'branch_id')::uuid AND org_id = v_org) THEN
    RETURN public._act_finish(ctx, 'patient.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'That clinic branch is not in this organization.', p_customer, NULL, 'customers');
  END IF;
  BEGIN
    UPDATE public.customers SET
      full_name = CASE WHEN p_changes ? 'full_name' THEN btrim(p_changes ->> 'full_name') ELSE full_name END,
      phone = CASE WHEN p_changes ? 'phone' THEN NULLIF(btrim(p_changes ->> 'phone'), '') ELSE phone END,
      email = CASE WHEN p_changes ? 'email' THEN NULLIF(btrim(p_changes ->> 'email'), '') ELSE email END,
      gender = CASE WHEN p_changes ? 'gender' THEN NULLIF(p_changes ->> 'gender', '') ELSE gender END,
      date_of_birth = CASE WHEN p_changes ? 'date_of_birth' THEN NULLIF(p_changes ->> 'date_of_birth', '')::date ELSE date_of_birth END,
      dob_bs = CASE WHEN p_changes ? 'dob_bs' THEN p_changes ->> 'dob_bs' ELSE dob_bs END,
      full_name_ne = CASE WHEN p_changes ? 'full_name_ne' THEN p_changes ->> 'full_name_ne' ELSE full_name_ne END,
      language = CASE WHEN p_changes ? 'language' THEN NULLIF(p_changes ->> 'language', '') ELSE language END,
      preferred_channel = CASE WHEN p_changes ? 'preferred_channel' THEN NULLIF(p_changes ->> 'preferred_channel', '') ELSE preferred_channel END,
      address = CASE WHEN p_changes ? 'address' THEN p_changes ->> 'address' ELSE address END,
      found_us = CASE WHEN p_changes ? 'found_us' THEN p_changes ->> 'found_us' ELSE found_us END,
      emergency_contact_name = CASE WHEN p_changes ? 'emergency_contact_name' THEN p_changes ->> 'emergency_contact_name' ELSE emergency_contact_name END,
      emergency_contact_phone = CASE WHEN p_changes ? 'emergency_contact_phone' THEN p_changes ->> 'emergency_contact_phone' ELSE emergency_contact_phone END,
      old_file_no = CASE WHEN p_changes ? 'old_file_no' THEN NULLIF(btrim(p_changes ->> 'old_file_no'), '') ELSE old_file_no END,
      notes = CASE WHEN p_changes ? 'notes' THEN p_changes ->> 'notes' ELSE notes END,
      branch_id = CASE WHEN p_changes ? 'branch_id' THEN (p_changes ->> 'branch_id')::uuid ELSE branch_id END
    WHERE id = p_customer;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_code = '23505' THEN v_code := 'PHONE_EXISTS'; v_msg := 'Another patient already has this phone number.'; END IF;
    IF v_code IN ('22007', '22008', '23514', '22P02') THEN v_code := 'INVALID_INPUT'; v_msg := 'A value is not valid (check the date, language and channel).'; END IF;
    RETURN public._act_finish(ctx, 'patient.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, v_code, v_msg, p_customer, NULL, 'customers');
  END;
  RETURN public._act_finish(ctx, 'patient.update', v_org, public._pt_branch(ctx), v_inputs, true,
    jsonb_build_object('customer_id', p_customer, 'patient_no', c.patient_no), NULL, NULL, p_customer, NULL, 'customers');   -- no undo: it would copy personal values into the audit log
END $$;

-- 5.3 alerts ----------------------------------------------------------------------------------------------------------------
CREATE FUNCTION public.act_alert_add(p_customer uuid, p_type text, p_text text, p_details text DEFAULT NULL, p_severity text DEFAULT 'note', p_ctx jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; v_inputs jsonb; c public.customers; v_id uuid; v_code text; v_msg text;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('customer_id', p_customer, 'type', p_type, 'severity', p_severity) || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['staff', 'manager', 'admin', 'practitioner']) THEN
    RETURN public._act_finish(ctx, 'alert.add', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot add alerts.', p_customer, NULL, 'customers');
  END IF;
  SELECT * INTO c FROM public.customers WHERE id = p_customer AND org_id = v_org;
  IF c.id IS NULL OR c.erased_at IS NOT NULL THEN
    RETURN public._act_finish(ctx, 'alert.add', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'PATIENT_NOT_FOUND', 'Patient not found.', p_customer, NULL, 'customers');
  END IF;
  BEGIN
    INSERT INTO public.patient_alerts (org_id, customer_id, type, text, details, severity, source, created_by,
                                       confirmed_by, confirmed_at)
    VALUES (v_org, p_customer, p_type, btrim(COALESCE(p_text, '')), p_details, COALESCE(p_severity, 'note'),
            CASE WHEN ctx ->> 'role' = 'practitioner' THEN 'practitioner' ELSE 'front_desk' END, (ctx ->> 'user_id')::uuid, NULL, NULL)
    RETURNING id INTO v_id;   -- a practitioner's own alert still starts unconfirmed: confirming is its own explicit act
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_code IN ('23514', '22P02') THEN v_code := 'INVALID_INPUT'; v_msg := 'Check the alert type, text and seriousness.'; END IF;
    RETURN public._act_finish(ctx, 'alert.add', v_org, public._pt_branch(ctx), v_inputs, false, NULL, v_code, v_msg, p_customer, NULL, 'customers');
  END;
  RETURN public._act_finish(ctx, 'alert.add', v_org, public._pt_branch(ctx), v_inputs, true, jsonb_build_object('alert_id', v_id, 'customer_id', p_customer), NULL, NULL, p_customer,
    jsonb_build_object('kind', 'alert_add', 'alert_id', v_id, 'roles', jsonb_build_array('staff', 'manager', 'admin', 'practitioner'), 'expires_at', now() + interval '24 hours'), 'customers');
END $$;

CREATE FUNCTION public.act_alert_confirm(p_alert uuid, p_ctx jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; v_inputs jsonb; a public.patient_alerts;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('alert_id', p_alert) || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['practitioner']) THEN
    RETURN public._act_finish(ctx, 'alert.confirm', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Only a practitioner can confirm an alert.', NULL, NULL, 'customers');
  END IF;
  SELECT * INTO a FROM public.patient_alerts WHERE id = p_alert AND org_id = v_org AND removed_at IS NULL FOR UPDATE;
  IF a.id IS NULL THEN
    RETURN public._act_finish(ctx, 'alert.confirm', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'ALERT_NOT_FOUND', 'Alert not found.', NULL, NULL, 'customers');
  END IF;
  IF a.confirmed_at IS NOT NULL THEN
    RETURN public._act_finish(ctx, 'alert.confirm', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'ALREADY_CONFIRMED', 'This alert is already confirmed.', a.customer_id, NULL, 'customers');
  END IF;
  UPDATE public.patient_alerts SET confirmed_by = (ctx ->> 'user_id')::uuid, confirmed_at = now() WHERE id = a.id;
  RETURN public._act_finish(ctx, 'alert.confirm', v_org, public._pt_branch(ctx), v_inputs, true, jsonb_build_object('alert_id', a.id, 'customer_id', a.customer_id), NULL, NULL, a.customer_id,
    jsonb_build_object('kind', 'alert_confirm', 'alert_id', a.id, 'roles', jsonb_build_array('practitioner'), 'expires_at', now() + interval '24 hours'), 'customers');
END $$;

-- change: anyone who edits may change an UNCONFIRMED alert; a confirmed one only a practitioner (and it stays confirmed)
CREATE FUNCTION public.act_alert_update(p_alert uuid, p_changes jsonb, p_ctx jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; v_inputs jsonb; a public.patient_alerts; k text; v_code text; v_msg text;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('alert_id', p_alert, 'fields', (SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM jsonb_object_keys(COALESCE(p_changes, '{}'::jsonb)) x)) || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['staff', 'manager', 'admin', 'practitioner']) THEN
    RETURN public._act_finish(ctx, 'alert.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot change alerts.', NULL, NULL, 'customers');
  END IF;
  SELECT * INTO a FROM public.patient_alerts WHERE id = p_alert AND org_id = v_org AND removed_at IS NULL FOR UPDATE;
  IF a.id IS NULL THEN
    RETURN public._act_finish(ctx, 'alert.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'ALERT_NOT_FOUND', 'Alert not found.', NULL, NULL, 'customers');
  END IF;
  IF a.confirmed_at IS NOT NULL AND ctx ->> 'role' <> 'practitioner' THEN
    RETURN public._act_finish(ctx, 'alert.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Only a practitioner can change a confirmed alert.', a.customer_id, NULL, 'customers');
  END IF;
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR p_changes = '{}'::jsonb THEN
    RETURN public._act_finish(ctx, 'alert.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'Nothing to change.', a.customer_id, NULL, 'customers');
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_changes) LOOP
    IF k NOT IN ('type', 'text', 'details', 'severity') THEN
      RETURN public._act_finish(ctx, 'alert.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'This field cannot be changed: ' || k, a.customer_id, NULL, 'customers');
    END IF;
  END LOOP;
  BEGIN
    UPDATE public.patient_alerts SET type = COALESCE(p_changes ->> 'type', type), text = COALESCE(btrim(p_changes ->> 'text'), text),
           details = CASE WHEN p_changes ? 'details' THEN p_changes ->> 'details' ELSE details END, severity = COALESCE(p_changes ->> 'severity', severity)
     WHERE id = a.id;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_code IN ('23514', '22P02') THEN v_code := 'INVALID_INPUT'; v_msg := 'Check the alert type, text and seriousness.'; END IF;
    RETURN public._act_finish(ctx, 'alert.update', v_org, public._pt_branch(ctx), v_inputs, false, NULL, v_code, v_msg, a.customer_id, NULL, 'customers');
  END;
  RETURN public._act_finish(ctx, 'alert.update', v_org, public._pt_branch(ctx), v_inputs, true, jsonb_build_object('alert_id', a.id, 'customer_id', a.customer_id), NULL, NULL, a.customer_id, NULL, 'customers');
END $$;

CREATE FUNCTION public.act_alert_remove(p_alert uuid, p_ctx jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; v_inputs jsonb; a public.patient_alerts;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('alert_id', p_alert) || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['staff', 'manager', 'admin', 'practitioner']) THEN
    RETURN public._act_finish(ctx, 'alert.remove', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot remove alerts.', NULL, NULL, 'customers');
  END IF;
  SELECT * INTO a FROM public.patient_alerts WHERE id = p_alert AND org_id = v_org AND removed_at IS NULL FOR UPDATE;
  IF a.id IS NULL THEN
    RETURN public._act_finish(ctx, 'alert.remove', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'ALERT_NOT_FOUND', 'Alert not found.', NULL, NULL, 'customers');
  END IF;
  IF a.confirmed_at IS NOT NULL AND ctx ->> 'role' <> 'practitioner' THEN
    RETURN public._act_finish(ctx, 'alert.remove', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Only a practitioner can remove a confirmed alert.', a.customer_id, NULL, 'customers');
  END IF;
  UPDATE public.patient_alerts SET removed_at = now(), removed_by = (ctx ->> 'user_id')::uuid WHERE id = a.id;
  RETURN public._act_finish(ctx, 'alert.remove', v_org, public._pt_branch(ctx), v_inputs, true, jsonb_build_object('alert_id', a.id, 'customer_id', a.customer_id), NULL, NULL, a.customer_id,
    jsonb_build_object('kind', 'alert_remove', 'alert_id', a.id, 'roles', CASE WHEN a.confirmed_at IS NULL THEN jsonb_build_array('staff', 'manager', 'admin', 'practitioner') ELSE jsonb_build_array('practitioner') END,
                       'expires_at', now() + interval '24 hours'), 'customers');
END $$;

-- 5.4 families ---------------------------------------------------------------------------------------------------------------
-- p_family OR p_with_customer (a member of the family, or a patient to start one with). The phone guard decides what is legal.
CREATE FUNCTION public.act_family_link(p_customer uuid, p_family uuid DEFAULT NULL, p_with_customer uuid DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; v_inputs jsonb; c public.customers; w public.customers; v_fam uuid; v_code text; v_msg text; v_created boolean := false;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('customer_id', p_customer, 'family_id', p_family, 'with_customer', p_with_customer) || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['staff', 'manager', 'admin']) THEN
    RETURN public._act_finish(ctx, 'family.link', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot link families.', p_customer, NULL, 'customers');
  END IF;
  SELECT * INTO c FROM public.customers WHERE id = p_customer AND org_id = v_org AND erased_at IS NULL FOR UPDATE;
  IF c.id IS NULL OR (p_family IS NULL AND p_with_customer IS NULL) THEN
    RETURN public._act_finish(ctx, 'family.link', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'Choose a patient or a family to link with.', p_customer, NULL, 'customers');
  END IF;
  IF p_family IS NOT NULL THEN
    SELECT id INTO v_fam FROM public.families WHERE id = p_family AND org_id = v_org;
  ELSE
    SELECT * INTO w FROM public.customers WHERE id = p_with_customer AND org_id = v_org AND erased_at IS NULL FOR UPDATE;
    IF w.id IS NOT NULL THEN
      v_fam := w.family_id;
      IF v_fam IS NULL THEN
        INSERT INTO public.families (org_id, name, contact_customer_id) VALUES (v_org, w.full_name || ' family', w.id) RETURNING id INTO v_fam;
        v_created := true;
      END IF;
    END IF;
  END IF;
  IF v_fam IS NULL OR c.id = p_with_customer THEN
    RETURN public._act_finish(ctx, 'family.link', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'Family not found.', p_customer, NULL, 'customers');
  END IF;
  BEGIN
    IF v_created THEN UPDATE public.customers SET family_id = v_fam WHERE id = w.id; END IF;
    UPDATE public.customers SET family_id = v_fam WHERE id = c.id;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_code = '23505' THEN v_code := 'PHONE_EXISTS'; v_msg := 'This patient''s phone number is used by someone outside the family.'; END IF;
    RETURN public._act_finish(ctx, 'family.link', v_org, public._pt_branch(ctx), v_inputs, false, NULL, v_code, v_msg, p_customer, NULL, 'customers');
  END;
  RETURN public._act_finish(ctx, 'family.link', v_org, public._pt_branch(ctx), v_inputs, true, jsonb_build_object('customer_id', c.id, 'family_id', v_fam), NULL, NULL, c.id,
    jsonb_build_object('kind', 'family_link', 'customer_id', c.id, 'prior_family_id', c.family_id, 'family_id', v_fam, 'created_family', v_created,
                       'roles', jsonb_build_array('staff', 'manager', 'admin'), 'expires_at', now() + interval '24 hours'), 'customers');
END $$;

CREATE FUNCTION public.act_family_unlink(p_customer uuid, p_ctx jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; v_inputs jsonb; c public.customers; v_code text; v_msg text;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('customer_id', p_customer) || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['staff', 'manager', 'admin']) THEN
    RETURN public._act_finish(ctx, 'family.unlink', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot unlink families.', p_customer, NULL, 'customers');
  END IF;
  SELECT * INTO c FROM public.customers WHERE id = p_customer AND org_id = v_org FOR UPDATE;
  IF c.id IS NULL OR c.family_id IS NULL THEN
    RETURN public._act_finish(ctx, 'family.unlink', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'This patient is not in a family.', p_customer, NULL, 'customers');
  END IF;
  BEGIN
    UPDATE public.families SET contact_customer_id = NULL WHERE id = c.family_id AND contact_customer_id = c.id;
    UPDATE public.customers SET family_id = NULL WHERE id = c.id;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_code = '23505' THEN v_code := 'PHONE_SHARED'; v_msg := 'This patient shares a phone number with the family. Give them their own number first.'; END IF;
    RETURN public._act_finish(ctx, 'family.unlink', v_org, public._pt_branch(ctx), v_inputs, false, NULL, v_code, v_msg, p_customer, NULL, 'customers');
  END;
  RETURN public._act_finish(ctx, 'family.unlink', v_org, public._pt_branch(ctx), v_inputs, true, jsonb_build_object('customer_id', c.id, 'family_id', c.family_id), NULL, NULL, c.id,
    jsonb_build_object('kind', 'family_unlink', 'customer_id', c.id, 'family_id', c.family_id, 'roles', jsonb_build_array('staff', 'manager', 'admin'), 'expires_at', now() + interval '24 hours'), 'customers');
END $$;

CREATE FUNCTION public.act_family_set_contact(p_family uuid, p_customer uuid, p_ctx jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; v_inputs jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('family_id', p_family, 'customer_id', p_customer) || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['staff', 'manager', 'admin']) THEN
    RETURN public._act_finish(ctx, 'family.set_contact', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot change a family contact.', p_customer, NULL, 'customers');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer AND org_id = v_org AND family_id = p_family AND erased_at IS NULL)
     OR NOT EXISTS (SELECT 1 FROM public.families WHERE id = p_family AND org_id = v_org) THEN
    RETURN public._act_finish(ctx, 'family.set_contact', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'The contact must be a member of the family.', p_customer, NULL, 'customers');
  END IF;
  UPDATE public.families SET contact_customer_id = p_customer WHERE id = p_family;
  RETURN public._act_finish(ctx, 'family.set_contact', v_org, public._pt_branch(ctx), v_inputs, true, jsonb_build_object('family_id', p_family, 'customer_id', p_customer), NULL, NULL, p_customer, NULL, 'customers');
END $$;

-- 5.5 forms -----------------------------------------------------------------------------------------------------------------
-- The token (32 random bytes, hex) is returned ONCE and only its sha256 is stored. Valid 3 days. A signed form cannot be submitted again.
CREATE FUNCTION public._pt_form_start(p_action text, p_channel text, p_customer uuid, p_template uuid, p_ctx jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE ctx jsonb := p_ctx; v_org uuid := (p_ctx ->> 'org_id')::uuid; v_inputs jsonb; v_tok text; v_id uuid; t public.form_templates;
BEGIN
  v_inputs := jsonb_build_object('customer_id', p_customer, 'template_id', p_template, 'channel', p_channel);
  IF NOT public._pt_ok(ctx, ARRAY['staff', 'manager', 'admin', 'practitioner']) THEN
    RETURN public._act_finish(ctx, p_action, v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot send forms.', p_customer, NULL, 'customers');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer AND org_id = v_org AND erased_at IS NULL) THEN
    RETURN public._act_finish(ctx, p_action, v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'PATIENT_NOT_FOUND', 'Patient not found.', p_customer, NULL, 'customers');
  END IF;
  SELECT * INTO t FROM public.form_templates WHERE id = p_template AND (org_id IS NULL OR org_id = v_org) AND is_active;
  IF t.id IS NULL THEN
    RETURN public._act_finish(ctx, p_action, v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'Form not found.', p_customer, NULL, 'customers');
  END IF;
  v_tok := encode(extensions.gen_random_bytes(32), 'hex');
  INSERT INTO public.form_submissions (org_id, customer_id, template_id, channel, status, token_hash, expires_at, created_by)
  VALUES (v_org, p_customer, t.id, p_channel, 'sent', encode(sha256(convert_to(v_tok, 'UTF8')), 'hex'), now() + interval '3 days', (ctx ->> 'user_id')::uuid)
  RETURNING id INTO v_id;
  RETURN public._act_finish(ctx, p_action, v_org, public._pt_branch(ctx), v_inputs, true,
    jsonb_build_object('submission_id', v_id, 'token', v_tok, 'expires_at', now() + interval '3 days'), NULL, NULL, p_customer, NULL, 'customers');
END $$;

CREATE FUNCTION public.act_form_send_link(p_customer uuid, p_template uuid, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb := public._act_resolve(p_ctx);
BEGIN
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  RETURN public._pt_form_start('form.send_link', 'link', p_customer, p_template, ctx);
END $$;
CREATE FUNCTION public.act_form_start_on_device(p_customer uuid, p_template uuid, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb := public._act_resolve(p_ctx);
BEGIN
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  RETURN public._pt_form_start('form.start_on_device', 'tablet', p_customer, p_template, ctx);
END $$;

CREATE FUNCTION public.act_form_record_typed(p_customer uuid, p_template uuid, p_answers jsonb, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; v_inputs jsonb; v_id uuid; t public.form_templates;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('customer_id', p_customer, 'template_id', p_template, 'channel', 'typed') || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['staff', 'manager', 'admin', 'practitioner']) THEN
    RETURN public._act_finish(ctx, 'form.record_typed', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot record forms.', p_customer, NULL, 'customers');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer AND org_id = v_org AND erased_at IS NULL) THEN
    RETURN public._act_finish(ctx, 'form.record_typed', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'PATIENT_NOT_FOUND', 'Patient not found.', p_customer, NULL, 'customers');
  END IF;
  SELECT * INTO t FROM public.form_templates WHERE id = p_template AND (org_id IS NULL OR org_id = v_org) AND is_active;
  IF t.id IS NULL OR p_answers IS NULL OR jsonb_typeof(p_answers) <> 'object' OR pg_column_size(p_answers) >= 200000 THEN
    RETURN public._act_finish(ctx, 'form.record_typed', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'The form or its answers are not valid.', p_customer, NULL, 'customers');
  END IF;
  INSERT INTO public.form_submissions (org_id, customer_id, template_id, channel, status, signed_at, device, answers, created_by)
  VALUES (v_org, p_customer, t.id, 'typed', 'signed', now(), 'typed by staff', p_answers, (ctx ->> 'user_id')::uuid) RETURNING id INTO v_id;
  PERFORM public._pt_alerts_from_answers(v_org, p_customer, t.body, p_answers);
  RETURN public._act_finish(ctx, 'form.record_typed', v_org, public._pt_branch(ctx), v_inputs, true, jsonb_build_object('submission_id', v_id), NULL, NULL, p_customer, NULL, 'customers');
END $$;

-- an intake form creates UNCONFIRMED alerts from the fields its template lists in alerts_from (text answers, max 10 per form)
CREATE FUNCTION public._pt_alerts_from_answers(p_org uuid, p_customer uuid, p_body jsonb, p_answers jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE f text; v jsonb; s text; n int := 0; v_type text;
BEGIN
  FOR f IN SELECT jsonb_array_elements_text(COALESCE(p_body -> 'alerts_from', '[]'::jsonb)) LOOP
    v := p_answers -> f;
    v_type := CASE f WHEN 'allergies' THEN 'allergy' WHEN 'medications' THEN 'medication' WHEN 'conditions' THEN 'condition' ELSE 'other' END;
    FOR s IN SELECT btrim(x) FROM jsonb_array_elements_text(
               CASE WHEN jsonb_typeof(v) = 'array' THEN v WHEN jsonb_typeof(v) = 'string' THEN jsonb_build_array(v #>> '{}') ELSE '[]'::jsonb END) x LOOP
      CONTINUE WHEN s = '';
      EXIT WHEN n >= 10;
      INSERT INTO public.patient_alerts (org_id, customer_id, type, text, severity, source) VALUES (p_org, p_customer, v_type, left(s, 300), 'note', 'intake_form');
      n := n + 1;
    END LOOP;
  END LOOP;
END $$;

-- anon (the patient's own link or the clinic tablet): one submission, by token hash, nothing else
CREATE FUNCTION public.public_get_form(p_token text)
RETURNS TABLE (title text, body jsonb, first_name text, status text)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT t.title, t.body, split_part(btrim(c.full_name), ' ', 1), 'open'::text
    FROM public.form_submissions s
    JOIN public.form_templates t ON t.id = s.template_id
    JOIN public.customers c ON c.id = s.customer_id
   WHERE length(COALESCE(p_token, '')) >= 64
     AND s.token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
     AND s.status = 'sent' AND s.signed_at IS NULL AND s.expires_at > now() AND c.erased_at IS NULL AND c.archived_at IS NULL;
$$;

CREATE FUNCTION public.public_submit_form(p_token text, p_answers jsonb, p_device text DEFAULT NULL) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE s public.form_submissions; t public.form_templates;
BEGIN
  IF length(COALESCE(p_token, '')) < 64 THEN RETURN 'invalid'; END IF;
  SELECT * INTO s FROM public.form_submissions WHERE token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex') FOR UPDATE;
  IF s.id IS NULL THEN RETURN 'invalid'; END IF;
  IF s.status = 'signed' OR s.signed_at IS NOT NULL THEN RETURN 'already_signed'; END IF;
  IF s.expires_at IS NULL OR s.expires_at <= now() THEN
    UPDATE public.form_submissions SET status = 'expired' WHERE id = s.id AND status = 'sent';
    RETURN 'expired';
  END IF;
  IF p_answers IS NULL OR jsonb_typeof(p_answers) <> 'object' OR pg_column_size(p_answers) >= 200000 THEN RETURN 'invalid'; END IF;
  IF EXISTS (SELECT 1 FROM public.customers WHERE id = s.customer_id AND (erased_at IS NOT NULL OR archived_at IS NOT NULL)) THEN RETURN 'invalid'; END IF;
  UPDATE public.form_submissions SET status = 'signed', signed_at = now(), answers = p_answers, device = left(p_device, 200) WHERE id = s.id;
  SELECT * INTO t FROM public.form_templates WHERE id = s.template_id;
  PERFORM public._pt_alerts_from_answers(s.org_id, s.customer_id, t.body, p_answers);
  RETURN 'ok';
END $$;

-- 5.6 consent (the patient's own words are the evidence) -------------------------------------------------------------------
CREATE FUNCTION public.act_consent_marketing_yes(p_customer uuid, p_channel text, p_address text, p_evidence text, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  IF NOT public._pt_ok(ctx, ARRAY['staff', 'manager', 'admin']) THEN
    RETURN public._act_finish(ctx, 'consent.record_marketing_yes', (ctx ->> 'org_id')::uuid, public._pt_branch(ctx), jsonb_build_object('customer_id', p_customer), false, NULL,
                              'FORBIDDEN', 'Your role cannot record consent.', p_customer, NULL, 'customers');
  END IF;
  IF btrim(COALESCE(p_evidence, '')) = '' THEN
    RETURN public._act_finish(ctx, 'consent.record_marketing_yes', (ctx ->> 'org_id')::uuid, public._pt_branch(ctx), jsonb_build_object('customer_id', p_customer), false, NULL,
                              'INVALID_INPUT', 'Write what the patient said.', p_customer, NULL, 'customers');
  END IF;
  RETURN public.act_consent_record(p_customer, COALESCE(p_channel, 'sms'), p_address, 'marketing', 'agreed', p_evidence, p_ctx);
END $$;

-- 5.7 undo for patient actions (kept apart from act_undo so 012/013/016 stay untouched). Ids only; no personal values.
CREATE FUNCTION public.act_patient_undo(p_action_id uuid, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; a public.action_log; u jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('action_id', p_action_id);
  SELECT * INTO a FROM public.action_log WHERE id = p_action_id AND org_id = v_org FOR UPDATE;
  IF a.id IS NULL OR a.undo IS NULL OR NOT a.ok OR a.target_table <> 'customers' THEN
    RETURN public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'ACTION_NOT_FOUND', 'Action not found.', NULL, NULL, 'customers');
  END IF;
  u := a.undo;
  IF a.undone_by_action IS NOT NULL THEN
    RETURN public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'UNDO_ALREADY', 'This action was already undone.', a.target_id, NULL, 'customers');
  END IF;
  IF (u ->> 'expires_at')::timestamptz < now() THEN
    RETURN public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'UNDO_EXPIRED', 'The time to undo this action has passed.', a.target_id, NULL, 'customers');
  END IF;
  IF ctx ->> 'kind' <> 'person' OR NOT ((u -> 'roles') ? (ctx ->> 'role')) THEN
    RETURN public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot undo this.', a.target_id, NULL, 'customers');
  END IF;
  BEGIN
    IF u ->> 'kind' = 'alert_add' THEN
      UPDATE public.patient_alerts SET removed_at = now(), removed_by = (ctx ->> 'user_id')::uuid WHERE id = (u ->> 'alert_id')::uuid AND removed_at IS NULL AND confirmed_at IS NULL;
      IF NOT FOUND THEN RETURN public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'UNDO_STALE', 'The alert was changed after you added it.', a.target_id, NULL, 'customers'); END IF;
    ELSIF u ->> 'kind' = 'alert_confirm' THEN
      UPDATE public.patient_alerts SET confirmed_at = NULL, confirmed_by = NULL WHERE id = (u ->> 'alert_id')::uuid AND removed_at IS NULL AND confirmed_by = a.actor_user_id;
      IF NOT FOUND THEN RETURN public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'UNDO_STALE', 'The alert was changed after it was confirmed.', a.target_id, NULL, 'customers'); END IF;
    ELSIF u ->> 'kind' = 'alert_remove' THEN
      UPDATE public.patient_alerts SET removed_at = NULL, removed_by = NULL WHERE id = (u ->> 'alert_id')::uuid AND removed_at IS NOT NULL;
      IF NOT FOUND THEN RETURN public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'UNDO_STALE', 'The alert is already back.', a.target_id, NULL, 'customers'); END IF;
    ELSIF u ->> 'kind' = 'family_link' THEN
      UPDATE public.customers SET family_id = NULLIF(u ->> 'prior_family_id', '')::uuid WHERE id = (u ->> 'customer_id')::uuid AND family_id = (u ->> 'family_id')::uuid;
      IF NOT FOUND THEN RETURN public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'UNDO_STALE', 'The family changed after the link.', a.target_id, NULL, 'customers'); END IF;
    ELSIF u ->> 'kind' = 'family_unlink' THEN
      UPDATE public.customers SET family_id = (u ->> 'family_id')::uuid WHERE id = (u ->> 'customer_id')::uuid AND family_id IS NULL;
      IF NOT FOUND THEN RETURN public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'UNDO_STALE', 'The patient changed after the unlink.', a.target_id, NULL, 'customers'); END IF;
    ELSE
      RETURN public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'UNDO_NOT_POSSIBLE', 'This action cannot be undone.', a.target_id, NULL, 'customers');
    END IF;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_code = '23505' THEN v_code := 'UNDO_BLOCKED'; v_msg := 'The phone number is now used outside the family, so this cannot be undone.'; END IF;
    RETURN public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, false, NULL, v_code, v_msg, a.target_id, NULL, 'customers');
  END;
  v_res := public._act_finish(ctx, 'patient.undo', v_org, public._pt_branch(ctx), v_inputs, true, jsonb_build_object('undone_action', a.id, 'kind', u ->> 'kind'), NULL, NULL, a.target_id, NULL, 'customers');
  UPDATE public.action_log SET undone_by_action = (v_res ->> 'action_id')::uuid WHERE id = a.id;
  RETURN v_res;
END $$;

-- 5.8 archive / restore -------------------------------------------------------------------------------------------------------
-- Archive: hidden from list, search, agents and bulk sends; future bookings are cancelled through the booking action (audited each);
-- money rows are untouched, so dues stay. The result carries the counts the dialog shows.
CREATE FUNCTION public.act_patient_archive(p_customer uuid, p_reason text DEFAULT NULL, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  ctx jsonb; v_org uuid; v_inputs jsonb; c public.customers; b record; r jsonb; v_cancelled int := 0; v_skipped int := 0; v_dues int;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('customer_id', p_customer, 'has_reason', btrim(COALESCE(p_reason, '')) <> '') || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['manager', 'admin']) THEN
    RETURN public._act_finish(ctx, 'patient.archive', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Only a manager or the owner can archive a patient.', p_customer, NULL, 'customers');
  END IF;
  SELECT * INTO c FROM public.customers WHERE id = p_customer AND org_id = v_org FOR UPDATE;
  IF c.id IS NULL OR c.erased_at IS NOT NULL THEN
    RETURN public._act_finish(ctx, 'patient.archive', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'PATIENT_NOT_FOUND', 'Patient not found.', p_customer, NULL, 'customers');
  END IF;
  IF c.archived_at IS NOT NULL THEN
    RETURN public._act_finish(ctx, 'patient.archive', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'ALREADY_ARCHIVED', 'This patient is already archived.', p_customer, NULL, 'customers');
  END IF;
  UPDATE public.customers SET archived_at = now(), archived_by = (ctx ->> 'user_id')::uuid, archive_reason = NULLIF(btrim(p_reason), '') WHERE id = c.id;
  FOR b IN SELECT bk.id FROM public.bookings bk WHERE bk.customer_id = c.id AND bk.start_datetime > now() AND bk.status IN ('Pending', 'Confirmed') ORDER BY bk.start_datetime LOOP
    r := public.act_booking_set_status(b.id, 'Cancelled', 'Patient archived', p_ctx);
    IF (r ->> 'ok')::boolean THEN v_cancelled := v_cancelled + 1; ELSE v_skipped := v_skipped + 1; END IF;
  END LOOP;
  UPDATE public.agent_jobs SET status = 'skipped', last_error = 'PATIENT_ARCHIVED' WHERE customer_id = c.id AND status = 'queued';
  UPDATE public.agent_work_items SET status = 'expired' WHERE customer_id = c.id AND status = 'open';
  SELECT count(*) INTO v_dues FROM public.bookings bk WHERE bk.customer_id = c.id AND bk.status <> 'Cancelled' AND bk.payment_status IN ('unpaid', 'partial');
  RETURN public._act_finish(ctx, 'patient.archive', v_org, public._pt_branch(ctx), v_inputs, true,
    jsonb_build_object('customer_id', c.id, 'cancelled_bookings', v_cancelled, 'not_cancelled', v_skipped, 'bookings_with_dues', v_dues), NULL, NULL, c.id, NULL, 'customers');
END $$;

CREATE FUNCTION public.act_patient_restore(p_customer uuid, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; v_inputs jsonb; c public.customers;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('customer_id', p_customer) || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['manager', 'admin']) THEN
    RETURN public._act_finish(ctx, 'patient.restore', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Only a manager or the owner can restore a patient.', p_customer, NULL, 'customers');
  END IF;
  SELECT * INTO c FROM public.customers WHERE id = p_customer AND org_id = v_org AND erased_at IS NULL FOR UPDATE;
  IF c.id IS NULL OR c.archived_at IS NULL THEN
    RETURN public._act_finish(ctx, 'patient.restore', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'This patient is not archived.', p_customer, NULL, 'customers');
  END IF;
  UPDATE public.customers SET archived_at = NULL, archived_by = NULL, archive_reason = NULL WHERE id = c.id;   -- cancelled bookings are not brought back
  RETURN public._act_finish(ctx, 'patient.restore', v_org, public._pt_branch(ctx), v_inputs, true, jsonb_build_object('customer_id', c.id), NULL, NULL, c.id, NULL, 'customers');
END $$;

-- 5.9 erase (owner only: admin = owner in this app; admin_viewer and everyone else refused) -------------------------------------
-- Needs: an uploaded written request in the private bucket erase-requests under "<org>/<customer>/", and the patient's typed name.
-- Refuses while any recording of the patient still exists in storage: the edge function patient-erase deletes the files through the
-- Storage API first (SQL must not delete storage.objects), then calls this. Keeps clinical and money rows, relabelled "Erased patient P-NNNNN".
CREATE FUNCTION public.act_patient_erase(p_customer uuid, p_request_path text, p_typed_name text, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  ctx jsonb; v_org uuid; v_inputs jsonb; c public.customers; v_label text; v_prefix text; v_n_conv int; v_n_ch int; v_n_book int; v_n_cons int; v_n_out int;
  v_auth uuid[]; v_code text; v_msg text;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('customer_id', p_customer, 'request_path', p_request_path) || public._act_ctx_inputs(p_ctx, ctx);   -- the typed name is never logged
  IF NOT public._pt_ok(ctx, ARRAY['admin']) THEN
    RETURN public._act_finish(ctx, 'patient.erase', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Only the owner can erase a patient.', p_customer, NULL, 'customers');
  END IF;
  SELECT * INTO c FROM public.customers WHERE id = p_customer AND org_id = v_org FOR UPDATE;
  IF c.id IS NULL THEN
    RETURN public._act_finish(ctx, 'patient.erase', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'PATIENT_NOT_FOUND', 'Patient not found.', p_customer, NULL, 'customers');
  END IF;
  IF c.erased_at IS NOT NULL THEN
    RETURN public._act_finish(ctx, 'patient.erase', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'ALREADY_ERASED', 'This patient was already erased.', p_customer, NULL, 'customers');
  END IF;
  v_prefix := v_org::text || '/' || c.id::text || '/';
  IF p_request_path IS NULL OR left(p_request_path, length(v_prefix)) <> v_prefix
     OR NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'erase-requests' AND o.name = p_request_path) THEN
    RETURN public._act_finish(ctx, 'patient.erase', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'REQUEST_FILE_MISSING', 'Upload the patient''s written request first.', p_customer, NULL, 'customers');
  END IF;
  IF public._norm_name(p_typed_name) <> public._norm_name(c.full_name) THEN
    RETURN public._act_finish(ctx, 'patient.erase', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'NAME_MISMATCH', 'The typed name does not match the patient.', p_customer, NULL, 'customers');
  END IF;
  IF EXISTS (SELECT 1 FROM public.consultations cs CROSS JOIN LATERAL unnest(cs.audio_paths) p
              JOIN storage.objects o ON o.bucket_id = 'consultation-audio' AND o.name = p WHERE cs.customer_id = c.id) THEN
    RETURN public._act_finish(ctx, 'patient.erase', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'AUDIO_FILES_REMAIN',
                              'The recordings must be deleted first (use the erase service).', p_customer, NULL, 'customers');
  END IF;
  v_label := public._pt_label(c.patient_no);
  BEGIN
    -- threads and recordings' transcripts
    SELECT count(*) INTO v_n_conv FROM public.conversations WHERE customer_id = c.id;
    DELETE FROM public.conversations WHERE customer_id = c.id;                       -- messages cascade
    SELECT count(*) INTO v_n_ch FROM public.patient_channels WHERE customer_id = c.id;
    DELETE FROM public.patient_channels WHERE customer_id = c.id;
    DELETE FROM public.outreach_messages WHERE customer_id = c.id;
    UPDATE public.agent_jobs SET status = 'skipped', last_error = 'PATIENT_ERASED' WHERE customer_id = c.id AND status = 'queued';
    UPDATE public.agent_work_items SET status = 'expired' WHERE customer_id = c.id AND status = 'open';
    -- patient login: the account row goes; the edge function removes the auth user (ids returned)
    SELECT COALESCE(array_agg(auth_user_id), '{}') INTO v_auth FROM public.customer_accounts WHERE customer_id = c.id;
    UPDATE public.bookings SET customer_account_id = NULL WHERE customer_id = c.id AND customer_account_id IS NOT NULL;
    DELETE FROM public.customer_accounts WHERE customer_id = c.id;
    -- the clinical and money rows stay; only the name / contact copies on them are relabelled
    UPDATE public.bookings SET customer_name = v_label, customer_phone = NULL, customer_email = NULL, special_requests = NULL WHERE customer_id = c.id;
    GET DIAGNOSTICS v_n_book = ROW_COUNT;
    UPDATE public.consultations SET patient_name = v_label, transcript = NULL, audio_paths = '{}' WHERE customer_id = c.id;
    GET DIAGNOSTICS v_n_cons = ROW_COUNT;
    UPDATE public.families SET contact_customer_id = NULL WHERE contact_customer_id = c.id;
    UPDATE public.customers SET full_name = v_label, full_name_ne = NULL, phone = NULL, email = NULL, notes = NULL, gender = NULL, date_of_birth = NULL, dob_bs = NULL,
           old_file_no = NULL, address = NULL, found_us = NULL, emergency_contact_name = NULL, emergency_contact_phone = NULL, language = NULL, preferred_channel = NULL,
           family_id = NULL, is_active = false, erased_at = now(), erased_by = (ctx ->> 'user_id')::uuid, erase_request_path = p_request_path
     WHERE id = c.id;
    INSERT INTO public.patient_erasures (org_id, customer_id, patient_no, request_path, erased_by, fields_wiped, counts)
    VALUES (v_org, c.id, c.patient_no, p_request_path, (ctx ->> 'user_id')::uuid,
            ARRAY['full_name', 'full_name_ne', 'phone', 'email', 'notes', 'gender', 'date_of_birth', 'dob_bs', 'old_file_no', 'address', 'found_us', 'emergency_contact',
                  'language', 'preferred_channel', 'family_link', 'message_threads', 'patient_channels', 'recordings', 'transcripts', 'patient_login'],
            jsonb_build_object('conversations', v_n_conv, 'channels', v_n_ch, 'bookings_relabelled', v_n_book, 'consultations_relabelled', v_n_cons));
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RETURN public._act_finish(ctx, 'patient.erase', v_org, public._pt_branch(ctx), v_inputs, false, NULL, v_code, v_msg, p_customer, NULL, 'customers');
  END;
  RETURN public._act_finish(ctx, 'patient.erase', v_org, public._pt_branch(ctx), v_inputs, true,
    jsonb_build_object('customer_id', c.id, 'label', v_label, 'auth_user_ids', to_jsonb(v_auth)), NULL, NULL, c.id, NULL, 'customers');   -- not undoable
END $$;

-- erase-requests: a private bucket; the owner uploads and reads the written request under "<org>/<customer>/"
INSERT INTO storage.buckets (id, name, public, file_size_limit) VALUES ('erase-requests', 'erase-requests', false, 10485760) ON CONFLICT (id) DO NOTHING;
CREATE POLICY "Owner reads erase requests" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'erase-requests' AND (storage.foldername(name))[1] = public.get_user_org_id()::text AND public.get_user_role()::text IN ('admin', 'admin_viewer'));
CREATE POLICY "Owner uploads erase requests" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'erase-requests' AND (storage.foldername(name))[1] = public.get_user_org_id()::text AND public.get_user_role()::text = 'admin');

-- 5.10 merge, dismiss, link_family -------------------------------------------------------------------------------------------
-- One merge routine for the new action and the old merge_customers RPC. It repoints EVERY table that references the patient (the old RPC
-- missed notes, consultations, conversations, channels, agent rows, packages: ON DELETE SET NULL would have orphaned them), keeps the
-- dropped patient's number as a redirect to the kept record, snapshots the dropped row, and deletes it.
CREATE FUNCTION public._merge_customer_rows(p_keep uuid, p_drop uuid, p_actor uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE d public.customers; k public.customers; v_moved jsonb;
BEGIN
  SELECT * INTO k FROM public.customers WHERE id = p_keep FOR UPDATE;
  SELECT * INTO d FROM public.customers WHERE id = p_drop FOR UPDATE;
  UPDATE public.bookings SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.customer_accounts SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.customer_referral_credits SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.customer_referral_debits SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.customer_referrals SET referring_customer_id = p_keep WHERE referring_customer_id = p_drop;
  UPDATE public.customer_referrals SET referred_customer_id = p_keep WHERE referred_customer_id = p_drop;
  UPDATE public.memberships SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.outreach_messages SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.vouchers SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.packages SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.treatment_notes SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.consultations SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.conversations SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.patient_channels SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.agent_jobs SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.agent_work_items SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.patient_alerts SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.form_submissions SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.patient_redirects SET customer_id = p_keep WHERE customer_id = p_drop;
  UPDATE public.families SET contact_customer_id = p_keep WHERE contact_customer_id = p_drop;
  DELETE FROM public.customer_duplicate_dismissals WHERE customer_id_a = p_drop OR customer_id_b = p_drop;
  UPDATE public.customers can
     SET email = COALESCE(can.email, d.email), notes = COALESCE(can.notes, d.notes), gender = COALESCE(can.gender, d.gender),
         date_of_birth = COALESCE(can.date_of_birth, d.date_of_birth), old_file_no = COALESCE(can.old_file_no, d.old_file_no),
         full_name_ne = COALESCE(can.full_name_ne, d.full_name_ne), address = COALESCE(can.address, d.address),
         dob_bs = COALESCE(can.dob_bs, d.dob_bs), language = COALESCE(can.language, d.language), preferred_channel = COALESCE(can.preferred_channel, d.preferred_channel),
         emergency_contact_name = COALESCE(can.emergency_contact_name, d.emergency_contact_name),
         emergency_contact_phone = COALESCE(can.emergency_contact_phone, d.emergency_contact_phone), found_us = COALESCE(can.found_us, d.found_us),
         family_id = COALESCE(can.family_id, d.family_id)
   WHERE can.id = p_keep;
  INSERT INTO public.customer_merge_log (merged_id, canonical_id, org_id, nphone, merged_row)
  VALUES (p_drop, p_keep, d.org_id, public.normalize_phone_e164(d.phone), to_jsonb(d));
  INSERT INTO public.patient_redirects (org_id, patient_no, customer_id) VALUES (d.org_id, d.patient_no, p_keep);
  DELETE FROM public.customers WHERE id = p_drop;
  RETURN jsonb_build_object('kept', p_keep, 'merged', p_drop, 'merged_patient_no', d.patient_no, 'kept_patient_no', k.patient_no);
END $$;

CREATE FUNCTION public.act_duplicates_merge(p_keep uuid, p_drop uuid, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; k public.customers; d public.customers;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('keep', p_keep, 'drop', p_drop) || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['manager', 'admin']) THEN
    RETURN public._act_finish(ctx, 'duplicates.merge', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Only a manager or the owner can merge patients.', p_keep, NULL, 'customers');
  END IF;
  SELECT * INTO k FROM public.customers WHERE id = p_keep AND org_id = v_org AND erased_at IS NULL;
  SELECT * INTO d FROM public.customers WHERE id = p_drop AND org_id = v_org AND erased_at IS NULL;
  IF k.id IS NULL OR d.id IS NULL OR p_keep = p_drop THEN
    RETURN public._act_finish(ctx, 'duplicates.merge', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'Choose two different patients of this clinic group.', p_keep, NULL, 'customers');
  END IF;
  BEGIN
    v_res := public._merge_customer_rows(p_keep, p_drop, (ctx ->> 'user_id')::uuid);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RETURN public._act_finish(ctx, 'duplicates.merge', v_org, public._pt_branch(ctx), v_inputs, false, NULL, v_code, v_msg, p_keep, NULL, 'customers');
  END;
  RETURN public._act_finish(ctx, 'duplicates.merge', v_org, public._pt_branch(ctx), v_inputs, true, v_res, NULL, NULL, p_keep, NULL, 'customers');   -- not undoable
END $$;

-- the old RPC (still used by today's CRM screen) now uses the same routine, same checks and same result (void)
CREATE OR REPLACE FUNCTION public.merge_customers(p_canonical_id uuid, p_duplicate_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_role user_role; v_org_can uuid; v_org_dup uuid;
BEGIN
  IF p_canonical_id = p_duplicate_id THEN RAISE EXCEPTION 'merge_customers: canonical and duplicate are the same customer'; END IF;
  v_role := get_user_role();
  IF v_role NOT IN ('manager', 'admin') THEN RAISE EXCEPTION 'merge_customers: requires manager or admin role'; END IF;
  SELECT org_id INTO v_org_can FROM public.customers WHERE id = p_canonical_id;
  SELECT org_id INTO v_org_dup FROM public.customers WHERE id = p_duplicate_id;
  IF v_org_can IS NULL OR v_org_dup IS NULL THEN RAISE EXCEPTION 'merge_customers: canonical or duplicate customer not found'; END IF;
  IF v_org_can <> v_org_dup THEN RAISE EXCEPTION 'merge_customers: canonical and duplicate belong to different orgs'; END IF;
  IF v_org_can <> get_user_org_id() THEN RAISE EXCEPTION 'merge_customers: not authorized for this organization'; END IF;
  IF v_role = 'manager' AND NOT EXISTS (SELECT 1 FROM public.customers c WHERE c.id IN (p_canonical_id, p_duplicate_id) AND c.branch_id = get_user_branch_id()) THEN
    RAISE EXCEPTION 'merge_customers: manager may only merge customers touching their own branch';
  END IF;
  PERFORM public._merge_customer_rows(p_canonical_id, p_duplicate_id, auth.uid());
END;
$function$;

CREATE FUNCTION public.act_duplicates_dismiss(p_a uuid, p_b uuid, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_org uuid; v_inputs jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('a', p_a, 'b', p_b) || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT public._pt_ok(ctx, ARRAY['manager', 'admin']) THEN
    RETURN public._act_finish(ctx, 'duplicates.dismiss', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'FORBIDDEN', 'Only a manager or the owner can dismiss a duplicate.', p_a, NULL, 'customers');
  END IF;
  IF p_a = p_b OR (SELECT count(*) FROM public.customers WHERE id IN (p_a, p_b) AND org_id = v_org) <> 2 THEN
    RETURN public._act_finish(ctx, 'duplicates.dismiss', v_org, public._pt_branch(ctx), v_inputs, false, NULL, 'INVALID_INPUT', 'Choose two different patients.', p_a, NULL, 'customers');
  END IF;
  INSERT INTO public.customer_duplicate_dismissals (org_id, customer_id_a, customer_id_b, dismissed_by)
  VALUES (v_org, p_a, p_b, (ctx ->> 'user_id')::uuid) ON CONFLICT DO NOTHING;
  RETURN public._act_finish(ctx, 'duplicates.dismiss', v_org, public._pt_branch(ctx), v_inputs, true, jsonb_build_object('a', p_a, 'b', p_b), NULL, NULL, p_a, NULL, 'customers');
END $$;

-- "link as family" from the duplicates screen is the family action
CREATE FUNCTION public.act_duplicates_link_family(p_a uuid, p_b uuid, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN RETURN public._pt_err(ctx); END IF;
  IF NOT public._pt_ok(ctx, ARRAY['manager', 'admin']) THEN
    RETURN public._act_finish(ctx, 'duplicates.link_family', (ctx ->> 'org_id')::uuid, public._pt_branch(ctx), jsonb_build_object('a', p_a, 'b', p_b), false, NULL,
                              'FORBIDDEN', 'Only a manager or the owner can do this.', p_a, NULL, 'customers');
  END IF;
  RETURN public.act_family_link(p_a, NULL, p_b, p_ctx);
END $$;

-- duplicate candidates: members of one family are not duplicates of each other
CREATE OR REPLACE FUNCTION public.customer_duplicate_candidates(p_org_id uuid)
 RETURNS TABLE(customer_id_a uuid, customer_id_b uuid, nphone text, name_a text, name_b text, phone_a text, phone_b text, email_a text, email_b text, branch_id_a uuid, branch_id_b uuid, created_at_a timestamp with time zone, created_at_b timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF p_org_id <> get_user_org_id() THEN
    RAISE EXCEPTION 'customer_duplicate_candidates: not authorized for this organization';
  END IF;
  IF get_user_role() NOT IN ('manager', 'admin') THEN
    RAISE EXCEPTION 'customer_duplicate_candidates: requires manager or admin role';
  END IF;
  RETURN QUERY
  WITH norm AS (
    SELECT c.id, c.org_id, c.full_name, c.phone, c.email, c.branch_id, c.created_at, c.family_id,
           public.normalize_phone_e164(c.phone) AS v_nphone
    FROM public.customers c
    WHERE c.org_id = p_org_id AND c.erased_at IS NULL
  ),
  grp AS (
    SELECT v_nphone, array_agg(id ORDER BY created_at, id) AS ids
    FROM norm WHERE v_nphone IS NOT NULL GROUP BY v_nphone HAVING count(*) > 1
  ),
  pairs AS (
    SELECT g.v_nphone, a.id AS id_a, b.id AS id_b
    FROM grp g,
         LATERAL unnest(g.ids) WITH ORDINALITY AS a(id, ord_a),
         LATERAL unnest(g.ids) WITH ORDINALITY AS b(id, ord_b)
    WHERE a.ord_a < b.ord_b
  )
  SELECT p.id_a, p.id_b, p.v_nphone, na.full_name, nb.full_name, na.phone, nb.phone, na.email, nb.email, na.branch_id, nb.branch_id, na.created_at, nb.created_at
  FROM pairs p
  JOIN norm na ON na.id = p.id_a
  JOIN norm nb ON nb.id = p.id_b
  WHERE NOT (na.family_id IS NOT NULL AND na.family_id = nb.family_id)
    AND NOT EXISTS (
    SELECT 1 FROM public.customer_duplicate_dismissals d
    WHERE d.org_id = p_org_id
      AND d.customer_id_lo = LEAST(p.id_a, p.id_b)
      AND d.customer_id_hi = GREATEST(p.id_a, p.id_b)
  );
END;
$function$;

-- 6. org-scoped reads ---------------------------------------------------------------------------------------------------------
-- SECURITY INVOKER: table RLS applies. Archived and erased patients are not listed (managers may ask for archived ones to restore them).
-- No balance column here: money is a separate read (practitioners have no money access, 011 / 014); Part 1 adds it for the roles that may.
CREATE FUNCTION public.list_patients(p_branch uuid DEFAULT NULL, p_view text DEFAULT 'all', p_q text DEFAULT NULL, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0,
                                     p_archived boolean DEFAULT false)
RETURNS TABLE (id uuid, patient_no integer, full_name text, full_name_ne text, phone text, email text, gender text, date_of_birth date, home_branch_id uuid,
               family_id uuid, old_file_no text, created_at timestamptz, archived_at timestamptz, last_visit date, next_visit date, visit_count bigint,
               unconfirmed_alerts bigint, max_severity text, is_mine boolean, total_count bigint)
    LANGUAGE plpgsql STABLE SET search_path = public
    AS $$
DECLARE v_q text := NULLIF(btrim(COALESCE(p_q, '')), ''); v_digits text; v_no integer; v_like text; v_role text := public.get_user_role()::text;
BEGIN
  IF v_role IS NULL THEN RAISE EXCEPTION 'list_patients: staff only' USING ERRCODE = '42501'; END IF;
  IF p_archived AND v_role NOT IN ('manager', 'admin') THEN RAISE EXCEPTION 'list_patients: archived patients are for managers' USING ERRCODE = '42501'; END IF;
  IF p_view NOT IN ('all', 'mine', 'new') THEN RAISE EXCEPTION 'list_patients: unknown view %', p_view; END IF;
  IF v_q IS NOT NULL THEN
    v_digits := NULLIF(regexp_replace(v_q, '\D', '', 'g'), '');
    v_like := '%' || replace(replace(replace(lower(v_q), '\', '\\'), '%', '\%'), '_', '\_') || '%';
    IF v_q ~* '^p?-?\s*\d{1,9}$' THEN v_no := v_digits::integer; END IF;
  END IF;
  RETURN QUERY
  WITH base AS (
    SELECT c.* FROM public.customers c
     WHERE c.erased_at IS NULL AND (c.archived_at IS NOT NULL) = p_archived
       AND (p_branch IS NULL OR c.branch_id = p_branch)
       AND (p_view <> 'new' OR c.created_at > now() - interval '30 days')
       AND (p_view <> 'mine' OR public.is_my_patient(c.id))
       AND (v_q IS NULL
            OR lower(c.full_name) LIKE v_like ESCAPE '\'
            OR lower(COALESCE(c.full_name_ne, '')) LIKE v_like ESCAPE '\'
            OR lower(COALESCE(c.old_file_no, '')) LIKE v_like ESCAPE '\'
            OR (v_no IS NOT NULL AND c.patient_no = v_no)
            OR (v_digits IS NOT NULL AND length(v_digits) >= 3 AND regexp_replace(COALESCE(c.phone, ''), '\D', '', 'g') LIKE '%' || v_digits || '%'))
  ), counted AS (SELECT count(*) AS n FROM base)
  SELECT b.id, b.patient_no, b.full_name, b.full_name_ne, b.phone, b.email, b.gender, b.date_of_birth, b.branch_id, b.family_id, b.old_file_no, b.created_at, b.archived_at,
         (SELECT max(bk.date) FROM public.bookings bk WHERE bk.customer_id = b.id AND bk.status = 'Completed'),
         (SELECT min(bk.date) FROM public.bookings bk WHERE bk.customer_id = b.id AND bk.date >= current_date AND bk.status IN ('Pending', 'Confirmed')),
         (SELECT count(*) FROM public.bookings bk WHERE bk.customer_id = b.id AND bk.status = 'Completed'),
         (SELECT count(*) FROM public.patient_alerts a WHERE a.customer_id = b.id AND a.removed_at IS NULL AND a.confirmed_at IS NULL),
         (SELECT (array_agg(a.severity ORDER BY CASE a.severity WHEN 'danger' THEN 0 WHEN 'caution' THEN 1 ELSE 2 END))[1] FROM public.patient_alerts a WHERE a.customer_id = b.id AND a.removed_at IS NULL),
         public.is_my_patient(b.id),
         (SELECT n FROM counted)
    FROM base b
   ORDER BY b.full_name, b.patient_no
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200) OFFSET GREATEST(COALESCE(p_offset, 0), 0);
END $$;

-- by number, following a merge redirect: P-01287 or 1287
CREATE FUNCTION public.patient_lookup(p_no integer) RETURNS TABLE (id uuid, patient_no integer, redirected boolean, erased boolean)
    LANGUAGE sql STABLE SET search_path = public
    AS $$
  SELECT c.id, c.patient_no, false, c.erased_at IS NOT NULL FROM public.customers c WHERE c.org_id = public.get_user_org_id() AND c.patient_no = p_no
  UNION ALL
  SELECT c.id, c.patient_no, true, c.erased_at IS NOT NULL FROM public.patient_redirects r JOIN public.customers c ON c.id = r.customer_id
   WHERE r.org_id = public.get_user_org_id() AND r.patient_no = p_no;
$$;

-- Needs attention, sorted by next visit. Rules: an unconfirmed alert; a required form not signed in its valid window with a visit coming;
-- a last signed form over a year old; a bounced (failed) last outbound message; possible duplicates (managers and owner only).
CREATE FUNCTION public.patient_needs_attention(p_branch uuid DEFAULT NULL)
RETURNS TABLE (customer_id uuid, patient_no integer, full_name text, reason text, next_visit date)
    LANGUAGE plpgsql STABLE SET search_path = public
    AS $$
BEGIN
  IF public.get_user_role() IS NULL THEN RAISE EXCEPTION 'patient_needs_attention: staff only' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  WITH p AS (
    SELECT c.id, c.patient_no, c.full_name, c.family_id,
           (SELECT min(b.date) FROM public.bookings b WHERE b.customer_id = c.id AND b.date >= current_date AND b.status IN ('Pending', 'Confirmed')) AS nv
      FROM public.customers c
     WHERE c.erased_at IS NULL AND c.archived_at IS NULL AND (p_branch IS NULL OR c.branch_id = p_branch)
  ), r AS (
    SELECT p.id, 'unconfirmed_alert'::text AS reason FROM p WHERE EXISTS (SELECT 1 FROM public.patient_alerts a WHERE a.customer_id = p.id AND a.removed_at IS NULL AND a.confirmed_at IS NULL)
    UNION ALL
    SELECT p.id, 'form_due' FROM p WHERE p.nv IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.form_templates t WHERE t.required AND t.is_active AND (t.org_id IS NULL OR t.org_id = public.get_user_org_id())
         AND NOT EXISTS (SELECT 1 FROM public.form_submissions s WHERE s.customer_id = p.id AND s.template_id = t.id AND s.status = 'signed'
                            AND s.signed_at > now() - make_interval(days => t.valid_days)))
    UNION ALL
    SELECT p.id, 'form_old' FROM p WHERE EXISTS (SELECT 1 FROM public.form_submissions s WHERE s.customer_id = p.id AND s.status = 'signed')
       AND NOT EXISTS (SELECT 1 FROM public.form_submissions s WHERE s.customer_id = p.id AND s.status = 'signed' AND s.signed_at > now() - interval '1 year')
    UNION ALL
    SELECT p.id, 'bounced_phone' FROM p WHERE (
      SELECT m.status FROM public.messages m JOIN public.conversations cv ON cv.id = m.conversation_id
       WHERE cv.customer_id = p.id AND m.direction = 'out' AND m.kind = 'message' ORDER BY m.created_at DESC LIMIT 1) = 'failed'
    UNION ALL
    SELECT d.id, 'possible_duplicate' FROM (
      SELECT p2.id FROM p p2 JOIN public.customers c2 ON c2.id = p2.id
       WHERE public.get_user_role()::text IN ('manager', 'admin') AND public.normalize_phone_e164(c2.phone) IS NOT NULL
         AND EXISTS (SELECT 1 FROM public.customers o WHERE o.org_id = c2.org_id AND o.id <> c2.id AND o.erased_at IS NULL
                        AND public.normalize_phone_e164(o.phone) = public.normalize_phone_e164(c2.phone) AND NOT (o.family_id IS NOT NULL AND o.family_id = c2.family_id))) d
  )
  SELECT p.id, p.patient_no, p.full_name, r.reason, p.nv FROM r JOIN p ON p.id = r.id ORDER BY p.nv NULLS LAST, p.full_name, r.reason;
END $$;

-- 7. grants -------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.act_patient_create(jsonb, uuid, uuid, jsonb)', 'public.act_patient_update(uuid, jsonb, jsonb)',
    'public.act_alert_add(uuid, text, text, text, text, jsonb)', 'public.act_alert_confirm(uuid, jsonb)', 'public.act_alert_update(uuid, jsonb, jsonb)', 'public.act_alert_remove(uuid, jsonb)',
    'public.act_family_link(uuid, uuid, uuid, jsonb)', 'public.act_family_unlink(uuid, jsonb)', 'public.act_family_set_contact(uuid, uuid, jsonb)',
    'public.act_form_send_link(uuid, uuid, jsonb)', 'public.act_form_start_on_device(uuid, uuid, jsonb)', 'public.act_form_record_typed(uuid, uuid, jsonb, jsonb)',
    'public.act_consent_marketing_yes(uuid, text, text, text, jsonb)', 'public.act_patient_undo(uuid, jsonb)',
    'public.act_patient_archive(uuid, text, jsonb)', 'public.act_patient_restore(uuid, jsonb)', 'public.act_patient_erase(uuid, text, text, jsonb)',
    'public.act_duplicates_merge(uuid, uuid, jsonb)', 'public.act_duplicates_dismiss(uuid, uuid, jsonb)', 'public.act_duplicates_link_family(uuid, uuid, jsonb)',
    'public.list_patients(uuid, text, text, integer, integer, boolean)', 'public.patient_lookup(integer)', 'public.patient_needs_attention(uuid)',
    'public.patient_clinical_index(uuid)', 'public.patient_message_target(uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
  END LOOP;
  -- internals: only other functions call them
  FOREACH f IN ARRAY ARRAY[
    'public._pt_ok(jsonb, text[])', 'public._pt_branch(jsonb)', 'public._pt_err(jsonb)', 'public._pt_label(integer)', 'public._norm_name(text)',
    'public._pt_form_start(text, text, uuid, uuid, jsonb)', 'public._pt_alerts_from_answers(uuid, uuid, jsonb, jsonb)', 'public._merge_customer_rows(uuid, uuid, uuid)',
    'public._pick_customer_for_booking(uuid, text, text, text)', 'public._customers_assign_patient_no()', 'public._customers_keep_patient_no()',
    'public._customers_phone_family_guard()', 'public._messages_block_inactive_patient()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role', f);
  END LOOP;
  -- the anon booking and form surface: find / upsert (rewritten above) and the two token-only form functions
  EXECUTE 'REVOKE ALL ON FUNCTION public.find_customer_for_booking(uuid, text, text, text) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.find_customer_for_booking(uuid, text, text, text) TO anon, authenticated, service_role';
  EXECUTE 'REVOKE ALL ON FUNCTION public.public_get_form(text) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.public_get_form(text) TO anon, authenticated, service_role';
  EXECUTE 'REVOKE ALL ON FUNCTION public.public_submit_form(text, jsonb, text) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.public_submit_form(text, jsonb, text) TO anon, authenticated, service_role';
END $$;

COMMIT;
