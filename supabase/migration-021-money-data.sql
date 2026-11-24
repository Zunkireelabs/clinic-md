-- Migration 021 (CMD-115, Money Part 0): receipts and bills, BS calendar and fiscal year, refunds and refund requests,
-- two-step daily closing, locks by money-event date. NOT applied to prod. Rollback: migration-021-rollback.sql.
-- Needs 011-018 applied first (does not need 019 or 020). Design: docs/briefs/money-data-design.md (approved 9.3/10, round 3).
--
-- Nothing here rewires the client: payments, refunds and closings made by the current screens behave as before
-- (the day lock and the immutability of receipt-linked payments are the only new refusals). BS calendar ROWS are not in
-- this file yet: they come from a checked-in generated file once the converter is approved (CMD-115, needs-verification).
--
-- Who may do what (compare 014): writes are only through act_* wrappers (012 pattern). Inner functions have no grants.
--   can_write_money(): staff, manager, admin   | refunds, bill cancel, close: manager, admin | reopen, billing mode: admin

BEGIN;

-- ============================================================================================================================
-- 1. Helpers
-- ============================================================================================================================

-- True when the statement runs as the role that owns the SECURITY DEFINER functions (migrations, seeds, definer code), not as a
-- client role (authenticated, anon, service_role). INVOKER on purpose: inside a SECURITY DEFINER function current_user is always the
-- owner, so this must run in the caller's own context (triggers on payments and bookings are INVOKER).
CREATE OR REPLACE FUNCTION public._money_is_owner_ctx() RETURNS boolean
  LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT current_user = (SELECT r.rolname FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
                          WHERE p.oid = 'public.sync_booking_payment_status(uuid)'::regprocedure);
$$;
REVOKE ALL ON FUNCTION public._money_is_owner_ctx() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._money_is_owner_ctx() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._money_day(p_ts timestamptz) RETURNS date
  LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT (p_ts AT TIME ZONE 'Asia/Kathmandu')::date;
$$;
REVOKE ALL ON FUNCTION public._money_day(timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._money_day(timestamptz) TO authenticated, service_role;

-- ============================================================================================================================
-- 2. BS calendar and fiscal year (rows come later: see header)
-- ============================================================================================================================
CREATE TABLE public.bs_calendar (
  ad_date  date PRIMARY KEY,
  bs_year  integer NOT NULL CHECK (bs_year BETWEEN 2000 AND 3000),
  bs_month integer NOT NULL CHECK (bs_month BETWEEN 1 AND 12),
  bs_day   integer NOT NULL CHECK (bs_day BETWEEN 1 AND 32)
);
CREATE INDEX bs_calendar_bs_idx ON public.bs_calendar (bs_year, bs_month, bs_day);
ALTER TABLE public.bs_calendar ENABLE ROW LEVEL SECURITY;
CREATE POLICY bs_calendar_read ON public.bs_calendar FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.bs_calendar FROM PUBLIC, anon;
GRANT SELECT ON public.bs_calendar TO authenticated;

CREATE OR REPLACE FUNCTION public.bs_date(p_ad date) RETURNS TABLE (bs_year integer, bs_month integer, bs_day integer)
  LANGUAGE plpgsql STABLE SET search_path = public AS $$
BEGIN
  RETURN QUERY SELECT c.bs_year, c.bs_month, c.bs_day FROM public.bs_calendar c WHERE c.ad_date = p_ad;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'BS_OUT_OF_RANGE: no BS date for %', p_ad USING ERRCODE = 'P0001';
  END IF;
END $$;

-- '2083/84': a Nepali fiscal year starts on 1 Shrawan (BS month 4).
CREATE OR REPLACE FUNCTION public.fiscal_year(p_ad date) RETURNS text
  LANGUAGE plpgsql STABLE SET search_path = public AS $$
DECLARE c public.bs_calendar;
BEGIN
  SELECT * INTO c FROM public.bs_calendar WHERE ad_date = p_ad;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'BS_OUT_OF_RANGE: no BS date for %', p_ad USING ERRCODE = 'P0001';
  END IF;
  IF c.bs_month >= 4 THEN
    RETURN c.bs_year::text || '/' || lpad(((c.bs_year + 1) % 100)::text, 2, '0');
  END IF;
  RETURN (c.bs_year - 1)::text || '/' || lpad((c.bs_year % 100)::text, 2, '0');
END $$;

-- printed BS date 'YYYY-MM-DD'
CREATE OR REPLACE FUNCTION public.bs_date_text(p_ad date) RETURNS text
  LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT format('%s-%s-%s', b.bs_year, lpad(b.bs_month::text, 2, '0'), lpad(b.bs_day::text, 2, '0')) FROM public.bs_date(p_ad) b;
$$;
REVOKE ALL ON FUNCTION public.bs_date(date), public.fiscal_year(date), public.bs_date_text(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bs_date(date), public.fiscal_year(date), public.bs_date_text(date) TO authenticated, service_role;

-- ============================================================================================================================
-- 3. Settings, counters, documents, requests
-- ============================================================================================================================
CREATE TABLE public.org_billing_settings (
  org_id          uuid PRIMARY KEY REFERENCES public.organizations(id),
  pan             text,
  pan_bill_mode   boolean NOT NULL DEFAULT false,
  mode_changed_at timestamptz,
  mode_changed_by uuid REFERENCES public.users(id)
);

CREATE TABLE public.money_counters (
  org_id      uuid NOT NULL REFERENCES public.organizations(id),
  series      text NOT NULL CHECK (series IN ('receipt', 'pan_bill', 'credit_note')),
  fiscal_year text NOT NULL,
  last_seq    integer NOT NULL CHECK (last_seq >= 1),
  PRIMARY KEY (org_id, series, fiscal_year)
);

CREATE TABLE public.money_documents (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL REFERENCES public.organizations(id),
  branch_id           uuid NOT NULL REFERENCES public.branches(id),
  kind                text NOT NULL CHECK (kind IN ('receipt', 'refund_note', 'pan_bill', 'credit_note')),
  series              text NOT NULL CHECK (series IN ('receipt', 'pan_bill', 'credit_note')),
  fiscal_year         text NOT NULL,
  seq                 integer NOT NULL CHECK (seq >= 1),
  number              text NOT NULL,
  customer_id         uuid REFERENCES public.customers(id),
  buyer_name          text,
  buyer_pan           text,
  booking_ids         uuid[] NOT NULL DEFAULT '{}',
  lines               jsonb NOT NULL DEFAULT '[]',
  total               numeric(12,2) NOT NULL CHECK (total > 0),
  method_summary      jsonb NOT NULL DEFAULT '[]',
  issued_by           uuid REFERENCES public.users(id),
  issued_by_name      text,
  issued_at           timestamptz NOT NULL DEFAULT now(),
  bs_date             text,
  related_document_id uuid REFERENCES public.money_documents(id),
  status              text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued', 'cancelled')),
  cancel_reason       text,
  cancelled_by        uuid REFERENCES public.users(id),
  cancelled_at        timestamptz,
  print_count         integer NOT NULL DEFAULT 0 CHECK (print_count >= 0),
  sent                jsonb NOT NULL DEFAULT '[]',
  CONSTRAINT money_documents_series_kind CHECK (
    (kind IN ('receipt', 'refund_note') AND series = 'receipt') OR (kind = 'pan_bill' AND series = 'pan_bill') OR (kind = 'credit_note' AND series = 'credit_note')),
  CONSTRAINT money_documents_related CHECK ((kind IN ('refund_note', 'credit_note')) = (related_document_id IS NOT NULL)),
  CONSTRAINT money_documents_cancel CHECK (status = 'issued' OR (cancel_reason IS NOT NULL AND cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL)),
  -- the number is NOT unique on its own: PAN bill 1189 and CN-14 repeat every fiscal year
  CONSTRAINT money_documents_seq_uq UNIQUE (org_id, series, fiscal_year, seq),
  CONSTRAINT money_documents_number_uq UNIQUE (org_id, series, fiscal_year, number)
);
CREATE INDEX money_documents_branch_day ON public.money_documents (branch_id, issued_at);
CREATE INDEX money_documents_customer ON public.money_documents (customer_id);

CREATE TABLE public.money_requests (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.organizations(id),
  branch_id       uuid NOT NULL REFERENCES public.branches(id),
  kind            text NOT NULL CHECK (kind IN ('refund')),
  document_id     uuid REFERENCES public.money_documents(id),
  booking_id      uuid REFERENCES public.bookings(id),
  amount          numeric(12,2) NOT NULL CHECK (amount > 0),
  note            text,
  requested_by    uuid REFERENCES public.users(id),
  requested_at    timestamptz NOT NULL DEFAULT now(),
  assigned_to     uuid REFERENCES public.users(id),
  status          text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'declined')),
  resolved_by     uuid REFERENCES public.users(id),
  resolved_at     timestamptz,
  resolution_note text
);
CREATE INDEX money_requests_open ON public.money_requests (branch_id, status);

-- additions to existing tables (old rows keep NULL / their old values)
ALTER TABLE public.payments        ADD COLUMN document_id uuid REFERENCES public.money_documents(id);
ALTER TABLE public.payment_refunds ADD COLUMN document_id uuid REFERENCES public.money_documents(id);
ALTER TABLE public.payment_refunds ADD COLUMN paid_back_by text;
CREATE INDEX payments_document_idx ON public.payments (document_id) WHERE document_id IS NOT NULL;

-- daily_reports: existing rows are closings (status 'closed'), and the client's closeDay keeps inserting closed rows.
ALTER TABLE public.daily_reports
  ADD COLUMN status text NOT NULL DEFAULT 'closed' CHECK (status IN ('counted', 'closed', 'reopened')),
  ADD COLUMN blind_counts jsonb,
  ADD COLUMN difference_reason text,
  ADD COLUMN submitted_by uuid REFERENCES public.users(id),
  ADD COLUMN submitted_at timestamptz,
  ADD COLUMN reopened_at timestamptz,
  ADD COLUMN reopened_by uuid REFERENCES public.users(id),
  ADD COLUMN reopen_reason text,
  ADD COLUMN superseded_by uuid REFERENCES public.daily_reports(id);
ALTER TABLE public.daily_reports DROP CONSTRAINT uq_daily_report_branch_date;
-- one CURRENT row per branch and day: a reopened row is history (it stays, with who and why), a later count/closing is a new row
CREATE UNIQUE INDEX uq_daily_report_current ON public.daily_reports (branch_id, report_date) WHERE superseded_by IS NULL AND status <> 'reopened';

-- ============================================================================================================================
-- 4. RLS: reads only (all writes go through definer code). practitioner reads nothing (can_read_money), admin_viewer reads.
-- ============================================================================================================================
ALTER TABLE public.org_billing_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.money_counters       ENABLE ROW LEVEL SECURITY;   -- no policy: nobody reads or writes it directly
ALTER TABLE public.money_documents      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.money_requests       ENABLE ROW LEVEL SECURITY;

CREATE POLICY org_billing_settings_read ON public.org_billing_settings FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id() AND public.can_read_money());
CREATE POLICY money_documents_read ON public.money_documents FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id() AND public.can_read_money()
         AND (public.get_user_role()::text IN ('admin', 'admin_viewer') OR branch_id = ANY (public.get_user_branch_ids())));
CREATE POLICY money_requests_read ON public.money_requests FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id() AND public.can_read_money()
         AND (public.get_user_role()::text IN ('admin', 'admin_viewer') OR branch_id = ANY (public.get_user_branch_ids())));

REVOKE ALL ON public.org_billing_settings, public.money_counters, public.money_documents, public.money_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.org_billing_settings, public.money_documents, public.money_requests TO authenticated;

-- ============================================================================================================================
-- 5. Locks, by money-event date (design section 5)
-- ============================================================================================================================
-- A day is closed for a branch when its CURRENT daily_reports row is 'closed'.
CREATE OR REPLACE FUNCTION public.day_is_closed(p_branch uuid, p_date date) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.daily_reports d
                  WHERE d.branch_id = p_branch AND d.report_date = p_date AND d.superseded_by IS NULL AND d.status = 'closed');
$$;
REVOKE ALL ON FUNCTION public.day_is_closed(uuid, date) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._money_assert_day_open(p_branch uuid, p_ts timestamptz) RETURNS void
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_branch IS NOT NULL AND public.day_is_closed(p_branch, public._money_day(p_ts)) THEN
    RAISE EXCEPTION 'DAY_LOCKED: This day has been closed. No further modifications allowed.' USING ERRCODE = 'P0001';
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._money_assert_day_open(uuid, timestamptz) FROM PUBLIC, anon, authenticated, service_role;

-- 5a. payments: BEFORE guard (INVOKER, so current_user is the caller's role)
--   * a client can never set or change document_id (only definer code can, i.e. money_collect);
--   * created_at is now() for any client insert, and can never be changed (a future or past stamp cannot dodge the day lock);
--   * a payment on a receipt is immutable: no change to amount, mode, booking or document, and no delete, for anyone.
-- Owner context (migrations, seeds, definer code) may still stamp history on INSERT.
CREATE OR REPLACE FUNCTION public.trg_payments_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.document_id IS NOT NULL AND NOT public._money_is_owner_ctx() THEN
      RAISE EXCEPTION 'DOC_PAYMENT_FORBIDDEN: a payment can only be linked to a receipt by the collect function.' USING ERRCODE = 'P0001';
    END IF;
    IF NOT public._money_is_owner_ctx() THEN
      NEW.created_at := now();
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.document_id IS DISTINCT FROM OLD.document_id AND NOT public._money_is_owner_ctx() THEN
      RAISE EXCEPTION 'DOC_PAYMENT_FORBIDDEN: a payment can only be linked to a receipt by the collect function.' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'TIME_IMMUTABLE: the time of a payment cannot be changed.' USING ERRCODE = 'P0001';
    END IF;
    IF OLD.document_id IS NOT NULL AND (NEW.amount IS DISTINCT FROM OLD.amount OR NEW.payment_mode IS DISTINCT FROM OLD.payment_mode
        OR NEW.booking_id IS DISTINCT FROM OLD.booking_id OR NEW.document_id IS DISTINCT FROM OLD.document_id) THEN
      RAISE EXCEPTION 'DOC_PAYMENT_IMMUTABLE: a payment on a receipt cannot be changed. Refund it and issue a refund note.' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  ELSE
    IF OLD.document_id IS NOT NULL THEN
      RAISE EXCEPTION 'DOC_PAYMENT_IMMUTABLE: a payment on a receipt cannot be deleted. Refund it and issue a refund note.' USING ERRCODE = 'P0001';
    END IF;
    RETURN OLD;
  END IF;
END $$;
CREATE TRIGGER trg_payments_guard BEFORE INSERT OR UPDATE OR DELETE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.trg_payments_guard();

-- 5b. payments: AFTER trigger (SECURITY DEFINER, from 007) now also checks the day, and lets money_collect's payments on a
--     locked booking through (only: document_id set at INSERT AND equal to the money.doc this transaction's collect set).
--     Every definer function shares the owner, so current_user alone does not single out money_collect: money.doc does.
CREATE OR REPLACE FUNCTION public.update_booking_payment_status() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_bypass boolean := false;
  v_branch uuid;
BEGIN
  IF TG_OP = 'INSERT' AND NEW.document_id IS NOT NULL
     AND NEW.document_id::text = NULLIF(current_setting('money.doc', true), '') THEN
    v_bypass := true;
  END IF;

  IF NOT v_bypass AND EXISTS (
    SELECT 1 FROM public.bookings b
    WHERE b.is_locked
      AND b.id IN (
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN NEW.booking_id END,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN OLD.booking_id END)
  ) THEN
    RAISE EXCEPTION 'DAY_LOCKED: This day has been closed. No further modifications allowed.'
      USING ERRCODE = 'P0001';
  END IF;

  -- money-event day: the day the payment was taken (created_at), for the branch of its booking. OLD and NEW.
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    SELECT branch_id INTO v_branch FROM public.bookings WHERE id = NEW.booking_id;
    PERFORM public._money_assert_day_open(v_branch, NEW.created_at);
  END IF;
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    SELECT branch_id INTO v_branch FROM public.bookings WHERE id = OLD.booking_id;
    PERFORM public._money_assert_day_open(v_branch, OLD.created_at);
  END IF;

  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM public.sync_booking_payment_status(NEW.booking_id);
  END IF;
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.booking_id IS DISTINCT FROM NEW.booking_id) THEN
    PERFORM public.sync_booking_payment_status(OLD.booking_id);
  END IF;
  RETURN NULL;
END $$;

-- 5c. bookings: two narrow exceptions to "a locked booking never changes" (enforce_booking_immutability, INVOKER).
--   (1) payment_status only, by money_collect: owner context, this transaction's money.doc names a document issued now that lists
--       this booking, nothing else on the row changed, and the new status is the one the payments sum gives.
--   (2) is_locked true -> false only, by day_reopen: owner context, money.reopen names this booking's branch and day.
CREATE OR REPLACE FUNCTION public.enforce_booking_immutability() RETURNS trigger
  LANGUAGE plpgsql SET search_path TO 'public' AS $$
BEGIN
  IF OLD.is_locked = true THEN
    IF public._money_is_owner_ctx()
       AND NULLIF(current_setting('money.doc', true), '') IS NOT NULL
       AND NEW.payment_status IS DISTINCT FROM OLD.payment_status
       AND (to_jsonb(NEW) - 'payment_status' - 'updated_at') = (to_jsonb(OLD) - 'payment_status' - 'updated_at')
       AND NEW.payment_status = public.derive_payment_status((SELECT COALESCE(SUM(amount), 0) FROM public.payments WHERE booking_id = OLD.id), OLD.final_amount)
       AND EXISTS (SELECT 1 FROM public.money_documents d
                    WHERE d.id::text = current_setting('money.doc', true) AND d.issued_at = now() AND OLD.id = ANY (d.booking_ids)) THEN
      RETURN NEW;
    END IF;
    IF public._money_is_owner_ctx()
       AND NEW.is_locked = false
       AND NULLIF(current_setting('money.reopen', true), '') = OLD.branch_id::text || ':' || OLD.date::text
       AND (to_jsonb(NEW) - 'is_locked' - 'updated_at') = (to_jsonb(OLD) - 'is_locked' - 'updated_at') THEN
      RETURN NEW;
    END IF;
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
END $$;

-- 5d. payment_refunds: time is now() for a client insert and never changes, no delete (INVOKER guard), and the event day must be
--     open, for OLD and NEW (DEFINER day check; an INVOKER trigger could not call the revoked helper).
CREATE OR REPLACE FUNCTION public.trg_payment_refunds_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'REFUND_IMMUTABLE: a refund cannot be deleted.' USING ERRCODE = 'P0001';
  ELSIF TG_OP = 'INSERT' THEN
    IF NOT public._money_is_owner_ctx() THEN
      NEW.created_at := now();
    END IF;
  ELSIF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'TIME_IMMUTABLE: the time of a refund cannot be changed.' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_payment_refunds_guard BEFORE INSERT OR UPDATE OR DELETE ON public.payment_refunds
  FOR EACH ROW EXECUTE FUNCTION public.trg_payment_refunds_guard();

CREATE OR REPLACE FUNCTION public.trg_payment_refunds_day() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_branch uuid;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    SELECT branch_id INTO v_branch FROM public.bookings WHERE id = OLD.booking_id;
    PERFORM public._money_assert_day_open(v_branch, OLD.created_at);
  END IF;
  SELECT branch_id INTO v_branch FROM public.bookings WHERE id = NEW.booking_id;
  PERFORM public._money_assert_day_open(v_branch, NEW.created_at);
  RETURN NEW;
END $$;
-- named so it runs after trg_payment_refunds_guard (alphabetical): the day is checked on the final created_at
CREATE TRIGGER trg_payment_refunds_i_day BEFORE INSERT OR UPDATE ON public.payment_refunds
  FOR EACH ROW EXECUTE FUNCTION public.trg_payment_refunds_day();
REVOKE ALL ON FUNCTION public.trg_payment_refunds_guard(), public.trg_payment_refunds_day(), public.trg_payments_guard() FROM PUBLIC, anon;

-- 5e. money_documents: issued_at is now() and the day must be open (DEFINER); immutable except print/send/cancel (PAN bill only).
CREATE OR REPLACE FUNCTION public.trg_money_documents_insert() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.issued_at := now();
  PERFORM public._money_assert_day_open(NEW.branch_id, NEW.issued_at);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_money_documents_insert BEFORE INSERT ON public.money_documents
  FOR EACH ROW EXECUTE FUNCTION public.trg_money_documents_insert();

CREATE OR REPLACE FUNCTION public.trg_money_documents_immutable() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'DOC_IMMUTABLE: a receipt or bill is never deleted.' USING ERRCODE = 'P0001';
  END IF;
  IF (to_jsonb(NEW) - 'print_count' - 'sent' - 'status' - 'cancel_reason' - 'cancelled_by' - 'cancelled_at')
     IS DISTINCT FROM (to_jsonb(OLD) - 'print_count' - 'sent' - 'status' - 'cancel_reason' - 'cancelled_by' - 'cancelled_at') THEN
    RAISE EXCEPTION 'DOC_IMMUTABLE: a receipt or bill cannot be changed.' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (OLD.status = 'issued' AND NEW.status = 'cancelled' AND OLD.kind = 'pan_bill') THEN
      RAISE EXCEPTION 'DOC_IMMUTABLE: only an issued PAN bill can be cancelled.' USING ERRCODE = 'P0001';
    END IF;
    PERFORM public._money_assert_day_open(OLD.branch_id, now());
  ELSIF NEW.cancel_reason IS DISTINCT FROM OLD.cancel_reason OR NEW.cancelled_by IS DISTINCT FROM OLD.cancelled_by
        OR NEW.cancelled_at IS DISTINCT FROM OLD.cancelled_at THEN
    RAISE EXCEPTION 'DOC_IMMUTABLE: cancel details cannot be changed.' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.print_count < OLD.print_count THEN
    RAISE EXCEPTION 'DOC_IMMUTABLE: the print count only goes up.' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_money_documents_immutable BEFORE UPDATE OR DELETE ON public.money_documents
  FOR EACH ROW EXECUTE FUNCTION public.trg_money_documents_immutable();
REVOKE ALL ON FUNCTION public.trg_money_documents_insert(), public.trg_money_documents_immutable() FROM PUBLIC, anon;
