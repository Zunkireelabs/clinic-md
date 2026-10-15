-- migration-010: per-clinic AI consultation switch + a higher phone verify-code limit.
--
-- 1. organizations.ai_consultation_enabled (default false). There is NO UPDATE policy on organizations, so a clinic
--    admin cannot change it from the client; enabling a clinic is a platform decision (owner-approved SQL for now).
--    supabase/tests/tenant-isolation.sql asserts an admin's UPDATE touches 0 rows, so adding an UPDATE policy later fails the test.
-- 2. org_ai_enabled(): the caller's own clinic flag (false when there is no clinic). Used by the app and the edge functions.
-- 3. phone_pairing_create: 'signin' codes stay at 5 per 10 minutes; 'verify' codes get 30 per 10 minutes (counted per purpose).
-- Apply this BEFORE deploying the client that calls org_ai_enabled().
-- Rollback: migration-010-rollback.sql

BEGIN;

ALTER TABLE public.organizations ADD COLUMN IF NOT EXISTS ai_consultation_enabled boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.org_ai_enabled()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE((SELECT o.ai_consultation_enabled FROM public.organizations o WHERE o.id = public.get_user_org_id()), false);
$function$;

-- since migration-009 default privileges are closed: grant explicitly
REVOKE EXECUTE ON FUNCTION public.org_ai_enabled() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.org_ai_enabled() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.phone_pairing_create(p_user uuid, p_code_hash text, p_short_hash text, p_purpose text, p_expires timestamp with time zone)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_recent integer; v_limit integer := CASE WHEN p_purpose = 'verify' THEN 30 ELSE 5 END;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('pairing:' || p_user::text, 0));
  SELECT count(*) INTO v_recent FROM public.phone_pairings
  WHERE user_id = p_user AND purpose = p_purpose AND created_at > now() - interval '10 minutes';
  IF v_recent >= v_limit THEN RETURN 'rate_limited'; END IF;
  INSERT INTO public.phone_pairings (user_id, code_hash, short_hash, purpose, expires_at)
  VALUES (p_user, p_code_hash, p_short_hash, p_purpose, p_expires);
  RETURN 'ok';
END $function$;

COMMIT;
