# CMD-82: Tailwind 3 → 4 / React 18 → 19, visual differences

Method: `origin/main` build (served on 4061) against this branch (served on 4062), 146 screen pairs at 1440 and 390 px,
local DB, all feature flags on for both sides. Images are in `temp_ss/final/before` and `temp_ss/final/after`
(git-ignored, not in the PR). Compared with pixelmatch.

| # | Screen | Pair (file name in both folders) | Cause | Result |
|---|--------|----------------------------------|-------|--------|
| 1 | Customer header, Support button (every customer-flow page, 1440) | `customer-book__1440`, `customer-signin__1440`, `customer-signup__1440`, `customer-account__1440` | v4 `space-x-*` no longer adds margin after a `display:none` sibling: button 110 px instead of 118 px | Fixed `64f8293` (`sm:ml-2` on the icon) |
| 2 | Customer header, Support icon (390) | `customer-book__390`, `customer-signin__390` | Same change: icon 4 px off-centre | Fixed `fce4bfd` (`mr-0`) |
| 3 | Booking flow step 3, provider-gender labels | `flow-3-datetime__1440`, `flow-3b-date-chosen__1440` (in `temp_ss/shots/{before,after}`) | v4 `text-sm` reads `--tw-leading`, so `leading-tight` won: 17.5 px lines instead of 20 px | Fixed `727575b` (`sm:leading-5`) |
| 4 | Phone pairing link | `phone-pair__1440`, `phone-pair__390` | v4 `space-y` moves the margin to the previous sibling: link 1 px lower | Fixed `fce4bfd` (`block w-fit mx-auto`) |
| 5 | Performance page, chevron | `performance__1440` | The chevron icon has both `space-x-2` on its row and `ml-auto` (`DentistPerformancePanel.jsx:277`). In v3 `space-x-*` sets `margin-left` with higher specificity and beat `ml-auto`, so the chevron sat 8 px after the name. In v4 `space-x-*` is `:where(...)` (zero specificity), so `ml-auto` now applies and the chevron goes to the far right, which is what the class says. Not a bug | Accepted (lead); Sadin may ask for a revert |
| 6 | Dashboard charts (390) | `dashboard__390` | Capture timing: Recharts animation, empty in the before shot. Same DOM counts | Not a bug |
| 7 | Dentists "Branch ID is required" banner | one after-shot only | Capture timing; did not reproduce in 26 loads on either build | Not a bug |
| 8 | `customer-book__390`, `flow-1-branch-selected__390`, `flow-stopped__390` | re-captured on both builds: `temp_ss/qc1/{before,after}/` | 560 / 1311 / 1311 pixels, largest colour change 8 / 6 / 12 (of 765 summed over R+G+B), at hairlines and card edges. On `customer-book` the rows are the `border-t border-border/50` lines (y 491 and 780): v4 computes `/50` colours with `color-mix` in oklab, v3 used plain rgba, so one colour level differs (244,244,245 → 244,244,246). The two flow shots show the same kind of 1-level edge differences; I did not trace each one to a class | Accepted: invisible, no layout change |
| 9 | `Button` hover/active states (success, danger, warning, info, text variants) | `temp_ss/hover/before-text-button-hover.png`, `temp_ss/hover/after-text-button-hover.png` | `hover:bg-opacity-90`, `active:bg-opacity-100` (and `-50` / `-70` on the text variant) generate nothing in v4. Found by QC | Fixed `10e3832`: slash form (`hover:bg-success/90 active:bg-success`, same for error, warning, accent; `hover:bg-surface/50 active:bg-surface/70`). Checked the built CSS has the new rules. Browser check on the text variant only ("Find Existing Booking"): hover is white at 50 % on both builds |

Known v4 removals, checked in source: `grep -E "[a-z]-opacity-[0-9]" src` now returns 0 lines (the earlier 10 uses were all in `Button.jsx`; QC found no others). `outline-none` meaning and the bare `ring` width were not re-checked per use.

Dark mode: not applicable, 0 `dark:` classes in `src`.

Calendar drag-and-cancel (QC item 4): an earlier click-through saw one dialog still open at 1440 after drag-and-cancel. Repeated 3 times at 1440 and 3 at 390 on both the `origin/main` build (4061) and this branch (4062): `[role=dialog]` count 0 before and after every time. Not reproduced on either build; the earlier observation was probably left over from the previous step in a long session (not proven).

## Astryx (CMD-77) compatibility

The spike's setup (`@config`, `@tailwind utilities`, `tailwind.config.js`) is not what this branch has. This branch uses
`@import 'tailwindcss'`, `@plugin` and `@theme`, and has no `tailwind.config.js`. `src/styles/index.css` is already wrapped in `@layer base`.

- Adding `@layer reset, theme, base, astryx-base, astryx-theme, components, utilities;` at the top of `tailwind.css`
  built, and the output contained `@layer reset;` and `@layer astryx-base,astryx-theme,components;`. Reverted, not committed.
- Not done: compare against the spike's rendering, and the `:root` collisions on `--color-accent`, `--color-border`, `--color-error`,
  `--color-success`, `--color-text-primary`, `--color-text-secondary`, `--color-warning` (spike 5.2). Recount on this branch: `var(--color-…)` appears 4 times, all in `src/styles/tailwind.css`, 0 in components. The CMD-77 follow-up has to settle the layer order, preflight and these seven names.
