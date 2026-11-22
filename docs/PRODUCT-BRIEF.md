# ClinicMD Product Brief

**Status:** v2, direction agreed by the owner 2026-11-21; phase dates still to set · **Ticket:** CMD-74 · **Written:** 2026-11-21 by the lead session
**Owner:** Sadin Shrestha · **Settles:** CMD-73 (phase plan) once agreed · **Feeds:** sitemap, user journeys, design direction (CMD-72), mockups

**This file is the source of truth for ClinicMD's product direction.** A feature, brief or design that
disagrees with it is wrong until this file is changed first.

> How to read this. Claims about the current product come from a read of `main @ 6a7b980`. Claims about
> competitors come mostly from search summaries and vendor pages, so outcome numbers are vendor claims unless
> stated. Anything not proven is marked **UNVERIFIED**. Phase dates are blank until Sadin sets them.

---

## 1. Summary

ClinicMD is **the operating system a small clinic runs on, where AI agents do the routine work and people
supervise, decide and treat patients.**

- **For whom:** private outpatient clinics with one to a few branches. Dental today; dermatology/skin next;
  other specialties after. Nepal first, then wider.
- **What it does:** it is the clinic's system of record (bookings, patients, clinical notes, payments, staff).
  Agents work on that record: they confirm and remind, follow up, answer patients by message and phone, chase
  dues, write the consultation note, and tell the owner what changed and what to do. The screens exist so
  people can see that work, approve it, correct it and do what only a person can do.
- **Our selling point is that the product is agentic all the way through.** Anything a staff member can do in
  the app, an agent can do through the same action, under the same rules.
- **Why we can win:** most AI agents for clinics are add-ons to someone else's software. They only see part of
  the data and often cannot write back. We own the record, so our agents see everything and act directly.
  In Nepal we found no clinic product with AI agents, chat-app messaging or local payment providers
  (**UNVERIFIED**: based on search only).

**The one number we steer by: agent-handled share.** Of the routine tasks a clinic does in a week
(confirmations, reminders, replies to patients, bookings and reschedules, dues reminders, notes drafted), the
percentage completed by agents with no staff typing. We measure the baseline (0% today) and set a target per
phase once Phase 2 is live.

## 2. Decisions made (2026-11-21, Sadin)

| Decision | Detail |
|---|---|
| Positioning | Completely agentic and AI-native. This is the selling point, not an add-on. |
| Market | Nepal first, then wider. |
| Specialties | Dental now, one dermatology clinic lined up, others to come. Generic at the core, specific per specialty. |
| Channels | Messaging first (SMS, chat apps, email). The phone agent comes second, on the same agent platform, built inside ClinicMD. A phone agent has been promised to a clinic and stays on the plan. |
| AI providers | Not limited to one. The platform uses the provider that works best for each job. ElevenLabs is the starting point for voice (Sadin has it working in an earlier trial). OpenAI stays for the consultation note until we choose to change it. |
| Design system | Astryx (Meta, MIT licence, v0.7.17, beta). Accepts the upgrade to React 19 and Tailwind 4. |
| Calendar | Keep our custom calendar and port bookX's latest version in steps (section 10). |
| Plan | This brief is the product plan. The earlier five-phase plan is folded into section 12. |

## 3. Where the product is today

**Working and worth keeping:** calendar (4-Day, Day, Unassigned; drag and drop; blocks; staff transfers),
bookings, patients list and patient chart, payments and outstanding dues, packages, payroll, attendance,
performance, reports with daily closing, public booking, ⌘K palette, and the AI consultation (record →
transcript → structured note, piloted at one clinic).

**Gaps that shape this plan:**

| Gap | Evidence |
|---|---|
| The in-app Assistant is a keyword mock; it calls no AI and reads no data | `src/components/ui/AIAssistant/AIAssistantPanel.jsx` |
| All business logic sits in one client file that only the UI can call, so an agent has nothing safe to call | `src/services/api.js` (12,320 lines, 232 functions) |
| No patient messaging at all: no confirmations, no reminders | No scheduled jobs for it; `send-message` supports email only |
| Outreach is email-only, flag-off and half wired (2 of 5 triggers real; nothing schedules the scans) | `supabase/functions/_shared/channels.ts`, Outreach rules editor |
| Dental is in the structure: `dentists`, `chairs`, `dentist_id` in schema; "dentist" about 1,700 times in the UI; dental AI prompts | `supabase/schema.sql`, `src/contexts/OrgContext.jsx` |
| The audit log is never written | `audit_logs` has SELECT policies only, no trigger, no insert |
| No invoices or receipts, no intake or consent forms, no treatment-plan record, no allergies field | Schema; CMD-54, CMD-56 |
| No online payment; no plans, subscriptions or AI credits; no self-serve clinic onboarding | Schema; CMD-60 |
| Not built for phones (staff side) | Calendar and panels are desktop layouts |
| No staging; dev and prod share one database; Free-plan Supabase (no daily backups) | CMD-18, CMD-41, CMD-70 |
| The marketing site advertises a dermatology product and an AI phone receptionist the app does not have | `clinic-md-web/dermatology.html`, `voiceai.html` |

## 4. Users and their problems

| User | What they are trying to do | What goes wrong today |
|---|---|---|
| **Owner** (usually the lead doctor) | Know the clinic is healthy without being there; grow revenue; trust the numbers | Sees patients all day, so reads reports late or never. Cannot tell why revenue moved. With more than one branch, oversight is by phone call. |
| **Manager / admin** | Keep the day full, staff accountable, cash reconciled | Chases confirmations and dues by hand. Reconciles cash and QR payments at closing. Finds no-shows after the slot is lost. |
| **Front desk** | Answer everyone, keep the calendar accurate, collect payment | One person handles walk-ins, the phone, and three chat apps on a personal handset. Messages after hours go unanswered. Recall depends on memory. |
| **Practitioner** | Treat patients, not type | Notes written after hours or not at all. No quick view of the patient's history before they sit down. Treatment explained once and never followed up. |
| **Patient** | Book easily, be reminded, know the cost, be looked after | Has to call during opening hours. Forgets appointments. Hears nothing after a procedure. Unfinished treatment quietly lapses. |

**The money problems behind these** (numbers are vendor or industry figures, mostly US; treat as direction, not fact):
- **Missed contact:** 20–38% of inbound dental calls go unanswered, most misses after hours.
- **No-shows:** reported anywhere from 4% to 30% depending on source and definition.
- **Unfinished treatment:** average case acceptance 34–46% against 75%+ for the best practices.
- **Recall leakage:** about 70% patient retention on average.

**Nepal-specific conditions** (**UNVERIFIED** in detail; to confirm with our clinics):
- Patients message on Messenger, Viber and WhatsApp, and SMS reaches everyone.
- Payments are cash and QR (eSewa, Khalti, Fonepay), not insurance.
- Walk-ins are common.
- Patients write and speak in Nepali, English and romanised Nepali, often mixed.
- Clinics pay far less for software than US practices do.

**We need our own numbers.** Before the first agent goes live we measure, at Bright Smile and the next clinic:
no-show rate, confirmed-before-visit rate, recall return rate, unpaid dues older than 30 days, and how messages
and calls reach the clinic today.

## 5. Competitors and where we win

| Group | Examples | What they do well | Where they fall short for us |
|---|---|---|---|
| AI-first clinic software | Archy (dental, 5 agents), Zenoti (spa/medspa, 12 agents), Dentrix Ascend | Named agents on a shared record; scribe, receptionist, retention, business advisor | US-priced ($400–1,500 per location a month), insurance-centred, English only, no Nepal channels or payments |
| Add-on front-desk agents | Weave, Arini, Peerlogic, Zocdoc Zo, Assort | Answer calls and texts all day, book appointments | Bolt onto another vendor's system; where they cannot write back the agent only creates a request for staff |
| Scribes | Freed, Heidi, Nabla; bundled in Jane, Pabau, Eka | Note from a conversation | Now a $15–40 feature. The note alone is not a differentiator. |
| South Asian clinic software | Practo Ray, HealthPlix, Eka Care, Clinicea | Cheap, prescription-centred, WhatsApp reminders; Eka's scribe handles Indian languages | Little agentic work; India-focused; no Nepal presence found |
| Enterprise AI | Scale (Mayo Clinic) | Evaluation discipline, source-cited output, human confirmation | Sold to health systems with embedded teams; not a clinic product. We copy its discipline, not its product. |

**How we are better, faster, cheaper:**
1. **Agents can do everything staff can do**, because every capability is one shared action and we own the record.
2. **The note starts the next step.** A finished consultation produces the treatment plan, the follow-up
   schedule and the payment request, each as a draft someone approves.
3. **The agents learn each clinic.** They know the clinic's prices, policies and preferences, and improve from
   every correction staff make.
4. **Built for Nepal:** the chat apps patients use, Nepali and mixed-language text and voice, QR payments, walk-ins.
5. **One core, many specialties.** A new specialty is a configuration pack, not a fork.
6. **Trust you can see.** Consent records, an "AI drafted, reviewed by" line, a log of every agent action.
7. **Flat, visible pricing with AI included**, where competitors use quotes, credits and paid add-ons.

## 6. Product principles

These apply to every feature. A design or brief that breaks one needs Sadin's sign-off.

1. **Agents first.** For every routine task we ask "which agent does this, and where does a person step in?"
   before we design a screen for a person to do it by hand.
2. **Every capability is an action.** Nothing changes data except through a named, typed, permission-checked
   action. The UI, the agents, the phone line and the public booking page all call the same actions.
3. **The page works without AI.** If the model is down or the clinic's AI is off, staff can still do the job.
4. **No mock AI.** Nothing in the UI pretends to be intelligent. The current Assistant mock is removed or replaced.
5. **The model translates; code decides.** The model turns language into action requests. Booking rules,
   availability, prices and permissions are enforced by code, checked against the database at the moment of action.
6. **SQL does the maths.** The model never calculates money, counts or rates. It explains numbers the database computed.
7. **Every claim cites its records.** A summary, answer or recommendation links to the bookings, notes,
   payments or clinic facts behind it.
8. **Agents propose; people approve; everything is logged.** Each kind of action has an autonomy level the clinic
   sets (section 7.5). Anything clinical, financial or irreversible needs a person.
9. **No medical advice from agents.** Patient-facing agents handle logistics. Clinical questions go to a person.
10. **Consent first.** No recording, no AI processing and no marketing message without a stored consent.
11. **Per-clinic switch and budget.** AI is off by default, turned on per clinic, and capped by a budget.
12. **Generic core, specialty in packs.** No specialty word or rule is hard-coded in shared code.
13. **Channel-neutral.** An agent's logic does not know whether it is talking by SMS, chat app, email or voice.
14. **Tenant-safe by construction.** Every table, query and action is scoped to the clinic; RLS is the safety net.
15. **Works on a phone.** Staff and owners use phones as much as desktops.

## 7. The foundation: seven pieces

### 7.1 The action layer

This is the base of everything agentic. Today the app's logic is 232 functions in one client file that only
the UI can call. An agent cannot safely use that.

**An action** is one thing the clinic can do: book an appointment, reschedule, cancel, record a payment, send a
message, add a note, create a task. Each action has:
- a name and typed inputs and outputs
- a permission check (who or which agent may run it, in which clinic and branch)
- validation against live data (the slot is still free, the amount matches the due)
- the change itself, on the server
- an audit entry: who or what ran it, with what inputs, on whose approval
- an undo where one is possible

**Who calls actions:** staff through the UI, agents through tools, the phone line, the public booking page, and
later outside systems. All of them get the same rules and the same audit trail.

**How we get there without a rewrite:** actions are introduced one domain at a time, starting with bookings and
messaging (what the first agent needs). Existing screens move onto actions when they are next touched.
From the day the layer exists, no new feature writes data any other way.

### 7.2 Generic core with specialty packs

**The core** uses neutral names everywhere: practitioner, resource (a chair or room), service, patient, visit.
It holds what every clinic needs: scheduling, patient record, clinical note, treatment plan, payments,
packages and memberships, staff, reports.

**Common chart elements for all specialties:** allergies and medical alerts, medications, problem list,
documents and photos, treatment plans, visit notes.

**A specialty pack is configuration, not code:**

| Pack part | Dental | Dermatology / skin | General |
|---|---|---|---|
| Labels | Dentist, Chair, Treatment | Dermatologist, Room, Procedure | Doctor, Room, Service |
| Starter service list | Scaling, filling, root canal… | Consultation, peel, laser session… | Consultation, follow-up… |
| Note template and AI prompts | Dental sections and vocabulary | Skin sections and vocabulary | SOAP note |
| Image types | X-ray, intraoral photo | Skin photo, before/after pairs | Documents |
| Chart module | Tooth chart | Body map and photo timeline | Vitals |
| Intake and consent forms | Dental history, procedure consent | Skin history, procedure and photo consent | General history |
| Agent playbooks | 6-month recall, unfinished plan, post-extraction check | Course-of-sessions reminders, aftercare, review visit | Follow-up visit |
| Starter clinic knowledge | Common dental questions and aftercare | Common skin questions and aftercare | General questions |

A clinic picks a pack at onboarding and can edit any part of it. Chart modules (tooth chart, body map) are the
only parts that need code, and they plug into a fixed slot in the chart.

**Schema:** move to neutral table and column names (for example `dentists` → `practitioners`, `chairs` →
`resources`, `treatments` → `services`). This is a hand-applied production migration, so it gets its own brief,
rollback and rehearsal. It is done together with the calendar port so the code is renamed once.

### 7.3 One patient timeline

Every event about a patient lands in one ordered stream: bookings, visits, notes, images, messages in and out,
calls, payments, dues, consents, agent actions. Staff see it in the chart. Agents read it as their context.
This is what makes "full context" real, and it is the main structural thing add-on agents lack.

### 7.4 One communication hub, channel-neutral

- **One inbox** for every conversation with a patient, across channels, linked to the patient record. Staff and
  agents work in the same threads; a person can take over from an agent at any point.
- **Channel adapters** behind one interface: SMS, WhatsApp, Viber, Messenger, email and **voice**. A voice call
  is a conversation like any other: it has a transcript in the thread, the same agent logic, the same actions
  and the same hand-off to a person.
- **Voice runs inside ClinicMD**, not as a separate tool. Speech-to-text, the agent, and text-to-speech are
  parts of the voice adapter, so each can be swapped for whichever provider handles Nepali best. ElevenLabs is
  the starting point. The telephony provider and Nepali quality are open (section 13).
- **Templates** per clinic, per language, per channel, with the variables filled by code.
- **Consent and opt-out** per patient per channel, checked before every send or call. Quiet hours per clinic.
- **Delivery tracking** (sent, delivered, read, failed, replied; call answered, completed, handed off) and cost
  per message and per call minute.
- **Fallback order** per clinic, for example chat app first, SMS if not delivered, call if not answered.

### 7.5 The agent platform

Every agent is built from the same parts:

1. **Event:** something happens or a time arrives (booking created, visit completed, no reply in 24 hours, due older than 14 days, patient message or call received).
2. **Playbook:** the clinic's rule for that event: which agent, what goal, which channel, what autonomy level.
3. **Context:** the patient timeline, the clinic brain and the clinic's settings, limited to what the task needs.
4. **Draft:** the agent proposes one or more actions (7.1).
5. **Check:** the action's own validation runs against rules and live data.
6. **Approval:** by autonomy level. Approval items appear in the **work queue** on the home screen (section 8).
7. **Action and log:** the action runs and is recorded with the model, the inputs and the approver.
8. **Outcome:** what happened next (confirmed, rebooked, paid, no reply) is tracked against the playbook and the agent's scorecard.

**Autonomy levels** (set per playbook by the clinic):

| Level | Meaning | Typical use |
|---|---|---|
| 1 Draft | Agent prepares; a person approves | New playbooks, sensitive messages, anything clinical or financial |
| 2 Auto by rule | Agent acts without approval using fixed templates and rules | Confirmations, reminders, review requests |
| 3 Conversational | Agent holds a conversation within a set scope and hands off outside it | Booking and rescheduling by chat or phone |

A clinic starts low and raises the level as it sees the agent's scorecard. The product suggests raising it when
an agent's drafts have been approved unchanged for long enough.

**The learning loop:**
- Every approval, edit and rejection of an agent's draft is recorded, with the reason when staff give one.
- Repeated edits become proposed preferences for that clinic ("always say 'Dr. Sharma', never 'the dentist'"),
  which staff accept into the clinic brain.
- Rejected and corrected outputs join that agent's test set.
- Learning stays inside the clinic. One clinic's patient data never trains or informs another clinic's agents.

**Quality:** each agent has a test set of real-shaped conversations that must pass before any prompt, model or
provider change ships. A sample of live conversations is reviewed each week.

**Model access:** one model client with a provider per job (text, transcription, vision, speech), so a provider
can change without touching any agent.

### 7.6 The clinic brain

Agents are only as good as what they know about the clinic. The clinic brain is the clinic's own knowledge,
kept in one place that staff can read and correct.

- **Facts:** hours, location and directions, price list (from the service list), payment options, cancellation
  and deposit policy, what each service involves, preparation and aftercare instructions, common questions.
- **Preferences:** tone, languages, how each practitioner likes notes written, who handles which kind of hand-off.
- **Where it comes from:** the specialty pack's starter content, the clinic's settings, documents staff upload,
  and teaching. When an agent does not know an answer it asks staff, and the answer is saved once approved.
- **Rules:** every entry has an owner and a date. Agents cite the entry they used. Clinical content is approved
  by a practitioner before any agent may send it.

### 7.7 The trust layer

- **Consent ledger:** recording consent per consultation (CMD-54), messaging and call consent per channel, photo consent.
- **Provenance:** every AI-drafted note stores the model, the time and the reviewer, and shows "AI drafted,
  reviewed by …" (CMD-55).
- **Audit log that is actually written:** by the action layer for every action, by whoever ran it.
- **Disclosure:** a patient talking to an agent is told it is an AI assistant and can ask for a person.
- **Data minimisation:** agents get only the fields a task needs. Private staff notes never go to a model.
- **Legal:** privacy notice naming the AI providers, clinic terms, and a Nepali lawyer's review before AI opens
  to more clinics (CMD-59). Rules for automated calls and bulk messages in Nepal are **UNVERIFIED** and need
  local counsel before any agent messages or calls patients.

## 8. Home is the work

The home screen is not a dashboard of charts. It shows the clinic's work, per role:

| Section | What it shows |
|---|---|
| **Needs you** | Approvals waiting, conversations handed off by an agent, exceptions (a failed payment, a double booking, a patient who asked for a person) |
| **Done by agents** | What agents did since you last looked, with the outcome and an undo where possible |
| **Today** | The schedule, who is waiting, the few numbers that matter for this role |
| **Ask or tell** | The Staff copilot: ask a question or give an instruction from anywhere (also ⌘K) |

Every other screen carries the same idea: the copilot knows which page and which patient you are on, and
agent activity appears where it happened (in the booking, in the patient timeline, in the inbox thread).

## 9. The agents

All agents share the platform in 7.5 and are judged by a scorecard the clinic can see.

| Agent | Works for | What it does | Default level | Scorecard |
|---|---|---|---|---|
| **Follow-up** | Front desk, patients | Booking confirmation; reminders; "reply to confirm"; no-show recovery; recall when due; unfinished treatment plan nudges; aftercare check-in; review request; birthday and package-expiry messages | 2 for confirmations and reminders, 1 for the rest | Confirmed-before-visit rate; no-show rate; recalls rebooked; unfinished plans restarted |
| **Front desk** | Patients, front desk | Answers patient messages and calls: book, reschedule, cancel, hours, location, prices, preparation instructions. Hands off anything else with a summary. | 1 at first, then 3 for booking | Conversations closed without staff; reply time; bookings made after hours; hand-off rate |
| **Scribe** | Practitioners | Record → transcript → note, plus image analysis. Pre-visit summary of the patient's history. After sign-off, drafts the treatment plan, follow-up schedule and a patient-friendly summary. | Always 1 (practitioner signs) | Notes signed same day; share of the draft kept unedited; visits with a follow-up scheduled |
| **Collections** | Manager | Dues reminders by age of debt; payment links (eSewa, Khalti, Fonepay); receipts; flags disputes to a person | 1, then 2 for first reminders | Dues older than 30 days; days to collect; amount recovered |
| **Owner's advisor** | Owner, manager | Morning briefing per clinic and across branches: what changed, why, what to do, who should do it. Answers questions about the clinic's data with cited records. Flags unusual things (discount spikes, empty days, a no-show cluster). | Read-only; proposes tasks | Briefings opened; proposed tasks accepted and completed |
| **Staff copilot** | All staff | Do a task by asking ("move Sita to Thursday 3pm"), find anything, explain how to do something, guide a new clinic through setup and a new staff member through their first week | 1: shows the action for confirmation | Tasks completed through the copilot; setup time for a new clinic |

**The product-level number** is agent-handled share (section 1), built from these scorecards.

**Later agents** (not in this plan's phases): inventory and reorder, staff scheduling, marketing campaigns, lead
manager for aesthetic clinics.

## 10. Feature map

Status: **Keep** (works), **Extend**, **New**, **Fix**, **Replace**.

| Area | Feature | Status |
|---|---|---|
| **Home** | "Home is the work": needs you, done by agents, today, ask or tell | Replace (today's dashboard charts move to Reports) |
| **Calendar** | Day, 4-Day, Unassigned, blocks, transfers | Keep |
| | Week and Month views, phone layout, filters, zoom, shared pickers, Assign flow | New (port from bookX) |
| | Availability shading and guard, waitlist, walk-ins | New (port from bookX, needs schema) |
| | Recurring appointments and multi-visit treatment plans on the calendar | New |
| **Bookings** | Create, reschedule, status, discounts with approval, collect payment | Keep, moved onto actions |
| | Public booking flow | Fix (spa copy, step counter, CMD-66), then pack-aware |
| **Patients** | Directory, duplicate merge, chart, visits | Keep |
| | Edit patient details (CMD-65), allergies and alerts (CMD-56) | Fix |
| | Patient timeline, treatment plans, documents and photos, intake and consent forms | New |
| | Specialty chart modules (tooth chart, body map and photo timeline) | New |
| **Inbox** | One inbox across channels including call transcripts, templates, consent and opt-out, delivery tracking | New |
| **Agents** | Playbooks, autonomy settings, scorecards, activity log, budgets | New |
| | Clinic brain: facts, preferences, teaching, approvals | New |
| | Outreach module | Replace (its rules, templates and review queue become playbooks, templates and the work queue) |
| **Consultation** | Record, transcript, structured note, image analysis, phone recording | Keep (finish pilot: CMD-52, CMD-53) |
| | Consent stored, provenance stored, pack-specific prompts, pre-visit summary, note → plan → follow-up | New |
| **Money** | Payments, dues, packages, daily closing | Keep, moved onto actions |
| | Invoices and receipts with VAT, payment links and QR reconciliation | New |
| | Memberships, vouchers, referrals | Decide: ship or remove (CMD-14, CMD-13) |
| **People** | Practitioners, attendance, payroll, performance | Keep (rename to generic) |
| | Shifts and availability | New (comes with the calendar port) |
| **Reports** | Sales, team and patient reports, Excel export | Keep |
| | Briefings and "ask a question" from the Owner's advisor; agent scorecards; agent-handled share | New |
| **Assistant** | ⌘K find and simple actions | Keep |
| | Assistant panel | Replace the mock with the Staff copilot |
| **Settings** | Master data, payment methods | Keep |
| | Specialty pack editor, channels and voice, roles, working audit log | New |
| **Platform** | Revenue-share admin | Keep |
| | Clinic onboarding, plans, AI, message and call usage, billing | New |
| **Patient side** | Booking, account, history | Keep |
| | Confirm, reschedule, pay and fill forms from a message link | New |

## 11. Calendar and design system

### Calendar

The calendar began in ClinicMD and was copied to bookX in October 2026; bookX has since made 77 calendar
commits (its latest is on bookX `stage`, not yet in bookX production). It cannot be cherry-picked because every
name differs. We port it:

1. **Step 1, little or no schema:** phone layout, Week and Month views, filters, zoom, shared pickers, Assign flow.
2. **Step 2:** availability shading and the "Book anyway" guard (needs shifts tables).
3. **Step 3:** waitlist and walk-ins.
4. **Not ported:** couple, combo and group bookings, unless a clinic asks. The combo "steps" idea is the likely
   base for multi-visit treatment plans.

ClinicMD's two additions (patient alerts in the hover card, link to the chart) are re-applied. bookX migrations
are rewritten for our tables, each with a rollback.

### Design system

- **Astryx** for the app shell, navigation, tables, forms, date inputs, overlays, command palette and chat UI.
  MIT licence (checked on the repo, 2026-11-21). It is beta (v0.7.17), so we pin versions and expect breaking changes.
- **Required first:** React 18 → 19 and Tailwind 3 → 4, and StyleX in the build. **UNVERIFIED:** that Astryx
  works in a plain-JSX Vite app; a one-day spike proves this before anything else is built on it.
- **Not in Astryx:** an appointment scheduler (our calendar stays custom, restyled with Astryx tokens) and
  charts (keep Recharts, themed with Astryx data colours).
- **Migration is module by module, not one big rewrite:** new shell and home first, new screens in Astryx,
  existing screens moved when they are next touched. The old `spa-*` classes are removed as each screen moves.
- **Layout references from Scale's healthcare page:** patient header with record tabs; a review card showing the
  AI's reasoning with sources; clear accept / edit / reject controls; large single-number stat callouts.
- **Design direction** (theme, density, colour, type, tone) is a separate document, `docs/DESIGN-DIRECTION.md`
  (CMD-72), written after this brief is agreed.

## 12. Phases

Every phase has an exit test. Dates are set by Sadin before a phase starts; no phase starts without one.
The next dental clinic onboards on the current product; it does not wait for any phase.

The order puts the agent foundation first and gets a working agent into a clinic early, before the larger
rebuild of the shell and the core.

| Phase | What | Tickets so far | Done when | Date |
|---|---|---|---|---|
| **0 Safety basics** | Branch protection, repo visibility, Supabase plan and backups, which migrations are in prod, flag mismatch | CMD-42, 71, 70, 11, 13 | `main` is protected, the decisions are recorded, prod migration status is known | to set |
| **1 Finish the AI pilot** (alongside 0 and D) | Image analysis and phone recording verified; consent and provenance stored | CMD-52, 53, 54, 55 | Bright Smile runs a full consultation (audio, image, phone), and consent and the "AI drafted, reviewed by" line survive a reload | to set |
| **D Design** (alongside 0 and 1) | Sitemap, user journeys, design direction, then mockups of every screen in phases 2–5 on a design canvas | CMD-72, new tickets | Sadin has approved boards for every screen in phases 2–5 | to set |
| **2 Agent foundation and the first agent** | Staging; action layer for bookings and messaging; agent platform; communication hub with SMS and one chat app; clinic brain v1; audit log written; legal check for messaging; Follow-up agent (confirmations, reminders, reply to confirm) in the current app; a voice spike that proves the hub is channel-neutral | CMD-18, 41, 59, new tickets | For two weeks at one clinic, confirmations and reminders go out automatically through actions, replies land in the inbox, every send is logged with consent, the no-show and confirmation rates are reported against the baseline, and a test call runs through the same agent | to set |
| **3 New shell and generic core** | React 19, Tailwind 4, Astryx shell; "Home is the work"; generic core and schema rename; specialty packs (dental, dermatology); calendar port step 1; security items | CMD-58, 15, 20, 43, 62, 63, 44, new tickets | A dermatology clinic can be created with its own labels, note template, AI prompts and playbooks with no code change; staff start their day from the new home | to set |
| **4 The real assistant** | Staff copilot replaces the mock (needs actions across all main domains); Owner's advisor with morning briefing and cited answers; learning loop | new tickets | The mock is gone; the copilot passes its test set; one owner receives the briefing daily for two weeks | to set |
| **5 Front desk and Collections** | Chat booking agent with hand-off; no-show recovery and recall; invoices and receipts; payment links; dues reminders; remaining chat apps | new tickets | A patient books and reschedules by chat with no staff involvement, pays from a link, and the payment reconciles in daily closing | to set |
| **6 Phone agent** | Inbound and outbound calls through the voice channel, in Nepali and English | new tickets | The promised clinic's after-hours calls are answered and booked by the agent, with transcripts in the inbox, consent, disclosure and hand-off working | to set |
| **7 Plans and billing** | Plans, AI, message and call usage, credits, clinic billing, self-serve onboarding | CMD-60, 61, new tickets | A new clinic signs up, picks a pack and a plan, and pays without our help | to set |

**Pricing runs earlier than Phase 7:** pricing is checked with 2–3 clinics during phases 2–3, and clinics are
invoiced by hand until Phase 7 is built.

**The phone agent can move earlier.** Because voice is a channel on the same platform and is proven by the
spike in Phase 2, Phase 6 can be pulled forward if the promised clinic needs it and Nepali voice quality is good enough.

**Alongside the phases:** CMD-65 (edit patient), CMD-66 (booking copy), CMD-56 (allergies), CMD-68.

## 13. Open questions and risks

**Questions for Sadin**

| # | Question | Needed by |
|---|---|---|
| 1 | Which chat app first after SMS: WhatsApp, Viber or Messenger? Recommendation: ask the two clinics what their patients use, then pick one. | Phase 2 |
| 2 | Who builds? One builder session at a time, or developers in parallel? This sets the dates. | Before dates |
| 3 | What is promised to the clinic waiting for the phone agent, and by when? | Before dates |
| 4 | Where is the earlier ElevenLabs voice trial (repo or account), so the voice spike starts from it? | Phase 2 |
| 5 | Memberships, vouchers, referrals: ship or remove? (CMD-14) | Phase 3 |
| 6 | Pricing shape: flat per branch with AI included, or base plus usage? (CMD-61) | Phase 3 |

**Risks**

| Risk | What we do about it |
|---|---|
| Moving logic from one client file to server-side actions is a large change to working code | One domain at a time, starting with bookings and messaging; old paths stay until each screen moves; tests per action |
| Astryx is beta and needs two framework upgrades | One-day spike first; pin versions; module-by-module migration |
| The schema rename is a hand-applied production change | Own brief, rollback, rehearsal on a prod-schema copy; staging exists first (Phase 2) |
| Nepali and mixed-language quality for chat, and especially for voice, is unproven | Test with real patient messages before the first agent goes live; voice test in the Phase 2 spike before Phase 6 is dated |
| Nepal rules for bulk messages and automated calls are unclear | Local counsel (CMD-59 scope extended); start with service messages to consenting patients only |
| Chat-app business accounts and phone numbers need approval per clinic and can be slow | Start the first clinic's applications at the start of Phase 2 |
| Message, call and AI costs at Nepal prices | Cost per message, call minute and agent action tracked from day one; budgets per clinic |
| AI notes contain errors (one 2026 study: omissions in 18% of notes, hallucinations in 11.5%) | Practitioner sign-off is mandatory; provenance stored; errors feed the test set |
| An agent says or does something wrong to a patient | Autonomy starts at level 1; scope limits; disclosure and hand-off; weekly review of live conversations |
| The plan is large for a small team | Each phase is useful alone; nothing in a later phase blocks an earlier one |

## 14. Not in this plan

Insurance and claims · lab orders · e-prescriptions · inventory · telehealth · hospital or inpatient features ·
AI diagnosis from images (analysis stays advisory, signed off by the practitioner) · countries other than Nepal.

## 15. Sources

Research done 2026-11-21. Current product: read of `main @ 6a7b980`. Calendar: bookX `origin/stage @ 58db162`.

- Scale: `scale.com/enterprise/healthcare`, `scale.com/blog/mayo-clinic-scale`, `scale.com/genai-platform`
- Astryx: `astryx.atmeta.com` (docs, components, themes), `github.com/meta/astryx` (MIT, v0.7.17)
- Agent architecture: Zocdoc engineering post on Zo, `zocdoc.com/techblog/what-zo-taught-us-about-operationalizing-genai-at-zocdoc/`
- Competitors: Zenoti AI guide (`zenoti.com/thecheckin/ai-for-medspas-complete-guide`), Archy Series C (Becker's Dental),
  Weave AI Receptionist, Arini (Capterra), Pabau Scribe, Jane pricing, Practo Ray, Eka Care
- Problem numbers: Dental Economics on missed calls; Henry Schein One 2026 Catalyst Index and case-acceptance figures
- Scribe accuracy: UC Davis pilot, JMIR Medical Informatics 2026 (`medinform.jmir.org/2026/1/e86474`)
- Nepal: Individual Privacy Act 2075 (2018); Messenger and Viber usage reports (NapoleonCat, Nepali Telecom)
