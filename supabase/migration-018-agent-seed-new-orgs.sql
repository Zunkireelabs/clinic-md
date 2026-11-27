-- migration-018: agent rows for organizations created after 017 (CMD-97). Needs 016 and 017.
-- 016 seeded the clinic-wide scribe and follow_up agent_settings rows, and 017 the five follow_up playbooks, only for organizations that existed
-- when they ran. A clinic created later had neither, so the Follow-up agent could never be switched on for it.
--
--   * _agent_seed_org(org): inserts exactly what 016 and 017 seed for an existing organization, ON CONFLICT DO NOTHING:
--       agent_settings  scribe     clinic-wide, ENABLED, ceiling 1   (as 016, since CMD-109; see the note below)
--                       follow_up  clinic-wide, DISABLED, ceiling 1  (as 016)
--       playbooks       booking_confirmation, day_before_reminder, reply_to_confirm, not_confirmed_by_6pm, aftercare_check_in:
--                       clinic-wide, DISABLED, level 1, no template, the same names, events and settings as 017.
--     016's and 017's own seeds are left as they are; tenant-isolation.sql 3g compares a new org's rows with an untouched 016 / 017-seeded
--     org's rows, value by value, so the copies cannot drift apart unnoticed.
--   * trg_agent_seed_new_org: AFTER INSERT ON organizations. A failing seed never fails the organization insert: the error is caught, the
--     seed's rows are rolled back together (all seven or none; the exception block is a subtransaction) and a WARNING is raised
--     ('agent seed failed for organization <id> (<SQLSTATE>)'), which lands in the Postgres log and is sent to the client. Same pattern as
--     017's enqueue triggers. An organization left without rows can be fixed later with: SELECT public._agent_seed_org('<org id>');
--   * The scribe row is seeded ENABLED (lead QC, 2026-11-23), as 016 does since CMD-109. The AI switch alone keeps the Scribe off:
--     _ai_block_reason returns AI_OFF while organizations.ai_consultation_enabled is false, exactly as when there is no row (_agent_org_enabled
--     defaults the Scribe to on). Seeding it = the AI switch (016's rule before CMD-109) gave a clinic with AI off (every new clinic: 010's
--     default) a scribe row that is OFF; act_ai_set_enabled(true) only updates organizations, so the Scribe stayed blocked with AGENT_OFF
--     after the owner switched AI on.
--   * Backfill: every organization with no clinic-wide follow_up playbook gets the rows now (idempotent: ON CONFLICT DO NOTHING).
--   * Both functions are SECURITY DEFINER with search_path set; nobody but the owner may EXECUTE them (not anon, authenticated or service_role).
-- No other path seeds these rows: no RPC or edge function inserts organizations (organizations has no INSERT policy), and the only other
-- writers of agent_settings are the act_* actions, which upsert.
-- Apply by hand with psql (CMD-85). Local only until the owner applies it to prod (needs 011-017 first). Rollback: migration-018-rollback.sql

BEGIN;

CREATE FUNCTION public._agent_seed_org(p_org uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE n integer; m integer;
BEGIN
  INSERT INTO public.agent_settings (org_id, branch_id, agent, enabled, max_level)
  SELECT o.id, NULL, v.agent, v.agent = 'scribe', 1   -- scribe on (the AI switch gates it), follow_up off
    FROM public.organizations o CROSS JOIN (VALUES ('scribe'), ('follow_up')) v(agent)
   WHERE o.id = p_org
  ON CONFLICT ON CONSTRAINT agent_settings_key DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;

  INSERT INTO public.playbooks (org_id, branch_id, agent, key, name, event, level, enabled, settings)
  SELECT o.id, NULL, 'follow_up', v.key, v.name, v.event, 1, false, v.settings::jsonb
    FROM public.organizations o
   CROSS JOIN (VALUES
     ('booking_confirmation', 'Booking confirmation',         'booking_created', '{}'),
     ('day_before_reminder',  'Day-before reminder',          'day_before',      '{"send_time": "09:00"}'),
     ('reply_to_confirm',     'Reply to confirm',             'patient_reply',   '{}'),
     ('not_confirmed_by_6pm', 'Not confirmed by 6:00 pm',     'no_reply',        '{"send_time": "18:00"}'),
     ('aftercare_check_in',   'Aftercare check-in',           'visit_completed', '{"send_time": "09:00", "treatments": []}')
   ) v(key, name, event, settings)
   WHERE o.id = p_org
  ON CONFLICT ON CONSTRAINT playbooks_key DO NOTHING;
  GET DIAGNOSTICS m = ROW_COUNT;
  RETURN n + m;
END $$;
REVOKE ALL ON FUNCTION public._agent_seed_org(uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.trg_agent_seed_new_org() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
BEGIN
  BEGIN
    PERFORM public._agent_seed_org(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'agent seed failed for organization % (%)', NEW.id, SQLSTATE;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.trg_agent_seed_new_org() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER trg_agent_seed_new_org AFTER INSERT ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.trg_agent_seed_new_org();

-- backfill: organizations created after 017 (none had a clinic-wide follow_up playbook)
SELECT public._agent_seed_org(o.id) FROM public.organizations o
 WHERE NOT EXISTS (SELECT 1 FROM public.playbooks p WHERE p.org_id = o.id AND p.branch_id IS NULL AND p.agent = 'follow_up');

COMMIT;
