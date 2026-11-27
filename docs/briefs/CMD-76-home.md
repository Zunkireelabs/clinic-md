# Brief: Home ("Home is the work") · CMD-76

**Status:** boards approved by Sadin 2026-11-22 (final) · **Phase:** 3 (briefing card: 4) · **Lead:** lead session
**Boards:** canvas "ClinicMD Mockups" → page **10 Home** (https://claude.ai/artifact/DDYuBuT3fvosAvUBBzRtmz#page-home).
Rows are roles, columns are states: Normal · Empty · Loading · Error · Agents paused. 20 boards.
**Follows:** `docs/PRODUCT-BRIEF.md` §8, `docs/SITEMAP.md` §3.1 and §7, `docs/USER-JOURNEYS.md` 2.1, 3.1, 4.1, 5.1–5.4,
`docs/DESIGN-DIRECTION.md`. If the boards and this brief disagree, ask the lead; do not choose.

**Build only from the boards.** They are the final design: copy, spacing, colours, order. The builder makes no design
decisions. Phone layout is a later pass (not in this ticket); below 1100 px the right column drops under the left.

## 1. Before this can start (blockers)

| Blocker | Why |
|---|---|
| Astryx spike passes (React 19, Tailwind 4, StyleX, plain JSX in our Vite app) | Every part below is an Astryx component |
| Action layer for bookings and messaging (Phase 2) | Approve, take over, undo and assign are actions, not direct table writes (brief principle 2) |
| Agent platform tables: work-queue items, agent actions log, playbooks with autonomy level, AI budget | Needs you and Done by agents read them |
| Practitioner access level + user-to-practitioner link (migration, its own ticket) | The Practitioner row and "My patients" for the owner |

Until these exist, nothing in this ticket ships. A Phase 2 simple work queue inside Agents is a separate ticket.

## 2. Page structure (same for every role)

Order, top to bottom, never changes (design direction §5.4):
1. **Header:** H1 greeting ("Good morning/afternoon/evening, {first name or Dr. surname}") + one line
   (date · role-specific counts · "N things need you"). Right: one number with a change badge (see §3).
2. **Banner** (only in Agents paused): yellow, under the header.
3. **Ask or tell** bar (the Staff copilot, Phase 4; until then the bar is hidden, not mocked: principle 4).
4. Two columns: **left 3fr** (Needs you, or Setup on a new clinic) · **right 2fr** (Today, then Done by agents).
   Columns 24 apart; sections 24 apart; cards in a section 12 apart.

## 3. Per role (what each board shows)

| | Front desk | Practitioner | Manager | Owner |
|---|---|---|---|---|
| Sidebar | Home, Inbox, Calendar, Patients, Money, Agents; **no Settings** | Home, Inbox, Calendar, Patients, Team, Reports, Settings | all 8 + Settings | all 8 + Settings |
| Branch | their branch | their branch | their branch | All branches (switcher) |
| Header number | Handled by agents this week (branch) | Notes signed the same day (own) | Handled by agents this week (branch) | Handled by agents, all branches |
| Needs you | urgent hand-offs, drafts to approve, discount hand-offs, unconfirmed bookings | clinical hand-offs routed to them, notes to sign, Scribe style suggestions | Collections batch, assigned hand-offs, double bookings, attendance, autonomy suggestions | morning briefing (P4), budget warning, autonomy requests from managers |
| Today | the branch schedule (time, patient, service · practitioner · chair, status) | **My patients today** (own column) with alerts, "Scribe prepared summaries" chip | **Today at {branch}**: 4 number tiles + staff list with status | one row per branch + "My patients" (next 4) when the owner has a practitioner profile |
| Done by agents | since 6:00 pm yesterday (or since last look) | same, filtered to own patients | branch | all branches |

Urgent items sort first in Needs you. The count badge next to "Needs you" = items shown.

## 4. States (columns on the canvas)

| State | Rule |
|---|---|
| Normal | As drawn. |
| Empty | Front desk, practitioner, manager: evening, every section in its empty form ("Nothing needs you", "No more patients today", "Nothing new since …"). Owner: **new clinic, first day**: the Setup checklist replaces Needs you; Today and Done by agents show their first-use empties; no unread badges. |
| Loading | Header greeting renders at once (from the session); the count line and number are skeletons. Skeletons appear after 300 ms. Ask or tell is usable while loading. |
| Error | **One section fails, the rest still works.** Each section has its own error and its own Try again. Copy per section is on the boards: Today (front desk row), Needs you (practitioner row), Done by agents (manager row), briefing (owner row). The header count leaves out what failed. |
| Agents paused | Yellow banner with the reason (AI service down, or budget used up) and one link (Details · Ask Dr. Sharma · Raise budget, by role). Ask or tell is disabled with its paused placeholder; ⌘K search still works. A "N conversations are waiting for a person" card (Rule chip) joins Needs you. Done by agents shows "Paused at {time}". Already-drafted approvals stay approvable. |

## 5. Components (Astryx names from the Foundations boards; confirm each in the spike)

| Part | Component |
|---|---|
| Shell, sidebar, branch switcher, user row | `AppShell`, `SideNav` (badge on Inbox only), `Menu` for the switcher |
| Header | `Layout` page header; number = Text + `Badge` |
| Banner | `Banner` (yellow) |
| Ask or tell | **AskOrTell** (ours, from `ChatComposer` + `CommandPalette`) |
| Approval card, hand-off card, rule card | **ApprovalCard** (ours, from `Card`, `Badge`, `Button`), with the states on FND · Agent patterns (editing, approved → collapses, rejected → reason chips, blocked, failed) |
| Who-acted chips | **WhoActed** (ours, from `Badge`): agent (purple), person (gray), Rule (outlined) |
| Today rows, staff rows | `List` rows (time or avatar · two lines · trailing `Badge`) |
| Number tiles (manager), branch rows (owner) | `Card` inner tiles; numbers tabular |
| Done by agents rows | **AgentActivityRow** (ours) with Undo (`Button` sm, secondary) where the action can be undone |
| Empty, error | `EmptyState` |
| Loading | `Skeleton` |
| Setup checklist | `Card` + `List` + progress bar (`ProgressBar` if Astryx has one; else the lead decides) |
| Toast after an action | `Toast` (FND · States: bottom centre, Undo where possible) |

Tokens only, no raw hex (design direction §2). Purple only on agent things.

## 6. Data and actions

Names below are **proposed**; the action-layer ticket fixes the real names. Every read and action is scoped to the
org, and to the branch unless the owner chose All branches.

| Need | Read / action |
|---|---|
| Needs you list | read: work-queue items for this person (role, branch, practitioner link), urgent first |
| Approve / Edit / Reject a draft | actions: `approval.approve`, `approval.edit_and_approve`, `approval.reject(reason?)` |
| Take over / Assign | actions: `conversation.take_over`, `conversation.assign(person)` |
| Call patient | `tel:` link with the patient's phone; logs nothing |
| Review and sign a note | opens Consultation for that booking (no action on Home) |
| Accept / reject a style suggestion | actions: `brain.accept_preference`, `brain.reject_preference` |
| Move to level 2 / Allow level 3 | action: `playbook.set_autonomy` (manager up to the owner's ceiling; owner sets the ceiling) |
| Mark as leave | action: `attendance.mark_leave` |
| Raise budget | opens Agents → Usage and budget (owner only) |
| Briefing "do it" buttons | action: `task.create` for the agent or person named (Phase 4) |
| Today | read: bookings for today (branch, or own column), status, patient alerts |
| Manager tiles | read, computed in SQL (principle 6): bookings, confirmed, chairs in use %, collected so far vs expected, not confirmed |
| Header number | read: agent-handled share for the week (SQL), and last week's for the badge |
| Done by agents | read: agent actions since the person's last Home view (stored per user) or 6:00 pm yesterday, whichever is later; `undo` only where the action declares one |
| Setup checklist | read: setup steps done per clinic |

The page must render with AI off: nothing on Home calls a model on load.

## 7. Acceptance checks (the lead runs these)

1. For each of the 4 roles, the sidebar, header line, header number and section titles match the role's Normal board.
2. Front desk has no Settings item and no Team or Reports; the practitioner has no Money or Agents.
3. A practitioner sees only hand-offs routed to them and only their own patients in Today (checked with a second
   practitioner's data in the same branch).
4. Owner with All branches sees both branches; switching to one branch narrows every section.
5. Each Empty, Loading, Error and Agents paused board can be reproduced on local Supabase and matches the board
   (screenshots attached to the ticket).
6. Making one section's query fail leaves the other sections working and shows that section's error copy.
7. Approve, Edit, Reject, Take over and Undo each run through an action, write an audit entry, and show the toast from
   FND · States. Reject asks for an optional reason.
8. With AI switched off for the clinic: no model call on load (network tab), banner shown, Ask or tell disabled,
   approvals still work.
9. No raw hex in the components; purple appears only on agent chips, the agent mark and the Ask or tell icon.
10. `npm test` and `npm run build` pass; `npm run test:rls` on local if any SQL changed.

## 8. Not verified (lead)

- Astryx component names come from the Foundations boards, which were drawn from Astryx's source, not from rendered
  components. The spike must confirm each, and `ProgressBar` in particular.
- The boards were checked at 1440 wide only (local headless Chrome and the canvas). Not checked at 1024–1280, and no
  phone layout exists yet.
- Nepali text on the boards has not been checked by a Nepali reader.
- The work-queue, agent-action and budget tables do not exist; the data shapes above are not designed yet.
