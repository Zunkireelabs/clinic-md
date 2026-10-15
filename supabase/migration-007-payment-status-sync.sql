-- migration-007-payment-status-sync.sql
-- Keep bookings.payment_status ('unpaid' | 'partial' | 'paid' | 'refunded') true to the payments rows.
--
-- Before this, the label was only recalculated AFTER INSERT on payments. It went stale when:
--   * a booking's price changed after a payment (base_amount / discount_amount → final_amount)
--   * a payment row was edited or deleted (service role / SQL editor; the app itself only inserts)
-- A stale label matters: enforce_booking_immutability freezes discounts on 'paid' bookings, and
-- status pills/filters read it. Money totals in the app are computed from payments (bookingMoney.js)
-- and do not depend on this label.
--
-- Rules, unchanged from the original trigger:
--   paid >= final → 'paid' · paid > 0 → 'partial' · otherwise → 'unpaid'
--   'refunded' (set by handle_booking_cancellation_refund on cancellation) is never overwritten.
--
-- Idempotent: safe to run more than once. Locked (closed-day) bookings are never modified; any
-- that are out of sync are reported with a NOTICE so they can be reviewed.

BEGIN;

-- 1. One definition of the rule.
CREATE OR REPLACE FUNCTION public.derive_payment_status(p_paid numeric, p_final numeric)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path TO 'public'
AS $$
  SELECT CASE
    WHEN COALESCE(p_paid, 0) >= COALESCE(p_final, 0) THEN 'paid'
    WHEN COALESCE(p_paid, 0) > 0                     THEN 'partial'
    ELSE 'unpaid'
  END
$$;

-- 2. Recompute one booking from its payments. No-op when unchanged, refunded, or the booking is gone.
CREATE OR REPLACE FUNCTION public.sync_booking_payment_status(p_booking_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_paid numeric;
BEGIN
  IF p_booking_id IS NULL THEN
    RETURN;
  END IF;

  -- Serialise concurrent payments on the same booking: without this row lock, two payments committed
  -- at the same moment could each sum without seeing the other and leave 'partial' on a paid booking.
  PERFORM 1 FROM public.bookings WHERE id = p_booking_id FOR UPDATE;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM public.payments WHERE booking_id = p_booking_id;

  UPDATE public.bookings b
  SET payment_status = public.derive_payment_status(v_paid, b.final_amount)
  WHERE b.id = p_booking_id
    AND b.payment_status <> 'refunded'
    AND b.payment_status IS DISTINCT FROM public.derive_payment_status(v_paid, b.final_amount);
END;
$$;

-- 3. Payments: recompute after insert, update or delete (both bookings if booking_id itself changed).
--    Replaces the old insert-only function body; the old trigger is dropped and recreated below.
--    Closed (locked) days: the old trigger always UPDATEd the booking, so enforce_booking_immutability
--    rejected any payment on a locked booking as a side effect (the wallet/voucher payment functions
--    check this explicitly too). sync_booking_payment_status skips no-op updates, so the rule is made
--    explicit here instead: no payment may be added, changed or removed on a locked booking.
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

DROP TRIGGER IF EXISTS trg_payment_update_booking_status ON public.payments;
CREATE TRIGGER trg_payment_update_booking_status
  AFTER INSERT OR UPDATE OF amount, booking_id OR DELETE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.update_booking_payment_status();

-- 4. Bookings: when the price changes, set the label in the same write (no second UPDATE).
--    BEFORE triggers run alphabetically, so this name sorts after trg_compute_final_amount (which
--    sets final_amount) and trg_handle_booking_cancellation_refund (which may set 'refunded').
CREATE OR REPLACE FUNCTION public.trg_sync_payment_status_on_price()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_paid numeric;
BEGIN
  IF NEW.final_amount IS DISTINCT FROM OLD.final_amount
     AND NEW.payment_status <> 'refunded' THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM public.payments WHERE booking_id = NEW.id;
    NEW.payment_status := public.derive_payment_status(v_paid, NEW.final_amount);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_payment_status_on_price ON public.bookings;
CREATE TRIGGER trg_sync_payment_status_on_price
  BEFORE UPDATE ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.trg_sync_payment_status_on_price();

-- 5. Backfill existing drift (unlocked, non-refunded bookings only), and report what it did.
DO $$
DECLARE
  v_fixed  integer;
  v_locked integer;
BEGIN
  WITH sums AS (
    SELECT b.id, public.derive_payment_status(COALESCE(SUM(p.amount), 0), b.final_amount) AS expected
    FROM public.bookings b
    LEFT JOIN public.payments p ON p.booking_id = b.id
    WHERE b.payment_status <> 'refunded'
    GROUP BY b.id, b.final_amount
  )
  UPDATE public.bookings b
  SET payment_status = s.expected
  FROM sums s
  WHERE b.id = s.id
    AND b.is_locked IS NOT TRUE
    AND b.payment_status IS DISTINCT FROM s.expected;
  GET DIAGNOSTICS v_fixed = ROW_COUNT;

  SELECT COUNT(*) INTO v_locked
  FROM public.bookings b
  WHERE b.is_locked IS TRUE
    AND b.payment_status <> 'refunded'
    AND b.payment_status IS DISTINCT FROM public.derive_payment_status(
          (SELECT COALESCE(SUM(amount), 0) FROM public.payments WHERE booking_id = b.id), b.final_amount);

  RAISE NOTICE 'payment_status backfill: % booking(s) corrected; % locked booking(s) out of sync (left unchanged)', v_fixed, v_locked;
END $$;

COMMIT;
