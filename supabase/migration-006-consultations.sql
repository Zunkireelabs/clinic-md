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
CREATE UNIQUE INDEX IF NOT EXISTS uniq_phone_pairings_open_short
    ON public.phone_pairings (short_hash) WHERE used_at IS NULL AND short_hash IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.phone_pairing_failures (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    ip text,
    created_at timestamp with time zone NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_phone_pairing_failures_recent ON public.phone_pairing_failures (created_at);
ALTER TABLE public.phone_pairing_failures ENABLE ROW LEVEL SECURITY;

-- ── RLS: consultations (org-scoped; read-only admins can read but not write) ──────────────────────────────────────────
ALTER TABLE public.consultations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Staff can read own org consultations" ON public.consultations;
CREATE POLICY "Staff can read own org consultations" ON public.consultations FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id());

DROP POLICY IF EXISTS "Staff can create own org consultations" ON public.consultations;
CREATE POLICY "Staff can create own org consultations" ON public.consultations FOR INSERT TO authenticated
  WITH CHECK (
    org_id = public.get_user_org_id()
    AND public.get_user_role() IN ('staff', 'manager', 'admin')
    AND EXISTS (
      SELECT 1 FROM public.bookings bk
      JOIN public.branches b ON b.id = bk.branch_id
      WHERE bk.id = consultations.booking_id AND b.org_id = public.get_user_org_id()
    )
  );

DROP POLICY IF EXISTS "Staff can update own org consultations" ON public.consultations;
CREATE POLICY "Staff can update own org consultations" ON public.consultations FOR UPDATE TO authenticated
  USING (org_id = public.get_user_org_id() AND public.get_user_role() IN ('staff', 'manager', 'admin'))
  WITH CHECK (org_id = public.get_user_org_id() AND public.get_user_role() IN ('staff', 'manager', 'admin'));

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

DROP POLICY IF EXISTS "Org staff read consultation files" ON storage.objects;
CREATE POLICY "Org staff read consultation files" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id IN ('consultation-audio', 'consultation-images')
         AND (storage.foldername(name))[1] = public.get_user_org_id()::text);

DROP POLICY IF EXISTS "Org staff upload consultation files" ON storage.objects;
CREATE POLICY "Org staff upload consultation files" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id IN ('consultation-audio', 'consultation-images')
              AND (storage.foldername(name))[1] = public.get_user_org_id()::text
              AND public.get_user_role() IN ('staff', 'manager', 'admin'));

DROP POLICY IF EXISTS "Org staff delete consultation files" ON storage.objects;
CREATE POLICY "Org staff delete consultation files" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id IN ('consultation-audio', 'consultation-images')
         AND (storage.foldername(name))[1] = public.get_user_org_id()::text
         AND public.get_user_role() IN ('staff', 'manager', 'admin'));

COMMIT;
