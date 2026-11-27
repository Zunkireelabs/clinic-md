-- migration-023 (CMD-146): the transcript is kept as one piece per recording, so "this recording is already in the transcript" is a fact
-- in the database, not something one browser remembers in localStorage.
--
-- Requires 020 (_consult_gate, consultations_lock_signed, signed_at) and 012/016 (_act_resolve, _act_finish, action_log).
-- NOT applied to production. Apply to prod BEFORE the code that calls consultation_add_transcript_piece reaches main (main deploys at once).
-- Rollback: migration-023-rollback.sql (revert the client first, then the SQL). Changes nothing from 011-022.
--
-- WHAT IT ADDS
--   * consultations.transcript_pieces jsonb [{ path, text, language, at }], one element per recording. Written ONLY by the function below
--     (a trigger refuses direct writes from 'authenticated'/'anon', same idea as 020 Rule A).
--   * consultation_add_transcript_piece(consultation, audio_path, text, language): SECURITY DEFINER, authenticated only (never anon, 009).
--     Same gate as 020: practitioner (own booking), manager (branch), admin (org); front desk, admin_viewer, service role and agents are
--     refused; other clinics see NOT_FOUND; a signed note answers SIGNED_LOCKED. The row is locked FOR UPDATE, so a phone and a desk adding
--     at the same moment are serialised: the second sees the first's piece and adds nothing. A path already present is a no-op
--     (ok, added=false). Audited in action_log as consultation.add_transcript_piece: ids and the audio path only, never the text.
--   * the `transcript` text column is KEPT and is what the drafter and every reader use. The function APPENDS the piece's text to the
--     CURRENT text (joined by a blank line), it does not rebuild the text from the pieces: the doctor may have edited the transcript by hand
--     and a rebuild would silently throw those edits away.
--   * backfill: every existing non-blank transcript becomes one piece with path NULL (we do not know which recording made which words).

BEGIN;

ALTER TABLE public.consultations ADD COLUMN IF NOT EXISTS transcript_pieces jsonb NOT NULL DEFAULT '[]'::jsonb;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'consultations_transcript_pieces_check') THEN
    ALTER TABLE public.consultations ADD CONSTRAINT consultations_transcript_pieces_check CHECK (jsonb_typeof(transcript_pieces) = 'array');
  END IF;
END $$;

-- backfill. The signed-lock trigger would refuse the UPDATE on signed rows (even for the owner) and updated_at must not move for every
-- row, so the user triggers are off for this one statement only (inside this transaction).
ALTER TABLE public.consultations DISABLE TRIGGER USER;
UPDATE public.consultations
   SET transcript_pieces = jsonb_build_array(jsonb_build_object('path', NULL, 'text', transcript, 'language', detected_language, 'at', coalesce(updated_at, now())))
 WHERE btrim(coalesce(transcript, '')) <> '' AND transcript_pieces = '[]'::jsonb;
ALTER TABLE public.consultations ENABLE TRIGGER USER;

-- direct client writes to the pieces are refused (not security definer: it reads current_user, like consultations_lock_signed)
CREATE OR REPLACE FUNCTION public.consultation_pieces_fn_only() RETURNS trigger
    LANGUAGE plpgsql SET search_path = public
    AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon')
     AND (CASE WHEN TG_OP = 'INSERT' THEN NEW.transcript_pieces <> '[]'::jsonb ELSE NEW.transcript_pieces IS DISTINCT FROM OLD.transcript_pieces END) THEN
    RAISE EXCEPTION 'FUNCTION_ONLY_COLUMN: transcript_pieces is written by the server only' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.consultation_pieces_fn_only() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS consultations_pieces_fn_only ON public.consultations;
CREATE TRIGGER consultations_pieces_fn_only BEFORE INSERT OR UPDATE ON public.consultations
  FOR EACH ROW EXECUTE FUNCTION public.consultation_pieces_fn_only();

CREATE OR REPLACE FUNCTION public.consultation_add_transcript_piece(p_consultation uuid, p_audio_path text, p_text text, p_language text DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; c public.consultations; v_inputs jsonb; v_code text; v_text text; v_new text; v_lang text; a constant text := 'consultation.add_transcript_piece';
BEGIN
  ctx := public._act_resolve(NULL);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('consultation_id', p_consultation, 'audio_path', p_audio_path);   -- never the text

  SELECT * INTO c FROM public.consultations WHERE id = p_consultation FOR UPDATE;
  v_code := public._consult_gate(ctx, c.org_id, c.booking_id);
  IF v_code IS NOT NULL THEN
    RETURN public._act_finish(ctx, a, CASE WHEN v_code = 'NOT_FOUND' THEN (ctx ->> 'org_id')::uuid ELSE c.org_id END, CASE WHEN v_code = 'NOT_FOUND' THEN NULL ELSE c.branch_id END,
                              v_inputs, false, NULL, v_code, public._consult_gate_message(v_code), p_consultation, NULL, 'consultations');
  END IF;
  IF c.signed_at IS NOT NULL THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'SIGNED_LOCKED', 'This consultation note is signed.', p_consultation, NULL, 'consultations');
  END IF;
  -- the recording must belong to THIS consultation's booking: "<org>/<booking>/<file>"
  IF p_audio_path IS NULL OR split_part(p_audio_path, '/', 1) <> c.org_id::text OR split_part(p_audio_path, '/', 2) <> c.booking_id::text
     OR split_part(p_audio_path, '/', 3) = '' THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'INVALID_PATH', 'That recording does not belong to this consultation.', p_consultation, NULL, 'consultations');
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(c.transcript_pieces) e WHERE e ->> 'path' = p_audio_path) THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, true,
      jsonb_build_object('consultation_id', c.id, 'added', false, 'transcript', c.transcript, 'language', c.detected_language,
                         'pieces', jsonb_array_length(c.transcript_pieces)), NULL, NULL, p_consultation, NULL, 'consultations');
  END IF;

  v_text := btrim(coalesce(p_text, ''));
  v_new := CASE WHEN v_text = '' THEN c.transcript
                WHEN btrim(coalesce(c.transcript, '')) = '' THEN v_text
                ELSE c.transcript || E'\n\n' || v_text END;
  v_lang := coalesce(nullif(btrim(p_language), ''), c.detected_language);
  UPDATE public.consultations
     SET transcript_pieces = transcript_pieces || jsonb_build_array(jsonb_build_object('path', p_audio_path, 'text', v_text, 'language', p_language, 'at', now())),
         transcript = v_new, detected_language = v_lang
   WHERE id = c.id;
  RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, true,
    jsonb_build_object('consultation_id', c.id, 'added', true, 'transcript', v_new, 'language', v_lang, 'pieces', jsonb_array_length(c.transcript_pieces) + 1),
    NULL, NULL, p_consultation, NULL, 'consultations');
END $$;

REVOKE ALL ON FUNCTION public.consultation_add_transcript_piece(uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.consultation_add_transcript_piece(uuid, text, text, text) TO authenticated;

COMMIT;
