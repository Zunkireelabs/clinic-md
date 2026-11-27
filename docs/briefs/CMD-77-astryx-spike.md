# Brief: Astryx spike · CMD-77

**Status:** ready to build, 2026-11-22 · **Phase:** 3 (blocks CMD-76 Home and every new screen) · **Lead:** lead session
**Size:** spike, time-box **one working day**. If it isn't done by then, stop and hand off what you found.
**Follows:** `docs/PRODUCT-BRIEF.md` §11 (Design system), `docs/DESIGN-DIRECTION.md` §2–4 and §12,
`docs/briefs/CMD-76-home.md` §5 (the component list).

## 1. The question this answers

Can we build ClinicMD screens with Astryx (`github.com/meta/astryx`, beta) inside **our** app: plain JSX (no
TypeScript), Vite, React Router 6, Supabase, with React 19, Tailwind 4 and StyleX in the build? Can we do it
**without breaking the screens that exist today**?

The answer is **go**, **go with conditions** or **no-go**, backed by evidence.

## 2. Where to work

- Make your own worktree from `origin/main`. Don't work in the shared checkout, where other sessions work:
  `git worktree add ../clinic-md-CMD-77 -b feature/CMD-77-astryx-spike origin/main`
- Run with `npm run start:local` (local Supabase, see `supabase/LOCAL_DEV.md`). Never use the cloud project.
- **This branch is not merged.** It is evidence. Whether the upgrades go to `main` becomes its own ticket, decided from
  your findings.

## 3. Steps

1. **Upgrade in place:** React 18 → 19 (`react`, `react-dom`), Tailwind 3.4 → 4, and whatever Vite or plugin versions
   Astryx and StyleX need. Pin exact versions (no `^`). Write down every package you changed, and why.
2. **Check what the upgrade broke in today's app.** Look in particular at `react-router-dom` 6.0.2,
   `react-helmet`, `@testing-library/react` 11, and the Tailwind 3 plugins (`tailwindcss-fluid-type`,
   `tailwindcss-elevation`, `@tailwindcss/line-clamp`, `@tailwindcss/forms`, `tailwindcss-animate`) plus
   `tailwind.config.js`. Fix what is small. List what isn't.
3. **Install Astryx** (exact version, from its README) and get its StyleX build step working in Vite.
4. **Theme:** one theme file (`defineTheme` extending the neutral theme), adding only the three agent tokens from
   DESIGN-DIRECTION §2. Fonts: Figtree, plus Noto Sans Devanagari as the fallback for Nepali text.
5. **Spike page** at `/:orgSlug/__astryx`. Gate it with a dev-only flag (`import.meta.env.DEV`) so it never ships.
   Render each part from CMD-76 §5 that exists in Astryx: `AppShell`, `SideNav` (with a badge), `Menu`, `Layout`
   page header, `Banner`, `Card`, `Badge`, `Button` (all sizes, disabled), `List`, `EmptyState`, `Skeleton`, `Toast`,
   `CommandPalette`, `ChatComposer`, a `Dialog`, a text input, a select, a date input, and `ProgressBar` (if it
   exists). Show one line of Nepali text, a purple agent chip made from tokens, and one existing screen (the
   booking list, or any page) inside the Astryx `AppShell`. That proves old and new can live together.
6. **Measure:** the production bundle size (main JS and CSS) before and after, and the dev-server cold start.

## 4. Output

- The spike branch, pushed, with no PR to `main`.
- **`docs/spikes/CMD-77-astryx.md`** on that branch, holding:
  - the verdict (go / go with conditions / no-go) in one line, with the reasons;
  - the exact versions used, and the install and build steps a builder can copy;
  - a component table: every CMD-76 §5 name → exists / different name (give it) / missing (suggest the
    replacement);
  - what the React 19 and Tailwind 4 upgrade broke, as fixed / not fixed, and the effort for each item not fixed;
  - the bundle size and start-time numbers;
  - screenshots of the spike page at 1440 px and at 390 px, and of one old screen still working.

## 5. Acceptance checks (the lead runs these)

1. `npm test` and `npm run build` pass on the spike branch. Any test you changed to make it pass is listed, with the
   reason.
2. `npm run start:local`: sign-in, Calendar, the booking modal and the patient booking flow (v2) open without
   console errors. The spike page renders every component in the table marked "exists".
3. Nepali text renders in Noto Sans Devanagari, not in a system fallback, on the spike page.
4. There are no raw hex values in the spike page's components. Colours come from the theme tokens.
5. The spike page is not reachable in a production build (`npm run build && npm run serve`, then open the route).
6. The findings doc answers every point in §4.

## 6. Not in scope

Building Home or any real screen; renaming `spa-*` classes; dark mode beyond checking that the theme switches;
charts (Recharts stays); merging anything to `main`.

## 7. Handoff

Use the template in `docs/DEV-APPROACH.md`, and end it with a **Not verified** list.
