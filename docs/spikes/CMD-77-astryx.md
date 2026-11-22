# CMD-77: Astryx spike, findings

**Branch:** `feature/CMD-77-astryx-spike` (from `origin/main @ 6a7b980`; not merged, no PR) · **Built:** 2026-11-22 by Builder A
**Brief:** `docs/briefs/CMD-77-astryx-spike.md` · **Checked by:** nobody yet (the lead re-runs the gates)

## 1. Verdict

**GO WITH CONDITIONS.** Astryx 0.7.17 renders every component the Home brief needs inside our plain-JSX Vite app, on
React 19, with no StyleX or Tailwind 4 build step, and `npm test` (231) and `npm run build` pass. The conditions:

1. **Tailwind must go 3 → 4.** On Tailwind 3 the Astryx styles are overridden (section 5.1: unstyled buttons and
   cards). This is the one upgrade Astryx forces on us.
2. **Do the upgrade as its own PR, behind a full visual pass of today's screens.** I only checked the
   build, the tests and the login page. The rest was not looked at (section 7).
3. **`react-helmet` has to go** (React 19 peer conflict). Done here in two files.
4. **Local DB wasn't available**, so sign-in, Calendar, the booking modal and the patient booking flow were **not
   checked** (section 8).
5. **Bundle cost is real** when Astryx ships (section 6): decide with the lead how to load it.

## 2. The key finding: Astryx needs no build step

The brief expected a StyleX build step and Tailwind 4. Neither is needed for Astryx itself. The README says: "No build
plugins needed; Astryx ships pre-built" (`packages/core/README.md`, Vite section). Evidence in the installed packages
(`node_modules/@astryxdesign/core@0.7.17`):

- `dist/astryx.css`: the compiled component styles, in `@layer astryx-base`.
- `src/reset.css` is imported as `@astryxdesign/core/reset.css` (`@layer reset`).
- `@astryxdesign/theme-neutral/theme.css` (`@layer astryx-theme`) and `fonts.css` (Figtree woff2 files shipped in the package).
- `peerDependencies`: `react >=19`, `react-dom >=19`, `@stylexjs/stylex ^0.19.0`. StyleX is only a peer
  dependency for the `xstyle` prop types. **No StyleX Babel/Vite plugin is configured in this repo and none is needed.**

The imports used (`src/pages/astryx-spike/index.jsx`):

```js
import "@astryxdesign/theme-neutral/fonts.css";
import "@astryxdesign/core/reset.css";
import "@astryxdesign/core/astryx.css";
import "@astryxdesign/theme-neutral/theme.css";
```

Wrap in `<Theme theme={clinicTheme}>` from `@astryxdesign/core/theme`. Components are imported per path:
`import { Button } from "@astryxdesign/core/Button"`.

## 3. Versions and steps (copy these)

All pinned exact (no `^`).

| Package | Before | After | Why |
|---|---|---|---|
| `react`, `react-dom` | `^18.2.0` | `19.3.1` | Astryx peer dependency |
| `@astryxdesign/core` | n/a | `0.7.17` | the design system |
| `@astryxdesign/theme-neutral` | n/a | `0.7.17` | base theme |
| `@astryxdesign/cli` (dev) | n/a | `0.7.17` | `component`/`docs` lookups; not needed at runtime |
| `@stylexjs/stylex` | n/a | `0.19.2` | Astryx peer dependency |
| `@fontsource/noto-sans-devanagari` | n/a | `5.2.8` | Nepali font (Figtree has no Devanagari) |
| `tailwindcss` | `3.4.6` | `4.3.5` | Astryx's layers lose to Tailwind 3's unlayered CSS |
| `@tailwindcss/postcss` | n/a | `4.3.5` | Tailwind 4's PostCSS plugin |
| `autoprefixer` | `10.4.2` | removed | Tailwind 4 does it |
| `react-helmet` | `^6.1.0` | removed | peer `react <=18`; replaced by React 19 `<title>`/`<meta>` |
| `tailwindcss-elevation`, `tailwindcss-fluid-type`, `@tailwindcss/line-clamp`, `@tailwindcss/aspect-ratio` | present | removed | **unused** (not in `tailwind.config.js` plugins, no imports); `tailwindcss-elevation` peers `tailwindcss ^3`, which made `npm ci` fail |

Unchanged: `vite 5.0.0`, `@vitejs/plugin-react 4.3.4`, `react-router-dom 6.0.2`, `@testing-library/react 11` (no test
uses it), `@tailwindcss/forms`, `tailwindcss-animate`, `@tailwindcss/container-queries`, `@tailwindcss/typography`.

Files changed to make it work:
- `postcss.config.js`: only `"@tailwindcss/postcss": {}`.
- `src/styles/tailwind.css`: v3 `@tailwind` lines replaced by the layer-order line, `@import` of Tailwind's
  `theme.css` / `preflight.css`, `@config "../../tailwind.config.js"` (keeps the whole v3 JS config), `@source`, and
  `@tailwind utilities;`.
- `src/styles/index.css`: wrapped in `@layer base { … }` (section 5.2).
- `src/pages/branch-manager-dashboard/index.jsx`, `src/pages/booking-management-portal/index.jsx`: Helmet → plain `<title>`/`<meta>`.
- `src/theme/clinicTheme.js`, `src/pages/astryx-spike/*`, a lazy dev-only route in `src/Routes.jsx`.

Steps for a builder starting from `origin/main`:
```bash
npm install -E react@19.3.1 react-dom@19.3.1
npm install -E @astryxdesign/core@0.7.17 @astryxdesign/theme-neutral@0.7.17 @stylexjs/stylex@0.19.2 @fontsource/noto-sans-devanagari@5.2.8
npm install -D -E @astryxdesign/cli@0.7.17 tailwindcss@4.3.5 @tailwindcss/postcss@4.3.5
npm uninstall autoprefixer react-helmet tailwindcss-elevation tailwindcss-fluid-type @tailwindcss/line-clamp @tailwindcss/aspect-ratio
npm install    # then check plain `npm ci` passes: CI and the Dockerfile use it
```
Then apply the file changes above. Restart `vite` after changing `postcss.config.js` (the dev server caches it).

## 4. Components: CMD-76 §5 against Astryx 0.7.17

Checked with `npx @astryxdesign/cli component <Name>` (174 components) and rendered on the spike page.

| CMD-76 §5 name | Result | Notes |
|---|---|---|
| `AppShell` | exists | `sideNav`, `topNav`, `banner`, `variant`. Collapses to a hamburger at phone width. |
| `SideNav` | exists | `SideNavItem` has `endContent` for the badge (the Inbox badge rendered). `SideNavSection`, `SideNavHeading` exist. |
| `Menu` (branch switcher) | **different name: `DropdownMenu`** | `items=[{label}]` + `button={{label}}`; also `MoreMenu`, `ContextMenu`. Rendered. |
| `Layout` page header | exists | `Layout` + `LayoutHeader` / `LayoutContent` / `LayoutFooter` / `LayoutPanel`. |
| `Banner` (yellow) | exists, **prop is `status="warning"`** | Rendered yellow. Statuses: info, warning, error, success. |
| `Card` | exists | Rendered with the 1 px border and no shadow. |
| `Badge` | exists, **no `gray` variant: use `neutral`** | Variants: neutral, info, success, warning, error, plus ten hues (incl. `purple`). Design direction §2 says `gray`: change the doc to `neutral`. |
| `Button` (sizes, disabled) | exists | `variant` primary/secondary/ghost/destructive; `size` sm/md/lg; `isDisabled`. |
| `List` | exists | `List` + `ListItem` (`startContent`, `description`, `endContent`). |
| `EmptyState` | exists | `title`, `description`, `icon`, `actions`. |
| `Skeleton` | exists | |
| `Toast` | exists, used through `useToast()` | Rendered bottom-**right**; the design (FND · States) says bottom centre. Not looked into whether placement is configurable. |
| `CommandPalette` | exists | Needs a `searchSource`; `createStaticSource(items)` from `@astryxdesign/core/Typeahead` works. |
| `ChatComposer` | exists (`@astryxdesign/core/Chat`) | Also `ChatDictationButton`, `ChatMessage*`. Fills its parent's width: don't put it in an `align="start"` stack. |
| `Dialog` | exists | `isOpen`, `onOpenChange`, `DialogHeader`. |
| Text input | exists: `TextInput` | `label` and `value` required. |
| Select | exists: `Selector` | `options=[{value,label}]`. Also `MultiSelector`, `Typeahead`. |
| Date input | exists: `DateInput` | ISO string value; `DateTimeInput`, `DateRangeInput`, `Calendar` also exist. |
| `ProgressBar` | exists | `value`, `hasValueLabel`, `variant`, `marks`. The setup checklist can use it. |
| AskOrTell, ApprovalCard, WhoActed, AgentActivityRow | ours, as the brief says | WhoActed's agent chip was built here from tokens only (a `span` + `--color-agent-muted`). Astryx has no purple-token Badge, but it has `Badge variant="purple"`; I did not use it because it is not our agent token. |

Not used but relevant: `Table`, `Tabs`/`TabList`, `Drawer`, `BottomSheet`, `MobileNav`, `Stepper`, `Timestamp`, `Avatar`,
`SegmentedControl`, `Collapsible`. Charts are not stable (`@astryxdesign/charts` is canary only): keep Recharts.

## 5. What the upgrade broke

### 5.1 Fixed

- **Astryx styles lose to Tailwind 3 (blocking).** With Tailwind 3 kept, buttons rendered as bare text and cards
  had no background. Cause: Astryx styles live in cascade layers; Tailwind 3's `@tailwind base` output and
  our `index.css` `* { margin: unset; line-height: normal; font-family: inherit }` are **unlayered**, and unlayered
  CSS beats any layer. Fix: Tailwind 4 (real layers) plus the layer order `reset, theme, base, astryx-base,
  astryx-theme, components, utilities`, declared on the first line of `src/styles/tailwind.css`.
- **`index.css` global reset.** Under Tailwind 4 an unlayered `* { margin: unset }` would also beat every
  `m-*` utility. Wrapped in `@layer base` so it behaves as before (loses to utilities and to Astryx).
- **`@import` must come first.** The `@font-face` rules at the top of `tailwind.css` made CSS ignore the later
  `@import`s: preflight and utilities silently vanished (CSS 11 kB instead of 117 kB). Imports now sit above them.
- **`@import "tailwindcss/utilities.css" layer(utilities)` produced zero utilities** with Vite 5.0.0 +
  `@tailwindcss/postcss` (Astryx's documented line). `@tailwind utilities;` works. Cause not investigated further.
- **`react-helmet` (2 files).** Peer `react <=18`; `npm ci` failed with ERESOLVE. Replaced with React 19's native
  `<title>`/`<meta>`. Login page title still showed "ClinicMD".
- **Unused Tailwind plugin packages.** `tailwindcss-elevation` (peer `^3`) also broke `npm ci`. Four unused packages removed.
- **`npm ci` (what CI and the Dockerfile run) passes** on the final lockfile; `npm ls` shows no invalid peers.
- **The Tailwind v3 JS config is kept** via `@config`. Renamed-utility risk checked in the built CSS: `.rounded` still
  `0.25rem`, `.shadow-sm` still the v3 value, `.flex-shrink-0` and `.bg-primary` exist. So today's classes keep their v3 meaning.

### 5.2 Not fixed (effort)

| Item | Effort |
|---|---|
| **Visual regression of every existing screen under Tailwind 4.** I did not look at them. Counts in `src/`: 862 `space-x/y-*` (v4 changed the selector, can change spacing with `hidden` or margin children), 143 `outline-none` (v4 renamed it `outline-hidden`; the meaning differs), 10 `bg/text/border-opacity-*` (removed in v4: those 10 lose their opacity), 1 bare `ring` (width 3 px → 1 px), 64 `divide-*`. | **2 to 3 days** of walking every screen in light and dark, plus fixes. The biggest unknown in the whole upgrade. |
| **Token name collisions on `:root`.** Our `tailwind.css` and the Astryx theme both define `--color-accent`, `--color-border`, `--color-error`, `--color-success`, `--color-text-primary`, `--color-text-secondary`, `--color-warning`. Astryx's wins (a later layer), and on the spike page `:root` shows Astryx's values. **`var(--color-…)` of those seven has zero uses in `src/`**, so nothing visible changes today; Tailwind's JS-config colours are separate. Anything new that reads them gets Astryx's values. | 0.5 day: rename ours with a `--spa-` prefix, or scope Astryx to the new screens. |
| **Page background.** `body` stays our `bg-background` (`#FAFAFB`), not Astryx's `--color-background-body` (`#f1f1f1`). The cards still read as cards, but Home is not the "white cards on soft grey" look. | 0.5 day to decide the page background (scope the Astryx shell, or set the body background to the token). |
| **Existing screen inside the Astryx `AppShell`.** The `?legacy=1` mode of the spike page embeds `BranchManagerDashboard`, but it needs sign-in and the local DB. **Not shown.** | needs the local DB |
| **Prod build uses the runtime theme.** Dev warns: "Theme "clinic" is using runtime style injection… build the theme". The built path (`npx astryx theme build`) is not tried. | 0.5 day |
| **Brand clash.** The existing app uses `--color-primary: #7B2FF7` as its brand purple, the same hex as the new agent purple, which design direction §2 reserves for agents only. Today's screens keep using it. | a design decision, not a build one |
| Existing fonts. The app uses Inter; Astryx uses Figtree. They load side by side; I did not check old screens for a font change. | included in the visual pass |
| `@testing-library/react@11` and `react-router-dom@6.0.2` | No tests use RTL. `react-router-dom` 6.0.2 worked on React 19 on the pages I opened (login, spike). It is very old: upgrade it separately. Not tested: navigation flows. |
| ESLint config says `react-app`; no lint script exists, so not run. | none |

## 6. Numbers

| | Before (`origin/main`) | After (React 19 + TW 4, spike not shipped) | If the spike's Astryx code shipped |
|---|---|---|---|
| main JS | 4,389.92 kB (gzip 1,104.39) | 4,455.09 kB (gzip 1,122.40) | same + a lazy chunk of **1,167.15 kB (gzip 377.25)** |
| main CSS | 104.62 kB (gzip 18.40) | 117.53 kB (gzip 20.46) | same + **338.24 kB (gzip 53.79)** |
| Dev server `ready` | 137 ms | 130 ms | |
| Dev first-request transforms (`/`, `index.jsx`, `App.jsx`, `Routes.jsx`; `--force`) | 0.68 s | 1.14 s (also requests the spike module) | |
| `npm test` | 231 pass | 231 pass | |

Notes: the "if shipped" column was measured by building once with the route forced on (then reverted). It covers every
component the spike page imports, with the **source (runtime) theme**; a built theme and fewer imports would cost
less. The +65 kB main-JS is React 19 vs 18 (and −16 kB from removing react-helmet). Start-time figures are rough, single runs
(`curl` timing, not a browser). Astryx adds **nothing** to the production bundle today because the page is dev-only.

## 7. Spike page and screenshots

Route `/:orgSlug/__astryx`, dev only (`import.meta.env.DEV`). It is mounted **without sign-in**, because the local DB was
unavailable (section 8): fine for a dev-only page, not for anything real. Open it with `npm run start:local` →
`http://localhost:4029/bright-smile-dental/__astryx`.

Checked in Chrome on the dev server:
- Rendered: AppShell, SideNav with a badge, branch DropdownMenu, Layout header with a number Badge, Banner, Card,
  Badges, Buttons (lg/md/sm, ghost, disabled), List, EmptyState, Skeleton, ProgressBar, TextInput, Selector, DateInput,
  ChatComposer. Toast, Dialog and CommandPalette **open and close** (Escape closes).
- Nepali: computed `font-family` is `"Noto Sans Devanagari", Figtree, …`, and `document.fonts` shows
  Noto Sans Devanagari 400 **loaded** (a system fallback would not load it). Looks right on the page; whether the mixed
  Figtree/Devanagari line reads well at small sizes on a real phone is still **UNVERIFIED** (as design direction §3 says).
- Agent chip from tokens: background `rgb(241,234,255)` = `#F1EAFF`, text `rgb(90,31,207)` = `#5A1FCF`, dot `--color-agent`.
  No raw hex in the page's components: the only colours are tokens (`spike.css` uses `var(--color-agent*)`); the three hex
  values exist once, in `src/theme/clinicTheme.js`.
- Theme: `defineTheme({ extends: neutralTheme })` adds only the three agent tokens, with dark values (`light-dark(…)`).
  I **did not switch to dark mode** to look at it.
- The spike page is **not in the production build**: `grep` of `build/` finds no spike code, no `data-astryx`,
  no `--color-agent`. In `vite preview` the route renders nothing (no Astryx theme in the DOM).

Screenshots (`docs/spikes/CMD-77-assets/`):
- `spike-1440-top.jpg`, `spike-1440-bottom.jpg`: 1440 px.
- `spike-500-mobile.jpg`: **500 px, not 390**: Chrome would not shrink the window below 500 px. No horizontal scroll;
  the side nav collapses to the hamburger. Header controls truncate because my button row doesn't wrap (page code, not Astryx).
- **No screenshot of an old screen inside the Astryx shell or of an old screen working**: needs the local DB.

## 8. Not verified

- Sign-in, Calendar, the booking modal and the patient booking flow (v2): **not verified, local DB unavailable.**
  Ports 55321/55322 are held by another project's Supabase stack (`public.organizations` does not exist there); I did not touch it.
- Any existing screen under Tailwind 4 beyond the login page: no visual comparison, no dark-mode check.
- The `?legacy=1` embed of an old screen inside the Astryx `AppShell`.
- A 390 px screenshot (500 px taken); real-phone rendering of Nepali text.
- Dark mode of the Astryx theme.
- A built theme (`astryx theme build`) and the production cost of it.
- Toast placement (bottom centre) and the CommandPalette opening on ⌘K (I only opened it from a button).
- Console errors on the pages in acceptance check 2 (the only console errors seen came from the missing local DB
  tables; the spike page itself logged the runtime-theme warning only).
- `npm run serve` (I used `vite preview`, which is what `serve` runs).
- The Docker image build and the Deploy workflow (`npm ci` works locally; the image was not built).
- `react-router-dom@6.0.2`, `recharts@2`, `@dnd-kit` and `jspdf` flows on React 19 (they installed with no peer errors; none exercised).
