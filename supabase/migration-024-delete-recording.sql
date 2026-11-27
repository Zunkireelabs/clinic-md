-- migration-024 (CMD-143): staff can delete ONE recording from a consultation that is not signed.
--
-- Requires 023 (transcript_pieces) and 020 (_consult_gate, the signed lock, transcript_segments). NOT applied to production. Apply to prod
-- BEFORE the code that calls consultation_delete_recording reaches main. Rollback: migration-024-rollback.sql. Changes nothing from 011-023.
--
-- consultation_delete_recording(consultation, audio_path): SECURITY DEFINER, authenticated only (never anon, 009). Same gate as 020/023:
-- practitioner (own booking), manager (branch), admin (org); front desk, admin_viewer, service role and agents are refused; another clinic
-- or a nonexistent id answers NOT_FOUND; a signed note answers SIGNED_LOCKED. The row is locked FOR UPDATE. In one UPDATE it removes
--   * the recording's piece from transcript_pieces and its rows from transcript_segments (they hold its words);
--   * the path from audio_paths;
--   * the piece's words from `transcript` ONLY when they are still there as a whole untouched block (they start the text or follow a blank
--     line, and end it or precede one; the block plus one blank-line separator is cut). If the doctor edited them, the transcript is left
--     alone and text_removed=false tells the page to say so.
-- It does NOT touch ai_draft, the note or note_sources and does not redraft: the transcript changed, so the page's staleness check offers
-- "Update the draft". Audited in action_log as consultation.delete_recording: ids and the audio path only, never audio or words.
-- The storage object is deleted by the CLIENT through the Storage API AFTER this returns ok (never SQL on storage.objects). Calling this
-- again for a path that is already gone is ok (removed=false), so a failed storage delete can simply be retried.

BEGIN;

CREATE OR REPLACE FUNCTION public.consultation_delete_recording(p_consultation uuid, p_audio_path text)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; c public.consultations; v_inputs jsonb; v_code text; a constant text := 'consultation.delete_recording';
  v_piece jsonb; v_t text; v_pos int; v_before text; v_after text; v_new text; v_text_removed boolean := false; v_was_listed boolean; v_from int; v_hit int;
BEGIN
  ctx := public._act_resolve(NULL);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('consultation_id', p_consultation, 'audio_path', p_audio_path);   -- never audio, never words

  SELECT * INTO c FROM public.consultations WHERE id = p_consultation FOR UPDATE;
  v_code := public._consult_gate(ctx, c.org_id, c.booking_id);
  IF v_code IS NOT NULL THEN
    RETURN public._act_finish(ctx, a, CASE WHEN v_code = 'NOT_FOUND' THEN (ctx ->> 'org_id')::uuid ELSE c.org_id END, CASE WHEN v_code = 'NOT_FOUND' THEN NULL ELSE c.branch_id END,
                              v_inputs, false, NULL, v_code, public._consult_gate_message(v_code), p_consultation, NULL, 'consultations');
  END IF;
  IF c.signed_at IS NOT NULL THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'SIGNED_LOCKED', 'This consultation note is signed.', p_consultation, NULL, 'consultations');
  END IF;
  IF p_audio_path IS NULL OR split_part(p_audio_path, '/', 1) <> c.org_id::text OR split_part(p_audio_path, '/', 2) <> c.booking_id::text
     OR split_part(p_audio_path, '/', 3) = '' THEN
    RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, false, NULL, 'INVALID_PATH', 'That recording does not belong to this consultation.', p_consultation, NULL, 'consultations');
  END IF;

  v_was_listed := p_audio_path = ANY (c.audio_paths);
  SELECT e INTO v_piece FROM jsonb_array_elements(c.transcript_pieces) e WHERE e ->> 'path' = p_audio_path LIMIT 1;
  v_new := c.transcript;
  IF v_piece IS NOT NULL THEN
    v_t := btrim(coalesce(v_piece ->> 'text', ''));
    -- only a WHOLE block counts as untouched: the words must start the text or follow a blank line, and end the text or precede one. Words
    -- that sit inside a sentence the doctor edited are left alone.
    v_pos := 0; v_from := 1;
    WHILE v_t <> '' AND v_from <= length(coalesce(c.transcript, '')) LOOP
      v_hit := strpos(substr(c.transcript, v_from), v_t);
      EXIT WHEN v_hit = 0;
      v_hit := v_hit + v_from - 1;
      IF (v_hit = 1 OR substr(c.transcript, v_hit - 2, 2) = E'\n\n')
         AND (v_hit + length(v_t) > length(c.transcript) OR substr(c.transcript, v_hit + length(v_t), 2) = E'\n\n') THEN v_pos := v_hit; EXIT; END IF;
      v_from := v_hit + 1;
    END LOOP;
    IF v_pos > 0 THEN
      v_before := regexp_replace(left(c.transcript, v_pos - 1), E'\n\n$', '');
      v_after := substr(c.transcript, v_pos + length(v_t));
      IF v_before = '' THEN v_after := regexp_replace(v_after, E'^\n\n', ''); END IF;
      v_new := nullif(v_before || v_after, '');
      v_text_removed := true;
    END IF;
  END IF;

  UPDATE public.consultations
     SET transcript_pieces = coalesce((SELECT jsonb_agg(e ORDER BY o) FROM jsonb_array_elements(c.transcript_pieces) WITH ORDINALITY AS t(e, o) WHERE e ->> 'path' IS DISTINCT FROM p_audio_path), '[]'::jsonb),
         transcript_segments = coalesce((SELECT jsonb_agg(e ORDER BY o) FROM jsonb_array_elements(c.transcript_segments) WITH ORDINALITY AS t(e, o) WHERE e ->> 'audio_path' IS DISTINCT FROM p_audio_path), '[]'::jsonb),
         audio_paths = array_remove(c.audio_paths, p_audio_path),
         transcript = v_new
   WHERE id = c.id AND (v_was_listed OR v_piece IS NOT NULL OR EXISTS (SELECT 1 FROM jsonb_array_elements(c.transcript_segments) e WHERE e ->> 'audio_path' = p_audio_path));
  RETURN public._act_finish(ctx, a, c.org_id, c.branch_id, v_inputs, true,
    jsonb_build_object('consultation_id', c.id, 'removed', (v_was_listed OR v_piece IS NOT NULL), 'had_piece', v_piece IS NOT NULL, 'text_removed', v_text_removed,
                       'transcript', v_new, 'audio_paths', to_jsonb(array_remove(c.audio_paths, p_audio_path)),
                       'pieces', (SELECT count(*) FROM jsonb_array_elements(c.transcript_pieces) e WHERE e ->> 'path' IS DISTINCT FROM p_audio_path)),
    NULL, NULL, p_consultation, NULL, 'consultations');
END $$;

REVOKE ALL ON FUNCTION public.consultation_delete_recording(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.consultation_delete_recording(uuid, text) TO authenticated;

INSERT INTO public.schema_migrations (version, name) VALUES ('024', 'delete-recording') ON CONFLICT DO NOTHING;

COMMIT;
