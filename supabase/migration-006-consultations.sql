-- migration-006-consultations.sql
-- Doctor consultations (Yukta's feature/adventra-feat): extracted from the additions appended to schema.sql / rls.sql.
-- Tables: consultations, push_subscriptions, phone_pairings, phone_pairing_failures; the attendee trigger; the realtime
-- publication entry; the two private storage buckets and their policies; RLS policies.
-- Idempotent: safe to run more than once (IF NOT EXISTS / DROP ... IF EXISTS before CREATE / ON CONFLICT).

BEGIN;

-- ── Consultations ─────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.consultations (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    org_id uuid NOT NULL REFERENCES public.organizations(id),
    branch_id uuid REFERENCES public.branches(id),
    booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
    customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL,
    dentist_id uuid REFERENCES public.dentists(id) ON DELETE SET NULL,
    created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
    patient_name text NOT NULL,
    status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'completed')),
    transcript text,
    detected_language text,
    recording_duration_seconds integer,
    audio_paths text[] NOT NULL DEFAULT '{}',
    preliminary_summary text,
    xray_analysis text,
    xray_image_paths text[] NOT NULL DEFAULT '{}',
    photo_analysis text,
    photo_image_paths text[] NOT NULL DEFAULT '{}',
    additional_notes text,
    doctor_notes text,
    final_summary text,
    session_date date NOT NULL DEFAULT CURRENT_DATE,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Columns added later in the original change (kept as separate ADD COLUMNs so an older partial table is brought up to date)
ALTER TABLE public.consultations ADD COLUMN IF NOT EXISTS created_by_name text;
ALTER TABLE public.consultations ADD COLUMN IF NOT EXISTS attended_by_names text[] NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS idx_consultations_booking ON public.consultations (booking_id);
CREATE INDEX IF NOT EXISTS idx_consultations_customer ON public.consultations (customer_id);
CREATE INDEX IF NOT EXISTS idx_consultations_org_date ON public.consultations (org_id, session_date DESC);

-- One open draft per booking (desktop + phone can open the same consultation at once)
CREATE UNIQUE INDEX IF NOT EXISTS uniq_consultations_open_draft
    ON public.consultations (booking_id) WHERE status = 'draft';

DROP TRIGGER IF EXISTS consultations_updated_at ON public.consultations;
CREATE TRIGGER consultations_updated_at BEFORE UPDATE ON public.consultations
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- Backfill for rows that predate the name columns (no-op on a fresh table)
UPDATE public.consultations c SET created_by_name = u.full_name FROM public.users u WHERE u.id = c.created_by AND c.created_by_name IS NULL;
UPDATE public.consultations SET attended_by_names = ARRAY[created_by_name] WHERE created_by_name IS NOT NULL AND attended_by_names = '{}';

-- Which doctors attended: whoever creates or changes a consultation is added by name (from the logged-in user)
CREATE OR REPLACE FUNCTION public.consultation_track_attendee() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_name text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT full_name INTO v_name FROM public.users WHERE id = auth.uid();
  IF v_name IS NOT NULL AND NOT (v_name = ANY (NEW.attended_by_names)) THEN
    NEW.attended_by_names := array_append(NEW.attended_by_names, v_name);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS consultations_track_attendee ON public.consultations;
CREATE TRIGGER consultations_track_attendee BEFORE INSERT OR UPDATE ON public.consultations
    FOR EACH ROW EXECUTE FUNCTION public.consultation_track_attendee();

-- Live sync through Supabase Realtime
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'consultations'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.consultations;
  END IF;
END $$;

-- ── Web Push subscriptions ────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.push_subscriptions (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    org_id uuid NOT NULL REFERENCES public.organizations(id),
    endpoint text NOT NULL UNIQUE,
    p256dh text NOT NULL,
    auth text NOT NULL,
    user_agent text,
    created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_push_subscriptions_user ON public.push_subscriptions (user_id);

-- ── Phone pairing (only reachable through the phone-pair Edge Function / service role: no policies) ────────────────────
CREATE TABLE IF NOT EXISTS public.phone_pairings (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    code_hash text NOT NULL UNIQUE,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.phone_pairings ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.phone_pairings ADD COLUMN IF NOT EXISTS short_hash text;
-- purpose: 'signin' codes (256-bit long code in the QR link) sign a phone in; 'verify' codes (6 digits) only confirm that the person
-- holding an ALREADY signed-in phone is at the computer. A verify code can never sign anything in.
ALTER TABLE public.phone_pairings ADD COLUMN IF NOT EXISTS purpose text NOT NULL DEFAULT 'signin';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'phone_pairings_purpose_check') THEN
    ALTER TABLE public.phone_pairings ADD CONSTRAINT phone_pairings_purpose_check CHECK (purpose IN ('signin', 'verify'));
  END IF;
END $$;
-- wrong guesses made against a user's open verify codes; at 5 the codes are burnt
ALTER TABLE public.phone_pairings ADD COLUMN IF NOT EXISTS attempts integer NOT NULL DEFAULT 0;

-- A short hash only has to be unique among one user's open codes (it is only ever looked up together with the user id).
DROP INDEX IF EXISTS public.uniq_phone_pairings_open_short;
CREATE UNIQUE INDEX IF NOT EXISTS uniq_phone_pairings_open_short_user
    ON public.phone_pairings (user_id, short_hash) WHERE used_at IS NULL AND short_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_phone_pairings_user_created ON public.phone_pairings (user_id, created_at);

-- Failure log: counted per user (and per code through phone_pairings.attempts), never globally.
CREATE TABLE IF NOT EXISTS public.phone_pairing_failures (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    ip text,
    created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.phone_pairing_failures ADD COLUMN IF NOT EXISTS user_id uuid;
CREATE INDEX IF NOT EXISTS idx_phone_pairing_failures_recent ON public.phone_pairing_failures (created_at);
CREATE INDEX IF NOT EXISTS idx_phone_pairing_failures_user ON public.phone_pairing_failures (user_id, created_at);
ALTER TABLE public.phone_pairing_failures ENABLE ROW LEVEL SECURITY;

-- Mint a code, rate-limited per user (at most 5 codes per 10 minutes), under a per-user advisory lock so parallel requests can't slip past.
CREATE OR REPLACE FUNCTION public.phone_pairing_create(p_user uuid, p_code_hash text, p_short_hash text, p_purpose text, p_expires timestamptz)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_recent integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('pairing:' || p_user::text, 0));
  SELECT count(*) INTO v_recent FROM public.phone_pairings WHERE user_id = p_user AND created_at > now() - interval '10 minutes';
  IF v_recent >= 5 THEN RETURN 'rate_limited'; END IF;
  INSERT INTO public.phone_pairings (user_id, code_hash, short_hash, purpose, expires_at)
  VALUES (p_user, p_code_hash, p_short_hash, p_purpose, p_expires);
  RETURN 'ok';
END $$;

-- Redeem a sign-in code (the long QR code only). Single use; verify codes can never match.
CREATE OR REPLACE FUNCTION public.phone_pairing_redeem(p_code_hash text)
RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  UPDATE public.phone_pairings SET used_at = now()
  WHERE code_hash = p_code_hash AND purpose = 'signin' AND used_at IS NULL AND expires_at > now()
  RETURNING user_id;
$$;

-- Verify a 6-digit code for an already signed-in user. Atomic: serialised per user with an advisory lock, then the attempt is
-- recorded and counted in the same transaction. 5 wrong guesses in 10 minutes lock the user out; 5 wrong guesses against the
-- open codes burn them. Returns 'ok' | 'wrong' | 'locked'.
CREATE OR REPLACE FUNCTION public.phone_pairing_verify(p_user uuid, p_short_hash text, p_ip text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_fails integer; v_id uuid;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('pairing:' || p_user::text, 0));
  SELECT count(*) INTO v_fails FROM public.phone_pairing_failures WHERE user_id = p_user AND created_at > now() - interval '10 minutes';
  IF v_fails >= 5 THEN RETURN 'locked'; END IF;

  UPDATE public.phone_pairings SET used_at = now()
  WHERE user_id = p_user AND purpose = 'verify' AND short_hash = p_short_hash AND used_at IS NULL AND expires_at > now() AND attempts < 5
  RETURNING id INTO v_id;
  IF v_id IS NOT NULL THEN RETURN 'ok'; END IF;

  INSERT INTO public.phone_pairing_failures (user_id, ip) VALUES (p_user, p_ip);
  UPDATE public.phone_pairings SET attempts = attempts + 1, used_at = CASE WHEN attempts + 1 >= 5 THEN now() ELSE used_at END
  WHERE user_id = p_user AND purpose = 'verify' AND used_at IS NULL AND expires_at > now();
  RETURN 'wrong';
END $$;

REVOKE ALL ON FUNCTION public.phone_pairing_create(uuid, text, text, text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phone_pairing_redeem(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.phone_pairing_verify(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.phone_pairing_create(uuid, text, text, text, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.phone_pairing_redeem(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.phone_pairing_verify(uuid, text, text) TO service_role;

-- ── AI usage quota (cost control): at most p_limit calls per user per hour; atomic upsert ───────────────────────────────
CREATE TABLE IF NOT EXISTS public.ai_usage (
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    window_start timestamp with time zone NOT NULL,
    calls integer NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, window_start)
);
ALTER TABLE public.ai_usage ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.consume_ai_quota(p_user uuid, p_limit integer DEFAULT 60)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_calls integer;
BEGIN
  INSERT INTO public.ai_usage (user_id, window_start, calls) VALUES (p_user, date_trunc('hour', now()), 1)
  ON CONFLICT (user_id, window_start) DO UPDATE SET calls = public.ai_usage.calls + 1
  RETURNING calls INTO v_calls;
  DELETE FROM public.ai_usage WHERE window_start < now() - interval '2 days';
  RETURN v_calls <= p_limit;
END $$;
REVOKE ALL ON FUNCTION public.consume_ai_quota(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_ai_quota(uuid, integer) TO service_role;

-- ── Branch isolation: same rule as bookings. Admin / admin_viewer see the whole org; others only their branches. ─────────
-- Uses the BOOKING's branch (a consultation's own branch_id is a copy). Storage objects live under "<org_id>/<booking_id>/<file>".
CREATE OR REPLACE FUNCTION public.can_access_consultation_booking(p_booking uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.bookings bk JOIN public.branches b ON b.id = bk.branch_id
    WHERE bk.id = p_booking AND b.org_id = public.get_user_org_id()
      AND (public.get_user_role() IN ('admin', 'admin_viewer') OR bk.branch_id = ANY (public.get_user_branch_ids()))
  );
$$;

-- The booking's org, customer, dentist and branch must all belong to the caller's org (used by INSERT and UPDATE checks).
CREATE OR REPLACE FUNCTION public.consultation_refs_ok(p_org uuid, p_branch uuid, p_customer uuid, p_dentist uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT p_org = public.get_user_org_id()
    AND (p_branch IS NULL OR EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch AND org_id = p_org))
    AND (p_customer IS NULL OR EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer AND org_id = p_org))
    AND (p_dentist IS NULL OR EXISTS (SELECT 1 FROM public.dentists d JOIN public.branches b ON b.id = d.branch_id WHERE d.id = p_dentist AND b.org_id = p_org));
$$;

-- created_by is forced to the caller on insert and can't change afterwards; booking and org are fixed too.
CREATE OR REPLACE FUNCTION public.consultation_guard_columns() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF auth.uid() IS NOT NULL THEN NEW.created_by := auth.uid(); END IF;
  ELSE
    NEW.created_by := OLD.created_by;
    NEW.booking_id := OLD.booking_id;
    NEW.org_id := OLD.org_id;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS consultations_guard_columns ON public.consultations;
CREATE TRIGGER consultations_guard_columns BEFORE INSERT OR UPDATE ON public.consultations
    FOR EACH ROW EXECUTE FUNCTION public.consultation_guard_columns();

-- ── RLS: consultations (org-scoped; read-only admins can read but not write) ──────────────────────────────────────────
ALTER TABLE public.consultations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Staff can read own org consultations" ON public.consultations;
DROP POLICY IF EXISTS "Staff can read branch consultations" ON public.consultations;
CREATE POLICY "Staff can read branch consultations" ON public.consultations FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id() AND public.can_access_consultation_booking(booking_id));

DROP POLICY IF EXISTS "Staff can create own org consultations" ON public.consultations;
DROP POLICY IF EXISTS "Staff can create branch consultations" ON public.consultations;
CREATE POLICY "Staff can create branch consultations" ON public.consultations FOR INSERT TO authenticated
  WITH CHECK (
    org_id = public.get_user_org_id()
    AND public.get_user_role() IN ('staff', 'manager', 'admin')
    AND public.can_access_consultation_booking(booking_id)
    AND public.consultation_refs_ok(org_id, branch_id, customer_id, dentist_id)
  );

DROP POLICY IF EXISTS "Staff can update own org consultations" ON public.consultations;
DROP POLICY IF EXISTS "Staff can update branch consultations" ON public.consultations;
CREATE POLICY "Staff can update branch consultations" ON public.consultations FOR UPDATE TO authenticated
  USING (org_id = public.get_user_org_id() AND public.get_user_role() IN ('staff', 'manager', 'admin') AND public.can_access_consultation_booking(booking_id))
  WITH CHECK (
    org_id = public.get_user_org_id()
    AND public.get_user_role() IN ('staff', 'manager', 'admin')
    AND public.can_access_consultation_booking(booking_id)
    AND public.consultation_refs_ok(org_id, branch_id, customer_id, dentist_id)
  );

-- ── RLS: push subscriptions (each user manages only their own) ────────────────────────────────────────────────────────
ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users read own push subscriptions" ON public.push_subscriptions;
CREATE POLICY "Users read own push subscriptions" ON public.push_subscriptions FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Users add own push subscriptions" ON public.push_subscriptions;
CREATE POLICY "Users add own push subscriptions" ON public.push_subscriptions FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND org_id = public.get_user_org_id());

DROP POLICY IF EXISTS "Users update own push subscriptions" ON public.push_subscriptions;
CREATE POLICY "Users update own push subscriptions" ON public.push_subscriptions FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid() AND org_id = public.get_user_org_id());

DROP POLICY IF EXISTS "Users delete own push subscriptions" ON public.push_subscriptions;
CREATE POLICY "Users delete own push subscriptions" ON public.push_subscriptions FOR DELETE TO authenticated
  USING (user_id = auth.uid());

-- ── Storage: private consultation-audio / consultation-images buckets; objects live under "<org_id>/<booking_id>/<file>" ─
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES
  ('consultation-audio', 'consultation-audio', false, 52428800),
  ('consultation-images', 'consultation-images', false, 10485760)
ON CONFLICT (id) DO NOTHING;

-- The booking id is the 2nd path segment; the object is only visible / writable if the caller can access that booking (branch rule).
-- (The 2nd segment is cast defensively: a malformed path simply matches no booking.)
CREATE OR REPLACE FUNCTION public.consultation_object_booking(p_name text) RETURNS uuid
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN ((storage.foldername(p_name))[2])::uuid;
EXCEPTION WHEN others THEN
  RETURN NULL;
END $$;

DROP POLICY IF EXISTS "Org staff read consultation files" ON storage.objects;
DROP POLICY IF EXISTS "Branch staff read consultation files" ON storage.objects;
CREATE POLICY "Branch staff read consultation files" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id IN ('consultation-audio', 'consultation-images')
         AND (storage.foldername(name))[1] = public.get_user_org_id()::text
         AND public.can_access_consultation_booking(public.consultation_object_booking(name)));

DROP POLICY IF EXISTS "Org staff upload consultation files" ON storage.objects;
DROP POLICY IF EXISTS "Branch staff upload consultation files" ON storage.objects;
CREATE POLICY "Branch staff upload consultation files" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id IN ('consultation-audio', 'consultation-images')
              AND (storage.foldername(name))[1] = public.get_user_org_id()::text
              AND public.get_user_role() IN ('staff', 'manager', 'admin')
              AND public.can_access_consultation_booking(public.consultation_object_booking(name)));

DROP POLICY IF EXISTS "Org staff delete consultation files" ON storage.objects;
DROP POLICY IF EXISTS "Branch staff delete consultation files" ON storage.objects;
CREATE POLICY "Branch staff delete consultation files" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id IN ('consultation-audio', 'consultation-images')
         AND (storage.foldername(name))[1] = public.get_user_org_id()::text
         AND public.get_user_role() IN ('staff', 'manager', 'admin')
         AND public.can_access_consultation_booking(public.consultation_object_booking(name)));

-- Topic "consultation-remote-<consultation id>": only people who can access that consultation's booking (same branch rule) may join
-- or broadcast, so nobody can spoof phone→desk activity. Malformed topics match nothing.
CREATE OR REPLACE FUNCTION public.consultation_remote_topic_ok(p_topic text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid; v_booking uuid;
BEGIN
  IF p_topic IS NULL OR p_topic NOT LIKE 'consultation-remote-%' THEN RETURN false; END IF;
  BEGIN
    v_id := substring(p_topic from 21)::uuid;
  EXCEPTION WHEN others THEN
    RETURN false;
  END;
  SELECT booking_id INTO v_booking FROM public.consultations WHERE id = v_id;
  RETURN v_booking IS NOT NULL AND public.can_access_consultation_booking(v_booking);
END $$;

-- ── Realtime: the phone-link channels are PRIVATE and scoped to the owner. A user may only join / broadcast on the topics
-- "doctor-phone-<own uid>" and "phone-unlock-<own uid>" (clients pass `private: true`). ─────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'realtime' AND table_name = 'messages') THEN
    DROP POLICY IF EXISTS "Own phone-link topics: read" ON realtime.messages;
    CREATE POLICY "Own phone-link topics: read" ON realtime.messages FOR SELECT TO authenticated
      USING (realtime.topic() IN ('doctor-phone-' || auth.uid()::text, 'phone-unlock-' || auth.uid()::text)
             OR public.consultation_remote_topic_ok(realtime.topic()));
    DROP POLICY IF EXISTS "Own phone-link topics: write" ON realtime.messages;
    CREATE POLICY "Own phone-link topics: write" ON realtime.messages FOR INSERT TO authenticated
      WITH CHECK (realtime.topic() IN ('doctor-phone-' || auth.uid()::text, 'phone-unlock-' || auth.uid()::text)
                  OR public.consultation_remote_topic_ok(realtime.topic()));
  END IF;
END $$;

COMMIT;
