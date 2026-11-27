# ClinicMD User Journeys

**Status:** draft for owner review · **Ticket:** CMD-75 · **Written:** 2026-11-21 by the lead session
**Follows:** `docs/PRODUCT-BRIEF.md` (v2) and `docs/SITEMAP.md`. If they disagree, the brief wins.
**Used by:** the design direction (CMD-72) and the mockups. Each journey step that has a screen needs a board.

> These are **target** journeys. Almost none of the agent steps exist today.
> "Phase" is the phase in the brief (section 12) where the journey first works end to end.
> Names and details in the examples are made up.

**Who acts, in every table:**
- **Agent**: an agent does it with no person involved.
- **Agent → Person**: an agent prepares it; a person approves, edits or rejects.
- **Person**: a person does it. The copilot may help, but the person decides.
- **System**: ordinary code, no AI (a rule, a timer, a check).

---

## 1. The patient's path (the spine)

Everything else hangs off this path. One patient, from first contact to coming back.

### 1.1 Booking by message · Phase 5

Sita messages the clinic on a chat app at 9pm asking for a cleaning this week.

| # | Who acts | What happens | Where staff see it |
|---|---|---|---|
| 1 | System | The message arrives and is matched to Sita's record by phone number (or a new patient is started) | Inbox |
| 2 | Agent | Front desk agent tells her it is the clinic's AI assistant, asks what she needs and when | Inbox thread |
| 3 | System | Availability is read from the live calendar, with the clinic's booking rules | n/a |
| 4 | Agent | Offers two or three real slots; Sita picks one | Inbox thread |
| 5 | System | The **book appointment** action runs: checks the slot is still free, creates the booking, logs it | Calendar; Agents → Activity |
| 6 | Agent | Confirms the time, practitioner, price from the clinic brain, and how to get there | Inbox thread |
| 7 | System | Next morning the booking appears under **Done by agents** | Home |

**If the agent is at level 1** (the clinic's starting point): step 5 becomes **Agent → Person**. The proposed
booking waits under **Needs you**, front desk approves it, and the agent then confirms to Sita.

### 1.2 Confirmation and reminders · Phase 2

This is the first journey we ship, and it works for bookings made any way (by staff, online, or by an agent).

| # | Who acts | What happens | Where staff see it |
|---|---|---|---|
| 1 | System | A booking is created; the Follow-up playbook "confirmation" fires | n/a |
| 2 | System | Consent and quiet hours are checked for Sita's preferred channel | n/a |
| 3 | Agent | Sends the confirmation from the clinic's template, in her language | Booking panel; Inbox |
| 4 | Agent | The day before, sends a reminder asking her to reply to confirm (or tap a link) | Inbox |
| 5a | System | Sita confirms: the booking is marked confirmed | Calendar shows confirmed |
| 5b | Agent | Sita asks to move it: the agent offers slots and reschedules (Phase 5), or hands off to front desk (Phase 2) | Inbox: needs a person |
| 5c | System | No reply by the cut-off: the booking is flagged "not confirmed" | Home → Needs you |
| 6 | Person | Front desk decides what to do with unconfirmed bookings (call, keep, release the slot) | Home; Calendar |

### 1.3 The visit · Phases 1 and 4

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Agent | Before the visit, sends the intake form and consent to fill on her phone (Phase 3) | Patient link page |
| 2 | Person | Sita arrives; front desk checks her in | Calendar |
| 3 | Agent | Scribe prepares a pre-visit summary: last visits, open treatment plan, allergies, dues, recent messages, each linked to its record (Phase 4) | Consultation |
| 4 | Person | The practitioner asks for recording consent; it is stored (Phase 1) | Consultation |
| 5 | Agent → Person | Scribe records, transcribes and drafts the structured note; the practitioner edits and signs. "AI drafted, reviewed by Dr. …" is stored. | Consultation |
| 6 | Agent → Person | After sign-off, Scribe drafts the treatment plan, the follow-up schedule and a plain-language summary for the patient; the practitioner approves each (Phase 4) | Consultation; Patient → Treatment plans |
| 7 | Person | Front desk takes payment | Booking panel; Money |
| 8 | Agent | Sends the visit summary and aftercare instructions (approved content from the clinic brain) | Patient link page; Inbox |

### 1.4 After the visit · Phases 2 to 5

| # | Who acts | What happens | Where staff see it |
|---|---|---|---|
| 1 | Agent | Two days later, an aftercare check-in: "How are you feeling after the extraction?" | Inbox |
| 2a | Agent | "Fine, thank you": the agent closes the thread and asks for a review (if the clinic has this playbook on) | Done by agents |
| 2b | Agent → Person | "It is still bleeding": this is clinical. The agent does not advise. It tells Sita a person will contact her and hands off as urgent with a summary. | Home → Needs you (urgent); Inbox |
| 3 | Agent | She has an unfinished treatment plan: after the clinic's set interval, a nudge to book the next step | Inbox; Patient → Treatment plans |
| 4 | Agent | Six months on, a recall message offering slots | Inbox |
| 5 | Agent → Person | She has an unpaid balance: Collections drafts a reminder with a payment link; the manager approves the first ones | Home → Needs you; Money → Outstanding |
| 6 | System | Sita pays from the link; the payment is recorded and appears in daily closing | Money |

### 1.5 Calling the clinic after hours · Phase 6

| # | Who acts | What happens | Where staff see it |
|---|---|---|---|
| 1 | Agent | The call is answered: "This is the clinic's AI assistant. The call is recorded. How can I help?" in Nepali or English | n/a |
| 2 | Agent | Same Front desk agent, same actions as by message: books, reschedules, answers hours, location and prices | Calendar; Activity |
| 3 | Agent → Person | Anything outside its scope, or if the caller asks for a person: takes a message and hands off | Home → Needs you |
| 4 | System | The transcript and recording are in Sita's thread next to her messages | Inbox; Patient → Timeline |

## 2. Front desk

### 2.1 Start of the day · Phase 3 (a simpler version in Phase 2)

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Person | Opens Home | Home |
| 2 | System | **Done by agents** shows the night: 4 bookings made, 11 confirmations received, 2 reschedules | Home |
| 3 | Person | Works **Needs you**: 3 bookings not confirmed, 1 conversation handed off, 1 payment that failed | Home → Inbox / Calendar |
| 4 | Person | Checks **Today**: the schedule, who is new, who owes money, who has alerts | Home → Calendar |

### 2.2 Taking over a conversation · Phase 2

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Agent | Cannot help (the patient wants a discount) and hands off with a two-line summary | Inbox: needs a person |
| 2 | Person | Opens the thread, sees the summary and the patient's details beside it, takes over | Inbox thread |
| 3 | Person | Replies, and books or takes payment from the side of the thread | Inbox thread |
| 4 | Person | Hands the thread back to the agent, or closes it | Inbox thread |

### 2.3 Teaching the clinic brain · Phase 2

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Agent | A patient asks "Do you do braces for children?" and the clinic brain has no answer. The agent says it will check and get back. | Inbox |
| 2 | System | The question goes to the teaching queue | Agents → Clinic brain |
| 3 | Person | Front desk answers. If the answer is clinical, a practitioner approves it. | Agents → Clinic brain |
| 4 | Agent | Sends the answer to the patient and uses it from now on, citing that entry | Inbox |

### 2.4 Doing a task by asking · Phase 4

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Person | Types or says: "Move Sita to Thursday at 3 with Dr. Sharma" | Ask or tell (⌘K) |
| 2 | Agent → Person | The copilot shows the exact change it will make, and any conflict | Copilot panel |
| 3 | Person | Confirms | Copilot panel |
| 4 | System | The reschedule action runs; the Follow-up agent tells Sita | Calendar; Inbox |

### 2.5 A walk-in · after Phase 3

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Person | Adds a walk-in from the calendar; the system shows who is free now | Calendar |
| 2 | System | A patient record is created or matched | Patients |
| 3 | Agent | After the visit the patient is on the same follow-up path as anyone else, once consent is recorded | Inbox |

## 3. Practitioner

### 3.1 A day of consultations · Phases 1 and 4

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Person | Opens Home on the phone: today's patients in order | Home |
| 2 | Agent | Each patient has a pre-visit summary ready | Consultation |
| 3 | Person | Taps record on the phone when the consultation starts | Practitioner phone |
| 4 | Agent → Person | Reviews and signs the drafted note between patients | Consultation |
| 5 | Agent → Person | Approves the drafted plan and follow-up | Consultation |
| 6 | Person | End of day: **Needs you** shows any notes still unsigned | Home |

### 3.2 A clinical question from a patient · Phase 2 onward

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Agent | Recognises a clinical question, does not answer it, hands off to the practitioner who saw the patient | Home → Needs you |
| 2 | Person | The practitioner reads the summary and the patient's timeline, and replies or asks front desk to book a visit | Inbox thread |

### 3.3 The agent learns the practitioner's style · Phase 4

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | System | Dr. Sharma has changed "pt" to "patient" in ten notes | n/a |
| 2 | Agent → Person | A proposed preference appears: "Write 'patient' in full for Dr. Sharma" | Agents → Clinic brain → Teaching queue |
| 3 | Person | Dr. Sharma accepts it; later notes follow it | Agents → Clinic brain |

## 4. Manager

### 4.1 Running the agents · Phase 2

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Person | Opens Agents and reads each agent's scorecard for the week | Agents overview |
| 2 | Person | Opens the Follow-up agent and reviews the reminder playbook: timing, template, channel order | Agent page → Playbook editor |
| 3 | Person | Previews the message on a real patient, then turns the playbook on at level 1 | Playbook editor |
| 4 | Agent → Person | For the first weeks, approves the agent's drafts in the work queue | Home → Needs you |
| 5 | System | After enough drafts are approved unchanged, the product suggests moving to level 2 | Agent page |
| 6 | Person | The manager (or owner) raises the level | Agent page |

### 4.2 Recovering a no-show · Phase 5

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | System | A patient does not arrive; the booking is marked no-show | Calendar |
| 2 | Agent | Sends a polite message offering to rebook | Inbox |
| 3 | Agent | Offers the freed slot to the first matching patient on the waitlist (after the waitlist is ported) | Inbox; Calendar |
| 4 | System | Rebooked or not, the outcome counts on the Follow-up scorecard | Agents |

### 4.3 Collecting dues · Phase 5

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Person | Opens Outstanding: dues by age, and what the Collections agent has done for each | Money → Outstanding |
| 2 | Agent → Person | Approves this week's batch of reminders (first ones only; later reminders for the same due follow the rule) | Home → Needs you |
| 3 | Agent | Sends each reminder with a payment link | Inbox |
| 4 | Agent → Person | A patient disputes the amount: the agent stops and hands off | Home → Needs you |
| 5 | Person | End of day: daily closing shows cash, QR and link payments reconciled | Money → Daily closing |

### 4.4 Undoing something an agent did · Phase 2

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Person | Sees a booking the agent made at the wrong branch | Home → Done by agents |
| 2 | Person | Opens the action: what the agent was asked, what it did, and why | Agents → Activity |
| 3 | Person | Chooses undo; the booking is cancelled and the patient is told | Activity |
| 4 | Person | Marks the action as wrong, with a reason. It joins the agent's test set. | Activity |

## 5. Owner

### 5.1 The morning briefing · Phase 4

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Agent | At a set time, the Owner's advisor sends a short briefing: what changed, why, what to do, who should do it. Numbers come from the database; each item links to its records. | Phone notification; Reports → Briefings |
| 2 | Person | Reads it in two minutes. Example item: "Thursday is 40% empty at the Lalitpur branch. 12 patients are due for recall there. Send recall messages?" | Briefings |
| 3 | Person | Taps "do it": a task is created for the Follow-up agent or a person | Home (theirs) |
| 4 | System | Tomorrow's briefing reports what happened | Briefings |

### 5.2 Asking a question · Phase 4

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Person | Asks: "Why was revenue down last week?" | Reports → Ask |
| 2 | Agent | Answers from computed numbers (fewer visits on two days, one practitioner on leave, higher discounts), each with a link to the report or bookings behind it | Ask |
| 3 | Person | Follows a link to check, or asks a follow-up | Reports |

### 5.3 Overseeing several branches · Phase 4

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Person | Switches to all branches | Branch switcher |
| 2 | System | Home shows what needs the owner across branches, and each branch's agent-handled share | Home |
| 3 | Agent | Flags unusual things: a discount spike at one branch, a cluster of no-shows for one practitioner | Briefings; Home |

### 5.4 Deciding how much the agents may do · Phase 2

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Person | Turns AI on for the clinic and reads which providers are used and what data they receive | Settings → AI and privacy |
| 2 | Person | Sets the monthly budget | Agents → Usage and budget |
| 3 | Person | Chooses which agents are on and the highest autonomy level each may reach | Agents overview |
| 4 | System | At 80% of the budget the owner is warned; patient care is never blocked | Home |

## 6. Setting up a new clinic · Phase 3 (done by us), Phase 7 (self-serve)

A dermatology clinic joins.

| # | Who acts | What happens | Where |
|---|---|---|---|
| 1 | Person (us, later the clinic) | Creates the clinic and picks the dermatology pack | Platform → Clinics; Setup |
| 2 | System | Labels, starter services, note template, forms, playbooks and starter knowledge are loaded from the pack | n/a |
| 3 | Agent → Person | The copilot walks the owner through: branches and hours, services and prices, team | Setup |
| 4 | Person | Connects channels: SMS sender, a chat app account, later a phone number | Settings → Channels |
| 5 | Agent → Person | The copilot asks the questions agents will need answered (cancellation policy, payment options, directions) and saves the answers | Agents → Clinic brain |
| 6 | Person | Imports patients (a file) and checks the result | Patients |
| 7 | Person | Turns on the confirmation and reminder playbooks at level 1 | Agents |
| 8 | System | The setup checklist on Home shows what is left | Home |

## 7. When things do not go to plan

These are as important as the main paths, and each needs a board.

| Situation | What happens | Who acts |
|---|---|---|
| The agent does not know the answer | It says so, promises a reply, and sends the question to the teaching queue (2.3) | Agent → Person |
| A clinical question or a symptom | The agent never advises. It hands off, marked urgent when the words suggest it (1.4, 3.2). | Agent → Person |
| The patient asks for a person | Immediate hand-off with a summary; the patient is told when to expect a reply | Agent → Person |
| The patient writes in mixed Nepali and English, or in a language the agent handles badly | The agent replies in the patient's language where it can; when unsure of the meaning it hands off and does not guess | Agent → Person |
| The slot was taken between the offer and the booking | The action's check fails; the agent apologises and offers other slots | System, Agent |
| The patient has not consented, or has opted out of a channel | Nothing is sent on that channel. The task shows as "blocked: no consent" for staff. | System |
| A message fails to deliver | The next channel in the clinic's fallback order is tried; if all fail, it goes to **Needs you** | System |
| AI is switched off, over budget, or the provider is down | Every screen still works by hand. Fixed-template reminders still send. Conversations wait for a person. A banner says agents are paused. | System |
| An agent did the wrong thing | Undo, mark as wrong with a reason, and it joins the test set (4.4) | Person |
| An agent keeps being corrected | Its autonomy level is lowered automatically for that playbook and the manager is told | System |
| A patient is angry or distressed | The agent stops selling or reminding, hands off as urgent, and pauses that patient's other playbooks | Agent → Person |

## 8. What the journeys ask of the design

- **Three screens carry the product:** Home, the Inbox thread, and the agent page. They come first in the mockups.
- **One approval pattern everywhere:** what the agent proposes, why, the records it used, and approve / edit /
  reject. The same card appears on Home, in the Inbox, in the consultation and in the copilot.
- **It is always clear who is acting:** every message, booking and note shows whether an agent or a person did
  it, and who approved it.
- **Agent activity lives where the work is:** in the booking, the thread and the patient timeline, not only on
  an agents screen.
- **Phone first for the owner and the practitioner;** desktop first for front desk and manager, and usable on a phone.
