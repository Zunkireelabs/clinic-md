-- Migration 005: pg_cron jobs for staff transfers
--
-- Requires the pg_cron extension (on the cloud: Dashboard -> Database -> Extensions, before applying).
-- pg_cron schedules are UTC; the functions do their own Asia/Kathmandu conversion, so no timezone setting
-- is needed. Jobs are unscheduled-if-exists first, so re-running is idempotent.
--   * every 5 minutes: apply due transfers, then auto-revert due returns
--   * daily 00:15 UTC (= 06:00 Asia/Kathmandu): in-app reminder for bookings left at the origin branch
-- Reversible: SELECT cron.unschedule('apply-due-staff-transfers'); SELECT cron.unschedule('notify-left-behind-bookings');

CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'apply-due-staff-transfers') THEN
    PERFORM cron.unschedule('apply-due-staff-transfers');
  END IF;
  PERFORM cron.schedule('apply-due-staff-transfers', '*/5 * * * *',
    'SELECT public.apply_due_staff_transfers(); SELECT public.apply_due_staff_reverts();');

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'notify-left-behind-bookings') THEN
    PERFORM cron.unschedule('notify-left-behind-bookings');
  END IF;
  PERFORM cron.schedule('notify-left-behind-bookings', '15 0 * * *',
    'SELECT public.notify_left_behind_bookings();');
END $$;

INSERT INTO public.schema_migrations (version, name)
VALUES ('005', 'staff-transfer-cron')
ON CONFLICT DO NOTHING;
