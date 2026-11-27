# agent-run

The Follow-up agent's runner (CMD-95). pg_cron calls it through `public.agent_kick_runner()` every minute when a job is due; it claims jobs with
`agent_claim_jobs`, runs the playbook for each, and records the outcome with `agent_finish_job`. It calls only `act_*` functions and the service
functions; it never reads or writes a table. Logic and tests: `supabase/functions/_shared/agent.ts`, `model.ts` (Vitest, run by `npm test`).

Env: `CRON_BEARER_TOKEN` (shared with hub-send), `OPENAI_API_KEY` (free-text replies only; without it, free text is handed off), the usual Supabase
URL and service key. Local setup: `scripts/local-agent-setup.sh`. Not deployed; deploying is a human step.
