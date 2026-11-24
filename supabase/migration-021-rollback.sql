-- Rollback of migration 021 (CMD-115, Money Part 0). For local / rehearsal use: it DELETES every receipt, bill, credit note, refund note,
-- counter, request, blind count and reopen history created after 021 (payments, refunds and closings made before 021 are untouched).
-- On prod after real receipts exist, do not run this without a decision from the lead.
BEGIN;

-- 1. actions, inner functions, view
DROP VIEW IF EXISTS public.money_sales_register;
DROP FUNCTION IF EXISTS public.act_money_collect(jsonb, jsonb, uuid, text, text, jsonb);
DROP FUNCTION IF EXISTS public.act_money_refund(uuid, numeric, text, text, uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_money_request_refund(uuid, uuid, numeric, text, jsonb);
DROP FUNCTION IF EXISTS public.act_money_request_decline(uuid, text, jsonb);
DROP FUNCTION IF EXISTS public.act_bill_cancel(uuid, text, jsonb);
DROP FUNCTION IF EXISTS public.act_document_print(uuid, jsonb);
DROP FUNCTION IF EXISTS public.act_document_send(uuid, text, text, jsonb);
DROP FUNCTION IF EXISTS public.act_day_submit_count(uuid, date, jsonb, jsonb);
DROP FUNCTION IF EXISTS public.act_day_expected(uuid, date, jsonb);
DROP FUNCTION IF EXISTS public.act_day_close(uuid, date, text, jsonb);
DROP FUNCTION IF EXISTS public.act_day_reopen(uuid, date, text, jsonb);
DROP FUNCTION IF EXISTS public.act_billing_set_mode(text, boolean, jsonb);
DROP FUNCTION IF EXISTS public._money_collect(jsonb, jsonb, jsonb, uuid, text, text);
DROP FUNCTION IF EXISTS public._money_refund(jsonb, uuid, numeric, text, text, uuid);
DROP FUNCTION IF EXISTS public._money_request_refund(jsonb, uuid, uuid, numeric, text);
DROP FUNCTION IF EXISTS public._money_request_decline(jsonb, uuid, text);
DROP FUNCTION IF EXISTS public._bill_cancel(jsonb, uuid, text);
DROP FUNCTION IF EXISTS public._document_print(jsonb, uuid);
DROP FUNCTION IF EXISTS public._document_send(jsonb, uuid, text, text);
DROP FUNCTION IF EXISTS public._billing_set_mode(jsonb, text, boolean);
DROP FUNCTION IF EXISTS public._day_submit_count(jsonb, uuid, date, jsonb);
DROP FUNCTION IF EXISTS public._day_expected(jsonb, uuid, date);
DROP FUNCTION IF EXISTS public._day_close(jsonb, uuid, date, text);
DROP FUNCTION IF EXISTS public._day_reopen(jsonb, uuid, date, text);
DROP FUNCTION IF EXISTS public._money_blockers(uuid, date);
DROP FUNCTION IF EXISTS public._money_expected(uuid, date);
DROP FUNCTION IF EXISTS public._money_issue_document(uuid, uuid, text, uuid, text, text, uuid[], jsonb, numeric, jsonb, uuid, uuid);
DROP FUNCTION IF EXISTS public._money_next_number(uuid, text, text);
DROP FUNCTION IF EXISTS public._money_pan_mode(uuid);

-- 2. triggers: restore the pre-021 bodies of the two shared functions (007 and schema.sql), drop the new ones
DROP TRIGGER IF EXISTS trg_payments_guard ON public.payments;
DROP TRIGGER IF EXISTS trg_payment_refunds_guard ON public.payment_refunds;
DROP TRIGGER IF EXISTS trg_payment_refunds_i_day ON public.payment_refunds;
DROP TRIGGER IF EXISTS trg_money_documents_insert ON public.money_documents;
DROP TRIGGER IF EXISTS trg_money_documents_immutable ON public.money_documents;

CREATE OR REPLACE FUNCTION public.update_booking_payment_status()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.bookings b
    WHERE b.is_locked
      AND b.id IN (
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN NEW.booking_id END,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN OLD.booking_id END)
  ) THEN
    RAISE EXCEPTION 'DAY_LOCKED: This day has been closed. No further modifications allowed.'
      USING ERRCODE = 'P0001';
  END IF;

  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM public.sync_booking_payment_status(NEW.booking_id);
  END IF;
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.booking_id IS DISTINCT FROM NEW.booking_id) THEN
    PERFORM public.sync_booking_payment_status(OLD.booking_id);
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.enforce_booking_immutability() RETURNS trigger
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

DROP FUNCTION IF EXISTS public.trg_payments_guard();
DROP FUNCTION IF EXISTS public.trg_payment_refunds_guard();
DROP FUNCTION IF EXISTS public.trg_payment_refunds_day();
DROP FUNCTION IF EXISTS public.trg_money_documents_insert();
DROP FUNCTION IF EXISTS public.trg_money_documents_immutable();

-- 3. the daily_reports additions: counts and reopen history go (a day that was reopened and closed again keeps its current closing)
ALTER TABLE public.daily_reports DROP COLUMN superseded_by;
DELETE FROM public.daily_reports WHERE status IN ('counted', 'reopened');
DROP INDEX IF EXISTS public.uq_daily_report_current;
ALTER TABLE public.daily_reports
  DROP COLUMN status, DROP COLUMN blind_counts, DROP COLUMN difference_reason, DROP COLUMN submitted_by, DROP COLUMN submitted_at,
  DROP COLUMN reopened_at, DROP COLUMN reopened_by, DROP COLUMN reopen_reason;
ALTER TABLE public.daily_reports ALTER COLUMN closed_by SET NOT NULL, ALTER COLUMN closed_at SET NOT NULL;
ALTER TABLE public.daily_reports ADD CONSTRAINT uq_daily_report_branch_date UNIQUE (branch_id, report_date);

-- 4. columns that point at money_documents go BEFORE the table does
DROP INDEX IF EXISTS public.payments_document_idx;
ALTER TABLE public.payments DROP COLUMN document_id;
ALTER TABLE public.payment_refunds DROP COLUMN document_id, DROP COLUMN paid_back_by;

DROP TABLE public.money_requests;
DROP TABLE public.money_documents;
DROP TABLE public.money_counters;
DROP TABLE public.org_billing_settings;
DROP FUNCTION IF EXISTS public.bs_date_text(date);
DROP FUNCTION IF EXISTS public.fiscal_year(date);
DROP FUNCTION IF EXISTS public.bs_date(date);
DROP TABLE public.bs_calendar;
DROP FUNCTION IF EXISTS public.money_format_number(text, text, integer);
DROP FUNCTION IF EXISTS public._money_assert_day_open(uuid, timestamptz);
DROP FUNCTION IF EXISTS public.day_is_closed(uuid, date);
DROP FUNCTION IF EXISTS public._money_day(timestamptz);
DROP FUNCTION IF EXISTS public._money_is_owner_ctx();

COMMIT;
