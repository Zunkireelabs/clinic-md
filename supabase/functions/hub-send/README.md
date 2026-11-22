# hub-send

The communication hub's sender (CMD-88, migration 013). Called by pg_cron through `public.hub_kick_sender()`, with the same bearer token the outreach drain
uses (`CRON_BEARER_TOKEN`; the function URL and token are read from `private.outreach_function_config`):

- **every minute**, only when a message is due: `{"mode":"send"}`. It claims due messages with `hub_claim_messages` (`FOR UPDATE SKIP LOCKED`), sends each
  through the provider chosen by `channel_accounts.provider`, and records the result (`sent` with the provider id and credits, or `failed` with the error);
- **every 5 minutes**: `{"mode":"poll"}`. For providers that only offer a pull report (Aakash) it asks which messages are waiting, pulls the report, and
  marks the delivered ones. A message that never appears in the report stays `sent`.

## Rules that protect patients

- Consent and quiet hours are re-checked at claim time (a patient who replied STOP after the message was queued is not texted; a message that is now in
  quiet hours is pushed to the end of the window). The one STOP confirmation reply is exempt.
- A message stuck in `sending` for 10 minutes is re-queued **only** for a provider that declares idempotent sends (`test`). Otherwise it becomes `failed`
  with "outcome unknown: check the provider report" and is **never re-sent automatically** (a duplicate patient text is worse than a missed one). A person
  can retry it (`message.retry`).
- A network error, a 5xx or an unreadable answer is recorded as "outcome unknown"; only an explicit refusal from the provider is a plain failure.

## Env (edge-function secrets; never in a table or a file in git)

| Variable | For |
|---|---|
| `CRON_BEARER_TOKEN` | authenticating the pg_cron call (shared with `send-message`) |
| `<secret_ref>` | a channel account's API key, for example `AAKASH_AUTH_TOKEN`: the account row stores only this **name** |
| `<secret_ref>_INBOUND_TOKEN` | the Aakash inbound path token (used by `hub-inbound`) |
| `HUB_TEST_WEBHOOK_SECRET` | signing the test provider's webhooks (used by `hub-inbound`) |

Deploying is a separate step by a human: `supabase functions deploy hub-send hub-inbound`, then set the secrets with `supabase secrets set`. Locally:
`scripts/local-hub-setup.sh`, then `supabase functions serve --env-file supabase/functions/.env.hub.local`.
