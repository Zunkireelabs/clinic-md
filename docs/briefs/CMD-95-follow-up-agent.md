# Brief: The Follow-up agent (jobs, model client, confirmations, reminders, replies, scorecard) · CMD-95

**Status:** ready to build, 2026-11-22 · **Phase:** 2 · **Parent:** CMD-81 · **Blocked by:** CMD-90 (PR #20) · **Lead:** lead session
**Follows:** `docs/PRODUCT-BRIEF.md` §7.5 (agent platform) and §12 (Phase 2 exit test); briefs CMD-78 (012 actions),
hub-data-model (013), CMD-93 (015 consent at booking), CMD-90 (016 playbooks, work queue, budget).
**Boards (approved):** Agents › Follow-up agent (playbooks, levels, scorecard), Home › Needs you (approval cards),
Inbox (hand-offs), Calendar (agent marks, "not confirmed", running-late draft), Agents › Usage and budget.

## 1. What and why

Phase 2's exit test: "for two weeks at one clinic, confirmations and reminders go out automatically through actions,
replies land in the inbox, every send is logged with consent, and the no-show and confirmation rates are reported
against the baseline." 011–016 built the parts. This ticket makes the first agent run on them, **in today's app**,
with no new screens.

**In scope:**
1. The job queue and the scheduler.
2. The model client and spend recording.
3. Five playbooks:
   - booking confirmation;
   - day-before reminder;
   - reply to confirm;
   - not confirmed by 6:00 pm;
   - aftercare check-in.
4. Reply handling, rules first, with AI only for free text.
5. Outcomes and the scorecard numbers.
6. Read functions for the Usage and AI screens (CMD-90 left them service-only).

**Not in scope:**
- any screen;
- the running-late notice (Calendar board; its own ticket later);
- WhatsApp (the hub stays channel-neutral; SMS today);
- the Front desk agent, which handles conversations at level 3.

## 2. Where to work

- Worktree from `origin/feature/CMD-90-agent-platform`. **Migration 017** is claimed. The PR targets #20.
- New edge function `agent-run` (Deno, same shape as `hub-send`: bearer-token cron call, service role inside).
  Local only. Not deployed; deploying is a human step.

## 3. Design (checkpoint: send a design note and wait for approval before SQL or code)

**3.1 Jobs (017).** `agent_jobs`:
- columns: `id`, `org_id`, `branch_id`, `agent`, `playbook_id`, `event`, `booking_id`, `customer_id`,
  `conversation_id`, `message_id`, `run_after`, `status` (`queued`, `running`, `done`, `skipped`, `failed`), `attempts`,
  `last_error`, `result` jsonb, `created_at`;
- uniqueness: one job per (`playbook_id`, `booking_id`, `event`), **for idempotency: a booking never gets two
  confirmations**;
- claim with `FOR UPDATE SKIP LOCKED`, the same pattern as `hub_claim_messages`.

Enqueued by:
- `booking_created`: trigger on booking insert, only for enabled playbooks, `run_after = now()`;
- `day_before`: a pg_cron scan every 15 minutes that enqueues bookings for tomorrow once the playbook's send time
  (default 9:00 am, Nepal time) has passed;
- `patient_reply`: when `act_message_receive` stores an inbound message on a conversation whose patient has a
  booking in the next 7 days that isn't confirmed yet;
- `not_confirmed`: a 6:00 pm scan; it uses the existing `act_booking_flag_not_confirmed`;
- `visit_completed`: trigger when a booking becomes `Completed`, for treatments the playbook lists (extraction, root
  canal); `run_after` = the next day at the send time.

**3.2 The runner (`agent-run`).** It claims jobs, then for each one:
1. `ai_may_run` decides whether AI may be used.
2. Consent and quiet hours are not re-checked here: the actions check them.
3. It builds the action:
   - Level 2 (auto by rule) sends with `act_message_send` as the agent (service ctx, template, booking fields).
   - Level 1 (draft) creates an approval item with `act_work_propose`, so a person approves it on Home.
4. It records the job result.

The agent never calls a table directly, only `act_*` functions. With AI off or the budget used up:
- confirmations and replies on **fixed templates still send** (the approved boards say so);
- anything needing AI becomes a hand-off to the front desk.

**3.3 Replies.**
- **Rules first, no AI:**
  - YES / Y / OK / हो / ठिक छ / "ho" / "huncha" → `act_booking_set_status(Confirmed)` with
    `reason_source = 'patient_reply'`, then the confirmation template;
  - NO / CANCEL / रद्द → cancel only where 012 lets an agent (unpaid, patient reply). Otherwise hand off.
  - Keep the word lists in one table (`agent_reply_rules`) per language, seeded with these. Tests use them.
- **Free text** goes to the model client to classify: `confirm`, `cancel`, `reschedule`, `question`, `clinical`,
  `urgent`, `other`.
  - Only `confirm` acts on its own, and only at confidence ≥ 0.9.
  - Everything else is a hand-off (`act_conversation_handoff` with the matching reason).
  - Clinical and urgent words (bleeding, swelling, pain, fever, रगत, सुन्निएको) are a rule-based hand-off **before**
    any model call.
- **The agent never writes free text to a patient** in this ticket. Outgoing messages are templates only; a
  confirmation reply that also has a question sends the confirmation and hands the question off (the Calendar
  Messages board shows this).

**3.4 The model client** (`supabase/functions/_shared/model.ts`):
- one function per job type (`classify`); provider and model from one config (OpenAI, `gpt-4o`, the same provider
  the Settings › AI board names);
- a timeout and one retry; the API key from the function's env, never logged;
- every call recorded with `ai_record_spend` (tokens and an NPR cost from a price table in the same config file);
- only the reply text and the booking's treatment and date are sent; no patient name, no history.

**3.5 Outcomes and scorecard.** `agent_outcomes` (or columns on `agent_jobs`): confirmed before the visit (yes/no and
when), cancelled, no-show, no reply. Read functions (authenticated, `can_read_money` where cost is involved):
- `agent_scorecard(agent, branch, from, to)`: confirmed-before-visit %, no-show %, the same for the 4 weeks before
  the agent was turned on (the baseline), drafts waiting, undone by staff;
- `ai_usage_summary(month)`: spent, budget, %, state, by agent and branch, cost per confirmed visit.

## 4. Tests

- **SQL** (`tenant-isolation.sql`, new section):
  - jobs are enqueued once per (playbook, booking, event);
  - nothing is enqueued for a disabled playbook or agent;
  - the claim skips locked rows;
  - org B can't read org A's jobs or outcomes;
  - the read functions respect roles (a practitioner gets no cost data).
- **Deno unit tests** for the runner and model client: the reply-rule matcher (English, Nepali, romanised); the
  clinical-word hand-off fires before any model call; level 1 vs level 2 paths; the AI-off / budget-used-up paths
  (templates still send, AI paths hand off); the spend row is written; the key is never logged.
- **Show red** for at least the idempotency guard and the clinical-word guard.

## 5. Acceptance checks (the lead runs these)

1. 017 applies after 016, rolls back cleanly, re-applies; `test:rls`, `npm test` and `npm run build` pass; the Deno
   tests pass.
2. End to end locally, with the hub's test provider and `supabase functions serve`:
   - a new booking with the confirmation at level 2 → confirmation sent;
   - "YES" → booking `Confirmed`, the action log shows the Follow-up agent;
   - "ठिक छ" → confirmed;
   - "can I come at 5 instead?" → hand-off with reason `asks_to_change`;
   - "my cheek is swollen" → urgent clinical hand-off with no model call;
   - day-before reminder at level 1 → a work item → staff@ approves → sent with approved_by.
3. With AI off: the templates still send, and the free-text reply is handed off.
4. The scorecard function returns sane numbers on the seeded data.
5. No provider key in any file, table or log.

## 6. Handoff

The DEV-APPROACH template, ending with **Not verified**. Say:
- 017 is not applied to prod and needs 011–016 first;
- `agent-run` is not deployed;
- the real OpenAI and Aakash calls are untested (CMD-92).
