-- migration-022 (CMD-62): staff PINs are hashed, wrong guesses lock the account, and no role can read a PIN.
--
-- WHY: users.pin was plain text. anon and authenticated hold table-level ALL on public.users, and RLS lets manager, admin and admin_viewer read every
-- user row of their org, so a read-only viewer could read the owner's PIN and log in as the owner (pin-login). login_with_pin compared u.pin = p_pin.
--
-- WHAT:
--   * public.user_pins (user_id, pin_hash, failed_count, locked_until): bcrypt (pgcrypto crypt/gen_salt('bf', 10)). RLS on, NO policy, every API
--     role revoked (the action_log pattern). Only the SECURITY DEFINER functions below, run by the owner, can touch it. Not a column on users: the
--     table-level grants would make a column REVOKE ineffective, and a column grant list would break AuthContext (select '*') and every future column.
--   * Backfill in this file: every non-empty users.pin is hashed into user_pins, then users.pin is NULLed for ALL rows. No format check on the
--     backfill, so every former PIN keeps working, weak ones included. The column stays for one release (old clients); it is always NULL.
--   * login_with_pin / verify_pin (same signature and return shape, grants unchanged: service_role only): bcrypt compare; 5 wrong guesses lock the
--     account for 15 minutes; a success resets the counter; unknown email, wrong PIN, locked account and wrong org slug all return the one message
--     'Invalid email or PIN'. A bcrypt compare against a dummy hash runs when there is no hash to compare with.
--   * set_my_pin(current, new) for the signed-in user; admin_reset_pin(user) for admins (returns a random temporary PIN once). Audited in
--     action_log as user.set_pin / user.reset_pin through the 012 action layer: ids and codes only, NEVER a PIN.
--   * list_discount_approvers() asks user_pins instead of users.pin.
--   * TEMPORARY BRIDGE: trigger users_hash_plain_pin on users. Any plain value written to users.pin (by postgres or service_role; RLS lets no one else write
--     users) is hashed into user_pins and the column stays NULL. It exists so an unknown prod writer of users.pin (CMD-11) cannot bring plain text back.
--     REMOVE THE TRIGGER AND ITS FUNCTION WHEN users.pin IS DROPPED (follow-up ticket).
--
-- PIN RULES: exactly 4 digits (the login form and pin-login accept nothing else), not all one digit, not a run (0123..., 3210...). 4 digits is weak:
-- 10,000 combinations. The lock slows guessing; it does not make a 4-digit PIN strong.
--
-- Requires 011 (users.role 'practitioner' is irrelevant here, but the test base is 001-018), 012 (_act_resolve, _act_finish, action_log), 014
-- (list_discount_approvers body). Independent of 019, 020, 021. NOT applied to production.
-- Before production: run migration-022-preflight.sql (counts only). Deploy supabase/functions/pin-login from this repo after 022.
-- ROLLBACK (migration-022-rollback.sql) CANNOT restore plain PINs: they are gone after the backfill. It restores the old function bodies, drops the
-- trigger and new functions, KEEPS user_pins and the hashes, and leaves users.pin NULL, so after a rollback PIN login and the discount-approver list
-- work for nobody until PINs are written into users.pin by hand. Rolling forward is the safer recovery.

BEGIN;

-- 1. the table ------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_pins (   -- IF NOT EXISTS: the rollback keeps this table, so rolling forward again must work
  user_id       uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- deferred: the INSERT trigger on users runs first
  pin_hash      text,
  failed_count  integer NOT NULL DEFAULT 0,
  locked_until  timestamptz,
  updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.user_pins ENABLE ROW LEVEL SECURITY;      -- no policy on purpose
REVOKE ALL ON public.user_pins FROM PUBLIC, anon, authenticated, service_role;

-- 2. helpers (owner only) ------------------------------------------------------------------------------------------------------
CREATE FUNCTION public._pin_is_trivial(p_pin text) RETURNS boolean
    LANGUAGE sql IMMUTABLE SET search_path = public
    AS $$
  SELECT p_pin ~ '^(\d)\1{3}$' OR position(p_pin IN '0123456789') > 0 OR position(p_pin IN '9876543210') > 0;
$$;

-- One guess at a user's PIN. Locks the user_pins row, so two parallel guesses cannot both slip under the limit. Returns true only for a right PIN
-- on an account that is not locked. p_force_fail makes a right PIN count as a wrong one (wrong org slug). Never raises on a wrong PIN, so the
-- counter update commits.
CREATE FUNCTION public._pin_try(p_user uuid, p_pin text, p_force_fail boolean DEFAULT false) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
    AS $$
DECLARE
  r public.user_pins; v_count integer; v_ok boolean;
  c_dummy constant text := '$2a$10$JmYG3V/1BG549LIqVTzG2ea0wFnDgvKHnsqvzcPNnuYzghMnlcy7q';
BEGIN
  SELECT * INTO r FROM public.user_pins WHERE user_id = p_user FOR UPDATE;
  IF NOT FOUND OR r.pin_hash IS NULL THEN
    PERFORM extensions.crypt(coalesce(p_pin, ''), c_dummy);
    RETURN false;
  END IF;
  IF r.locked_until IS NOT NULL AND r.locked_until > now() THEN
    PERFORM extensions.crypt(coalesce(p_pin, ''), c_dummy);   -- a locked account is not extended by more guessing
    RETURN false;
  END IF;
  v_count := CASE WHEN r.locked_until IS NOT NULL THEN 0 ELSE r.failed_count END;   -- the window has passed: start again
  v_ok := coalesce(r.pin_hash = extensions.crypt(coalesce(p_pin, ''), r.pin_hash), false) AND NOT p_force_fail;
  IF v_ok THEN
    UPDATE public.user_pins SET failed_count = 0, locked_until = NULL, updated_at = now() WHERE user_id = p_user;
    RETURN true;
  END IF;
  v_count := v_count + 1;
  UPDATE public.user_pins
     SET failed_count = v_count,
         locked_until = CASE WHEN v_count >= 5 THEN now() + interval '15 minutes' END,
         updated_at = now()
   WHERE user_id = p_user;
  RETURN false;
END $$;

-- A random 4-digit PIN that passes the trivial check. Never logged.
CREATE FUNCTION public._pin_random() RETURNS text
    LANGUAGE plpgsql VOLATILE SET search_path = public, extensions
    AS $$
DECLARE v text;
BEGIN
  LOOP
    v := lpad((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint % 10000)::text, 4, '0');
    EXIT WHEN NOT public._pin_is_trivial(v);
  END LOOP;
  RETURN v;
END $$;

-- 3. login_with_pin / verify_pin: same signature and return shape. CREATE OR REPLACE keeps the 009 grants (service_role only). ------
CREATE OR REPLACE FUNCTION public.login_with_pin(p_email text, p_pin text, p_org_slug text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
DECLARE
  v_user record;
BEGIN
  SELECT u.id, u.email, u.role, u.full_name, o.slug AS org_slug INTO v_user
    FROM users u LEFT JOIN organizations o ON u.org_id = o.id
   WHERE u.email = p_email AND u.is_active = true;
  IF v_user.id IS NULL THEN
    PERFORM extensions.crypt(coalesce(p_pin, ''), '$2a$10$JmYG3V/1BG549LIqVTzG2ea0wFnDgvKHnsqvzcPNnuYzghMnlcy7q');
    RETURN json_build_object('success', false, 'error', 'Invalid email or PIN');
  END IF;
  IF NOT public._pin_try(v_user.id, p_pin, p_org_slug IS NOT NULL AND v_user.org_slug IS DISTINCT FROM p_org_slug) THEN
    RETURN json_build_object('success', false, 'error', 'Invalid email or PIN');
  END IF;
  RETURN json_build_object('success', true, 'user_id', v_user.id, 'email', v_user.email, 'role', v_user.role,
                           'full_name', v_user.full_name, 'org_slug', v_user.org_slug);
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_pin(p_email text, p_pin text, p_org_slug text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
DECLARE
  v_user record;
BEGIN
  SELECT u.id, u.email, u.role, u.full_name, o.slug AS org_slug INTO v_user
    FROM users u LEFT JOIN organizations o ON u.org_id = o.id
   WHERE u.email = p_email AND u.is_active = true;
  IF v_user.id IS NULL THEN
    PERFORM extensions.crypt(coalesce(p_pin, ''), '$2a$10$JmYG3V/1BG549LIqVTzG2ea0wFnDgvKHnsqvzcPNnuYzghMnlcy7q');
    RETURN json_build_object('valid', false, 'error', 'Invalid email or PIN');
  END IF;
  IF NOT public._pin_try(v_user.id, p_pin, p_org_slug IS NOT NULL AND v_user.org_slug IS DISTINCT FROM p_org_slug) THEN
    RETURN json_build_object('valid', false, 'error', 'Invalid email or PIN');
  END IF;
  RETURN json_build_object('valid', true, 'user_id', v_user.id, 'email', v_user.email, 'role', v_user.role, 'full_name', v_user.full_name);
END;
$$;

-- 4. set_my_pin: the signed-in user sets their own PIN. Needs the current PIN once a PIN exists; the first PIN needs none (they are already signed
--    in with a password). A wrong current PIN counts toward the same 5-failure lock and answers with one generic message. -------------------
CREATE FUNCTION public.set_my_pin(p_current_pin text, p_new_pin text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
    AS $$
DECLARE
  ctx jsonb; v_org uuid; v_uid uuid; v_has boolean; v_inputs jsonb; a constant text := 'user.set_pin';
BEGIN
  ctx := public._act_resolve(NULL);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  IF ctx ->> 'kind' <> 'person' THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', 'FORBIDDEN', 'message', 'Only a signed-in person can set their own PIN.'));
  END IF;
  v_uid := (ctx ->> 'user_id')::uuid; v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('user_id', v_uid);          -- ids only: never a PIN

  IF p_new_pin IS NULL OR p_new_pin !~ '^[0-9]{4}$' THEN
    RETURN public._act_finish(ctx, a, v_org, NULL, v_inputs, false, NULL, 'INVALID_PIN', 'A PIN is exactly 4 digits.', v_uid, NULL, 'users');
  END IF;
  IF public._pin_is_trivial(p_new_pin) THEN
    RETURN public._act_finish(ctx, a, v_org, NULL, v_inputs, false, NULL, 'TRIVIAL_PIN', 'Choose a PIN that is not a repeated digit or a run like 1234.', v_uid, NULL, 'users');
  END IF;

  SELECT pin_hash IS NOT NULL INTO v_has FROM public.user_pins WHERE user_id = v_uid FOR UPDATE;
  IF coalesce(v_has, false) THEN
    IF NOT public._pin_try(v_uid, p_current_pin) THEN
      RETURN public._act_finish(ctx, a, v_org, NULL, v_inputs, false, NULL, 'WRONG_PIN', 'Invalid PIN.', v_uid, NULL, 'users');
    END IF;
  END IF;

  INSERT INTO public.user_pins (user_id, pin_hash, failed_count, locked_until, updated_at)
  VALUES (v_uid, extensions.crypt(p_new_pin, extensions.gen_salt('bf', 10)), 0, NULL, now())
  ON CONFLICT (user_id) DO UPDATE SET pin_hash = EXCLUDED.pin_hash, failed_count = 0, locked_until = NULL, updated_at = now();
  RETURN public._act_finish(ctx, a, v_org, NULL, v_inputs, true, jsonb_build_object('user_id', v_uid), NULL, NULL, v_uid, NULL, 'users');
END $$;

-- 5. admin_reset_pin: an admin sets a random temporary PIN for a colleague of the same org (never for themselves: they use set_my_pin). The PIN is
--    returned ONCE in the result and written nowhere else: not to a table, not to action_log (the log call gets no PIN), not to any message. -----
CREATE FUNCTION public.admin_reset_pin(p_user uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
    AS $$
DECLARE
  ctx jsonb; v_org uuid; v_actor uuid; t public.users; v_inputs jsonb; v_pin text; v_res jsonb; a constant text := 'user.reset_pin';
BEGIN
  ctx := public._act_resolve(NULL);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid; v_actor := (ctx ->> 'user_id')::uuid;
  v_inputs := jsonb_build_object('target_user_id', p_user);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' <> 'admin' THEN
    RETURN public._act_finish(ctx, a, v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Only an admin can reset a PIN.', p_user, NULL, 'users');
  END IF;
  IF p_user IS NULL OR p_user = v_actor THEN
    RETURN public._act_finish(ctx, a, v_org, NULL, v_inputs, false, NULL, 'INVALID_INPUT', 'Choose a colleague. To change your own PIN use set_my_pin.', p_user, NULL, 'users');
  END IF;
  SELECT * INTO t FROM public.users WHERE id = p_user AND org_id = v_org AND is_active IS NOT FALSE;
  IF t.id IS NULL THEN
    RETURN public._act_finish(ctx, a, v_org, NULL, v_inputs, false, NULL, 'USER_NOT_FOUND', 'User not found.', p_user, NULL, 'users');
  END IF;

  v_pin := public._pin_random();
  INSERT INTO public.user_pins (user_id, pin_hash, failed_count, locked_until, updated_at)
  VALUES (t.id, extensions.crypt(v_pin, extensions.gen_salt('bf', 10)), 0, NULL, now())
  ON CONFLICT (user_id) DO UPDATE SET pin_hash = EXCLUDED.pin_hash, failed_count = 0, locked_until = NULL, updated_at = now();
  v_res := public._act_finish(ctx, a, v_org, NULL, v_inputs, true, jsonb_build_object('target_user_id', t.id), NULL, NULL, t.id, NULL, 'users');
  RETURN v_res || jsonb_build_object('temporary_pin', v_pin);       -- added AFTER the log row was written
END $$;

-- 6. list_discount_approvers: the 014 body, asking user_pins instead of users.pin ------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_discount_approvers()
 RETURNS TABLE(id uuid, full_name text, role user_role, branch_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT u.id, u.full_name, u.role, u.branch_id
  FROM public.users u
  WHERE u.is_active = true
    AND EXISTS (SELECT 1 FROM public.user_pins p WHERE p.user_id = u.id AND p.pin_hash IS NOT NULL)
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

-- 7. backfill: hash every non-empty PIN, then NULL the plain column for every row ---------------------------------------------------
INSERT INTO public.user_pins (user_id, pin_hash)
SELECT id, extensions.crypt(pin, extensions.gen_salt('bf', 10)) FROM public.users WHERE pin IS NOT NULL AND pin <> ''
ON CONFLICT (user_id) DO NOTHING;
UPDATE public.users SET pin = NULL WHERE pin IS NOT NULL;

-- 8. TEMPORARY BRIDGE (remove when users.pin is dropped): a plain write to users.pin is hashed and the column stays NULL ----------------
CREATE FUNCTION public._users_hash_plain_pin() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
    AS $$
BEGIN
  IF NEW.pin IS NOT NULL AND NEW.pin <> '' THEN
    INSERT INTO public.user_pins (user_id, pin_hash, failed_count, locked_until, updated_at)
    VALUES (NEW.id, extensions.crypt(NEW.pin, extensions.gen_salt('bf', 10)), 0, NULL, now())
    ON CONFLICT (user_id) DO UPDATE SET pin_hash = EXCLUDED.pin_hash, failed_count = 0, locked_until = NULL, updated_at = now();
  END IF;
  NEW.pin := NULL;
  RETURN NEW;
END $$;
CREATE TRIGGER users_hash_plain_pin BEFORE INSERT OR UPDATE OF pin ON public.users
  FOR EACH ROW WHEN (NEW.pin IS NOT NULL) EXECUTE FUNCTION public._users_hash_plain_pin();

-- 9. grants: helpers and the trigger function for nobody (the owner runs them); the two person functions for signed-in users only -------
REVOKE ALL ON FUNCTION public._pin_is_trivial(text), public._pin_try(uuid, text, boolean), public._pin_random(), public._users_hash_plain_pin()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_my_pin(text, text), public.admin_reset_pin(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_my_pin(text, text), public.admin_reset_pin(uuid) TO authenticated;

INSERT INTO public.schema_migrations (version, name) VALUES ('022', 'staff-pin') ON CONFLICT DO NOTHING;

COMMIT;
