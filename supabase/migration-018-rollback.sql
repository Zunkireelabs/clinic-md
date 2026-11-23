-- migration-018-rollback (CMD-97): undo migration-018. Drops the trigger on organizations and its two functions. 017 and 016 are untouched.
-- Rows the trigger or the backfill already inserted are KEPT: they are the same rows 016 and 017 seed for every other organization, a clinic
-- may have configured them since, and migration-017-rollback.sql removes the playbooks anyway. Run as postgres, local first.

BEGIN;

DROP TRIGGER IF EXISTS trg_agent_seed_new_org ON public.organizations;
DROP FUNCTION IF EXISTS public.trg_agent_seed_new_org();
DROP FUNCTION IF EXISTS public._agent_seed_org(uuid);

COMMIT;
