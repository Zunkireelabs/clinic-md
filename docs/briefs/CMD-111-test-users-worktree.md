# Brief: Test-user script must not reset the shared stack's passwords from a worktree · CMD-111 · no migration

Lead session, 2026-11-25. Groundwork (local dev tooling). Builder B (clinic-md-76). Label found-by-dev. Parent epic: CMD-8 (Docs & DevEx).

## Why
`scripts/local-create-test-users.sh` writes passwords to `$REPO_ROOT/supabase/LOCAL_TEST_USERS.md`, where `REPO_ROOT` is the checkout
it runs from. Every worktree talks to the same local stack (`project_id = "clinicmd-local"`, DB 55322, API 55321). Run from a worktree,
the script doesn't find that worktree's file (or finds a stale one), makes new passwords, PUTs them to GoTrue for admin@, manager@ and
staff@, and the main checkout's file is now wrong. Every other session's logins break. `local-db-bootstrap.sh` calls the script too.

## Where
New worktree `~/Projects/clinic-md-CMD-111`, branch `feature/CMD-111-test-users-worktree` from **`origin/main`**. PR to `main`, title
`CMD-111: test-user script keeps the shared passwords from a worktree`. Copy `~/Projects/clinic-md/.claude/settings.local.json` into the
new worktree's `.claude/` first (ponytail; merge it into an existing settings.local.json rather than overwriting).

## Build
1. Work out the **main checkout** with git: `git rev-parse --path-format=absolute --git-common-dir` gives `<main>/.git`, and its
   parent is the main checkout. In the main checkout itself nothing changes.
2. From a worktree, with no flag, read and write the **main checkout's** `supabase/LOCAL_TEST_USERS.md`. Existing passwords are reused,
   so nothing in GoTrue changes. Print one line saying which file was used (path only, never a password).
3. `--workdir <dir>` (the ticket's escape hatch): use `<dir>/supabase/LOCAL_TEST_USERS.md` and run `supabase status` with
   `--workdir <dir>`, for a worktree that runs its own separate stack. Refuse with a clear message if `<dir>` has no `supabase/config.toml`.
4. If the main checkout's file can't be found or written, **refuse** with a clear message and change nothing. Don't fall back to the
   worktree's own file.
5. `local-db-bootstrap.sh` passes `--workdir` through if given. Otherwise it's unchanged.
6. Document it in `supabase/LOCAL_DEV.md` under "Test users": worktrees share the main checkout's file, and when to use `--workdir`.

## Must not
- Never print, echo, log or commit a password, and don't `cat` LOCAL_TEST_USERS.md in your output. To check passwords didn't change,
  compare a hash of the file (`shasum`) before and after.
- Don't change the users, roles, org or branch the script creates. Keep the existing local-only guard.
- Local stack only.

## Acceptance checks (the lead re-runs these)
1. From the main checkout: two runs leave `supabase/LOCAL_TEST_USERS.md` byte-identical (same shasum), and the manager@ login works with
   the file's password (prove it with a GoTrue password-grant call that reads the password into a shell variable, printing only the HTTP status).
2. From a worktree (with no LOCAL_TEST_USERS.md of its own): a run leaves the **main checkout's** file byte-identical, the login in (1)
   still works, and no LOCAL_TEST_USERS.md is created in the worktree.
3. Main checkout's file renamed away (put back afterwards): a run from a worktree refuses with a clear message, exits non-zero, and makes
   no GoTrue change (the login with the saved password still works once the file is back).
4. `--workdir <path-without-config>` refuses with a clear message.
5. `bash -n` on both scripts. `shellcheck` clean if it's installed (say if it isn't).
6. `npm test` and `npm run build` pass. LOCAL_DEV.md is updated.

## Handoff
The branch, PR link, the commands you ran for checks 1–4 with their outputs (no passwords), and a **Not verified** list.
