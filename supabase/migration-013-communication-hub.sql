-- migration-013 (CMD-88): the communication hub, part 1: data model, actions, send and receive.
--
-- Requires 011 (CMD-79) and 012 (CMD-78): uses the practitioner role, get_user_dentist_id(), is_my_booking_row() and the action
-- framework (action_log, _act_finish, act_undo). The three must reach prod in order. NOT applied to production.
-- Prod: rehearse on a prod-schema copy first (CMD-11). Rollback: migration-013-rollback.sql (drops the hub tables: export first).
--
-- WHAT: conversations and messages across channels, consent per address and channel, channel accounts (the gateway is chosen per row),
-- templates, and the actions message.send / message.retry / conversation.take_over / hand_back / assign / handoff / consent.record /
-- message.receive on the 012 framework (one action_log row per call), plus the internal functions the sender and the inbound webhook use.
-- There is NO UI here. Secrets never live in a table: a channel account holds only the NAME of the edge-function env variable (secret_ref).
--
-- CONSENT BACKFILL (Sadin, 2026-11-22; legal check CMD-59 pending): the phone a patient gave when booking counts as 'agreed' for SERVICE
-- messages on SMS (source 'booking'). It runs when this file is applied UNLESS you set, before the file:
--     SET hub.backfill_booking_consent = 'off';
-- It never touches an existing row (so never a stopped one) and never marketing. hub_backfill_booking_consent(org, dry_run) can be
-- run later; counts are reported in a NOTICE. New patients after this migration get no consent until it is recorded (booking flow ticket).
--
-- When the agent platform lands, approved_by can also be satisfied by the playbook's autonomy level; see PRODUCT-BRIEF §7.5.

BEGIN;

-- 1. tables -----------------------------------------------------------------------------------------------------------------
CREATE TABLE public.channel_accounts (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.organizations(id),
  branch_id        uuid REFERENCES public.branches(id),          -- NULL = the whole organization
  channel          text NOT NULL CHECK (channel IN ('sms', 'whatsapp', 'viber', 'messenger', 'email')),
  provider         text NOT NULL,                                 -- 'test', 'aakash'; Bird or others later. Not a CHECK: a new gateway needs no migration
  sender           text NOT NULL,                                 -- the public identifier (number, sender name, page id); never a secret
  status           text NOT NULL DEFAULT 'not_connected' CHECK (status IN ('not_connected', 'connected', 'error')),
  quiet_start      time,                                          -- quiet hours in the organization's timezone; both null = none; may wrap midnight
  quiet_end        time,
  priority         smallint NOT NULL DEFAULT 100,                 -- the clinic's fallback order: lower is tried first
  secret_ref       text,                                          -- NAME of the edge env variable holding the key (never the key)
  credit_cost_npr  numeric(10,4),                                 -- price of one provider credit, so cost_npr = credits x this
  last_polled_at   timestamptz,                                   -- the delivery-report poller (providers that only offer pull)
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT channel_accounts_quiet_pair CHECK ((quiet_start IS NULL) = (quiet_end IS NULL)),
  CONSTRAINT channel_accounts_provider_sender_key UNIQUE (provider, sender)
);

-- Consent is keyed by ADDRESS (the number or handle), so a STOP from a number that is not a patient yet is not lost: if that number later
-- books, the row is linked to the new patient and the STOP still applies.
CREATE TABLE public.patient_channels (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.organizations(id),
  customer_id  uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  channel      text NOT NULL CHECK (channel IN ('sms', 'whatsapp', 'viber', 'messenger', 'email')),
  address      text NOT NULL,
  purpose      text NOT NULL CHECK (purpose IN ('service', 'marketing')),
  status       text NOT NULL CHECK (status IN ('agreed', 'not_asked', 'stopped')),
  source       text NOT NULL CHECK (source IN ('booking', 'front_desk', 'patient_reply', 'import')),
  recorded_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  recorded_at  timestamptz NOT NULL DEFAULT now(),
  evidence     text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT patient_channels_address_key UNIQUE (org_id, channel, address, purpose)
);
CREATE INDEX idx_patient_channels_customer ON public.patient_channels (customer_id);

CREATE TABLE public.conversations (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.organizations(id),
  branch_id          uuid REFERENCES public.branches(id),          -- NULL only for an unknown number on an organization-wide account
  channel            text NOT NULL CHECK (channel IN ('sms', 'whatsapp', 'viber', 'messenger', 'email')),
  address            text NOT NULL,
  channel_account_id uuid REFERENCES public.channel_accounts(id) ON DELETE SET NULL,
  customer_id        uuid REFERENCES public.customers(id) ON DELETE SET NULL,   -- NULL = "No patient match"
  state              text NOT NULL DEFAULT 'agent' CHECK (state IN ('agent', 'needs_person', 'person', 'closed')),
  handled_by         uuid REFERENCES public.users(id) ON DELETE SET NULL,
  assigned_to        uuid REFERENCES public.users(id) ON DELETE SET NULL,
  assigned_by        uuid REFERENCES public.users(id) ON DELETE SET NULL,
  assigned_at        timestamptz,
  assign_note        text,
  handoff_reason     text CHECK (handoff_reason IN ('urgent', 'clinical', 'discount', 'complaint', 'asks_to_change', 'unclear', 'other')),
  handoff_summary    text,
  urgent             boolean NOT NULL DEFAULT false,
  practitioner_id    uuid REFERENCES public.dentists(id) ON DELETE SET NULL,
  needs_person_since timestamptz,
  language           text NOT NULL DEFAULT 'en',
  last_message_at    timestamptz,
  last_inbound_at    timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
-- one thread per organization, channel, address and branch (NULL branches count as one)
CREATE UNIQUE INDEX conversations_thread_key ON public.conversations (org_id, channel, address, COALESCE(branch_id, '00000000-0000-0000-0000-000000000000'::uuid));
CREATE INDEX idx_conversations_branch_state ON public.conversations (branch_id, state, last_message_at DESC);
CREATE INDEX idx_conversations_customer ON public.conversations (customer_id);
CREATE INDEX idx_conversations_needs_person ON public.conversations (org_id, needs_person_since) WHERE state = 'needs_person';

CREATE TABLE public.conversation_reads (
  conversation_id uuid NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  last_read_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_id)
);

CREATE TABLE public.message_templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.organizations(id),
  name        text NOT NULL,
  channel     text CHECK (channel IN ('sms', 'whatsapp', 'viber', 'messenger', 'email')),   -- NULL = any channel
  language    text NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'ne')),
  body        text NOT NULL,                                       -- with {fields}: patient_name, clinic, branch, date, time, dentist, treatment
  purpose     text NOT NULL DEFAULT 'service' CHECK (purpose IN ('service', 'marketing')),
  clinical    boolean NOT NULL DEFAULT false,                      -- only a person with a practitioner profile, on their own patient, may send one
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX message_templates_name_key ON public.message_templates (org_id, name, language, COALESCE(channel, 'any'));

CREATE TABLE public.messages (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL REFERENCES public.organizations(id),
  conversation_id     uuid NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  direction           text NOT NULL CHECK (direction IN ('in', 'out')),
  kind                text NOT NULL DEFAULT 'message' CHECK (kind IN ('message', 'event')),   -- events are the timeline lines ("Anita took over")
  event_type          text CHECK (event_type IN ('took_over', 'handed_back', 'handed_back_undone', 'assigned', 'handoff', 'stop_recorded', 'start_recorded', 'consent_recorded')),
  body                text NOT NULL,
  meta                jsonb NOT NULL DEFAULT '{}'::jsonb,           -- retry_of, opt_out_confirmation, event details
  language            text,
  author_kind         text NOT NULL CHECK (author_kind IN ('patient', 'person', 'agent', 'rule', 'system')),
  author_user_id      uuid REFERENCES public.users(id) ON DELETE SET NULL,
  author_agent        text,
  template_id         uuid REFERENCES public.message_templates(id) ON DELETE SET NULL,
  purpose             text CHECK (purpose IN ('service', 'marketing')),
  status              text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sending', 'sent', 'delivered', 'read', 'failed', 'cancelled')),
  channel_account_id  uuid REFERENCES public.channel_accounts(id) ON DELETE SET NULL,
  provider            text,
  provider_message_id text,
  error               text,
  credits             numeric(10,2),
  cost_npr            numeric(10,4),
  scheduled_for       timestamptz NOT NULL DEFAULT now(),
  sent_at             timestamptz,
  delivered_at        timestamptz,
  action_id           uuid REFERENCES public.action_log(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_messages_conversation ON public.messages (conversation_id, created_at);
CREATE INDEX idx_messages_due ON public.messages (scheduled_for) WHERE status IN ('queued', 'sending');
CREATE INDEX idx_messages_provider_id ON public.messages (provider, provider_message_id) WHERE provider_message_id IS NOT NULL;
CREATE INDEX idx_messages_sent_poll ON public.messages (channel_account_id, sent_at) WHERE status = 'sent';
-- a webhook retry must not insert the same inbound message twice
CREATE UNIQUE INDEX messages_inbound_dedupe ON public.messages (channel_account_id, provider_message_id)
  WHERE direction = 'in' AND provider_message_id IS NOT NULL;

-- what the TEST provider "sent" (local development): service role only
CREATE TABLE public.hub_test_outbox (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id  uuid NOT NULL,
  to_address  text NOT NULL,
  body        text NOT NULL,
  state       text NOT NULL DEFAULT 'accepted',
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- per-account inbound counters for the rate limit (accepted and dropped per minute)
CREATE TABLE public.hub_inbound_rate (
  channel_account_id uuid NOT NULL REFERENCES public.channel_accounts(id) ON DELETE CASCADE,
  bucket             timestamptz NOT NULL,
  accepted           integer NOT NULL DEFAULT 0,
  dropped            integer NOT NULL DEFAULT 0,
  PRIMARY KEY (channel_account_id, bucket)
);

-- patients' bookings are looked up by customer: there was no index for it
CREATE INDEX IF NOT EXISTS idx_bookings_customer ON public.bookings (customer_id);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['channel_accounts', 'patient_channels', 'conversations', 'message_templates', 'messages'] LOOP
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.update_updated_at()', t, t);
  END LOOP;
END $$;

-- 2. who can read what (helpers: one source of truth for the policies and for hub_mark_read) --------------------------------------
-- "Mine": the patient has at least one booking whose dentist (bookings.dentist_id or booking_dentists) is my practitioner profile.
CREATE FUNCTION public.is_my_patient(p_customer uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT COALESCE(
    p_customer IS NOT NULL
    AND public.get_user_dentist_id() IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.bookings b JOIN public.customers c ON c.id = b.customer_id
       WHERE b.customer_id = p_customer AND c.org_id = public.get_user_org_id()
         AND (b.dentist_id = public.get_user_dentist_id()
              OR EXISTS (SELECT 1 FROM public.booking_dentists bd WHERE bd.booking_id = b.id AND bd.dentist_id = public.get_user_dentist_id()))
    ), false);   -- strictly true / false, never NULL
$$;
REVOKE ALL ON FUNCTION public.is_my_patient(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_my_patient(uuid) TO authenticated;

-- Conversations: admin / admin_viewer the whole org; staff and manager their branches PLUS threads with no branch yet (an unknown number:
-- anyone on the front desk can triage it); a practitioner only the threads of their own patients.
CREATE FUNCTION public.hub_can_read_conversation(p_org uuid, p_branch uuid, p_customer uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT COALESCE(
    p_org = public.get_user_org_id()
    AND (
      public.get_user_role()::text IN ('admin', 'admin_viewer')
      OR (public.get_user_role()::text IN ('staff', 'manager') AND (p_branch IS NULL OR p_branch = ANY (public.get_user_branch_ids())))
      OR (public.get_user_role()::text = 'practitioner' AND public.is_my_patient(p_customer))
    ), false);
$$;
REVOKE ALL ON FUNCTION public.hub_can_read_conversation(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hub_can_read_conversation(uuid, uuid, uuid) TO authenticated;

-- Consent rows: by the linked patient's branch; rows with no patient yet are for admin and manager only.
CREATE FUNCTION public.hub_can_read_consent(p_org uuid, p_customer uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT COALESCE(
    p_org = public.get_user_org_id()
    AND (
      public.get_user_role()::text IN ('admin', 'admin_viewer')
      OR (public.get_user_role()::text IN ('staff', 'manager') AND p_customer IS NOT NULL
          AND (SELECT c.branch_id FROM public.customers c WHERE c.id = p_customer) = ANY (public.get_user_branch_ids()))
      OR (public.get_user_role()::text = 'manager' AND p_customer IS NULL)
      OR (public.get_user_role()::text = 'practitioner' AND public.is_my_patient(p_customer))
    ), false);
$$;
REVOKE ALL ON FUNCTION public.hub_can_read_consent(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hub_can_read_consent(uuid, uuid) TO authenticated;

-- 3. RLS: read only for the API roles; every write goes through an action ------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['channel_accounts', 'patient_channels', 'conversations', 'conversation_reads', 'message_templates', 'messages', 'hub_test_outbox', 'hub_inbound_rate'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated, service_role', t);
  END LOOP;
END $$;
GRANT SELECT ON public.channel_accounts, public.patient_channels, public.conversations, public.conversation_reads, public.message_templates, public.messages TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON public.hub_test_outbox TO service_role;   -- the test provider (edge function) writes its local log

CREATE POLICY channel_accounts_read ON public.channel_accounts FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id()
         AND (public.get_user_role()::text IN ('admin', 'admin_viewer')
              OR (public.get_user_role()::text IN ('staff', 'manager') AND (branch_id IS NULL OR branch_id = ANY (public.get_user_branch_ids())))));
CREATE POLICY patient_channels_read ON public.patient_channels FOR SELECT TO authenticated
  USING (public.hub_can_read_consent(org_id, customer_id));
CREATE POLICY conversations_read ON public.conversations FOR SELECT TO authenticated
  USING (public.hub_can_read_conversation(org_id, branch_id, customer_id));
CREATE POLICY messages_read ON public.messages FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id()
         AND EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = messages.conversation_id));   -- the conversation's own policy applies
CREATE POLICY message_templates_read ON public.message_templates FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id() AND public.get_user_role() IS NOT NULL);
CREATE POLICY conversation_reads_read ON public.conversation_reads FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- Live Inbox through Realtime (RLS applies to the stream)
DO $$
DECLARE t text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    FOREACH t IN ARRAY ARRAY['conversations', 'messages'] LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t) THEN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
      END IF;
    END LOOP;
  END IF;
END $$;

-- 4. internal helpers (callable by nobody but the function owner) --------------------------------------------------------------------
CREATE FUNCTION public._hub_scope(p_ctx jsonb, p_org uuid, p_branch uuid, p_customer uuid) RETURNS boolean
    LANGUAGE sql STABLE SET search_path = public
    AS $$
  SELECT COALESCE(
    p_org = (p_ctx ->> 'org_id')::uuid
    AND CASE
      WHEN (p_ctx ->> 'service')::boolean THEN (p_ctx ->> 'branch_id') IS NULL OR p_branch IS NULL OR (p_ctx ->> 'branch_id')::uuid = p_branch
      WHEN p_ctx ->> 'role' IN ('admin', 'admin_viewer') THEN true
      WHEN p_ctx ->> 'role' = 'practitioner' THEN public.is_my_patient(p_customer)
      ELSE p_branch IS NULL OR COALESCE(p_ctx -> 'branch_ids', '[]'::jsonb) ? p_branch::text   -- no branch yet: any front desk may triage
    END, false);   -- strictly true / false
$$;

CREATE FUNCTION public._hub_fail(p_code text, p_message text, p_branch uuid DEFAULT NULL, p_target uuid DEFAULT NULL) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    AS $$ SELECT jsonb_build_object('ok', false, 'code', p_code, 'message', p_message, 'branch_id', p_branch, 'target_id', p_target) $$;

CREATE FUNCTION public._hub_user_name(p_user uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$ SELECT COALESCE((SELECT full_name FROM public.users WHERE id = p_user), 'Someone') $$;

-- A timeline line in the thread ("Anita took over"). Events never bump last_message_at and are never sent.
CREATE FUNCTION public._hub_event(p_conv uuid, p_type text, p_body text, p_meta jsonb, p_author_kind text, p_author_user uuid, p_author_agent text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.messages (org_id, conversation_id, direction, kind, event_type, body, meta, author_kind, author_user_id, author_agent, status)
  SELECT c.org_id, c.id, 'out', 'event', p_type, p_body, COALESCE(p_meta, '{}'::jsonb), p_author_kind, p_author_user, p_author_agent, 'delivered'
    FROM public.conversations c WHERE c.id = p_conv
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- The end of the quiet window the account is in at p_at (in the organization's timezone), or NULL when not in quiet hours.
CREATE FUNCTION public._hub_quiet_end(p_acc public.channel_accounts, p_at timestamptz) RETURNS timestamptz
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_tz text; v_t time; v_d date;
BEGIN
  IF p_acc.quiet_start IS NULL OR p_acc.quiet_end IS NULL OR p_acc.quiet_start = p_acc.quiet_end THEN RETURN NULL; END IF;
  v_tz := COALESCE((SELECT timezone FROM public.organizations WHERE id = p_acc.org_id), 'Asia/Kathmandu');
  v_t := (p_at AT TIME ZONE v_tz)::time;
  v_d := (p_at AT TIME ZONE v_tz)::date;
  IF p_acc.quiet_start < p_acc.quiet_end THEN
    IF v_t >= p_acc.quiet_start AND v_t < p_acc.quiet_end THEN RETURN (v_d + p_acc.quiet_end) AT TIME ZONE v_tz; END IF;
  ELSE   -- the window wraps midnight (for example 21:00-07:00)
    IF v_t >= p_acc.quiet_start THEN RETURN ((v_d + 1) + p_acc.quiet_end) AT TIME ZONE v_tz; END IF;
    IF v_t < p_acc.quiet_end THEN RETURN (v_d + p_acc.quiet_end) AT TIME ZONE v_tz; END IF;
  END IF;
  RETURN NULL;
END $$;

CREATE FUNCTION public._hub_consent(p_org uuid, p_channel text, p_address text, p_purpose text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT COALESCE((SELECT status FROM public.patient_channels WHERE org_id = p_org AND channel = p_channel AND address = p_address AND purpose = p_purpose), 'not_asked')
$$;

-- Fills {fields}. A placeholder with no value is reported, never sent as a literal "{x}".
CREATE FUNCTION public._hub_render(p_body text, p_fields jsonb, OUT result text, OUT missing text[]) RETURNS record
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE k text;
BEGIN
  result := p_body; missing := ARRAY[]::text[];
  FOR k IN SELECT DISTINCT m[1] FROM regexp_matches(p_body, '\{([a-z_]+)\}', 'g') AS m LOOP
    IF p_fields ->> k IS NULL THEN missing := missing || k;
    ELSE result := replace(result, '{' || k || '}', p_fields ->> k);
    END IF;
  END LOOP;
END $$;

-- The standard fields, filled by code from a booking (null when the booking is not in the organization).
CREATE FUNCTION public._hub_booking_fields(p_booking uuid, p_org uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'patient_name', b.customer_name,
    'clinic', o.name,
    'branch', br.name,
    'date', to_char(b.date, 'FMDD Mon YYYY'),
    'time', to_char(b.start_time, 'FMHH12:MI AM'),
    'dentist', COALESCE(b.dentist_name_snapshot, (SELECT d.name FROM public.dentists d WHERE d.id = b.dentist_id)),
    'treatment', COALESCE(b.treatment_name_snapshot, (SELECT t.name FROM public.treatments t WHERE t.id = b.treatment_id))))
  FROM public.bookings b
  JOIN public.branches br ON br.id = b.branch_id
  JOIN public.organizations o ON o.id = br.org_id
  WHERE b.id = p_booking AND br.org_id = p_org
$$;

-- 5. send: the shared core behind message.send and message.retry ---------------------------------------------------------------------
-- Returns { ok:false, code, message, branch_id, target_id } or { ok:true, org_id, branch_id, target_id, data }. It checks (in this order)
-- who may send, the template, the clinical rule, who needs approval, the channel and consent, the text, quiet hours; then it queues one
-- message. The sender worker (hub-send) delivers it.
CREATE FUNCTION public._hub_send_core(ctx jsonb, p_conversation uuid, p_customer uuid, p_channel text, p_template uuid, p_text text, p_fields jsonb,
                                      p_purpose text, p_booking uuid, p_language text, p_on_quiet text, p_retry_of uuid, p_body_override text)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  conv public.conversations; cust public.customers; acc public.channel_accounts; tpl public.message_templates; bk record; picked public.channel_accounts;
  v_org uuid := (ctx ->> 'org_id')::uuid; v_kind text := ctx ->> 'kind'; v_user uuid := (ctx ->> 'user_id')::uuid;
  v_branch uuid; v_address text; v_picked_address text; v_purpose text; v_body text; v_lang text; v_cons text;
  v_have_account boolean := false; v_stopped boolean := false; v_nocons boolean := false; v_noaddr boolean := false;
  v_fields jsonb; v_render record; v_sched timestamptz := now(); v_quiet_end timestamptz; v_msg uuid; v_conv uuid;
  v_clinical boolean := false; v_approved boolean := (ctx ->> 'approved_by') IS NOT NULL; v_cust_id uuid; v_new_state text;
  v_has_profile boolean; v_conv_state text;
BEGIN
  IF (p_conversation IS NULL) = (p_customer IS NULL) THEN
    RETURN public._hub_fail('INVALID_INPUT', 'Give either a conversation or a patient.');
  END IF;
  IF p_body_override IS NULL AND ((p_template IS NULL) = (p_text IS NULL)) THEN
    RETURN public._hub_fail('INVALID_INPUT', 'Give either a template or a text.');
  END IF;
  IF p_on_quiet NOT IN ('refuse', 'defer') OR p_purpose NOT IN ('service', 'marketing') THEN
    RETURN public._hub_fail('INVALID_INPUT', 'on_quiet_hours must be refuse or defer, and purpose service or marketing.');
  END IF;

  -- the subject: an existing thread, or a patient
  IF p_conversation IS NOT NULL THEN
    SELECT * INTO conv FROM public.conversations WHERE id = p_conversation;
    IF conv.id IS NULL OR NOT public._hub_scope(ctx, conv.org_id, conv.branch_id, conv.customer_id) THEN
      RETURN public._hub_fail('CONVERSATION_NOT_FOUND', 'Conversation not found.');
    END IF;
    v_branch := conv.branch_id; v_cust_id := conv.customer_id; v_address := conv.address; v_lang := COALESCE(p_language, conv.language, 'en');
    IF p_channel IS NOT NULL AND p_channel <> conv.channel THEN
      RETURN public._hub_fail('INVALID_INPUT', 'This thread is on another channel.', v_branch, conv.id);
    END IF;
  ELSE
    SELECT * INTO cust FROM public.customers WHERE id = p_customer;
    IF cust.id IS NULL OR cust.org_id <> v_org THEN RETURN public._hub_fail('PATIENT_NOT_FOUND', 'Patient not found.'); END IF;
    v_branch := cust.branch_id; v_cust_id := cust.id; v_lang := COALESCE(p_language, 'en');
  END IF;

  IF p_booking IS NOT NULL THEN
    SELECT b.id, b.branch_id, b.customer_id INTO bk FROM public.bookings b JOIN public.branches br ON br.id = b.branch_id WHERE b.id = p_booking AND br.org_id = v_org;
    IF bk.id IS NULL OR (v_cust_id IS NOT NULL AND bk.customer_id IS DISTINCT FROM v_cust_id) THEN
      RETURN public._hub_fail('INVALID_INPUT', 'That booking does not belong to this patient.', v_branch);
    END IF;
    IF p_conversation IS NULL THEN v_branch := bk.branch_id; END IF;
  END IF;

  IF p_conversation IS NULL AND NOT public._hub_scope(ctx, v_org, v_branch, v_cust_id) THEN
    RETURN public._hub_fail('PATIENT_NOT_FOUND', 'Patient not found.');
  END IF;

  -- who may send
  IF v_kind = 'person' THEN
    IF ctx ->> 'role' NOT IN ('staff', 'manager', 'admin', 'practitioner') THEN
      RETURN public._hub_fail('FORBIDDEN', 'Your role cannot send messages.', v_branch, conv.id);
    END IF;
  ELSIF v_kind NOT IN ('agent', 'rule') THEN
    RETURN public._hub_fail('FORBIDDEN', 'This kind of caller cannot send messages.', v_branch, conv.id);
  END IF;

  -- the template (or the text), the purpose, the clinical rule
  v_purpose := p_purpose;
  IF p_template IS NOT NULL THEN
    SELECT * INTO tpl FROM public.message_templates WHERE id = p_template AND org_id = v_org AND active;
    IF tpl.id IS NULL THEN RETURN public._hub_fail('TEMPLATE_NOT_FOUND', 'Template not found.', v_branch, conv.id); END IF;
    IF p_language IS NOT NULL AND tpl.language <> p_language THEN
      SELECT * INTO tpl FROM public.message_templates t
       WHERE t.org_id = v_org AND t.name = tpl.name AND t.language = p_language AND t.active AND COALESCE(t.channel, '') = COALESCE(tpl.channel, '') LIMIT 1;
      IF tpl.id IS NULL THEN RETURN public._hub_fail('TEMPLATE_NOT_FOUND', 'That template has no ' || p_language || ' version.', v_branch, conv.id); END IF;
    END IF;
    v_purpose := tpl.purpose; v_clinical := tpl.clinical;
    v_lang := tpl.language;
  END IF;

  IF v_clinical THEN
    SELECT (u.dentist_id IS NOT NULL) INTO v_has_profile FROM public.users u WHERE u.id = v_user;
    IF v_kind <> 'person' OR NOT COALESCE(v_has_profile, false) OR NOT public.is_my_patient(v_cust_id) THEN
      RETURN public._hub_fail('CLINICAL_TEMPLATE', 'A clinical message can only be sent by the practitioner who sees this patient.', v_branch, conv.id);
    END IF;
  END IF;

  IF v_kind = 'agent' THEN
    IF NOT (p_template IS NOT NULL AND v_purpose = 'service' AND NOT v_clinical) AND NOT v_approved THEN
      RETURN public._hub_fail('APPROVAL_REQUIRED', 'Only a service message from a template can be sent without a person''s approval.', v_branch, conv.id);
    END IF;
  ELSIF v_kind = 'rule' THEN
    IF NOT (p_template IS NOT NULL AND v_purpose = 'service' AND NOT v_clinical) THEN
      RETURN public._hub_fail('FORBIDDEN', 'A rule can only send a service message from a template.', v_branch, conv.id);
    END IF;
  END IF;

  -- the channel and the consent
  FOR acc IN
    SELECT a.* FROM public.channel_accounts a
     WHERE a.org_id = v_org AND a.status = 'connected'
       AND CASE WHEN p_conversation IS NOT NULL THEN a.channel = conv.channel ELSE (p_channel IS NULL OR a.channel = p_channel) END
       AND (tpl.channel IS NULL OR a.channel = tpl.channel)
       AND (a.branch_id IS NULL OR v_branch IS NULL OR a.branch_id = v_branch)
     ORDER BY (a.id = conv.channel_account_id) DESC NULLS LAST, a.priority, (a.branch_id IS NULL), a.created_at
  LOOP
    v_have_account := true;
    IF p_conversation IS NOT NULL THEN v_picked_address := v_address;
    ELSIF acc.channel IN ('sms', 'whatsapp') THEN v_picked_address := public.normalize_phone_e164(cust.phone);
    ELSIF acc.channel = 'email' THEN v_picked_address := lower(NULLIF(btrim(cust.email), ''));
    ELSE v_picked_address := NULL;
    END IF;
    IF v_picked_address IS NULL THEN v_noaddr := true; CONTINUE; END IF;
    v_cons := public._hub_consent(v_org, acc.channel, v_picked_address, v_purpose);
    IF v_cons = 'agreed' THEN picked := acc; v_address := v_picked_address; EXIT;
    ELSIF v_cons = 'stopped' THEN v_stopped := true;
    ELSE v_nocons := true;
    END IF;
  END LOOP;
  IF picked.id IS NULL THEN
    IF NOT v_have_account THEN RETURN public._hub_fail('CHANNEL_NOT_CONNECTED', 'No connected channel for this message.', v_branch, conv.id); END IF;
    IF v_stopped AND NOT v_nocons THEN RETURN public._hub_fail('STOPPED', 'The patient replied STOP on this channel.', v_branch, conv.id); END IF;
    IF v_nocons OR v_stopped THEN RETURN public._hub_fail('NO_CONSENT', 'The patient has not agreed to ' || v_purpose || ' messages on this channel.', v_branch, conv.id); END IF;
    RETURN public._hub_fail('NO_ADDRESS', 'The patient has no phone number or address for this channel.', v_branch, conv.id);
  END IF;

  -- the text
  IF p_body_override IS NOT NULL THEN
    v_body := p_body_override;
  ELSIF p_template IS NOT NULL THEN
    v_fields := COALESCE(public._hub_booking_fields(p_booking, v_org), '{}'::jsonb) || COALESCE(p_fields, '{}'::jsonb);
    IF cust.id IS NOT NULL AND v_fields ->> 'patient_name' IS NULL THEN v_fields := v_fields || jsonb_build_object('patient_name', cust.full_name); END IF;
    IF v_fields ->> 'clinic' IS NULL THEN v_fields := v_fields || jsonb_build_object('clinic', (SELECT name FROM public.organizations WHERE id = v_org)); END IF;
    SELECT * INTO v_render FROM public._hub_render(tpl.body, v_fields);
    IF array_length(v_render.missing, 1) > 0 THEN
      RETURN public._hub_fail('TEMPLATE_FIELD_MISSING', 'Missing value for: ' || array_to_string(v_render.missing, ', ') || '.', v_branch, conv.id);
    END IF;
    v_body := v_render.result;
  ELSE
    v_body := btrim(p_text);
    IF v_body = '' OR length(v_body) > 1000 THEN RETURN public._hub_fail('INVALID_INPUT', 'The text must be 1 to 1000 characters.', v_branch, conv.id); END IF;
  END IF;

  -- quiet hours
  v_quiet_end := public._hub_quiet_end(picked, now());
  IF v_quiet_end IS NOT NULL THEN
    IF p_on_quiet = 'refuse' THEN
      RETURN public._hub_fail('QUIET_HOURS', 'Quiet hours until ' || to_char(v_quiet_end AT TIME ZONE COALESCE((SELECT timezone FROM public.organizations WHERE id = v_org), 'Asia/Kathmandu'), 'HH24:MI') || '.', v_branch, conv.id);
    END IF;
    v_sched := v_quiet_end;
  END IF;

  -- the thread, then the queued message
  IF p_conversation IS NOT NULL THEN
    v_conv := conv.id; v_conv_state := conv.state;
  ELSE
    SELECT c.id, c.state INTO v_conv, v_conv_state FROM public.conversations c
     WHERE c.org_id = v_org AND c.channel = picked.channel AND c.address = v_address
       AND COALESCE(c.branch_id, '00000000-0000-0000-0000-000000000000'::uuid) = COALESCE(v_branch, '00000000-0000-0000-0000-000000000000'::uuid);
    IF v_conv IS NULL THEN
      v_new_state := CASE WHEN v_kind = 'person' THEN 'person' ELSE 'agent' END;
      INSERT INTO public.conversations (org_id, branch_id, channel, address, channel_account_id, customer_id, state, handled_by, language)
      VALUES (v_org, v_branch, picked.channel, v_address, picked.id, v_cust_id, v_new_state, CASE WHEN v_kind = 'person' THEN v_user END, v_lang)
      RETURNING id INTO v_conv;
      v_conv_state := v_new_state;
    END IF;
  END IF;

  INSERT INTO public.messages (org_id, conversation_id, direction, kind, body, meta, language, author_kind, author_user_id, author_agent, template_id, purpose,
                               status, channel_account_id, provider, scheduled_for)
  VALUES (v_org, v_conv, 'out', 'message', v_body, CASE WHEN p_retry_of IS NOT NULL THEN jsonb_build_object('retry_of', p_retry_of) ELSE '{}'::jsonb END,
          v_lang, CASE v_kind WHEN 'person' THEN 'person' ELSE v_kind END, v_user, ctx ->> 'agent', p_template, v_purpose,
          'queued', picked.id, picked.provider, v_sched)
  RETURNING id INTO v_msg;

  UPDATE public.conversations
     SET last_message_at = now(),
         state = CASE WHEN state = 'closed' THEN CASE WHEN v_kind = 'person' THEN 'person' ELSE 'agent' END ELSE state END,
         handled_by = CASE WHEN state = 'closed' AND v_kind = 'person' THEN v_user ELSE handled_by END,
         needs_person_since = CASE WHEN state = 'closed' THEN NULL ELSE needs_person_since END
   WHERE id = v_conv;

  RETURN jsonb_build_object('ok', true, 'org_id', v_org, 'branch_id', v_branch, 'target_id', v_conv,
    'data', jsonb_build_object('message_id', v_msg, 'conversation_id', v_conv, 'channel', picked.channel, 'scheduled_for', v_sched,
                               'deferred', v_sched > now(), 'retry_of', p_retry_of));
END $$;

-- 6. message.send ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION public.act_message_send(p_conversation uuid DEFAULT NULL, p_customer uuid DEFAULT NULL, p_channel text DEFAULT NULL, p_template uuid DEFAULT NULL,
                                        p_text text DEFAULT NULL, p_fields jsonb DEFAULT '{}'::jsonb, p_purpose text DEFAULT 'service', p_booking uuid DEFAULT NULL,
                                        p_language text DEFAULT NULL, p_on_quiet_hours text DEFAULT 'refuse', p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; r jsonb; v_inputs jsonb; res jsonb;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('conversation_id', p_conversation, 'customer_id', p_customer, 'channel', p_channel, 'template_id', p_template,
                                 'text_length', length(p_text), 'fields', p_fields, 'purpose', p_purpose, 'booking_id', p_booking, 'language', p_language,
                                 'on_quiet_hours', p_on_quiet_hours) || public._act_ctx_inputs(p_ctx, ctx);
  r := public._hub_send_core(ctx, p_conversation, p_customer, p_channel, p_template, p_text, COALESCE(p_fields, '{}'::jsonb), COALESCE(p_purpose, 'service'),
                             p_booking, p_language, COALESCE(p_on_quiet_hours, 'refuse'), NULL, NULL);
  IF (r ->> 'ok')::boolean THEN
    res := public._act_finish(ctx, 'message.send', (r ->> 'org_id')::uuid, (r ->> 'branch_id')::uuid, v_inputs, true, r -> 'data', NULL, NULL, (r ->> 'target_id')::uuid, NULL, 'conversations');
    UPDATE public.messages SET action_id = (res ->> 'action_id')::uuid WHERE id = (r #>> '{data,message_id}')::uuid;
    RETURN res;
  END IF;
  RETURN public._act_finish(ctx, 'message.send', (ctx ->> 'org_id')::uuid, (r ->> 'branch_id')::uuid, v_inputs, false, NULL, r ->> 'code', r ->> 'message', (r ->> 'target_id')::uuid, NULL, 'conversations');
END $$;

-- 7. message.retry: a NEW message linked to the failed one (meta.retry_of); the old row is never re-sent ---------------------------------
CREATE FUNCTION public.act_message_retry(p_message uuid, p_channel text DEFAULT NULL, p_on_quiet_hours text DEFAULT 'refuse', p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; m public.messages; conv public.conversations; r jsonb; v_inputs jsonb; res jsonb; v_same boolean; v_tpl public.message_templates;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('message_id', p_message, 'channel', p_channel, 'on_quiet_hours', p_on_quiet_hours) || public._act_ctx_inputs(p_ctx, ctx);

  SELECT * INTO m FROM public.messages WHERE id = p_message AND org_id = (ctx ->> 'org_id')::uuid AND kind = 'message' AND direction = 'out';
  IF m.id IS NOT NULL THEN SELECT * INTO conv FROM public.conversations WHERE id = m.conversation_id; END IF;
  IF m.id IS NULL OR conv.id IS NULL OR NOT public._hub_scope(ctx, conv.org_id, conv.branch_id, conv.customer_id) THEN
    RETURN public._act_finish(ctx, 'message.retry', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'MESSAGE_NOT_FOUND', 'Message not found.', NULL, NULL, 'conversations');
  END IF;
  IF m.status <> 'failed' THEN
    RETURN public._act_finish(ctx, 'message.retry', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'NOT_FAILED', 'Only a message that failed can be retried.', conv.id, NULL, 'conversations');
  END IF;
  IF EXISTS (SELECT 1 FROM public.messages x WHERE x.org_id = conv.org_id AND x.meta ->> 'retry_of' = p_message::text AND x.status NOT IN ('failed', 'cancelled')) THEN
    RETURN public._act_finish(ctx, 'message.retry', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'ALREADY_RETRIED', 'This message was already retried.', conv.id, NULL, 'conversations');
  END IF;

  v_same := p_channel IS NULL OR p_channel = conv.channel;
  IF NOT v_same AND conv.customer_id IS NULL THEN
    RETURN public._act_finish(ctx, 'message.retry', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'INVALID_INPUT', 'An unknown number cannot be reached on another channel.', conv.id, NULL, 'conversations');
  END IF;
  -- an agent may retry without approval only what it could have sent without approval; the old text is sent as it was (not re-rendered)
  IF m.template_id IS NOT NULL THEN SELECT * INTO v_tpl FROM public.message_templates WHERE id = m.template_id; END IF;
  r := public._hub_send_core(ctx, CASE WHEN v_same THEN conv.id END, CASE WHEN v_same THEN NULL ELSE conv.customer_id END, CASE WHEN v_same THEN NULL ELSE p_channel END,
                             CASE WHEN v_tpl.id IS NOT NULL AND v_tpl.active THEN v_tpl.id END, NULL, '{}'::jsonb, COALESCE(m.purpose, 'service'), NULL, m.language,
                             COALESCE(p_on_quiet_hours, 'refuse'), m.id, m.body);
  IF (r ->> 'ok')::boolean THEN
    res := public._act_finish(ctx, 'message.retry', (r ->> 'org_id')::uuid, (r ->> 'branch_id')::uuid, v_inputs, true, r -> 'data', NULL, NULL, (r ->> 'target_id')::uuid, NULL, 'conversations');
    UPDATE public.messages SET action_id = (res ->> 'action_id')::uuid WHERE id = (r #>> '{data,message_id}')::uuid;
    RETURN res;
  END IF;
  RETURN public._act_finish(ctx, 'message.retry', conv.org_id, conv.branch_id, v_inputs, false, NULL, r ->> 'code', r ->> 'message', conv.id, NULL, 'conversations');
END $$;

-- 8. conversation.take_over / hand_back / assign / handoff ----------------------------------------------------------------------------
CREATE FUNCTION public.act_conversation_take_over(p_conversation uuid, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; conv public.conversations; v_inputs jsonb; res jsonb; v_ev uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('conversation_id', p_conversation) || public._act_ctx_inputs(p_ctx, ctx);
  SELECT * INTO conv FROM public.conversations WHERE id = p_conversation FOR UPDATE;
  IF conv.id IS NULL OR NOT public._hub_scope(ctx, conv.org_id, conv.branch_id, conv.customer_id) THEN
    RETURN public._act_finish(ctx, 'conversation.take_over', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'CONVERSATION_NOT_FOUND', 'Conversation not found.', p_conversation, NULL, 'conversations');
  END IF;
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('staff', 'manager', 'admin', 'practitioner') THEN
    RETURN public._act_finish(ctx, 'conversation.take_over', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Only a person on the team can take over a conversation.', conv.id, NULL, 'conversations');
  END IF;
  IF conv.state = 'closed' THEN
    RETURN public._act_finish(ctx, 'conversation.take_over', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'CONVERSATION_CLOSED', 'This conversation is closed.', conv.id, NULL, 'conversations');
  END IF;
  IF conv.state = 'person' AND conv.handled_by IS DISTINCT FROM (ctx ->> 'user_id')::uuid AND ctx ->> 'role' NOT IN ('manager', 'admin') THEN
    RETURN public._act_finish(ctx, 'conversation.take_over', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'ALREADY_HANDLED', 'Someone else is handling this conversation.', conv.id, NULL, 'conversations');
  END IF;

  UPDATE public.conversations SET state = 'person', handled_by = (ctx ->> 'user_id')::uuid, needs_person_since = NULL WHERE id = conv.id;
  v_ev := public._hub_event(conv.id, 'took_over', public._hub_user_name((ctx ->> 'user_id')::uuid) || ' took over', jsonb_build_object('user_id', ctx ->> 'user_id', 'from_state', conv.state),
                            'person', (ctx ->> 'user_id')::uuid, NULL);
  res := public._act_finish(ctx, 'conversation.take_over', conv.org_id, conv.branch_id, v_inputs, true,
                            jsonb_build_object('conversation_id', conv.id, 'state', 'person'), NULL, NULL, conv.id, NULL, 'conversations');
  UPDATE public.messages SET action_id = (res ->> 'action_id')::uuid WHERE id = v_ev;
  RETURN res;
END $$;

-- Back to the agent. Undoable (the toast on the Handed-back board): the prior state is stored, act_undo restores it.
CREATE FUNCTION public.act_conversation_hand_back(p_conversation uuid, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; conv public.conversations; v_inputs jsonb; res jsonb; v_ev uuid; v_upd timestamptz;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('conversation_id', p_conversation) || public._act_ctx_inputs(p_ctx, ctx);
  SELECT * INTO conv FROM public.conversations WHERE id = p_conversation FOR UPDATE;
  IF conv.id IS NULL OR NOT public._hub_scope(ctx, conv.org_id, conv.branch_id, conv.customer_id) THEN
    RETURN public._act_finish(ctx, 'conversation.hand_back', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'CONVERSATION_NOT_FOUND', 'Conversation not found.', p_conversation, NULL, 'conversations');
  END IF;
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('staff', 'manager', 'admin', 'practitioner') THEN
    RETURN public._act_finish(ctx, 'conversation.hand_back', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Only a person on the team can hand a conversation back.', conv.id, NULL, 'conversations');
  END IF;
  IF conv.state NOT IN ('person', 'needs_person') THEN
    RETURN public._act_finish(ctx, 'conversation.hand_back', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'NOT_HANDLED', 'The agent already has this conversation.', conv.id, NULL, 'conversations');
  END IF;

  UPDATE public.conversations SET state = 'agent', handled_by = NULL, needs_person_since = NULL, urgent = false WHERE id = conv.id
    RETURNING updated_at INTO v_upd;
  v_ev := public._hub_event(conv.id, 'handed_back', public._hub_user_name((ctx ->> 'user_id')::uuid) || ' handed this back to the agent',
                            jsonb_build_object('user_id', ctx ->> 'user_id', 'from_state', conv.state), 'person', (ctx ->> 'user_id')::uuid, NULL);
  res := public._act_finish(ctx, 'conversation.hand_back', conv.org_id, conv.branch_id, v_inputs, true,
    jsonb_build_object('conversation_id', conv.id, 'state', 'agent'), NULL, NULL, conv.id,
    jsonb_build_object('kind', 'hand_back', 'prior', jsonb_build_object('state', conv.state, 'handled_by', conv.handled_by,
                         'needs_person_since', conv.needs_person_since, 'urgent', conv.urgent),
                       'expect_updated_at', v_upd, 'expires_at', now() + interval '24 hours'), 'conversations');
  UPDATE public.messages SET action_id = (res ->> 'action_id')::uuid WHERE id = v_ev;
  RETURN res;
END $$;

-- Manager and admin assign to anyone with access to the thread; front desk only to a manager or admin ("Assign to manager").
CREATE FUNCTION public.act_conversation_assign(p_conversation uuid, p_user uuid, p_note text DEFAULT NULL, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; conv public.conversations; v_inputs jsonb; res jsonb; v_ev uuid; u record; v_access boolean;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('conversation_id', p_conversation, 'assign_to', p_user, 'note', p_note) || public._act_ctx_inputs(p_ctx, ctx);
  SELECT * INTO conv FROM public.conversations WHERE id = p_conversation FOR UPDATE;
  IF conv.id IS NULL OR NOT public._hub_scope(ctx, conv.org_id, conv.branch_id, conv.customer_id) THEN
    RETURN public._act_finish(ctx, 'conversation.assign', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'CONVERSATION_NOT_FOUND', 'Conversation not found.', p_conversation, NULL, 'conversations');
  END IF;
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('staff', 'manager', 'admin') THEN
    RETURN public._act_finish(ctx, 'conversation.assign', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot assign conversations.', conv.id, NULL, 'conversations');
  END IF;
  SELECT id, role::text AS role, branch_id, dentist_id, full_name INTO u FROM public.users WHERE id = p_user AND org_id = conv.org_id AND is_active IS NOT FALSE;
  IF u.id IS NULL THEN
    RETURN public._act_finish(ctx, 'conversation.assign', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'ASSIGNEE_NOT_FOUND', 'That person is not on the team.', conv.id, NULL, 'conversations');
  END IF;
  IF ctx ->> 'role' = 'staff' AND u.role NOT IN ('manager', 'admin') THEN
    RETURN public._act_finish(ctx, 'conversation.assign', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Front desk can assign a conversation to a manager only.', conv.id, NULL, 'conversations');
  END IF;
  v_access := CASE
    WHEN u.role = 'admin' THEN true
    WHEN u.role IN ('staff', 'manager') THEN conv.branch_id IS NULL OR u.branch_id = conv.branch_id
                                             OR EXISTS (SELECT 1 FROM public.user_branches ub WHERE ub.user_id = u.id AND ub.branch_id = conv.branch_id)
    WHEN u.role = 'practitioner' THEN u.dentist_id IS NOT NULL AND conv.customer_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.bookings b WHERE b.customer_id = conv.customer_id
           AND (b.dentist_id = u.dentist_id OR EXISTS (SELECT 1 FROM public.booking_dentists bd WHERE bd.booking_id = b.id AND bd.dentist_id = u.dentist_id)))
    ELSE false END;
  IF NOT COALESCE(v_access, false) THEN
    RETURN public._act_finish(ctx, 'conversation.assign', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'ASSIGNEE_NO_ACCESS', 'That person cannot see this conversation.', conv.id, NULL, 'conversations');
  END IF;

  UPDATE public.conversations SET assigned_to = u.id, assigned_by = (ctx ->> 'user_id')::uuid, assigned_at = now(), assign_note = NULLIF(btrim(p_note), '') WHERE id = conv.id;
  v_ev := public._hub_event(conv.id, 'assigned', public._hub_user_name((ctx ->> 'user_id')::uuid) || ' assigned this to ' || u.full_name,
                            jsonb_build_object('assigned_to', u.id, 'assigned_by', ctx ->> 'user_id', 'note', NULLIF(btrim(p_note), '')), 'person', (ctx ->> 'user_id')::uuid, NULL);
  res := public._act_finish(ctx, 'conversation.assign', conv.org_id, conv.branch_id, v_inputs, true,
                            jsonb_build_object('conversation_id', conv.id, 'assigned_to', u.id), NULL, NULL, conv.id, NULL, 'conversations');
  UPDATE public.messages SET action_id = (res ->> 'action_id')::uuid WHERE id = v_ev;
  RETURN res;
END $$;

-- Agents and rules only: needs_person, with the reason, the summary, urgent, and (for a clinical question) the practitioner who sees the patient.
CREATE FUNCTION public.act_conversation_handoff(p_conversation uuid, p_reason text, p_summary text, p_urgent boolean DEFAULT false, p_practitioner uuid DEFAULT NULL,
                                                p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; conv public.conversations; v_inputs jsonb; res jsonb; v_ev uuid; v_pr uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('conversation_id', p_conversation, 'reason', p_reason, 'summary', p_summary, 'urgent', p_urgent, 'practitioner_id', p_practitioner) || public._act_ctx_inputs(p_ctx, ctx);
  SELECT * INTO conv FROM public.conversations WHERE id = p_conversation FOR UPDATE;
  IF conv.id IS NULL OR NOT public._hub_scope(ctx, conv.org_id, conv.branch_id, conv.customer_id) THEN
    RETURN public._act_finish(ctx, 'conversation.handoff', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'CONVERSATION_NOT_FOUND', 'Conversation not found.', p_conversation, NULL, 'conversations');
  END IF;
  IF ctx ->> 'kind' NOT IN ('agent', 'rule') THEN
    RETURN public._act_finish(ctx, 'conversation.handoff', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Only an agent or a rule hands a conversation off.', conv.id, NULL, 'conversations');
  END IF;
  IF p_reason IS NULL OR p_reason NOT IN ('urgent', 'clinical', 'discount', 'complaint', 'asks_to_change', 'unclear', 'other') OR p_summary IS NULL OR btrim(p_summary) = '' OR length(p_summary) > 1000 THEN
    RETURN public._act_finish(ctx, 'conversation.handoff', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'INVALID_INPUT', 'A valid reason and a summary of up to 1000 characters are required.', conv.id, NULL, 'conversations');
  END IF;
  IF conv.state = 'person' THEN
    RETURN public._act_finish(ctx, 'conversation.handoff', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'ALREADY_HANDLED', 'A person is already handling this conversation.', conv.id, NULL, 'conversations');
  END IF;

  IF p_practitioner IS NOT NULL THEN
    SELECT d.id INTO v_pr FROM public.dentists d WHERE d.id = p_practitioner AND d.org_id = conv.org_id;
    IF v_pr IS NULL THEN
      RETURN public._act_finish(ctx, 'conversation.handoff', conv.org_id, conv.branch_id, v_inputs, false, NULL, 'INVALID_INPUT', 'That practitioner is not in this organization.', conv.id, NULL, 'conversations');
    END IF;
  ELSIF p_reason = 'clinical' AND conv.customer_id IS NOT NULL THEN
    -- the dentist of the patient's next booking, else of the latest past one
    SELECT x.dentist INTO v_pr FROM (
      SELECT COALESCE(b.dentist_id, (SELECT bd.dentist_id FROM public.booking_dentists bd WHERE bd.booking_id = b.id LIMIT 1)) AS dentist, b.date
        FROM public.bookings b JOIN public.branches br ON br.id = b.branch_id
       WHERE b.customer_id = conv.customer_id AND br.org_id = conv.org_id AND b.status <> 'Cancelled') x
     WHERE x.dentist IS NOT NULL
     ORDER BY (x.date < current_date), CASE WHEN x.date >= current_date THEN x.date END ASC NULLS LAST, x.date DESC
     LIMIT 1;
  END IF;

  UPDATE public.conversations
     SET state = 'needs_person', handled_by = NULL, handoff_reason = p_reason, handoff_summary = btrim(p_summary), urgent = COALESCE(p_urgent, false),
         practitioner_id = COALESCE(v_pr, practitioner_id),
         needs_person_since = CASE WHEN state = 'needs_person' THEN COALESCE(needs_person_since, now()) ELSE now() END
   WHERE id = conv.id;
  v_ev := public._hub_event(conv.id, 'handoff', 'Handed off to a person: ' || replace(p_reason, '_', ' '),
                            jsonb_build_object('reason', p_reason, 'urgent', COALESCE(p_urgent, false), 'practitioner_id', v_pr, 'summary', btrim(p_summary)),
                            ctx ->> 'kind', NULL, ctx ->> 'agent');
  res := public._act_finish(ctx, 'conversation.handoff', conv.org_id, conv.branch_id, v_inputs, true,
                            jsonb_build_object('conversation_id', conv.id, 'state', 'needs_person', 'practitioner_id', v_pr), NULL, NULL, conv.id, NULL, 'conversations');
  UPDATE public.messages SET action_id = (res ->> 'action_id')::uuid WHERE id = v_ev;
  RETURN res;
END $$;

-- 9. consent.record --------------------------------------------------------------------------------------------------------------------
-- Front desk, manager, admin. A 'stopped' row can be reversed only by the patient's own START (through message.receive) or by a manager / admin
-- recording a new written agreement with evidence.
CREATE FUNCTION public.act_consent_record(p_customer uuid DEFAULT NULL, p_channel text DEFAULT 'sms', p_address text DEFAULT NULL, p_purpose text DEFAULT 'service',
                                          p_status text DEFAULT 'agreed', p_evidence text DEFAULT NULL, p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; cust public.customers; v_inputs jsonb; res jsonb; v_org uuid; v_branch uuid; v_address text; v_prev text; v_id uuid; c record; v_ev uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('customer_id', p_customer, 'channel', p_channel, 'purpose', p_purpose, 'status', p_status, 'evidence', p_evidence) || public._act_ctx_inputs(p_ctx, ctx);
  IF ctx ->> 'kind' <> 'person' OR ctx ->> 'role' NOT IN ('staff', 'manager', 'admin') THEN
    RETURN public._act_finish(ctx, 'consent.record', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Only front desk, a manager or an admin can record consent.', NULL, NULL, 'patient_channels');
  END IF;
  IF p_channel NOT IN ('sms', 'whatsapp', 'viber', 'messenger', 'email') OR p_purpose NOT IN ('service', 'marketing') OR p_status NOT IN ('agreed', 'not_asked', 'stopped')
     OR p_evidence IS NULL OR btrim(p_evidence) = '' THEN
    RETURN public._act_finish(ctx, 'consent.record', v_org, NULL, v_inputs, false, NULL, 'INVALID_INPUT', 'A channel, a purpose, a status and the evidence (for example "Agreed at the front desk, 4 Feb") are required.', NULL, NULL, 'patient_channels');
  END IF;

  IF p_customer IS NOT NULL THEN
    SELECT * INTO cust FROM public.customers WHERE id = p_customer;
    IF cust.id IS NULL OR NOT public._hub_scope(ctx, cust.org_id, cust.branch_id, cust.id) THEN
      RETURN public._act_finish(ctx, 'consent.record', v_org, NULL, v_inputs, false, NULL, 'PATIENT_NOT_FOUND', 'Patient not found.', NULL, NULL, 'patient_channels');
    END IF;
    v_branch := cust.branch_id;
    v_address := COALESCE(CASE WHEN p_channel IN ('sms', 'whatsapp') THEN public.normalize_phone_e164(COALESCE(p_address, cust.phone))
                               WHEN p_channel = 'email' THEN lower(NULLIF(btrim(COALESCE(p_address, cust.email)), '')) ELSE NULLIF(btrim(p_address), '') END, NULL);
  ELSE
    IF ctx ->> 'role' NOT IN ('manager', 'admin') THEN
      RETURN public._act_finish(ctx, 'consent.record', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Consent for a number that is not a patient can be recorded by a manager or admin only.', NULL, NULL, 'patient_channels');
    END IF;
    v_address := CASE WHEN p_channel IN ('sms', 'whatsapp') THEN public.normalize_phone_e164(p_address)
                      WHEN p_channel = 'email' THEN lower(NULLIF(btrim(p_address), '')) ELSE NULLIF(btrim(p_address), '') END;
  END IF;
  IF v_address IS NULL THEN
    RETURN public._act_finish(ctx, 'consent.record', v_org, v_branch, v_inputs, false, NULL, 'NO_ADDRESS', 'There is no phone number or address to record consent for.', NULL, NULL, 'patient_channels');
  END IF;

  SELECT status INTO v_prev FROM public.patient_channels WHERE org_id = v_org AND channel = p_channel AND address = v_address AND purpose = p_purpose;
  IF v_prev = 'stopped' AND p_status <> 'stopped' AND (ctx ->> 'role' NOT IN ('manager', 'admin') OR length(btrim(p_evidence)) < 10) THEN
    RETURN public._act_finish(ctx, 'consent.record', v_org, v_branch, v_inputs, false, NULL, 'FORBIDDEN',
      'This number replied STOP. Only a manager or admin can record a new written agreement, with the evidence.', NULL, NULL, 'patient_channels');
  END IF;

  INSERT INTO public.patient_channels (org_id, customer_id, channel, address, purpose, status, source, recorded_by, recorded_at, evidence)
  VALUES (v_org, p_customer, p_channel, v_address, p_purpose, p_status, 'front_desk', (ctx ->> 'user_id')::uuid, now(), btrim(p_evidence))
  ON CONFLICT (org_id, channel, address, purpose) DO UPDATE
     SET status = EXCLUDED.status, source = EXCLUDED.source, recorded_by = EXCLUDED.recorded_by, recorded_at = now(), evidence = EXCLUDED.evidence,
         customer_id = COALESCE(public.patient_channels.customer_id, EXCLUDED.customer_id)
  RETURNING id INTO v_id;

  res := public._act_finish(ctx, 'consent.record', v_org, v_branch, v_inputs, true,
                            jsonb_build_object('patient_channel_id', v_id, 'status', p_status, 'purpose', p_purpose, 'channel', p_channel, 'previous', COALESCE(v_prev, 'not_asked')),
                            NULL, NULL, v_id, NULL, 'patient_channels');
  FOR c IN SELECT id FROM public.conversations WHERE org_id = v_org AND channel = p_channel AND address = v_address LOOP
    v_ev := public._hub_event(c.id, 'consent_recorded', public._hub_user_name((ctx ->> 'user_id')::uuid) || ' recorded ' || p_purpose || ' consent: ' || replace(p_status, '_', ' '),
                              jsonb_build_object('purpose', p_purpose, 'status', p_status, 'evidence', btrim(p_evidence)), 'person', (ctx ->> 'user_id')::uuid, NULL);
    UPDATE public.messages SET action_id = (res ->> 'action_id')::uuid WHERE id = v_ev;
  END LOOP;
  RETURN res;
END $$;

-- 10. message.receive: SERVICE ROLE ONLY (the inbound webhook) ---------------------------------------------------------------------------
-- The caller passes p_ctx { actor_kind: 'patient', org_id }. An unverified sender (Aakash inbound is not signed) can only do what this function does:
-- insert one inbound message into a thread for ITS OWN number, and record STOP or START for that same number. Nothing else.
CREATE FUNCTION public.hub_find_account(p_provider text, p_recipient text) RETURNS TABLE (id uuid, org_id uuid, branch_id uuid, channel text, status text, secret_ref text)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT a.id, a.org_id, a.branch_id, a.channel, a.status, a.secret_ref FROM public.channel_accounts a
   WHERE a.provider = p_provider AND (a.sender = p_recipient
         OR (regexp_replace(a.sender, '\D', '', 'g') <> '' AND regexp_replace(a.sender, '\D', '', 'g') = regexp_replace(p_recipient, '\D', '', 'g')))
   LIMIT 1
$$;

CREATE FUNCTION public.hub_list_accounts(p_provider text) RETURNS TABLE (id uuid, org_id uuid, branch_id uuid, channel text, status text, secret_ref text)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$ SELECT a.id, a.org_id, a.branch_id, a.channel, a.status, a.secret_ref FROM public.channel_accounts a WHERE a.provider = p_provider AND a.status = 'connected' $$;

-- Per-account rate limit for inbound webhooks: returns false (and counts a drop) beyond p_limit per minute.
CREATE FUNCTION public.hub_rate_check(p_account uuid, p_limit integer DEFAULT 60) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_bucket timestamptz := date_trunc('minute', now()); v_acc integer;
BEGIN
  INSERT INTO public.hub_inbound_rate (channel_account_id, bucket) VALUES (p_account, v_bucket) ON CONFLICT DO NOTHING;
  SELECT accepted INTO v_acc FROM public.hub_inbound_rate WHERE channel_account_id = p_account AND bucket = v_bucket FOR UPDATE;
  IF v_acc < p_limit THEN
    UPDATE public.hub_inbound_rate SET accepted = accepted + 1 WHERE channel_account_id = p_account AND bucket = v_bucket;
    RETURN true;
  END IF;
  UPDATE public.hub_inbound_rate SET dropped = dropped + 1 WHERE channel_account_id = p_account AND bucket = v_bucket;
  RETURN false;
END $$;

CREATE FUNCTION public.act_message_receive(p_account uuid, p_from text, p_body text, p_provider_message_id text DEFAULT NULL, p_received_at timestamptz DEFAULT NULL,
                                           p_ctx jsonb DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; acc public.channel_accounts; v_inputs jsonb; res jsonb; cust public.customers; conv public.conversations;
  v_org uuid; v_address text; v_body text; v_norm text; v_kw text; v_lang text := 'en'; v_branch uuid; v_msg uuid; v_ev uuid; v_was_stopped boolean;
  v_org_name text; v_confirm text; v_state text; v_dup boolean;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_org := (ctx ->> 'org_id')::uuid;
  v_inputs := jsonb_build_object('account_id', p_account, 'provider_message_id', p_provider_message_id) || public._act_ctx_inputs(p_ctx, ctx);   -- no number, no text: those live on the rows
  IF ctx ->> 'kind' <> 'patient' THEN
    RETURN public._act_finish(ctx, 'message.receive', v_org, NULL, v_inputs, false, NULL, 'FORBIDDEN', 'Only the inbound webhook can record an incoming message.', NULL, NULL, 'conversations');
  END IF;
  SELECT * INTO acc FROM public.channel_accounts WHERE id = p_account AND org_id = v_org;
  IF acc.id IS NULL THEN
    RETURN public._act_finish(ctx, 'message.receive', v_org, NULL, v_inputs, false, NULL, 'ACCOUNT_NOT_FOUND', 'Channel account not found.', NULL, NULL, 'conversations');
  END IF;

  v_address := CASE WHEN acc.channel IN ('sms', 'whatsapp') THEN public.normalize_phone_e164(p_from) WHEN acc.channel = 'email' THEN lower(NULLIF(btrim(p_from), '')) ELSE NULLIF(btrim(p_from), '') END;
  v_body := btrim(p_body);
  IF v_address IS NULL OR v_body IS NULL OR v_body = '' OR length(v_body) > 2000 THEN
    RETURN public._act_finish(ctx, 'message.receive', v_org, acc.branch_id, v_inputs, false, NULL, 'INVALID_INPUT', 'A sender and a text of up to 2000 characters are required.', NULL, NULL, 'conversations');
  END IF;

  IF p_provider_message_id IS NOT NULL THEN
    SELECT EXISTS (SELECT 1 FROM public.messages WHERE channel_account_id = acc.id AND direction = 'in' AND provider_message_id = p_provider_message_id) INTO v_dup;
    IF v_dup THEN
      RETURN public._act_finish(ctx, 'message.receive', v_org, acc.branch_id, v_inputs, true, jsonb_build_object('duplicate', true), NULL, NULL, NULL, NULL, 'conversations');
    END IF;
  END IF;

  -- the patient, by normalised phone (unique per organization)
  IF acc.channel IN ('sms', 'whatsapp') THEN
    SELECT * INTO cust FROM public.customers WHERE org_id = v_org AND phone = v_address LIMIT 1;
  ELSIF acc.channel = 'email' THEN
    SELECT * INTO cust FROM public.customers WHERE org_id = v_org AND lower(email) = v_address LIMIT 1;
  END IF;
  v_branch := COALESCE(acc.branch_id, cust.branch_id);

  -- the thread: one per organization, channel, address and branch
  SELECT * INTO conv FROM public.conversations c
   WHERE c.org_id = v_org AND c.channel = acc.channel AND c.address = v_address
     AND COALESCE(c.branch_id, '00000000-0000-0000-0000-000000000000'::uuid) = COALESCE(v_branch, '00000000-0000-0000-0000-000000000000'::uuid);
  IF conv.id IS NULL AND cust.id IS NOT NULL THEN
    -- a thread that had no patient match yet: link it (this sets its branch)
    SELECT * INTO conv FROM public.conversations c WHERE c.org_id = v_org AND c.channel = acc.channel AND c.address = v_address AND c.branch_id IS NULL;
    IF conv.id IS NOT NULL THEN
      UPDATE public.conversations SET customer_id = cust.id, branch_id = v_branch WHERE id = conv.id RETURNING * INTO conv;
    END IF;
  END IF;
  IF conv.id IS NULL THEN
    INSERT INTO public.conversations (org_id, branch_id, channel, address, channel_account_id, customer_id, state, language)
    VALUES (v_org, v_branch, acc.channel, v_address, acc.id, cust.id, 'agent', 'en') RETURNING * INTO conv;
  ELSIF conv.customer_id IS NULL AND cust.id IS NOT NULL THEN
    UPDATE public.conversations SET customer_id = cust.id WHERE id = conv.id RETURNING * INTO conv;
  END IF;
  IF cust.id IS NOT NULL THEN
    UPDATE public.patient_channels SET customer_id = cust.id WHERE org_id = v_org AND channel = acc.channel AND address = v_address AND customer_id IS NULL;
  END IF;

  IF v_body ~ '[ऀ-ॿ]' THEN v_lang := 'ne'; END IF;

  INSERT INTO public.messages (org_id, conversation_id, direction, kind, body, language, author_kind, status, channel_account_id, provider, provider_message_id, delivered_at)
  VALUES (v_org, conv.id, 'in', 'message', v_body, v_lang, 'patient', 'delivered', acc.id, acc.provider, p_provider_message_id, COALESCE(p_received_at, now()))
  RETURNING id INTO v_msg;

  -- a closed thread comes back: to the agent, or to a person if a person had been handling it
  v_state := conv.state;
  UPDATE public.conversations
     SET last_message_at = now(), last_inbound_at = now(), language = v_lang, channel_account_id = COALESCE(channel_account_id, acc.id),
         state = CASE WHEN state = 'closed' THEN CASE WHEN handled_by IS NOT NULL THEN 'needs_person' ELSE 'agent' END ELSE state END,
         needs_person_since = CASE WHEN state = 'closed' AND handled_by IS NOT NULL THEN now() ELSE needs_person_since END
   WHERE id = conv.id;

  -- STOP and START: the whole message, case-insensitive. "cancel" is NOT a stop word here: in a clinic it means "cancel my appointment".
  v_norm := lower(btrim(regexp_replace(v_body, '[[:space:]]+', ' ', 'g'), ' .!'));
  v_kw := CASE WHEN v_norm IN ('stop', 'stopall', 'stop all', 'unsubscribe', 'end', 'quit', 'रोक', 'बन्द') THEN 'stop'
               WHEN v_norm IN ('start', 'unstop', 'शुरु', 'शुरू') THEN 'start' END;

  IF v_kw = 'stop' THEN
    SELECT EXISTS (SELECT 1 FROM public.patient_channels WHERE org_id = v_org AND channel = acc.channel AND address = v_address AND purpose = 'service' AND status = 'stopped') INTO v_was_stopped;
    INSERT INTO public.patient_channels (org_id, customer_id, channel, address, purpose, status, source, recorded_at, evidence)
    SELECT v_org, cust.id, acc.channel, v_address, p.purpose, 'stopped', 'patient_reply', now(), 'Patient replied STOP on ' || to_char(now() AT TIME ZONE 'Asia/Kathmandu', 'FMDD Mon YYYY')
      FROM (VALUES ('service'), ('marketing')) p(purpose)
    ON CONFLICT (org_id, channel, address, purpose) DO UPDATE
       SET status = 'stopped', source = 'patient_reply', recorded_by = NULL, recorded_at = now(), evidence = EXCLUDED.evidence,
           customer_id = COALESCE(public.patient_channels.customer_id, EXCLUDED.customer_id)
     WHERE public.patient_channels.status <> 'stopped';
    v_ev := public._hub_event(conv.id, 'stop_recorded', 'STOP recorded: no more messages on this channel', jsonb_build_object('keyword', v_norm), 'system', NULL, NULL);
    IF NOT v_was_stopped THEN
      SELECT name INTO v_org_name FROM public.organizations WHERE id = v_org;
      v_confirm := CASE WHEN v_lang = 'ne'
        THEN 'तपाईंले अब ' || v_org_name || ' बाट सन्देश प्राप्त गर्नुहुने छैन। फेरि प्राप्त गर्न START पठाउनुहोस्।'
        ELSE 'You will no longer receive messages from ' || v_org_name || '. Reply START to receive them again.' END;
      -- the ONE confirmation reply; queued here, past the consent check on purpose (no caller can reach this path)
      INSERT INTO public.messages (org_id, conversation_id, direction, kind, body, meta, language, author_kind, purpose, status, channel_account_id, provider)
      VALUES (v_org, conv.id, 'out', 'message', v_confirm, jsonb_build_object('opt_out_confirmation', true), v_lang, 'system', 'service', 'queued', acc.id, acc.provider);
    END IF;
  ELSIF v_kw = 'start' THEN
    INSERT INTO public.patient_channels (org_id, customer_id, channel, address, purpose, status, source, recorded_at, evidence)
    VALUES (v_org, cust.id, acc.channel, v_address, 'service', 'agreed', 'patient_reply', now(), 'Patient replied START on ' || to_char(now() AT TIME ZONE 'Asia/Kathmandu', 'FMDD Mon YYYY'))
    ON CONFLICT (org_id, channel, address, purpose) DO UPDATE
       SET status = 'agreed', source = 'patient_reply', recorded_by = NULL, recorded_at = now(), evidence = EXCLUDED.evidence,
           customer_id = COALESCE(public.patient_channels.customer_id, EXCLUDED.customer_id);
    -- marketing never comes back by a keyword: a STOPPED marketing row goes to "not asked"
    UPDATE public.patient_channels SET status = 'not_asked', source = 'patient_reply', recorded_at = now(), evidence = 'Marketing needs a new explicit agreement (patient replied START)'
     WHERE org_id = v_org AND channel = acc.channel AND address = v_address AND purpose = 'marketing' AND status = 'stopped';
    v_ev := public._hub_event(conv.id, 'start_recorded', 'START recorded: service messages are back on', jsonb_build_object('keyword', v_norm), 'system', NULL, NULL);
  END IF;

  res := public._act_finish(ctx, 'message.receive', v_org, conv.branch_id, v_inputs, true,
    jsonb_build_object('conversation_id', conv.id, 'message_id', v_msg, 'customer_id', cust.id, 'matched', cust.id IS NOT NULL, 'keyword', v_kw, 'reopened', v_state = 'closed'),
    NULL, NULL, conv.id, NULL, 'conversations');
  UPDATE public.messages SET action_id = (res ->> 'action_id')::uuid WHERE id IN (v_msg, v_ev) AND id IS NOT NULL;
  RETURN res;
END $$;

-- 11. the sender and the poller (internal; service role only). These are NOT actions: a delivery receipt or a worker result lives on the
-- message row itself (status, error, cost), because a log row per receipt (three per message) would drown action_log. message.send already
-- logged the send, and message.receive logs every inbound text.

-- Providers whose send can be repeated without sending twice. Others (Aakash) have no idempotency key.
CREATE FUNCTION public._hub_provider_idempotent(p_provider text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$ SELECT p_provider IN ('test') $$;

-- Claims due messages for the sender (FOR UPDATE SKIP LOCKED: two workers never get the same row). Before it hands anything out:
--   * a message stuck in 'sending' for 10 minutes: re-queued if the provider is idempotent; otherwise set to 'failed' with
--     "outcome unknown: check the provider report", never re-sent (a duplicate patient text is worse than a missed one);
--   * consent is re-checked NOW (the patient may have replied STOP after the message was queued): the message is cancelled;
--   * quiet hours are re-checked NOW: the message is pushed to the end of the window.
-- The one STOP confirmation reply is exempt from both checks.
CREATE FUNCTION public.hub_claim_messages(p_limit integer DEFAULT 20)
    RETURNS TABLE (id uuid, org_id uuid, conversation_id uuid, to_address text, body text, channel text, provider text, sender text, secret_ref text,
                   language text, account_id uuid, credit_cost_npr numeric)
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  r record; v_cons text; v_qe timestamptz; v_confirm boolean;
BEGIN
  UPDATE public.messages m SET status = 'failed', error = 'outcome unknown: check the provider report'
   WHERE m.status = 'sending' AND m.updated_at < now() - interval '10 minutes' AND NOT public._hub_provider_idempotent(m.provider);
  UPDATE public.messages m SET status = 'queued'
   WHERE m.status = 'sending' AND m.updated_at < now() - interval '10 minutes' AND public._hub_provider_idempotent(m.provider);

  FOR r IN
    SELECT m.id AS mid, m.org_id AS morg, m.conversation_id AS mconv, m.body AS mbody, m.purpose AS mpurpose, m.language AS mlang, m.meta AS mmeta,
           c.address AS caddr, c.channel AS cchan, a.id AS aid, a, a.provider AS aprov, a.sender AS asender, a.secret_ref AS aref, a.status AS astatus, a.credit_cost_npr AS acost
      FROM public.messages m
      JOIN public.conversations c ON c.id = m.conversation_id
      LEFT JOIN public.channel_accounts a ON a.id = m.channel_account_id
     WHERE m.status = 'queued' AND m.kind = 'message' AND m.direction = 'out' AND m.scheduled_for <= now()
     ORDER BY m.scheduled_for
     LIMIT p_limit
     FOR UPDATE OF m SKIP LOCKED
  LOOP
    v_confirm := COALESCE((r.mmeta ->> 'opt_out_confirmation')::boolean, false);
    IF r.aid IS NULL OR r.astatus <> 'connected' THEN
      UPDATE public.messages SET status = 'failed', error = 'channel not connected' WHERE messages.id = r.mid;
      CONTINUE;
    END IF;
    IF NOT v_confirm THEN
      v_cons := public._hub_consent(r.morg, r.cchan, r.caddr, COALESCE(r.mpurpose, 'service'));
      IF v_cons <> 'agreed' THEN
        UPDATE public.messages SET status = 'cancelled', error = CASE WHEN v_cons = 'stopped' THEN 'cancelled: the patient replied STOP before this was sent' ELSE 'cancelled: no consent at send time' END
         WHERE messages.id = r.mid;
        CONTINUE;
      END IF;
      v_qe := public._hub_quiet_end(r.a, now());
      IF v_qe IS NOT NULL THEN
        UPDATE public.messages SET scheduled_for = v_qe WHERE messages.id = r.mid;
        CONTINUE;
      END IF;
    END IF;
    UPDATE public.messages SET status = 'sending' WHERE messages.id = r.mid;
    id := r.mid; org_id := r.morg; conversation_id := r.mconv; to_address := r.caddr; body := r.mbody; channel := r.cchan; provider := r.aprov;
    sender := r.asender; secret_ref := r.aref; language := r.mlang; account_id := r.aid; credit_cost_npr := r.acost;
    RETURN NEXT;
  END LOOP;
END $$;

-- The worker's result for a claimed message: 'sent' (with the provider's id and the credits it used) or 'failed'.
CREATE FUNCTION public.hub_record_send_result(p_message uuid, p_ok boolean, p_provider_message_id text DEFAULT NULL, p_credits numeric DEFAULT NULL, p_error text DEFAULT NULL)
    RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE n integer;
BEGIN
  IF p_ok THEN
    UPDATE public.messages m
       SET status = 'sent', sent_at = now(), provider_message_id = COALESCE(p_provider_message_id, m.provider_message_id), credits = p_credits,
           cost_npr = CASE WHEN p_credits IS NOT NULL THEN p_credits * (SELECT a.credit_cost_npr FROM public.channel_accounts a WHERE a.id = m.channel_account_id) END,
           error = NULL
     WHERE m.id = p_message AND m.status = 'sending';
  ELSE
    UPDATE public.messages SET status = 'failed', error = left(COALESCE(p_error, 'send failed'), 500), credits = p_credits WHERE id = p_message AND status = 'sending';
  END IF;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;
END $$;

-- A delivery receipt from a provider (push or pulled): statuses only move forward; a late 'sent' never undoes 'delivered'; 'failed' is
-- accepted until the message is delivered. Returns 'updated', 'ignored' or 'not_found'.
CREATE FUNCTION public.hub_apply_delivery_status(p_account uuid, p_provider_message_id text, p_status text, p_at timestamptz DEFAULT NULL, p_error text DEFAULT NULL)
    RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  m public.messages; v_new integer; v_cur integer;
  ranks constant jsonb := '{"queued":0,"sending":1,"sent":2,"delivered":3,"read":4}'::jsonb;
BEGIN
  IF p_status NOT IN ('sent', 'delivered', 'read', 'failed') THEN RETURN 'ignored'; END IF;
  SELECT * INTO m FROM public.messages WHERE channel_account_id = p_account AND provider_message_id = p_provider_message_id AND direction = 'out' AND kind = 'message' FOR UPDATE;
  IF m.id IS NULL THEN RETURN 'not_found'; END IF;
  IF m.status IN ('failed', 'cancelled') THEN RETURN 'ignored'; END IF;
  IF p_status = 'failed' THEN
    IF m.status IN ('delivered', 'read') THEN RETURN 'ignored'; END IF;
    UPDATE public.messages SET status = 'failed', error = left(COALESCE(p_error, 'the provider reported a failure'), 500) WHERE id = m.id;
    RETURN 'updated';
  END IF;
  v_new := (ranks ->> p_status)::integer; v_cur := (ranks ->> m.status)::integer;
  IF v_new <= v_cur THEN RETURN 'ignored'; END IF;
  UPDATE public.messages
     SET status = p_status, delivered_at = CASE WHEN p_status IN ('delivered', 'read') THEN COALESCE(delivered_at, p_at, now()) ELSE delivered_at END
   WHERE id = m.id;
  RETURN 'updated';
END $$;

-- For providers that only offer a PULL report (Aakash): which accounts to poll, and which messages are waiting for a delivery report.
CREATE FUNCTION public.hub_poll_accounts() RETURNS TABLE (id uuid, org_id uuid, provider text, secret_ref text, last_polled_at timestamptz)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$ SELECT a.id, a.org_id, a.provider, a.secret_ref, a.last_polled_at FROM public.channel_accounts a WHERE a.status = 'connected' AND a.provider <> 'test' $$;

CREATE FUNCTION public.hub_pending_delivery(p_account uuid, p_since interval DEFAULT interval '3 days')
    RETURNS TABLE (message_id uuid, provider_message_id text, to_address text, sent_at timestamptz)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
    AS $$
  SELECT m.id, m.provider_message_id, c.address, m.sent_at FROM public.messages m JOIN public.conversations c ON c.id = m.conversation_id
   WHERE m.channel_account_id = p_account AND m.status = 'sent' AND m.provider_message_id IS NOT NULL AND m.sent_at > now() - p_since
   ORDER BY m.sent_at LIMIT 500
$$;

CREATE FUNCTION public.hub_mark_polled(p_account uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER SET search_path = public
    AS $$ UPDATE public.channel_accounts SET last_polled_at = now() WHERE id = p_account $$;

-- 12. "I have read this thread" (per person). Not an action: logging every thread opened would flood action_log. ----------------------------
CREATE FUNCTION public.hub_mark_read(p_conversation uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not signed in' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = p_conversation AND public.hub_can_read_conversation(c.org_id, c.branch_id, c.customer_id)) THEN
    RETURN;   -- not visible to this person: nothing to mark, and nothing revealed
  END IF;
  INSERT INTO public.conversation_reads (conversation_id, user_id, last_read_at) VALUES (p_conversation, auth.uid(), now())
  ON CONFLICT (conversation_id, user_id) DO UPDATE SET last_read_at = now();
END $$;

-- 13. the clock: pg_cron every minute kicks the sender, every 5 minutes the delivery poller. Same pattern as the outreach drain: one HTTP call
-- to the edge function with the bearer token read from private.outreach_function_config. Nothing is sent when there is nothing due. ----------
CREATE FUNCTION public.hub_kick_sender(p_mode text DEFAULT 'send') RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_cfg record; v_due integer;
BEGIN
  IF to_regclass('private.outreach_function_config') IS NULL THEN RETURN 0; END IF;
  EXECUTE 'SELECT function_base_url, cron_bearer_token FROM private.outreach_function_config LIMIT 1' INTO v_cfg;
  IF v_cfg.function_base_url IS NULL THEN RETURN 0; END IF;
  IF p_mode = 'poll' THEN
    SELECT count(*) INTO v_due FROM public.channel_accounts WHERE status = 'connected' AND provider <> 'test';
  ELSE
    SELECT count(*) INTO v_due FROM public.messages
     WHERE kind = 'message' AND direction = 'out' AND ((status = 'queued' AND scheduled_for <= now()) OR (status = 'sending' AND updated_at < now() - interval '10 minutes'));
  END IF;
  IF v_due = 0 THEN RETURN 0; END IF;
  BEGIN
    PERFORM net.http_post(url := v_cfg.function_base_url || '/hub-send',
                          headers := jsonb_build_object('Authorization', 'Bearer ' || v_cfg.cron_bearer_token, 'Content-Type', 'application/json'),
                          body := jsonb_build_object('mode', p_mode));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'hub_kick_sender: could not call hub-send: %', SQLERRM;
    RETURN 0;
  END;
  RETURN 1;
END $$;

DO $$
BEGIN
  IF to_regnamespace('cron') IS NULL THEN
    RAISE NOTICE 'pg_cron is not installed here: the hub-send jobs were NOT scheduled (enable pg_cron, then run migration-013 section 13 again).';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'hub-send-kick') THEN PERFORM cron.unschedule('hub-send-kick'); END IF;
  PERFORM cron.schedule('hub-send-kick', '* * * * *', 'SELECT public.hub_kick_sender(''send'')');
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'hub-status-poll') THEN PERFORM cron.unschedule('hub-status-poll'); END IF;
  PERFORM cron.schedule('hub-status-poll', '*/5 * * * *', 'SELECT public.hub_kick_sender(''poll'')');
END $$;

-- 14. consent backfill (flag ON by default; see the header) -----------------------------------------------------------------------------
CREATE FUNCTION public.hub_backfill_booking_consent(p_org uuid DEFAULT NULL, p_dry_run boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE v_cand integer; v_exist integer; v_ins integer := 0;
BEGIN
  CREATE TEMP TABLE _hub_cands ON COMMIT DROP AS
    SELECT c.org_id, c.id AS customer_id, public.normalize_phone_e164(c.phone) AS address
      FROM public.customers c
     WHERE (p_org IS NULL OR c.org_id = p_org) AND NULLIF(btrim(c.phone), '') IS NOT NULL AND public.normalize_phone_e164(c.phone) IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.bookings b WHERE b.customer_id = c.id);
  SELECT count(*), count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.patient_channels pc
                                                   WHERE pc.org_id = k.org_id AND pc.channel = 'sms' AND pc.address = k.address AND pc.purpose = 'service'))
    INTO v_cand, v_exist FROM _hub_cands k;
  IF NOT p_dry_run THEN
    -- never touches an existing row (so never a stopped one), never marketing
    INSERT INTO public.patient_channels (org_id, customer_id, channel, address, purpose, status, source, recorded_at, evidence)
    SELECT k.org_id, k.customer_id, 'sms', k.address, 'service', 'agreed', 'booking', now(),
           'Phone given when booking (backfill, migration 013, ' || to_char(now() AT TIME ZONE 'Asia/Kathmandu', 'FMDD Mon YYYY') || ')'
      FROM _hub_cands k
    ON CONFLICT (org_id, channel, address, purpose) DO NOTHING;
    GET DIAGNOSTICS v_ins = ROW_COUNT;
  END IF;
  DROP TABLE _hub_cands;
  RAISE NOTICE 'hub consent backfill (%): % patients have a phone and a booking; % already had a service-sms row; % %',
    CASE WHEN p_dry_run THEN 'dry run' ELSE 'applied' END, v_cand, v_exist, CASE WHEN p_dry_run THEN 'would insert' ELSE 'inserted' END,
    CASE WHEN p_dry_run THEN v_cand - v_exist ELSE v_ins END;
  RETURN jsonb_build_object('dry_run', p_dry_run, 'patients_with_phone_and_booking', v_cand, 'already_had_a_row', v_exist,
                            'inserted', CASE WHEN p_dry_run THEN 0 ELSE v_ins END, 'would_insert', v_cand - v_exist);
END $$;

DO $$
BEGIN
  IF COALESCE(current_setting('hub.backfill_booking_consent', true), 'on') <> 'off' THEN
    PERFORM public.hub_backfill_booking_consent(NULL, false);
  ELSE
    RAISE NOTICE 'hub consent backfill SKIPPED (hub.backfill_booking_consent = off). Run hub_backfill_booking_consent(NULL, true) for a dry run.';
  END IF;
END $$;

-- 15. the two 012 functions this migration extends (every other line is migration-012's, unchanged) ---------------------------------------
-- _act_resolve: the service role may now act as 'patient' (the inbound webhook). act_undo: a 'hand_back' kind; a practitioner may undo a hand-back
-- THEY made on their own patient; threads with no branch yet are reachable by any front desk.
CREATE OR REPLACE FUNCTION public._act_resolve(p_ctx jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  v_kind text; v_org uuid; v_branch uuid; v_agent text; v_appr uuid; v_u record; v_jwt_role text;
BEGIN
  -- the JWT role claim, read directly (auth.role() differs between Supabase auth versions)
  v_jwt_role := coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role');
  IF current_setting('role', true) = 'service_role' AND v_jwt_role = 'service_role' THEN
    IF p_ctx IS NULL OR jsonb_typeof(p_ctx) <> 'object' THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'A service-role call needs a p_ctx object.');
    END IF;
    BEGIN
      v_org := (p_ctx ->> 'org_id')::uuid;
      v_branch := (p_ctx ->> 'branch_id')::uuid;
      v_appr := (p_ctx ->> 'approved_by')::uuid;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'p_ctx has an invalid id.');
    END;
    v_kind := p_ctx ->> 'actor_kind';
    v_agent := p_ctx ->> 'agent';
    IF v_kind IS NULL OR v_kind NOT IN ('agent', 'rule', 'system', 'patient') THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'actor_kind must be agent, rule, system or patient.');
    END IF;
    IF v_kind = 'agent' AND (v_agent IS NULL OR v_agent !~ '^[a-z][a-z0-9_]{1,40}$') THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'An agent call needs a valid agent name.');
    END IF;
    IF v_org IS NULL OR NOT EXISTS (SELECT 1 FROM public.organizations WHERE id = v_org) THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'org_id is required and must exist.');
    END IF;
    IF v_branch IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.branches WHERE id = v_branch AND org_id = v_org) THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'branch_id is not in that organization.');
    END IF;
    IF v_appr IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_appr AND org_id = v_org AND is_active IS NOT FALSE) THEN
      RETURN jsonb_build_object('ok', false, 'code', 'INVALID_CONTEXT', 'message', 'approved_by is not an active user of that organization.');
    END IF;
    RETURN jsonb_build_object('ok', true, 'kind', v_kind, 'user_id', NULL, 'role', NULL, 'org_id', v_org, 'branch_id', v_branch,
                              'branch_ids', NULL, 'agent', CASE WHEN v_kind = 'agent' THEN v_agent END, 'approved_by', v_appr,
                              'reason_source', p_ctx ->> 'reason_source', 'service', true, 'ctx_ignored', false);
  END IF;

  IF auth.uid() IS NOT NULL THEN
    SELECT id, role::text AS role, org_id, is_active INTO v_u FROM public.users WHERE id = auth.uid();
    IF v_u.id IS NOT NULL AND v_u.is_active IS NOT FALSE THEN
      RETURN jsonb_build_object('ok', true, 'kind', 'person', 'user_id', v_u.id, 'role', v_u.role, 'org_id', v_u.org_id, 'branch_id', NULL,
                                'branch_ids', to_jsonb(public.get_user_branch_ids()), 'agent', NULL, 'approved_by', NULL,
                                'reason_source', NULL, 'service', false, 'ctx_ignored', p_ctx IS NOT NULL);
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', false, 'code', 'FORBIDDEN', 'message', 'Your account cannot run this action.');
END $$;

CREATE OR REPLACE FUNCTION public.act_undo(p_action_id uuid, p_reason text DEFAULT NULL, p_ctx jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $$
DECLARE
  ctx jsonb; a public.action_log; v_inputs jsonb; u jsonb; b public.bookings; v_res jsonb; v_code text; v_msg text; r jsonb; cv public.conversations; v_ev uuid;
BEGIN
  ctx := public._act_resolve(p_ctx);
  IF NOT (ctx ->> 'ok')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'action_id', NULL, 'data', NULL, 'error', jsonb_build_object('code', ctx ->> 'code', 'message', ctx ->> 'message'));
  END IF;
  v_inputs := jsonb_build_object('action_id', p_action_id, 'reason', p_reason) || public._act_ctx_inputs(p_ctx, ctx);

  SELECT * INTO a FROM public.action_log WHERE id = p_action_id FOR UPDATE;
  IF a.id IS NULL OR a.org_id IS DISTINCT FROM (ctx ->> 'org_id')::uuid OR NOT (public._act_in_scope(ctx, a.org_id, a.branch_id)
                                                 OR (a.branch_id IS NULL AND a.target_table = 'conversations' AND public._hub_scope(ctx, a.org_id, NULL, NULL))) THEN
    RETURN public._act_finish(ctx, 'undo', (ctx ->> 'org_id')::uuid, NULL, v_inputs, false, NULL, 'ACTION_NOT_FOUND', 'Action not found.', NULL, NULL, NULL);
  END IF;

  -- who may undo: anyone who may run bookings actions in that branch; a practitioner only a status change THEY made on their own booking; an agent only with approval
  IF ctx ->> 'kind' = 'person' THEN
    IF ctx ->> 'role' = 'practitioner' THEN
      IF NOT COALESCE((a.action = 'booking.set_status' AND a.actor_user_id = (ctx ->> 'user_id')::uuid AND a.target_id IS NOT NULL AND public.is_my_booking(a.target_id))
                       OR (a.action = 'conversation.hand_back' AND a.actor_user_id = (ctx ->> 'user_id')::uuid AND a.target_id IS NOT NULL
                           AND public.is_my_patient((SELECT c.customer_id FROM public.conversations c WHERE c.id = a.target_id))), false) THEN
        RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'You can only undo your own status changes.', a.target_id, NULL, a.target_table);
      END IF;
    ELSIF ctx ->> 'role' NOT IN ('staff', 'manager', 'admin') THEN
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'Your role cannot undo actions.', a.target_id, NULL, a.target_table);
    END IF;
  ELSIF ctx ->> 'kind' = 'agent' THEN
    IF (ctx ->> 'approved_by') IS NULL THEN
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'APPROVAL_REQUIRED', 'Undoing needs a person''s approval.', a.target_id, NULL, a.target_table);
    END IF;
  ELSE
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'FORBIDDEN', 'This kind of caller cannot undo actions.', a.target_id, NULL, a.target_table);
  END IF;

  IF a.undone_by_action IS NOT NULL THEN
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_ALREADY', 'This action was already undone.', a.target_id, NULL, a.target_table);
  END IF;
  u := a.undo;
  IF NOT a.ok OR u IS NULL THEN
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_NOT_POSSIBLE', 'This action cannot be undone.', a.target_id, NULL, a.target_table);
  END IF;
  IF (u ->> 'expires_at')::timestamptz < now() THEN
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_EXPIRED', 'The time to undo this action has passed.', a.target_id, NULL, a.target_table);
  END IF;

  IF u ->> 'kind' = 'flag' THEN
    UPDATE public.booking_flags SET cleared_at = now() WHERE id = (u ->> 'flag_id')::uuid AND cleared_at IS NULL;
    IF NOT FOUND THEN
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_STALE', 'The flag was already cleared.', a.target_id, NULL, a.target_table);
    END IF;
    v_res := public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, true,
      jsonb_build_object('undone_action', a.id, 'kind', 'flag'), NULL, NULL, a.target_id, NULL, a.target_table);
    UPDATE public.action_log SET undone_by_action = (v_res ->> 'action_id')::uuid, undone_reason = p_reason WHERE id = a.id;
    RETURN v_res;
  END IF;

  IF u ->> 'kind' = 'hand_back' THEN
    SELECT * INTO cv FROM public.conversations WHERE id = a.target_id FOR UPDATE;
    IF cv.id IS NULL OR cv.updated_at IS DISTINCT FROM (u ->> 'expect_updated_at')::timestamptz THEN
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_STALE', 'This conversation changed after the hand-back, so it can''t be undone.', a.target_id, NULL, a.target_table);
    END IF;
    UPDATE public.conversations
       SET state = u #>> '{prior,state}', handled_by = (u #>> '{prior,handled_by}')::uuid,
           needs_person_since = (u #>> '{prior,needs_person_since}')::timestamptz, urgent = COALESCE((u #>> '{prior,urgent}')::boolean, false)
     WHERE id = cv.id;
    v_ev := public._hub_event(cv.id, 'handed_back_undone', public._hub_user_name((ctx ->> 'user_id')::uuid) || ' undid the hand-back',
                              jsonb_build_object('undone_action', a.id), 'person', (ctx ->> 'user_id')::uuid, NULL);
    v_res := public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, true,
      jsonb_build_object('undone_action', a.id, 'kind', 'hand_back'), NULL, NULL, a.target_id, NULL, a.target_table);
    UPDATE public.messages SET action_id = (v_res ->> 'action_id')::uuid WHERE id = v_ev;
    UPDATE public.action_log SET undone_by_action = (v_res ->> 'action_id')::uuid, undone_reason = p_reason WHERE id = a.id;
    RETURN v_res;
  END IF;

  -- booking-level undo (set_status, reschedule): the booking must be exactly as the action left it
  SELECT * INTO b FROM public.bookings WHERE id = a.target_id FOR UPDATE;
  IF b.id IS NULL OR b.updated_at IS DISTINCT FROM (u ->> 'expect_updated_at')::timestamptz THEN
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_STALE', 'This booking changed after the action, so it can''t be undone.', a.target_id, NULL, a.target_table);
  END IF;
  IF b.is_locked THEN
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'DAY_LOCKED', 'This day has been closed. No further modifications allowed.', a.target_id, NULL, a.target_table);
  END IF;

  IF u ->> 'kind' = 'set_status' THEN
    IF u ->> 'to' = 'In-Progress' AND EXISTS (SELECT 1 FROM public.consultations WHERE booking_id = b.id) THEN
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_NOT_POSSIBLE', 'A consultation was already started for this booking.', a.target_id, NULL, a.target_table);
    END IF;
    BEGIN
      UPDATE public.bookings
         SET status = (u ->> 'from')::public.booking_status,
             cancellation_reason = CASE WHEN u ->> 'to' IN ('Cancelled', 'No Show') THEN u ->> 'prior_cancellation_reason' ELSE cancellation_reason END
       WHERE id = b.id;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      IF v_code IN ('P0003', '23P01') THEN v_code := 'UNDO_BLOCKED'; v_msg := 'The slot or chair is no longer free, so this can''t be undone.'; END IF;
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, v_code, v_msg, a.target_id, NULL, a.target_table);
    END;
  ELSIF u ->> 'kind' = 'reschedule' THEN
    r := u -> 'prior';
    BEGIN
      UPDATE public.bookings
         SET date = (r ->> 'date')::date, start_time = (r ->> 'start_time')::time, end_time = (r ->> 'end_time')::time,
             dentist_id = (r ->> 'dentist_id')::uuid, dentist_name_snapshot = r ->> 'dentist_name_snapshot',
             chair_id = (r ->> 'chair_id')::uuid, chair_name_snapshot = r ->> 'chair_name_snapshot'
       WHERE id = b.id;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      IF v_code IN ('P0003', '23P01') THEN v_code := 'UNDO_BLOCKED'; v_msg := 'The old slot is no longer free, so this can''t be undone.'; END IF;
      RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, v_code, v_msg, a.target_id, NULL, a.target_table);
    END;
    BEGIN
      DELETE FROM public.booking_dentists WHERE booking_id = b.id;
      INSERT INTO public.booking_dentists (booking_id, dentist_id, start_time, end_time)
        SELECT b.id, (x ->> 'dentist_id')::uuid, (x ->> 'start_time')::time, (x ->> 'end_time')::time
          FROM jsonb_array_elements(COALESCE(u -> 'prior_booking_dentists', '[]'::jsonb)) x;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'act_undo booking_dentists restore failed: %', SQLERRM;
    END;
  ELSE
    RETURN public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, false, NULL, 'UNDO_NOT_POSSIBLE', 'This action cannot be undone.', a.target_id, NULL, a.target_table);
  END IF;

  v_res := public._act_finish(ctx, 'undo', a.org_id, a.branch_id, v_inputs, true,
    jsonb_build_object('undone_action', a.id, 'kind', u ->> 'kind'), NULL, NULL, a.target_id, NULL, a.target_table);
  UPDATE public.action_log SET undone_by_action = (v_res ->> 'action_id')::uuid, undone_reason = p_reason WHERE id = a.id;
  RETURN v_res;
END $$;

-- 16. grants: actions for signed-in users and the service role; the webhook / worker functions for the service role only; helpers for nobody --------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.act_message_send(uuid, uuid, text, uuid, text, jsonb, text, uuid, text, text, jsonb)',
    'public.act_message_retry(uuid, text, text, jsonb)',
    'public.act_conversation_take_over(uuid, jsonb)',
    'public.act_conversation_hand_back(uuid, jsonb)',
    'public.act_conversation_assign(uuid, uuid, text, jsonb)',
    'public.act_conversation_handoff(uuid, text, text, boolean, uuid, jsonb)',
    'public.act_consent_record(uuid, text, text, text, text, text, jsonb)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
  END LOOP;

  FOREACH f IN ARRAY ARRAY[
    'public.act_message_receive(uuid, text, text, text, timestamptz, jsonb)',
    'public.hub_find_account(text, text)',
    'public.hub_list_accounts(text)',
    'public.hub_rate_check(uuid, integer)',
    'public.hub_claim_messages(integer)',
    'public.hub_record_send_result(uuid, boolean, text, numeric, text)',
    'public.hub_apply_delivery_status(uuid, text, text, timestamptz, text)',
    'public.hub_poll_accounts()',
    'public.hub_pending_delivery(uuid, interval)',
    'public.hub_mark_polled(uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;

  FOREACH f IN ARRAY ARRAY[
    'public._hub_scope(jsonb, uuid, uuid, uuid)',
    'public._hub_fail(text, text, uuid, uuid)',
    'public._hub_user_name(uuid)',
    'public._hub_event(uuid, text, text, jsonb, text, uuid, text)',
    'public._hub_quiet_end(public.channel_accounts, timestamptz)',
    'public._hub_consent(uuid, text, text, text)',
    'public._hub_render(text, jsonb)',
    'public._hub_booking_fields(uuid, uuid)',
    'public._hub_send_core(jsonb, uuid, uuid, text, uuid, text, jsonb, text, uuid, text, text, uuid, text)',
    'public._hub_provider_idempotent(text)',
    'public.hub_kick_sender(text)',
    'public.hub_backfill_booking_consent(uuid, boolean)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role', f);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.hub_mark_read(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hub_mark_read(uuid) TO authenticated;

COMMIT;
