# Brief: Upgrade to React 19 + Tailwind 4, with a visual pass of every screen · CMD-(id from the PM)

**Status:** ready to build, 2026-11-22 · **Phase:** 3 prerequisite (no Astryx screen can ship before this) · **Lead:** lead session
**Follows:** the CMD-77 spike, `docs/spikes/CMD-77-astryx.md` on branch `feature/CMD-77-astryx-spike` (commit 9e5a886);
`docs/PRODUCT-BRIEF.md` §11 (Design system); `docs/DESIGN-DIRECTION.md` §12.

## 1. What and why

The spike showed that Astryx needs React 19 and Tailwind 4. On Tailwind 3 its layered styles lose. This ticket does
**only the upgrade**, as its own PR to `main`, and proves that **no existing screen changed**. Astryx itself is **not**
added here. It comes with the first Astryx screen, so this PR stays reviewable and easy to revert.

## 2. Where to work

- Your own worktree from `origin/main`: `feature/CMD-<id>-react19-tailwind4`. Take the upgrade parts of the spike
  branch, **not** the spike page, the Astryx packages or the theme file.
- `npm run start:local` against the shared local DB. Don't stop or reset it. Run your build on a port that isn't
  4029 or 4031.

## 3. Steps

1. **Versions:** React and React DOM 19, Tailwind 4 with `@tailwindcss/postcss`; remove `autoprefixer`, `react-helmet`
   and the unused Tailwind plugins (as the spike did). Pin exact versions. Check `react-router-dom` 6.0.2 and
   `@testing-library/react` 11 on React 19, and upgrade them only if needed (say why).
2. **Tailwind 4 migration:** use the official upgrade tool first, then fix by hand:
   - `space-x-*` / `space-y-*` (862 uses; the selector changed in v4);
   - `outline-none` (143; now `outline-hidden`);
   - `*-opacity-*` (10; removed);
   - the default border colour, ring width and shadow scale changes;
   - the `tailwind.config.js` → CSS `@theme` move. Keep every custom colour and token name working.
   - Move the global reset in `index.css` into `@layer base` (spike finding 2).
3. **Visual pass, the main work.** For each screen in §4, take a screenshot on `origin/main` and on your branch,
   same data, same viewport (1440 and 390 wide), and compare. Fix every difference that isn't intended. Save the
   pairs under `docs/upgrade/` (before/after) with a table: screen, the two widths, same or fixed or accepted, with a
   note.
4. **Build and deploy path:** run the Docker image build locally (`Dockerfile`). Confirm `deploy.yml` needs no change,
   or say what does.

## 4. Screens to check (both roles where they differ: admin@ and staff@)

Sign-in · Org finder · Dashboard (manager) · Calendar: 4-Day, Day and Unassigned views, the booking panel, the booking
details modal, drag and drop · Bookings list · New booking · Patients list and patient chart (all tabs) · Consultation
(desk and phone pages) · Payroll · Performance · Reports (each) · Settings (each section) · Packages, Memberships,
Vouchers (if their flags are on locally) · Outstanding · Master data · Patient booking flow v2 (every step to the
confirmation) · Customer sign-in, sign-up and account · Platform admin (if the flag is on locally).

## 5. Acceptance checks (the lead runs these)

1. `npm test` and `npm run build` pass; `npm ci` passes on a clean clone.
2. `docs/upgrade/` holds a before/after pair for every screen in §4 at both widths, and the table marks each one.
   The lead spot-checks 10 pairs and opens 5 screens itself.
3. No unintended visual difference remains. Any accepted one is listed with a reason.
4. The Docker image builds locally.
5. No Astryx package, theme or spike page is in the diff.

## 6. Handoff

Use the template in `docs/DEV-APPROACH.md`. End it with **Not verified** (for example: phone hardware, real
production data, the deploy itself).
