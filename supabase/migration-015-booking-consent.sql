-- Migration 015 (CMD-93): record service-SMS consent when a booking is made.
-- Needs 011-014 applied first (013 creates patient_channels). NOT applied to prod. Rollback: migration-015-rollback.sql.
--
-- 013 backfilled service-SMS consent (agreed, source = booking) for patients who had ALREADY booked. A patient who books after
-- 013 got no row, so the Follow-up agent would refuse to confirm their booking (NO_CONSENT). Sadin decided (2026-11-22): record it
-- at booking time, by the same rule as the backfill. Legal check: CMD-59.
--
-- Rules (same as the backfill): the number the patient gave when booking is service consent for ONE purpose, 'service', on 'sms'.
--   * never changes an existing row (never a 'stopped' one, never one a person recorded)  -> ON CONFLICT DO NOTHING
--   * never creates marketing consent
--   * never fails a booking: any error becomes a WARNING and the booking goes through
--   * a lasting per-clinic switch (013's hub.backfill_booking_consent only exists while the migration runs) lets legal turn it off
-- Out of scope: a patient's phone changing later (a new number gets a row at the patient's next booking).

BEGIN;

ALTER TABLE public.organizations
  ADD COLUMN IF NOT EXISTS booking_phone_is_service_consent boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.organizations.booking_phone_is_service_consent IS
  'When true, the phone number a patient gives when booking counts as consent to service SMS (booking confirmations and reminders only, never marketing); a patient_channels row is recorded by trigger. Set false for a clinic to stop recording it (CMD-59, legal check). Shown in Settings > Channels later.';

CREATE OR REPLACE FUNCTION public.trg_booking_record_service_consent() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org uuid; v_phone text; v_on boolean; v_addr text;
BEGIN
  BEGIN
    IF NEW.customer_id IS NULL THEN RETURN NULL; END IF;
    SELECT c.org_id, c.phone, o.booking_phone_is_service_consent
      INTO v_org, v_phone, v_on
      FROM public.customers c
      JOIN public.branches br ON br.id = NEW.branch_id AND br.org_id = c.org_id   -- patient and booking must be in one org
      JOIN public.organizations o ON o.id = c.org_id
     WHERE c.id = NEW.customer_id;
    IF v_org IS NULL OR NOT COALESCE(v_on, false) THEN RETURN NULL; END IF;
    IF NULLIF(btrim(v_phone), '') IS NULL THEN RETURN NULL; END IF;
    v_addr := public.normalize_phone_e164(v_phone);
    IF v_addr IS NULL THEN RETURN NULL; END IF;
    INSERT INTO public.patient_channels (org_id, customer_id, channel, address, purpose, status, source, recorded_at, evidence)
    VALUES (v_org, NEW.customer_id, 'sms', v_addr, 'service', 'agreed', 'booking', now(),
            'Phone given when booking ' || COALESCE(NEW.booking_number, ''))
    ON CONFLICT (org_id, channel, address, purpose) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'trg_booking_record_service_consent failed (booking %): % (%)', NEW.id, SQLERRM, SQLSTATE;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.trg_booking_record_service_consent() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_booking_service_consent_ins ON public.bookings;
CREATE TRIGGER trg_booking_service_consent_ins AFTER INSERT ON public.bookings
  FOR EACH ROW WHEN (NEW.customer_id IS NOT NULL) EXECUTE FUNCTION public.trg_booking_record_service_consent();
DROP TRIGGER IF EXISTS trg_booking_service_consent_upd ON public.bookings;
CREATE TRIGGER trg_booking_service_consent_upd AFTER UPDATE OF customer_id ON public.bookings
  FOR EACH ROW WHEN (NEW.customer_id IS NOT NULL AND OLD.customer_id IS DISTINCT FROM NEW.customer_id)
  EXECUTE FUNCTION public.trg_booking_record_service_consent();

COMMIT;
