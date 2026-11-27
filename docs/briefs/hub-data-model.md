# Brief: Communication hub, part 1 (data model, actions, send and receive) · CMD-(id from the PM)

**Status:** ready to build, 2026-11-22 · **Phase:** 2 · **Lead:** lead session
**Follows:** `docs/PRODUCT-BRIEF.md` §7.4 (hub), §6 principles 10 (consent first) and 13 (channel-neutral), §12 Phase 2
exit test; `docs/SITEMAP.md` §3.2 (Inbox); `docs/USER-JOURNEYS.md` 1.2 (confirmations), 2.2 (take over), 3.2 (clinical
question); the approved **Inbox boards** (canvas page 11), which show every field this data model must hold.
**Builds on:** CMD-78 (action layer, migration 012). **Migration 013** is claimed by this ticket and applies after 012.

## 1. What and why

The Phase 2 exit test needs three things: confirmations and reminders sent through actions, patient replies landing
in the Inbox, and every send logged with consent. Today there are no conversation threads, no inbound messages and
no consent records.
The old `outreach_*` tables are flag-gated, may be missing in prod (CMD-13), and model one-way sends only. This ticket
builds the hub's data and server side. **There is no UI here**: the Inbox build is its own ticket, and it reads what
this one writes.

## 2. Where to work

- Worktree from `origin/main`, branch `feature/CMD-<id>-communication-hub`. Your branch needs 012's framework, so
  base it on `feature/CMD-78-action-layer` (PR #16) and say so in the PR; rebase onto `main` once #16 merges.
- The shared local DB has 001–012 and the busy-calendar seed. Don't reset it without asking.

## 3. Data model (CHECKPOINT: send the lead a design note before writing SQL)

The proposal below is the starting point. Change what the code tells you to, and say why.

| Table | Holds |
|---|---|
| `channel_accounts` | Per org (optionally per branch): channel (`sms`, `whatsapp`, `viber`, `messenger`, `email`), provider, sender identity (number or page), status (`not_connected`, `connected`, `error`), quiet hours. Secrets never live here: they stay in edge-function env or Vault. |
| `patient_channels` | Per patient per channel: address (phone or handle), consent `status` (`agreed`, `not_asked`, `stopped`), `purpose` (`service` or `marketing`), source (`booking`, `front_desk`, `patient_reply`, `import`), recorded_by, recorded_at, and evidence text (for example "Agreed at the front desk, 4 Feb"). One row per patient, channel and purpose. |
| `conversations` | One thread per patient per channel per branch (an unknown number is allowed: `customer_id` null, with "No patient match" in the boards). `state` (`agent`, `needs_person`, `person`, `closed`), `handled_by` (user), `assigned_to` (user), `handoff_reason` (`urgent`, `clinical`, `discount`, `complaint`, `asks_to_change`, `unclear`, `other`), `handoff_summary` (the agent's first-person summary), `urgent` bool, `practitioner_id` (for clinical routing), `last_message_at`, and a counter or unread state per person. |
| `messages` | `conversation_id`, `direction` (`in` / `out`), `kind` (`message` / `event`: events are the timeline lines on the boards, such as "Anita took over", "handed off", "STOP recorded"), body, language, `author_kind` (`patient`, `person`, `agent`, `rule`, `system`), author user or agent, `template_id`, `status` (`queued`, `sent`, `delivered`, `read`, `failed`, `cancelled`), provider message id, error, cost (NPR), `action_id` (links to `action_log`), created_at. |
| `message_templates` | Per org: name, channel (or any), language (`en`, `ne`), body with `{fields}`, `clinical` bool (only practitioners may send clinical ones; see the Inbox boards), active. |

**RLS:**
- **Front desk, manager:** their branches.
- **Admin, admin_viewer:** the whole org.
- **Practitioner:** only conversations of **their own patients** (patients with at least one booking where
  `is_my_booking`). Add a helper `is_my_patient(customer_id)`, and test it against a second practitioner's patient.
- **No direct writes** from the API roles: all writes go through actions, as in 012.
- **Read-only (`admin_viewer`):** read only.

## 4. Actions (on the 012 framework, logged in `action_log`)

| Action | Rules |
|---|---|
| `message.send` | Inputs: patient or conversation, channel (optional: otherwise the first channel in the clinic's fallback order that has `agreed` consent for the purpose), template or text, fields, purpose. Refuse with `NO_CONSENT`, `STOPPED`, `CHANNEL_NOT_CONNECTED` or `QUIET_HOURS` (or queue for the end of quiet hours, if the playbook says so), or `CLINICAL_TEMPLATE` (a non-practitioner sending a clinical template). Inserts a `queued` message; the sender worker sends it. Agents need the same approval rules as 012 (service messages from a template at level 2: no approval). |
| `conversation.take_over` | The person becomes `handled_by`; state becomes `person`; an event line is added. Anyone with access to the thread; a practitioner only for own patients. |
| `conversation.hand_back` | Back to the agent; event line; **undoable** (the toast on the Handed-back board). |
| `conversation.assign` | Sets `assigned_to` (manager and admin; front desk may assign to the manager, as on the "Assign to manager" button). |
| `conversation.handoff` | Agents and rules only: state becomes `needs_person`, with reason, summary, urgent flag and practitioner routing. |
| `consent.record` | Sets a `patient_channels` row (front desk, or the patient by reply). `stopped` can't be reversed by staff, only by the patient's own START or a new written agreement recorded with evidence. |
| `message.receive` | **Service role only** (the inbound webhook). Finds or creates the conversation; matches the patient by normalised phone; records STOP and START (STOP → consent `stopped`, plus one required confirmation reply, as on the Messages-stopped board); updates the delivery status of outbound messages. |

## 5. Edge functions

- **`hub-send`:** takes queued messages (claim with `SKIP LOCKED`), resolves the provider through `_shared/channels.ts`
  (extend the interface: `sms`, `whatsapp`; delivery status callback), sends, and writes the status and cost.
  It is triggered by a DB webhook or by pg_cron: say which.
- **`hub-inbound`:** one endpoint per provider; **verifies the provider's signature**; calls `message.receive`.
- **Providers:**
  - A **`test` provider** (writes to a local log table, can simulate delivery, failure and a reply), so everything
    runs locally.
  - An **Aakash SMS** adapter: Sadin chose Aakash SMS on 2026-11-22. Bird is the alternative and may be added or
    swapped later, so keep the gateway behind the interface and selected per `channel_accounts` row. Build it from
    Aakash's public API docs and test it with mocked HTTP only. The API key goes in edge-function env and is never
    committed. No real send happens from this ticket; Sadin connects the real account.
  - WhatsApp comes in its own ticket.

## 6. Out of scope

Inbox UI · the Follow-up agent's playbooks and scheduling (agent platform ticket) · real providers · voice ·
migrating old outreach rows (leave them; outreach stays off).

## 7. Tests

`tenant-isolation.sql` sections, as in CMD-78, cover:
- RLS per role, including the practitioner's own patients and a second practitioner;
- every action and refusal code;
- STOP, then a send is refused, then START allows it again;
- quiet hours;
- a clinical template refused for front desk;
- the inbound path with an unknown number;
- one `action_log` row per action.

Plus Deno or Vitest tests for the provider interface and the `test` provider.

## 8. Acceptance checks (the lead runs these)

1. 013 applies after 012 on the shared DB; rollback and re-apply are clean; `test:rls` passes; `npm test` and
   `npm run build` pass.
2. Locally, with the test provider, as staff@: send a template to a seeded patient with consent → queued → sent →
   delivered. A simulated reply lands in the same thread. A simulated "STOP" stops the channel and sends the one
   confirmation reply. The next send is refused with `STOPPED`.
3. As the agent (service role): a handoff with reason `clinical` routes to the patient's practitioner, and that
   practitioner can read the thread while a second practitioner can't.
4. Take over, hand back (and undo it), and assign each write one `action_log` row and one event line.
5. No provider secret in any table, file or log.

## 9. Consent for existing patients (decided by Sadin, 2026-11-22)

- The phone a patient gave when booking counts as `agreed` for **service** messages (confirmations, reminders) on SMS,
  with `source = booking`. The migration backfills this from bookings.
- Marketing always needs an explicit `agreed`.
- STOP works at any time.
- The legal check (CMD-59) confirms this before go-live, so keep the backfill switchable (a flag, **on** by default
  now) so it can be turned off if legal says so.

## 10. Handoff

Use the template in `docs/DEV-APPROACH.md`. End it with **Not verified**, and say that 013 is not applied to prod and
needs 011 and 012 first.
