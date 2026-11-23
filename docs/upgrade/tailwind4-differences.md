# CMD-82: Tailwind 3 → 4 / React 18 → 19, visual differences

Method: `origin/main` build (served on 4061) against this branch (served on 4062), 146 screen pairs at 1440 and 390 px,
local DB, all feature flags on for both sides. Images are in `temp_ss/final/before` and `temp_ss/final/after`
(git-ignored, not in the PR). Compared with pixelmatch.

| # | Screen | Pair (file name in both folders) | Cause | Result |
|---|--------|----------------------------------|-------|--------|
| 1 | Customer header, Support button (every customer-flow page, 1440) | `customer-book__1440`, `customer-signin__1440`, `customer-signup__1440`, `customer-account__1440` | v4 `space-x-*` no longer adds margin after a `display:none` sibling: button 110 px instead of 118 px | Fixed `64f8293` (`sm:ml-2` on the icon) |
| 2 | Customer header, Support icon (390) | `customer-book__390`, `customer-signin__390` | Same change: icon 4 px off-centre | Fixed `fce4bfd` (`mr-0`) |
| 3 | Booking flow step 3, provider-gender labels | booking flow step 3 (capture-set file name not recorded in my notes) | v4 `text-sm` reads `--tw-leading`, so `leading-tight` won: 17.5 px lines instead of 20 px | Fixed `727575b` (`sm:leading-5`) |
| 4 | Phone pairing link | `phone-pair__1440`, `phone-pair__390` | v4 `space-y` moves the margin to the previous sibling: link 1 px lower | Fixed `fce4bfd` (`block w-fit mx-auto`) |
| 5 | Performance page, chevron | `performance__1440` | Not investigated: chevron sits further right | Accepted by lead; Sadin may ask for a revert |
| 6 | Dashboard charts (390) | `dashboard__390` | Capture timing: Recharts animation, empty in the before shot. Same DOM counts | Not a bug |
| 7 | Dentists "Branch ID is required" banner | one after-shot only | Capture timing; did not reproduce in 26 loads on either build | Not a bug |
| 8 | `customer-book__390`, `flow-1-branch-selected__390`, `flow-stopped__390` | same names | 2 pixels each, not inspected | Open (not inspected) |

Known v4 removals checked in source: `bg/text/border-opacity-*` (10 uses; one is `Button.jsx`), `outline-none` meaning, bare `ring` width.
Not re-checked per use in this pass.

## Astryx (CMD-77) compatibility

The spike's setup (`@config`, `@tailwind utilities`, `tailwind.config.js`) is not what this branch has. This branch uses
`@import 'tailwindcss'`, `@plugin` and `@theme`, and has no `tailwind.config.js`. `src/styles/index.css` is already wrapped in `@layer base`.

- Adding `@layer reset, theme, base, astryx-base, astryx-theme, components, utilities;` at the top of `tailwind.css`
  built, and the output contained `@layer reset;` and `@layer astryx-base,astryx-theme,components;`. Reverted, not committed.
- Not done: compare against the spike's rendering, and the `:root` collisions on `--color-accent`, `--color-border`, `--color-error`,
  `--color-success`, `--color-text-primary`, `--color-text-secondary`, `--color-warning` (spike 5.2: zero `var(--color-…)` uses in `src/`
  at that time, not re-counted here). The CMD-77 follow-up has to settle the layer order, preflight and these seven names.
