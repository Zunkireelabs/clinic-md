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
-- a blind count creates the row before anybody closes the day
ALTER TABLE public.daily_reports ALTER COLUMN closed_by DROP NOT NULL, ALTER COLUMN closed_at DROP NOT NULL;
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

-- ============================================================================================================================
-- 6. Numbering and documents
-- ============================================================================================================================
CREATE OR REPLACE FUNCTION public.money_format_number(p_kind text, p_fy text, p_seq integer) RETURNS text
  LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE p_kind
           WHEN 'receipt'     THEN p_fy || '-' || p_seq::text      -- 2083/84-1189 (receipts and refund notes share the series)
           WHEN 'refund_note' THEN p_fy || '-' || p_seq::text
           WHEN 'pan_bill'    THEN p_seq::text                      -- 1189, per fiscal year
           WHEN 'credit_note' THEN 'CN-' || p_seq::text             -- CN-14, per fiscal year
         END;
$$;
REVOKE ALL ON FUNCTION public.money_format_number(text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.money_format_number(text, text, integer) TO authenticated, service_role;

-- Takes the next number. The ON CONFLICT path locks the counter row until the issuing transaction ends, so concurrent issuers
-- queue; a rollback rolls the counter back too (no gap, no reuse).
CREATE OR REPLACE FUNCTION public._money_next_number(p_org uuid, p_series text, p_fy text) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_seq integer;
BEGIN
  INSERT INTO public.money_counters (org_id, series, fiscal_year, last_seq) VALUES (p_org, p_series, p_fy, 1)
  ON CONFLICT (org_id, series, fiscal_year) DO UPDATE SET last_seq = public.money_counters.last_seq + 1
  RETURNING last_seq INTO v_seq;
  RETURN v_seq;
END $$;
REVOKE ALL ON FUNCTION public._money_next_number(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;

-- Issues one document. The day check comes first (DAY_LOCKED before any number is taken).
CREATE OR REPLACE FUNCTION public._money_issue_document(p_org uuid, p_branch uuid, p_kind text, p_customer uuid, p_buyer_name text, p_buyer_pan text,
    p_booking_ids uuid[], p_lines jsonb, p_total numeric, p_methods jsonb, p_user uuid, p_related uuid) RETURNS public.money_documents
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_series text := CASE p_kind WHEN 'pan_bill' THEN 'pan_bill' WHEN 'credit_note' THEN 'credit_note' ELSE 'receipt' END;
  v_day date := public._money_day(now());
  v_fy text; v_seq integer; v_doc public.money_documents; v_name text;
BEGIN
  PERFORM public._money_assert_day_open(p_branch, now());
  v_fy := public.fiscal_year(v_day);
  v_seq := public._money_next_number(p_org, v_series, v_fy);
  SELECT full_name INTO v_name FROM public.users WHERE id = p_user;
  INSERT INTO public.money_documents (org_id, branch_id, kind, series, fiscal_year, seq, number, customer_id, buyer_name, buyer_pan, booking_ids, lines,
                                      total, method_summary, issued_by, issued_by_name, bs_date, related_document_id)
  VALUES (p_org, p_branch, p_kind, v_series, v_fy, v_seq, public.money_format_number(p_kind, v_fy, v_seq), p_customer, p_buyer_name, p_buyer_pan,
          p_booking_ids, p_lines, p_total, COALESCE(p_methods, '[]'), p_user, v_name, public.bs_date_text(v_day), p_related)
  RETURNING * INTO v_doc;
  RETURN v_doc;
END $$;
REVOKE ALL ON FUNCTION public._money_issue_document(uuid, uuid, text, uuid, text, text, uuid[], jsonb, numeric, jsonb, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._money_pan_mode(p_org uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT pan_bill_mode FROM public.org_billing_settings WHERE org_id = p_org), false);
$$;
REVOKE ALL ON FUNCTION public._money_pan_mode(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- ============================================================================================================================
-- 7. Inner functions (no grants; called only by their act_* wrapper, which has already resolved the caller into p_ctx)
--    They RAISE 'CODE: text' (P0001); messages never carry amounts, counts or totals (a message with figures would leak to staff).
-- ============================================================================================================================

-- 7.1 collect: day check -> lines -> number -> document -> money.doc -> payments WITH document_id (never UPDATEd afterwards)
CREATE OR REPLACE FUNCTION public._money_collect(p_ctx jsonb, p_lines jsonb, p_tenders jsonb, p_customer uuid, p_buyer_name text, p_buyer_pan text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org uuid := (p_ctx ->> 'org_id')::uuid; v_user uuid := (p_ctx ->> 'user_id')::uuid;
  ids uuid[] := '{}'; amts numeric[] := '{}'; e jsonb; i integer; piece numeric; t_rem numeric; take numeric;
  v_lines_total numeric := 0; v_tender_total numeric := 0;
  b record; v_paid numeric; v_branch uuid; v_cust text; v_customer_id uuid;
  v_pan boolean; v_kind text; v_doc public.money_documents;
  v_doc_lines jsonb := '[]'; v_methods jsonb;
  v_pkg_count integer := 0; v_mode text; v_pkg uuid;
BEGIN
  -- parse (INVALID_INPUT on anything malformed)
  BEGIN
    IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 OR jsonb_typeof(p_tenders) <> 'array' OR jsonb_array_length(p_tenders) = 0 THEN
      RAISE EXCEPTION 'INVALID_INPUT: lines and tenders are required.' USING ERRCODE = 'P0001';
    END IF;
    FOR e IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      IF (e ->> 'booking_id')::uuid = ANY (ids) THEN RAISE EXCEPTION 'INVALID_INPUT: a booking appears twice.' USING ERRCODE = 'P0001'; END IF;
      IF (e ->> 'amount')::numeric <= 0 OR (e ->> 'amount')::numeric <> round((e ->> 'amount')::numeric, 2) THEN
        RAISE EXCEPTION 'INVALID_INPUT: amounts must be positive with at most 2 decimals.' USING ERRCODE = 'P0001'; END IF;
      ids := ids || (e ->> 'booking_id')::uuid; amts := amts || (e ->> 'amount')::numeric; v_lines_total := v_lines_total + (e ->> 'amount')::numeric;
    END LOOP;
    FOR e IN SELECT * FROM jsonb_array_elements(p_tenders) LOOP
      IF (e ->> 'amount')::numeric <= 0 OR (e ->> 'amount')::numeric <> round((e ->> 'amount')::numeric, 2)
         OR btrim(COALESCE(e ->> 'mode', '')) = '' OR length(e ->> 'mode') > 40 THEN
        RAISE EXCEPTION 'INVALID_INPUT: each tender needs a method and a positive amount with at most 2 decimals.' USING ERRCODE = 'P0001'; END IF;
      v_tender_total := v_tender_total + (e ->> 'amount')::numeric;
    END LOOP;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value OR null_value_not_allowed THEN
    RAISE EXCEPTION 'INVALID_INPUT: the lines or tenders are malformed.' USING ERRCODE = 'P0001';
  END;

  -- tender kinds: plain methods and SessionPackage only (wallet tenders are out of scope: Money shows packages only)
  FOR e IN SELECT * FROM jsonb_array_elements(p_tenders) LOOP
    v_mode := e ->> 'mode';
    IF v_mode IN ('Membership', 'ReferralWallet', 'ReferralVoucher', 'VoucherWallet') THEN
      RAISE EXCEPTION 'UNSUPPORTED_TENDER: this payment method is not available here.' USING ERRCODE = 'P0001';
    END IF;
    IF v_mode = 'SessionPackage' THEN
      v_pkg_count := v_pkg_count + 1;
      IF (e ->> 'package_id') IS NULL THEN RAISE EXCEPTION 'INVALID_INPUT: a session package tender needs a package.' USING ERRCODE = 'P0001'; END IF;
    END IF;
  END LOOP;
  IF v_pkg_count > 0 AND array_length(ids, 1) > 1 THEN
    RAISE EXCEPTION 'UNSUPPORTED_TENDER: a session package can only settle one booking at a time.' USING ERRCODE = 'P0001';
  END IF;
  IF v_tender_total <> v_lines_total THEN
    RAISE EXCEPTION 'TENDER_MISMATCH: the tenders must add up to the lines.' USING ERRCODE = 'P0001';
  END IF;

  -- bookings, locked in id order (no deadlock between two collects), same org, in the caller's branches
  i := 0;
  FOR b IN SELECT bk.*, br.org_id AS b_org FROM public.bookings bk JOIN public.branches br ON br.id = bk.branch_id
            WHERE bk.id = ANY (ids) ORDER BY bk.id FOR UPDATE OF bk LOOP
    i := i + 1;
    IF b.b_org <> v_org OR NOT public._act_in_scope(p_ctx, b.b_org, b.branch_id) THEN
      RAISE EXCEPTION 'BOOKING_NOT_FOUND: Booking not found.' USING ERRCODE = 'P0001';
    END IF;
    IF v_branch IS NOT NULL AND v_branch <> b.branch_id THEN RAISE EXCEPTION 'MIXED_BRANCH: all bookings must be in one branch.' USING ERRCODE = 'P0001'; END IF;
    v_branch := b.branch_id;
    IF v_cust IS NOT NULL AND v_cust <> COALESCE(b.customer_id::text, 'n:' || b.customer_name) THEN
      RAISE EXCEPTION 'MIXED_CUSTOMER: all bookings must belong to one patient.' USING ERRCODE = 'P0001'; END IF;
    v_cust := COALESCE(b.customer_id::text, 'n:' || b.customer_name);
    IF b.status NOT IN ('Confirmed', 'In-Progress', 'Completed') OR b.payment_status = 'refunded' THEN
      RAISE EXCEPTION 'INVALID_PAYMENT_STATE: this booking cannot take a payment.' USING ERRCODE = 'P0001'; END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM public.payments WHERE booking_id = b.id;
    IF amts[array_position(ids, b.id)] > b.final_amount - v_paid THEN
      RAISE EXCEPTION 'OVERPAY: a line is more than the booking still owes.' USING ERRCODE = 'P0001'; END IF;
  END LOOP;
  IF i <> array_length(ids, 1) THEN RAISE EXCEPTION 'BOOKING_NOT_FOUND: Booking not found.' USING ERRCODE = 'P0001'; END IF;
  IF p_customer IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.bookings WHERE id = ids[1] AND customer_id = p_customer) THEN
    RAISE EXCEPTION 'MIXED_CUSTOMER: the patient does not match the booking.' USING ERRCODE = 'P0001'; END IF;

  -- 4. the day (before any number is taken)
  PERFORM public._money_assert_day_open(v_branch, now());

  -- 5. document lines (computed from p_lines, no insert yet)
  FOR i IN 1..array_length(ids, 1) LOOP
    SELECT jsonb_build_object('label', COALESCE(treatment_name_snapshot, 'Visit') || ' · ' || booking_number, 'amount', amts[i], 'ref', id)
      INTO e FROM public.bookings WHERE id = ids[i];
    v_doc_lines := v_doc_lines || e;
  END LOOP;
  SELECT jsonb_agg(jsonb_build_object('mode', mode, 'amount', amt) ORDER BY mode) INTO v_methods
    FROM (SELECT x ->> 'mode' AS mode, SUM((x ->> 'amount')::numeric) AS amt FROM jsonb_array_elements(p_tenders) x GROUP BY 1) m;
  v_pan := public._money_pan_mode(v_org);
  v_kind := CASE WHEN v_pan THEN 'pan_bill' ELSE 'receipt' END;
  SELECT bk.customer_id, COALESCE(NULLIF(btrim(p_buyer_name), ''), bk.customer_name) INTO v_customer_id, p_buyer_name FROM public.bookings bk WHERE bk.id = ids[1];

  -- 6/7. number + document, then money.doc for this transaction
  v_doc := public._money_issue_document(v_org, v_branch, v_kind, v_customer_id, p_buyer_name, NULLIF(btrim(p_buyer_pan), ''), ids, v_doc_lines,
                                        v_lines_total, v_methods, v_user, NULL);
  PERFORM set_config('money.doc', v_doc.id::text, true);

  -- 8. payments WITH document_id: tenders are poured over the lines in order (a tender may split across bookings)
  i := 1; t_rem := amts[1];
  FOR e IN SELECT * FROM jsonb_array_elements(p_tenders) LOOP
    v_mode := e ->> 'mode';
    IF v_mode = 'SessionPackage' THEN
      v_pkg := (e ->> 'package_id')::uuid;
      PERFORM public.redeem_package_session(v_pkg, ids[1], v_branch);
    END IF;
    take := (e ->> 'amount')::numeric;
    WHILE take > 0 LOOP
      piece := LEAST(take, t_rem);
      INSERT INTO public.payments (booking_id, amount, payment_mode, recorded_by, document_id) VALUES (ids[i], piece, v_mode, v_user, v_doc.id);
      take := take - piece; t_rem := t_rem - piece;
      IF t_rem = 0 AND i < array_length(ids, 1) THEN i := i + 1; t_rem := amts[i]; END IF;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('document_id', v_doc.id, 'number', v_doc.number, 'kind', v_doc.kind, 'fiscal_year', v_doc.fiscal_year,
                            'branch_id', v_branch, 'bs_date', v_doc.bs_date);
END $$;
REVOKE ALL ON FUNCTION public._money_collect(jsonb, jsonb, jsonb, uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;

-- 7.2 refund: manager/admin (checked by the wrapper). Refund row + refund note (credit note when the original is a PAN bill), one transaction.
CREATE OR REPLACE FUNCTION public._money_refund(p_ctx jsonb, p_booking uuid, p_amount numeric, p_reason text, p_paid_back_by text, p_request uuid) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org uuid := (p_ctx ->> 'org_id')::uuid; v_user uuid := (p_ctx ->> 'user_id')::uuid;
  b public.bookings; v_borg uuid; v_paid numeric; v_refunded numeric; v_orig public.money_documents; v_doc public.money_documents;
  v_kind text; v_refund_id uuid; v_req public.money_requests;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> round(p_amount, 2) THEN RAISE EXCEPTION 'INVALID_INPUT: the refund amount must be positive with at most 2 decimals.' USING ERRCODE = 'P0001'; END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'REASON_REQUIRED: A reason is required for a refund.' USING ERRCODE = 'P0001'; END IF;
  IF p_paid_back_by IS NULL OR btrim(p_paid_back_by) = '' OR length(p_paid_back_by) > 40 THEN RAISE EXCEPTION 'INVALID_INPUT: say how the money was paid back.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO b FROM public.bookings WHERE id = p_booking FOR UPDATE;
  IF b.id IS NOT NULL THEN SELECT org_id INTO v_borg FROM public.branches WHERE id = b.branch_id; END IF;
  IF b.id IS NULL OR v_borg <> v_org OR NOT public._act_in_scope(p_ctx, v_borg, b.branch_id) THEN
    RAISE EXCEPTION 'BOOKING_NOT_FOUND: Booking not found.' USING ERRCODE = 'P0001'; END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM public.payments WHERE booking_id = p_booking;
  SELECT COALESCE(SUM(amount), 0) INTO v_refunded FROM public.payment_refunds WHERE booking_id = p_booking;
  IF p_amount > v_paid - v_refunded THEN RAISE EXCEPTION 'OVERREFUND: a refund cannot be more than was paid less earlier refunds.' USING ERRCODE = 'P0001'; END IF;
  IF p_request IS NOT NULL THEN
    SELECT * INTO v_req FROM public.money_requests WHERE id = p_request FOR UPDATE;
    IF v_req.id IS NULL OR v_req.org_id <> v_org OR v_req.status <> 'open' OR v_req.booking_id IS DISTINCT FROM p_booking THEN
      RAISE EXCEPTION 'REQUEST_NOT_FOUND: That request is not open for this booking.' USING ERRCODE = 'P0001'; END IF;
  END IF;
  PERFORM public._money_assert_day_open(b.branch_id, now());

  -- the original receipt or PAN bill for this booking (latest issued); legacy payments have none: the refund is recorded without a note
  SELECT * INTO v_orig FROM public.money_documents
   WHERE org_id = v_org AND kind IN ('receipt', 'pan_bill') AND status = 'issued' AND p_booking = ANY (booking_ids)
   ORDER BY issued_at DESC, seq DESC LIMIT 1;
  IF v_orig.id IS NOT NULL THEN
    v_kind := CASE v_orig.kind WHEN 'pan_bill' THEN 'credit_note' ELSE 'refund_note' END;
    v_doc := public._money_issue_document(v_org, b.branch_id, v_kind, v_orig.customer_id, v_orig.buyer_name, v_orig.buyer_pan, ARRAY[p_booking],
        jsonb_build_array(jsonb_build_object('label', 'Refund · ' || b.booking_number, 'amount', p_amount, 'ref', p_booking)), p_amount,
        jsonb_build_array(jsonb_build_object('mode', btrim(p_paid_back_by), 'amount', p_amount)), v_user, v_orig.id);
  END IF;
  INSERT INTO public.payment_refunds (booking_id, org_id, amount, refunded_by, reason, document_id, paid_back_by)
  VALUES (p_booking, v_org, p_amount, v_user, btrim(p_reason), v_doc.id, btrim(p_paid_back_by)) RETURNING id INTO v_refund_id;
  IF p_request IS NOT NULL THEN
    UPDATE public.money_requests SET status = 'done', resolved_by = v_user, resolved_at = now() WHERE id = p_request;
  END IF;
  RETURN jsonb_build_object('refund_id', v_refund_id, 'document_id', v_doc.id, 'number', v_doc.number, 'kind', v_doc.kind, 'branch_id', b.branch_id);
END $$;
REVOKE ALL ON FUNCTION public._money_refund(jsonb, uuid, numeric, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;

-- 7.3 refund request (front desk): a row for a manager. Nothing is refunded.
CREATE OR REPLACE FUNCTION public._money_request_refund(p_ctx jsonb, p_document uuid, p_booking uuid, p_amount numeric, p_note text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org uuid := (p_ctx ->> 'org_id')::uuid; v_user uuid := (p_ctx ->> 'user_id')::uuid;
  d public.money_documents; v_paid numeric; v_refunded numeric; v_assignee uuid; v_id uuid;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> round(p_amount, 2) THEN RAISE EXCEPTION 'INVALID_INPUT: the amount must be positive with at most 2 decimals.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO d FROM public.money_documents WHERE id = p_document;
  IF d.id IS NULL OR d.org_id <> v_org OR NOT public._act_in_scope(p_ctx, d.org_id, d.branch_id) OR d.kind NOT IN ('receipt', 'pan_bill') OR d.status <> 'issued'
     OR NOT (p_booking = ANY (d.booking_ids)) THEN
    RAISE EXCEPTION 'DOCUMENT_NOT_FOUND: Receipt not found.' USING ERRCODE = 'P0001'; END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM public.payments WHERE booking_id = p_booking;
  SELECT COALESCE(SUM(amount), 0) INTO v_refunded FROM public.payment_refunds WHERE booking_id = p_booking;
  IF p_amount > v_paid - v_refunded THEN RAISE EXCEPTION 'OVERREFUND: a refund cannot be more than was paid less earlier refunds.' USING ERRCODE = 'P0001'; END IF;
  SELECT u.id INTO v_assignee FROM public.users u
   WHERE u.org_id = v_org AND u.role::text IN ('manager', 'admin') AND u.is_active IS NOT FALSE
     AND (u.role::text = 'admin' OR u.branch_id = d.branch_id OR EXISTS (SELECT 1 FROM public.user_branches ub WHERE ub.user_id = u.id AND ub.branch_id = d.branch_id))
   ORDER BY (u.role::text = 'manager') DESC, u.id LIMIT 1;
  INSERT INTO public.money_requests (org_id, branch_id, kind, document_id, booking_id, amount, note, requested_by, assigned_to)
  VALUES (v_org, d.branch_id, 'refund', p_document, p_booking, p_amount, NULLIF(btrim(p_note), ''), v_user, v_assignee) RETURNING id INTO v_id;
  RETURN jsonb_build_object('request_id', v_id, 'branch_id', d.branch_id, 'assigned', v_assignee IS NOT NULL);
END $$;
REVOKE ALL ON FUNCTION public._money_request_refund(jsonb, uuid, uuid, numeric, text) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._money_request_decline(p_ctx jsonb, p_request uuid, p_note text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.money_requests;
BEGIN
  SELECT * INTO r FROM public.money_requests WHERE id = p_request FOR UPDATE;
  IF r.id IS NULL OR r.org_id <> (p_ctx ->> 'org_id')::uuid OR NOT public._act_in_scope(p_ctx, r.org_id, r.branch_id) OR r.status <> 'open' THEN
    RAISE EXCEPTION 'REQUEST_NOT_FOUND: That request is not open.' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.money_requests SET status = 'declined', resolved_by = (p_ctx ->> 'user_id')::uuid, resolved_at = now(), resolution_note = NULLIF(btrim(p_note), '') WHERE id = p_request;
  RETURN jsonb_build_object('request_id', p_request, 'branch_id', r.branch_id);
END $$;
REVOKE ALL ON FUNCTION public._money_request_decline(jsonb, uuid, text) FROM PUBLIC, anon, authenticated, service_role;

-- 7.4 cancel a PAN bill: the credit note and the cancel in one transaction (the immutability trigger allows only this move)
CREATE OR REPLACE FUNCTION public._bill_cancel(p_ctx jsonb, p_document uuid, p_reason text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.money_documents; cn public.money_documents; v_user uuid := (p_ctx ->> 'user_id')::uuid;
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'REASON_REQUIRED: A reason is required to cancel a bill.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO d FROM public.money_documents WHERE id = p_document FOR UPDATE;
  IF d.id IS NULL OR d.org_id <> (p_ctx ->> 'org_id')::uuid OR NOT public._act_in_scope(p_ctx, d.org_id, d.branch_id) THEN
    RAISE EXCEPTION 'DOCUMENT_NOT_FOUND: Bill not found.' USING ERRCODE = 'P0001'; END IF;
  IF d.kind <> 'pan_bill' THEN RAISE EXCEPTION 'NOT_A_BILL: Only a PAN bill can be cancelled; a receipt is corrected by a refund note.' USING ERRCODE = 'P0001'; END IF;
  IF d.status <> 'issued' THEN RAISE EXCEPTION 'ALREADY_CANCELLED: This bill is already cancelled.' USING ERRCODE = 'P0001'; END IF;
  cn := public._money_issue_document(d.org_id, d.branch_id, 'credit_note', d.customer_id, d.buyer_name, d.buyer_pan, d.booking_ids, d.lines, d.total, d.method_summary, v_user, d.id);
  UPDATE public.money_documents SET status = 'cancelled', cancel_reason = btrim(p_reason), cancelled_by = v_user, cancelled_at = now() WHERE id = p_document;
  RETURN jsonb_build_object('document_id', p_document, 'credit_note_id', cn.id, 'number', cn.number, 'branch_id', d.branch_id);
END $$;
REVOKE ALL ON FUNCTION public._bill_cancel(jsonb, uuid, text) FROM PUBLIC, anon, authenticated, service_role;

-- 7.5 print (Original, then Copy) and send
CREATE OR REPLACE FUNCTION public._document_print(p_ctx jsonb, p_document uuid) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.money_documents;
BEGIN
  SELECT * INTO d FROM public.money_documents WHERE id = p_document FOR UPDATE;
  IF d.id IS NULL OR d.org_id <> (p_ctx ->> 'org_id')::uuid OR NOT public._act_in_scope(p_ctx, d.org_id, d.branch_id) THEN
    RAISE EXCEPTION 'DOCUMENT_NOT_FOUND: Document not found.' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.money_documents SET print_count = print_count + 1 WHERE id = p_document;
  RETURN jsonb_build_object('document_id', p_document, 'label', CASE WHEN d.print_count = 0 THEN 'Original' ELSE 'Copy' END, 'branch_id', d.branch_id);
END $$;
REVOKE ALL ON FUNCTION public._document_print(jsonb, uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._document_send(p_ctx jsonb, p_document uuid, p_channel text, p_to text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.money_documents;
BEGIN
  IF p_channel IS NULL OR p_channel NOT IN ('sms', 'whatsapp', 'email', 'print') OR p_to IS NULL OR btrim(p_to) = '' THEN
    RAISE EXCEPTION 'INVALID_INPUT: a channel (sms, whatsapp, email) and a recipient are required.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO d FROM public.money_documents WHERE id = p_document FOR UPDATE;
  IF d.id IS NULL OR d.org_id <> (p_ctx ->> 'org_id')::uuid OR NOT public._act_in_scope(p_ctx, d.org_id, d.branch_id) THEN
    RAISE EXCEPTION 'DOCUMENT_NOT_FOUND: Document not found.' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.money_documents SET sent = sent || jsonb_build_array(jsonb_build_object('channel', p_channel, 'to', btrim(p_to), 'at', now(), 'by', p_ctx ->> 'user_id')) WHERE id = p_document;
  RETURN jsonb_build_object('document_id', p_document, 'branch_id', d.branch_id);
END $$;
REVOKE ALL ON FUNCTION public._document_send(jsonb, uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;

-- 7.6 billing mode: admin only; refused once the organisation has issued a document in the current fiscal year (mid-year, until Sadin rules)
CREATE OR REPLACE FUNCTION public._billing_set_mode(p_ctx jsonb, p_pan text, p_mode boolean) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org uuid := (p_ctx ->> 'org_id')::uuid; v_cur boolean; v_fy text;
BEGIN
  IF p_mode IS NULL THEN RAISE EXCEPTION 'INVALID_INPUT: say whether PAN bill mode is on.' USING ERRCODE = 'P0001'; END IF;
  IF p_mode AND (p_pan IS NULL OR btrim(p_pan) = '') THEN RAISE EXCEPTION 'PAN_REQUIRED: The clinic PAN is needed for PAN bill mode.' USING ERRCODE = 'P0001'; END IF;
  v_cur := public._money_pan_mode(v_org);
  IF p_mode IS DISTINCT FROM v_cur THEN
    v_fy := public.fiscal_year(public._money_day(now()));
    IF EXISTS (SELECT 1 FROM public.money_documents WHERE org_id = v_org AND fiscal_year = v_fy) THEN
      RAISE EXCEPTION 'MODE_CHANGE_MID_YEAR: The billing mode cannot change during a fiscal year in which documents were issued.' USING ERRCODE = 'P0001'; END IF;
  END IF;
  INSERT INTO public.org_billing_settings (org_id, pan, pan_bill_mode, mode_changed_at, mode_changed_by)
  VALUES (v_org, NULLIF(btrim(p_pan), ''), p_mode, CASE WHEN p_mode IS DISTINCT FROM v_cur THEN now() END, CASE WHEN p_mode IS DISTINCT FROM v_cur THEN (p_ctx ->> 'user_id')::uuid END)
  ON CONFLICT (org_id) DO UPDATE SET pan = EXCLUDED.pan, pan_bill_mode = EXCLUDED.pan_bill_mode,
      mode_changed_at = CASE WHEN EXCLUDED.pan_bill_mode IS DISTINCT FROM v_cur THEN now() ELSE public.org_billing_settings.mode_changed_at END,
      mode_changed_by = CASE WHEN EXCLUDED.pan_bill_mode IS DISTINCT FROM v_cur THEN (p_ctx ->> 'user_id')::uuid ELSE public.org_billing_settings.mode_changed_by END;
  RETURN jsonb_build_object('pan_bill_mode', p_mode, 'changed', p_mode IS DISTINCT FROM v_cur);
END $$;
REVOKE ALL ON FUNCTION public._billing_set_mode(jsonb, text, boolean) FROM PUBLIC, anon, authenticated, service_role;

-- ============================================================================================================================
-- 8. Daily closing: blind count -> manager checks and closes -> owner may reopen
-- ============================================================================================================================
-- What would stop a close: a visit still in the chair, a completed visit neither paid nor left as due. (Open QR / payment links: Part 5, none yet.)
CREATE OR REPLACE FUNCTION public._money_blockers(p_branch uuid, p_date date) RETURNS jsonb
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('code', c, 'booking_id', id) ORDER BY id), '[]'::jsonb)
    FROM (SELECT id, CASE WHEN status = 'In-Progress' THEN 'IN_CHAIR' ELSE 'NOT_PAID_OR_DUE' END AS c
            FROM public.bookings
           WHERE branch_id = p_branch AND date = p_date
             AND (status = 'In-Progress'
                  OR (status = 'Completed' AND payment_status IN ('unpaid', 'partial') AND COALESCE(btrim(due_holder_name), '') = ''))) x;
$$;
REVOKE ALL ON FUNCTION public._money_blockers(uuid, date) FROM PUBLIC, anon, authenticated, service_role;

-- Expected per method for a day: payments taken that day (event date) less refunds paid back that day. Wallet modes and SessionPackage are not drawer money.
CREATE OR REPLACE FUNCTION public._money_expected(p_branch uuid, p_date date) RETURNS jsonb
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(jsonb_object_agg(m, amt), '{}'::jsonb) FROM (
    SELECT m, SUM(amt) AS amt FROM (
      SELECT lower(btrim(p.payment_mode)) AS m, p.amount AS amt
        FROM public.payments p JOIN public.bookings b ON b.id = p.booking_id
       WHERE b.branch_id = p_branch AND public._money_day(p.created_at) = p_date
         AND p.payment_mode NOT IN ('Membership', 'ReferralWallet', 'VoucherWallet', 'ReferralVoucher', 'SessionPackage')
      UNION ALL
      SELECT lower(btrim(COALESCE(r.paid_back_by, 'cash'))), -r.amount
        FROM public.payment_refunds r JOIN public.bookings b ON b.id = r.booking_id
       WHERE b.branch_id = p_branch AND public._money_day(r.created_at) = p_date
    ) u GROUP BY m) t;
$$;
REVOKE ALL ON FUNCTION public._money_expected(uuid, date) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._day_submit_count(p_ctx jsonb, p_branch uuid, p_date date, p_counts jsonb) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org uuid; k text; v jsonb; v_clean jsonb := '{}'; v_user uuid := (p_ctx ->> 'user_id')::uuid; v_id uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.branches WHERE id = p_branch;
  IF v_org IS NULL OR v_org <> (p_ctx ->> 'org_id')::uuid OR NOT public._act_in_scope(p_ctx, v_org, p_branch) THEN
    RAISE EXCEPTION 'BRANCH_NOT_FOUND: Branch not found.' USING ERRCODE = 'P0001'; END IF;
  IF p_date IS NULL OR p_date > public._money_day(now()) THEN RAISE EXCEPTION 'INVALID_INPUT: choose today or an earlier day.' USING ERRCODE = 'P0001'; END IF;
  IF p_counts IS NULL OR jsonb_typeof(p_counts) <> 'object' OR p_counts = '{}'::jsonb THEN RAISE EXCEPTION 'INVALID_INPUT: a count per method is required.' USING ERRCODE = 'P0001'; END IF;
  FOR k, v IN SELECT * FROM jsonb_each(p_counts) LOOP
    IF jsonb_typeof(v) <> 'number' OR (v #>> '{}')::numeric < 0 OR btrim(k) = '' THEN RAISE EXCEPTION 'INVALID_INPUT: each count must be a number of zero or more.' USING ERRCODE = 'P0001'; END IF;
    v_clean := v_clean || jsonb_build_object(lower(btrim(k)), v);
  END LOOP;
  PERFORM public._money_assert_day_open(p_branch, (p_date::timestamp AT TIME ZONE 'Asia/Kathmandu') + interval '12 hours');
  SELECT id INTO v_id FROM public.daily_reports WHERE branch_id = p_branch AND report_date = p_date AND superseded_by IS NULL AND status = 'counted' FOR UPDATE;
  IF v_id IS NULL THEN
    INSERT INTO public.daily_reports (branch_id, report_date, status, blind_counts, submitted_by, submitted_at, closed_by, closed_at, is_locked)
    VALUES (p_branch, p_date, 'counted', v_clean, v_user, now(), NULL, NULL, false);
  ELSE
    UPDATE public.daily_reports SET blind_counts = v_clean, submitted_by = v_user, submitted_at = now() WHERE id = v_id;
  END IF;
  RETURN jsonb_build_object('submitted', true, 'branch_id', p_branch);
END $$;
REVOKE ALL ON FUNCTION public._day_submit_count(jsonb, uuid, date, jsonb) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._day_expected(p_ctx jsonb, p_branch uuid, p_date date) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.branches WHERE id = p_branch;
  IF v_org IS NULL OR v_org <> (p_ctx ->> 'org_id')::uuid OR NOT public._act_in_scope(p_ctx, v_org, p_branch) THEN
    RAISE EXCEPTION 'BRANCH_NOT_FOUND: Branch not found.' USING ERRCODE = 'P0001'; END IF;
  RETURN jsonb_build_object('branch_id', p_branch, 'date', p_date, 'expected', public._money_expected(p_branch, p_date),
                            'counted', (SELECT blind_counts FROM public.daily_reports WHERE branch_id = p_branch AND report_date = p_date AND superseded_by IS NULL AND status <> 'reopened'),
                            'blockers', public._money_blockers(p_branch, p_date));
END $$;
REVOKE ALL ON FUNCTION public._day_expected(jsonb, uuid, date) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._day_close(p_ctx jsonb, p_branch uuid, p_date date, p_difference_reason text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org uuid; v_user uuid := (p_ctx ->> 'user_id')::uuid; r public.daily_reports; v_block jsonb; v_exp jsonb; v_diff boolean := false; k text;
  v_cash numeric; v_card numeric; v_digital numeric; v_net numeric; v_gross numeric; v_disc numeric; v_total int; v_done int; v_canc int; v_unpaid int;
BEGIN
  SELECT org_id INTO v_org FROM public.branches WHERE id = p_branch;
  IF v_org IS NULL OR v_org <> (p_ctx ->> 'org_id')::uuid OR NOT public._act_in_scope(p_ctx, v_org, p_branch) THEN
    RAISE EXCEPTION 'BRANCH_NOT_FOUND: Branch not found.' USING ERRCODE = 'P0001'; END IF;
  IF public.day_is_closed(p_branch, p_date) THEN RAISE EXCEPTION 'ALREADY_CLOSED: Day has already been closed.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO r FROM public.daily_reports WHERE branch_id = p_branch AND report_date = p_date AND superseded_by IS NULL AND status = 'counted' FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION 'NO_COUNT: The front desk has not submitted the count for this day.' USING ERRCODE = 'P0001'; END IF;
  v_block := public._money_blockers(p_branch, p_date);
  IF jsonb_array_length(v_block) > 0 THEN RAISE EXCEPTION 'BLOCKERS: The day cannot be closed yet.' USING ERRCODE = 'P0001', DETAIL = v_block::text; END IF;
  v_exp := public._money_expected(p_branch, p_date);
  FOR k IN SELECT key FROM (SELECT jsonb_object_keys(v_exp) AS key UNION SELECT jsonb_object_keys(r.blind_counts)) x LOOP
    IF COALESCE((r.blind_counts ->> k)::numeric, 0) <> COALESCE((v_exp ->> k)::numeric, 0) THEN v_diff := true; END IF;
  END LOOP;
  IF v_diff AND (p_difference_reason IS NULL OR btrim(p_difference_reason) = '') THEN
    RAISE EXCEPTION 'REASON_REQUIRED: The count differs from what the system expects. A reason is required.' USING ERRCODE = 'P0001'; END IF;

  -- snapshot columns kept in the shape the current report screens read (payments counted on the day they were taken)
  SELECT COUNT(*), COUNT(*) FILTER (WHERE status = 'Completed'), COUNT(*) FILTER (WHERE status = 'Cancelled'),
         COALESCE(SUM(base_amount) FILTER (WHERE payment_status = 'paid'), 0), COALESCE(SUM(discount_amount) FILTER (WHERE payment_status = 'paid'), 0),
         COUNT(*) FILTER (WHERE payment_status IN ('unpaid', 'partial') AND status IN ('Confirmed', 'Completed'))
    INTO v_total, v_done, v_canc, v_gross, v_disc, v_unpaid FROM public.bookings WHERE branch_id = p_branch AND date = p_date;
  SELECT COALESCE(SUM(p.amount) FILTER (WHERE p.payment_mode = 'Cash'), 0), COALESCE(SUM(p.amount) FILTER (WHERE p.payment_mode LIKE '%Card%'), 0),
         COALESCE(SUM(p.amount) FILTER (WHERE p.payment_mode <> 'Cash' AND p.payment_mode NOT LIKE '%Card%'), 0)
    INTO v_cash, v_card, v_digital
    FROM public.payments p JOIN public.bookings b ON b.id = p.booking_id
   WHERE b.branch_id = p_branch AND public._money_day(p.created_at) = p_date
     AND p.payment_mode NOT IN ('Membership', 'ReferralWallet', 'VoucherWallet', 'ReferralVoucher', 'SessionPackage');
  v_net := v_cash + v_card + v_digital;

  UPDATE public.daily_reports SET status = 'closed', closed_by = v_user, closed_at = now(), is_locked = true, difference_reason = NULLIF(btrim(p_difference_reason), ''),
         total_bookings = v_total, completed_bookings = v_done, cancelled_bookings = v_canc, gross_revenue = v_gross, total_discounts = v_disc,
         net_revenue = v_net, cash_total = v_cash, card_total = v_card, fonepay_total = v_digital, unpaid_count = v_unpaid
   WHERE id = r.id;
  UPDATE public.daily_reports SET superseded_by = r.id WHERE branch_id = p_branch AND report_date = p_date AND status = 'reopened' AND superseded_by IS NULL;
  UPDATE public.bookings SET is_locked = true WHERE branch_id = p_branch AND date = p_date AND is_locked = false;
  RETURN jsonb_build_object('report_id', r.id, 'branch_id', p_branch, 'difference', v_diff);
END $$;
REVOKE ALL ON FUNCTION public._day_close(jsonb, uuid, date, text) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._day_reopen(p_ctx jsonb, p_branch uuid, p_date date, p_reason text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org uuid; r public.daily_reports;
BEGIN
  SELECT org_id INTO v_org FROM public.branches WHERE id = p_branch;
  IF v_org IS NULL OR v_org <> (p_ctx ->> 'org_id')::uuid OR NOT public._act_in_scope(p_ctx, v_org, p_branch) THEN
    RAISE EXCEPTION 'BRANCH_NOT_FOUND: Branch not found.' USING ERRCODE = 'P0001'; END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'REASON_REQUIRED: A reason is required to reopen a day.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO r FROM public.daily_reports WHERE branch_id = p_branch AND report_date = p_date AND superseded_by IS NULL AND status = 'closed' FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION 'NOT_CLOSED: That day is not closed.' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.daily_reports SET status = 'reopened', reopened_at = now(), reopened_by = (p_ctx ->> 'user_id')::uuid, reopen_reason = btrim(p_reason), is_locked = false WHERE id = r.id;
  PERFORM set_config('money.reopen', p_branch::text || ':' || p_date::text, true);
  UPDATE public.bookings SET is_locked = false WHERE branch_id = p_branch AND date = p_date AND is_locked = true;
  PERFORM set_config('money.reopen', '', true);
  RETURN jsonb_build_object('report_id', r.id, 'branch_id', p_branch);
END $$;
REVOKE ALL ON FUNCTION public._day_reopen(jsonb, uuid, date, text) FROM PUBLIC, anon, authenticated, service_role;

-- ============================================================================================================================
-- 9. Actions: the ONLY entry points granted to signed-in users (012 pattern: resolve the caller, check the role, call the inner function,
--    write one action_log row with ids only). Agents and service callers have no money access. admin_viewer reads only (day.expected).
-- ============================================================================================================================

CREATE OR REPLACE FUNCTION public.act_money_collect(p_lines jsonb, p_tenders jsonb, p_customer uuid DEFAULT NULL, p_buyer_name text DEFAULT NULL, p_buyer_pan text DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('booking_ids', CASE WHEN jsonb_typeof(p_lines) = 'array' THEN (SELECT jsonb_agg(x -> 'booking_id') FROM jsonb_array_elements(p_lines) x) END, 'customer_id', p_customer) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('staff','manager','admin') THEN
    RETURN public._act_finish(ctx, 'money.collect', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'money_documents');
  END IF;
  BEGIN
    v_res := public._money_collect(ctx, p_lines, p_tenders, p_customer, p_buyer_name, p_buyer_pan);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'money.collect', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'money_documents');
  END;
  RETURN public._act_finish(ctx, 'money.collect', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, (v_res ->> 'document_id')::uuid, NULL, 'money_documents');
END $$;
REVOKE ALL ON FUNCTION public.act_money_collect(jsonb, jsonb, uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_money_collect(jsonb, jsonb, uuid, text, text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.act_money_refund(p_booking uuid, p_amount numeric, p_reason text, p_paid_back_by text, p_request uuid DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('booking_id', p_booking, 'request_id', p_request) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('manager','admin') THEN
    RETURN public._act_finish(ctx, 'money.refund', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'payment_refunds');
  END IF;
  BEGIN
    v_res := public._money_refund(ctx, p_booking, p_amount, p_reason, p_paid_back_by, p_request);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'money.refund', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'payment_refunds');
  END;
  RETURN public._act_finish(ctx, 'money.refund', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, (v_res ->> 'refund_id')::uuid, NULL, 'payment_refunds');
END $$;
REVOKE ALL ON FUNCTION public.act_money_refund(uuid, numeric, text, text, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_money_refund(uuid, numeric, text, text, uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.act_money_request_refund(p_document uuid, p_booking uuid, p_amount numeric, p_note text DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('document_id', p_document, 'booking_id', p_booking) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('staff','manager','admin') THEN
    RETURN public._act_finish(ctx, 'money.request_refund', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'money_requests');
  END IF;
  BEGIN
    v_res := public._money_request_refund(ctx, p_document, p_booking, p_amount, p_note);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'money.request_refund', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'money_requests');
  END;
  RETURN public._act_finish(ctx, 'money.request_refund', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, (v_res ->> 'request_id')::uuid, NULL, 'money_requests');
END $$;
REVOKE ALL ON FUNCTION public.act_money_request_refund(uuid, uuid, numeric, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_money_request_refund(uuid, uuid, numeric, text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.act_money_request_decline(p_request uuid, p_note text DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('request_id', p_request) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('manager','admin') THEN
    RETURN public._act_finish(ctx, 'money.request_decline', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'money_requests');
  END IF;
  BEGIN
    v_res := public._money_request_decline(ctx, p_request, p_note);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'money.request_decline', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'money_requests');
  END;
  RETURN public._act_finish(ctx, 'money.request_decline', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, (v_res ->> 'request_id')::uuid, NULL, 'money_requests');
END $$;
REVOKE ALL ON FUNCTION public.act_money_request_decline(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_money_request_decline(uuid, text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.act_bill_cancel(p_document uuid, p_reason text, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('document_id', p_document) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('manager','admin') THEN
    RETURN public._act_finish(ctx, 'bill.cancel', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'money_documents');
  END IF;
  BEGIN
    v_res := public._bill_cancel(ctx, p_document, p_reason);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'bill.cancel', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'money_documents');
  END;
  RETURN public._act_finish(ctx, 'bill.cancel', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, (v_res ->> 'document_id')::uuid, NULL, 'money_documents');
END $$;
REVOKE ALL ON FUNCTION public.act_bill_cancel(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_bill_cancel(uuid, text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.act_document_print(p_document uuid, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('document_id', p_document) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('staff','manager','admin') THEN
    RETURN public._act_finish(ctx, 'document.print', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'money_documents');
  END IF;
  BEGIN
    v_res := public._document_print(ctx, p_document);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'document.print', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'money_documents');
  END;
  RETURN public._act_finish(ctx, 'document.print', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, (v_res ->> 'document_id')::uuid, NULL, 'money_documents');
END $$;
REVOKE ALL ON FUNCTION public.act_document_print(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_document_print(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.act_document_send(p_document uuid, p_channel text, p_to text, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('document_id', p_document, 'channel', p_channel) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('staff','manager','admin') THEN
    RETURN public._act_finish(ctx, 'document.send', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'money_documents');
  END IF;
  BEGIN
    v_res := public._document_send(ctx, p_document, p_channel, p_to);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'document.send', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'money_documents');
  END;
  RETURN public._act_finish(ctx, 'document.send', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, (v_res ->> 'document_id')::uuid, NULL, 'money_documents');
END $$;
REVOKE ALL ON FUNCTION public.act_document_send(uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_document_send(uuid, text, text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.act_day_submit_count(p_branch uuid, p_date date, p_counts jsonb, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('branch_id', p_branch, 'date', p_date) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('staff','manager','admin') THEN
    RETURN public._act_finish(ctx, 'day.submit_count', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'daily_reports');
  END IF;
  BEGIN
    v_res := public._day_submit_count(ctx, p_branch, p_date, p_counts);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'day.submit_count', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'daily_reports');
  END;
  RETURN public._act_finish(ctx, 'day.submit_count', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, NULL::uuid, NULL, 'daily_reports');
END $$;
REVOKE ALL ON FUNCTION public.act_day_submit_count(uuid, date, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_day_submit_count(uuid, date, jsonb, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.act_day_expected(p_branch uuid, p_date date, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('branch_id', p_branch, 'date', p_date) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('manager','admin','admin_viewer') THEN
    RETURN public._act_finish(ctx, 'day.expected', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'daily_reports');
  END IF;
  BEGIN
    v_res := public._day_expected(ctx, p_branch, p_date);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'day.expected', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'daily_reports');
  END;
  RETURN public._act_finish(ctx, 'day.expected', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, NULL::uuid, NULL, 'daily_reports');
END $$;
REVOKE ALL ON FUNCTION public.act_day_expected(uuid, date, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_day_expected(uuid, date, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.act_day_close(p_branch uuid, p_date date, p_difference_reason text DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('branch_id', p_branch, 'date', p_date) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('manager','admin') THEN
    RETURN public._act_finish(ctx, 'day.close', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'daily_reports');
  END IF;
  BEGIN
    v_res := public._day_close(ctx, p_branch, p_date, p_difference_reason);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'day.close', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'daily_reports');
  END;
  RETURN public._act_finish(ctx, 'day.close', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, (v_res ->> 'report_id')::uuid, NULL, 'daily_reports');
END $$;
REVOKE ALL ON FUNCTION public.act_day_close(uuid, date, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_day_close(uuid, date, text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.act_day_reopen(p_branch uuid, p_date date, p_reason text, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('branch_id', p_branch, 'date', p_date) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('admin') THEN
    RETURN public._act_finish(ctx, 'day.reopen', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'daily_reports');
  END IF;
  BEGIN
    v_res := public._day_reopen(ctx, p_branch, p_date, p_reason);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'day.reopen', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'daily_reports');
  END;
  RETURN public._act_finish(ctx, 'day.reopen', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, (v_res ->> 'report_id')::uuid, NULL, 'daily_reports');
END $$;
REVOKE ALL ON FUNCTION public.act_day_reopen(uuid, date, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_day_reopen(uuid, date, text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.act_billing_set_mode(p_pan text, p_mode boolean, p_ctx jsonb DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ctx jsonb; v_inputs jsonb; v_res jsonb; v_code text; v_msg text; v_detail text; v_org uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('pan_bill_mode', p_mode) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('admin') THEN
    RETURN public._act_finish(ctx, 'billing.set_mode', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot do this.', NULL, NULL, 'org_billing_settings');
  END IF;
  BEGIN
    v_res := public._billing_set_mode(ctx, p_pan, p_mode);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_msg ~ '^[A-Z][A-Z_]+: ' THEN
      v_code := split_part(v_msg, ':', 1); v_msg := btrim(substr(v_msg, length(v_code) + 2));
    ELSE
      v_msg := 'Could not complete the action.';   -- a raw database message can carry values: never pass it on
    END IF;
    RETURN public._act_finish(ctx, 'billing.set_mode', v_org, NULL, v_inputs, false, CASE WHEN v_code = 'BLOCKERS' THEN v_detail::jsonb END, v_code, v_msg, NULL, NULL, 'org_billing_settings');
  END;
  RETURN public._act_finish(ctx, 'billing.set_mode', v_org, (v_res ->> 'branch_id')::uuid, v_inputs, true, v_res, NULL, NULL, NULL::uuid, NULL, 'org_billing_settings');
END $$;
REVOKE ALL ON FUNCTION public.act_billing_set_mode(text, boolean, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.act_billing_set_mode(text, boolean, jsonb) TO authenticated;


-- ============================================================================================================================
-- 10. Sales register: PAN bills and credit notes per fiscal year, cancelled ones included (reads through the caller's RLS)
-- ============================================================================================================================
CREATE OR REPLACE VIEW public.money_sales_register WITH (security_invoker = true) AS
  SELECT d.org_id, d.branch_id, d.fiscal_year, d.kind, d.number, d.seq, d.issued_at, d.bs_date, d.buyer_name, d.buyer_pan,
         d.total AS amount, d.status, d.related_document_id
    FROM public.money_documents d WHERE d.kind IN ('pan_bill', 'credit_note');
REVOKE ALL ON public.money_sales_register FROM PUBLIC, anon;
GRANT SELECT ON public.money_sales_register TO authenticated;

COMMIT;
