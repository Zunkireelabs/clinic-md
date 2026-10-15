-- migration-007-rollback.sql
-- Restores the pre-007 behaviour exactly: payment_status recomputed only AFTER INSERT on payments.
-- Labels corrected by the 007 backfill are left as corrected (they reflect the payments rows).

BEGIN;

DROP TRIGGER IF EXISTS trg_sync_payment_status_on_price ON public.bookings;
DROP FUNCTION IF EXISTS public.trg_sync_payment_status_on_price();

CREATE OR REPLACE FUNCTION public.update_booking_payment_status() RETURNS trigger
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

DROP TRIGGER IF EXISTS trg_payment_update_booking_status ON public.payments;
CREATE TRIGGER trg_payment_update_booking_status AFTER INSERT ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.update_booking_payment_status();

DROP FUNCTION IF EXISTS public.sync_booking_payment_status(uuid);
DROP FUNCTION IF EXISTS public.derive_payment_status(numeric, numeric);

COMMIT;
