-- migration-022-rollback (CMD-62): undo migration-022 as far as it can be undone.
--
-- CANNOT RESTORE PLAIN PINs: they were NULLed by the backfill and only the bcrypt hashes exist. This file puts the OLD function bodies back (they compare
-- u.pin = p_pin), drops the hashing trigger and the new functions, KEEPS public.user_pins and its hashes, and leaves users.pin NULL.
-- CONSEQUENCE: after this file PIN login and list_discount_approvers() work for NOBODY until PINs are written into users.pin by hand. The old state is
-- also the vulnerability (plain-text PINs readable by manager, admin, admin_viewer), so rolling forward is the safer recovery. Run as postgres, local first.
-- ORDER: pin-login needs no change for 022 (it only calls login_with_pin), so there is nothing to revert on the edge side first.

BEGIN;

DROP TRIGGER IF EXISTS users_hash_plain_pin ON public.users;
DROP FUNCTION IF EXISTS public._users_hash_plain_pin();
DROP FUNCTION IF EXISTS public.set_my_pin(text, text);
DROP FUNCTION IF EXISTS public.admin_reset_pin(uuid);

-- old bodies (schema.sql and migration-014). CREATE OR REPLACE keeps the grants.
CREATE OR REPLACE FUNCTION public.login_with_pin(p_email text, p_pin text, p_org_slug text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
DECLARE
  v_user record;
  v_auth_user record;
BEGIN
  -- Find user by email and PIN
  SELECT u.*, o.slug as org_slug
  INTO v_user
  FROM users u
  LEFT JOIN organizations o ON u.org_id = o.id
  WHERE u.email = p_email AND u.pin = p_pin AND u.is_active = true;

  IF v_user IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Invalid email or PIN');
  END IF;

  -- Check org slug if provided
  IF p_org_slug IS NOT NULL AND v_user.org_slug != p_org_slug THEN
    RETURN json_build_object('success', false, 'error', 'User does not belong to this organization');
  END IF;

  RETURN json_build_object(
    'success', true,
    'user_id', v_user.id,
    'email', v_user.email,
    'role', v_user.role,
    'full_name', v_user.full_name,
    'org_slug', v_user.org_slug
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_pin(p_email text, p_pin text, p_org_slug text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_user record;
  v_org record;
BEGIN
  -- Find user by email and PIN
  SELECT u.*, o.slug as org_slug
  INTO v_user
  FROM users u
  LEFT JOIN organizations o ON u.org_id = o.id
  WHERE u.email = p_email AND u.pin = p_pin AND u.is_active = true;

  IF v_user IS NULL THEN
    RETURN json_build_object('valid', false, 'error', 'Invalid email or PIN');
  END IF;

  -- Check org slug if provided
  IF p_org_slug IS NOT NULL AND v_user.org_slug != p_org_slug THEN
    RETURN json_build_object('valid', false, 'error', 'User does not belong to this organization');
  END IF;

  RETURN json_build_object(
    'valid', true,
    'user_id', v_user.id,
    'email', v_user.email,
    'role', v_user.role,
    'full_name', v_user.full_name
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_discount_approvers()
 RETURNS TABLE(id uuid, full_name text, role user_role, branch_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT u.id, u.full_name, u.role, u.branch_id
  FROM public.users u
  WHERE u.is_active = true
    AND u.pin IS NOT NULL AND u.pin <> ''
    AND u.id <> auth.uid()
    AND public.can_read_money()
    AND u.org_id = (SELECT org_id FROM public.users WHERE id = auth.uid())
    AND (
      u.role = 'admin'
      OR (u.role = 'manager'
          AND u.branch_id = (SELECT branch_id FROM public.users WHERE id = auth.uid()))
    )
  ORDER BY u.role DESC, u.full_name;
$function$;

DROP FUNCTION IF EXISTS public._pin_try(uuid, text, boolean);
DROP FUNCTION IF EXISTS public._pin_random();
DROP FUNCTION IF EXISTS public._pin_is_trivial(text);
-- user_pins is KEPT on purpose (the hashes are all that is left of the PINs). Drop it by hand only when you are sure: DROP TABLE public.user_pins;

DELETE FROM public.schema_migrations WHERE version = '022';

COMMIT;
