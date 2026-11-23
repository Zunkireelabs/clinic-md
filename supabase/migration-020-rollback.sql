-- migration-020-rollback (CMD-54 + CMD-55): undo migration-020.
--
-- ORDER: revert the CLIENT and the EDGE FUNCTIONS first (consultation-transcribe, consultation-summarize, consultation-analyze-image back to the
-- pre-020 versions; consultation-retention undeployed), THEN run this file. The new client calls functions this file drops. The pre-020 client
-- writes none of the new columns, so it runs unchanged on the rolled-back schema.
--
-- DATA LOSS: recording consent, AI provenance, signatures, transcript segments and note sources are dropped. Export them first:
--   \copy (SELECT id, recording_consent, recording_consent_at, recording_consent_by, recording_consent_device, recording_consent_script,
--                 note_template, ai_drafted_at, ai_provider, ai_model, ai_inputs, ai_draft, note_sources, signed_at, signed_by, signed_by_name,
--                 edited_sections, audio_deleted_at, transcript_segments
--          FROM public.consultations
--          WHERE recording_consent IS NOT NULL OR ai_drafted_at IS NOT NULL OR signed_at IS NOT NULL OR transcript_segments <> '[]'::jsonb)
--     TO 'consultations-020-export.csv' CSV HEADER
-- Recordings already deleted by retention are gone from Storage either way (audio_paths was emptied for them).
--
-- Touches nothing that 019 (CMD-100) adds, so it restores the 018 or the 019 schema. Run as postgres, local first.

BEGIN;

DO $$
BEGIN
  IF to_regnamespace('cron') IS NOT NULL THEN
    PERFORM cron.unschedule(jobname) FROM cron.job WHERE jobname = 'consultation-retention';
  END IF;
END $$;

DROP TRIGGER IF EXISTS consultations_lock_signed ON public.consultations;

DROP FUNCTION IF EXISTS public.consultation_kick_retention();
DROP FUNCTION IF EXISTS public.consultation_mark_audio_deleted(uuid, text[]);
DROP FUNCTION IF EXISTS public.consultation_retention_due(integer);
DROP FUNCTION IF EXISTS public.consultation_store_draft(uuid, uuid, jsonb, text, text, text[], jsonb);
DROP FUNCTION IF EXISTS public.consultation_store_segments(uuid, uuid, text, jsonb);
DROP FUNCTION IF EXISTS public._consult_user_ok(uuid, uuid);
DROP FUNCTION IF EXISTS public.consultation_unsign(uuid);
DROP FUNCTION IF EXISTS public.consultation_sign(uuid, timestamptz);
DROP FUNCTION IF EXISTS public.consultation_record_consent(uuid, text, text, text);
DROP FUNCTION IF EXISTS public._consult_gate_message(text);
DROP FUNCTION IF EXISTS public._consult_gate(jsonb, uuid, uuid);
DROP FUNCTION IF EXISTS public.consultation_lock_signed();
DROP FUNCTION IF EXISTS public._consult_edited_sections(text, jsonb, text);
DROP FUNCTION IF EXISTS public._consult_note_sections(text, text);
DROP FUNCTION IF EXISTS public._consult_template_sections(text);

DROP INDEX IF EXISTS public.idx_consultations_retention;

ALTER TABLE public.consultations
  DROP CONSTRAINT IF EXISTS consultations_recording_consent_check,
  DROP CONSTRAINT IF EXISTS consultations_recording_consent_device_check,
  DROP CONSTRAINT IF EXISTS consultations_recording_consent_at_check,
  DROP CONSTRAINT IF EXISTS consultations_note_template_check,
  DROP CONSTRAINT IF EXISTS consultations_transcript_segments_check,
  DROP COLUMN IF EXISTS recording_consent,
  DROP COLUMN IF EXISTS recording_consent_at,
  DROP COLUMN IF EXISTS recording_consent_by,
  DROP COLUMN IF EXISTS recording_consent_device,
  DROP COLUMN IF EXISTS recording_consent_script,
  DROP COLUMN IF EXISTS transcript_segments,
  DROP COLUMN IF EXISTS note_template,
  DROP COLUMN IF EXISTS ai_drafted_at,
  DROP COLUMN IF EXISTS ai_provider,
  DROP COLUMN IF EXISTS ai_model,
  DROP COLUMN IF EXISTS ai_inputs,
  DROP COLUMN IF EXISTS ai_draft,
  DROP COLUMN IF EXISTS note_sources,
  DROP COLUMN IF EXISTS signed_at,
  DROP COLUMN IF EXISTS signed_by,
  DROP COLUMN IF EXISTS signed_by_name,
  DROP COLUMN IF EXISTS edited_sections,
  DROP COLUMN IF EXISTS audio_deleted_at;

-- action_log rows written by consultation.record_consent / .sign / .unsign are KEPT (the log is append-only; they hold ids and codes only).

COMMIT;
