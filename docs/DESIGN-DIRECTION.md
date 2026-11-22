# ClinicMD Design Direction

**Status:** direction given by the owner 2026-11-21; details below are the lead session's write-up for his review
**Ticket:** CMD-72 · **Follows:** `docs/PRODUCT-BRIEF.md` (v2), `docs/SITEMAP.md`, `docs/USER-JOURNEYS.md`
**Reference boards:** the "ClinicMD design direction" canvas (Home and the direction sheet),
https://claude.ai/artifact/DDYuBuT3fvosAvUBBzRtmz (private to the owner)

Every mockup and every screen the builder ships follows this file. A design that departs from it needs
Sadin's sign-off, and this file is changed first.

---

## 1. The direction in one paragraph

**Neutral, modern and premium, built on Astryx. Colour appears only when it means something.**
The base is Astryx's neutral look: white cards on a soft grey page, near-black text and buttons.
**Purple means an agent did it**, and is used for nothing else. Green, amber and red show state.
The result should feel like serious work software that is calm to sit in all day, and where the eye goes
straight to what needs a person.

**What the owner said (2026-11-21):** use Astryx so we do not spend time on CSS; take layout references from
Scale's healthcare page; keep it neutral "as Astryx"; it must feel modern and premium; no colour options, build
to this plan.

## 2. Colour

All values are **Astryx's neutral theme tokens, unchanged** (read from `github.com/meta/astryx`,
`packages/themes/neutral`, v0.7.17), except the three agent tokens, which are ours.

| Role | Astryx token | Light value | Used for |
|---|---|---|---|
| Page | `--color-background-body` | `#f1f1f1` | The background behind cards |
| Card | `--color-background-card` | `#ffffff` | Cards, panels, inputs |
| Line | `--color-border` | black at 8% | Borders and dividers |
| Text | `--color-text-primary` | `#000000` | Body text and headings |
| Secondary text | `--color-text-secondary` | `#474747` | Labels, times, supporting text |
| Main button | `--color-accent` / `--color-on-accent` | `#1b1b1b` / `#ffffff` | The primary button |
| Second button, selected nav item | `--color-neutral` | black at 6% | Secondary button, active sidebar item |
| Person chip | Badge `gray` | `#e2e2e2` / `#1b1b1b` | "Booked by Dr. Sharma", "Approved by Anita" |
| Confirmed, paid, done | Badge `green` | `#bce0bb` / `#00490b` | Positive state |
| Needs you, waiting | Badge `yellow` | `#fae19e` / `#4b3900` | Attention state |
| Urgent, failed, overdue | Badge `red` | `#ffc4be` / `#76000c` | Problem state |
| **Agent** (ours) | `--color-agent` | `#7B2FF7` | The agent mark and icon |
| **Agent chip** (ours) | `--color-agent-muted` / `--color-on-agent-muted` | `#F1EAFF` / `#5A1FCF` | Anything an agent did, drafted or handed off; the copilot; "AI drafted" |

**Rules**
- **Use Astryx's tokens as they are.** The only additions to the theme are the three agent tokens.
- **Purple is reserved.** Never use it for a normal button, a link, a selected tab or decoration. If something
  is purple, an agent was involved.
- **The primary button is near-black,** not a brand colour.
- **The old brand purple `#7B2FF7` is dropped from the staff app** (Sadin, 2026-11-22). It was the same hex as the
  agent purple (CMD-77 found this). As each screen moves to Astryx, replace its brand-purple buttons, links,
  tabs and highlights with the neutral tokens. The logo keeps its own colours.
- **State colours are for state only,** always with a word beside them. Colour is never the only signal.
- **No gradients, no coloured page backgrounds, no decorative illustration.**
- **Dark mode** is supported through Astryx's theme (light and dark values per token). Light is designed first.
- **Patient-facing pages** (booking, confirm, pay, forms) carry the clinic's own logo and colour, not ours.
- These values become an Astryx theme (`defineTheme` extending the neutral theme). The builder uses tokens,
  never raw hex values in components.

## 3. Type

Astryx's neutral type scale, unchanged: Figtree, base 14, ratio 1.2.

| Use | Astryx step | Size |
|---|---|---|
| Page title | Heading 1 | 24, semibold |
| Section title | Heading 2 | 20, semibold |
| Card title | Heading 3 | 17, bold |
| Body, labels on controls | Body | 14 |
| Supporting text, badges | Supporting | 12 |
| Nepali text | Noto Sans Devanagari at the same step, line height 1.6 | |
| Numbers | Tabular figures wherever numbers sit in a column (times, money, counts) | |

- **Figtree** is Astryx's neutral-theme font. It has no Devanagari letters, so **Noto Sans Devanagari** is the
  paired font for Nepali. **UNVERIFIED:** how the pair looks mixed in one line at small sizes; check on a real
  phone before the Inbox is built.
- Sentence case everywhere. No all-caps labels.

## 4. Shape, space and density

- **Corners** (Astryx tokens): 6 inside controls (`--radius-inner`), 10 for buttons and inputs
  (`--radius-element`), 12 for cards (`--radius-container`), fully round for badges.
- **Control heights** (Astryx sizes): 36 for the main controls on desktop (`lg`), 32 (`md`) and 28 (`sm`) in
  dense places such as table rows and toolbars. Buttons have 12 pixels of side padding and medium weight.
  Badges are 20 tall with 8 of side padding.
- **Borders over shadows.** Cards have a one-pixel line and no shadow. Astryx's low shadow (`--shadow-low`) is
  used only for things that float: the Ask or tell bar, menus, side panels, dialogs.
- **Spacing** on Astryx's 4-pixel scale. Cards have 16 to 20 of padding; sections sit 24 apart.
- **Density is comfortable, not sparse** on desktop. On touch screens Astryx raises the base text to 16; the
  phone designs set control heights to at least 44 (a later pass).
- **Premium comes from restraint:** generous whitespace, consistent alignment, few font sizes, almost no colour.

## 5. The patterns that carry the product

These are designed once and reused on every screen.

### 5.1 Who acted
Every booking, message, note and payment shows who did it.
- **Agent:** a purple chip with the agent mark and the agent's name ("Follow-up agent drafted").
- **Person:** a neutral grey chip ("Booked by Dr. Sharma").
- **Agent, approved by a person:** both, in that order ("Follow-up agent drafted · Approved by Anita").

### 5.2 The approval card
One card shape wherever an agent proposes something (Home, Inbox, consultation, copilot):
1. Who and what: the agent chip, the kind of action, the channel, the time.
2. A plain title saying what this is about.
3. The proposal itself, exactly as it will be sent or done.
4. Why: the records the agent used, with a link.
5. Actions, always in this order: the main action (near-black), Edit (outlined), Reject (plain).

### 5.3 Hand-off
When an agent passes something to a person, the card carries the agent's own short summary in the first
person ("I quoted NPR 85,000… Discounts are outside what I may offer") and one main action: Take over.

### 5.4 Home is the work
Order on the page, always the same: greeting and the day in one line → Ask or tell → **Needs you** (left, wide)
→ **Today** and **Done by agents** (right). Urgent items sort to the top of Needs you.

### 5.5 Ask or tell
One input, always available (also ⌘K). It carries the agent mark because the copilot answers. Before the
copilot changes anything it shows the exact change in an approval card.

### 5.6 Undo
Anything an agent did that can be undone shows Undo beside it, where it is listed.

## 6. Layout

- **App shell:** left sidebar with the clinic and branch at the top, eight items, Settings and the user at the
  bottom. The active item has a grey background, not a colour.
- **Record screens** (patient, booking), after Scale's reference: a header with the person's name and key
  facts, tabs under it, the main content in the centre, and a side column for actions and agent activity.
- **Review screens** (consultation note, drafted plan): the AI's draft with its sources beside it, and clear
  accept / edit / reject.
- **Numbers:** one large figure with a short label, used sparingly (for example agent-handled share).
- **Phone:** the sidebar becomes a bottom bar or a menu, columns stack, tables scroll sideways inside their own
  box, panels become bottom sheets. Owner and practitioner screens are designed phone-first.

## 7. Words and tone

- **Plain and short.** "Needs you", "Done by agents", "Take over", "Approve and send".
- **Agents speak in the first person and say what they did not do** ("I did not give advice").
- **No hype.** No "magic", no "AI-powered" labels, no sparkle animation. The agent mark is a small icon.
- **Patients are told they are talking to an AI assistant,** in their language.
- Labels come from the clinic's specialty pack (Dentist, Chair, Treatment), never hard-coded.

## 8. Motion and feedback

- Motion is quick and quiet: a panel slides, a card fades when done. Nothing moves to attract attention.
- After every action the screen says what happened in a short line, with Undo where possible.
- Loading shows the shape of the content (skeleton), not a spinner on a blank page.
- If AI is off or down, a calm banner says agents are paused; the screen stays fully usable.

## 9. Accessibility

- Text contrast at least 4.5 to 1, including small grey labels.
- Every control is a real button, link or input and works by keyboard.
- Touch targets at least 44 pixels.
- State is never shown by colour alone.

## 10. What we do not do

Gradients · glass effects · coloured cards with a stripe down one side · emoji as icons · purple as a general
brand colour inside the app · dashboards of charts on Home · more than one primary button in a card ·
fake or mock AI.

## 11. Mockups are the final design

The owner's rule (2026-11-21): every board on the design canvas is the production design, not a draft. The
builder builds what the board shows and makes no design decisions.

For a screen to count as designed, its boards include:
- **Desktop and phone.**
- **Every state:** normal, empty (nothing yet), loading, error, no permission, and agents paused or AI off.
- **Every role that sees it differently** (for example Home for front desk, practitioner, manager and owner).
- **Real content:** the specialty pack's labels, realistic names, Nepali where patients write Nepali, real
  lengths (long names, long messages), realistic numbers.
- **Exact values from this file:** colours, type sizes, corners and spacing. Nothing approximate.
- **Each interactive part shown in its states:** hover or focus, selected, disabled, and what appears after
  the action (the confirmation line, Undo).

Each screen's boards come with a **builder brief** that names the Astryx component for every part, the
actions it calls, and the acceptance checks. The lead checks the built screen against the board.

No exploratory variants or option sets go on the canvas unless the owner asks for them.

## 12. Building it

- **Astryx components first.** A custom component is built only where Astryx has none (the calendar).
- **Charts:** Astryx has a charts package (`@astryxdesign/charts`), but it is published only as an early
  test build, not a stable release. We keep Recharts, coloured with Astryx's data colours, until it is stable.
- **One theme file** holds the colours, type and radii above. No raw values in screens.
- Before any screen is built on it, a short spike confirms Astryx works in our plain-JSX Vite app with
  React 19 and Tailwind 4 (see the brief, section 11).
- **Not verified:** the reference boards are hand-built to Astryx's neutral values, not made with Astryx
  components, and have not been checked on a phone.
