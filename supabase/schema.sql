-- book-dental database schema
-- Types, tables, functions, triggers, indexes, and constraints.
-- Adapted from the book-spa schema: therapists -> dentists, rooms -> chairs,
-- services -> treatments. RLS policies live in rls.sql.

CREATE TYPE public.attendance_status AS ENUM (
    'Present',
    'Absent',
    'Leave',
    '1st-Half Day',
    '2nd-Half Day',
    'Annual Leave',
    'Sick Leave',
    'Day Off'
);

CREATE TYPE public.booking_status AS ENUM (
    'Pending',
    'Confirmed',
    'In-Progress',
    'Completed',
    'Cancelled',
    'No Show'
);

CREATE TYPE public.commission_basis AS ENUM (
    'vat_inclusive',
    'vat_exclusive'
);

CREATE TYPE public.discount_status_enum AS ENUM (
    'none',
    'pending',
    'approved'
);

CREATE TYPE public.user_role AS ENUM (
    'staff',
    'manager',
    'admin',
    'admin_viewer'
);

-- The outreach drain function reads its Edge Function endpoint/token from a
-- config table kept outside the `public` schema (and thus outside PostgREST's
-- exposed API / RLS surface) so the bearer token is never queryable over the
-- API. The source dump this file was reverse-engineered from never included
-- the `private` schema itself, so it's added here with the minimal shape the
-- function actually reads (see public.outreach_drain_outbox below).
CREATE SCHEMA IF NOT EXISTS private;

CREATE TABLE private.outreach_function_config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    function_base_url text NOT NULL,
    cron_bearer_token text NOT NULL,
    CONSTRAINT outreach_function_config_pkey PRIMARY KEY (id)
);

CREATE TABLE public.voucher_claims (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    voucher_id uuid NOT NULL,
    org_id uuid NOT NULL,
    redeemed_date date NOT NULL,
    guest_name_used_by text,
    treatment_claimed text,
    branch_claimed_id uuid NOT NULL,
    amount_claimed numeric(10,2) NOT NULL,
    notes text,
    performed_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    booking_id uuid,
    payment_id uuid,
    CONSTRAINT voucher_claims_amount_claimed_check CHECK ((amount_claimed > (0)::numeric))
);

CREATE FUNCTION public.compute_final_amount() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.final_amount := NEW.base_amount - NEW.discount_amount;
  RETURN NEW;
END;
$$;

CREATE TABLE public.customer_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    auth_user_id uuid NOT NULL,
    email text NOT NULL,
    phone text,
    full_name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    customer_id uuid
);

CREATE TABLE public.packages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    package_type_id uuid NOT NULL,
    treatment_id uuid,
    customer_id uuid,
    guest_name text,
    guest_info text,
    issued_date date NOT NULL,
    expiry_date date NOT NULL,
    paid_amount numeric(10,2) NOT NULL,
    sessions_total integer NOT NULL,
    package_code text,
    remarks text,
    issued_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT packages_expiry_after_issue CHECK ((expiry_date >= issued_date)),
    CONSTRAINT packages_paid_amount_check CHECK ((paid_amount >= (0)::numeric)),
    CONSTRAINT packages_sessions_total_check CHECK ((sessions_total > 0))
);

CREATE TABLE public.vouchers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    voucher_type_id uuid NOT NULL,
    voucher_code text NOT NULL,
    issued_date date NOT NULL,
    expiry_date date NOT NULL,
    guest_name text NOT NULL,
    guest_info text,
    actual_price numeric(10,2) NOT NULL,
    discount_percent numeric(5,2) DEFAULT 0 NOT NULL,
    total_amount_issued numeric(10,2) NOT NULL,
    remarks text,
    issued_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    customer_id uuid,
    CONSTRAINT vouchers_actual_price_check CHECK ((actual_price >= (0)::numeric)),
    CONSTRAINT vouchers_discount_percent_check CHECK (((discount_percent >= (0)::numeric) AND (discount_percent <= (100)::numeric))),
    CONSTRAINT vouchers_expiry_after_issue CHECK ((expiry_date >= issued_date)),
    CONSTRAINT vouchers_total_amount_issued_check CHECK ((total_amount_issued >= (0)::numeric))
);

CREATE FUNCTION public.normalize_phone_e164(p_raw text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
  v_trim   text := btrim(coalesce(p_raw, ''));
  v_plus   boolean := left(v_trim, 1) = '+';
  v_digits text := regexp_replace(v_trim, '\D', '', 'g');
BEGIN
  IF v_digits = '' THEN
    RETURN NULL;
  END IF;
  IF v_plus THEN
    RETURN '+' || v_digits;
  END IF;
  -- No explicit "+": 10 digits or fewer is a bare Nepal national number.
  IF length(v_digits) <= 10 THEN
    RETURN '+977' || v_digits;
  END IF;
  -- Longer values already carry a country code (either +977… or a real one).
  RETURN '+' || v_digits;
END;
$$;

CREATE TABLE public.bookings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    booking_number text,
    branch_id uuid NOT NULL,
    chair_id uuid,
    treatment_id uuid NOT NULL,
    dentist_id uuid,
    customer_name text NOT NULL,
    customer_email text,
    customer_phone text,
    customer_gender text,
    date date NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    start_datetime timestamp with time zone NOT NULL,
    end_datetime timestamp with time zone NOT NULL,
    status public.booking_status DEFAULT 'Pending'::public.booking_status NOT NULL,
    special_requests text,
    payment_status text DEFAULT 'unpaid'::text NOT NULL,
    base_amount numeric(10,2) NOT NULL,
    discount_amount numeric(10,2) DEFAULT 0 NOT NULL,
    final_amount numeric(10,2) NOT NULL,
    discount_status public.discount_status_enum DEFAULT 'none'::public.discount_status_enum NOT NULL,
    discount_approved_by uuid,
    discount_reason text,
    customer_id uuid,
    treatment_name_snapshot text,
    treatment_duration_snapshot integer,
    treatment_price_snapshot numeric(10,2),
    dentist_name_snapshot text,
    chair_name_snapshot text,
    is_locked boolean DEFAULT false NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    client_request_id uuid,
    discount_requested_by uuid,
    discount_requested_to uuid,
    booking_group_id uuid,
    referred_by text,
    due_holder_name text,
    referral_commission_type text,
    referral_commission_value numeric,
    customer_account_id uuid,
    referral_source text,
    referral_source_detail text,
    cancellation_reason text,
    CONSTRAINT bookings_referral_source_check CHECK (((referral_source IS NULL) OR (referral_source = ANY (ARRAY['client'::text, 'social_media'::text, 'staff'::text])))),
    CONSTRAINT chk_base_positive CHECK ((base_amount > (0)::numeric)),
    CONSTRAINT chk_discount_approval CHECK (((discount_status <> 'approved'::public.discount_status_enum) OR (discount_approved_by IS NOT NULL))),
    CONSTRAINT chk_discount_positive CHECK ((discount_amount >= (0)::numeric)),
    CONSTRAINT chk_final_amount CHECK ((final_amount = (base_amount - discount_amount))),
    CONSTRAINT chk_payment_status CHECK ((payment_status = ANY (ARRAY['unpaid'::text, 'partial'::text, 'paid'::text, 'refunded'::text]))),
    CONSTRAINT chk_referral_commission CHECK (((referral_commission_type IS NULL) OR ((referral_commission_type = ANY (ARRAY['percentage'::text, 'amount'::text])) AND (referral_commission_value IS NOT NULL) AND (referral_commission_value >= (0)::numeric) AND ((referral_commission_type <> 'percentage'::text) OR (referral_commission_value <= (100)::numeric)))))
);

CREATE FUNCTION public.can_delete_chair(p_chair_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM bookings WHERE chair_id = p_chair_id LIMIT 1
  );
$$;

CREATE FUNCTION public.can_delete_treatment(p_treatment_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM bookings WHERE treatment_id = p_treatment_id LIMIT 1
  );
$$;

CREATE FUNCTION public.can_delete_dentist(p_dentist_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM bookings WHERE dentist_id = p_dentist_id LIMIT 1
  );
$$;

CREATE FUNCTION public.enforce_booking_immutability() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  -- Locked bookings: no changes at all
  IF OLD.is_locked = true THEN
    RAISE EXCEPTION 'DAY_LOCKED: This day has been closed. No further modifications allowed.'
      USING ERRCODE = 'P0001';
  END IF;

  IF OLD.status = 'Completed' THEN
    -- Structural fields are always immutable once completed
    IF (
      NEW.status IS DISTINCT FROM OLD.status
      OR NEW.base_amount IS DISTINCT FROM OLD.base_amount
      OR NEW.dentist_id IS DISTINCT FROM OLD.dentist_id
    ) THEN
      RAISE EXCEPTION 'BOOKING_IMMUTABLE: Completed bookings cannot be modified.'
        USING ERRCODE = 'P0002';
    END IF;

    -- Discounts stay editable until payment is taken; once paid, frozen
    IF OLD.payment_status = 'paid' AND (
      NEW.discount_amount IS DISTINCT FROM OLD.discount_amount
      OR NEW.discount_status IS DISTINCT FROM OLD.discount_status
    ) THEN
      RAISE EXCEPTION 'BOOKING_IMMUTABLE: Cannot modify discount on a paid booking.'
        USING ERRCODE = 'P0002';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE FUNCTION public.generate_booking_number() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  date_part text;
  seq_num integer;
  new_number text;
BEGIN
  date_part := to_char(NEW.date, 'YYYYMMDD');

  PERFORM pg_advisory_xact_lock(hashtext('booking_number:' || date_part));

  SELECT COUNT(*) + 1 INTO seq_num
  FROM bookings
  WHERE date = NEW.date;

  new_number := 'BK-' || date_part || '-' || lpad(seq_num::text, 4, '0');

  WHILE EXISTS (SELECT 1 FROM bookings WHERE booking_number = new_number) LOOP
    seq_num := seq_num + 1;
    new_number := 'BK-' || date_part || '-' || lpad(seq_num::text, 4, '0');
  END LOOP;

  NEW.booking_number := new_number;
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.public_search_booking(p_branch_id uuid, p_query text) RETURNS SETOF public.bookings
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT b.*
  FROM public.bookings b
  WHERE b.branch_id = p_branch_id
    AND (
      b.booking_number ILIKE '%' || regexp_replace(p_query, '[,.()"\\%_]', '', 'g') || '%'
      OR b.customer_phone ILIKE '%' || regexp_replace(p_query, '[,.()"\\%_]', '', 'g') || '%'
    )
  ORDER BY b.date DESC
  LIMIT 20;
$$;

CREATE TABLE public.package_redemptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    package_id uuid NOT NULL,
    org_id uuid NOT NULL,
    redeemed_date date DEFAULT ((now() AT TIME ZONE 'Asia/Kathmandu'::text))::date NOT NULL,
    branch_id uuid,
    booking_id uuid,
    guest_name_used_by text,
    notes text,
    performed_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE FUNCTION public.trg_bookings_normalize_phone() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.customer_phone := public.normalize_phone_e164(NEW.customer_phone);
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.trg_customers_normalize_phone() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.phone := public.normalize_phone_e164(NEW.phone);
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.update_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TABLE public.attendance (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    date date NOT NULL,
    check_in timestamp with time zone DEFAULT now() NOT NULL,
    check_out timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.audit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    branch_id uuid,
    table_name text NOT NULL,
    record_id uuid,
    action_type text NOT NULL,
    old_data jsonb,
    new_data jsonb,
    changed_by uuid,
    changed_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.booking_dentists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    booking_id uuid NOT NULL,
    dentist_id uuid NOT NULL,
    assigned_at timestamp with time zone DEFAULT now(),
    start_time time without time zone,
    end_time time without time zone
);

CREATE TABLE public.branches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    address text,
    phone text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    org_id uuid NOT NULL,
    open_time time without time zone,
    close_time time without time zone,
    timezone text DEFAULT 'Asia/Kathmandu'::text,
    excluded_treatment_categories text[] DEFAULT '{}'::text[],
    online_booking_capacity integer,
    CONSTRAINT branches_online_booking_capacity_check CHECK ((online_booking_capacity > 0))
);

CREATE TABLE public.customer_duplicate_dismissals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    customer_id_a uuid NOT NULL,
    customer_id_b uuid NOT NULL,
    dismissed_by uuid,
    dismissed_at timestamp with time zone DEFAULT now() NOT NULL,
    customer_id_lo uuid GENERATED ALWAYS AS (LEAST(customer_id_a, customer_id_b)) STORED,
    customer_id_hi uuid GENERATED ALWAYS AS (GREATEST(customer_id_a, customer_id_b)) STORED
);

CREATE TABLE public.customer_merge_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    merged_id uuid NOT NULL,
    canonical_id uuid NOT NULL,
    org_id uuid,
    nphone text,
    merged_row jsonb NOT NULL,
    merged_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.customer_referral_credits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    referral_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    amount numeric(12,2) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT customer_referral_credits_amount_check CHECK ((amount > (0)::numeric))
);

CREATE TABLE public.customer_referral_debits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    amount numeric(12,2) NOT NULL,
    booking_id uuid,
    payment_id uuid,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT customer_referral_debits_amount_check CHECK ((amount > (0)::numeric))
);

CREATE TABLE public.customer_referrals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    referring_customer_id uuid NOT NULL,
    referred_customer_id uuid NOT NULL,
    booking_id uuid NOT NULL,
    reward_status text DEFAULT 'pending'::text NOT NULL,
    reward_amount numeric(12,2),
    credited_at timestamp with time zone,
    credited_by uuid,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    notes text,
    reward_type text DEFAULT 'wallet'::text NOT NULL,
    requested_reward_amount numeric(12,2),
    reward_catalog_id uuid,
    reward_label text,
    redeemed_at timestamp with time zone,
    redeemed_booking_id uuid,
    redeemed_by uuid,
    requires_manual_reward boolean DEFAULT false NOT NULL,
    CONSTRAINT customer_referrals_no_self_referral CHECK ((referring_customer_id <> referred_customer_id)),
    CONSTRAINT customer_referrals_requested_reward_amount_check CHECK (((requested_reward_amount IS NULL) OR (requested_reward_amount >= (0)::numeric))),
    CONSTRAINT customer_referrals_reward_status_check CHECK ((reward_status = ANY (ARRAY['pending'::text, 'credited'::text, 'void'::text]))),
    CONSTRAINT customer_referrals_reward_type_check CHECK ((reward_type = ANY (ARRAY['wallet'::text, 'voucher'::text])))
);

CREATE TABLE public.customers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    branch_id uuid NOT NULL,
    full_name text NOT NULL,
    phone text,
    email text,
    notes text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    org_id uuid NOT NULL,
    gender text,
    date_of_birth date
);

CREATE FUNCTION public.create_customer_account(p_org_id uuid, p_email text, p_phone text, p_full_name text) RETURNS public.customer_accounts
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;

CREATE FUNCTION public.find_customer_for_booking(p_org_id uuid, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text) RETURNS TABLE(id uuid, gender text)
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

-- Anon has no raw INSERT...RETURNING or UPDATE visibility on customers (no SELECT
-- policy, by design — customer PII must not be publicly readable). The public
-- booking flow needs to find-or-create a customer record as an unauthenticated
-- visitor, so this SECURITY DEFINER function does the find/update/insert
-- server-side and returns only the id, without ever exposing a broad SELECT
-- policy to the anon role.
CREATE FUNCTION public.upsert_customer_for_booking(
    p_org_id uuid,
    p_branch_id uuid,
    p_full_name text,
    p_phone text DEFAULT NULL::text,
    p_email text DEFAULT NULL::text,
    p_gender text DEFAULT NULL::text
) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;

-- Anon has no SELECT policy on bookings (by design — booking data must not be
-- publicly readable). createBooking() generates the id client-side and inserts
-- without RETURNING, then reads the DB-computed fields (final_amount,
-- booking_number, end_time, ...) back through this narrow, id-scoped RPC.
CREATE FUNCTION public.public_get_booking_by_id(p_booking_id uuid)
    RETURNS SETOF public.bookings
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT * FROM public.bookings WHERE id = p_booking_id;
$$;

CREATE TABLE public.daily_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    branch_id uuid NOT NULL,
    report_date date NOT NULL,
    total_bookings integer DEFAULT 0 NOT NULL,
    completed_bookings integer DEFAULT 0 NOT NULL,
    cancelled_bookings integer DEFAULT 0 NOT NULL,
    gross_revenue numeric(12,2) DEFAULT 0 NOT NULL,
    total_discounts numeric(12,2) DEFAULT 0 NOT NULL,
    net_revenue numeric(12,2) DEFAULT 0 NOT NULL,
    cash_total numeric(12,2) DEFAULT 0 NOT NULL,
    card_total numeric(12,2) DEFAULT 0 NOT NULL,
    fonepay_total numeric(12,2) DEFAULT 0 NOT NULL,
    unpaid_count integer DEFAULT 0 NOT NULL,
    closed_by uuid NOT NULL,
    closed_at timestamp with time zone DEFAULT now() NOT NULL,
    is_locked boolean DEFAULT true NOT NULL
);

CREATE TABLE public.membership_tiers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    name text NOT NULL,
    advance_amount numeric(12,2) NOT NULL,
    validity_days integer DEFAULT 365 NOT NULL,
    discount_rules jsonb DEFAULT '{}'::jsonb NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    code_prefix text DEFAULT ''::text NOT NULL,
    CONSTRAINT membership_tiers_advance_amount_check CHECK ((advance_amount > (0)::numeric)),
    CONSTRAINT membership_tiers_code_prefix_nonempty CHECK ((length(btrim(code_prefix)) > 0)),
    CONSTRAINT membership_tiers_validity_days_check CHECK ((validity_days > 0))
);

CREATE TABLE public.membership_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    membership_id uuid NOT NULL,
    org_id uuid NOT NULL,
    kind text NOT NULL,
    amount numeric(12,2) NOT NULL,
    payment_mode text,
    booking_id uuid,
    payment_id uuid,
    performed_by uuid,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    branch_id uuid,
    voucher_payment_id uuid,
    CONSTRAINT membership_transactions_amount_sign CHECK ((((kind = 'deposit'::text) AND (amount > (0)::numeric)) OR ((kind = 'deduction'::text) AND (amount < (0)::numeric)) OR ((kind = 'adjustment'::text) AND (amount <> (0)::numeric)) OR ((kind = 'birthday_perk'::text) AND (amount = (0)::numeric)) OR ((kind = 'extension'::text) AND (amount = (0)::numeric)))),
    CONSTRAINT membership_transactions_kind_check CHECK ((kind = ANY (ARRAY['deposit'::text, 'deduction'::text, 'birthday_perk'::text, 'adjustment'::text, 'extension'::text]))),
    CONSTRAINT membership_transactions_payment_mode_check CHECK (((payment_mode IS NULL) OR ((length(TRIM(BOTH FROM payment_mode)) > 0) AND (length(payment_mode) <= 40))))
);

CREATE TABLE public.memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    tier_id uuid NOT NULL,
    total_deposited numeric(12,2) DEFAULT 0 NOT NULL,
    balance numeric(12,2) DEFAULT 0 NOT NULL,
    activation_date date,
    expiry_date date,
    birthday_perk_used_at timestamp with time zone,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    membership_number text
);

CREATE FUNCTION public.membership_recompute() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_total      numeric(12,2);
  v_balance    numeric(12,2);
  v_threshold  numeric(12,2);
  v_validity   int;
  v_activation date;
  v_already    boolean;
BEGIN
  PERFORM 1 FROM public.memberships WHERE id = NEW.membership_id FOR UPDATE;

  SELECT t.advance_amount, t.validity_days, m.activation_date IS NOT NULL
    INTO v_threshold, v_validity, v_already
  FROM public.memberships m
  JOIN public.membership_tiers t ON t.id = m.tier_id
  WHERE m.id = NEW.membership_id;

  SELECT COALESCE(SUM(amount) FILTER (WHERE kind = 'deposit'), 0),
         COALESCE(SUM(amount), 0)
    INTO v_total, v_balance
  FROM public.membership_transactions
  WHERE membership_id = NEW.membership_id;

  IF v_already OR v_total < v_threshold THEN
    UPDATE public.memberships
       SET total_deposited = v_total,
           balance         = v_balance
     WHERE id = NEW.membership_id;
  ELSE
    v_activation := (now() AT TIME ZONE 'Asia/Kathmandu')::date;
    UPDATE public.memberships
       SET total_deposited = v_total,
           balance         = v_balance,
           activation_date = v_activation,
           expiry_date     = v_activation + (v_validity || ' days')::interval
     WHERE id = NEW.membership_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE FUNCTION public.set_membership_number() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_prefix text;
  v_seq    int;
BEGIN
  IF NEW.membership_number IS NOT NULL AND length(NEW.membership_number) > 0 THEN
    RETURN NEW;
  END IF;

  SELECT code_prefix INTO v_prefix
  FROM public.membership_tiers
  WHERE id = NEW.tier_id;

  IF v_prefix IS NULL OR length(v_prefix) = 0 THEN
    RAISE EXCEPTION 'set_membership_number: tier % has no code_prefix', NEW.tier_id;
  END IF;

  SELECT COALESCE(count(*), 0) + 1 INTO v_seq
  FROM public.memberships
  WHERE org_id = NEW.org_id AND tier_id = NEW.tier_id;

  NEW.membership_number := v_prefix || '-' || lpad(v_seq::text, 4, '0');
  RETURN NEW;
END;
$$;

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    type text NOT NULL,
    title text NOT NULL,
    body text,
    booking_id uuid,
    read boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.org_commission_collections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    amount_collected numeric(10,2) NOT NULL,
    collected_at date NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid NOT NULL,
    rate_percent numeric(5,2),
    commission_basis public.commission_basis,
    vat_rate_percent numeric(5,2),
    gross_sales numeric(12,2),
    expected_amount numeric(10,2),
    CONSTRAINT org_commission_collections_check CHECK ((period_end >= period_start))
);

CREATE TABLE public.org_commission_rates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    rate_percent numeric(5,2) NOT NULL,
    commission_basis public.commission_basis NOT NULL,
    vat_rate_percent numeric(5,2) DEFAULT 13.00 NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid NOT NULL,
    CONSTRAINT chk_vat_rate_sane CHECK ((vat_rate_percent <= (100)::numeric)),
    CONSTRAINT org_commission_rates_check CHECK (((effective_to IS NULL) OR (effective_to >= effective_from))),
    CONSTRAINT org_commission_rates_rate_percent_check CHECK (((rate_percent >= (0)::numeric) AND (rate_percent <= (100)::numeric))),
    CONSTRAINT org_commission_rates_vat_rate_percent_check CHECK ((vat_rate_percent >= (0)::numeric))
);

CREATE TABLE public.organizations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    code text NOT NULL,
    slug text NOT NULL,
    owner_email text,
    timezone text DEFAULT 'Asia/Kathmandu'::text,
    currency text DEFAULT 'NPR'::text,
    is_active boolean DEFAULT true,
    settings jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    referral_reward_amount numeric(12,2) DEFAULT 500 NOT NULL,
    CONSTRAINT organizations_referral_reward_amount_check CHECK ((referral_reward_amount >= (0)::numeric))
);

CREATE FUNCTION public.public_check_customer_exists(p_org_slug text, p_phone text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.customers c
    JOIN public.organizations o ON o.id = c.org_id
    WHERE o.slug = p_org_slug
      AND o.is_active = true
      AND c.is_active = true
      AND c.phone = p_phone
  );
$$;

CREATE FUNCTION public.public_find_customer_match(p_org_slug text, p_name text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text) RETURNS TABLE(customer_id uuid, full_name text, gender text, date_of_birth date)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT c.id, c.full_name, c.gender, c.date_of_birth
  FROM public.customers c
  JOIN public.organizations o ON o.id = c.org_id
  WHERE o.slug = p_org_slug
    AND o.is_active = true
    AND c.is_active = true
    AND lower(btrim(c.full_name)) = lower(btrim(coalesce(p_name, '')))
    AND btrim(coalesce(p_name, '')) <> ''
    AND (
      (p_phone IS NOT NULL AND c.phone = p_phone)
      OR (p_email IS NOT NULL AND lower(btrim(c.email)) = lower(btrim(p_email)))
    )
  ORDER BY c.created_at DESC
  LIMIT 1;
$$;

CREATE FUNCTION public.public_lookup_referrer_by_phone(p_org_slug text, p_phone text) RETURNS TABLE(id uuid, display_name text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT
    c.id,
    trim(
      split_part(c.full_name, ' ', 1)
      || CASE
           WHEN position(' ' in trim(c.full_name)) > 0
             THEN ' ' || left(trim(split_part(c.full_name, ' ', 2)), 1) || '.'
           ELSE ''
         END
    ) AS display_name
  FROM public.customers c
  JOIN public.organizations o ON o.id = c.org_id
  WHERE o.slug = p_org_slug
    AND o.is_active = true
    AND c.is_active = true
    AND c.phone = p_phone
  LIMIT 1;
$$;

CREATE FUNCTION public.public_record_customer_referral(p_org_slug text, p_referring_customer_id uuid, p_referred_customer_id uuid, p_booking_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_caller_org       uuid;
  v_referrer_org     uuid;
  v_referred_org     uuid;
  v_booking_customer uuid;
  v_booking_org      uuid;
  v_referral_id      uuid;
BEGIN
  SELECT id INTO v_caller_org
  FROM public.organizations
  WHERE slug = p_org_slug AND is_active = true;

  IF v_caller_org IS NULL THEN
    RAISE EXCEPTION 'public_record_customer_referral: organization % not found', p_org_slug;
  END IF;

  IF p_referring_customer_id = p_referred_customer_id THEN
    RAISE EXCEPTION 'public_record_customer_referral: a customer cannot refer themselves';
  END IF;

  SELECT org_id INTO v_referrer_org FROM public.customers WHERE id = p_referring_customer_id;
  SELECT org_id INTO v_referred_org FROM public.customers WHERE id = p_referred_customer_id;

  IF v_referrer_org IS NULL THEN
    RAISE EXCEPTION 'public_record_customer_referral: referring customer % not found', p_referring_customer_id;
  END IF;
  IF v_referred_org IS NULL THEN
    RAISE EXCEPTION 'public_record_customer_referral: referred customer % not found', p_referred_customer_id;
  END IF;
  IF v_referrer_org IS DISTINCT FROM v_caller_org OR v_referred_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'public_record_customer_referral: customers must be in this organization';
  END IF;

  SELECT b.customer_id, br.org_id
    INTO v_booking_customer, v_booking_org
  FROM public.bookings b
  JOIN public.branches br ON br.id = b.branch_id
  WHERE b.id = p_booking_id;

  IF v_booking_org IS NULL THEN
    RAISE EXCEPTION 'public_record_customer_referral: booking % not found', p_booking_id;
  END IF;
  IF v_booking_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'public_record_customer_referral: booking is not in this organization';
  END IF;
  IF v_booking_customer IS DISTINCT FROM p_referred_customer_id THEN
    RAISE EXCEPTION 'public_record_customer_referral: booking does not belong to the referred customer';
  END IF;

  IF EXISTS (SELECT 1 FROM public.customer_referrals WHERE referred_customer_id = p_referred_customer_id) THEN
    RAISE EXCEPTION 'public_record_customer_referral: this customer has already been referred once';
  END IF;

  INSERT INTO public.customer_referrals
    (org_id, referring_customer_id, referred_customer_id, booking_id, created_by, requires_manual_reward)
  VALUES
    (v_caller_org, p_referring_customer_id, p_referred_customer_id, p_booking_id, NULL, true)
  RETURNING id INTO v_referral_id;

  RETURN v_referral_id;
END;
$$;

CREATE TABLE public.outreach_ai_config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    ai_enabled boolean DEFAULT false NOT NULL,
    chatbot_enabled boolean DEFAULT false NOT NULL,
    monthly_token_budget integer DEFAULT 0 NOT NULL,
    tokens_used_this_period integer DEFAULT 0 NOT NULL,
    period_started_at timestamp with time zone DEFAULT now() NOT NULL,
    model text DEFAULT 'claude-sonnet-5'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE FUNCTION public.outreach_ai_consume(p_org_id uuid, p_tokens integer) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_row     public.outreach_ai_config;
  v_allowed boolean := false;
BEGIN
  IF p_tokens IS NULL OR p_tokens < 0 THEN
    RAISE EXCEPTION 'outreach_ai_consume: p_tokens must be a non-negative integer';
  END IF;

  SELECT * INTO v_row
  FROM public.outreach_ai_config
  WHERE org_id = p_org_id
  FOR UPDATE;

  IF v_row IS NULL THEN
    RETURN false;
  END IF;

  -- Reset the rolling 30-day period if it has elapsed.
  IF now() - v_row.period_started_at > interval '30 days' THEN
    UPDATE public.outreach_ai_config
       SET tokens_used_this_period = 0,
           period_started_at = now()
     WHERE org_id = p_org_id
    RETURNING * INTO v_row;
  END IF;

  IF v_row.tokens_used_this_period + p_tokens <= v_row.monthly_token_budget THEN
    UPDATE public.outreach_ai_config
       SET tokens_used_this_period = tokens_used_this_period + p_tokens,
           updated_at = now()
     WHERE org_id = p_org_id;
    v_allowed := true;
  END IF;

  RETURN v_allowed;
END;
$$;

CREATE TABLE public.outreach_drafts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    message_id uuid NOT NULL,
    model text,
    input_tokens integer,
    output_tokens integer,
    ai_raw jsonb,
    edited_subject text,
    edited_body text,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.outreach_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    rule_id uuid,
    customer_id uuid NOT NULL,
    booking_id uuid,
    channel text NOT NULL,
    to_address text NOT NULL,
    subject text,
    body text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    source text DEFAULT 'template'::text NOT NULL,
    provider text,
    provider_message_id text,
    error text,
    dedupe_key text NOT NULL,
    scheduled_for timestamp with time zone DEFAULT now() NOT NULL,
    sent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT outreach_messages_channel_check CHECK ((channel = ANY (ARRAY['email'::text, 'sms'::text, 'whatsapp'::text]))),
    CONSTRAINT outreach_messages_source_check CHECK ((source = ANY (ARRAY['template'::text, 'ai'::text]))),
    CONSTRAINT outreach_messages_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'review'::text, 'approved'::text, 'sending'::text, 'sent'::text, 'delivered'::text, 'failed'::text, 'cancelled'::text])))
);

CREATE FUNCTION public.outreach_drain_outbox() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_cfg          private.outreach_function_config;
  v_msg          record;
  v_count        integer := 0;
  v_request_id   bigint;
BEGIN
  -- Stale-send requeue: any row stuck in 'sending' for >10 minutes (the
  -- Edge Function call fired but we never heard back — fire-and-forget risk
  -- per the design doc) goes back to 'queued' so the next drain retries it.
  UPDATE public.outreach_messages
     SET status = 'queued',
         updated_at = now()
   WHERE status = 'sending'
     AND updated_at < now() - interval '10 minutes';

  SELECT * INTO v_cfg FROM private.outreach_function_config LIMIT 1;
  IF v_cfg IS NULL THEN
    -- No provider config yet (e.g. fresh environment before the operator
    -- seeds private.outreach_function_config) — nothing to drain.
    RETURN 0;
  END IF;

  FOR v_msg IN
    SELECT id
    FROM public.outreach_messages
    WHERE status IN ('queued', 'approved')
      AND scheduled_for <= now()
    ORDER BY scheduled_for
    LIMIT 50
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.outreach_messages
       SET status = 'sending',
           updated_at = now()
     WHERE id = v_msg.id;

    SELECT net.http_post(
      url     := v_cfg.function_base_url || '/send-message',
      headers := jsonb_build_object(
                   'Authorization', 'Bearer ' || v_cfg.cron_bearer_token,
                   'Content-Type', 'application/json'
                 ),
      body    := jsonb_build_object('message_id', v_msg.id)
    ) INTO v_request_id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

CREATE TABLE public.outreach_provider_config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    channel text NOT NULL,
    provider text NOT NULL,
    from_address text,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT outreach_provider_config_channel_check CHECK ((channel = ANY (ARRAY['email'::text, 'sms'::text, 'whatsapp'::text])))
);

CREATE TABLE public.outreach_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    trigger_type text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    channel text NOT NULL,
    template_id uuid NOT NULL,
    send_mode text DEFAULT 'review'::text NOT NULL,
    use_ai boolean DEFAULT false NOT NULL,
    lapsed_days integer,
    review_delay_hours integer DEFAULT 24,
    renewal_days_before integer,
    rebooking_interval_days integer,
    birthday_lead_days integer,
    quiet_hours jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT outreach_rules_channel_check CHECK ((channel = ANY (ARRAY['email'::text, 'sms'::text, 'whatsapp'::text]))),
    CONSTRAINT outreach_rules_send_mode_check CHECK ((send_mode = ANY (ARRAY['auto'::text, 'review'::text]))),
    CONSTRAINT outreach_rules_trigger_type_check CHECK ((trigger_type = ANY (ARRAY['win_back'::text, 'review_request'::text, 'renewal_reminder'::text, 'birthday'::text, 'rebooking'::text])))
);

CREATE TABLE public.outreach_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    branch_id uuid,
    key text NOT NULL,
    channel text NOT NULL,
    subject text,
    body text NOT NULL,
    whatsapp_template_name text,
    whatsapp_template_lang text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT outreach_templates_channel_check CHECK ((channel = ANY (ARRAY['email'::text, 'sms'::text, 'whatsapp'::text])))
);

CREATE FUNCTION public.outreach_enqueue_for_completed(p_booking_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;

CREATE VIEW public.package_balances WITH (security_invoker='true') AS
 SELECT p.id AS package_id,
    p.org_id,
    p.branch_id,
    p.package_type_id,
    p.treatment_id,
    p.customer_id,
    p.guest_name,
    p.guest_info,
    p.expiry_date,
    p.sessions_total,
    COALESCE(r.sessions_used, (0)::bigint) AS sessions_used,
    (p.sessions_total - COALESCE(r.sessions_used, (0)::bigint)) AS sessions_remaining,
        CASE
            WHEN ((p.expiry_date < ((now() AT TIME ZONE 'Asia/Kathmandu'::text))::date) AND ((p.sessions_total - COALESCE(r.sessions_used, (0)::bigint)) > 0)) THEN 'expired'::text
            WHEN (COALESCE(r.sessions_used, (0)::bigint) = 0) THEN 'unused'::text
            WHEN ((p.sessions_total - COALESCE(r.sessions_used, (0)::bigint)) <= 0) THEN 'fully_redeemed'::text
            ELSE 'partially_used'::text
        END AS status,
    r.last_redeemed_date
   FROM (public.packages p
     LEFT JOIN ( SELECT package_redemptions.package_id,
            count(*) AS sessions_used,
            max(package_redemptions.redeemed_date) AS last_redeemed_date
           FROM public.package_redemptions
          GROUP BY package_redemptions.package_id) r ON ((r.package_id = p.id)));

CREATE TABLE public.package_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    treatment_id uuid,
    name text NOT NULL,
    default_sessions integer,
    standard_price numeric(10,2),
    validity_days integer DEFAULT 365 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    display_order integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.payment_refunds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    booking_id uuid NOT NULL,
    org_id uuid NOT NULL,
    amount numeric(10,2) NOT NULL,
    refunded_by uuid,
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT payment_refunds_amount_check CHECK ((amount > (0)::numeric))
);

CREATE TABLE public.payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    booking_id uuid NOT NULL,
    amount numeric(10,2) NOT NULL,
    payment_mode text NOT NULL,
    recorded_by uuid NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT payments_payment_mode_check CHECK (((payment_mode IS NOT NULL) AND (length(TRIM(BOTH FROM payment_mode)) > 0) AND (length(payment_mode) <= 40)))
);

CREATE FUNCTION public.handle_booking_cancellation_refund() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
  v_amount  numeric(10,2);
  v_org_id  uuid;
BEGIN
  IF NEW.status = 'Cancelled'
     AND OLD.status IS DISTINCT FROM 'Cancelled'
     AND OLD.payment_status IN ('paid', 'partial') THEN

    SELECT COALESCE(SUM(amount), 0) INTO v_amount
    FROM public.payments
    WHERE booking_id = NEW.id;

    IF v_amount > 0 THEN
      SELECT br.org_id INTO v_org_id
      FROM public.branches br
      WHERE br.id = NEW.branch_id;

      INSERT INTO public.payment_refunds (booking_id, org_id, amount, refunded_by, reason)
      VALUES (NEW.id, v_org_id, v_amount, auth.uid(), 'Full refund on booking cancellation');

      NEW.payment_status := 'refunded';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE FUNCTION public.platform_org_branch_breakdown(p_org_id uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  WITH by_branch AS (
    SELECT br.id AS branch_id, br.name AS branch_name, SUM(pmt.amount) AS gross
    FROM public.payments pmt
    JOIN public.bookings bk ON bk.id = pmt.booking_id
    JOIN public.branches br ON br.id = bk.branch_id
    WHERE br.org_id = p_org_id
      AND bk.payment_status = 'paid'
      AND bk.date BETWEEN p_from AND p_to
      AND pmt.payment_mode NOT IN ('Membership','ReferralWallet','VoucherWallet','ReferralVoucher','SessionPackage')
    GROUP BY br.id, br.name
    UNION ALL
    SELECT v.branch_id, br.name, SUM(v.actual_price)
    FROM public.vouchers v JOIN public.branches br ON br.id = v.branch_id
    WHERE v.org_id = p_org_id AND v.issued_date BETWEEN p_from AND p_to
    GROUP BY v.branch_id, br.name
    UNION ALL
    -- membership_transactions has no branch_id -> org-level bucket
    SELECT NULL::uuid, '— (org-level)', SUM(mt.amount)
    FROM public.membership_transactions mt
    WHERE mt.org_id = p_org_id AND mt.kind = 'deposit'
      AND (mt.created_at AT TIME ZONE 'Asia/Kathmandu')::date BETWEEN p_from AND p_to
    HAVING SUM(mt.amount) > 0
  ),
  rolled AS (
    SELECT branch_id, MAX(branch_name) AS branch_name, SUM(gross) AS gross
    FROM by_branch WHERE gross IS NOT NULL AND gross <> 0
    GROUP BY branch_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'branch_id', branch_id, 'branch_name', branch_name, 'gross', gross) ORDER BY gross DESC), '[]'::jsonb)
  FROM rolled;
$$;

CREATE FUNCTION public.platform_org_sales_base(p_org_id uuid, p_from date, p_to date) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  WITH booking_income AS (
    -- Component 1: real (non-wallet) payments against paid, non-refunded bookings,
    -- at the payments grain (handles split tenders). Bucketed by booking.date.
    SELECT COALESCE(SUM(pmt.amount), 0) AS amt
    FROM public.payments pmt
    JOIN public.bookings bk ON bk.id = pmt.booking_id
    JOIN public.branches br ON br.id = bk.branch_id
    WHERE br.org_id = p_org_id
      AND bk.payment_status = 'paid'
      AND bk.date BETWEEN p_from AND p_to
      AND pmt.payment_mode NOT IN ('Membership','ReferralWallet','VoucherWallet','ReferralVoucher','SessionPackage')
  ),
  voucher_income AS (
    -- Component 2: money paid to buy vouchers, bucketed by issued_date.
    SELECT COALESCE(SUM(v.actual_price), 0) AS amt
    FROM public.vouchers v
    WHERE v.org_id = p_org_id
      AND v.issued_date BETWEEN p_from AND p_to
  ),
  membership_income AS (
    -- Component 3: membership wallet top-ups (deposits only), by created_at date.
    SELECT COALESCE(SUM(mt.amount), 0) AS amt
    FROM public.membership_transactions mt
    WHERE mt.org_id = p_org_id
      AND mt.kind = 'deposit'
      AND (mt.created_at AT TIME ZONE 'Asia/Kathmandu')::date BETWEEN p_from AND p_to
  )
  SELECT (SELECT amt FROM booking_income)
       + (SELECT amt FROM voucher_income)
       + (SELECT amt FROM membership_income);
$$;

CREATE FUNCTION public.update_booking_payment_status() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_paid  numeric;
  v_final numeric;
BEGIN
  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM public.payments WHERE booking_id = NEW.booking_id;

  SELECT final_amount INTO v_final
  FROM public.bookings WHERE id = NEW.booking_id;

  UPDATE public.bookings
  SET payment_status = CASE
        WHEN v_paid >= v_final THEN 'paid'
        WHEN v_paid > 0        THEN 'partial'
        ELSE 'unpaid'
      END
  WHERE id = NEW.booking_id;

  RETURN NEW;
END;
$$;

CREATE TABLE public.payroll_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    payroll_run_id uuid NOT NULL,
    dentist_id uuid NOT NULL,
    dentist_name text NOT NULL,
    monthly_salary numeric DEFAULT 0 NOT NULL,
    commission_rate numeric DEFAULT 0 NOT NULL,
    days_in_month integer NOT NULL,
    present_days integer DEFAULT 0 NOT NULL,
    absent_days numeric DEFAULT 0 NOT NULL,
    half_days integer DEFAULT 0 NOT NULL,
    leave_days integer DEFAULT 0 NOT NULL,
    attendance_deduction numeric DEFAULT 0 NOT NULL,
    treatment_revenue numeric DEFAULT 0 NOT NULL,
    treatment_commission numeric DEFAULT 0 NOT NULL,
    referral_commission numeric DEFAULT 0 NOT NULL,
    net_pay numeric DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    unpaid_leave_days numeric DEFAULT 0 NOT NULL
);

CREATE TABLE public.payroll_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    branch_id uuid NOT NULL,
    period_month date NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    total_net numeric DEFAULT 0 NOT NULL,
    generated_by uuid,
    generated_at timestamp with time zone DEFAULT now() NOT NULL,
    finalized_by uuid,
    finalized_at timestamp with time zone,
    CONSTRAINT payroll_runs_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'finalized'::text])))
);

CREATE FUNCTION public.enforce_payroll_immutability() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  IF TG_TABLE_NAME = 'payroll_items' THEN
    IF EXISTS (
      SELECT 1 FROM public.payroll_runs
      WHERE id = COALESCE(OLD.payroll_run_id, NEW.payroll_run_id)
        AND status = 'finalized'
    ) THEN
      RAISE EXCEPTION 'PAYROLL_FINALIZED: This payroll run has been finalized and cannot be changed.'
        USING ERRCODE = 'P0003';
    END IF;
  END IF;

  IF TG_TABLE_NAME = 'payroll_runs' THEN
    IF OLD.status = 'finalized' THEN
      RAISE EXCEPTION 'PAYROLL_FINALIZED: This payroll run has been finalized and cannot be changed.'
        USING ERRCODE = 'P0003';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

CREATE TABLE public.platform_admins (
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE FUNCTION public.is_platform_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.platform_admins WHERE user_id = auth.uid()
  );
$$;

CREATE FUNCTION public.platform_commission_for_range(p_org_id uuid, p_from date, p_to date) RETURNS numeric
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kathmandu')::date;
  r RECORD;
  v_overlap_from date;
  v_overlap_to   date;
  v_base numeric;
  v_total numeric := 0;
  v_any boolean := false;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  FOR r IN
    SELECT rate_percent, commission_basis, vat_rate_percent, effective_from, effective_to
    FROM public.org_commission_rates
    WHERE org_id = p_org_id
  LOOP
    v_overlap_from := GREATEST(p_from, r.effective_from);
    v_overlap_to   := LEAST(p_to, COALESCE(r.effective_to, v_today));
    IF v_overlap_from <= v_overlap_to THEN
      v_any := true;
      v_base := public.platform_org_sales_base(p_org_id, v_overlap_from, v_overlap_to);
      IF r.commission_basis = 'vat_exclusive' THEN
        v_base := v_base / (1 + r.vat_rate_percent / 100.0);
      END IF;
      v_total := v_total + v_base * r.rate_percent / 100.0;
    END IF;
  END LOOP;
  IF NOT v_any THEN RETURN NULL; END IF;
  RETURN round(v_total, 2);
END $$;

CREATE FUNCTION public.platform_get_org_membership_deposits(p_org_id uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(jsonb_agg(row_obj ORDER BY (row_obj->>'date') DESC), '[]'::jsonb) INTO v
  FROM (
    SELECT jsonb_build_object(
      'date', (mt.created_at AT TIME ZONE 'Asia/Kathmandu')::date,
      'branch_name', br.name,
      'customer_name', c.full_name,
      'amount', mt.amount,
      'notes', mt.notes
    ) AS row_obj
    FROM public.membership_transactions mt
    JOIN public.memberships m ON m.id = mt.membership_id
    JOIN public.customers c   ON c.id = m.customer_id
    JOIN public.branches br   ON br.id = c.branch_id
    WHERE mt.org_id = p_org_id
      AND mt.kind = 'deposit'
      AND (mt.created_at AT TIME ZONE 'Asia/Kathmandu')::date BETWEEN p_from AND p_to
  ) sub;
  RETURN v;
END $$;

CREATE FUNCTION public.platform_get_org_voucher_sales(p_org_id uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(jsonb_agg(row_obj ORDER BY (row_obj->>'date') DESC), '[]'::jsonb) INTO v
  FROM (
    SELECT jsonb_build_object(
      'date', v.issued_date,
      'branch_name', br.name,
      'guest_name', v.guest_name,
      'voucher_code', v.voucher_code,
      'amount', v.actual_price
    ) AS row_obj
    FROM public.vouchers v
    JOIN public.branches br ON br.id = v.branch_id
    WHERE v.org_id = p_org_id
      AND v.issued_date BETWEEN p_from AND p_to
  ) sub;
  RETURN v;
END $$;

CREATE FUNCTION public.platform_list_collections(p_org_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.collected_at DESC), '[]'::jsonb)
    INTO v FROM public.org_commission_collections c WHERE c.org_id = p_org_id;
  RETURN v;
END $$;

CREATE FUNCTION public.platform_list_rates(p_org_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.effective_from DESC), '[]'::jsonb)
    INTO v FROM public.org_commission_rates r WHERE r.org_id = p_org_id;
  RETURN v;
END $$;

CREATE FUNCTION public.platform_preview_blended_commission(p_org_id uuid, p_period_start date, p_period_end date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_gross  numeric;
  v_amount numeric;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_period_end < p_period_start THEN
    RAISE EXCEPTION 'period_end (%) cannot be before period_start (%)', p_period_end, p_period_start
      USING ERRCODE = '22007';
  END IF;

  v_gross  := public.platform_org_sales_base(p_org_id, p_period_start, p_period_end);
  v_amount := public.platform_commission_for_range(p_org_id, p_period_start, p_period_end);

  RETURN jsonb_build_object('gross_sales', v_gross, 'amount', v_amount);
END $$;

CREATE FUNCTION public.platform_record_collection(p_org_id uuid, p_period_start date, p_period_end date, p_amount numeric, p_collected_at date, p_notes text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.org_commission_collections
    (org_id, period_start, period_end, amount_collected, collected_at, notes, created_by)
  VALUES (p_org_id, p_period_start, p_period_end, p_amount, p_collected_at, p_notes, auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION public.platform_set_commission_rate(p_org_id uuid, p_rate numeric, p_basis text, p_vat_rate numeric, p_effective_from date) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_open      public.org_commission_rates%ROWTYPE;
  v_latest    public.org_commission_rates%ROWTYPE;
  v_new_id    uuid;
  v_row_count int;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_open FROM public.org_commission_rates
   WHERE org_id = p_org_id AND effective_to IS NULL
   ORDER BY effective_from DESC LIMIT 1;

  IF FOUND THEN
    IF p_effective_from < v_open.effective_from THEN
      SELECT count(*) INTO v_row_count FROM public.org_commission_rates WHERE org_id = p_org_id;
      IF v_row_count > 1 THEN
        RAISE EXCEPTION 'new effective_from (%) cannot be before the current rate''s effective_from (%) — earlier history already exists for this org',
          p_effective_from, v_open.effective_from USING ERRCODE = '22007';
      END IF;
      -- Sole row for this org: widen it backward in place, no history to conflict with.
      UPDATE public.org_commission_rates
         SET rate_percent = p_rate,
             commission_basis = p_basis::public.commission_basis,
             vat_rate_percent = COALESCE(p_vat_rate, 13.00),
             effective_from = p_effective_from
       WHERE id = v_open.id
      RETURNING id INTO v_new_id;
      RETURN v_new_id;
    ELSIF p_effective_from = v_open.effective_from THEN
      UPDATE public.org_commission_rates
         SET rate_percent = p_rate,
             commission_basis = p_basis::public.commission_basis,
             vat_rate_percent = COALESCE(p_vat_rate, 13.00)
       WHERE id = v_open.id
      RETURNING id INTO v_new_id;
      RETURN v_new_id;
    ELSE
      UPDATE public.org_commission_rates
         SET effective_to = p_effective_from - 1
       WHERE id = v_open.id;
    END IF;
  ELSE
    -- No open rate for this org. Still guard against an out-of-order/
    -- overlapping insert if MULTIPLE closed segments exist — same row-count
    -- exception as the open-row branch above (a sole row, open or closed,
    -- has no earlier history to conflict with, so backdating past it is
    -- unambiguous; only >1 rows makes the ordering matter).
    SELECT * INTO v_latest FROM public.org_commission_rates
     WHERE org_id = p_org_id
     ORDER BY effective_from DESC LIMIT 1;
    IF FOUND AND p_effective_from < v_latest.effective_from THEN
      SELECT count(*) INTO v_row_count FROM public.org_commission_rates WHERE org_id = p_org_id;
      IF v_row_count > 1 THEN
        RAISE EXCEPTION 'new effective_from (%) cannot be before the most recent rate''s effective_from (%) — earlier history already exists for this org',
          p_effective_from, v_latest.effective_from USING ERRCODE = '22007';
      END IF;
    END IF;
  END IF;

  INSERT INTO public.org_commission_rates
    (org_id, rate_percent, commission_basis, vat_rate_percent, effective_from, created_by)
  VALUES
    (p_org_id, p_rate, p_basis::public.commission_basis, COALESCE(p_vat_rate, 13.00), p_effective_from, auth.uid())
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END $$;

CREATE FUNCTION public.platform_collect_commission(p_org_id uuid, p_period_start date, p_period_end date, p_rate numeric, p_basis text, p_vat_rate numeric, p_collected_at date, p_notes text, p_actual_amount numeric DEFAULT NULL::numeric) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_amount      numeric;
  v_gross       numeric;
  v_actual      numeric;
  v_id          uuid;
  v_rate_stored numeric;
  v_basis_stored text;
  v_vat_stored  numeric;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_period_end < p_period_start THEN
    RAISE EXCEPTION 'period_end (%) cannot be before period_start (%)', p_period_end, p_period_start
      USING ERRCODE = '22007';
  END IF;

  BEGIN
    PERFORM public.platform_set_commission_rate(p_org_id, p_rate, p_basis, p_vat_rate, p_period_start);
    v_rate_stored := p_rate;
    v_basis_stored := p_basis;
    v_vat_stored := p_vat_rate;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22007' THEN
      -- Backdating into established rate history — leave the rate table
      -- untouched; the collection amount still comes out correct via
      -- platform_commission_for_range's per-segment blend below.
      v_rate_stored := NULL;
      v_basis_stored := NULL;
      v_vat_stored := NULL;
    ELSE
      RAISE;
    END IF;
  END;

  v_gross  := public.platform_org_sales_base(p_org_id, p_period_start, p_period_end);
  v_amount := public.platform_commission_for_range(p_org_id, p_period_start, p_period_end);
  v_actual := COALESCE(p_actual_amount, v_amount);

  INSERT INTO public.org_commission_collections
    (org_id, period_start, period_end, amount_collected, expected_amount, collected_at, notes,
     rate_percent, commission_basis, vat_rate_percent, gross_sales, created_by)
  VALUES
    (p_org_id, p_period_start, p_period_end, v_actual, v_amount, p_collected_at, p_notes,
     v_rate_stored, v_basis_stored::public.commission_basis, v_vat_stored, v_gross, auth.uid())
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'amount_collected', v_actual, 'expected_amount', v_amount, 'gross_sales', v_gross,
    'rate_blended', v_rate_stored IS NULL);
END $$;

CREATE TABLE public.reward_catalog (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    reward_type text NOT NULL,
    name text NOT NULL,
    value numeric(12,2),
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT reward_catalog_reward_type_check CHECK ((reward_type = 'voucher'::text)),
    CONSTRAINT reward_catalog_value_check CHECK (((value IS NULL) OR (value >= (0)::numeric)))
);

CREATE TABLE public.chairs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    branch_id uuid NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    display_order integer DEFAULT 0 NOT NULL,
    amenities text[] DEFAULT '{}'::text[],
    floor text,
    capacity integer DEFAULT 1 NOT NULL,
    requires_dentist boolean DEFAULT true NOT NULL,
    CONSTRAINT chairs_capacity_check CHECK ((capacity > 0))
);

-- SECURITY DEFINER is required for correctness, not just defense-in-depth: this
-- function's own capacity-counting SELECT is otherwise subject to the RLS of
-- whichever role triggered it. The anon role (public booking flow) has no
-- SELECT policy on bookings, so under SECURITY INVOKER this query would see
-- zero existing rows and the capacity check would silently never fire for
-- anonymous customers — the exact case double-booking prevention matters most.
CREATE FUNCTION public.check_chair_capacity() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_capacity integer;
  v_occupied integer;
BEGIN
  IF NEW.chair_id IS NULL OR NEW.status IN ('Cancelled', 'No Show') THEN
    RETURN NEW;
  END IF;

  -- Serialize all concurrent writers targeting this chair/date for the rest of this transaction —
  -- this is what closes the count-then-insert race window a plain SELECT count() can't.
  PERFORM pg_advisory_xact_lock(hashtext(NEW.chair_id::text || NEW.date::text));

  SELECT capacity INTO v_capacity FROM chairs WHERE id = NEW.chair_id;

  SELECT count(*) INTO v_occupied
  FROM bookings b
  WHERE b.chair_id = NEW.chair_id
    AND b.status NOT IN ('Cancelled', 'No Show')
    AND (TG_OP = 'INSERT' OR b.id != NEW.id)
    AND tstzrange(b.start_datetime, b.end_datetime) && tstzrange(NEW.start_datetime, NEW.end_datetime);

  IF v_occupied >= COALESCE(v_capacity, 1) THEN
    RAISE EXCEPTION 'CHAIR_AT_CAPACITY: Chair is fully booked for this time range.'
      USING ERRCODE = 'P0003';
  END IF;

  RETURN NEW;
END;
$$;

CREATE FUNCTION public.enforce_dentist_for_active_bookings() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.status IN ('In-Progress', 'Completed')
     AND NEW.dentist_id IS NULL
     AND COALESCE((SELECT r.requires_dentist FROM chairs r WHERE r.id = NEW.chair_id), true) THEN
    RAISE EXCEPTION
      'DENTIST_REQUIRED: Bookings with status "%" must have a dentist assigned.',
      NEW.status
      USING ERRCODE = 'P0003';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TABLE public.schema_migrations (
    version text NOT NULL,
    name text,
    applied_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.treatment_categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    display_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.treatments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    duration_minutes integer NOT NULL,
    price_npr numeric(10,2) NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    org_id uuid NOT NULL,
    category text,
    image_url text
);

CREATE FUNCTION public.compute_booking_datetimes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  svc_duration integer;
BEGIN
  -- Fetch treatment duration
  SELECT duration_minutes INTO svc_duration
  FROM treatments
  WHERE id = NEW.treatment_id;

  IF svc_duration IS NULL THEN
    RAISE EXCEPTION 'Treatment not found: %', NEW.treatment_id;
  END IF;

  -- Compute end_time from start_time + duration
  NEW.end_time := NEW.start_time + (svc_duration * interval '1 minute');

  -- Compute timestamptz values (Nepal timezone: Asia/Kathmandu = UTC+5:45)
  NEW.start_datetime := (NEW.date + NEW.start_time) AT TIME ZONE 'Asia/Kathmandu';
  NEW.end_datetime := (NEW.date + NEW.end_time) AT TIME ZONE 'Asia/Kathmandu';

  RETURN NEW;
END;
$$;

CREATE FUNCTION public.platform_get_org_bookings(p_org_id uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(jsonb_agg(row_obj ORDER BY (row_obj->>'date') DESC), '[]'::jsonb) INTO v
  FROM (
    SELECT jsonb_build_object(
      'booking_id', bk.id,
      'booking_number', bk.booking_number,
      'date', bk.date,
      'branch_name', br.name,
      'treatment_name', s.name,
      'category', s.category,
      'final_amount', bk.final_amount,
      'payment_status', bk.payment_status,
      'status', bk.status,
      'payments', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('amount', p2.amount, 'payment_mode', p2.payment_mode)), '[]'::jsonb)
        FROM public.payments p2 WHERE p2.booking_id = bk.id
      )
    ) AS row_obj
    FROM public.bookings bk
    JOIN public.branches br ON br.id = bk.branch_id
    JOIN public.treatments s  ON s.id = bk.treatment_id
    WHERE br.org_id = p_org_id
      AND bk.date BETWEEN p_from AND p_to
  ) sub;
  RETURN v;
END $$;

CREATE FUNCTION public.platform_org_category_breakdown(p_org_id uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  WITH cats AS (
    SELECT s.category AS category, SUM(pmt.amount) AS gross
    FROM public.payments pmt
    JOIN public.bookings bk ON bk.id = pmt.booking_id
    JOIN public.branches br ON br.id = bk.branch_id
    JOIN public.treatments s  ON s.id = bk.treatment_id
    WHERE br.org_id = p_org_id
      AND bk.payment_status = 'paid'
      AND bk.date BETWEEN p_from AND p_to
      AND pmt.payment_mode NOT IN ('Membership','ReferralWallet','VoucherWallet','ReferralVoucher','SessionPackage')
    GROUP BY s.category
    UNION ALL
    SELECT 'Voucher sales', SUM(v.actual_price)
    FROM public.vouchers v
    WHERE v.org_id = p_org_id AND v.issued_date BETWEEN p_from AND p_to
    HAVING SUM(v.actual_price) > 0
    UNION ALL
    SELECT 'Membership deposits', SUM(mt.amount)
    FROM public.membership_transactions mt
    WHERE mt.org_id = p_org_id AND mt.kind = 'deposit'
      AND (mt.created_at AT TIME ZONE 'Asia/Kathmandu')::date BETWEEN p_from AND p_to
    HAVING SUM(mt.amount) > 0
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('category', category, 'gross', gross) ORDER BY gross DESC), '[]'::jsonb)
  FROM cats WHERE gross IS NOT NULL AND gross <> 0;
$$;

CREATE FUNCTION public.platform_get_revenue_rollup(p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kathmandu')::date;
  v_result jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(org_obj ORDER BY org_name), '[]'::jsonb) INTO v_result
  FROM (
    SELECT
      jsonb_build_object(
        'org_id', o.id,
        'org_name', o.name,
        'gross_total', public.platform_org_sales_base(o.id, p_from, p_to),
        'revenue_by_category', public.platform_org_category_breakdown(o.id, p_from, p_to),
        'revenue_by_branch',   public.platform_org_branch_breakdown(o.id, p_from, p_to),
        'active_rate_percent',     ar.rate_percent,
        'active_commission_basis', ar.commission_basis,
        'commission_for_range',    public.platform_commission_for_range(o.id, p_from, p_to),
        'commission_owed_to_date', owed_l.owed,
        'collected_to_date',       COALESCE(coll.total, 0),
        'net_owed',                CASE WHEN owed_l.owed IS NULL THEN NULL
                                        ELSE owed_l.owed - COALESCE(coll.total, 0) END
      ) AS org_obj,
      o.name AS org_name
    FROM public.organizations o
    LEFT JOIN LATERAL (
      SELECT rate_percent, commission_basis
      FROM public.org_commission_rates
      WHERE org_id = o.id AND effective_to IS NULL
      ORDER BY effective_from DESC LIMIT 1
    ) ar ON true
    LEFT JOIN LATERAL (
      SELECT MIN(effective_from) AS first_from
      FROM public.org_commission_rates WHERE org_id = o.id
    ) fr ON true
    LEFT JOIN LATERAL (
      SELECT CASE WHEN fr.first_from IS NULL THEN NULL
                  ELSE public.platform_commission_for_range(o.id, fr.first_from, v_today) END AS owed
    ) owed_l ON true
    LEFT JOIN LATERAL (
      SELECT SUM(amount_collected) AS total
      FROM public.org_commission_collections WHERE org_id = o.id
    ) coll ON true
    WHERE o.is_active
       OR EXISTS (SELECT 1 FROM public.org_commission_rates r WHERE r.org_id = o.id)
  ) sub;

  RETURN v_result;
END $$;

CREATE TABLE public.treatment_notes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    booking_id uuid,
    customer_id uuid,
    dentist_id uuid,
    note text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.staff_compensation (
    dentist_id uuid NOT NULL,
    monthly_salary numeric DEFAULT 0 NOT NULL,
    commission_rate numeric DEFAULT 0 NOT NULL,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT staff_compensation_commission_rate_check CHECK (((commission_rate >= (0)::numeric) AND (commission_rate <= (100)::numeric))),
    CONSTRAINT staff_compensation_monthly_salary_check CHECK ((monthly_salary >= (0)::numeric))
);

CREATE TABLE public.dentist_attendance (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    branch_id uuid NOT NULL,
    dentist_id uuid NOT NULL,
    date date NOT NULL,
    status public.attendance_status DEFAULT 'Present'::public.attendance_status NOT NULL,
    check_in_time timestamp with time zone,
    check_out_time timestamp with time zone,
    notes text,
    marked_by uuid,
    created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.dentists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    branch_id uuid NOT NULL,
    name text NOT NULL,
    gender text NOT NULL,
    specialties text[] DEFAULT '{}'::text[],
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    display_order integer DEFAULT 0 NOT NULL,
    "position" text,
    is_treatment_staff boolean DEFAULT true,
    org_id uuid NOT NULL,
    CONSTRAINT dentists_gender_check CHECK ((gender = ANY (ARRAY['Male'::text, 'Female'::text])))
);

-- SECURITY DEFINER for the same reason as check_chair_capacity(): its counting
-- query must see all bookings regardless of the invoking role's RLS, or the
-- cap would silently never apply to anonymous customer-facing inserts.
CREATE FUNCTION public.check_branch_online_capacity() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_capacity integer;
  v_occupied integer;
BEGIN
  IF NEW.dentist_id IS NOT NULL OR NEW.created_by IS NOT NULL OR NEW.status IN ('Cancelled', 'No Show') THEN
    RETURN NEW;
  END IF;

  SELECT online_booking_capacity INTO v_capacity FROM branches WHERE id = NEW.branch_id;
  IF v_capacity IS NULL THEN
    RETURN NEW; -- no cap configured for this branch
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('online:' || NEW.branch_id::text || ':' || NEW.date::text));

  SELECT count(*) INTO v_occupied
  FROM bookings b
  WHERE b.branch_id = NEW.branch_id
    AND b.dentist_id IS NULL
    AND b.created_by IS NULL
    AND b.status NOT IN ('Cancelled', 'No Show')
    AND (TG_OP = 'INSERT' OR b.id != NEW.id)
    AND tstzrange(b.start_datetime, b.end_datetime) && tstzrange(NEW.start_datetime, NEW.end_datetime);

  IF v_occupied >= v_capacity THEN
    RAISE EXCEPTION 'BRANCH_ONLINE_CAPACITY: No dentists available at this branch for the selected time.'
      USING ERRCODE = 'P0005';
  END IF;

  RETURN NEW;
END;
$$;

CREATE FUNCTION public.public_check_branch_bookings_range(p_branch_id uuid, p_start_date date, p_end_date date) RETURNS TABLE(booking_date date, start_time time without time zone, duration_minutes integer, chair_id uuid, dentist_gender text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT
    b.date AS booking_date,
    b.start_time,
    GREATEST(1, (EXTRACT(EPOCH FROM (b.end_time - b.start_time)) / 60)::int) AS duration_minutes,
    b.chair_id,
    t.gender AS dentist_gender
  FROM public.bookings b
  LEFT JOIN public.dentists t ON t.id = b.dentist_id
  WHERE b.branch_id = p_branch_id
    AND b.date BETWEEN p_start_date AND p_end_date
    AND b.status NOT IN ('Cancelled', 'No Show');
$$;

CREATE FUNCTION public.public_check_slot_availability(p_branch_id uuid, p_date date) RETURNS TABLE(start_time time without time zone, duration_minutes integer, dentist_gender text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT
    b.start_time,
    COALESCE(s.duration_minutes, 60) AS duration_minutes,
    t.gender AS dentist_gender
  FROM public.bookings b
  JOIN public.dentists t ON t.id = b.dentist_id
  LEFT JOIN public.treatments s ON s.id = b.treatment_id
  WHERE b.branch_id = p_branch_id
    AND b.date = p_date
    AND b.status NOT IN ('Cancelled', 'No Show')
    AND b.dentist_id IS NOT NULL;
$$;

CREATE TABLE public.user_branches (
    user_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.users (
    id uuid NOT NULL,
    email text NOT NULL,
    full_name text NOT NULL,
    role public.user_role DEFAULT 'staff'::public.user_role NOT NULL,
    branch_id uuid,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    org_id uuid NOT NULL,
    pin text
);

CREATE FUNCTION public.enqueue_notification(p_user_id uuid, p_type text, p_title text, p_body text, p_booking_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF (SELECT role FROM public.users WHERE id = auth.uid())
       NOT IN ('manager', 'admin') THEN
    RAISE EXCEPTION 'Not authorized to enqueue notifications'
      USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, booking_id)
  VALUES (p_user_id, p_type, p_title, p_body, p_booking_id)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE FUNCTION public.get_user_branch_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT branch_id FROM users WHERE id = auth.uid();
$$;

CREATE FUNCTION public.get_user_branch_ids() RETURNS uuid[]
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT ARRAY(
    SELECT branch_id FROM public.users WHERE id = auth.uid() AND branch_id IS NOT NULL
    UNION
    SELECT branch_id FROM public.user_branches WHERE user_id = auth.uid()
  );
$$;

CREATE FUNCTION public.get_user_org_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT org_id FROM users WHERE id = auth.uid();
$$;

CREATE FUNCTION public.get_referral_credit_balance(p_customer_id uuid) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT
    COALESCE((SELECT SUM(amount) FROM public.customer_referral_credits
              WHERE customer_id = p_customer_id AND org_id = get_user_org_id()), 0)
    -
    COALESCE((SELECT SUM(amount) FROM public.customer_referral_debits
              WHERE customer_id = p_customer_id AND org_id = get_user_org_id()), 0);
$$;

CREATE FUNCTION public.get_user_role() RETURNS public.user_role
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT role FROM users WHERE id = auth.uid();
$$;

CREATE FUNCTION public.claim_voucher(p_voucher_id uuid, p_amount_claimed numeric, p_redeemed_date date DEFAULT NULL::date, p_guest_name_used_by text DEFAULT NULL::text, p_treatment_claimed text DEFAULT NULL::text, p_branch_claimed_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text) RETURNS public.voucher_claims
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_role             user_role := get_user_role();
  v_org              uuid      := get_user_org_id();
  v_voucher_org      uuid;
  v_total_issued     numeric(10,2);
  v_expiry_date      date;
  v_branch_org       uuid;
  v_already_claimed  numeric(10,2);
  v_row              public.voucher_claims;
BEGIN
  IF v_role NOT IN ('manager','admin') THEN
    RAISE EXCEPTION 'claim_voucher: manager or admin role required';
  END IF;

  IF p_amount_claimed IS NULL OR p_amount_claimed <= 0 THEN
    RAISE EXCEPTION 'claim_voucher: amount_claimed must be positive';
  END IF;

  IF p_branch_claimed_id IS NULL THEN
    RAISE EXCEPTION 'claim_voucher: branch_claimed_id is required';
  END IF;

  SELECT org_id INTO v_branch_org FROM public.branches WHERE id = p_branch_claimed_id;
  IF v_branch_org IS NULL OR v_branch_org IS DISTINCT FROM v_org THEN
    RAISE EXCEPTION 'claim_voucher: claiming branch is not in your organization';
  END IF;

  -- Lock the voucher row so a concurrent claim can't race the balance check.
  SELECT org_id, total_amount_issued, expiry_date
    INTO v_voucher_org, v_total_issued, v_expiry_date
  FROM public.vouchers
  WHERE id = p_voucher_id
  FOR UPDATE;

  IF v_voucher_org IS NULL THEN
    RAISE EXCEPTION 'claim_voucher: voucher % not found', p_voucher_id;
  END IF;
  IF v_voucher_org IS DISTINCT FROM v_org THEN
    RAISE EXCEPTION 'claim_voucher: voucher is not in your organization';
  END IF;

  IF v_expiry_date < (now() AT TIME ZONE 'Asia/Kathmandu')::date THEN
    RAISE EXCEPTION 'claim_voucher: voucher expired on %', v_expiry_date;
  END IF;

  SELECT COALESCE(SUM(amount_claimed), 0) INTO v_already_claimed
  FROM public.voucher_claims
  WHERE voucher_id = p_voucher_id;

  IF p_amount_claimed > (v_total_issued - v_already_claimed) THEN
    RAISE EXCEPTION 'claim_voucher: amount % exceeds remaining balance %',
      p_amount_claimed, (v_total_issued - v_already_claimed);
  END IF;

  INSERT INTO public.voucher_claims (
    voucher_id, org_id, redeemed_date, guest_name_used_by, treatment_claimed,
    branch_claimed_id, amount_claimed, notes, performed_by
  )
  VALUES (
    p_voucher_id, v_org,
    COALESCE(p_redeemed_date, (now() AT TIME ZONE 'Asia/Kathmandu')::date),
    p_guest_name_used_by, p_treatment_claimed, p_branch_claimed_id,
    p_amount_claimed, p_notes, auth.uid()
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE FUNCTION public.customer_duplicate_candidates(p_org_id uuid) RETURNS TABLE(customer_id_a uuid, customer_id_b uuid, nphone text, name_a text, name_b text, phone_a text, phone_b text, email_a text, email_b text, branch_id_a uuid, branch_id_b uuid, created_at_a timestamp with time zone, created_at_b timestamp with time zone)
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

CREATE FUNCTION public.extend_membership(p_membership_id uuid, p_new_expiry_date date, p_notes text DEFAULT NULL::text, p_branch_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_role        user_role := get_user_role();
  v_caller_org  uuid      := get_user_org_id();
  v_mem_org     uuid;
  v_balance     numeric(12,2);
  v_expiry      date;
  v_today       date := (now() AT TIME ZONE 'Asia/Kathmandu')::date;
  v_txn_id      uuid;
BEGIN
  IF v_role NOT IN ('manager','admin') THEN
    RAISE EXCEPTION 'extend_membership: manager or admin role required';
  END IF;

  IF p_new_expiry_date IS NULL OR p_new_expiry_date <= v_today THEN
    RAISE EXCEPTION 'extend_membership: new expiry date must be after today';
  END IF;

  -- Lock the membership row + load current state.
  SELECT org_id, balance, expiry_date
    INTO v_mem_org, v_balance, v_expiry
  FROM public.memberships
  WHERE id = p_membership_id
  FOR UPDATE;

  IF v_mem_org IS NULL THEN
    RAISE EXCEPTION 'extend_membership: membership % not found', p_membership_id;
  END IF;

  IF v_mem_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'extend_membership: membership is not in your organization';
  END IF;

  IF v_balance <= 0 THEN
    RAISE EXCEPTION 'extend_membership: membership has no remaining balance -- use renew instead';
  END IF;

  IF v_expiry IS NULL OR v_expiry >= v_today THEN
    RAISE EXCEPTION 'extend_membership: membership is not lapsed';
  END IF;

  -- Extend validity only -- balance, total_deposited, and tier_id are untouched.
  UPDATE public.memberships
     SET expiry_date = p_new_expiry_date
   WHERE id = p_membership_id;

  -- Zero-amount audit row so the reactivation shows up in transaction history.
  INSERT INTO public.membership_transactions
    (membership_id, org_id, kind, amount, performed_by, notes, branch_id)
  VALUES
    (p_membership_id, v_mem_org, 'extension', 0, auth.uid(),
     COALESCE(p_notes, 'Membership reactivated -- validity extended to ' || p_new_expiry_date || ', balance preserved.'), p_branch_id)
  RETURNING id INTO v_txn_id;

  RETURN v_txn_id;
END;
$$;

CREATE FUNCTION public.issue_package(p_org_id uuid, p_branch_id uuid, p_package_type_id uuid, p_customer_id uuid DEFAULT NULL::uuid, p_guest_name text DEFAULT NULL::text, p_guest_info text DEFAULT NULL::text, p_issued_date date DEFAULT NULL::date, p_expiry_date date DEFAULT NULL::date, p_paid_amount numeric DEFAULT NULL::numeric, p_sessions_total integer DEFAULT NULL::integer, p_remarks text DEFAULT NULL::text) RETURNS public.packages
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_role         user_role := get_user_role();
  v_org          uuid      := get_user_org_id();
  v_branch_org   uuid;
  v_customer_org uuid;
  v_type         record;
  v_issued       date := COALESCE(p_issued_date, (now() AT TIME ZONE 'Asia/Kathmandu')::date);
  v_expiry       date;
  v_row          public.packages;
BEGIN
  IF v_role NOT IN ('manager','admin') THEN
    RAISE EXCEPTION 'issue_package: manager or admin role required';
  END IF;

  IF p_org_id IS NULL OR p_org_id IS DISTINCT FROM v_org THEN
    RAISE EXCEPTION 'issue_package: org_id does not match your organization';
  END IF;

  IF p_customer_id IS NULL AND (p_guest_name IS NULL OR length(btrim(p_guest_name)) = 0) THEN
    RAISE EXCEPTION 'issue_package: either customer_id or guest_name is required';
  END IF;

  SELECT org_id INTO v_branch_org FROM public.branches WHERE id = p_branch_id;
  IF v_branch_org IS NULL OR v_branch_org IS DISTINCT FROM v_org THEN
    RAISE EXCEPTION 'issue_package: branch is not in your organization';
  END IF;

  IF p_customer_id IS NOT NULL THEN
    SELECT org_id INTO v_customer_org FROM public.customers WHERE id = p_customer_id;
    IF v_customer_org IS NULL OR v_customer_org IS DISTINCT FROM v_org THEN
      RAISE EXCEPTION 'issue_package: customer is not in your organization';
    END IF;
  END IF;

  SELECT * INTO v_type FROM public.package_types
  WHERE id = p_package_type_id AND org_id = v_org;
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'issue_package: package type not found in your organization';
  END IF;

  v_expiry := COALESCE(p_expiry_date, v_issued + make_interval(days => v_type.validity_days));

  IF v_expiry < v_issued THEN
    RAISE EXCEPTION 'issue_package: expiry_date cannot be before issued_date';
  END IF;

  IF p_paid_amount IS NULL OR p_paid_amount < 0 THEN
    RAISE EXCEPTION 'issue_package: paid_amount must be zero or greater';
  END IF;

  IF COALESCE(p_sessions_total, v_type.default_sessions) IS NULL
     OR COALESCE(p_sessions_total, v_type.default_sessions) <= 0 THEN
    RAISE EXCEPTION 'issue_package: sessions_total must be greater than zero';
  END IF;

  INSERT INTO public.packages (
    org_id, branch_id, package_type_id, treatment_id, customer_id, guest_name,
    guest_info, issued_date, expiry_date, paid_amount, sessions_total, remarks,
    issued_by
  )
  VALUES (
    v_org, p_branch_id, p_package_type_id, v_type.treatment_id, p_customer_id,
    btrim(p_guest_name), p_guest_info, v_issued, v_expiry, p_paid_amount,
    COALESCE(p_sessions_total, v_type.default_sessions), p_remarks, auth.uid()
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE FUNCTION public.list_discount_approvers() RETURNS TABLE(id uuid, full_name text, role public.user_role, branch_id uuid)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT u.id, u.full_name, u.role, u.branch_id
  FROM public.users u
  WHERE u.is_active = true
    AND u.pin IS NOT NULL AND u.pin <> ''
    AND u.id <> auth.uid()
    AND u.org_id = (SELECT org_id FROM public.users WHERE id = auth.uid())
    AND (
      u.role = 'admin'
      OR (u.role = 'manager'
          AND u.branch_id = (SELECT branch_id FROM public.users WHERE id = auth.uid()))
    )
  ORDER BY u.role DESC, u.full_name;
$$;

CREATE FUNCTION public.list_membership_status_for_org(p_customer_id uuid DEFAULT NULL::uuid) RETURNS TABLE(customer_id uuid, membership_id uuid, membership_number text, tier_name text, status text, usable boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
  FROM computed;
$$;

CREATE FUNCTION public.list_vouchers_for_customer(p_customer_id uuid) RETURNS TABLE(voucher_id uuid, voucher_code text, guest_name text, guest_info text, expiry_date date, remaining_balance numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
    AND v.customer_id = p_customer_id
    AND v.expiry_date >= (now() AT TIME ZONE 'Asia/Kathmandu')::date
    AND (v.total_amount_issued - COALESCE(c.total_claimed, 0)) > 0
  ORDER BY v.created_at DESC;
$$;

CREATE FUNCTION public.login_with_pin(p_email text, p_pin text, p_org_slug text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
DECLARE
  v_user record;
  v_auth_user record;
BEGIN
  -- Find user by email and PIN
  SELECT u.*, o.slug as org_slug
  INTO v_user
  FROM users u
  LEFT JOIN organizations o ON u.org_id = o.id
  WHERE u.email = p_email AND u.pin = p_pin AND u.is_active = true;
  
  IF v_user IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Invalid email or PIN');
  END IF;
  
  -- Check org slug if provided
  IF p_org_slug IS NOT NULL AND v_user.org_slug != p_org_slug THEN
    RETURN json_build_object('success', false, 'error', 'User does not belong to this organization');
  END IF;
  
  RETURN json_build_object(
    'success', true,
    'user_id', v_user.id,
    'email', v_user.email,
    'role', v_user.role,
    'full_name', v_user.full_name,
    'org_slug', v_user.org_slug
  );
END;
$$;

CREATE FUNCTION public.merge_customers(p_canonical_id uuid, p_duplicate_id uuid) RETURNS void
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

CREATE FUNCTION public.notify_outreach_review(p_org_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_pending_count integer;
BEGIN
  SELECT count(*) INTO v_pending_count
  FROM public.outreach_messages
  WHERE org_id = p_org_id
    AND status = 'review';

  IF v_pending_count = 0 THEN
    RETURN;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, booking_id)
  SELECT
    u.id,
    'outreach_review_pending',
    'Outreach messages awaiting review',
    v_pending_count || ' outreach message' ||
      CASE WHEN v_pending_count = 1 THEN '' ELSE 's' END ||
      ' need your review before sending.',
    NULL
  FROM public.users u
  WHERE u.org_id = p_org_id
    AND u.role IN ('manager', 'admin');
END;
$$;

CREATE FUNCTION public.outreach_approve_message(p_message_id uuid, p_subject text DEFAULT NULL::text, p_body text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_caller_role   text;
  v_caller_org_id uuid;
BEGIN
  SELECT role, org_id INTO v_caller_role, v_caller_org_id
  FROM public.users
  WHERE id = auth.uid();

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'admin') THEN
    RAISE EXCEPTION 'outreach_approve_message: caller is not authorized to approve outreach messages';
  END IF;

  UPDATE public.outreach_messages
  SET status     = 'approved',
      subject    = COALESCE(p_subject, subject),
      body       = COALESCE(p_body, body),
      updated_at = now()
  WHERE id = p_message_id
    AND org_id = v_caller_org_id
    AND status = 'review';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'outreach_approve_message: message % not found, not in caller''s organization, or not in review status', p_message_id;
  END IF;
END;
$$;

CREATE FUNCTION public.outreach_bulk_approve_messages(p_message_ids uuid[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_caller_role   text;
  v_caller_org_id uuid;
  v_updated_count integer;
BEGIN
  SELECT role, org_id INTO v_caller_role, v_caller_org_id
  FROM public.users
  WHERE id = auth.uid();

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'admin') THEN
    RAISE EXCEPTION 'outreach_bulk_approve_messages: caller is not authorized to approve outreach messages';
  END IF;

  UPDATE public.outreach_messages
  SET status     = 'approved',
      updated_at = now()
  WHERE id = ANY(p_message_ids)
    AND org_id = v_caller_org_id
    AND status = 'review';

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;

  RETURN v_updated_count;
END;
$$;

CREATE FUNCTION public.outreach_cancel_message(p_message_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_caller_role   text;
  v_caller_org_id uuid;
BEGIN
  SELECT role, org_id INTO v_caller_role, v_caller_org_id
  FROM public.users
  WHERE id = auth.uid();

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('manager', 'admin') THEN
    RAISE EXCEPTION 'outreach_cancel_message: caller is not authorized to cancel outreach messages';
  END IF;

  UPDATE public.outreach_messages
  SET status     = 'cancelled',
      updated_at = now()
  WHERE id = p_message_id
    AND org_id = v_caller_org_id
    AND status IN ('queued', 'review', 'approved');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'outreach_cancel_message: message % not found, not in caller''s organization, or not in a cancellable status', p_message_id;
  END IF;
END;
$$;

CREATE FUNCTION public.outreach_scan_winback() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_count integer := 0;
  v_review_org_ids uuid[];
  v_org_id uuid;
BEGIN
  WITH win_back_rules AS (
    SELECT r.id AS rule_id, r.org_id, r.channel, r.template_id, r.send_mode, r.lapsed_days
    FROM public.outreach_rules r
    WHERE r.trigger_type = 'win_back'
      AND r.enabled = true
      AND r.lapsed_days IS NOT NULL
  ),
  last_completed AS (
    -- Most recent Completed booking per customer, restricted to customers
    -- whose org has an enabled win_back rule. bookings has no org_id column
    -- (only branch_id) so org_id is resolved via branches, same as
    -- outreach_enqueue_for_completed() does below.
    SELECT DISTINCT ON (b.customer_id)
      b.id AS booking_id,
      b.customer_id,
      br.org_id,
      b.updated_at AS completed_at
    FROM public.bookings b
    JOIN public.branches br ON br.id = b.branch_id
    JOIN win_back_rules wr ON wr.org_id = br.org_id
    WHERE b.status = 'Completed'
      AND b.customer_id IS NOT NULL
    ORDER BY b.customer_id, b.updated_at DESC
  ),
  candidates AS (
    SELECT
      lc.booking_id,
      lc.customer_id,
      lc.org_id,
      lc.completed_at,
      wr.rule_id,
      wr.channel,
      wr.template_id,
      wr.send_mode
    FROM last_completed lc
    JOIN win_back_rules wr ON wr.org_id = lc.org_id
    WHERE lc.completed_at < now() - (wr.lapsed_days || ' days')::interval
  ),
  eligible AS (
    SELECT
      c.*,
      cu.full_name AS customer_name,
      cu.email     AS customer_email,
      'win_back:' || c.customer_id || ':' || to_char(c.completed_at, 'YYYY-MM-DD') AS dedupe_key
    FROM candidates c
    JOIN public.customers cu ON cu.id = c.customer_id
    WHERE cu.email IS NOT NULL AND btrim(cu.email) <> ''
  ),
  templated AS (
    SELECT
      e.*,
      t.subject AS template_subject,
      t.body    AS template_body
    FROM eligible e
    JOIN public.outreach_templates t ON t.id = e.template_id
  ),
  inserted AS (
    INSERT INTO public.outreach_messages (
      org_id, rule_id, customer_id, booking_id, channel, to_address,
      subject, body, status, source, dedupe_key
    )
    SELECT
      tp.org_id,
      tp.rule_id,
      tp.customer_id,
      tp.booking_id,
      tp.channel,
      tp.customer_email,
      replace(tp.template_subject, '{{customer_name}}', tp.customer_name),
      replace(tp.template_body, '{{customer_name}}', tp.customer_name),
      CASE WHEN tp.send_mode = 'auto' THEN 'queued' ELSE 'review' END,
      'template',
      tp.dedupe_key
    FROM templated tp
    ON CONFLICT (org_id, dedupe_key) DO NOTHING
    RETURNING org_id, status
  )
  SELECT count(*), array_agg(DISTINCT org_id) FILTER (WHERE status = 'review')
    INTO v_count, v_review_org_ids
  FROM inserted;

  -- Notify managers/admins in every org that got at least one review-mode
  -- row from THIS run (array captured directly off the INSERT...RETURNING
  -- above, no re-query / timing heuristic needed).
  IF v_review_org_ids IS NOT NULL THEN
    FOREACH v_org_id IN ARRAY v_review_org_ids LOOP
      PERFORM public.notify_outreach_review(v_org_id);
    END LOOP;
  END IF;

  RETURN v_count;
END;
$$;

CREATE FUNCTION public.outreach_send_manual(p_customer_id uuid, p_booking_id uuid, p_channel text, p_to_address text, p_subject text, p_body text, p_dedupe_key text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_caller_role   text;
  v_caller_org_id uuid;
  v_customer_org  uuid;
  v_message_id    uuid;
BEGIN
  SELECT role, org_id INTO v_caller_role, v_caller_org_id
  FROM public.users
  WHERE id = auth.uid();

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('staff', 'manager', 'admin') THEN
    RAISE EXCEPTION 'outreach_send_manual: caller is not authorized to send outreach messages';
  END IF;

  SELECT org_id INTO v_customer_org
  FROM public.customers
  WHERE id = p_customer_id;

  IF v_customer_org IS NULL THEN
    RAISE EXCEPTION 'outreach_send_manual: customer % not found', p_customer_id;
  END IF;

  IF v_customer_org <> v_caller_org_id THEN
    RAISE EXCEPTION 'outreach_send_manual: customer does not belong to caller''s organization';
  END IF;

  IF p_channel NOT IN ('email', 'sms', 'whatsapp') THEN
    RAISE EXCEPTION 'outreach_send_manual: invalid channel %', p_channel;
  END IF;

  IF p_to_address IS NULL OR btrim(p_to_address) = '' THEN
    RAISE EXCEPTION 'outreach_send_manual: to_address is required';
  END IF;

  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'outreach_send_manual: body is required';
  END IF;

  -- booking_id is optional but if provided must belong to the same org
  -- (resolved via branches, same pattern as outreach_enqueue_for_completed).
  IF p_booking_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.bookings b
      JOIN public.branches br ON br.id = b.branch_id
      WHERE b.id = p_booking_id
        AND br.org_id = v_caller_org_id
    ) THEN
      RAISE EXCEPTION 'outreach_send_manual: booking % not found in caller''s organization', p_booking_id;
    END IF;
  END IF;

  INSERT INTO public.outreach_messages (
    org_id, rule_id, customer_id, booking_id, channel, to_address,
    subject, body, status, source, dedupe_key
  )
  VALUES (
    v_caller_org_id,
    NULL,
    p_customer_id,
    p_booking_id,
    p_channel,
    p_to_address,
    p_subject,
    p_body,
    'queued',
    'template',
    COALESCE(p_dedupe_key, 'manual:' || p_customer_id || ':' || extract(epoch FROM now())::text)
  )
  RETURNING id INTO v_message_id;

  RETURN v_message_id;
END;
$$;

CREATE FUNCTION public.record_customer_referral(p_referring_customer_id uuid, p_referred_customer_id uuid, p_booking_id uuid, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_caller_org   uuid := get_user_org_id();
  v_referrer_org uuid;
  v_referred_org uuid;
  v_booking_customer uuid;
  v_booking_branch   uuid;
  v_booking_org      uuid;
  v_referral_id  uuid;
BEGIN
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
$$;

CREATE FUNCTION public.record_customer_referral(p_referring_customer_id uuid, p_referred_customer_id uuid, p_booking_id uuid, p_notes text DEFAULT NULL::text, p_reward_type text DEFAULT 'wallet'::text, p_reward_amount numeric DEFAULT NULL::numeric) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_caller_org   uuid := get_user_org_id();
  v_referrer_org uuid;
  v_referred_org uuid;
  v_booking_customer uuid;
  v_booking_branch   uuid;
  v_booking_org      uuid;
  v_referral_id  uuid;
BEGIN
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
$$;

CREATE FUNCTION public.record_customer_referral(p_referring_customer_id uuid, p_referred_customer_id uuid, p_booking_id uuid, p_notes text DEFAULT NULL::text, p_reward_type text DEFAULT 'wallet'::text, p_reward_amount numeric DEFAULT NULL::numeric, p_reward_catalog_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_caller_org   uuid := get_user_org_id();
  v_referrer_org uuid;
  v_referred_org uuid;
  v_booking_customer uuid;
  v_booking_branch   uuid;
  v_booking_org      uuid;
  v_referral_id  uuid;
BEGIN
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
$$;

CREATE FUNCTION public.record_membership_payment(p_booking_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;

CREATE FUNCTION public.record_membership_transaction(p_membership_id uuid, p_kind text, p_amount numeric, p_payment_mode text DEFAULT NULL::text, p_booking_id uuid DEFAULT NULL::uuid, p_payment_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text, p_branch_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_role         user_role := get_user_role();
  v_caller_org   uuid      := get_user_org_id();
  v_mem_org      uuid;
  v_balance      numeric(12,2);
  v_activation   date;
  v_expiry       date;
  v_perk_used    timestamptz;
  v_txn_id       uuid;
BEGIN
  IF p_kind NOT IN ('deposit','deduction','birthday_perk','adjustment') THEN
    RAISE EXCEPTION 'record_membership_transaction: invalid kind %', p_kind;
  END IF;

  -- Lock the membership row + load current state.
  SELECT org_id, balance, activation_date, expiry_date, birthday_perk_used_at
    INTO v_mem_org, v_balance, v_activation, v_expiry, v_perk_used
  FROM public.memberships
  WHERE id = p_membership_id
  FOR UPDATE;

  IF v_mem_org IS NULL THEN
    RAISE EXCEPTION 'record_membership_transaction: membership % not found', p_membership_id;
  END IF;

  IF v_mem_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'record_membership_transaction: membership is not in your organization';
  END IF;

  -- Per-kind authorization + sign/business-rule checks.
  IF p_kind IN ('deposit','deduction','birthday_perk') THEN
    IF v_role NOT IN ('manager','admin') THEN
      RAISE EXCEPTION 'record_membership_transaction: manager or admin role required';
    END IF;
  ELSIF p_kind = 'adjustment' THEN
    IF v_role <> 'admin' THEN
      RAISE EXCEPTION 'record_membership_transaction: adjustments are admin-only';
    END IF;
    IF p_notes IS NULL OR length(btrim(p_notes)) = 0 THEN
      RAISE EXCEPTION 'record_membership_transaction: adjustment requires a note';
    END IF;
  END IF;

  IF p_kind = 'deposit' AND p_amount <= 0 THEN
    RAISE EXCEPTION 'record_membership_transaction: deposit amount must be positive';
  END IF;

  IF p_kind = 'deduction' THEN
    IF p_amount >= 0 THEN
      RAISE EXCEPTION 'record_membership_transaction: deduction amount must be negative';
    END IF;
    IF abs(p_amount) > v_balance THEN
      RAISE EXCEPTION 'record_membership_transaction: insufficient balance (have %, need %)',
        v_balance, abs(p_amount);
    END IF;
  END IF;

  IF p_kind = 'birthday_perk' THEN
    IF p_amount <> 0 THEN
      RAISE EXCEPTION 'record_membership_transaction: birthday_perk amount must be 0';
    END IF;
    IF v_activation IS NULL THEN
      RAISE EXCEPTION 'record_membership_transaction: birthday perk requires an active membership';
    END IF;
    IF v_perk_used IS NOT NULL
       AND v_perk_used::date >= v_activation
       AND v_perk_used::date <= COALESCE(v_expiry, v_activation) THEN
      RAISE EXCEPTION 'record_membership_transaction: birthday perk already used in current cycle';
    END IF;
  END IF;

  -- Append the ledger row.
  INSERT INTO public.membership_transactions
    (membership_id, org_id, kind, amount, payment_mode, booking_id, payment_id, performed_by, notes, branch_id)
  VALUES
    (p_membership_id, v_mem_org, p_kind, p_amount, p_payment_mode, p_booking_id, p_payment_id, auth.uid(), p_notes, p_branch_id)
  RETURNING id INTO v_txn_id;

  -- Birthday perk side-effect: stamp the membership so we can block another in
  -- the same cycle. (The trigger handles balance/total_deposited/activation.)
  IF p_kind = 'birthday_perk' THEN
    UPDATE public.memberships
       SET birthday_perk_used_at = now()
     WHERE id = p_membership_id;
  END IF;

  RETURN v_txn_id;
END;
$$;

CREATE FUNCTION public.enroll_member(p_customer_id uuid, p_tier_id uuid, p_initial_deposit numeric, p_payment_mode text, p_notes text DEFAULT NULL::text, p_branch_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_role        user_role := get_user_role();
  v_caller_org  uuid      := get_user_org_id();
  v_cust_org    uuid;
  v_tier_org    uuid;
  v_membership  uuid;
BEGIN
  IF v_role NOT IN ('manager', 'admin', 'staff') THEN
    RAISE EXCEPTION 'enroll_member: manager, admin, or staff role required';
  END IF;

  IF p_initial_deposit IS NULL OR p_initial_deposit <= 0 THEN
    RAISE EXCEPTION 'enroll_member: initial deposit must be positive';
  END IF;

  IF p_payment_mode IS NULL
     OR length(trim(p_payment_mode)) = 0
     OR length(p_payment_mode) > 40 THEN
    RAISE EXCEPTION 'enroll_member: invalid payment_mode %', p_payment_mode;
  END IF;

  SELECT org_id INTO v_cust_org FROM public.customers      WHERE id = p_customer_id;
  SELECT org_id INTO v_tier_org FROM public.membership_tiers WHERE id = p_tier_id;

  IF v_cust_org IS NULL THEN
    RAISE EXCEPTION 'enroll_member: customer % not found', p_customer_id;
  END IF;
  IF v_tier_org IS NULL THEN
    RAISE EXCEPTION 'enroll_member: tier % not found', p_tier_id;
  END IF;
  IF v_cust_org IS DISTINCT FROM v_caller_org OR v_tier_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'enroll_member: customer and tier must be in your organization';
  END IF;

  INSERT INTO public.memberships (org_id, customer_id, tier_id, notes, created_by)
  VALUES (v_caller_org, p_customer_id, p_tier_id, p_notes, auth.uid())
  RETURNING id INTO v_membership;

  -- Initial deposit, inserted directly (not via record_membership_transaction,
  -- which is manager/admin-only) so a staff-enrolled member's first deposit
  -- still goes through the same trigger-driven balance recompute.
  INSERT INTO public.membership_transactions
    (membership_id, org_id, kind, amount, payment_mode, performed_by, notes, branch_id)
  VALUES
    (v_membership, v_caller_org, 'deposit', p_initial_deposit, p_payment_mode, auth.uid(), 'Initial enrollment deposit', p_branch_id);

  RETURN v_membership;
END;
$$;

CREATE FUNCTION public.record_referral_wallet_payment(p_booking_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_caller_org    uuid := get_user_org_id();
  v_actor         uuid := auth.uid();
  v_customer_id   uuid;
  v_booking_org   uuid;
  v_is_locked     boolean;
  v_balance       numeric(12,2);
  v_payment_id    uuid;
BEGIN
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
$$;

CREATE FUNCTION public.record_voucher_wallet_payment(p_booking_id uuid, p_voucher_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;

CREATE FUNCTION public.record_voucher_wallet_payment_pooled(p_booking_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;

CREATE FUNCTION public.redeem_package_session(p_package_id uuid, p_booking_id uuid DEFAULT NULL::uuid, p_branch_claimed_id uuid DEFAULT NULL::uuid, p_guest_name_used_by text DEFAULT NULL::text, p_notes text DEFAULT NULL::text) RETURNS public.package_redemptions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_role          user_role := get_user_role();
  v_org           uuid      := get_user_org_id();
  v_package_org   uuid;
  v_package_treatment uuid;
  v_sessions_total int;
  v_expiry_date   date;
  v_branch_org    uuid;
  v_booking_org   uuid;
  v_booking_treatment uuid;
  v_sessions_used int;
  v_row           public.package_redemptions;
BEGIN
  IF v_role NOT IN ('staff','manager','admin') THEN
    RAISE EXCEPTION 'redeem_package_session: staff, manager, or admin role required';
  END IF;

  IF p_branch_claimed_id IS NULL THEN
    RAISE EXCEPTION 'redeem_package_session: branch_claimed_id is required';
  END IF;

  SELECT org_id INTO v_branch_org FROM public.branches WHERE id = p_branch_claimed_id;
  IF v_branch_org IS NULL OR v_branch_org IS DISTINCT FROM v_org THEN
    RAISE EXCEPTION 'redeem_package_session: redeeming branch is not in your organization';
  END IF;

  IF p_booking_id IS NOT NULL THEN
    -- bookings has no org_id column (only branch_id) so org_id is resolved
    -- via branches, same as migration-108.
    SELECT br.org_id, b.treatment_id INTO v_booking_org, v_booking_treatment
    FROM public.bookings b
    JOIN public.branches br ON br.id = b.branch_id
    WHERE b.id = p_booking_id;
    IF v_booking_org IS NULL OR v_booking_org IS DISTINCT FROM v_org THEN
      RAISE EXCEPTION 'redeem_package_session: booking is not in your organization';
    END IF;
  END IF;

  -- Lock the package row so a concurrent redemption can't race the
  -- sessions-remaining check.
  SELECT org_id, treatment_id, sessions_total, expiry_date
  INTO v_package_org, v_package_treatment, v_sessions_total, v_expiry_date
  FROM public.packages
  WHERE id = p_package_id
  FOR UPDATE;

  IF v_package_org IS NULL THEN
    RAISE EXCEPTION 'redeem_package_session: package % not found', p_package_id;
  END IF;
  IF v_package_org IS DISTINCT FROM v_org THEN
    RAISE EXCEPTION 'redeem_package_session: package is not in your organization';
  END IF;

  -- A package only covers the one treatment it was issued for — a booking for
  -- a different treatment must not silently burn a session against it.
  IF p_booking_id IS NOT NULL AND v_package_treatment IS NOT NULL
     AND v_booking_treatment IS DISTINCT FROM v_package_treatment THEN
    RAISE EXCEPTION 'redeem_package_session: booking treatment does not match this package''s treatment';
  END IF;

  SELECT COUNT(*) INTO v_sessions_used
  FROM public.package_redemptions
  WHERE package_id = p_package_id;

  IF v_expiry_date < ((now() AT TIME ZONE 'Asia/Kathmandu')::date) THEN
    RAISE EXCEPTION 'redeem_package_session: package expired on %', v_expiry_date;
  END IF;

  IF v_sessions_used >= v_sessions_total THEN
    RAISE EXCEPTION 'redeem_package_session: no sessions remaining on this package';
  END IF;

  INSERT INTO public.package_redemptions (
    package_id, org_id, redeemed_date, branch_id, booking_id,
    guest_name_used_by, notes, performed_by
  )
  VALUES (
    p_package_id, v_org, (now() AT TIME ZONE 'Asia/Kathmandu')::date, p_branch_claimed_id,
    p_booking_id, p_guest_name_used_by, p_notes, auth.uid()
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE FUNCTION public.redeem_referral_voucher(p_referral_id uuid, p_booking_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;

CREATE FUNCTION public.renew_membership(p_membership_id uuid, p_amount numeric, p_payment_mode text, p_tier_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text, p_branch_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_role         user_role := get_user_role();
  v_caller_org   uuid      := get_user_org_id();
  v_mem_org      uuid;
  v_current_tier uuid;
  v_final_tier   uuid;
  v_tier_org     uuid;
  v_validity     int;
  v_activation   date;
  v_balance      numeric(12,2);
  v_txn_id       uuid;
BEGIN
  IF v_role NOT IN ('manager','admin') THEN
    RAISE EXCEPTION 'renew_membership: manager or admin role required';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'renew_membership: amount must be positive';
  END IF;

  -- Lock the membership row + load current state.
  SELECT org_id, tier_id, balance
    INTO v_mem_org, v_current_tier, v_balance
  FROM public.memberships
  WHERE id = p_membership_id
  FOR UPDATE;

  IF v_mem_org IS NULL THEN
    RAISE EXCEPTION 'renew_membership: membership % not found', p_membership_id;
  END IF;

  IF v_mem_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'renew_membership: membership is not in your organization';
  END IF;

  -- Optional tier change.
  v_final_tier := COALESCE(p_tier_id, v_current_tier);
  IF p_tier_id IS NOT NULL AND p_tier_id IS DISTINCT FROM v_current_tier THEN
    SELECT org_id INTO v_tier_org FROM public.membership_tiers WHERE id = p_tier_id;
    IF v_tier_org IS NULL THEN
      RAISE EXCEPTION 'renew_membership: tier % not found', p_tier_id;
    END IF;
    IF v_tier_org IS DISTINCT FROM v_caller_org THEN
      RAISE EXCEPTION 'renew_membership: tier must be in your organization';
    END IF;
    UPDATE public.memberships SET tier_id = p_tier_id WHERE id = p_membership_id;
  END IF;

  SELECT validity_days INTO v_validity FROM public.membership_tiers WHERE id = v_final_tier;

  -- Forfeit any balance left over from the expired cycle -- renewal starts a
  -- fresh cycle, so old unspent money is written off (visible in history as
  -- an adjustment row, not dropped).
  IF v_balance <> 0 THEN
    INSERT INTO public.membership_transactions
      (membership_id, org_id, kind, amount, performed_by, notes, branch_id)
    VALUES
      (p_membership_id, v_mem_org, 'adjustment', -v_balance, auth.uid(),
       'Previous cycle balance forfeited on renewal.', p_branch_id);
  END IF;

  -- Record the deposit (trigger recomputes total_deposited/balance; won't
  -- touch activation_date/expiry_date since they're already set).
  v_txn_id := public.record_membership_transaction(
    p_membership_id, 'deposit', p_amount, p_payment_mode, NULL, NULL,
    COALESCE(p_notes, 'Renewal deposit'), p_branch_id
  );

  -- Start a fresh cycle on this same row.
  v_activation := (now() AT TIME ZONE 'Asia/Kathmandu')::date;
  UPDATE public.memberships
     SET activation_date = v_activation,
         expiry_date     = v_activation + (v_validity || ' days')::interval
   WHERE id = p_membership_id;

  RETURN v_txn_id;
END;
$$;

CREATE FUNCTION public.resolve_customer_referral_reward(p_referral_id uuid, p_reward_type text, p_reward_amount numeric DEFAULT NULL::numeric, p_reward_catalog_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_caller_org    uuid := get_user_org_id();
  v_caller_role   text := get_user_role();
  v_org_id        uuid;
  v_referrer      uuid;
  v_status        text;
  v_amount        numeric(12,2);
  v_credit_id     uuid;
BEGIN
  IF v_caller_org IS NULL THEN
    RAISE EXCEPTION 'resolve_customer_referral_reward: caller has no organization';
  END IF;
  IF v_caller_role NOT IN ('manager', 'admin') THEN
    RAISE EXCEPTION 'resolve_customer_referral_reward: manager or admin only';
  END IF;
  IF p_reward_type IS DISTINCT FROM 'wallet' THEN
    RAISE EXCEPTION 'resolve_customer_referral_reward: only wallet rewards are supported';
  END IF;
  IF p_reward_amount IS NOT NULL AND p_reward_amount < 0 THEN
    RAISE EXCEPTION 'resolve_customer_referral_reward: reward_amount cannot be negative';
  END IF;

  SELECT org_id, referring_customer_id, reward_status
    INTO v_org_id, v_referrer, v_status
  FROM public.customer_referrals
  WHERE id = p_referral_id
  FOR UPDATE;

  IF v_org_id IS NULL THEN
    RAISE EXCEPTION 'resolve_customer_referral_reward: referral % not found', p_referral_id;
  END IF;
  IF v_org_id IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'resolve_customer_referral_reward: referral is not in your organization';
  END IF;
  IF v_status <> 'pending' THEN
    RAISE EXCEPTION 'resolve_customer_referral_reward: referral % is not pending', p_referral_id;
  END IF;

  UPDATE public.customer_referrals
     SET reward_type             = p_reward_type,
         requested_reward_amount = p_reward_amount,
         reward_catalog_id       = NULL,
         reward_label            = NULL
   WHERE id = p_referral_id;

  -- Wallet: staff-entered amount wins; fall back to the org-wide default.
  v_amount := p_reward_amount;
  IF v_amount IS NULL THEN
    SELECT referral_reward_amount INTO v_amount FROM public.organizations WHERE id = v_org_id;
  END IF;

  IF v_amount IS NULL OR v_amount = 0 THEN
    UPDATE public.customer_referrals
       SET reward_status = 'credited',
           reward_amount = 0,
           credited_at   = now(),
           credited_by   = auth.uid()
     WHERE id = p_referral_id;
    RETURN p_referral_id;
  END IF;

  INSERT INTO public.customer_referral_credits (org_id, referral_id, customer_id, amount)
  VALUES (v_org_id, p_referral_id, v_referrer, v_amount)
  RETURNING id INTO v_credit_id;

  UPDATE public.customer_referrals
     SET reward_status = 'credited',
         reward_amount = v_amount,
         credited_at   = now(),
         credited_by   = auth.uid()
   WHERE id = p_referral_id;

  RETURN v_credit_id;
END;
$$;

CREATE FUNCTION public.credit_pending_referral_for_booking(p_booking_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;

CREATE FUNCTION public.search_vouchers_for_payment(p_query text) RETURNS TABLE(voucher_id uuid, voucher_code text, guest_name text, guest_info text, expiry_date date, remaining_balance numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;

CREATE FUNCTION public.update_org_payment_methods(p_methods jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_org_id  uuid := get_user_org_id();
  v_role    text := get_user_role();
  v_settings jsonb;
BEGIN
  IF v_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'update_org_payment_methods: admin only';
  END IF;

  IF v_org_id IS NULL THEN
    RAISE EXCEPTION 'update_org_payment_methods: no organization context';
  END IF;

  IF jsonb_typeof(p_methods) IS DISTINCT FROM 'array' OR jsonb_array_length(p_methods) = 0 THEN
    RAISE EXCEPTION 'update_org_payment_methods: p_methods must be a non-empty array';
  END IF;

  UPDATE public.organizations
  SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '{paymentMethods}', p_methods, true)
  WHERE id = v_org_id
  RETURNING settings INTO v_settings;

  IF v_settings IS NULL THEN
    RAISE EXCEPTION 'update_org_payment_methods: organization % not found', v_org_id;
  END IF;

  RETURN v_settings;
END;
$$;

CREATE FUNCTION public.verify_pin(p_email text, p_pin text, p_org_slug text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_user record;
  v_org record;
BEGIN
  -- Find user by email and PIN
  SELECT u.*, o.slug as org_slug
  INTO v_user
  FROM users u
  LEFT JOIN organizations o ON u.org_id = o.id
  WHERE u.email = p_email AND u.pin = p_pin AND u.is_active = true;
  
  IF v_user IS NULL THEN
    RETURN json_build_object('valid', false, 'error', 'Invalid email or PIN');
  END IF;
  
  -- Check org slug if provided
  IF p_org_slug IS NOT NULL AND v_user.org_slug != p_org_slug THEN
    RETURN json_build_object('valid', false, 'error', 'User does not belong to this organization');
  END IF;
  
  RETURN json_build_object(
    'valid', true,
    'user_id', v_user.id,
    'email', v_user.email,
    'role', v_user.role,
    'full_name', v_user.full_name
  );
END;
$$;

CREATE VIEW public.voucher_balances WITH (security_invoker='true') AS
 SELECT v.id AS voucher_id,
    v.org_id,
    v.branch_id,
    v.voucher_code,
    v.guest_name,
    v.guest_info,
    v.total_amount_issued,
    COALESCE(c.total_claimed, (0)::numeric) AS total_claimed,
    (v.total_amount_issued - COALESCE(c.total_claimed, (0)::numeric)) AS remaining_balance,
        CASE
            WHEN (COALESCE(c.total_claimed, (0)::numeric) = (0)::numeric) THEN 'unused'::text
            WHEN ((v.total_amount_issued - COALESCE(c.total_claimed, (0)::numeric)) <= (0)::numeric) THEN 'fully_redeemed'::text
            ELSE 'partially_used'::text
        END AS status,
    c.last_claim_date
   FROM (public.vouchers v
     LEFT JOIN ( SELECT voucher_claims.voucher_id,
            sum(voucher_claims.amount_claimed) AS total_claimed,
            max(voucher_claims.redeemed_date) AS last_claim_date
           FROM public.voucher_claims
          GROUP BY voucher_claims.voucher_id) c ON ((c.voucher_id = v.id)));

CREATE TABLE public.voucher_code_counters (
    org_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    next_number integer DEFAULT 1 NOT NULL,
    code_prefix text NOT NULL,
    CONSTRAINT voucher_code_counters_next_number_check CHECK ((next_number > 0))
);

CREATE TABLE public.voucher_payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    voucher_id uuid NOT NULL,
    org_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    amount numeric(10,2) NOT NULL,
    payment_mode text NOT NULL,
    recorded_by uuid NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT voucher_payments_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT voucher_payments_payment_mode_check CHECK (((length(btrim(payment_mode)) > 0) AND (length(payment_mode) <= 40)))
);

CREATE TABLE public.voucher_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_id uuid NOT NULL,
    name text NOT NULL,
    code_prefix text NOT NULL,
    standard_price numeric(10,2) DEFAULT 0 NOT NULL,
    is_wallet boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    category text DEFAULT 'dental'::text NOT NULL,
    CONSTRAINT voucher_types_category_check CHECK ((category = ANY (ARRAY['dental'::text, 'package'::text]))),
    CONSTRAINT voucher_types_standard_price_check CHECK ((standard_price >= (0)::numeric))
);

CREATE FUNCTION public.issue_voucher(p_branch_id uuid, p_voucher_type_id uuid, p_guest_name text, p_guest_info text DEFAULT NULL::text, p_discount_percent numeric DEFAULT 0, p_actual_price numeric DEFAULT NULL::numeric, p_issued_date date DEFAULT NULL::date, p_expiry_date date DEFAULT NULL::date, p_remarks text DEFAULT NULL::text, p_customer_id uuid DEFAULT NULL::uuid, p_tenders jsonb DEFAULT NULL::jsonb, p_voucher_code text DEFAULT NULL::text) RETURNS public.vouchers
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_role              user_role := get_user_role();
  v_org               uuid      := get_user_org_id();
  v_branch_org        uuid;
  v_customer_org      uuid;
  v_type              record;
  v_seq               int;
  v_code              text;
  v_actual_price      numeric(10,2);
  v_issued            date := COALESCE(p_issued_date, (now() AT TIME ZONE 'Asia/Kathmandu')::date);
  v_expiry            date := COALESCE(p_expiry_date, v_issued + interval '90 days');
  v_row               public.vouchers;
  v_total             numeric(10,2);
  v_tender            jsonb;
  v_tender_sum        numeric(10,2) := 0;
  v_tender_amt        numeric(10,2);
  v_tender_mode       text;
  v_membership_amt    numeric(10,2) := 0;
  v_membership_id     uuid;
  v_membership_balance numeric(12,2);
  v_voucher_payment_id uuid;
BEGIN
  IF v_role NOT IN ('staff','manager','admin') THEN
    RAISE EXCEPTION 'issue_voucher: staff, manager, or admin role required';
  END IF;

  IF p_guest_name IS NULL OR length(btrim(p_guest_name)) = 0 THEN
    RAISE EXCEPTION 'issue_voucher: guest name is required';
  END IF;

  -- Type check only here — whether a nonempty array is REQUIRED depends on
  -- v_total, which isn't known until after the voucher type/discount are
  -- resolved below.
  IF p_tenders IS NOT NULL AND jsonb_typeof(p_tenders) != 'array' THEN
    RAISE EXCEPTION 'issue_voucher: p_tenders must be a JSON array';
  END IF;

  SELECT org_id INTO v_branch_org FROM public.branches WHERE id = p_branch_id;
  IF v_branch_org IS NULL OR v_branch_org IS DISTINCT FROM v_org THEN
    RAISE EXCEPTION 'issue_voucher: branch is not in your organization';
  END IF;

  IF p_customer_id IS NOT NULL THEN
    SELECT org_id INTO v_customer_org FROM public.customers WHERE id = p_customer_id;
    IF v_customer_org IS NULL OR v_customer_org IS DISTINCT FROM v_org THEN
      RAISE EXCEPTION 'issue_voucher: customer is not in your organization';
    END IF;
  END IF;

  SELECT * INTO v_type FROM public.voucher_types
  WHERE id = p_voucher_type_id AND org_id = v_org;
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'issue_voucher: voucher type not found in your organization';
  END IF;

  IF p_discount_percent IS NULL OR p_discount_percent < 0 OR p_discount_percent > 100 THEN
    RAISE EXCEPTION 'issue_voucher: discount_percent must be between 0 and 100';
  END IF;

  IF v_expiry < v_issued THEN
    RAISE EXCEPTION 'issue_voucher: expiry_date cannot be before issued_date';
  END IF;

  v_actual_price := COALESCE(p_actual_price, v_type.standard_price);
  v_total := round(v_actual_price - (v_actual_price * p_discount_percent / 100), 2);

  -- A voucher with a real cost still needs at least one tender; a fully
  -- discounted (v_total = 0) voucher legitimately has nothing to collect.
  IF v_total > 0 AND (p_tenders IS NULL OR jsonb_array_length(p_tenders) = 0) THEN
    RAISE EXCEPTION 'issue_voucher: at least one payment tender is required';
  END IF;

  -- Validate tenders sum to the voucher's total before touching any table.
  -- (jsonb_array_elements is STRICT — a NULL p_tenders yields zero rows, so
  -- this loop naturally no-ops for a zero-total voucher with no tenders.)
  FOR v_tender IN SELECT * FROM jsonb_array_elements(p_tenders)
  LOOP
    v_tender_amt := (v_tender->>'amount')::numeric;
    v_tender_mode := v_tender->>'payment_mode';
    IF v_tender_amt IS NULL OR v_tender_amt <= 0 THEN
      RAISE EXCEPTION 'issue_voucher: each tender amount must be greater than zero';
    END IF;
    IF v_tender_mode IS NULL OR length(btrim(v_tender_mode)) = 0 THEN
      RAISE EXCEPTION 'issue_voucher: each tender must have a payment_mode';
    END IF;
    v_tender_sum := v_tender_sum + v_tender_amt;
    IF v_tender_mode = 'Membership' THEN
      v_membership_amt := v_membership_amt + v_tender_amt;
    END IF;
  END LOOP;

  IF v_tender_sum != v_total THEN
    RAISE EXCEPTION 'issue_voucher: tenders total % does not match voucher total %', v_tender_sum, v_total;
  END IF;

  -- Membership tender: resolve + lock the wallet and validate balance before
  -- touching any table, same lock-then-validate order as record_membership_payment.
  IF v_membership_amt > 0 THEN
    IF p_customer_id IS NULL THEN
      RAISE EXCEPTION 'issue_voucher: a linked customer is required to pay by Membership';
    END IF;

    SELECT id, balance INTO v_membership_id, v_membership_balance
    FROM public.memberships
    WHERE org_id = v_org AND customer_id = p_customer_id
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_membership_id IS NULL THEN
      RAISE EXCEPTION 'issue_voucher: customer has no membership';
    END IF;

    IF v_membership_balance < v_membership_amt THEN
      RAISE EXCEPTION 'issue_voucher: insufficient wallet balance (have %, need %)',
        v_membership_balance, v_membership_amt;
    END IF;
  END IF;

  IF p_voucher_code IS NOT NULL AND length(btrim(p_voucher_code)) > 0 THEN
    -- Manual code from a physical booklet: use as typed, don't touch the
    -- counter so auto-generation stays correct for whenever this reverts.
    v_code := btrim(p_voucher_code);
    IF EXISTS (SELECT 1 FROM public.vouchers WHERE org_id = v_org AND voucher_code = v_code) THEN
      RAISE EXCEPTION 'issue_voucher: voucher code % is already in use', v_code;
    END IF;
  ELSE
    -- Keyed by code_prefix (not voucher_type_id): sibling types that share a
    -- prefix (e.g. the three "Full Body Oil Massage" durations, all "NT 4326")
    -- draw from one shared sequence, matching what the code text depends on.
    INSERT INTO public.voucher_code_counters (org_id, branch_id, code_prefix, next_number)
    VALUES (v_org, p_branch_id, v_type.code_prefix, 2)
    ON CONFLICT (branch_id, code_prefix)
      DO UPDATE SET next_number = public.voucher_code_counters.next_number + 1
    RETURNING next_number - 1 INTO v_seq;

    v_code := v_type.code_prefix || '-' || lpad(v_seq::text, 4, '0');
  END IF;

  BEGIN
    INSERT INTO public.vouchers (
      org_id, branch_id, voucher_type_id, voucher_code, issued_date, expiry_date,
      guest_name, guest_info, actual_price, discount_percent, total_amount_issued,
      remarks, issued_by, customer_id
    )
    VALUES (
      v_org, p_branch_id, p_voucher_type_id, v_code, v_issued, v_expiry,
      btrim(p_guest_name), p_guest_info, v_actual_price, p_discount_percent,
      v_total,
      p_remarks, auth.uid(), p_customer_id
    )
    RETURNING * INTO v_row;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'issue_voucher: voucher code % is already in use', v_code;
  END;

  FOR v_tender IN SELECT * FROM jsonb_array_elements(p_tenders)
  LOOP
    INSERT INTO public.voucher_payments (voucher_id, org_id, branch_id, amount, payment_mode, recorded_by)
    VALUES (
      v_row.id, v_org, p_branch_id,
      (v_tender->>'amount')::numeric,
      v_tender->>'payment_mode',
      auth.uid()
    )
    RETURNING id INTO v_voucher_payment_id;

    IF v_tender->>'payment_mode' = 'Membership' THEN
      INSERT INTO public.membership_transactions
        (membership_id, org_id, kind, amount, payment_mode, voucher_payment_id, performed_by, notes, branch_id)
      VALUES
        (v_membership_id, v_org, 'deduction', -((v_tender->>'amount')::numeric), NULL,
         v_voucher_payment_id, auth.uid(), 'Voucher purchase: ' || v_code, p_branch_id);
    END IF;
  END LOOP;

  RETURN v_row;
END;
$$;
ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.booking_dentists
    ADD CONSTRAINT booking_dentists_booking_id_dentist_id_key UNIQUE (booking_id, dentist_id);

ALTER TABLE ONLY public.booking_dentists
    ADD CONSTRAINT booking_dentists_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_booking_number_key UNIQUE (booking_number);

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.customer_accounts
    ADD CONSTRAINT customer_accounts_auth_user_id_key UNIQUE (auth_user_id);

ALTER TABLE ONLY public.customer_accounts
    ADD CONSTRAINT customer_accounts_org_id_email_key UNIQUE (org_id, email);

ALTER TABLE ONLY public.customer_accounts
    ADD CONSTRAINT customer_accounts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.customer_duplicate_dismissals
    ADD CONSTRAINT customer_duplicate_dismissals_org_id_customer_id_lo_custome_key UNIQUE (org_id, customer_id_lo, customer_id_hi);

ALTER TABLE ONLY public.customer_duplicate_dismissals
    ADD CONSTRAINT customer_duplicate_dismissals_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.customer_merge_log
    ADD CONSTRAINT customer_merge_log_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.customer_referral_credits
    ADD CONSTRAINT customer_referral_credits_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.customer_referral_credits
    ADD CONSTRAINT customer_referral_credits_referral_uniq UNIQUE (referral_id);

ALTER TABLE ONLY public.customer_referral_debits
    ADD CONSTRAINT customer_referral_debits_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_booking_uniq UNIQUE (booking_id);

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_referred_customer_uniq UNIQUE (referred_customer_id);

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.membership_tiers
    ADD CONSTRAINT membership_tiers_org_name_uniq UNIQUE (org_id, name);

ALTER TABLE ONLY public.membership_tiers
    ADD CONSTRAINT membership_tiers_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.membership_transactions
    ADD CONSTRAINT membership_transactions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.org_commission_collections
    ADD CONSTRAINT org_commission_collections_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.org_commission_rates
    ADD CONSTRAINT org_commission_rates_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_code_key UNIQUE (code);

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_slug_key UNIQUE (slug);

ALTER TABLE ONLY public.outreach_ai_config
    ADD CONSTRAINT outreach_ai_config_org_id_key UNIQUE (org_id);

ALTER TABLE ONLY public.outreach_ai_config
    ADD CONSTRAINT outreach_ai_config_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.outreach_drafts
    ADD CONSTRAINT outreach_drafts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.outreach_messages
    ADD CONSTRAINT outreach_messages_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.outreach_provider_config
    ADD CONSTRAINT outreach_provider_config_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.outreach_rules
    ADD CONSTRAINT outreach_rules_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.outreach_templates
    ADD CONSTRAINT outreach_templates_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.package_redemptions
    ADD CONSTRAINT package_redemptions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.package_types
    ADD CONSTRAINT package_types_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT packages_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.payment_refunds
    ADD CONSTRAINT payment_refunds_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.payroll_items
    ADD CONSTRAINT payroll_items_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.payroll_runs
    ADD CONSTRAINT payroll_runs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.platform_admins
    ADD CONSTRAINT platform_admins_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY public.reward_catalog
    ADD CONSTRAINT reward_catalog_name_uniq UNIQUE (org_id, reward_type, name);

ALTER TABLE ONLY public.reward_catalog
    ADD CONSTRAINT reward_catalog_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.chairs
    ADD CONSTRAINT chairs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);

ALTER TABLE ONLY public.treatment_categories
    ADD CONSTRAINT treatment_categories_org_id_name_key UNIQUE (org_id, name);

ALTER TABLE ONLY public.treatment_categories
    ADD CONSTRAINT treatment_categories_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.treatments
    ADD CONSTRAINT treatments_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.staff_compensation
    ADD CONSTRAINT staff_compensation_pkey PRIMARY KEY (dentist_id);

ALTER TABLE ONLY public.dentist_attendance
    ADD CONSTRAINT dentist_attendance_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.dentists
    ADD CONSTRAINT dentists_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT uq_attendance_user_date UNIQUE (user_id, date);

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT uq_daily_report_branch_date UNIQUE (branch_id, report_date);

ALTER TABLE ONLY public.outreach_messages
    ADD CONSTRAINT uq_outreach_messages_org_dedupe UNIQUE (org_id, dedupe_key);

ALTER TABLE ONLY public.outreach_provider_config
    ADD CONSTRAINT uq_outreach_provider_config_org_channel UNIQUE (org_id, channel);

ALTER TABLE ONLY public.outreach_rules
    ADD CONSTRAINT uq_outreach_rules_org_trigger UNIQUE (org_id, trigger_type);

ALTER TABLE ONLY public.outreach_templates
    ADD CONSTRAINT uq_outreach_templates_org_key UNIQUE (org_id, key);

ALTER TABLE ONLY public.payroll_items
    ADD CONSTRAINT uq_payroll_item_run_dentist UNIQUE (payroll_run_id, dentist_id);

ALTER TABLE ONLY public.payroll_runs
    ADD CONSTRAINT uq_payroll_run_branch_month UNIQUE (branch_id, period_month);

ALTER TABLE ONLY public.dentist_attendance
    ADD CONSTRAINT uq_dentist_attendance UNIQUE (dentist_id, date);

ALTER TABLE ONLY public.user_branches
    ADD CONSTRAINT user_branches_pkey PRIMARY KEY (user_id, branch_id);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.voucher_claims
    ADD CONSTRAINT voucher_claims_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.voucher_code_counters
    ADD CONSTRAINT voucher_code_counters_pkey PRIMARY KEY (branch_id, code_prefix);

ALTER TABLE ONLY public.voucher_payments
    ADD CONSTRAINT voucher_payments_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.voucher_types
    ADD CONSTRAINT voucher_types_org_name_uniq UNIQUE (org_id, name);

ALTER TABLE ONLY public.voucher_types
    ADD CONSTRAINT voucher_types_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.vouchers
    ADD CONSTRAINT vouchers_org_code_uniq UNIQUE (org_id, voucher_code);

ALTER TABLE ONLY public.vouchers
    ADD CONSTRAINT vouchers_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.treatment_notes
    ADD CONSTRAINT treatment_notes_pkey PRIMARY KEY (id);

CREATE UNIQUE INDEX customers_org_nphone_uniq ON public.customers USING btree (org_id, NULLIF(regexp_replace(COALESCE(phone, ''::text), '\D'::text, ''::text, 'g'::text), ''::text)) WHERE (NULLIF(regexp_replace(COALESCE(phone, ''::text), '\D'::text, ''::text, 'g'::text), ''::text) IS NOT NULL);

CREATE INDEX idx_attendance_date ON public.attendance USING btree (date);

CREATE INDEX idx_audit_logs_branch ON public.audit_logs USING btree (branch_id);

CREATE INDEX idx_audit_logs_changed_at ON public.audit_logs USING btree (changed_at);

CREATE INDEX idx_booking_dentists_booking ON public.booking_dentists USING btree (booking_id);

CREATE INDEX idx_booking_dentists_dentist ON public.booking_dentists USING btree (dentist_id);

CREATE INDEX idx_bookings_booking_group_id ON public.bookings USING btree (booking_group_id) WHERE (booking_group_id IS NOT NULL);

CREATE INDEX idx_bookings_branch_date ON public.bookings USING btree (branch_id, date);

CREATE INDEX idx_bookings_customer_account_id ON public.bookings USING btree (customer_account_id);

CREATE INDEX idx_bookings_date ON public.bookings USING btree (date);

CREATE INDEX idx_bookings_discount_requested_to ON public.bookings USING btree (discount_requested_to) WHERE (discount_status = 'pending'::public.discount_status_enum);

CREATE INDEX idx_bookings_status ON public.bookings USING btree (status);

CREATE INDEX idx_branches_org ON public.branches USING btree (org_id);

CREATE INDEX idx_branches_org_active ON public.branches USING btree (org_id, is_active) WHERE (is_active = true);

CREATE INDEX idx_commission_collections_org ON public.org_commission_collections USING btree (org_id);

CREATE INDEX idx_commission_rates_org ON public.org_commission_rates USING btree (org_id, effective_from);

CREATE INDEX idx_customer_accounts_customer_id ON public.customer_accounts USING btree (customer_id);

CREATE INDEX idx_customer_accounts_org_email ON public.customer_accounts USING btree (org_id, email);

CREATE INDEX idx_customer_referral_credits_customer ON public.customer_referral_credits USING btree (org_id, customer_id);

CREATE INDEX idx_customer_referral_debits_customer ON public.customer_referral_debits USING btree (org_id, customer_id);

CREATE INDEX idx_customer_referrals_org ON public.customer_referrals USING btree (org_id);

CREATE INDEX idx_customer_referrals_pending ON public.customer_referrals USING btree (reward_status) WHERE (reward_status = 'pending'::text);

CREATE INDEX idx_customer_referrals_referrer ON public.customer_referrals USING btree (org_id, referring_customer_id);

CREATE INDEX idx_customers_branch ON public.customers USING btree (branch_id);

CREATE INDEX idx_customers_org ON public.customers USING btree (org_id);

CREATE INDEX idx_customers_org_active ON public.customers USING btree (org_id, is_active) WHERE is_active;

CREATE INDEX idx_customers_phone ON public.customers USING btree (phone);

CREATE INDEX idx_membership_tiers_org ON public.membership_tiers USING btree (org_id);

CREATE INDEX idx_membership_transactions_branch ON public.membership_transactions USING btree (branch_id);

CREATE INDEX idx_membership_txns_booking ON public.membership_transactions USING btree (booking_id) WHERE (booking_id IS NOT NULL);

CREATE INDEX idx_membership_txns_membership ON public.membership_transactions USING btree (membership_id, created_at DESC);

CREATE INDEX idx_membership_txns_voucher_payment ON public.membership_transactions USING btree (voucher_payment_id) WHERE (voucher_payment_id IS NOT NULL);

CREATE INDEX idx_memberships_customer ON public.memberships USING btree (org_id, customer_id);

CREATE INDEX idx_memberships_org ON public.memberships USING btree (org_id);

CREATE INDEX idx_notifications_user_created ON public.notifications USING btree (user_id, created_at DESC);

CREATE INDEX idx_organizations_active ON public.organizations USING btree (is_active) WHERE (is_active = true);

CREATE INDEX idx_organizations_code ON public.organizations USING btree (code);

CREATE INDEX idx_organizations_slug ON public.organizations USING btree (slug);

CREATE INDEX idx_outreach_drafts_message ON public.outreach_drafts USING btree (message_id);

CREATE INDEX idx_outreach_drafts_org ON public.outreach_drafts USING btree (org_id);

CREATE INDEX idx_outreach_messages_org_customer_created ON public.outreach_messages USING btree (org_id, customer_id, created_at DESC);

CREATE INDEX idx_outreach_messages_org_status_scheduled ON public.outreach_messages USING btree (org_id, status, scheduled_for);

CREATE INDEX idx_outreach_provider_config_org ON public.outreach_provider_config USING btree (org_id);

CREATE INDEX idx_outreach_rules_org ON public.outreach_rules USING btree (org_id);

CREATE INDEX idx_outreach_rules_template ON public.outreach_rules USING btree (template_id);

CREATE INDEX idx_outreach_templates_org ON public.outreach_templates USING btree (org_id);

CREATE INDEX idx_package_redemptions_branch ON public.package_redemptions USING btree (branch_id);

CREATE INDEX idx_package_redemptions_package ON public.package_redemptions USING btree (package_id, redeemed_date DESC);

CREATE INDEX idx_package_types_org ON public.package_types USING btree (org_id);

CREATE INDEX idx_package_types_treatment ON public.package_types USING btree (treatment_id);

CREATE INDEX idx_packages_branch ON public.packages USING btree (branch_id);

CREATE INDEX idx_packages_customer ON public.packages USING btree (customer_id);

CREATE INDEX idx_packages_guest_name ON public.packages USING btree (org_id, guest_name);

CREATE INDEX idx_packages_org ON public.packages USING btree (org_id);

CREATE INDEX idx_packages_treatment ON public.packages USING btree (treatment_id);

CREATE INDEX idx_packages_type ON public.packages USING btree (package_type_id);

CREATE INDEX idx_payment_refunds_booking_id ON public.payment_refunds USING btree (booking_id);

CREATE INDEX idx_payment_refunds_org_id ON public.payment_refunds USING btree (org_id);

CREATE INDEX idx_payments_booking_id ON public.payments USING btree (booking_id);

CREATE INDEX idx_payments_created_at ON public.payments USING btree (created_at);

CREATE INDEX idx_payroll_items_run ON public.payroll_items USING btree (payroll_run_id);

CREATE INDEX idx_payroll_runs_branch_month ON public.payroll_runs USING btree (branch_id, period_month);

CREATE INDEX idx_reward_catalog_org_type_active ON public.reward_catalog USING btree (org_id, reward_type) WHERE is_active;

CREATE INDEX idx_chairs_branch_display_order ON public.chairs USING btree (branch_id, display_order);

CREATE INDEX idx_treatment_categories_org ON public.treatment_categories USING btree (org_id);

CREATE INDEX idx_treatments_org ON public.treatments USING btree (org_id);

CREATE INDEX idx_treatments_org_active ON public.treatments USING btree (org_id, is_active) WHERE (is_active = true);

CREATE INDEX idx_dentist_attendance_branch_date ON public.dentist_attendance USING btree (branch_id, date);

CREATE INDEX idx_dentists_branch_display_order ON public.dentists USING btree (branch_id, display_order);

CREATE INDEX idx_dentists_org ON public.dentists USING btree (org_id);

CREATE INDEX idx_users_org ON public.users USING btree (org_id);

CREATE INDEX idx_voucher_claims_booking ON public.voucher_claims USING btree (booking_id);

CREATE INDEX idx_voucher_claims_branch ON public.voucher_claims USING btree (branch_claimed_id);

CREATE INDEX idx_voucher_claims_voucher ON public.voucher_claims USING btree (voucher_id, redeemed_date DESC);

CREATE INDEX idx_voucher_types_org ON public.voucher_types USING btree (org_id);

CREATE INDEX idx_vouchers_branch ON public.vouchers USING btree (branch_id);

CREATE INDEX idx_vouchers_customer ON public.vouchers USING btree (customer_id);

CREATE INDEX idx_vouchers_guest_name ON public.vouchers USING btree (org_id, guest_name);

CREATE INDEX idx_vouchers_org ON public.vouchers USING btree (org_id);

CREATE INDEX idx_vouchers_type ON public.vouchers USING btree (voucher_type_id);

CREATE UNIQUE INDEX uniq_active_membership_per_customer ON public.memberships USING btree (org_id, customer_id) WHERE ((balance > (0)::numeric) OR (activation_date IS NULL));

CREATE UNIQUE INDEX uniq_org_membership_number ON public.memberships USING btree (org_id, membership_number) WHERE (membership_number IS NOT NULL);

CREATE INDEX voucher_payments_branch_created_idx ON public.voucher_payments USING btree (branch_id, created_at);

CREATE INDEX voucher_payments_voucher_id_idx ON public.voucher_payments USING btree (voucher_id);

CREATE INDEX idx_treatment_notes_booking ON public.treatment_notes USING btree (booking_id);

CREATE INDEX idx_treatment_notes_customer ON public.treatment_notes USING btree (customer_id);

CREATE TRIGGER bookings_normalize_phone BEFORE INSERT OR UPDATE OF customer_phone ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.trg_bookings_normalize_phone();

CREATE TRIGGER customers_normalize_phone BEFORE INSERT OR UPDATE OF phone ON public.customers FOR EACH ROW EXECUTE FUNCTION public.trg_customers_normalize_phone();

CREATE TRIGGER trg_booking_number BEFORE INSERT ON public.bookings FOR EACH ROW WHEN ((new.booking_number IS NULL)) EXECUTE FUNCTION public.generate_booking_number();

CREATE TRIGGER trg_compute_datetimes BEFORE INSERT OR UPDATE OF date, start_time, treatment_id ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.compute_booking_datetimes();

CREATE TRIGGER trg_compute_final_amount BEFORE INSERT OR UPDATE OF base_amount, discount_amount ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.compute_final_amount();

CREATE TRIGGER trg_enforce_booking_immutability BEFORE UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.enforce_booking_immutability();

CREATE TRIGGER trg_enforce_payroll_items_immutability BEFORE DELETE OR UPDATE ON public.payroll_items FOR EACH ROW EXECUTE FUNCTION public.enforce_payroll_immutability();

CREATE TRIGGER trg_enforce_payroll_runs_immutability BEFORE DELETE OR UPDATE ON public.payroll_runs FOR EACH ROW EXECUTE FUNCTION public.enforce_payroll_immutability();

CREATE TRIGGER trg_enforce_dentist_required BEFORE UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.enforce_dentist_for_active_bookings();

CREATE TRIGGER trg_handle_booking_cancellation_refund BEFORE UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.handle_booking_cancellation_refund();

CREATE TRIGGER trg_membership_recompute AFTER INSERT ON public.membership_transactions FOR EACH ROW EXECUTE FUNCTION public.membership_recompute();

CREATE TRIGGER trg_online_capacity_check BEFORE INSERT OR UPDATE OF branch_id, dentist_id, date, start_time, treatment_id, status ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.check_branch_online_capacity();

CREATE TRIGGER trg_organizations_updated_at BEFORE UPDATE ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_payment_update_booking_status AFTER INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION public.update_booking_payment_status();

-- Named to sort alphabetically AFTER trg_compute_datetimes: Postgres fires
-- same-event BEFORE triggers in trigger-name order, and this function reads
-- NEW.start_datetime/end_datetime, which trg_compute_datetimes computes.
-- (The original "room" naming happened to sort after "compute" too — renaming
-- to "chair" would silently invert that order and disable the overlap check.)
CREATE TRIGGER trg_verify_chair_capacity BEFORE INSERT OR UPDATE OF chair_id, date, start_time, treatment_id, status ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.check_chair_capacity();

CREATE TRIGGER trg_set_membership_number BEFORE INSERT ON public.memberships FOR EACH ROW EXECUTE FUNCTION public.set_membership_number();

CREATE TRIGGER trg_updated_at BEFORE UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.booking_dentists
    ADD CONSTRAINT booking_dentists_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.booking_dentists
    ADD CONSTRAINT booking_dentists_dentist_id_fkey FOREIGN KEY (dentist_id) REFERENCES public.dentists(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_customer_account_id_fkey FOREIGN KEY (customer_account_id) REFERENCES public.customer_accounts(id);

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_discount_approved_by_fkey FOREIGN KEY (discount_approved_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_discount_requested_by_fkey FOREIGN KEY (discount_requested_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_discount_requested_to_fkey FOREIGN KEY (discount_requested_to) REFERENCES public.users(id);

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_chair_id_fkey FOREIGN KEY (chair_id) REFERENCES public.chairs(id);

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_treatment_id_fkey FOREIGN KEY (treatment_id) REFERENCES public.treatments(id);

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_dentist_id_fkey FOREIGN KEY (dentist_id) REFERENCES public.dentists(id);

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.customer_accounts
    ADD CONSTRAINT customer_accounts_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.customer_accounts
    ADD CONSTRAINT customer_accounts_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);

ALTER TABLE ONLY public.customer_accounts
    ADD CONSTRAINT customer_accounts_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.customer_duplicate_dismissals
    ADD CONSTRAINT customer_duplicate_dismissals_customer_id_a_fkey FOREIGN KEY (customer_id_a) REFERENCES public.customers(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.customer_duplicate_dismissals
    ADD CONSTRAINT customer_duplicate_dismissals_customer_id_b_fkey FOREIGN KEY (customer_id_b) REFERENCES public.customers(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.customer_duplicate_dismissals
    ADD CONSTRAINT customer_duplicate_dismissals_dismissed_by_fkey FOREIGN KEY (dismissed_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.customer_duplicate_dismissals
    ADD CONSTRAINT customer_duplicate_dismissals_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.customer_referral_credits
    ADD CONSTRAINT customer_referral_credits_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.customer_referral_credits
    ADD CONSTRAINT customer_referral_credits_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.customer_referral_credits
    ADD CONSTRAINT customer_referral_credits_referral_id_fkey FOREIGN KEY (referral_id) REFERENCES public.customer_referrals(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.customer_referral_debits
    ADD CONSTRAINT customer_referral_debits_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.customer_referral_debits
    ADD CONSTRAINT customer_referral_debits_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.customer_referral_debits
    ADD CONSTRAINT customer_referral_debits_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.customer_referral_debits
    ADD CONSTRAINT customer_referral_debits_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.customer_referral_debits
    ADD CONSTRAINT customer_referral_debits_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES public.payments(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_credited_by_fkey FOREIGN KEY (credited_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_redeemed_booking_id_fkey FOREIGN KEY (redeemed_booking_id) REFERENCES public.bookings(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_redeemed_by_fkey FOREIGN KEY (redeemed_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_referred_customer_id_fkey FOREIGN KEY (referred_customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_referring_customer_id_fkey FOREIGN KEY (referring_customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.customer_referrals
    ADD CONSTRAINT customer_referrals_reward_catalog_id_fkey FOREIGN KEY (reward_catalog_id) REFERENCES public.reward_catalog(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_closed_by_fkey FOREIGN KEY (closed_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.membership_tiers
    ADD CONSTRAINT membership_tiers_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.membership_transactions
    ADD CONSTRAINT membership_transactions_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.membership_transactions
    ADD CONSTRAINT membership_transactions_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.membership_transactions
    ADD CONSTRAINT membership_transactions_membership_id_fkey FOREIGN KEY (membership_id) REFERENCES public.memberships(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.membership_transactions
    ADD CONSTRAINT membership_transactions_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.membership_transactions
    ADD CONSTRAINT membership_transactions_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES public.payments(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.membership_transactions
    ADD CONSTRAINT membership_transactions_performed_by_fkey FOREIGN KEY (performed_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.membership_transactions
    ADD CONSTRAINT membership_transactions_voucher_payment_id_fkey FOREIGN KEY (voucher_payment_id) REFERENCES public.voucher_payments(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_tier_id_fkey FOREIGN KEY (tier_id) REFERENCES public.membership_tiers(id);

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.org_commission_collections
    ADD CONSTRAINT org_commission_collections_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);

ALTER TABLE ONLY public.org_commission_collections
    ADD CONSTRAINT org_commission_collections_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.org_commission_rates
    ADD CONSTRAINT org_commission_rates_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);

ALTER TABLE ONLY public.org_commission_rates
    ADD CONSTRAINT org_commission_rates_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.outreach_ai_config
    ADD CONSTRAINT outreach_ai_config_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.outreach_drafts
    ADD CONSTRAINT outreach_drafts_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.outreach_messages(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.outreach_drafts
    ADD CONSTRAINT outreach_drafts_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.outreach_drafts
    ADD CONSTRAINT outreach_drafts_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.outreach_messages
    ADD CONSTRAINT outreach_messages_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.outreach_messages
    ADD CONSTRAINT outreach_messages_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.outreach_messages
    ADD CONSTRAINT outreach_messages_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.outreach_messages
    ADD CONSTRAINT outreach_messages_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES public.outreach_rules(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.outreach_provider_config
    ADD CONSTRAINT outreach_provider_config_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.outreach_rules
    ADD CONSTRAINT outreach_rules_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.outreach_rules
    ADD CONSTRAINT outreach_rules_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.outreach_templates(id);

ALTER TABLE ONLY public.outreach_templates
    ADD CONSTRAINT outreach_templates_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.outreach_templates
    ADD CONSTRAINT outreach_templates_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.package_redemptions
    ADD CONSTRAINT package_redemptions_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id);

ALTER TABLE ONLY public.package_redemptions
    ADD CONSTRAINT package_redemptions_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.package_redemptions
    ADD CONSTRAINT package_redemptions_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.package_redemptions
    ADD CONSTRAINT package_redemptions_package_id_fkey FOREIGN KEY (package_id) REFERENCES public.packages(id);

ALTER TABLE ONLY public.package_redemptions
    ADD CONSTRAINT package_redemptions_performed_by_fkey FOREIGN KEY (performed_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.package_types
    ADD CONSTRAINT package_types_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.package_types
    ADD CONSTRAINT package_types_treatment_id_fkey FOREIGN KEY (treatment_id) REFERENCES public.treatments(id);

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT packages_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT packages_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT packages_issued_by_fkey FOREIGN KEY (issued_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT packages_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT packages_package_type_id_fkey FOREIGN KEY (package_type_id) REFERENCES public.package_types(id);

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT packages_treatment_id_fkey FOREIGN KEY (treatment_id) REFERENCES public.treatments(id);

ALTER TABLE ONLY public.payment_refunds
    ADD CONSTRAINT payment_refunds_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.payment_refunds
    ADD CONSTRAINT payment_refunds_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.payment_refunds
    ADD CONSTRAINT payment_refunds_refunded_by_fkey FOREIGN KEY (refunded_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_recorded_by_fkey FOREIGN KEY (recorded_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.payroll_items
    ADD CONSTRAINT payroll_items_payroll_run_id_fkey FOREIGN KEY (payroll_run_id) REFERENCES public.payroll_runs(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.payroll_items
    ADD CONSTRAINT payroll_items_dentist_id_fkey FOREIGN KEY (dentist_id) REFERENCES public.dentists(id);

ALTER TABLE ONLY public.payroll_runs
    ADD CONSTRAINT payroll_runs_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.payroll_runs
    ADD CONSTRAINT payroll_runs_finalized_by_fkey FOREIGN KEY (finalized_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.payroll_runs
    ADD CONSTRAINT payroll_runs_generated_by_fkey FOREIGN KEY (generated_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.platform_admins
    ADD CONSTRAINT platform_admins_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.reward_catalog
    ADD CONSTRAINT reward_catalog_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.reward_catalog
    ADD CONSTRAINT reward_catalog_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.chairs
    ADD CONSTRAINT chairs_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.treatment_categories
    ADD CONSTRAINT treatment_categories_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.treatments
    ADD CONSTRAINT treatments_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.staff_compensation
    ADD CONSTRAINT staff_compensation_dentist_id_fkey FOREIGN KEY (dentist_id) REFERENCES public.dentists(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.staff_compensation
    ADD CONSTRAINT staff_compensation_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.dentist_attendance
    ADD CONSTRAINT dentist_attendance_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.dentist_attendance
    ADD CONSTRAINT dentist_attendance_marked_by_fkey FOREIGN KEY (marked_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.dentist_attendance
    ADD CONSTRAINT dentist_attendance_dentist_id_fkey FOREIGN KEY (dentist_id) REFERENCES public.dentists(id);

ALTER TABLE ONLY public.dentists
    ADD CONSTRAINT dentists_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.dentists
    ADD CONSTRAINT dentists_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.user_branches
    ADD CONSTRAINT user_branches_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.user_branches
    ADD CONSTRAINT user_branches_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.voucher_claims
    ADD CONSTRAINT voucher_claims_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.voucher_claims
    ADD CONSTRAINT voucher_claims_branch_claimed_id_fkey FOREIGN KEY (branch_claimed_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.voucher_claims
    ADD CONSTRAINT voucher_claims_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id);

ALTER TABLE ONLY public.voucher_claims
    ADD CONSTRAINT voucher_claims_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES public.payments(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.voucher_claims
    ADD CONSTRAINT voucher_claims_performed_by_fkey FOREIGN KEY (performed_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.voucher_claims
    ADD CONSTRAINT voucher_claims_voucher_id_fkey FOREIGN KEY (voucher_id) REFERENCES public.vouchers(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.voucher_code_counters
    ADD CONSTRAINT voucher_code_counters_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.voucher_code_counters
    ADD CONSTRAINT voucher_code_counters_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.voucher_payments
    ADD CONSTRAINT voucher_payments_voucher_id_fkey FOREIGN KEY (voucher_id) REFERENCES public.vouchers(id);

ALTER TABLE ONLY public.voucher_types
    ADD CONSTRAINT voucher_types_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.vouchers
    ADD CONSTRAINT vouchers_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);

ALTER TABLE ONLY public.vouchers
    ADD CONSTRAINT vouchers_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);

ALTER TABLE ONLY public.vouchers
    ADD CONSTRAINT vouchers_issued_by_fkey FOREIGN KEY (issued_by) REFERENCES public.users(id);

ALTER TABLE ONLY public.vouchers
    ADD CONSTRAINT vouchers_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.vouchers
    ADD CONSTRAINT vouchers_voucher_type_id_fkey FOREIGN KEY (voucher_type_id) REFERENCES public.voucher_types(id);

ALTER TABLE ONLY public.treatment_notes
    ADD CONSTRAINT treatment_notes_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.treatment_notes
    ADD CONSTRAINT treatment_notes_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.treatment_notes
    ADD CONSTRAINT treatment_notes_dentist_id_fkey FOREIGN KEY (dentist_id) REFERENCES public.dentists(id) ON DELETE SET NULL;


-- ============================================================================
-- Role grants
-- ============================================================================
-- A fresh Supabase project sets these up automatically, but a schema created
-- via DROP SCHEMA public CASCADE + this file's CREATE statements does not —
-- discovered the hard way while standing up staging. Every table/RPC access
-- from the anon/authenticated roles depends on this running once per project.

GRANT USAGE ON SCHEMA public TO postgres, anon, authenticated, service_role;

GRANT ALL ON ALL TABLES IN SCHEMA public TO postgres, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO anon, authenticated;

GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO postgres, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated;

GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO postgres, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO postgres, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated;
