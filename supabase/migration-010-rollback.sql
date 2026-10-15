-- migration-010 rollback: restores phone_pairing_create exactly (5 codes per 10 minutes for every purpose) and removes the AI switch.
-- WARNING: dropping the column erases which clinics were switched on.
BEGIN;

CREATE OR REPLACE FUNCTION public.phone_pairing_create(p_user uuid, p_code_hash text, p_short_hash text, p_purpose text, p_expires timestamp with time zone)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_recent integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('pairing:' || p_user::text, 0));
  SELECT count(*) INTO v_recent FROM public.phone_pairings WHERE user_id = p_user AND created_at > now() - interval '10 minutes';
  IF v_recent >= 5 THEN RETURN 'rate_limited'; END IF;
  INSERT INTO public.phone_pairings (user_id, code_hash, short_hash, purpose, expires_at)
  VALUES (p_user, p_code_hash, p_short_hash, p_purpose, p_expires);
  RETURN 'ok';
END $function$;

DROP FUNCTION IF EXISTS public.org_ai_enabled();
ALTER TABLE public.organizations DROP COLUMN IF EXISTS ai_consultation_enabled;

COMMIT;
