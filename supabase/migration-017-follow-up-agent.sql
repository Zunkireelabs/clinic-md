-- migration-017: the Follow-up agent's data (CMD-95). Brief: docs/briefs/CMD-95-follow-up-agent.md. Needs 010-016.
-- The job queue and its scanners, reply rules, five seeded playbooks (DISABLED, no template text), the claim / finish functions the
-- agent-run edge function uses, the scorecard and AI usage read functions. The agent itself is the edge function agent-run: it calls only
-- act_* functions and the service functions below, never a table.
--
-- QC fixes (lead, 2026-11-22): per-step idempotency (agent_step_result); symptom words match word STARTS (pain -> painful) in English, romanised and
-- Devanagari Nepali; a reply acts on a booking only through the agent's own recent message about it; ai_usage_summary is for admin, admin_viewer
-- and manager only (a manager sees their branches); the rollback removes the five playbooks this file seeds.
-- Design note approved by the lead 2026-11-22:
--   * playbooks.event also allows 'patient_reply'; the 6 pm "not confirmed" scan reuses 'no_reply'.
--   * One job per (playbook, booking, event); a patient_reply job is also keyed by the inbound message, so a second reply gets its own job.
--   * The reply job is enqueued by a trigger on inbound messages: migration 013 is not touched.
--   * No outcomes table: the scorecard is derived from bookings, action_log and agent_jobs.
--   * act_work_propose gets a trailing p_uses_ai (default true): template-only drafts pass false and only AGENT_OFF applies.
--   * act_work_approve gets ORDER_REQUIRED: an item whose sources hold {"kind":"work_item","id":..,"requires":true} cannot be approved
--     until that item is approved (or edited).
--   * Replaces act_work_propose and act_work_approve with the CURRENT (016) bodies plus those changes. migration-017-rollback.sql restores the 016 bodies.
-- Apply by hand with psql (CMD-85). Local only until the owner applies it to prod (needs 011-016 first). Rollback: migration-017-rollback.sql

BEGIN;

-- 1. playbooks: a patient's reply is an event too ---------------------------------------------------------------------------
ALTER TABLE public.playbooks DROP CONSTRAINT playbooks_event_check;
ALTER TABLE public.playbooks ADD CONSTRAINT playbooks_event_check
  CHECK (event IN ('booking_created', 'day_before', 'visit_completed', 'no_reply', 'patient_reply'));

-- 2. jobs ------------------------------------------------------------------------------------------------------------------
CREATE TABLE public.agent_jobs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.organizations(id),
  branch_id       uuid NOT NULL REFERENCES public.branches(id),
  agent           text NOT NULL CHECK (agent ~ '^[a-z][a-z0-9_]{1,40}$'),
  playbook_id     uuid NOT NULL REFERENCES public.playbooks(id) ON DELETE CASCADE,
  event           text NOT NULL CHECK (event IN ('booking_created', 'day_before', 'visit_completed', 'no_reply', 'patient_reply')),
  booking_id      uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  customer_id     uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  conversation_id uuid REFERENCES public.conversations(id) ON DELETE SET NULL,
  message_id      uuid REFERENCES public.messages(id) ON DELETE SET NULL,      -- the inbound reply (patient_reply jobs)
  run_after       timestamptz NOT NULL DEFAULT now(),
  status          text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'done', 'skipped', 'failed')),
  attempts        integer NOT NULL DEFAULT 0,
  last_error      text,                                                         -- a CODE, never a body
  result          jsonb NOT NULL DEFAULT '{}'::jsonb,                           -- codes and ids only: never reply text
  claimed_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);
-- idempotency: a booking never gets two confirmations (two reminders, ...); a reply is keyed by its message too
CREATE UNIQUE INDEX agent_jobs_once ON public.agent_jobs (playbook_id, booking_id, event, COALESCE(message_id, '00000000-0000-0000-0000-000000000000'::uuid));
CREATE INDEX idx_agent_jobs_due ON public.agent_jobs (run_after) WHERE status = 'queued';
CREATE INDEX idx_agent_jobs_org ON public.agent_jobs (org_id, branch_id, status);

-- 3. reply rules: built-in rows (org_id NULL) per language; an organization can add its own ------------------------------------
CREATE TABLE public.agent_reply_rules (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id    uuid REFERENCES public.organizations(id),
  language  text NOT NULL CHECK (language IN ('en', 'ne')),
  intent    text NOT NULL CHECK (intent IN ('confirm', 'cancel', 'urgent', 'clinical')),
  word      text NOT NULL CHECK (length(btrim(word)) > 0 AND word = lower(word)),
  match     text NOT NULL CHECK (match IN ('exact', 'prefix', 'contains')),   -- exact: the whole message; prefix: a word STARTING with it (pain -> painful, pains); contains: the whole word or phrase
  enabled   boolean NOT NULL DEFAULT true,
  CONSTRAINT agent_reply_rules_key UNIQUE NULLS NOT DISTINCT (org_id, language, intent, word),
  CONSTRAINT agent_reply_rules_match_intent CHECK ((intent IN ('confirm', 'cancel')) = (match = 'exact'))   -- confirm / cancel only on the WHOLE message; symptoms anywhere in it
);
INSERT INTO public.agent_reply_rules (org_id, language, intent, word, match) VALUES
  (NULL, 'en', 'confirm', 'yes', 'exact'), (NULL, 'en', 'confirm', 'y', 'exact'), (NULL, 'en', 'confirm', 'ok', 'exact'), (NULL, 'en', 'confirm', 'okay', 'exact'),
  (NULL, 'en', 'confirm', 'haa', 'exact'), (NULL, 'en', 'confirm', 'ho', 'exact'), (NULL, 'en', 'confirm', 'huncha', 'exact'), (NULL, 'en', 'confirm', 'thik cha', 'exact'),
  (NULL, 'en', 'confirm', 'thik chha', 'exact'), (NULL, 'en', 'confirm', 'thik chha hajur', 'exact'),
  (NULL, 'ne', 'confirm', 'हो', 'exact'), (NULL, 'ne', 'confirm', 'हुन्छ', 'exact'), (NULL, 'ne', 'confirm', 'ठिक छ', 'exact'), (NULL, 'ne', 'confirm', 'ठीक छ', 'exact'),
  (NULL, 'en', 'cancel', 'no', 'exact'), (NULL, 'en', 'cancel', 'cancel', 'exact'), (NULL, 'en', 'cancel', 'radda', 'exact'), (NULL, 'ne', 'cancel', 'रद्द', 'exact'),
  -- urgent (hand off AND flag urgent): word starts, so bleeding / bleeds / bled / blood, fever / feverish; romanised and Devanagari Nepali
  (NULL, 'en', 'urgent', 'bleed', 'prefix'), (NULL, 'en', 'urgent', 'bled', 'prefix'), (NULL, 'en', 'urgent', 'blood', 'prefix'), (NULL, 'en', 'urgent', 'fever', 'prefix'),
  (NULL, 'en', 'urgent', 'emergency', 'prefix'), (NULL, 'en', 'urgent', 'urgent', 'prefix'), (NULL, 'en', 'urgent', 'ragat', 'prefix'), (NULL, 'en', 'urgent', 'jaro', 'prefix'),
  (NULL, 'en', 'urgent', 'cannot breathe', 'contains'), (NULL, 'en', 'urgent', 'can''t breathe', 'contains'), (NULL, 'en', 'urgent', 'cant breathe', 'contains'),
  (NULL, 'ne', 'urgent', 'रगत', 'prefix'), (NULL, 'ne', 'urgent', 'ज्वरो', 'prefix'),
  -- clinical (hand off): pain / painful / pains, swell / swelling / swollen / swelled, hurt / hurts, ache / aching, toothache, infection, sore, ...
  (NULL, 'en', 'clinical', 'pain', 'prefix'), (NULL, 'en', 'clinical', 'swell', 'prefix'), (NULL, 'en', 'clinical', 'swollen', 'prefix'), (NULL, 'en', 'clinical', 'hurt', 'prefix'),
  (NULL, 'en', 'clinical', 'ache', 'prefix'), (NULL, 'en', 'clinical', 'toothache', 'prefix'), (NULL, 'en', 'clinical', 'infect', 'prefix'), (NULL, 'en', 'clinical', 'allerg', 'prefix'),
  (NULL, 'en', 'clinical', 'medicin', 'prefix'), (NULL, 'en', 'clinical', 'sore', 'contains'), (NULL, 'en', 'clinical', 'sores', 'contains'), (NULL, 'en', 'clinical', 'pus', 'contains'),
  (NULL, 'en', 'clinical', 'dukh', 'prefix'), (NULL, 'en', 'clinical', 'sunni', 'prefix'),
  (NULL, 'ne', 'clinical', 'सुन्नि', 'prefix'), (NULL, 'ne', 'clinical', 'दुख', 'prefix');

-- 4. no direct writes; reads by policy ---------------------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['agent_jobs', 'agent_reply_rules'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated, service_role', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;
CREATE POLICY agent_jobs_read ON public.agent_jobs FOR SELECT TO authenticated
  USING (
    org_id = public.get_user_org_id()
    AND (
      public.get_user_role()::text IN ('admin', 'admin_viewer')
      OR (public.get_user_role()::text IN ('staff', 'manager') AND branch_id = ANY (public.get_user_branch_ids()))
    )
  );
CREATE POLICY agent_reply_rules_read ON public.agent_reply_rules FOR SELECT TO authenticated
  USING (
    (org_id IS NULL OR org_id = public.get_user_org_id())
    AND public.get_user_role()::text IN ('staff', 'manager', 'admin', 'admin_viewer', 'practitioner')
  );

-- 5. seed: the five playbooks per existing organization, DISABLED, level 1, NO template text (a clinic attaches its own wording) ---
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
ON CONFLICT ON CONSTRAINT playbooks_key DO NOTHING;

-- 6. enqueue (internal) ------------------------------------------------------------------------------------------------------
-- the follow_up playbooks that may enqueue for this org, branch and event: enabled, and the agent on for that branch
CREATE FUNCTION public._agent_enqueue(p_org uuid, p_branch uuid, p_event text, p_booking uuid, p_customer uuid, p_run_after timestamptz,
                                      p_conversation uuid DEFAULT NULL, p_message uuid DEFAULT NULL, p_key text DEFAULT NULL) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE n integer := 0; k integer; pb record;
BEGIN
  IF NOT public._agent_enabled(p_org, p_branch, 'follow_up') THEN RETURN 0; END IF;
  FOR pb IN SELECT id, settings FROM public.playbooks
             WHERE org_id = p_org AND agent = 'follow_up' AND event = p_event AND enabled AND (branch_id IS NULL OR branch_id = p_branch)
               AND (p_key IS NULL OR key = p_key) LOOP
    INSERT INTO public.agent_jobs (org_id, branch_id, agent, playbook_id, event, booking_id, customer_id, conversation_id, message_id, run_after)
    VALUES (p_org, p_branch, 'follow_up', pb.id, p_event, p_booking, p_customer, p_conversation, p_message, p_run_after)
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  END LOOP;
  RETURN n;
END $$;

-- 6.1 a booking is created
CREATE FUNCTION public.trg_agent_booking_created() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_org uuid;
BEGIN
  BEGIN   -- an enqueue problem must never fail the booking
    IF NEW.customer_id IS NOT NULL AND NEW.status IN ('Pending', 'Confirmed') AND NEW.start_datetime > now() THEN
      SELECT org_id INTO v_org FROM public.branches WHERE id = NEW.branch_id;
      IF v_org IS NOT NULL THEN
        PERFORM public._agent_enqueue(v_org, NEW.branch_id, 'booking_created', NEW.id, NEW.customer_id, now());
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'agent enqueue failed for booking % (%)', NEW.id, SQLSTATE;
  END;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_agent_booking_created AFTER INSERT ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.trg_agent_booking_created();

-- 6.2 a visit is completed: the aftercare check-in, for the treatments the playbook lists, the next day at its send time (org timezone)
CREATE FUNCTION public.trg_agent_visit_completed() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_org uuid; v_tz text; v_treat text; pb record; v_time time; v_run timestamptz;
BEGIN
  BEGIN
    IF NEW.customer_id IS NOT NULL AND NEW.status = 'Completed' AND OLD.status IS DISTINCT FROM NEW.status THEN
      SELECT b.org_id, COALESCE(o.timezone, 'Asia/Kathmandu') INTO v_org, v_tz FROM public.branches b JOIN public.organizations o ON o.id = b.org_id WHERE b.id = NEW.branch_id;
      SELECT t.name INTO v_treat FROM public.treatments t WHERE t.id = NEW.treatment_id;
      IF v_org IS NOT NULL AND v_treat IS NOT NULL AND public._agent_enabled(v_org, NEW.branch_id, 'follow_up') THEN
        FOR pb IN SELECT id, settings FROM public.playbooks
                   WHERE org_id = v_org AND agent = 'follow_up' AND event = 'visit_completed' AND enabled AND (branch_id IS NULL OR branch_id = NEW.branch_id)
                     AND jsonb_typeof(settings -> 'treatments') = 'array'
                     AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(settings -> 'treatments') x WHERE lower(x) = lower(v_treat)) LOOP
          v_time := COALESCE(NULLIF(pb.settings ->> 'send_time', '')::time, time '09:00');
          v_run := (((now() AT TIME ZONE v_tz)::date + 1) + v_time) AT TIME ZONE v_tz;
          INSERT INTO public.agent_jobs (org_id, branch_id, agent, playbook_id, event, booking_id, customer_id, run_after)
          VALUES (v_org, NEW.branch_id, 'follow_up', pb.id, 'visit_completed', NEW.id, NEW.customer_id, v_run) ON CONFLICT DO NOTHING;
        END LOOP;
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'agent enqueue failed for completed booking % (%)', NEW.id, SQLSTATE;
  END;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_agent_visit_completed AFTER UPDATE OF status ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.trg_agent_visit_completed();

-- 6.3 a patient replies. A reply is tied to a booking ONLY when the agent sent a confirmation or reminder about THAT booking in the same
-- conversation within the last 48 hours (the message's action carries the booking id); the booking must still be Pending and within 7 days.
-- Otherwise no job: the reply is just a message in the Inbox. STOP / START words are the hub's, not ours.
CREATE FUNCTION public.trg_agent_patient_reply() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_cust uuid; v_branch uuid; v_org uuid; v_bk uuid; v_norm text;
BEGIN
  BEGIN
    IF NEW.direction = 'in' AND NEW.kind = 'message' AND NEW.author_kind = 'patient' THEN
      v_norm := lower(btrim(regexp_replace(NEW.body, '[[:space:]]+', ' ', 'g'), ' .!'));
      IF v_norm NOT IN ('stop', 'stopall', 'stop all', 'unsubscribe', 'end', 'quit', 'रोक', 'बन्द', 'start', 'unstop', 'शुरु', 'शुरू') THEN
        SELECT c.customer_id, c.branch_id, c.org_id INTO v_cust, v_branch, v_org FROM public.conversations c WHERE c.id = NEW.conversation_id;
        IF v_cust IS NOT NULL THEN
          SELECT bk.id, bk.branch_id INTO v_bk, v_branch FROM public.bookings bk JOIN public.branches br ON br.id = bk.branch_id
           WHERE bk.customer_id = v_cust AND br.org_id = v_org AND bk.status = 'Pending' AND bk.start_datetime > now() AND bk.start_datetime <= now() + interval '7 days'
             AND EXISTS (SELECT 1 FROM public.messages om JOIN public.action_log al ON al.id = om.action_id
                          WHERE om.conversation_id = NEW.conversation_id AND om.direction = 'out' AND om.kind = 'message' AND om.author_kind = 'agent'
                            AND om.status IN ('queued', 'sending', 'sent', 'delivered', 'read') AND om.created_at > now() - interval '48 hours'
                            AND al.inputs ->> 'booking_id' = bk.id::text)
           ORDER BY bk.start_datetime, bk.id LIMIT 1;   -- id: a deterministic pick if two bookings start at the same time
          IF v_bk IS NOT NULL THEN
            PERFORM public._agent_enqueue(v_org, v_branch, 'patient_reply', v_bk, v_cust, now(), NEW.conversation_id, NEW.id);
          END IF;
        END IF;
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'agent enqueue failed for an inbound message (%)', SQLSTATE;
  END;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_agent_patient_reply AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.trg_agent_patient_reply();

-- 7. scans (pg_cron) -----------------------------------------------------------------------------------------------------------
-- 7.1 day before: bookings tomorrow (org timezone), Pending or Confirmed, once the playbook's send time (default 09:00) has passed
CREATE FUNCTION public.agent_scan_day_before() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE n integer := 0; r record;
BEGIN
  FOR r IN
    SELECT bk.id AS bid, bk.branch_id, bk.customer_id, br.org_id, pb.id AS pid
      FROM public.playbooks pb
      JOIN public.organizations o ON o.id = pb.org_id
      JOIN public.branches br ON br.org_id = pb.org_id AND (pb.branch_id IS NULL OR pb.branch_id = br.id)
      JOIN public.bookings bk ON bk.branch_id = br.id
     WHERE pb.agent = 'follow_up' AND pb.event = 'day_before' AND pb.enabled
       AND bk.customer_id IS NOT NULL AND bk.status IN ('Pending', 'Confirmed')
       AND bk.date = ((now() AT TIME ZONE COALESCE(o.timezone, 'Asia/Kathmandu'))::date + 1)
       AND (now() AT TIME ZONE COALESCE(o.timezone, 'Asia/Kathmandu'))::time >= COALESCE(NULLIF(pb.settings ->> 'send_time', '')::time, time '09:00')
       AND public._agent_enabled(pb.org_id, br.id, 'follow_up')
  LOOP
    INSERT INTO public.agent_jobs (org_id, branch_id, agent, playbook_id, event, booking_id, customer_id, run_after)
    VALUES (r.org_id, r.branch_id, 'follow_up', r.pid, 'day_before', r.bid, r.customer_id, now()) ON CONFLICT DO NOTHING;
    IF FOUND THEN n := n + 1; END IF;
  END LOOP;
  RETURN n;
END $$;

-- 7.2 six o'clock: tomorrow's bookings that are still Pending (from the playbook's send time, default 18:00, until midnight)
CREATE FUNCTION public.agent_scan_not_confirmed() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE n integer := 0; r record;
BEGIN
  FOR r IN
    SELECT bk.id AS bid, bk.branch_id, bk.customer_id, br.org_id, pb.id AS pid
      FROM public.playbooks pb
      JOIN public.organizations o ON o.id = pb.org_id
      JOIN public.branches br ON br.org_id = pb.org_id AND (pb.branch_id IS NULL OR pb.branch_id = br.id)
      JOIN public.bookings bk ON bk.branch_id = br.id
     WHERE pb.agent = 'follow_up' AND pb.event = 'no_reply' AND pb.enabled
       AND bk.status = 'Pending'
       AND bk.date = ((now() AT TIME ZONE COALESCE(o.timezone, 'Asia/Kathmandu'))::date + 1)
       AND (now() AT TIME ZONE COALESCE(o.timezone, 'Asia/Kathmandu'))::time >= COALESCE(NULLIF(pb.settings ->> 'send_time', '')::time, time '18:00')
       AND public._agent_enabled(pb.org_id, br.id, 'follow_up')
  LOOP
    INSERT INTO public.agent_jobs (org_id, branch_id, agent, playbook_id, event, booking_id, customer_id, run_after)
    VALUES (r.org_id, r.branch_id, 'follow_up', r.pid, 'no_reply', r.bid, r.customer_id, now()) ON CONFLICT DO NOTHING;
    IF FOUND THEN n := n + 1; END IF;
  END LOOP;
  RETURN n;
END $$;

-- 7.3 the clock: every minute kick the runner when a queued job is due (same pattern as hub_kick_sender)
CREATE FUNCTION public.agent_kick_runner() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_cfg record; v_due integer;
BEGIN
  IF to_regclass('private.outreach_function_config') IS NULL THEN RETURN 0; END IF;
  EXECUTE 'SELECT function_base_url, cron_bearer_token FROM private.outreach_function_config LIMIT 1' INTO v_cfg;
  IF v_cfg.function_base_url IS NULL THEN RETURN 0; END IF;
  SELECT count(*) INTO v_due FROM public.agent_jobs WHERE (status = 'queued' AND run_after <= now()) OR (status = 'running' AND claimed_at < now() - interval '10 minutes');
  IF v_due = 0 THEN RETURN 0; END IF;
  BEGIN
    PERFORM net.http_post(url := v_cfg.function_base_url || '/agent-run',
                          headers := jsonb_build_object('Authorization', 'Bearer ' || v_cfg.cron_bearer_token, 'Content-Type', 'application/json'),
                          body := '{}'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'agent_kick_runner: could not call agent-run (%)', SQLSTATE;
    RETURN 0;
  END;
  RETURN 1;
END $$;

DO $$
BEGIN
  IF to_regnamespace('cron') IS NULL THEN
    RAISE NOTICE 'pg_cron is not installed here: the agent jobs were NOT scheduled (enable pg_cron, then run migration-017 section 7 again).';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'agent-scan-day-before') THEN PERFORM cron.unschedule('agent-scan-day-before'); END IF;
  PERFORM cron.schedule('agent-scan-day-before', '*/15 * * * *', 'SELECT public.agent_scan_day_before()');
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'agent-scan-no-reply') THEN PERFORM cron.unschedule('agent-scan-no-reply'); END IF;
  PERFORM cron.schedule('agent-scan-no-reply', '*/15 * * * *', 'SELECT public.agent_scan_not_confirmed()');
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'agent-kick') THEN PERFORM cron.unschedule('agent-kick'); END IF;
  PERFORM cron.schedule('agent-kick', '* * * * *', 'SELECT public.agent_kick_runner()');
END $$;

-- 8. the runner's functions (service role only). Each job comes back as ONE jsonb: only what the runner needs. The reply text is in it for
-- patient_reply jobs and nowhere else; the treatment is a NAME and the date is the visit date in the clinic's timezone. -------------
CREATE FUNCTION public.agent_claim_jobs(p_limit integer DEFAULT 10) RETURNS SETOF jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
BEGIN
  UPDATE public.agent_jobs j SET status = 'failed', last_error = 'STALE'
   WHERE j.status = 'running' AND j.claimed_at < now() - interval '10 minutes' AND j.attempts >= 3;
  UPDATE public.agent_jobs j SET status = 'queued'
   WHERE j.status = 'running' AND j.claimed_at < now() - interval '10 minutes' AND j.attempts < 3;

  RETURN QUERY
  WITH picked AS (
    SELECT q.id FROM public.agent_jobs q WHERE q.status = 'queued' AND q.run_after <= now() ORDER BY q.run_after LIMIT GREATEST(1, LEAST(p_limit, 50)) FOR UPDATE SKIP LOCKED
  ), upd AS (
    UPDATE public.agent_jobs j SET status = 'running', attempts = j.attempts + 1, claimed_at = now() FROM picked WHERE j.id = picked.id RETURNING j.*
  )
  SELECT jsonb_build_object(
    'job_id', u.id, 'org_id', u.org_id, 'branch_id', u.branch_id, 'agent', u.agent, 'event', u.event, 'attempts', u.attempts,
    'customer_id', u.customer_id, 'booking_id', u.booking_id, 'conversation_id', u.conversation_id, 'message_id', u.message_id,
    'playbook', jsonb_build_object('id', p.id, 'key', p.key, 'level', p.level, 'enabled', p.enabled, 'template_id', p.template_id, 'channel', p.channel, 'settings', p.settings),
    'agent_enabled', public._agent_enabled(u.org_id, u.branch_id, u.agent),
    'booking', CASE WHEN b.id IS NULL THEN NULL ELSE jsonb_build_object('status', b.status, 'treatment', t.name,
                 'date', to_char((b.start_datetime AT TIME ZONE COALESCE(o.timezone, 'Asia/Kathmandu'))::date, 'YYYY-MM-DD')) END,
    'conversation', CASE WHEN c.id IS NULL THEN NULL ELSE jsonb_build_object('state', c.state, 'language', c.language) END,
    'reply_text', CASE WHEN u.event = 'patient_reply' THEN m.body END
  )
  FROM upd u
  JOIN public.playbooks p ON p.id = u.playbook_id
  JOIN public.organizations o ON o.id = u.org_id
  LEFT JOIN public.bookings b ON b.id = u.booking_id
  LEFT JOIN public.treatments t ON t.id = b.treatment_id
  LEFT JOIN public.conversations c ON c.id = u.conversation_id
  LEFT JOIN public.messages m ON m.id = u.message_id;
END $$;

-- p_status: done | skipped | failed | retry (retry = queued again in attempts * 5 minutes, failed after 3 attempts)
CREATE FUNCTION public.agent_finish_job(p_job uuid, p_status text, p_result jsonb DEFAULT '{}'::jsonb, p_error text DEFAULT NULL) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE j public.agent_jobs;
BEGIN
  IF p_status NOT IN ('done', 'skipped', 'failed', 'retry') THEN RAISE EXCEPTION 'agent_finish_job: bad status' USING ERRCODE = '22023'; END IF;
  SELECT * INTO j FROM public.agent_jobs WHERE id = p_job AND status = 'running' FOR UPDATE;
  IF j.id IS NULL THEN RETURN false; END IF;
  IF p_status = 'retry' THEN
    IF j.attempts >= 3 THEN
      UPDATE public.agent_jobs SET status = 'failed', last_error = left(COALESCE(p_error, 'RETRIES_EXHAUSTED'), 80), result = COALESCE(p_result, '{}'::jsonb) WHERE id = j.id;
    ELSE
      UPDATE public.agent_jobs SET status = 'queued', run_after = now() + (j.attempts * interval '5 minutes'), last_error = left(p_error, 80) WHERE id = j.id;
    END IF;
  ELSE
    UPDATE public.agent_jobs SET status = p_status, last_error = left(p_error, 80), result = COALESCE(p_result, '{}'::jsonb) WHERE id = j.id;
  END IF;
  RETURN true;
END $$;

-- Idempotency per job step. Every runner action carries p_ctx.step_key = 'job:<job id>:<step>'; the action log keeps the ctx in inputs.ctx. A retried
-- job asks here first and skips a step that already succeeded (returns that action's result, with its action id), so a lost response or a failed
-- finish can never send a second message. NULL = the step has not succeeded yet.
CREATE INDEX idx_action_log_step_key ON public.action_log ((inputs -> 'ctx' ->> 'step_key')) WHERE inputs -> 'ctx' ? 'step_key';
CREATE FUNCTION public.agent_step_result(p_org uuid, p_key text) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT jsonb_set(a.result, '{action_id}', to_jsonb(a.id))
    FROM public.action_log a
   WHERE a.org_id = p_org AND a.ok AND p_key LIKE 'job:%' AND a.inputs -> 'ctx' ->> 'step_key' = p_key
   ORDER BY a.created_at, a.id LIMIT 1 $$;

-- the rules for one organization: the built-ins plus its own, enabled only
CREATE FUNCTION public.agent_get_reply_rules(p_org uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('intent', r.intent, 'word', r.word, 'match', r.match, 'language', r.language)), '[]'::jsonb)
    FROM public.agent_reply_rules r WHERE r.enabled AND (r.org_id IS NULL OR r.org_id = p_org) $$;

-- 9. act_work_propose: p_uses_ai (the 016 body plus one trailing parameter) ---------------------------------------------------
DROP FUNCTION public.act_work_propose(text, text, uuid, text, text, text, jsonb, uuid, jsonb, uuid, uuid, uuid, boolean, timestamptz, jsonb);
CREATE OR REPLACE FUNCTION public.act_work_propose(p_agent text, p_kind text, p_branch uuid, p_title text, p_summary text, p_action text DEFAULT NULL::text, p_inputs jsonb DEFAULT '{}'::jsonb, p_playbook uuid DEFAULT NULL::uuid, p_sources jsonb DEFAULT '[]'::jsonb, p_customer uuid DEFAULT NULL::uuid, p_booking uuid DEFAULT NULL::uuid, p_conversation uuid DEFAULT NULL::uuid, p_urgent boolean DEFAULT false, p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ctx jsonb DEFAULT NULL::jsonb, p_uses_ai boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  ctx jsonb; v_inputs jsonb; v_org uuid; v_reason text; v_id uuid; pb public.playbooks; k text; v_in jsonb := COALESCE(p_inputs, '{}'::jsonb);
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('agent', p_agent, 'kind', p_kind, 'branch_id', p_branch, 'title', p_title, 'proposed_action', p_action, 'input_keys',
                                 CASE WHEN jsonb_typeof(v_in) = 'object' THEN (SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM jsonb_object_keys(v_in) x) END,
                                 'playbook_id', p_playbook, 'customer_id', p_customer, 'booking_id', p_booking, 'conversation_id', p_conversation)
              || public._act_ctx_inputs(p_ctx, ctx);
  IF NOT COALESCE((ctx ->> 'service')::boolean, false) OR ctx ->> 'kind' NOT IN ('agent', 'rule') THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'FORBIDDEN', 'Only an agent or a rule can propose work.', NULL, NULL, 'agent_work_items');
  END IF;
  IF ctx ->> 'kind' = 'agent' AND ctx ->> 'agent' IS DISTINCT FROM p_agent THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'FORBIDDEN', 'An agent can propose only as itself.', NULL, NULL, 'agent_work_items');
  END IF;
  IF p_branch IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch AND org_id = v_org) OR NOT public._act_in_scope(ctx, v_org, p_branch) THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, NULL, v_inputs, false, NULL, 'BRANCH_NOT_FOUND', 'Branch not found.', NULL, NULL, 'agent_work_items');
  END IF;
  IF p_agent IS NULL OR p_agent !~ '^[a-z][a-z0-9_]{1,40}$' OR p_kind IS NULL OR p_kind NOT IN ('approval', 'exception')
     OR COALESCE(btrim(p_title), '') = '' OR COALESCE(btrim(p_summary), '') = '' OR jsonb_typeof(v_in) <> 'object'
     OR (p_kind = 'approval' AND p_action IS NULL) THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'INVALID_INPUT', 'Agent, kind, title, summary and (for an approval) an action are required.', NULL, NULL, 'agent_work_items');
  END IF;
  IF p_action IS NOT NULL THEN
    IF p_action NOT IN ('act_message_send', 'act_booking_set_status', 'act_booking_flag_not_confirmed') THEN
      RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'ACTION_NOT_ALLOWED', 'That action cannot be proposed.', NULL, NULL, 'agent_work_items');
    END IF;
    FOR k IN SELECT jsonb_object_keys(v_in) LOOP
      IF NOT k = ANY (public._work_keys(p_action, false)) THEN
        RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'INVALID_INPUT', 'Unknown input key: ' || k, NULL, NULL, 'agent_work_items');
      END IF;
    END LOOP;
    IF (p_action = 'act_message_send' AND p_customer IS NULL AND p_conversation IS NULL AND p_booking IS NULL)
       OR (p_action <> 'act_message_send' AND p_booking IS NULL) THEN
      RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'INVALID_INPUT', 'The action needs its target (patient, conversation or booking).', NULL, NULL, 'agent_work_items');
    END IF;
  END IF;
  IF (p_customer IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer AND org_id = v_org))
     OR (p_booking IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.bookings WHERE id = p_booking AND branch_id = p_branch))
     OR (p_conversation IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.conversations WHERE id = p_conversation AND org_id = v_org AND (branch_id IS NULL OR branch_id = p_branch))) THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'TARGET_NOT_FOUND', 'The patient, booking or conversation is not in this branch.', NULL, NULL, 'agent_work_items');
  END IF;
  IF p_playbook IS NOT NULL THEN
    SELECT * INTO pb FROM public.playbooks WHERE id = p_playbook AND org_id = v_org AND agent = p_agent AND (branch_id IS NULL OR branch_id = p_branch);
    IF pb.id IS NULL THEN
      RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'PLAYBOOK_NOT_FOUND', 'Playbook not found for this agent and branch.', NULL, NULL, 'agent_work_items');
    END IF;
    IF NOT pb.enabled THEN
      RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, 'PLAYBOOK_OFF', 'This playbook is switched off.', NULL, NULL, 'agent_work_items');
    END IF;
  END IF;
  -- 017: a draft that needs no model (a fixed template) only needs the agent to be on; AI off or an empty budget does not stop it
  v_reason := CASE WHEN COALESCE(p_uses_ai, true) THEN public._ai_block_reason(v_org, p_branch, p_agent)
                   WHEN NOT public._agent_enabled(v_org, p_branch, p_agent) THEN 'AGENT_OFF' END;
  IF v_reason IS NOT NULL THEN
    RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, false, NULL, v_reason,
      CASE v_reason WHEN 'AI_OFF' THEN 'AI is switched off for this clinic.' WHEN 'AGENT_OFF' THEN 'This agent is switched off for this branch.'
                    ELSE 'The AI budget for this month is used up.' END, NULL, NULL, 'agent_work_items');
  END IF;

  INSERT INTO public.agent_work_items (org_id, branch_id, agent, playbook_id, kind, urgent, title, summary, proposed_action, proposed_inputs, sources,
                                       customer_id, booking_id, conversation_id, expires_at)
  VALUES (v_org, p_branch, p_agent, p_playbook, p_kind, COALESCE(p_urgent, false), btrim(p_title), btrim(p_summary), p_action, v_in, COALESCE(p_sources, '[]'::jsonb),
          p_customer, p_booking, p_conversation, COALESCE(p_expires_at, now() + interval '48 hours'))
  RETURNING id INTO v_id;
  RETURN public._act_finish(ctx, 'work.propose', v_org, p_branch, v_inputs, true, jsonb_build_object('item_id', v_id), NULL, NULL, v_id, NULL, 'agent_work_items');
END $function$;

-- 10. act_work_approve: ORDER_REQUIRED (the 016 body plus the prerequisite check) -------------------------------------------------
CREATE OR REPLACE FUNCTION public.act_work_approve(p_item uuid, p_edited_inputs jsonb DEFAULT NULL::jsonb, p_ctx jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  ctx jsonb; v_inputs jsonb; v_org uuid; v_uid uuid; w public.agent_work_items; v_final jsonb; v_edited boolean := false; k text; v_ictx jsonb; r jsonb;
  v_ok boolean; v_code text; v_msg text; v_status text; v_req text; v_req_status text;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid; v_uid := (ctx ->> 'user_id')::uuid;
  v_inputs := jsonb_build_object('item_id', p_item, 'edited', p_edited_inputs IS NOT NULL,
                                 'edited_keys', CASE WHEN jsonb_typeof(p_edited_inputs) = 'object' THEN (SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM jsonb_object_keys(p_edited_inputs) x) END)
              || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('admin', 'manager', 'staff', 'practitioner') THEN
    RETURN public._act_finish(ctx, 'work.approve', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot approve this.', p_item, NULL, 'agent_work_items');
  END IF;
  SELECT * INTO w FROM public.agent_work_items WHERE id = p_item AND org_id = v_org FOR UPDATE;
  IF w.id IS NULL OR NOT public._work_in_scope(ctx, w) THEN
    RETURN public._act_finish(ctx, 'work.approve', v_org, NULL, v_inputs, false, NULL, 'ITEM_NOT_FOUND', 'Item not found.', NULL, NULL, 'agent_work_items');
  END IF;
  IF w.status <> 'open' THEN
    RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, NULL, 'ITEM_NOT_OPEN', 'This item was already decided.', w.id, NULL, 'agent_work_items');
  END IF;
  IF w.kind <> 'approval' OR w.proposed_action IS NULL THEN
    RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, NULL, 'NOT_APPROVABLE', 'This item has nothing to approve.', w.id, NULL, 'agent_work_items');
  END IF;
  -- 017: a step can require an earlier step (sources: [{"kind":"work_item","id":..,"requires":true}]): it cannot go first
  FOR v_req IN SELECT x ->> 'id' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(w.sources) = 'array' THEN w.sources ELSE '[]'::jsonb END) x
                WHERE x ->> 'kind' = 'work_item' AND COALESCE((x ->> 'requires')::boolean, false) LOOP
    SELECT status INTO v_req_status FROM public.agent_work_items WHERE id = v_req::uuid AND org_id = v_org;
    IF v_req_status IS DISTINCT FROM 'approved' AND v_req_status IS DISTINCT FROM 'edited' THEN
      RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, NULL, 'ORDER_REQUIRED',
        CASE WHEN v_req_status = 'open' THEN 'Approve the earlier step first.' ELSE 'The earlier step was not approved, so this one cannot go ahead.' END, w.id, NULL, 'agent_work_items');
    END IF;
  END LOOP;
  IF w.expires_at IS NOT NULL AND w.expires_at < now() THEN
    UPDATE public.agent_work_items SET status = 'expired', decided_at = now() WHERE id = w.id;
    RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, NULL, 'ITEM_EXPIRED', 'This item expired before it was approved.', w.id, NULL, 'agent_work_items');
  END IF;

  -- edits: content keys only; customer, conversation and booking always come from the stored item
  v_final := w.proposed_inputs;
  IF p_edited_inputs IS NOT NULL THEN
    IF jsonb_typeof(p_edited_inputs) <> 'object' THEN
      RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, NULL, 'INVALID_INPUT', 'Edits must be an object.', w.id, NULL, 'agent_work_items');
    END IF;
    FOR k IN SELECT jsonb_object_keys(p_edited_inputs) LOOP
      IF NOT k = ANY (public._work_keys(w.proposed_action, true)) THEN
        RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, NULL, 'EDIT_NOT_ALLOWED', 'You cannot edit "' || k || '" on this item.', w.id, NULL, 'agent_work_items');
      END IF;
    END LOOP;
    v_final := w.proposed_inputs || p_edited_inputs;
    v_edited := v_final IS DISTINCT FROM w.proposed_inputs;
  END IF;

  -- the grant, then the stored action as the agent, approved by this person. A raised error inside it is caught: the item is marked failed.
  v_ictx := jsonb_build_object('actor_kind', 'agent', 'agent', w.agent, 'org_id', w.org_id, 'branch_id', w.branch_id, 'approved_by', v_uid,
                               'reason_source', 'work_item:' || w.id);
  INSERT INTO private.approval_grants (txid, work_item, agent, org_id, branch_id, approved_by) VALUES (txid_current(), w.id, w.agent, w.org_id, w.branch_id, v_uid);
  BEGIN
    IF w.proposed_action = 'act_message_send' THEN
      r := public.act_message_send(p_conversation => w.conversation_id, p_customer => w.customer_id, p_channel => v_final ->> 'channel',
                                   p_template => (v_final ->> 'template')::uuid, p_text => v_final ->> 'text', p_fields => COALESCE(v_final -> 'fields', '{}'::jsonb),
                                   p_purpose => COALESCE(v_final ->> 'purpose', 'service'), p_booking => w.booking_id, p_language => v_final ->> 'language',
                                   p_on_quiet_hours => COALESCE(v_final ->> 'on_quiet_hours', 'refuse'), p_ctx => v_ictx);
    ELSIF w.proposed_action = 'act_booking_set_status' THEN
      r := public.act_booking_set_status(w.booking_id, (v_final ->> 'status')::public.booking_status, v_final ->> 'reason', v_ictx);
    ELSIF w.proposed_action = 'act_booking_flag_not_confirmed' THEN
      r := public.act_booking_flag_not_confirmed(w.booking_id, v_final ->> 'reason', v_ictx);
    ELSE
      r := jsonb_build_object('ok', false, 'error', jsonb_build_object('code', 'ACTION_NOT_ALLOWED', 'message', 'That action cannot be run from the queue.'));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    r := jsonb_build_object('ok', false, 'error', jsonb_build_object('code', 'ACTION_ERROR', 'message', 'The action could not be run.'));
  END;
  DELETE FROM private.approval_grants WHERE txid = txid_current();   -- never leave a grant behind

  v_ok := COALESCE((r ->> 'ok')::boolean, false);
  IF v_ok THEN
    v_status := CASE WHEN v_edited THEN 'edited' ELSE 'approved' END;
    UPDATE public.agent_work_items SET status = v_status, decided_by = v_uid, decided_at = now(), final_inputs = CASE WHEN v_edited THEN v_final END,
           result_action_id = (r ->> 'action_id')::uuid WHERE id = w.id;
    RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, true,
      jsonb_build_object('item_id', w.id, 'status', v_status, 'result_action_id', r ->> 'action_id', 'result', r -> 'data'), NULL, NULL, w.id, NULL, 'agent_work_items');
  END IF;
  v_code := COALESCE(r #>> '{error,code}', 'ACTION_ERROR'); v_msg := COALESCE(r #>> '{error,message}', 'The action could not be run.');
  UPDATE public.agent_work_items SET status = 'failed', decided_by = v_uid, decided_at = now(), decision_reason = v_code,
         result_action_id = (r ->> 'action_id')::uuid WHERE id = w.id;
  RETURN public._act_finish(ctx, 'work.approve', v_org, w.branch_id, v_inputs, false, jsonb_build_object('item_id', w.id, 'status', 'failed'), v_code, v_msg, w.id, NULL, 'agent_work_items');
END $function$;

REVOKE ALL ON FUNCTION public.act_work_propose(text, text, uuid, text, text, text, jsonb, uuid, jsonb, uuid, uuid, uuid, boolean, timestamptz, jsonb, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.act_work_propose(text, text, uuid, text, text, text, jsonb, uuid, jsonb, uuid, uuid, uuid, boolean, timestamptz, jsonb, boolean) TO service_role;
-- act_work_approve keeps the grants 016 gave it (CREATE OR REPLACE does not change them)

-- 11. read functions for the screens (signed-in users; the caller's own organization, never an argument) -------------------------
CREATE FUNCTION public._agent_rates(m jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE SET search_path = public
    AS $$
  SELECT m || jsonb_build_object(
    'cancelled_pct',            CASE WHEN (m ->> 'bookings')::numeric > 0 THEN round((m ->> 'cancelled')::numeric / (m ->> 'bookings')::numeric * 100, 1) END,
    'no_show_pct',              CASE WHEN (m ->> 'visits')::numeric > 0 THEN round((m ->> 'no_show')::numeric / (m ->> 'visits')::numeric * 100, 1) END,
    'confirmed_before_visit_pct', CASE WHEN (m ->> 'visits')::numeric > 0 THEN round((m ->> 'confirmed_before_visit')::numeric / (m ->> 'visits')::numeric * 100, 1) END,
    'confirmed_or_attended_pct', CASE WHEN (m ->> 'visits')::numeric > 0 THEN round((m ->> 'confirmed_or_attended')::numeric / (m ->> 'visits')::numeric * 100, 1) END) $$;

CREATE FUNCTION public._agent_metrics(p_branches uuid[], p_agent text, p_from timestamptz, p_to timestamptz) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  WITH b AS (
    SELECT bk.id, bk.status, bk.start_datetime FROM public.bookings bk
     WHERE bk.branch_id = ANY (p_branches) AND bk.start_datetime >= p_from AND bk.start_datetime < p_to
  ), conf AS (   -- confirmed through an action before the visit (anyone); by_agent = the agent did it
    SELECT b.id, bool_or(a.actor_kind = 'agent' AND a.actor_agent = p_agent) AS by_agent
      FROM b JOIN public.action_log a ON a.target_id = b.id AND a.action = 'booking.set_status' AND a.ok AND a.inputs ->> 'status' = 'Confirmed' AND a.created_at < b.start_datetime
     GROUP BY b.id
  )
  SELECT public._agent_rates(jsonb_build_object(
    'bookings', count(*), 'cancelled', count(*) FILTER (WHERE b.status = 'Cancelled'), 'visits', count(*) FILTER (WHERE b.status <> 'Cancelled'),
    'no_show', count(*) FILTER (WHERE b.status = 'No Show'),
    'confirmed_or_attended', count(*) FILTER (WHERE b.status IN ('Confirmed', 'In-Progress', 'Completed')),
    'confirmed_before_visit', (SELECT count(*) FROM conf), 'confirmed_by_agent', (SELECT count(*) FROM conf WHERE by_agent)))
    FROM b $$;

CREATE FUNCTION public.agent_scorecard(p_agent text, p_branch uuid, p_from timestamptz, p_to timestamptz) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  v_org uuid := public.get_user_org_id(); v_role text := public.get_user_role()::text; v_branches uuid[]; v_on timestamptz; v_cur jsonb; v_base jsonb; v_jobs jsonb;
BEGIN
  IF v_org IS NULL OR v_role NOT IN ('admin', 'admin_viewer', 'manager', 'staff') THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF p_agent IS NULL OR p_agent !~ '^[a-z][a-z0-9_]{1,40}$' OR p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN RAISE EXCEPTION 'bad arguments' USING ERRCODE = '22023'; END IF;
  IF v_role IN ('admin', 'admin_viewer') THEN SELECT array_agg(id) INTO v_branches FROM public.branches WHERE org_id = v_org;
  ELSE v_branches := public.get_user_branch_ids(); END IF;
  IF p_branch IS NOT NULL THEN
    IF NOT (p_branch = ANY (COALESCE(v_branches, ARRAY[]::uuid[]))) THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
    v_branches := ARRAY[p_branch];
  END IF;
  v_branches := COALESCE(v_branches, ARRAY[]::uuid[]);

  SELECT min(created_at) INTO v_on FROM public.action_log
   WHERE org_id = v_org AND action = 'agent.set_enabled' AND ok AND inputs ->> 'agent' = p_agent AND (inputs ->> 'enabled')::boolean IS TRUE;
  IF v_on IS NULL THEN SELECT min(created_at) INTO v_on FROM public.agent_jobs WHERE org_id = v_org AND agent = p_agent; END IF;

  v_cur := public._agent_metrics(v_branches, p_agent, p_from, p_to);
  v_base := CASE WHEN v_on IS NULL THEN NULL ELSE public._agent_metrics(v_branches, p_agent, v_on - interval '28 days', v_on) END;
  SELECT COALESCE(jsonb_object_agg(status, n), '{}'::jsonb) INTO v_jobs FROM (
    SELECT status, count(*) AS n FROM public.agent_jobs WHERE org_id = v_org AND agent = p_agent AND branch_id = ANY (v_branches) AND created_at >= p_from AND created_at < p_to GROUP BY status) x;
  RETURN jsonb_build_object(
    'agent', p_agent, 'from', p_from, 'to', p_to, 'turned_on_at', v_on,
    'current', v_cur, 'baseline', v_base,
    'baseline_note', 'Baseline = the 28 days before the agent was turned on. Confirmed-before-visit counts confirmations made through actions; confirmed_or_attended_pct (confirmed, in progress or completed) is the comparable figure for both periods.',
    'jobs', v_jobs,
    'drafts_waiting', (SELECT count(*) FROM public.agent_work_items w WHERE w.org_id = v_org AND w.agent = p_agent AND w.status = 'open' AND w.branch_id = ANY (v_branches)),
    'undone_by_staff', (SELECT count(*) FROM public.action_log a WHERE a.org_id = v_org AND a.actor_agent = p_agent AND a.undone_by_action IS NOT NULL AND a.created_at >= p_from AND a.created_at < p_to
                          AND (a.branch_id IS NULL OR a.branch_id = ANY (v_branches))));
END $$;

CREATE FUNCTION public.ai_usage_summary(p_month date DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  v_org uuid := public.get_user_org_id(); v_role text := public.get_user_role()::text; v_month date; v_from timestamptz; v_to timestamptz; v_branches uuid[];
  v_amount numeric; v_warn smallint; v_spent_all numeric; v_spent numeric; v_ratio numeric; v_state text; v_confirmed bigint; v_clinic boolean;
BEGIN
  -- the owner and the read-only owner see the clinic; a manager sees their branches (spend, by agent, by branch, cost per visit); staff and practitioners nothing
  IF v_org IS NULL OR v_role NOT IN ('admin', 'admin_viewer', 'manager') THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  v_clinic := v_role IN ('admin', 'admin_viewer');
  v_month := date_trunc('month', COALESCE(p_month, public._ai_month_start()))::date;
  v_from := v_month::timestamp AT TIME ZONE 'Asia/Kathmandu'; v_to := (v_month + interval '1 month')::timestamp AT TIME ZONE 'Asia/Kathmandu';
  IF v_clinic THEN SELECT array_agg(id) INTO v_branches FROM public.branches WHERE org_id = v_org;
  ELSE v_branches := public.get_user_branch_ids(); END IF;
  v_branches := COALESCE(v_branches, ARRAY[]::uuid[]);

  SELECT b.amount_npr, b.warn_pct INTO v_amount, v_warn FROM public.ai_budgets b WHERE b.org_id = v_org AND b.month <= v_month ORDER BY b.month DESC LIMIT 1;
  SELECT COALESCE(sum(cost_npr), 0) INTO v_spent_all FROM public.ai_spend WHERE org_id = v_org AND created_at >= v_from AND created_at < v_to;
  SELECT COALESCE(sum(cost_npr), 0) INTO v_spent FROM public.ai_spend WHERE org_id = v_org AND created_at >= v_from AND created_at < v_to AND (v_clinic OR branch_id = ANY (v_branches));
  -- the budget and its state are the clinic's (a manager must know when AI stops); the figures below are the caller's scope
  IF v_amount IS NULL THEN v_state := 'none';
  ELSIF v_amount = 0 THEN v_state := 'used_up'; v_ratio := 100;
  ELSE v_ratio := v_spent_all / v_amount * 100; v_state := CASE WHEN v_ratio >= 100 THEN 'used_up' WHEN v_ratio >= v_warn THEN 'warn' ELSE 'ok' END; END IF;

  SELECT count(DISTINCT a.target_id) INTO v_confirmed FROM public.action_log a
   WHERE a.org_id = v_org AND a.action = 'booking.set_status' AND a.ok AND a.inputs ->> 'status' = 'Confirmed' AND a.actor_kind = 'agent' AND a.created_at >= v_from AND a.created_at < v_to
     AND (v_clinic OR a.branch_id = ANY (v_branches));
  RETURN jsonb_build_object(
    'month', v_month, 'scope', CASE WHEN v_clinic THEN 'clinic' ELSE 'branches' END, 'spent', v_spent, 'amount', v_amount,
    'pct', CASE WHEN v_ratio IS NULL THEN NULL ELSE round(v_ratio, 2) END, 'state', v_state,
    'by_agent', (SELECT COALESCE(jsonb_agg(jsonb_build_object('agent', agent, 'spent', s) ORDER BY agent), '[]'::jsonb) FROM (
                   SELECT agent, sum(cost_npr) AS s FROM public.ai_spend WHERE org_id = v_org AND created_at >= v_from AND created_at < v_to AND (v_clinic OR branch_id = ANY (v_branches)) GROUP BY agent) x),
    'by_branch', (SELECT COALESCE(jsonb_agg(jsonb_build_object('branch_id', branch_id, 'name', name, 'spent', s) ORDER BY name), '[]'::jsonb) FROM (
                   SELECT sp.branch_id, br.name, sum(sp.cost_npr) AS s FROM public.ai_spend sp JOIN public.branches br ON br.id = sp.branch_id
                    WHERE sp.org_id = v_org AND sp.created_at >= v_from AND sp.created_at < v_to AND sp.branch_id = ANY (v_branches) GROUP BY sp.branch_id, br.name) y),
    'confirmed_by_agent', v_confirmed,
    'cost_per_confirmed_visit', CASE WHEN v_confirmed > 0 THEN round(v_spent / v_confirmed, 4) END);
END $$;

-- 12. grants -----------------------------------------------------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._agent_enqueue(uuid, uuid, text, uuid, uuid, timestamptz, uuid, uuid, text), public._agent_rates(jsonb), public._agent_metrics(uuid[], text, timestamptz, timestamptz),
  public.trg_agent_booking_created(), public.trg_agent_visit_completed(), public.trg_agent_patient_reply(),
  public.agent_scan_day_before(), public.agent_scan_not_confirmed(), public.agent_kick_runner(),
  public.agent_claim_jobs(integer), public.agent_finish_job(uuid, text, jsonb, text), public.agent_get_reply_rules(uuid), public.agent_step_result(uuid, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.agent_claim_jobs(integer), public.agent_finish_job(uuid, text, jsonb, text), public.agent_get_reply_rules(uuid), public.agent_step_result(uuid, text) TO service_role;
REVOKE ALL ON FUNCTION public.agent_scorecard(text, uuid, timestamptz, timestamptz), public.ai_usage_summary(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.agent_scorecard(text, uuid, timestamptz, timestamptz), public.ai_usage_summary(date) TO authenticated, service_role;

COMMIT;
