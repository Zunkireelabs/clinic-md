# ClinicMD tracker

> **Generated from Plane by `/project-pm sync`. Do not edit by hand.** Plane (project **ClinicMD**, key
> `CMD`) is the source of truth; this file is a read-only snapshot for everyone in the repo. Never copy
> anything from this file back into Plane. Stale or conflicted? Run `/project-pm sync`.

Last synced: **2026-10-26** by Sadin · 22 open tickets (epics excluded)

---

## How we track work (HARD RULE for every developer)
1. **Your work is in Plane before you start it.** Fixes, features, migrations, data fixes, hotfixes,
   investigations and follow-ups all get a `CMD` ticket with an assignee, however small.
2. **Search before you create. No duplicates.** If a ticket covers it, comment on that one or add a child.
3. **This file is generated** (`/project-pm sync`). Never hand-edit it; never copy it into Plane.
4. **No other to-do lists:** not in `todo.md`, handoffs, briefs, PR descriptions or logs.
5. **Move the ticket when the work moves:** Backlog → Todo → In Progress → In Review (PR open) → On Stage
   (merged to `stage`; no `stage` branch yet, CMD-18) → Done (live on `main` in production).
6. **Branch and PR carry the ticket id** (`feature/CMD-123-short-name`, `CMD-123: …`). No id, no merge.
7. **New work found mid-task is a new ticket**, not scope creep.
8. **Questions only the owner can answer are `DECIDE …` tickets**, assigned to the owner.
9. **Unverified isn't done.** Anything you can't prove gets the `needs-verification` label.
10. **Never delete a ticket.** Won't do → Cancelled, with a comment saying why.
11. **Handoffs come through tickets**, not copy-pasted prompts or handoff files.
12. **Push, merge, and any write to a shared or production database need a human's explicit OK.** `main`
    deploys to production on every push.

---

## Flags from the last sync
- **Open PRs without `CMD-` in the title:** none (no open PRs).
- **Urgent/high with no owner:** CMD-11, CMD-12, CMD-13, CMD-15, CMD-18, CMD-21, CMD-41, CMD-42.

## In progress
| Ticket | Owner | Priority | What |
|---|---|---|---|
| CMD-16 | unassigned | medium | CLAUDE.md, project-pm skill and architecture/deploy/migration docs |
| CMD-46 | Sadin | medium | Plane workflow setup: project-pm skill, plane.md, tracker, CLAUDE.md rules |

## In review / on stage
| Ticket | Owner | Priority | State | What |
|---|---|---|---|---|

## Todo
| Ticket | Owner | Priority | What |
|---|---|---|---|
| CMD-11 | unassigned | urgent | Verify migrations 006-010 are applied to the prod database |
| CMD-12 | unassigned | high | Confirm prod VITE_ENABLE_CONSULTATION and AI edge-function secrets |
| CMD-13 | unassigned | high | Memberships/vouchers ON in prod build but flags file says migrations not applied in prod |

## Waiting on owner
| Ticket | Owner | Priority | What |
|---|---|---|---|

## Backlog
| Ticket | Owner | Priority | What |
|---|---|---|---|
| CMD-15 | unassigned | high | Define a migration process / runner (replace hand-applied SQL) |
| CMD-18 | unassigned | high | Add a staging environment + stage branch (feature → stage → main) |
| CMD-21 | unassigned | high | Cross-check Zennly/bookX against ClinicMD security fixes (migrations 008/009) |
| CMD-41 | unassigned | high | .env.example says one Supabase project serves both local dev and production |
| CMD-42 | unassigned | high | Verify GitHub branch protection on main (PR + CI required before auto-deploy) |
| CMD-14 | unassigned | medium | Decide ship-or-remove for gated modules (Outreach, Platform admin, Referrals, Memberships, Vouchers) |
| CMD-17 | unassigned | medium | Rewrite README to match reality |
| CMD-19 | unassigned | medium | Verify prod is actually serving (app.clinicmd.pro) and which clinics use it |
| CMD-20 | unassigned | medium | Run supabase/tests/tenant-isolation.sql in CI |
| CMD-22 | unassigned | medium | Check git history for a committed .env.local; rotate anything exposed |
| CMD-23 | unassigned | medium | Test coverage gaps: no component/e2e tests, no lint/typecheck in CI |
| CMD-43 | unassigned | medium | Deploy workflow pre-deploy check runs only the build, not npm test |
| CMD-44 | unassigned | medium | public_search_booking / public_get_booking_by_id still anon-callable and return full booking rows |
| CMD-24 | unassigned | low | Remove unused parts of customer-booking-flow v1 (v2 still imports 6 of its components) |
| CMD-25 | unassigned | low | Delete 7 stale merged remote branches; ignore build/ and temp_ss/ |
| CMD-26 | unassigned | low | Rename leftover book-dental image/container/package names to clinicmd |
| CMD-45 | unassigned | low | Add rollback files for migrations 001-006 (only 007-010 have one) |
