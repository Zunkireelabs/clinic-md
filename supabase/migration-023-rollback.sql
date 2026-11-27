-- migration-023-rollback (CMD-146): undo migration-023. Revert the CLIENT first (it calls the function this file drops), then run this.
-- The `transcript` text column is untouched, so no transcript text is lost. DATA LOSS: the per-recording split (which recording produced
-- which words) and, after CMD-143, nothing else lives only in transcript_pieces. action_log rows stay. Run as postgres, local first.
BEGIN;
DROP FUNCTION IF EXISTS public.consultation_add_transcript_piece(uuid, text, text, text);
DROP TRIGGER IF EXISTS consultations_pieces_fn_only ON public.consultations;
DROP FUNCTION IF EXISTS public.consultation_pieces_fn_only();
ALTER TABLE public.consultations DROP CONSTRAINT IF EXISTS consultations_transcript_pieces_check;
ALTER TABLE public.consultations DROP COLUMN IF EXISTS transcript_pieces;
COMMIT;
