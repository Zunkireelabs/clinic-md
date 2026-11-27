-- migration-012-rollback (CMD-78): undo migration-012. Drops action_log and booking_flags, so the audit rows are LOST: export them first.
-- Run as postgres. Not for production without the owner.

BEGIN;

DROP FUNCTION IF EXISTS public.act_undo(uuid, text, jsonb);
DROP FUNCTION IF EXISTS public.act_booking_flag_not_confirmed(uuid, text, jsonb);
DROP FUNCTION IF EXISTS public.act_booking_reschedule(uuid, date, time, jsonb, jsonb);
DROP FUNCTION IF EXISTS public.act_booking_set_status(uuid, public.booking_status, text, jsonb);
DROP FUNCTION IF EXISTS public._act_finish(jsonb, text, uuid, uuid, jsonb, boolean, jsonb, text, text, uuid, jsonb, text);
DROP FUNCTION IF EXISTS public._act_ctx_inputs(jsonb, jsonb);
DROP FUNCTION IF EXISTS public._act_in_scope(jsonb, uuid, uuid);
DROP FUNCTION IF EXISTS public._act_resolve(jsonb);

DROP TABLE IF EXISTS public.booking_flags;
DROP TABLE IF EXISTS public.action_log;      -- its guard triggers go with it
DROP FUNCTION IF EXISTS public._action_log_guard();

COMMIT;
