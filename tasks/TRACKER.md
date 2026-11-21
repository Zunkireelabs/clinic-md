# ClinicMD tracker

> **Generated from Plane by `/project-pm sync`. Do not edit by hand.** Plane (project **ClinicMD**, key
> `CMD`) is the source of truth; this file is a read-only snapshot for everyone in the repo. Never copy
> anything from this file back into Plane. Stale or conflicted? Run `/project-pm sync`.

Last synced: **2026-11-21** by Project Manager · 43 open tickets (epics excluded: CMD-1, CMD-2, CMD-3, CMD-4, CMD-5, CMD-6, CMD-7, CMD-8, CMD-9, CMD-10)

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
- **Open PRs without `CMD-` in the title:** #10 (1 open PRs).
- **Urgent/high with no owner:** CMD-62, CMD-58, CMD-54, CMD-41, CMD-21, CMD-18, CMD-15, CMD-13, CMD-12, CMD-11.

## In progress
| Ticket | Owner | Priority | What |
|---|---|---|---|
| CMD-16 | — | medium | CLAUDE.md, project-pm skill and architecture/deploy/migration docs |

## In review / on stage
| Ticket | Owner | Priority | State | What |
|---|---|---|---|---|

## Todo
| Ticket | Owner | Priority | What |
|---|---|---|---|
| CMD-11 | — | urgent | Verify migrations 006-010 are applied to the prod database |
| CMD-12 | — | high | Confirm prod VITE_ENABLE_CONSULTATION and AI edge-function secrets |
| CMD-13 | — | high | Memberships/vouchers ON in prod build but flags file says migrations not applied in prod |
| CMD-42 | Sadin | high | Verify GitHub branch protection on main (PR + CI required before auto-deploy) |
| CMD-52 | Sadin | high | AI pilot (Bright Smile): verify image analysis (X-ray/photo → OpenAI vision) in production |
| CMD-53 | Sadin | high | AI pilot (Bright Smile): verify phone recording + push delivery in production |

## Waiting on owner
| Ticket | Owner | Priority | What |
|---|---|---|---|
| CMD-70 | Sadin | high | DECIDE: upgrade Supabase from Free to Pro for daily backups of clinical data |
| CMD-71 | Sadin | high | DECIDE: should the clinic-md GitHub repo be public? |
| CMD-14 | — | medium | Decide ship-or-remove for gated modules (Outreach, Platform admin, Referrals, Memberships, Vouchers) |
| CMD-57 | Sadin | medium | DECIDE: may old debts on closed (locked) days be paid? |
| CMD-63 | Sadin | medium | DECIDE: how far to limit enumeration and spam in the public booking flow (rate-limit wrapper or captcha) |
| CMD-72 | Sadin | medium | DECIDE: ClinicMD design direction (to record in docs/DESIGN-DIRECTION.md) |
| CMD-73 | Sadin | medium | DECIDE: ClinicMD phase plan (each phase with an exit test and a date) |
| CMD-61 | Sadin | low | DECIDE: AI credit tier prices and payment provider (Khalti / eSewa / Fonepay) |

## Backlog
| Ticket | Owner | Priority | What |
|---|---|---|---|
| CMD-15 | — | high | Define a migration process / runner (replace hand-applied SQL) |
| CMD-18 | — | high | Add a staging environment + stage branch (feature → stage → main) |
| CMD-21 | — | high | Cross-check Zennly/bookX against ClinicMD security fixes (migrations 008/009) |
| CMD-41 | — | high | .env.example says one Supabase project serves both local dev and production |
| CMD-54 | — | high | Store patient recording consent on consultations (who, when) |
| CMD-58 | — | high | Production rollout of migrations 001–005 (manual blocks, staff transfers, pg_cron) |
| CMD-59 | Sadin | high | AI data-policy conditions before wider launch: zero data retention, privacy notice naming OpenAI, Nepali lawyer review |
| CMD-62 | — | high | Staff PINs stored in plaintext with no lockout: hash them and add an attempt counter |
| CMD-17 | — | medium | Rewrite README to match reality |
| CMD-19 | — | medium | Verify prod is actually serving (app.clinicmd.pro) and which clinics use it |
| CMD-20 | — | medium | Run supabase/tests/tenant-isolation.sql in CI |
| CMD-23 | — | medium | Test coverage gaps: no component/e2e tests, no lint/typecheck in CI |
| CMD-43 | — | medium | Deploy workflow pre-deploy check runs only the build, not npm test |
| CMD-44 | — | medium | public_search_booking / public_get_booking_by_id still anon-callable and return full booking rows |
| CMD-55 | — | medium | Persist AI note provenance (drafted with AI: model, time; reviewed by: user, time) |
| CMD-56 | — | medium | Allergies / medical alerts field on patients (feeds consultation rail and chart alerts) |
| CMD-60 | — | medium | AI credits and plans (monetisation): ledger, Settings → Plan & AI usage, balance card, top-ups |
| CMD-64 | — | medium | Signed-in patient booking with a chosen dentist can't write the booking_dentists row (since 009) |
| CMD-65 | — | medium | Edit patient details (name, phone, email, gender): no edit-customer flow exists |
| CMD-66 | — | medium | Public booking flow: leftover "spa" copy and step counter jumping "1 of 4" → "2 of 5" |
| CMD-24 | — | low | Remove unused parts of customer-booking-flow v1 (v2 still imports 6 of its components) |
| CMD-25 | — | low | Delete 7 stale merged remote branches; ignore build/ and temp_ss/ |
| CMD-26 | — | low | Rename leftover book-dental image/container/package names to clinicmd |
| CMD-45 | — | low | Add rollback files for migrations 001-006 (only 007-010 have one) |
| CMD-51 | — | low | project-pm plane.md: MCP fallback for sync breaks token rules and doesn't say what happens to the tracker (CodeRabbit on PR #11) |
| CMD-67 | — | low | Outstanding report: restyle the filter area (date chips, date inputs, Responsible person) |
| CMD-68 | — | low | Calendar: hover card can cover the neighbouring card; Unassigned column width (parked) |
| CMD-69 | — | low | Recall banner on Patients ("n patients haven't visited in 6+ months, send reminders") |
