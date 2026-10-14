# Staff (dentist) transfers — design note

Final behaviour as it exists on Zennly `origin/stage` (migrations 038–167, read in full), consolidated for
ClinicMD into `migration-003` (table + RLS), `004` (functions), `005` (cron). Terms: therapist → dentist,
room → chair. Local DB only until the owner approves production promotion.

## Data model

- `dentists.branch_id` is the dentist's **single current branch** (this schema has no join table).
  A transfer *moves* it. `dentists.org_id` already exists and a transfer never changes it.
- `staff_transfers` is the audit + schedule table. One row per leg:
  `dentist_id, org_id, from_branch_id, to_branch_id, transferred_by, transferred_at, note`,
  `effective_date` + `start_time` (Asia/Kathmandu wall clock), `applied` (the move has happened),
  `duration_value/duration_unit` (minute|hour|day|week|month), `revert_at` (timestamptz),
  `reverted/reverted_at`, `is_permanent`, `from_display_order` (column position at the origin before
  it was overwritten), `is_return_leg` (synthesised destination→origin row recording a return).
- Constraints/indexes: `from_branch_id <> to_branch_id`; partial index for pending scans; partial
  **unique** index `one active per dentist`: `applied = false OR (applied AND revert_at IS NOT NULL AND NOT reverted)`.
- RLS: org members read their org's rows; there is **no** client INSERT/UPDATE/DELETE policy. All writes
  go through SECURITY DEFINER functions, so the audit trail cannot be forged.

## What a transfer does

- Moves `dentists.branch_id` to the destination and appends them to the destination's `display_order`
  (the origin position is saved in `from_display_order`). Bookings, `booking_dentists` and attendance rows
  are **not** touched.
- `user_branches` and `users.branch_id` are **not** touched. (Zennly's `_sync_user_branch_for_transfer`
  flips the login branch of a *staff user whose full_name matches the dentist's name*. ClinicMD dentists
  are not login users and there is no reliable link, so name-matching would be a privilege-shifting
  guess. Dropped deliberately.)
- Timing: effective date + start time are compared in **Asia/Kathmandu**. If that instant is `<= now`
  the move is immediate (`applied = true`); otherwise the row is stored pending and the cron applies it.

## Lifecycle

- **Temporary** (default): start time + duration are required; `revert_at = start + duration` (Kathmandu).
  When it passes, the cron moves the dentist back to the origin, restores the saved column position when
  free, inserts a return-leg row and marks the original `reverted`.
- **Permanent**: no duration or revert; the dentist just moves (now or on the effective date) and stays.
- **Scheduled**: effective instant in the future → pending, non-blocking, shown as a "Scheduled" badge.
  Cancelling deletes the pending row (only while `applied = false`).
- One unresolved transfer per dentist at a time. Sequential transfers are fine.

## Cron (migration-005)

- One pg_cron job every 5 minutes runs `apply_due_staff_transfers()` then `apply_due_staff_reverts()`.
  pg_cron runs in UTC; both functions do their own Kathmandu conversion
  (`now() AT TIME ZONE 'Asia/Kathmandu'`), so no cron timezone setting is needed.
- **Zennly bug 148 (kept fixed):** "due" compares `effective_date + start_time` as a Kathmandu timestamp
  to the Kathmandu `now`, not just the date. Otherwise a 15:40 transfer is applied at 00:05.
- Both functions are SECURITY DEFINER, pinned `search_path`, and **revoked from PUBLIC/anon/authenticated**
  (only the cron/postgres role runs them). Zennly requires no client access to them.
- The "left-behind bookings" daily reminder (Zennly 040) is ported as `notify_left_behind_bookings()`.

## Booking guards

- Creating a transfer does **not** reassign, delete or block the dentist's existing future bookings at the
  origin: they stay put ("left behind"). The origin calendar still shows them in a greyed transferred-out
  column (the existing orphan-dentist column logic), and the daily job reminds origin users the day before.
- Ending a transfer early / auto-revert **will not pull a dentist away from a live booking**: if the dentist
  has any non-terminal booking (anything except Completed/Cancelled/No Show) at the destination ending after
  the return moment, `revert_staff_transfer_now` raises with the last booking's end time and count, and the
  cron **defers** (leaves the row untouched, retries next tick) instead of forcing it through.
- Client-side, the calendar refuses/warns new bookings or drops for a dentist inside a transferred-out
  window (see Blocks below for how it reuses the overlap check).

## Revert, extend, reschedule return

- `revert_staff_transfer_now(id, [reverted_at])`: admin, or manager of **either** branch; return time may be
  a past/now custom time (not future, not before the transfer started, before the scheduled return).
- `extend_staff_transfer(id, +n unit)`: admin or manager of the **destination**; only while active.
- `reschedule_staff_transfer_return(id, new_revert_at)`: either branch's manager/admin; strictly future.
- `cancel_scheduled_transfer(id)`: admin or manager of the **origin**; only while pending.
- Permanent transfers have no return time, so extend/reschedule/revert-now reject them.

## Authorization (final Zennly rules, ClinicMD roles)

- `transfer_dentist`: caller must be `admin` or a `manager` whose branches (`get_user_branch_ids()` =
  primary + `user_branches` grants) include the dentist's **current** branch. The dentist and destination
  must be in the caller's org. Destination branch consent is **not** required in Zennly — only same-org.
  `staff` and `admin_viewer` can never transfer. A transfer never crosses orgs.
- Multi-branch managers: every manager check is "primary branch OR a `user_branches` grant" — Zennly's
  incident fix 157/166 — expressed once via `get_user_branch_ids()`.

## Race fixes kept

- 153: per-dentist `pg_advisory_xact_lock` serialises concurrent `transfer_dentist` calls + the partial
  unique index as defence in depth, with a friendly error on `unique_violation`.
- 148: Kathmandu date+time "due" check. 149: preserve origin column position (`from_display_order`).
  163: `is_return_leg` column instead of matching note text. 164/167: booking guard reports the *last*
  conflicting booking and covers Pending too; the cron applies the same guard.
- 154 (restoring an old overload after a bad deploy) is an incident artefact and is **not** ported.

## Interactions with ClinicMD features

- **Blocks (3b):** `manual_block_scope_ok` required `dentist.branch_id = block.branch_id`, which breaks
  editing/cancelling an origin-branch block once the dentist has moved. Rule chosen (migration-003 replaces
  the function): a dentist may be scoped by a block at a branch they currently belong to **or** have a
  transfer record with (from/to). Existing blocks are never moved or deleted by a transfer. A block for a
  dentist who is away is harmless (their column is already unavailable in the window).
- **Attendance:** attendance is per `(branch_id, dentist_id, date)`. A transferred dentist keeps their
  rows; the destination marks attendance for the visitor at the destination. The Attendance panel gains
  the transfer action, a "Transferred" filter, the transferred-out list (with the dentist's attendance) and
  scheduled/active badges, as in Zennly. Nothing is silently re-linked.
- **Calendar:** transferred-out columns (neutral grey window shading, not the block hatch), "Visiting"
  columns at the destination, header badges (Transferred / back at X / Scheduled) with cancel, revert,
  extend, reschedule; `transferSlotWindow.js` for the shaded window. Window overlap joins the shared
  `findBlockOverlap` "warn everywhere" check as pseudo-blocks.
- **Fail open:** if the transfer tables/RPCs are missing (`PGRST205`, `PGRST202`, `42P01`, `42883`) the
  calendar and attendance load with no transfer data, like `blocksAvailable`, so the cloud-backed :4028 keeps working.

## Promotion notes

`pg_cron` must be enabled on the target project (Database → Extensions) before migration-005; migrations are
idempotent and applied by hand in order 001–005 only with the owner's approval.

## Left-behind reminder (in-app only)

`notify_left_behind_bookings()` only inserts rows into `public.notifications` (type `transferred_staff_reminder`);
it sends no email/SMS/WhatsApp and calls no `pg_net`/http. Recipients: every active user whose **primary**
`users.branch_id` is the booking's origin branch, once per user per booking (dedupe), for bookings dated
**tomorrow** (Asia/Kathmandu) still assigned to a dentist who has since moved. It runs **daily at 06:00
Asia/Kathmandu** (`15 0 * * *` UTC). Zennly's version was already in-app; nothing was dropped from it.

## Not ported / known limits

- `_sync_user_branch_for_transfer` (name-matched login branch flip) and migration 154 (incident overload).
- Zennly's `resolveOrphanTransferWindow` (shading windows for *orphan* columns of left-behind bookings after a
  permanent transfer): ClinicMD keeps its simpler orphan-dentist column (no shading).
- Transfer shading, header badges and the "unavailable" gating apply in **Dentist** column view and the Day
  view's dentist columns; Chair view and the 4-Day view (day columns) don't draw transfer windows. Quick-create,
  the booking-edit forms and the reschedule modal warn via `findBlockOverlap` (transfer windows are fed in as
  pseudo-blocks), for dentist-scoped checks.
- Manager direct `UPDATE dentists SET branch_id` (existing RLS "Manager can update org dentists") bypasses
  transfer records; transfers are the supported path.

## Production promotion checklist (when the owner approves)

1. Enable the **pg_cron** extension on the target project (Dashboard → Database → Extensions) — `pg_net` is NOT needed.
2. Apply, in order, by hand: `migration-001`, `002` (blocks), `003`, `004`, `005`. All are idempotent; 005 creates two
   cron jobs (`apply-due-staff-transfers` every 5 min, `notify-left-behind-bookings` daily 00:15 UTC).
3. No dashboard settings, secrets, auth or storage changes. No Edge Functions. API schema cache reloads automatically
   (PostgREST `PGRST205`/`PGRST202` fail-open in the app covers the window before it does).
4. Verify: `select jobname, schedule from cron.job;` and a manager's `rpc/transfer_dentist` denied for staff.
