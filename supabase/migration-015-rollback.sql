-- Rollback for migration 015 (CMD-93): drops the two triggers, the function and the switch column.
-- It does NOT remove the patient_channels rows the trigger created: they are consent records and stay. They can only be told apart
-- from the 013 backfill rows by their evidence text ('Phone given when booking <number>', without "(backfill, migration 013 ...)").
BEGIN;
DROP TRIGGER IF EXISTS trg_booking_service_consent_upd ON public.bookings;
DROP TRIGGER IF EXISTS trg_booking_service_consent_ins ON public.bookings;
DROP FUNCTION IF EXISTS public.trg_booking_record_service_consent();
ALTER TABLE public.organizations DROP COLUMN IF EXISTS booking_phone_is_service_consent;
COMMIT;
