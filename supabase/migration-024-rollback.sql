-- migration-024-rollback (CMD-143): undo migration-024. Revert the CLIENT first (it calls this function). Nothing else changes: recordings
-- already deleted stay deleted (audio, pieces, segments are gone; that cannot be undone). action_log rows stay. Run as postgres, local first.
BEGIN;
DROP FUNCTION IF EXISTS public.consultation_delete_recording(uuid, text);
DELETE FROM public.schema_migrations WHERE version = '024';
COMMIT;
