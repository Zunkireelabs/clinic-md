# Brief: Agent platform tables, part 1 (playbooks, autonomy, work queue, AI budget) · CMD-90

**Status:** ready to build, 2026-11-22 · **Phase:** 2 · **Parent:** CMD-81 · **Lead:** lead session
**Follows:** `docs/PRODUCT-BRIEF.md` §7.5 (agent platform, autonomy levels, learning loop) and §2 (decisions 2026-11-22),
`docs/briefs/CMD-78-action-layer.md` (012: `action_log`, `_act_resolve`, `_act_finish`, `act_undo`),
`docs/briefs/hub-data-model.md` (013), migrations 006 (`ai_usage` rate limit) and 010 (`ai_consultation_enabled`).
**Boards it serves (canvas, approved):** Agents overview and Follow-up agent page (on/off per branch, level per playbook,
owner's ceiling), Home › Needs you (approval cards: Approve, Edit, Reject), Agents › Usage and budget, and Settings ›
AI and privacy (drawn 2026-11-22, awaiting approval: AI on/off by the owner, per-agent switches).

## 1. What and why

The Follow-up agent (next ticket) needs somewhere to keep its playbooks and levels, a queue where its drafts wait for a
person, and a budget that stops it when the money is used up. This ticket builds those **tables and actions only**.
No agent runs, no model is called, and no screen is built here.

**In scope:**
1. Agent settings per clinic and branch: agent on/off, and the owner's highest allowed level (the ceiling).
2. Playbooks: event → agent, channel, template, autonomy level.
3. The work queue: drafts and exceptions waiting for a person, plus approve, edit and reject, each recorded for the
   learning loop.
4. AI money: a cost ledger per AI call, a monthly budget, the budget's state (ok, warning at 80%, used up), and the
   clinic's AI switch, run by the owner.

**Not in scope** (the Follow-up agent ticket): the event and job queue, triggers and schedules, the model client,
scorecards and outcomes, and the clinic brain.

## 2. Where to work

- Worktree from the top of the stack:
  `git worktree add ../clinic-md-CMD-90 -b feature/CMD-90-agent-platform origin/feature/CMD-93-booking-consent`
- **Migration 016** is claimed. The PR targets `feature/CMD-93-booking-consent` (#19).
- Local Supabase only; apply by hand with psql (CMD-85).

## 3. Data model (checkpoint: send it to the lead and wait for approval before writing SQL)

Send a short design note with: every table (columns, keys, checks), every RLS policy, every function and who may call
it, and how undo works for each action. Use this as the starting point; change it if you find a better fit, and say why.

**3.1 `agent_settings`**: `org_id`, `branch_id` (NULL = the clinic-wide row), `agent` (text, `^[a-z][a-z0-9_]{1,40}$`;
today `follow_up`, `scribe`), `enabled` boolean, `max_level` smallint 1–3 (the owner's ceiling, org-wide row only),
`updated_by`, `updated_at`. Unique (`org_id`, `branch_id`, `agent`), NULLs not distinct. A branch row overrides
`enabled` for that branch.

**3.2 `playbooks`**: `id`, `org_id`, `branch_id` (NULL = every branch), `agent`, `key` (e.g. `booking_confirmation`,
`day_before_reminder`, `aftercare_check_in`), `name`, `event` (text; a fixed list in a CHECK: `booking_created`,
`day_before`, `visit_completed`, `no_reply`), `template_id` (→ `message_templates`, nullable), `channel` (nullable =
follow the sending rules), `level` smallint 1–3, `enabled`, `settings` jsonb (e.g. hours before, wait times),
`created_by`, `updated_by`, timestamps. A level above the agent's `max_level` is refused by the action, not just the UI.

**3.3 `agent_work_items`** (the work queue): `id`, `org_id`, `branch_id`, `agent`, `playbook_id`, `kind`
(`approval`, `exception`), `status` (`open`, `approved`, `edited`, `rejected`, `failed`, `expired`), `urgent`,
`title`, `summary` (the agent's first-person line), `proposed_action` (text: an `act_*` name from an allow-list),
`proposed_inputs` jsonb, `sources` jsonb (the records the agent used, for "Why"), `customer_id`, `booking_id`,
`conversation_id`, `expires_at`, `decided_by`, `decided_at`, `decision_reason`, `final_inputs` jsonb (what actually ran,
when edited), `result_action_id` (→ `action_log`), `created_at`.
Hand-offs stay in `conversations` (013). A view **`work_queue`** (`security_invoker`) unions the open items with the
`needs_person` conversations, so Home reads one list.

**3.4 `ai_spend`** (the cost ledger; `ai_usage` is already the per-user rate limit from 006, so leave it alone):
`id`, `org_id`, `branch_id`, `agent`, `job` (`text`, `transcription`, `vision`), `provider`, `model`, `units` jsonb
(tokens in and out, audio seconds), `cost_npr` numeric(12,4), `work_item_id`, `consultation_id`, `created_at`.
Written only by a service-role function.

**3.5 `ai_budgets`**: `org_id`, `month` (date, first of the month), `amount_npr`, `warn_pct` (default 80), `set_by`,
`set_at`. Primary key (`org_id`, `month`). With no row for this month, last month's amount carries over.

## 4. Actions (all through the 012 pattern: `_act_resolve`, scope, one `action_log` row, undo where possible)

| Action | Who | Undo |
|---|---|---|
| `act_agent_set_enabled(agent, branch, enabled)` | owner; manager for their branch | yes |
| `act_agent_set_ceiling(agent, max_level)` | owner only. Lowering it lowers every playbook above it, in the same action | yes (restores the levels) |
| `act_playbook_set_level(playbook, level)` | owner and manager, ≤ ceiling | yes |
| `act_playbook_set_enabled(playbook, enabled)` | owner and manager | yes |
| `act_work_propose(...)` | agent or rule only (service role). Refuses if the agent is off for that branch, the clinic's AI is off, or the budget is used up (except the Scribe) | n/a |
| `act_work_approve(item, edited_inputs?)` | person in scope (practitioner: only their own patients). Runs `proposed_action` with `approved_by` = the person; status `approved`, or `edited` with `final_inputs` if inputs changed; `failed` + error code if the action refuses | the inner action's own undo |
| `act_work_reject(item, reason)` | person in scope; a reason is required | no |
| `act_ai_set_enabled(enabled)` | owner only. Turning on needs a budget for this month | yes |
| `act_ai_budget_set(amount_npr)` | owner only | yes |

- `act_work_approve` must call the inner action as a normal **person** call, so all its own checks (consent, quiet
  hours, scope) run again. Never trust the stored draft.
- The `proposed_action` allow-list for now: `act_message_send`, `act_booking_set_status`, `act_booking_flag_not_confirmed`.
- **The AI switch:** `act_ai_set_enabled` writes `organizations.ai_consultation_enabled` (rename not in scope).
  010's rule stays: **no** UPDATE policy on `organizations`, and the existing test (an admin's direct UPDATE touches 0
  rows) must still pass. The owner changes it only through this action.

**Service functions** (service role only, no `authenticated` grant):
- `ai_record_spend(...)`;
- `ai_budget_status(org)` → spent, amount, pct, state (`ok`, `warn`, `used_up`);
- `ai_may_run(org, branch, agent)` → false when the clinic's AI is off, the agent is off, or the budget is used up and
  the agent isn't `scribe`;
- `agent_expire_work_items()` (sets `expired` past `expires_at`; scheduled by pg_cron locally like `hub-send-kick`).

## 5. RLS

- All five tables: RLS on, no direct writes for any API role (same as `action_log`).
- `agent_settings`, `playbooks`: read for every staff role in the org. A practitioner reads them too: they're not money.
- `agent_work_items` and `work_queue`: admin and admin_viewer org-wide; staff and manager their branches; practitioner
  only items whose `customer_id` is `is_my_patient`.
- `ai_spend` and `ai_budgets`: money. Use CMD-83's `can_read_money()`, so practitioners never see them.

## 6. Tests (`supabase/tests/tenant-isolation.sql`)

- Cross-org: org B can't read or act on org A's settings, playbooks, items or spend.
- Every action: the allowed roles succeed; manager is refused on the ceiling, the AI switch and the budget; staff are
  refused on settings; practitioner is refused on another practitioner's patient's item.
- Ceiling: a level above it is refused; lowering it lowers the playbooks; undo restores them.
- Approve runs the inner action with `approved_by`; an edited approval stores `final_inputs`; an inner refusal (e.g.
  `STOPPED`) marks the item `failed` and changes nothing else.
- `act_work_propose` is refused when AI is off, the agent is off, or the budget is used up; the Scribe is still allowed
  when the budget is used up.
- The budget state flips at 80% and 100%; last month's amount carries over.
- The AI switch: the owner's action changes it; an admin's direct UPDATE still touches 0 rows (010's test).
- Show red: with the new block present but one guard removed, at least one case fails.

## 7. Acceptance checks (the lead runs these)

1. 016 applies after 015, rolls back cleanly, re-applies cleanly.
2. `test:rls` passes with the new cases, and fails with a guard removed. `npm test` and `npm run build` pass.
3. Through PostgREST with real logins: the owner sets a budget, turns AI on and raises a ceiling; the manager is refused
   on all three and can change a playbook level within the ceiling; a service-role `act_work_propose` creates an item that
   staff@ approves, and a message is queued in 013's `messages` with `approved_by` = staff.
4. The design note from §3 is in the handoff, with the lead's approval noted.
5. The diff touches only 016, its rollback and the tests.

## 8. Handoff

The DEV-APPROACH template, ending with **Not verified**. Say that 016 is **not applied to prod** and needs 011–015 first.
