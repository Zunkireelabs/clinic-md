# Brief: Action layer, first slice (bookings) · CMD-78

**Status:** ready to build, 2026-11-22 · **Phase:** 2 (foundation for the Follow-up agent, Home and Inbox) · **Lead:** lead session
**Follows:** `docs/PRODUCT-BRIEF.md` §7.1 (the action layer), §7.5 (agent platform, steps 4–8), §7.7 (trust layer:
audit log), principle 14 (tenant-safe), `docs/USER-JOURNEYS.md` 1.2 (confirmations), 4.4 (undo), `CLAUDE.md` → Database.
**Boards that depend on it:** Home (Approve, Undo), Inbox (Take over, Assign), Agents › Activity (Undo, Retry).

## 1. What and why

Today every write is a client-side function in `src/services/api.js` (about 230 of them) that only the UI can call.
An agent can't use them safely: there's no permission check per actor, no shared audit and no undo.

**An action** is one thing the clinic can do, run on the server. Each action has:
- a name;
- typed inputs and outputs;
- a permission check (which person or agent may run it, in which org and branch);
- validation against live data;
- the change itself;
- one audit entry (who or what ran it, the inputs, on whose approval);
- an undo, where one is possible.

This ticket builds **the framework plus the booking actions the Follow-up agent and the calendar need**. It also
moves two existing UI paths onto those actions, to prove the old screens can use them. Messaging actions come with
the communication hub ticket. Approvals and the work queue come with the agent platform ticket.

## 2. Where to work

- Your own worktree from `origin/main`:
  `git worktree add ../clinic-md-CMD-78 -b feature/CMD-78-action-layer origin/main`
- **Migration 012** is claimed for this ticket. `main` has 001–010, and PR #15 uses 011. **Branch from main, but
  write 012 so it applies on top of 011.** Add a comment at the top: "Requires 011 (CMD-79)." The two must
  reach prod in order.
- Local Supabase only (the shared stack on 55321/55322 already has 001–011). Don't stop or reset it: tell the lead
  if you need a reset. Never touch the cloud project or prod. Never read `.env` files.

## 3. The design (decide in step 1, approved by the lead before you write it)

**Shape (fixed by this brief):** actions are Postgres functions. Postgres gives us one transaction for validation,
change and audit, it works the same for the UI (the user's JWT) and for agents (edge functions), and it fits the
stack.

**Step 1, CHECKPOINT:** send the lead a short design note covering the points below. **Write no SQL or JS until it's
approved.**

1. **`action_log` table** (new; the old `audit_logs` stays, untouched). Proposed columns: `id`, `org_id`,
   `branch_id`, `action` (e.g. `booking.set_status`), `actor_kind` (`person` | `agent` | `rule` | `system` |
   `patient`), `actor_user_id`, `actor_agent` (text, e.g. `follow_up`), `approved_by` (user id, nullable),
   `inputs jsonb`, `result jsonb`, `target_table`, `target_id`, `undo jsonb` (what is needed to reverse it, or null),
   `undone_by_action uuid`, `undone_reason text`, `created_at`.
   - RLS: read by staff of the same org and branch (the practitioner deny from 011 does **not** apply here); no direct
     insert, update or delete by anyone.
   - Indexes for "this branch, newest first" and "this target".
2. **Actor resolution:** one internal helper that every action calls first.
   - **Signed-in staff:** actor = `auth.uid()`, role from `users`.
   - **Service-role callers (agents in edge functions):** actor comes from a `p_ctx jsonb` argument
     (`{ "actor_kind": "agent", "agent": "follow_up", "approved_by": "<uuid>|null", "org_id": "..." }`). It is
     **accepted only when the caller is the service role**; a signed-in user's `p_ctx` actor fields are ignored.
     Say how you detect the service role.
   - **Anon:** never.
3. **Permission matrix** per action and actor: staff roles, including CMD-79's practitioner rules (own bookings
   only), agents, and rules. Write it as a table in the note.
4. **Function naming and signature pattern**, e.g. `act_booking_set_status(p_booking uuid, p_status booking_status,
   p_reason text default null, p_ctx jsonb default null) returns jsonb`, and the standard result
   `{ ok, action_id, data, error: { code, message } }`.
5. **Undo:** a generic `act_undo(p_action_id uuid, p_reason text, p_ctx jsonb default null)`. It runs the stored
   reverse as its own logged action and refuses when the target changed since (it compares `updated_at`).
   List which booking actions are undoable and for how long. Proposal: status changes, until the visit starts.

## 4. Actions in this ticket (bookings)

| Action | Notes |
|---|---|
| `booking.set_status` | Pending → Confirmed / Cancelled / No Show / In-Progress / Completed, with the existing lifecycle rules from `validateBookingMutation` and `updateBookingStatus` (locked bookings, allowed transitions) moved into SQL. Keep the side effects the client does today (the referral credit RPC, `outreach_enqueue_for_completed`) by calling them inside the action, unchanged. Undoable. |
| `booking.reschedule` | New date, time, dentist, chair. Re-checks the slot is free (chair and dentist overlap), as `rescheduleBooking` does in JS today. Undoable (restores the old slot only if it is still free). |
| `booking.flag_not_confirmed` | Marks a booking for front desk attention (for the 6 pm rule). Use a new column or table as your design says; no UI yet. Undoable. |
| `act_undo` | Generic, as in §3.5. |

Not in this ticket: booking creation (customer upsert, packages, vouchers and referrals make it big; it gets its own
ticket), payments, messaging.

## 5. App changes

- A small client wrapper, `src/services/actions.js`: `runAction(name, inputs)` calls the RPC and maps the
  standard result. There are no actions in `api.js`.
- Move **`updateBookingStatus`** and **`rescheduleBooking`** in `api.js` to call the actions, keeping their current
  signatures and error codes, so no screen changes. Delete the client-side logic they replace.
- No new screens.

## 6. Tests

- `supabase/tests/`: a new `actions.sql`, run by the same psql pattern as `test:rls`, or new sections in
  `tenant-isolation.sql`, whichever your design note proposes. Cover:
  - each action for each actor kind;
  - cross-org refusal;
  - practitioner own-booking only;
  - a service-role `p_ctx` honoured, and a user-supplied `p_ctx` ignored;
  - the slot clash refused on reschedule;
  - undo works, then is refused when the booking changed since;
  - every call writes exactly one `action_log` row;
  - no direct writes to `action_log`.
- Vitest for `actions.js` and the two moved `api.js` functions (mock the RPC).

## 7. Acceptance checks (the lead runs these)

1. On the shared local DB: 012 applies on top of 011; rollback, then re-apply, both clean.
2. `npm run test:rls` (and the new action tests) pass on local; `npm test` and `npm run build` pass.
3. On `start:local` as staff@: change a booking's status and reschedule one from the calendar. Each writes one
   `action_log` row with the right actor, and the UI behaves exactly as before, including its error messages.
4. As practitioner@: their own booking can change status; another dentist's booking is refused with a clear error.
5. A service-role call with `actor_kind: agent` logs the agent; the same call made as a signed-in user logs the user,
   not the agent.
6. `act_undo` reverses a status change and logs it; a second undo, or an undo after a later change, is refused.
7. The diff matches the approved design note; the money functions and the payment UI are not touched.

## 8. Handoff

Use the template in `docs/DEV-APPROACH.md`. End it with **Not verified**, and say that 012 is **not applied to prod**
and needs 011 first.
