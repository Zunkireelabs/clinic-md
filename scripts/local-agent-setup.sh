#!/usr/bin/env bash
# LOCAL ONLY. Sets up the Follow-up agent (migration 017) on the local Supabase stack so it can be tried end to end with the hub's TEST provider:
#   * AI switch on, this month's AI budget, follow_up switched on with a ceiling of 2
#   * local test templates (English and Nepali; NONE clinical: an agent can never send a clinical template) attached to the five playbooks
#   * playbook levels for the check: confirmation, reply and 6 pm flag at level 2 (auto); day-before reminder and aftercare at level 1 (drafts)
# No template wording goes into the migration: this script is the only place the local test wording lives. Refuses to run against anything but
# the local stack. Needs scripts/local-hub-setup.sh to have run first (channel account, function URL, bearer token).
#
# Then:  supabase functions serve --env-file supabase/functions/.env.hub.local
#        (free-text replies need OPENAI_API_KEY in that file; without it they are handed off. Never commit it.)
set -euo pipefail

STATUS="$(supabase status -o env 2>/dev/null)"
DB_URL="$(echo "$STATUS" | grep '^DB_URL=' | cut -d= -f2- | tr -d '"')"
API_URL="$(echo "$STATUS" | grep '^API_URL=' | cut -d= -f2- | tr -d '"')"
case "$DB_URL$API_URL" in
  *127.0.0.1*127.0.0.1*|*localhost*localhost*) ;;
  *) echo "Refusing to run: stack does not look local." >&2; exit 1 ;;
esac

ORG_ID="${AGENT_ORG_ID:-00000000-0000-0000-0000-000000000001}"
psql "$DB_URL" -tAc "select 1 from public.channel_accounts where org_id = '$ORG_ID' and provider = 'test' and status = 'connected' limit 1" | grep -q 1 \
  || { echo "No connected test channel account: run scripts/local-hub-setup.sh first." >&2; exit 1; }
psql "$DB_URL" -tAc "select to_regclass('public.agent_jobs')" | grep -q agent_jobs || { echo "migration-017 is not applied locally." >&2; exit 1; }

psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL
update public.organizations set ai_consultation_enabled = true where id = '$ORG_ID';
insert into public.ai_budgets (org_id, month, amount_npr, warn_pct)
  values ('$ORG_ID', public._ai_month_start(), 5000, 80) on conflict (org_id, month) do nothing;
insert into public.agent_settings (org_id, branch_id, agent, enabled, max_level)
  values ('$ORG_ID', null, 'follow_up', true, 2)
  on conflict on constraint agent_settings_key do update set enabled = true, max_level = 2, updated_at = now();

insert into public.message_templates (org_id, name, channel, language, body, purpose, clinical) values
  ('$ORG_ID', 'agent-booking-confirmation', null, 'en', 'Hi {patient_name}, your {treatment} at {clinic} is booked for {date} at {time}. Reply YES to confirm.', 'service', false),
  ('$ORG_ID', 'agent-booking-confirmation', null, 'ne', 'नमस्ते {patient_name}, {clinic} मा तपाईंको {treatment} {date} {time} बजे बुक भयो। पुष्टि गर्न हो पठाउनुहोस्।', 'service', false),
  ('$ORG_ID', 'agent-day-before-reminder', null, 'en', 'Reminder: your {treatment} at {clinic} is tomorrow, {date} at {time}.', 'service', false),
  ('$ORG_ID', 'agent-day-before-reminder', null, 'ne', 'सम्झना: {clinic} मा तपाईंको {treatment} भोलि {date} {time} बजे हो।', 'service', false),
  ('$ORG_ID', 'agent-reply-confirmed', null, 'en', 'Thank you {patient_name}, your {treatment} on {date} at {time} is confirmed.', 'service', false),
  ('$ORG_ID', 'agent-reply-confirmed', null, 'ne', 'धन्यवाद {patient_name}, {date} {time} बजेको {treatment} पुष्टि भयो।', 'service', false),
  ('$ORG_ID', 'agent-aftercare-check-in', null, 'en', 'Hi {patient_name}, we hope your {treatment} went well. Call the clinic if you need us.', 'service', false)
on conflict (org_id, name, language, coalesce(channel, 'any')) do nothing;

update public.playbooks p set template_id = t.id, level = v.level, enabled = true, settings = p.settings || v.extra::jsonb, updated_at = now()
  from (values
    ('booking_confirmation', 'agent-booking-confirmation', 2, '{}'),
    ('day_before_reminder',  'agent-day-before-reminder',  1, '{}'),
    ('reply_to_confirm',     'agent-reply-confirmed',      2, '{}'),
    ('not_confirmed_by_6pm', null,                         2, '{}'),
    ('aftercare_check_in',   'agent-aftercare-check-in',   1, '{"treatments": ["Root Canal Treatment", "Extraction"]}')
  ) v(key, tname, level, extra)
  left join public.message_templates t on t.org_id = '$ORG_ID' and t.name = v.tname and t.language = 'en'
 where p.org_id = '$ORG_ID' and p.branch_id is null and p.agent = 'follow_up' and p.key = v.key and (v.tname is null or t.id is not null);
SQL
echo "==> Follow-up agent ready locally for org $ORG_ID (no provider key written). Serve the functions:"
echo "    supabase functions serve --env-file supabase/functions/.env.hub.local"
echo "    The runner is kicked every minute by pg_cron (agent-kick); scans run every 15 minutes."
