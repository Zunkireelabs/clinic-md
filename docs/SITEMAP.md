# ClinicMD Sitemap

**Status:** draft for owner review · **Ticket:** CMD-75 · **Written:** 2026-11-21 by the lead session
**Follows:** `docs/PRODUCT-BRIEF.md` (v2). If this file and the brief disagree, the brief wins.
**Used by:** `docs/USER-JOURNEYS.md`, the design direction (CMD-72) and the mockups.

> This is the **target** sitemap. The "Today" column says what exists on `main @ 6a7b980`.
> Paths are proposals for the builder; names can change in the mockups.
> Labels shown here are the generic ones. A clinic sees its specialty pack's words
> (for example Dentist, Chair, Treatment).

**Status words:** **Exists** (works today) · **Changes** (exists, reworked) · **New** · **Removed**.
**Phase** is the phase in the brief (section 12) that delivers it.

---

## 1. How the app is organised

Four surfaces:

| Surface | Who | Where |
|---|---|---|
| **Staff app** | Owner, manager, front desk, practitioner | `/:org/...` (desktop and phone) |
| **Practitioner phone** | Practitioner recording a consultation | `/phone`, `/:org/phone` |
| **Patient side** | Patients | `/:org`, `/:org/book`, `/:org/account`, and pages opened from a message link |
| **Platform** | Zunkireelabs | `/platform/...` |

**Today** almost every staff page is a view inside one route (`/:org/dashboard?view=...`). The target gives
each area its own address, so a link, the copilot or an agent's notification can open the exact screen.

## 2. Staff app navigation

**Sidebar (target, eight items and Settings):**

| # | Item | What it is | Today |
|---|---|---|---|
| 1 | **Home** | The clinic's work: needs you, done by agents, today, ask or tell | Changes (replaces Dashboard) |
| 2 | **Inbox** | Every conversation with patients, all channels, calls included | New |
| 3 | **Calendar** | The schedule, plus the bookings list | Exists (Calendar and Bookings are two items today) |
| 4 | **Patients** | Directory and the patient record | Exists |
| 5 | **Money** | Payments, dues, invoices, packages, daily closing | Changes (gathers Outstanding, Packages, Memberships, Vouchers, Daily closing) |
| 6 | **Team** | Practitioners, shifts, attendance, payroll, performance | Changes (gathers the "People" section) |
| 7 | **Agents** | The agents, their playbooks and scorecards, and the clinic brain | New (replaces Outreach) |
| 8 | **Reports** | Briefings, questions, and the standard reports | Exists, extended |
| | **Settings** (footer) | Clinic, specialty pack, channels, payments, people and roles, AI, audit | Exists, extended |

**Always available, on every screen:**
- **Ask or tell** (the Staff copilot): a panel plus ⌘K. It knows the page and the patient you are on.
- **Branch switcher**, including the all-branches view.
- **Notifications**: items that need you, linking to Home.

**Rolling this out in small steps.** An earlier full sidebar overhaul was reverted as too much. So:
- **Phase 2** adds only **Inbox** and **Agents** to today's sidebar. Nothing else moves.
- **Phase 3** brings the full eight-item sidebar with the new shell, and only after the mockups are approved.

## 3. Staff app screens

### 3.1 Home `/:org/home`

| Screen | What it shows | Today | Phase |
|---|---|---|---|
| Home | Four sections: **Needs you**, **Done by agents**, **Today**, **Ask or tell**. Content depends on role (section 6). | Changes | 3 |
| Work queue (in Home) | Approvals waiting, conversations handed off by an agent, exceptions. Approve, edit, reject, assign. | New (a simple version ships inside Agents in Phase 2) | 2, then 3 |
| Agent activity (in Home) | What agents did since you last looked, the outcome, undo where possible | New | 2, then 3 |
| Setup checklist (in Home, new clinics) | Steps left to finish setting up the clinic | New | 3 |

### 3.2 Inbox `/:org/inbox`

| Screen | What it shows | Today | Phase |
|---|---|---|---|
| Conversation list | All threads; filters: needs a person, handled by agent, unread, channel, branch, assigned to me | New | 2 |
| Conversation `/inbox/:threadId` | Messages and call transcripts in one thread; who is handling it (agent or person); take over / hand back; reply with a template; the patient's summary beside it with quick actions (book, reschedule, take payment) | New | 2 |
| Call view (in a thread) | Recording, transcript, what the agent did during the call | New | 6 |
| New message | Start a conversation with a patient on a chosen channel (consent checked) | New | 2 |

### 3.3 Calendar `/:org/calendar`

| Screen | What it shows | Today | Phase |
|---|---|---|---|
| Day and 4-Day views, Unassigned column, blocks, staff transfers | The schedule by practitioner or resource | Exists | n/a |
| Week and Month views, phone layout, filters, zoom, Assign flow | Ported from bookX | New | 3 |
| Availability shading and "Book anyway" guard | Ported from bookX | New | after 3 |
| Waitlist panel, walk-in booking | Ported from bookX | New | after 3 |
| New booking panel | Create a booking from a slot | Exists (updated with the port) | 3 |
| Booking panel `/bookings/:id` | Details, status, timeline, assign, reschedule, payment, messages for this booking, what agents did for this booking | Changes (the fake Communication panel is replaced by the real thread) | 2 for messages, 3 for the rest |
| Bookings list `/:org/bookings` | All bookings as a table with filters; "check a booking" | Exists (moves under Calendar) | 3 |
| Consultation `/bookings/:id/consultation` | Record, transcript, structured note, images, sign-off; later the pre-visit summary and the drafted plan and follow-up | Exists (extended) | 1, then 4 |

### 3.4 Patients `/:org/patients`

| Screen | What it shows | Today | Phase |
|---|---|---|---|
| Patient list | Directory, search, duplicates | Exists | n/a |
| Patient record `/patients/:id` | Header with alerts and allergies, then the tabs below | Exists (extended) | n/a |
| · Overview | Summary, upcoming visits, dues, open treatment plans, alerts | Exists (extended) | 3 |
| · Timeline | Everything about the patient in order: visits, notes, messages, calls, payments, consents, agent actions | New | 2 (messages), 3 (full) |
| · Visits | Visit list and the note for each visit | Exists | n/a |
| · Treatment plans | Planned services across visits, accepted or not, progress | New | 5 |
| · Chart | The specialty module: tooth chart, or body map and photo timeline, or vitals | New | after 3 |
| · Documents and photos | Uploads, X-rays, before/after pairs | New | after 3 |
| · Forms and consents | Intake forms, signed consents, messaging and recording consent | New | 1 (recording consent), 3 (rest) |
| · Money | Payments, dues, invoices, packages for this patient | Changes | 5 |
| Edit patient | Name, phone, email, gender, date of birth, language, preferred channel | New (CMD-65) | alongside |
| Merge duplicates | Review and merge | Exists | n/a |

### 3.5 Money `/:org/money`

| Screen | What it shows | Today | Phase |
|---|---|---|---|
| Collect payment | Take a payment against a booking | Exists | n/a |
| Outstanding | Dues by patient, visits that need closing, settled history, and what the Collections agent is doing about each | Exists (extended) | 5 |
| Invoices and receipts | Numbered documents with VAT; send or print | New | 5 |
| Payment links | Links and QR sent to patients; paid, pending, expired; reconciliation | New | 5 |
| Packages | Define, issue, track redemptions | Exists | n/a |
| Memberships, Vouchers, Referrals | As built | Exists behind flags; ship or remove is open (CMD-14) | to decide |
| Daily closing | Close and lock the day | Exists (moves from Reports) | 3 |

### 3.6 Team `/:org/team`

| Screen | What it shows | Today | Phase |
|---|---|---|---|
| Practitioners | List, profile, specialties, services they can do | Exists | n/a |
| Shifts | Working hours per practitioner | New (with the calendar port) | after 3 |
| Attendance | Check-in/out, leave, attendance calendar | Exists | n/a |
| Payroll | Monthly run, generate and finalise | Exists | n/a |
| Performance | Score per practitioner with tabs | Exists | n/a |

### 3.7 Agents `/:org/agents`

| Screen | What it shows | Today | Phase |
|---|---|---|---|
| Agents overview | One card per **live** agent (no cards for agents not built yet): on or off, autonomy level, this week's scorecard. The clinic's **agent-handled share** at the top. Tabs: Agents, Activity, Clinic brain, Usage and budget (manager and owner). | New | 2 |
| Agent page `/agents/:agent` | Scorecard over time; playbooks; recent activity; suggestions to raise autonomy | New | 2 (Follow-up), then per agent |
| Playbook editor | Trigger, goal, channel order, template, autonomy level, quiet hours; preview on a real patient; turn on or off | New (replaces Outreach rules and templates) | 2 |
| Activity log `/agents/activity` | Every agent action: what, for whom, on whose approval, outcome; filter and undo | New | 2 |
| Clinic brain `/agents/brain` | **Facts** (hours, prices, policies, service information, aftercare, common questions), **Preferences** (tone, languages, practitioner styles), **Teaching queue** (questions agents could not answer; proposed preferences from staff edits), each with owner, date and approval | New | 2 (facts and teaching queue), 4 (preferences from the learning loop) |
| Usage and budget | AI, message and call usage against the clinic's budget | New | 2 |

### 3.8 Reports `/:org/reports`

| Screen | What it shows | Today | Phase |
|---|---|---|---|
| Briefings | The Owner's advisor's morning briefings, per branch and across branches; each item links to its records and can become a task | New | 4 |
| Ask | Ask a question about the clinic's data; answers cite records | New | 4 |
| Sales, Team, Patients reports | The existing catalogue (daily, service revenue, discounts, performance, attendance, transfers, referrals) | Exists | n/a |
| Clinic numbers | The charts from today's dashboard (KPIs, utilisation, revenue) | Exists (moves from Dashboard) | 3 |
| Agent reports | Scorecards across agents, agent-handled share over time, cost per outcome | New | 2 (basic), 4 |

### 3.9 Settings `/:org/settings`

| Screen | What it shows | Today | Phase |
|---|---|---|---|
| Clinic and branches | Profile, hours, branches, closed dates | Changes | 3 |
| Specialty pack | Labels, note templates and AI prompts, image types, forms, chart module on or off | New | 3 |
| Resources (chairs or rooms) | List and capacity | Exists | n/a |
| Services and categories | The service list and prices | Exists | n/a |
| Channels | SMS, chat apps, email, phone numbers and voice; templates; quiet hours; fallback order; consent wording | New | 2 (SMS, one chat app, email), 6 (voice) |
| Payments | Payment methods; payment providers; invoice numbering and VAT | Exists (methods), New (rest) | 5 |
| People and roles | Staff accounts, roles, branch access, PINs | Changes | 3 |
| AI and privacy | AI on or off for the clinic, which providers are used, consent texts, data settings | New (today the switch is set by us in SQL) | 2 |
| Audit log | Every action, by person or agent | Changes (exists as a screen, but nothing is written to it today) | 2 |
| Plan and billing | The clinic's plan, usage and invoices from us | New | 7 |

### 3.10 Setup `/:org/setup`

| Screen | What it shows | Today | Phase |
|---|---|---|---|
| Setup guide | Guided by the Staff copilot: pick a specialty pack → branches and hours → services and prices → team → channels → clinic brain basics → turn on the first playbooks | New | 3 (manual steps), 7 (self-serve) |

### 3.11 Sign-in

| Screen | Path | Today |
|---|---|---|
| Find your clinic | `/login` | Exists |
| Staff sign-in | `/:org/login` | Exists |

## 4. Practitioner phone

| Screen | Path | What it does | Today | Phase |
|---|---|---|---|---|
| Phone entry and pairing | `/phone`, `/phone/pair` | Pair the phone by QR or code | Exists | 1 (verify in prod) |
| Recorder | `/:org/phone` | Tap to record a consultation; shares the draft with the desktop | Exists | 1 |

The rest of the staff app works on a phone as a responsive layout (Phase 3 onward); there is no separate app.

## 5. Patient side

| Screen | Path | What it does | Today | Phase |
|---|---|---|---|---|
| Book an appointment | `/:org`, `/:org/book` | Public booking flow | Exists (copy fixes, CMD-66) | alongside |
| Patient sign-in and sign-up | `/:org/customer-login`, `/:org/signup` | Email code sign-in | Exists | n/a |
| My account | `/:org/account` | Bookings and history | Exists | n/a |
| Confirm, reschedule or cancel | opened from a message link | One-tap confirm; pick a new time; cancel | New | 2 (confirm), 5 (reschedule) |
| Pay | opened from a message link | Pay a due by eSewa, Khalti or Fonepay; receipt | New | 5 |
| Forms and consent | opened from a message link | Fill intake forms and sign consents before the visit | New | 3 |
| Visit summary and aftercare | opened from a message link | What was done, instructions, next visit | New | 4 |
| Stop messages | opened from a message link | Opt out per channel | New | 2 |

**Most patient contact happens in their own chat app, SMS or a phone call, not on our pages.** Those
conversations have no screen here; they appear to staff in the Inbox.

**Link pages must be safe:** each link does one thing, expires, and cannot be guessed or used to look up
another patient (see CMD-63 on the booking flow).

## 6. Platform (Zunkireelabs) `/platform`

| Screen | What it shows | Today | Phase |
|---|---|---|---|
| Sign-in, clinics revenue dashboard, clinic detail | Revenue share across clinics | Exists (flag off in prod) | n/a |
| Clinics | Create and set up a clinic, pick its pack, switch AI on | New (today done by SQL) | 3 |
| Pack library | The specialty packs and their starter content | New | 3 |
| Agent quality | Test sets and pass rates per agent; review of sampled conversations | New | 2 |
| Usage | AI, message and call usage and cost per clinic | New | 2 |
| Plans and billing | Plans, subscriptions, invoices to clinics | New | 7 |

## 7. Who sees what

Today's roles are `staff` (front desk), `manager`, `admin` (owner), `admin_viewer` (read-only owner view).

| Area | Front desk | Practitioner | Manager | Owner | Read-only |
|---|---|---|---|---|---|
| Home | own work and today | own patients today | branch | all branches | view |
| Inbox | yes | own patients | yes | yes | view |
| Calendar and bookings | yes | own column | yes | yes | view |
| Consultation | open | yes, signs the note | open | open | no |
| Patients | yes | yes | yes | yes | view |
| Money | collect payment | no | yes | yes | view |
| Team | no | own attendance | yes, no payroll | yes | view |
| Agents | activity and teaching queue | no | playbooks and approvals | everything, including autonomy and budget | view |
| Reports | no | own performance | branch | all, with briefings | view |
| Settings | no | own preferences | clinic data | everything | view |

**Decided 2026-11-21 (Sadin):**
1. **Access level and practitioner profile are separate.**
   - *Access level* is what a person may do: owner, manager, front desk, practitioner, read-only. One per person per clinic.
   - *Practitioner profile* is what a person is: someone who treats patients, has a calendar column, signs notes
     and receives clinical hand-offs. Any login can be linked to one.
   - So a doctor who owns the clinic is **Owner + linked profile**; a doctor who manages a branch is
     **Manager + linked profile**; an employed doctor who only treats is **Practitioner + linked profile**.
   - A linked person gets their access level's screens plus the practitioner parts: "my patients today" on Home,
     their notes to sign, clinical hand-offs routed to them.
   - Set in Settings → People and roles: choose the access level, then "this person treats patients" and the profile.
   - The new **practitioner** access level is the limited one (the Practitioner column above): no money, payroll or settings.
   - Later refinement, not in scope now: a different access level per branch.
2. **Front desk sees Patients.** Today the patient list is hidden from the `staff` role; front desk gets it.
3. **Sidebar in two steps**, as in section 2: Inbox and Agents added in Phase 2; the full sidebar in Phase 3
   after the mockups are approved.

**For the builder:** today a practitioner (`dentists`) is a record with no link to a login (`users`), and the
role enum is `staff`, `manager`, `admin`, `admin_viewer`. This decision needs a new role value and a
user-to-practitioner link, with RLS for "own patients". It is a migration and gets its own ticket.

## 8. Screens removed or replaced

| Today | What happens |
|---|---|
| Dashboard (charts) | Replaced by Home; the charts move to Reports → Clinic numbers |
| Outreach (rules, templates, review queue, message log) | Replaced by Agents (playbooks), Settings → Channels (templates), Home (work queue) and Inbox (messages) |
| Assistant panel (keyword mock) | Replaced by the Staff copilot |
| Communication panel in the booking screen (fake) | Replaced by the booking's real message thread |
| Old manage-booking portal (dead, with one broken link from the booking flow) | Removed; replaced by the confirm / reschedule link page |
| `?view=` addresses under `/:org/dashboard` | Replaced by real addresses; old links redirect |
