-- migration-020 (CMD-54 + CMD-55): consultation groundwork. Recording consent, AI provenance and signing, a source for every note line,
-- recordings deleted 30 days after signing.
--
-- Requires 011 (is_my_booking, the 'practitioner' role) and 012/016 (_act_resolve, _act_finish, action_log). Independent of 019 (CMD-100):
-- it touches no read policy. NOT applied to production. Prod order: after 011-018 (and 019 if it went first), and only after every
-- dentist who logs in as role 'staff' has been moved to 'practitioner' (run migration-020-preflight.sql first: 020 refuses staff).
-- Rollback: migration-020-rollback.sql (revert the client and edge functions FIRST, then the SQL).
-- Design: docs/briefs/CMD-54-data-design.md (approved by the lead 2026-11-23, 9.3/10). Brief: docs/briefs/CMD-54-consultation-data.md.
--
-- ADDITIVE ONLY. Every new column is nullable or has a constant default (metadata-only on PG 11+). Code that writes none of the new columns
-- keeps working. A row from before 020 has signed_at NULL and behaves exactly as it does today.
--
-- WHO WRITES WHAT
--   * person functions (SECURITY DEFINER, signed-in users): consultation_record_consent, consultation_sign, consultation_unsign. Audited in
--     action_log as consultation.record_consent / .sign / .unsign (ids and codes only, never note text: staff read action_log in their branch).
--     Allowed roles: practitioner (own bookings only, is_my_booking), manager (branch), admin (org). staff, admin_viewer, service role, agents: refused.
--   * service-role writers (SECURITY INVOKER, EXECUTE for service_role only), called by edge functions after they have read the row through the
--     user's own client: consultation_store_segments, consultation_store_draft, consultation_retention_due, consultation_mark_audio_deleted.
--     INVOKER on purpose: the lock trigger must see current_user = 'service_role' for the retention exception.
--
-- THE GUARD TRIGGER (consultations_lock_signed, plpgsql, NOT security definer: it reads current_user, which inside a SECURITY DEFINER function
-- is the function owner; proven by the first check of tenant-isolation.sql section 3i)
--   Rule A: the function-only columns cannot be set or changed by 'authenticated' or 'anon'. (006/011 policies let those roles UPDATE any column.)
--   Rule B: a signed row (OLD.signed_at NOT NULL) is frozen for every role, service_role and direct SQL included, except additional_notes,
--           attended_by_names and updated_at. Two exceptions: unsign (signed_at -> NULL, only from a SECURITY DEFINER function) and retention
--           (service_role may shrink audio_paths and set audio_deleted_at).

BEGIN;

-- 1. columns -----------------------------------------------------------------------------------------------------------------
ALTER TABLE public.consultations
  ADD COLUMN IF NOT EXISTS recording_consent        text,
  ADD COLUMN IF NOT EXISTS recording_consent_at     timestamptz,
  ADD COLUMN IF NOT EXISTS recording_consent_by     uuid REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS recording_consent_device text,
  ADD COLUMN IF NOT EXISTS recording_consent_script text,
  ADD COLUMN IF NOT EXISTS transcript_segments      jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS note_template            text NOT NULL DEFAULT 'dental-v1',
  ADD COLUMN IF NOT EXISTS ai_drafted_at            timestamptz,
  ADD COLUMN IF NOT EXISTS ai_provider              text,
  ADD COLUMN IF NOT EXISTS ai_model                 text,
  ADD COLUMN IF NOT EXISTS ai_inputs                text[],
  ADD COLUMN IF NOT EXISTS ai_draft                 jsonb,
  ADD COLUMN IF NOT EXISTS note_sources             jsonb,
  ADD COLUMN IF NOT EXISTS signed_at                timestamptz,
  ADD COLUMN IF NOT EXISTS signed_by                uuid REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS signed_by_name           text,
  ADD COLUMN IF NOT EXISTS edited_sections          text[],
  ADD COLUMN IF NOT EXISTS audio_deleted_at         timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'consultations_recording_consent_check') THEN
    ALTER TABLE public.consultations ADD CONSTRAINT consultations_recording_consent_check
      CHECK (recording_consent IS NULL OR recording_consent IN ('agreed', 'declined'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'consultations_recording_consent_device_check') THEN
    ALTER TABLE public.consultations ADD CONSTRAINT consultations_recording_consent_device_check
      CHECK (recording_consent_device IS NULL OR recording_consent_device IN ('computer', 'phone'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'consultations_recording_consent_at_check') THEN
    ALTER TABLE public.consultations ADD CONSTRAINT consultations_recording_consent_at_check
      CHECK ((recording_consent IS NULL) = (recording_consent_at IS NULL));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'consultations_note_template_check') THEN
    ALTER TABLE public.consultations ADD CONSTRAINT consultations_note_template_check CHECK (note_template ~ '^[a-z0-9-]{1,40}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'consultations_transcript_segments_check') THEN
    ALTER TABLE public.consultations ADD CONSTRAINT consultations_transcript_segments_check CHECK (jsonb_typeof(transcript_segments) = 'array');
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_consultations_retention ON public.consultations (signed_at)
  WHERE signed_at IS NOT NULL AND audio_paths <> '{}';

-- 2. note templates: section keys and the SQL twin of src/utils/consultationNote.js (strict "## " headings) ----------------------
-- Only dental-v1 (today's six sections) exists in this part. An unknown template returns NULL everywhere, never a guess.
CREATE OR REPLACE FUNCTION public._consult_template_sections(p_template text) RETURNS TABLE (key text, heading text, ord int)
    LANGUAGE sql IMMUTABLE SET search_path = public
    AS $$
  SELECT v.key, v.heading, v.ord FROM (VALUES
    ('dental-v1', 'chief_complaint', 'Chief complaint', 1),
    ('dental-v1', 'history',         'History',         2),
    ('dental-v1', 'findings',        'Findings',        3),
    ('dental-v1', 'assessment',      'Assessment',      4),
    ('dental-v1', 'plan',            'Plan',            5),
    ('dental-v1', 'follow_up',       'Follow-up',       6)
  ) v(template, key, heading, ord) WHERE v.template = p_template ORDER BY v.ord;
$$;

-- final_summary markdown -> {key: text}, exactly as markdownToNote() reads a note written by noteToMarkdown() (strict mode: every heading
-- line is one of the template's "## " headings). Text before the first heading goes to findings, as in JS. A legacy free-form summary
-- (any other heading) or an unknown template returns NULL: edited_sections is then NULL rather than a guess.
CREATE OR REPLACE FUNCTION public._consult_note_sections(p_md text, p_template text) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE SET search_path = public
    AS $$
DECLARE
  v_heads text[]; v_keys text[]; v_line text; v_cur text; v_m text[]; v_idx int;
  v_acc jsonb := '{}'::jsonb; v_loose text := NULL; v_out jsonb := '{}'::jsonb; v_strict_re text; k text; v_txt text;
BEGIN
  SELECT array_agg(heading ORDER BY ord), array_agg(key ORDER BY ord) INTO v_heads, v_keys FROM public._consult_template_sections(p_template);
  IF v_heads IS NULL THEN RETURN NULL; END IF;
  v_strict_re := '^##\s+(' || array_to_string(ARRAY(SELECT regexp_replace(h, '([.^$*+?()\[\]{}|\\-])', '\\\1', 'g') FROM unnest(v_heads) h), '|') || ')\s*$';

  FOREACH v_line IN ARRAY string_to_array(coalesce(p_md, ''), E'\n') LOOP
    IF v_line ~ '^\s*#{1,6}\s+\S' AND v_line !~ v_strict_re THEN
      RETURN NULL;                                   -- another heading: an older free-form summary
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM unnest(string_to_array(coalesce(p_md, ''), E'\n')) l WHERE l ~ v_strict_re) THEN
    RETURN NULL;                                     -- no heading at all: also the legacy path in JS
  END IF;

  FOREACH v_line IN ARRAY string_to_array(coalesce(p_md, ''), E'\n') LOOP
    v_m := regexp_match(v_line, v_strict_re);
    IF v_m IS NOT NULL THEN
      v_idx := array_position(v_heads, v_m[1]);
      v_cur := v_keys[v_idx];
      CONTINUE;
    END IF;
    IF v_cur IS NULL THEN
      v_loose := CASE WHEN v_loose IS NULL THEN v_line ELSE v_loose || E'\n' || v_line END;
    ELSE
      v_acc := jsonb_set(v_acc, ARRAY[v_cur], to_jsonb(coalesce(v_acc ->> v_cur, '') || v_line || E'\n'));
    END IF;
  END LOOP;

  FOREACH k IN ARRAY v_keys LOOP
    -- unescape "\#" at the start of a body line, then trim (JS String.prototype.trim on the joined text)
    v_txt := regexp_replace(coalesce(v_acc ->> k, ''), '(^|\n)(\s*)\\(#{1,6}(\s|$))', '\1\2\3', 'g');
    v_out := v_out || jsonb_build_object(k, btrim(v_txt, E' \t\n\r\f\v'));
  END LOOP;
  v_loose := btrim(coalesce(v_loose, ''), E' \t\n\r\f\v');
  IF v_loose <> '' AND v_out ? 'findings' THEN
    v_out := jsonb_set(v_out, '{findings}', to_jsonb(CASE WHEN v_out ->> 'findings' = '' THEN v_loose ELSE (v_out ->> 'findings') || E'\n' || v_loose END));
  END IF;
  RETURN v_out;
END $$;

-- keys whose signed text differs from the AI draft (both trimmed). NULL without an AI draft ("Written by") or when the note can't be split.
CREATE OR REPLACE FUNCTION public._consult_edited_sections(p_md text, p_ai_draft jsonb, p_template text) RETURNS text[]
    LANGUAGE plpgsql IMMUTABLE SET search_path = public
    AS $$
DECLARE v_note jsonb; v_out text[] := '{}'; s record;
BEGIN
  IF p_ai_draft IS NULL OR jsonb_typeof(p_ai_draft) <> 'object' THEN RETURN NULL; END IF;
  v_note := public._consult_note_sections(p_md, p_template);
  IF v_note IS NULL THEN RETURN NULL; END IF;
  FOR s IN SELECT key FROM public._consult_template_sections(p_template) LOOP
    IF btrim(coalesce(v_note ->> s.key, ''), E' \t\n\r\f\v') IS DISTINCT FROM btrim(coalesce(p_ai_draft ->> s.key, ''), E' \t\n\r\f\v') THEN
      v_out := v_out || s.key;
    END IF;
  END LOOP;
  RETURN v_out;
END $$;

-- 3. the guard trigger -------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.consultation_lock_signed() RETURNS trigger
    LANGUAGE plpgsql SET search_path = public      -- NOT security definer (see the header)
    AS $$
DECLARE
  v_client boolean := current_user IN ('authenticated', 'anon');
  v_fn_only text[] := ARRAY['recording_consent', 'recording_consent_at', 'recording_consent_by', 'recording_consent_device', 'recording_consent_script',
                            'transcript_segments', 'ai_drafted_at', 'ai_provider', 'ai_model', 'ai_inputs', 'ai_draft', 'note_sources',
                            'signed_at', 'signed_by', 'signed_by_name', 'edited_sections', 'audio_deleted_at'];
  v_free text[] := ARRAY['additional_notes', 'attended_by_names', 'updated_at'];
  v_new jsonb := to_jsonb(NEW); v_old jsonb; k text;
BEGIN
  -- Rule A
  IF v_client THEN
    IF TG_OP = 'INSERT' THEN
      FOREACH k IN ARRAY v_fn_only LOOP
        IF k = 'transcript_segments' THEN
          IF NEW.transcript_segments IS DISTINCT FROM '[]'::jsonb THEN
            RAISE EXCEPTION 'FUNCTION_ONLY_COLUMN: % is written by the server only', k USING ERRCODE = '42501';
          END IF;
        ELSIF v_new -> k IS DISTINCT FROM 'null'::jsonb THEN
          RAISE EXCEPTION 'FUNCTION_ONLY_COLUMN: % is written by the server only', k USING ERRCODE = '42501';
        END IF;
      END LOOP;
    ELSE
      v_old := to_jsonb(OLD);
      FOREACH k IN ARRAY v_fn_only LOOP
        IF v_new -> k IS DISTINCT FROM v_old -> k THEN
          RAISE EXCEPTION 'FUNCTION_ONLY_COLUMN: % is written by the server only', k USING ERRCODE = '42501';
        END IF;
      END LOOP;
    END IF;
  END IF;

  -- Rule B
  IF TG_OP = 'UPDATE' AND OLD.signed_at IS NOT NULL THEN
    v_old := coalesce(v_old, to_jsonb(OLD));
    IF NEW.signed_at IS NULL AND current_user NOT IN ('authenticated', 'anon', 'service_role') THEN
      RETURN NEW;                                    -- consultation_unsign (it enforces the signer and the 15-minute window)
    END IF;
    IF current_user = 'service_role'
       AND NEW.audio_paths <@ OLD.audio_paths
       AND (v_new - v_free - 'audio_paths' - 'audio_deleted_at') = (v_old - v_free - 'audio_paths' - 'audio_deleted_at') THEN
      RETURN NEW;                                    -- retention: audio fields only, and only removing paths
    END IF;
    IF (v_new - v_free) IS DISTINCT FROM (v_old - v_free) THEN
      RAISE EXCEPTION 'SIGNED_LOCKED: this consultation note is signed and can no longer be changed' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.consultation_lock_signed() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS consultations_lock_signed ON public.consultations;
CREATE TRIGGER consultations_lock_signed BEFORE INSERT OR UPDATE ON public.consultations
  FOR EACH ROW EXECUTE FUNCTION public.consultation_lock_signed();

-- 4. person functions --------------------------------------------------------------------------------------------------------------
-- The gate: NULL = allowed, otherwise an error code. Same scope as the 006 read policy (can_access_consultation_booking) and the 011
-- practitioner policy (is_my_booking). Out-of-scope rows answer NOT_FOUND, so ids in other branches or orgs can't be probed.
CREATE OR REPLACE FUNCTION public._consult_gate(p_ctx jsonb, p_org uuid, p_booking uuid) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
    AS $$
BEGIN
  IF coalesce((p_ctx ->> 'service')::boolean, false) THEN RETURN 'FORBIDDEN'; END IF;   -- consent and signature are a person's act
  IF p_org IS NULL OR p_org IS DISTINCT FROM public.get_user_org_id() OR NOT public.can_access_consultation_booking(p_booking) THEN
    RETURN 'NOT_FOUND';
  END IF;
  IF coalesce(p_ctx ->> 'role', '') NOT IN ('practitioner', 'manager', 'admin') THEN RETURN 'FORBIDDEN'; END IF;
  IF p_ctx ->> 'role' = 'practitioner' AND NOT public.is_my_booking(p_booking) THEN RETURN 'NOT_FOUND'; END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._consult_gate(jsonb, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._consult_gate_message(p_code text) RETURNS text
    LANGUAGE sql IMMUTABLE SET search_path = public
    AS $$
  SELECT CASE p_code
    WHEN 'NOT_FOUND' THEN 'Consultation not found.'
    WHEN 'FORBIDDEN' THEN 'Your role cannot do this on a consultation.'
    ELSE p_code END;
$$;

-- 4.1 recording consent: recorded once per consultation. The same answer again is ok (two devices ticking at once); a different one is refused.
CREATE OR REPLACE FUNCTION public.consultation_record_consent(p_consultation uuid, p_answer text, p_device text, p_script text)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; c public.consultations; v_inputs jsonb; v_code text; a constant text := 'consultation.record_consent';
  v_scripts constant text[] := ARRAY['dental-en-ne-v1'];   -- allow-list: the words live in src/utils/consentScripts.js
BEGIN
  ctx := public._act_resolve(NULL);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('consultation_id', p_consultation, 'answer', p_answer, 'device', p_device, 'script', p_script);

  SELECT * INTO c FROM public.consultations WHERE id = p_consultation FOR UPDATE;
  v_code := public._consult_gate(ctx, c.org_id, c.booking_id);
  IF v_code IS NOT NULL THEN
    RETURN public._act_finish(ctx, a, CASE WHEN v_code = 'NOT_FOUND' THEN (ctx ->> 'org_id')::uuid ELSE c.org_id END, CASE WHEN v_code = 'NOT_FOUND' THEN NULL ELSE c.branch_id END,
                              v_inputs, false, NULL, v_code, public._consult_gate_message(v_code), p_consultation, NULL, 'consultations');
  END IF;
  IF p_answer IS NULL OR p_answer NOT IN ('agreed', 'declined') THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'INVALID_ANSWER', 'The answer must be agreed or declined.', p_consultation, NULL, 'consultations');
  END IF;
  IF p_device IS NULL OR p_device NOT IN ('computer', 'phone') THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'INVALID_DEVICE', 'The device must be computer or phone.', p_consultation, NULL, 'consultations');
  END IF;
  IF p_script IS NULL OR NOT (p_script = ANY (v_scripts)) THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'UNKNOWN_SCRIPT', 'Unknown consent wording.', p_consultation, NULL, 'consultations');
  END IF;
  IF c.signed_at IS NOT NULL THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'SIGNED_LOCKED', 'This consultation note is signed.', p_consultation, NULL, 'consultations');
  END IF;
  IF c.recording_consent IS NOT NULL THEN
    IF c.recording_consent = p_answer THEN
      RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, true,
        jsonb_build_object('consultation_id', c.id, 'answer', c.recording_consent, 'at', c.recording_consent_at, 'already_recorded', true), NULL, NULL, p_consultation, NULL, 'consultations');
    END IF;
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'CONSENT_ALREADY_RECORDED',
                              'Consent for this consultation was already recorded with a different answer.', p_consultation, NULL, 'consultations');
  END IF;

  UPDATE public.consultations
     SET recording_consent = p_answer, recording_consent_at = now(), recording_consent_by = (ctx ->> 'user_id')::uuid,
         recording_consent_device = p_device, recording_consent_script = p_script
   WHERE id = c.id;
  RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, true,
    jsonb_build_object('consultation_id', c.id, 'answer', p_answer, 'at', now(), 'already_recorded', false), NULL, NULL, p_consultation, NULL, 'consultations');
END $$;

-- 4.2 sign. p_expected_drafted_at = the ai_drafted_at the client last saw: a late AI draft stored between the client's save and this call
-- would otherwise make edited_sections compare against a draft the doctor never saw.
CREATE OR REPLACE FUNCTION public.consultation_sign(p_consultation uuid, p_expected_drafted_at timestamptz DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; c public.consultations; v_inputs jsonb; v_code text; v_name text; v_edited text[]; a constant text := 'consultation.sign';
BEGIN
  ctx := public._act_resolve(NULL);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('consultation_id', p_consultation, 'expected_drafted_at', p_expected_drafted_at);

  SELECT * INTO c FROM public.consultations WHERE id = p_consultation FOR UPDATE;
  v_code := public._consult_gate(ctx, c.org_id, c.booking_id);
  IF v_code IS NOT NULL THEN
    RETURN public._act_finish(ctx, a, CASE WHEN v_code = 'NOT_FOUND' THEN (ctx ->> 'org_id')::uuid ELSE c.org_id END, CASE WHEN v_code = 'NOT_FOUND' THEN NULL ELSE c.branch_id END,
                              v_inputs, false, NULL, v_code, public._consult_gate_message(v_code), p_consultation, NULL, 'consultations');
  END IF;
  IF c.signed_at IS NOT NULL THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'ALREADY_SIGNED', 'This consultation note is already signed.', p_consultation, NULL, 'consultations');
  END IF;
  IF btrim(coalesce(c.final_summary, '') || coalesce(c.preliminary_summary, '') || coalesce(c.doctor_notes, '')) = '' THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'NOTE_EMPTY', 'There is no note to sign.', p_consultation, NULL, 'consultations');
  END IF;
  IF c.ai_drafted_at IS DISTINCT FROM p_expected_drafted_at THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, jsonb_build_object('ai_drafted_at', c.ai_drafted_at), 'AI_DRAFT_CHANGED',
                              'A newer AI draft arrived. Review the note again before signing.', p_consultation, NULL, 'consultations');
  END IF;

  SELECT full_name INTO v_name FROM public.users WHERE id = (ctx ->> 'user_id')::uuid;
  v_edited := public._consult_edited_sections(c.final_summary, c.ai_draft, c.note_template);
  UPDATE public.consultations
     SET status = 'completed', signed_at = now(), signed_by = (ctx ->> 'user_id')::uuid, signed_by_name = v_name, edited_sections = v_edited
   WHERE id = c.id;
  RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, true,
    jsonb_build_object('consultation_id', c.id, 'signed_at', now(), 'signed_by_name', v_name, 'edited_sections', to_jsonb(v_edited)),
    NULL, NULL, p_consultation, NULL, 'consultations');
END $$;

-- 4.3 unsign: the signer, within 15 minutes (the board's "Undo"). Later corrections need an addendum feature (not in this ticket).
CREATE OR REPLACE FUNCTION public.consultation_unsign(p_consultation uuid)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; c public.consultations; v_inputs jsonb; v_code text; a constant text := 'consultation.unsign';
BEGIN
  ctx := public._act_resolve(NULL);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('consultation_id', p_consultation);

  SELECT * INTO c FROM public.consultations WHERE id = p_consultation FOR UPDATE;
  v_code := public._consult_gate(ctx, c.org_id, c.booking_id);
  IF v_code IS NOT NULL THEN
    RETURN public._act_finish(ctx, a, CASE WHEN v_code = 'NOT_FOUND' THEN (ctx ->> 'org_id')::uuid ELSE c.org_id END, CASE WHEN v_code = 'NOT_FOUND' THEN NULL ELSE c.branch_id END,
                              v_inputs, false, NULL, v_code, public._consult_gate_message(v_code), p_consultation, NULL, 'consultations');
  END IF;
  IF c.signed_at IS NULL THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'NOT_SIGNED', 'This consultation note is not signed.', p_consultation, NULL, 'consultations');
  END IF;
  IF c.signed_by IS DISTINCT FROM (ctx ->> 'user_id')::uuid THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, jsonb_build_object('reason', 'not the signer'), 'UNSIGN_NOT_ALLOWED',
                              'Only the person who signed can undo the signature.', p_consultation, NULL, 'consultations');
  END IF;
  IF now() - c.signed_at > interval '15 minutes' THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, jsonb_build_object('reason', 'window passed'), 'UNSIGN_NOT_ALLOWED',
                              'The 15 minutes to undo a signature have passed.', p_consultation, NULL, 'consultations');
  END IF;

  UPDATE public.consultations SET signed_at = NULL, signed_by = NULL, signed_by_name = NULL, edited_sections = NULL, status = 'draft' WHERE id = c.id;
  RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, true, jsonb_build_object('consultation_id', c.id, 'unsigned', true),
                            NULL, NULL, p_consultation, NULL, 'consultations');
END $$;

REVOKE ALL ON FUNCTION public.consultation_record_consent(uuid, text, text, text), public.consultation_sign(uuid, timestamptz),
                       public.consultation_unsign(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.consultation_record_consent(uuid, text, text, text), public.consultation_sign(uuid, timestamptz),
                          public.consultation_unsign(uuid) TO authenticated;

-- 5. service-role writers (SECURITY INVOKER; EXECUTE for service_role only) ---------------------------------------------------------
-- p_user: the signed-in user the edge function acts for. The edge function has already read the row through that user's own client (RLS
-- proves visibility); here the user must also be active, in the row's org, and of an allowed role.
CREATE OR REPLACE FUNCTION public._consult_user_ok(p_user uuid, p_org uuid) RETURNS boolean
    LANGUAGE sql STABLE SET search_path = public
    AS $$
  SELECT EXISTS (SELECT 1 FROM public.users u WHERE u.id = p_user AND u.org_id = p_org AND u.is_active IS NOT FALSE
                   AND u.role::text IN ('practitioner', 'manager', 'admin'));
$$;

CREATE OR REPLACE FUNCTION public.consultation_store_segments(p_consultation uuid, p_user uuid, p_audio_path text, p_segments jsonb)
    RETURNS jsonb
    LANGUAGE plpgsql SET search_path = public
    AS $$
DECLARE c public.consultations; v_new jsonb;
BEGIN
  SELECT * INTO c FROM public.consultations WHERE id = p_consultation FOR UPDATE;
  IF c.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'code', 'NOT_FOUND'); END IF;
  IF NOT public._consult_user_ok(p_user, c.org_id) THEN RETURN jsonb_build_object('ok', false, 'code', 'FORBIDDEN'); END IF;
  IF c.signed_at IS NOT NULL THEN RETURN jsonb_build_object('ok', false, 'code', 'SIGNED_LOCKED'); END IF;
  -- storage path is "<org_id>/<booking_id>/<file>" (consultation_object_booking): the recording must belong to this consultation's booking
  IF p_audio_path IS NULL OR split_part(p_audio_path, '/', 1) <> c.org_id::text OR split_part(p_audio_path, '/', 2) <> c.booking_id::text THEN
    RETURN jsonb_build_object('ok', false, 'code', 'WRONG_RECORDING');
  END IF;
  IF p_segments IS NULL OR jsonb_typeof(p_segments) <> 'array' OR jsonb_array_length(p_segments) > 5000 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'INVALID_SEGMENTS');
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('audio_path', p_audio_path, 'start', (s ->> 'start')::numeric, 'end', (s ->> 'end')::numeric,
                                               'text', left(s ->> 'text', 4000)) ORDER BY o), '[]'::jsonb)
    INTO v_new
    FROM jsonb_array_elements(p_segments) WITH ORDINALITY AS t(s, o)
   WHERE jsonb_typeof(s) = 'object' AND jsonb_typeof(s -> 'start') = 'number' AND jsonb_typeof(s -> 'end') = 'number' AND jsonb_typeof(s -> 'text') = 'string';
  UPDATE public.consultations
     SET transcript_segments = coalesce((SELECT jsonb_agg(e) FROM jsonb_array_elements(c.transcript_segments) e WHERE e ->> 'audio_path' IS DISTINCT FROM p_audio_path), '[]'::jsonb) || v_new
   WHERE id = c.id;
  RETURN jsonb_build_object('ok', true, 'stored', jsonb_array_length(v_new));
END $$;

CREATE OR REPLACE FUNCTION public.consultation_store_draft(p_consultation uuid, p_user uuid, p_note jsonb, p_provider text, p_model text,
                                                           p_inputs text[], p_sources jsonb)
    RETURNS jsonb
    LANGUAGE plpgsql SET search_path = public
    AS $$
DECLARE c public.consultations; v_keys text[]; v_at timestamptz := now();
BEGIN
  SELECT * INTO c FROM public.consultations WHERE id = p_consultation FOR UPDATE;
  IF c.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'code', 'NOT_FOUND'); END IF;
  IF NOT public._consult_user_ok(p_user, c.org_id) THEN RETURN jsonb_build_object('ok', false, 'code', 'FORBIDDEN'); END IF;
  IF c.signed_at IS NOT NULL THEN RETURN jsonb_build_object('ok', false, 'code', 'SIGNED_LOCKED'); END IF;
  SELECT array_agg(key) INTO v_keys FROM public._consult_template_sections(c.note_template);
  IF v_keys IS NULL THEN RETURN jsonb_build_object('ok', false, 'code', 'UNKNOWN_TEMPLATE'); END IF;
  IF p_note IS NULL OR jsonb_typeof(p_note) <> 'object'
     OR EXISTS (SELECT 1 FROM jsonb_each(p_note) e WHERE NOT (e.key = ANY (v_keys)) OR jsonb_typeof(e.value) <> 'string') THEN
    RETURN jsonb_build_object('ok', false, 'code', 'INVALID_NOTE');
  END IF;
  IF p_provider IS DISTINCT FROM 'openai' OR p_model IS NULL OR p_model !~ '^[a-z0-9][a-z0-9.:-]{0,59}$' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'INVALID_PROVENANCE');
  END IF;
  IF p_inputs IS NULL OR NOT (p_inputs <@ ARRAY['recording', 'xray', 'photo']) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'INVALID_INPUTS');
  END IF;
  IF p_sources IS NOT NULL AND (jsonb_typeof(p_sources) <> 'object'
     OR EXISTS (SELECT 1 FROM jsonb_each(p_sources) e WHERE NOT (e.key = ANY (v_keys)) OR jsonb_typeof(e.value) <> 'array')) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'INVALID_SOURCES');
  END IF;
  UPDATE public.consultations
     SET ai_drafted_at = v_at, ai_provider = p_provider, ai_model = p_model, ai_inputs = p_inputs, ai_draft = p_note,
         note_sources = coalesce(p_sources, '{}'::jsonb)
   WHERE id = c.id;
  RETURN jsonb_build_object('ok', true, 'drafted_at', v_at);
END $$;

-- 6. retention: recordings of notes signed more than 30 days ago. Unsigned consultations are never returned. -----------------------
CREATE OR REPLACE FUNCTION public.consultation_retention_due(p_limit integer DEFAULT 200)
    RETURNS TABLE (id uuid, audio_paths text[])
    LANGUAGE sql STABLE SET search_path = public
    AS $$
  SELECT c.id, c.audio_paths FROM public.consultations c
   WHERE c.signed_at IS NOT NULL AND c.signed_at < now() - interval '30 days' AND c.audio_paths <> '{}'
   ORDER BY c.signed_at
   LIMIT greatest(1, least(coalesce(p_limit, 200), 1000));
$$;

-- Called after the Storage API confirmed the deletion of p_deleted_paths. Re-checks the 30 days, so it can never clear a draft's audio.
CREATE OR REPLACE FUNCTION public.consultation_mark_audio_deleted(p_consultation uuid, p_deleted_paths text[])
    RETURNS jsonb
    LANGUAGE plpgsql SET search_path = public
    AS $$
DECLARE c public.consultations; v_left text[];
BEGIN
  SELECT * INTO c FROM public.consultations WHERE id = p_consultation FOR UPDATE;
  IF c.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'code', 'NOT_FOUND'); END IF;
  IF c.signed_at IS NULL OR c.signed_at >= now() - interval '30 days' THEN RETURN jsonb_build_object('ok', false, 'code', 'NOT_DUE'); END IF;
  v_left := ARRAY(SELECT p FROM unnest(c.audio_paths) WITH ORDINALITY AS t(p, o) WHERE NOT (p = ANY (coalesce(p_deleted_paths, '{}'))) ORDER BY o);
  UPDATE public.consultations
     SET audio_paths = v_left, audio_deleted_at = CASE WHEN v_left = '{}' THEN now() ELSE audio_deleted_at END
   WHERE id = c.id;
  RETURN jsonb_build_object('ok', true, 'left', cardinality(v_left));
END $$;

REVOKE ALL ON FUNCTION public._consult_user_ok(uuid, uuid), public.consultation_store_segments(uuid, uuid, text, jsonb),
                       public.consultation_store_draft(uuid, uuid, jsonb, text, text, text[], jsonb), public.consultation_retention_due(integer),
                       public.consultation_mark_audio_deleted(uuid, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._consult_user_ok(uuid, uuid), public.consultation_store_segments(uuid, uuid, text, jsonb),
                          public.consultation_store_draft(uuid, uuid, jsonb, text, text, text[], jsonb), public.consultation_retention_due(integer),
                          public.consultation_mark_audio_deleted(uuid, text[]) TO service_role;
-- pure helpers: no client access; service_role keeps EXECUTE because the INVOKER writers above call _consult_template_sections as service_role
REVOKE ALL ON FUNCTION public._consult_template_sections(text), public._consult_note_sections(text, text),
                       public._consult_edited_sections(text, jsonb, text), public._consult_gate_message(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._consult_template_sections(text), public._consult_note_sections(text, text),
                          public._consult_edited_sections(text, jsonb, text), public._consult_gate_message(text) TO service_role;

-- 6.1 the clock: daily at 21:30 UTC (03:15 Asia/Kathmandu), kick the edge function only when something is due (agent_kick_runner pattern)
CREATE OR REPLACE FUNCTION public.consultation_kick_retention() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_cfg record;
BEGIN
  IF to_regclass('private.outreach_function_config') IS NULL THEN RETURN 0; END IF;
  EXECUTE 'SELECT function_base_url, cron_bearer_token FROM private.outreach_function_config LIMIT 1' INTO v_cfg;
  IF v_cfg.function_base_url IS NULL THEN RETURN 0; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.consultation_retention_due(1)) THEN RETURN 0; END IF;
  BEGIN
    PERFORM net.http_post(url := v_cfg.function_base_url || '/consultation-retention',
                          headers := jsonb_build_object('Authorization', 'Bearer ' || v_cfg.cron_bearer_token, 'Content-Type', 'application/json'),
                          body := '{}'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'consultation_kick_retention: could not call consultation-retention (%)', SQLSTATE;
    RETURN 0;
  END;
  RETURN 1;
END $$;
REVOKE ALL ON FUNCTION public.consultation_kick_retention() FROM PUBLIC, anon, authenticated, service_role;

DO $$
BEGIN
  IF to_regnamespace('cron') IS NULL THEN
    RAISE NOTICE 'pg_cron is not installed here: consultation-retention was NOT scheduled (enable pg_cron, then run this block again).';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'consultation-retention') THEN PERFORM cron.unschedule('consultation-retention'); END IF;
  PERFORM cron.schedule('consultation-retention', '30 21 * * *', 'SELECT public.consultation_kick_retention()');
END $$;

COMMIT;
