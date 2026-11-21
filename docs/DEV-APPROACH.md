# ClinicMD: development approach

How the Zunkireelabs development approach (SOP `zunkireelabs-org/SOPs/development-approach/README.md`,
v1.0 pilot, 2026-11-16; OPS-164/165) applies to this repo. The SOP wins if this file disagrees with it.
Adopted under CMD-50 on 2026-11-21. Worked example in another repo: ZONE `CLAUDE.md` (commit b0383da).

## Who does what

| Role | Who | Does | Never |
|---|---|---|---|
| Human dev | Sadin, Anish | Approves scope, boards, design direction; approves the other person's push; merges to `main` | Approves their own push |
| Lead / QC session | Claude session in this repo | Briefs (one per ticket, with acceptance checks), design direction file, boards, re-running gates, acceptance comment | Builds the ticket it checks |
| Builder session | Separate Claude session (or a developer) | Builds one ticket per branch from the brief; handoff with a Not verified list | Checks its own work, moves its ticket to QC Accepted |
| Project Manager | Office employee | Board, states, labels, `/project-pm sync` scoreboard | |
| Quality Engineer | Office employee | QA go / no-go with evidence on features and modules | |

## Flow for one ticket

1. **Ticket** exists in Plane (`CMD`) with parent epic and acceptance criteria. No ticket, no work.
2. **Brief** (lead): what to build, files likely touched, acceptance checks, migration number if any.
3. **Build** (builder): branch `feature/CMD-n-short-name`, commits, `npm test` + `npm run build`.
4. **Handoff** (builder): what changed, how to check it, and a **Not verified** list.
5. **Check** (lead): re-runs `npm test`, `npm run build`, and `npm run test:rls` on **local** Supabase when SQL
   changed; reads the diff against the brief; opens the app on `npm run start:local` for UI changes. Then either an
   acceptance comment on the ticket (→ QC Accepted) or findings back to the builder.
6. **PR** to `main` (title `CMD-n: ...`), ticket → In Review. The approver is not the pusher.
7. **Ship**: Sadin merges. Ticket → Done only after the Deploy run for that merge succeeded.

## Handoff template (builder → lead)

```
Ticket: CMD-n   Branch: feature/CMD-n-...   Commit: <sha>
Changed: <one line per file or area>
Ran: npm test (pass/fail, counts), npm run build (pass/fail)
How to check: <steps>
Not verified:
- <what was not run / not opened / not tested on prod-shaped data / not measured>
```

A handoff without a Not verified list is sent back. "Nothing" is only acceptable if it is true.

## Spec by size

| Size | Spec |
|---|---|
| Small change | Ticket with acceptance criteria |
| Feature | One-page brief, one to three boards or sketches, acceptance checks |
| New module | Scope, phases (each with exit test + date), sitemap, full boards, role matrix, full QA |

## ClinicMD-specific gates

- Migrations: number claimed in the ticket, rollback file written, applied to prod **before** the code that needs it
  reaches `main` (see `CLAUDE.md` → Database). The lead checks this before QC Accepted.
- Tenant safety: every new query is org/branch-scoped; RLS is the net, not the scope.
- No session runs anything against the production DB or VPS; a human does.

## Board (CMD, set up 2026-11-21)

- State `QC Accepted` (between In Progress and In Review): set only by the lead, after its acceptance comment.
- Labels `found-by-qc`, `found-by-qe`, `found-by-dev`, `found-by-client`: one on every bug, for the scoreboard
  (who found it; the SOP wants QC + Quality Engineer finding at least 70% of bugs).

## Gaps today (not yet in place)

- **No stage branch or staging environment** (CMD-18): stages 7–8 run straight to `main`, which is production.
- **No design direction file** (`docs/DESIGN-DIRECTION.md`): to be written by the lead when Sadin gives the direction.
- **No phase plan** with exit tests and dates for ClinicMD.
- Branch protection on `main` is unverified (CMD-42); deploy pre-check runs build only, no tests (CMD-43).
- Tenant-isolation test is not in CI (CMD-20).
