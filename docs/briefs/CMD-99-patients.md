# Brief: Patients (list, record, forms) · CMD-99

**Status:** boards approved by Sadin 2026-11-23 (final) · **Phase:** 3 (parts in 5, see §2) · **Epic:** CMD-80 · **Lead:** lead session
**Boards:** canvas "ClinicMD Mockups" v44 → page **13 Patients** (https://claude.ai/artifact/DDYuBuT3fvosAvUBBzRtmz#page-patients).
42 boards in 7 rows: list front desk (6), list other roles (6), record practitioner (6), record front desk / manager /
read-only (6), record states (5), forms (8), phone (5). Each board title ends with its phase and "new" or "changes".
**Follows:** `docs/PRODUCT-BRIEF.md` §2 (the eight Patients decisions of 2026-11-22), `docs/SITEMAP.md` §3.4,
`docs/DESIGN-DIRECTION.md` (§6 phone, §11 mockups are final). If the boards and this brief disagree, ask the lead; do not choose.

**Build only from the boards.** They are the final design: copy, spacing, colours, order, every state and role. The builder
makes no design decisions. Sample data on the boards (Suman Khadka, P-01287, "now" = Tue 24 Nov 11:20 am) is for the
seed script, not for the code.

**Nothing that exists today is lost.** The current CRM list (segments, search, filters, sort, columns, CSV, preview with
↑ ↓, duplicates and merge) and the current record (prev/next with J/K, overview, visits with the full visit record,
clinical notes with PDF, X-rays and photos with a viewer, billing) all reappear on the boards, regrouped. Before deleting
any current screen, list each feature it has and point to the board that carries it (put the list in the PR).

## 1. Before this can start (blockers)

| Blocker | Why |
|---|---|
| CMD-77 Astryx spike accepted, CMD-82 React 19 + Tailwind 4 merged | Every part below is an Astryx component |
| CMD-79 practitioner access (011, PR #15) | Practitioner row, "My patients", clinical vs front desk access |
| CMD-78 action layer (012, PR #16) | Every write below is an action with an audit entry, not a direct table write |
| CMD-88 communication hub (013) and CMD-93 consent at booking (015) | Messages on the timeline, consent per channel, bulk notices |
| CMD-90 agent platform (016) and CMD-95 Follow-up agent (017) | Agent activity, hand-off card, "Agents paused" |
| Sadin's order of work (PRODUCT-BRIEF §12) | All phase 2-5 mockups are finished before phase builds start. Until the lead says go, only the groundwork in §2 Part 0 may start. |

## 2. Parts (children of CMD-99; one branch and PR each)

| Part | Ticket | What | Phase | Boards |
|---|---|---|---|---|
| 0 Data | CMD-100 | Migration: one record per org, patient number, old file number, families, medical alerts, forms and consents, archive and erase, clinical-content access (§6). RLS and tests. No UI. | 3 | none (data for all) |
| 1 List | CMD-101 | Patient list (all views, preview panel, Needs attention, no results, empty, loading, error, read-only), practitioner My patients, duplicates and merge, bulk notice | 3 | PatList* (12) |
| 2 Record | CMD-102 | Header, alerts row, tabs, side column; Overview, Timeline, Visits, Forms and consents tabs; loading, error, paused, archived, erased, read-only | 3 (timeline messages need P2 data) | PatRec* except Plans, Docs, Money |
| 3 Forms | CMD-103 | New patient (same-phone check), Edit (CMD-65 already covers it: the PM links CMD-65 under Part 3, no second ticket), Add alert, Confirm alert, Send or fill a form (tablet lock, link, typed), Family, Archive, Erase | 3 | PatForm* (8) |
| 4 Phone | CMD-104 | Practitioner list, record, timeline, confirm sheet; owner record | 3 | PhonePat* (5) |
| 5 Later tabs | CMD-105 | Treatment plans (P5), Documents and photos (after P3), Money tab (P5) | 5 / after 3 | PatRecPractitionerPlans, *Docs, PatRecManagerMoney |

Until Part 5 ships, those three tabs are **hidden**, not shown empty or mocked (product principle 4). The current media
viewer and billing stay reachable from the record until then.

## 3. Roles (what differs; the boards show each)

| | Front desk | Practitioner | Manager | Owner | Read-only (admin_viewer) |
|---|---|---|---|---|---|
| List opens on | Branch, All view | **My patients** + "My patients today" card | Branch | Branch (All branches in filter) | Branch, no actions |
| Balance column | yes | **no** | yes | yes | yes |
| Import / Export | no | no | yes | yes | no |
| Bulk select + Send a notice | no | no | yes | yes | no |
| Clinical notes, X-rays, clinical photos, clinical documents | **hidden: lock line + author + date, no content** | yes | yes | yes | yes (view only) |
| Money tab, Collect | yes | **no** (tab hidden) | yes | yes | view only |
| Add an alert | yes | yes | yes | yes | no |
| Confirm / change / remove a confirmed alert | no | **yes** | no | no (unless also a practitioner) | no |
| Archive / Restore | no | no | yes | yes | no |
| Erase personal details | no | no | no | **yes** | no |
| Merge duplicates | no | no | yes | yes | no |

The side column, alerts row and timeline are the same for every role except what is hidden above.

## 4. States (per the boards)

| State | Rule |
|---|---|
| Loading | Skeletons after 300 ms. List: view tabs without counts, 10 skeleton rows. Record: header, tabs and both columns as skeletons. |
| Error | List: "The patient list did not load" + Try again; the rest of the shell works. Record: "This record did not load" + Try again + Back to patients. |
| Empty (new clinic) | Owner board: "No patients yet", Import a spreadsheet + New patient, the columns-we-read tip. |
| No results | Searches the current branch first; if the name exists at another branch, says so and shows that patient's card with Open record. |
| Agents paused | Yellow banner (same as Home); the side column's Agent activity says what is waiting. |
| Archived | Grey status bar under the header with Restore; actions become Restore record; hidden from list and search; agents do not message. |
| Erased | Opening the old link shows "This patient was erased"; the record shows only as "Erased patient P-…" in reports. |
| Alert confirmed | Toast "Alert confirmed: … Everyone now sees it." |

## 5. Components (Astryx names from the Foundations boards; confirm each in the spike)

| Part | Component |
|---|---|
| Shell, sidebar, branch filter | `AppShell`, `SideNav`, `Menu` |
| List table, view tabs, pager | `Table` (sticky header, row hover, keyboard ↑ ↓ Enter), `Tabs`, `Pagination` |
| Search box with `/` shortcut | `TextField` + our `/` key handler |
| Filters, sort, columns | `Select` / `Menu`, `IconButton` |
| Preview panel, New / Edit sheets | `Sheet` (right side, 400 / 600 wide) |
| Dialogs (alert, confirm, family, send form, archive, erase, merge, bulk notice) | `Dialog` |
| Chips (alerts, states, Today, agent) | `Badge`; agent chips use the agent (purple) tone only |
| Who-acted chips on the timeline | **WhoActed** (ours, from the Home brief) |
| Timeline | **PatientTimeline** (ours, from `List`): day headers, icon rail, filter buttons, search, "Show earlier" |
| Bulk action bar | **BulkBar** (ours, from `Toolbar` or a dark `Card`) |
| Segmented controls (gender, BS/AD, type, seriousness) | `SegmentedControl` |
| Checkboxes | `Checkbox` (with mixed state for select all) |
| Progress bar (plan) | `ProgressBar` (Part 5) |
| Empty, error | `EmptyState` · Loading: `Skeleton` · Toast: `Toast` with Undo |
| Phone record and sheet | phone parts from the approved phone boards (bottom bar, bottom `Sheet`) |

Tokens only, no raw hex. Purple only on agent things. Nepali text uses Noto Sans Devanagari.

## 6. Data (Part 0) and actions

Names are **proposed**; the builder writes the design into the Part 0 ticket and the lead approves it before SQL is written.
Take the next free migration number (017 is CMD-95 and 018 is claimed by CMD-97, so probably 019; check `supabase/` on every open branch and Plane) and claim it
in the Part 0 ticket. Rollback file required; round trip tested on local.

| Need | Proposal |
|---|---|
| One record across branches | Today `customers.branch_id` is NOT NULL and lists are branch-scoped. Keep `branch_id` as **home branch**; make reads org-scoped with a branch filter. Every existing query that scopes patients by branch must be listed and checked (the Part 0 PR lists them). Visits keep their own branch. |
| Patient number | `customers.patient_no` per org, gapless sequence per org, shown as P-01234, unique (org_id, patient_no); backfill existing rows by created_at. |
| Old file number | `customers.old_file_no text`, searchable. |
| Name in Nepali, language, preferred channel, address, emergency contact, found us | columns on `customers` (some may exist via 013 `patient_channels`; reuse, don't duplicate). |
| Families | `families` (org) + `customers.family_id` + `families.contact_customer_id`. Messages to a family go to the contact phone and name the patient. Duplicate check ignores members of the same family. |
| Medical alerts | `patient_alerts` (type, text, details, source, severity note/caution/danger, confirmed_by, confirmed_at, created_by). Anyone who can edit adds; only a practitioner confirms, changes or removes a confirmed one. Every change audited. Intake forms create unconfirmed alerts. |
| Forms and consents | `form_templates` (from the specialty pack; editing them is Settings, not this ticket) and `form_submissions` (customer, template, channel: tablet/link/typed, signed_at, device, PDF path). Link valid 3 days. Service / marketing consent stays where 013/015 put it. |
| Needs attention | SQL view or function: unconfirmed alerts, forms due before the next visit, forms over a year old, same-phone pairs, bounced phones; sorted by next visit. |
| Archive | `customers.archived_at`, `archived_by`, `archive_reason`. Archived rows are excluded from list, search, agents and bulk sends; archiving cancels future bookings and keeps dues (show this in the dialog, as drawn). |
| Erase | Owner-only definer function: needs an uploaded written request; wipes the listed personal fields, family links, message threads and recordings; keeps clinical and money rows linked to "Erased patient P-…"; audit entry with the request. |
| **Clinical content for front desk** | **Enforced in the database, not only hidden in the UI.** Front desk (`staff`) must not be able to read note bodies, X-ray / photo files or clinical documents through PostgREST, storage or any RPC. It may read author, date and type. Test it with the anon key as a staff user in `test:rls`. |

| Action (via the action layer) | Who |
|---|---|
| `patient.create` (with same-phone check and family choice), `patient.update` | front desk, manager, owner (practitioner: update only) |
| `alert.add`, `alert.confirm`, `alert.update`, `alert.remove` | add: all who edit; the rest: practitioner |
| `family.link`, `family.unlink`, `family.set_contact` | front desk, manager, owner |
| `form.send_link`, `form.start_on_device`, `form.record_typed` | front desk, manager, owner, practitioner |
| `consent.record_marketing_yes` | staff, with the patient's words |
| `patient.archive`, `patient.restore` | manager, owner |
| `patient.erase` | owner |
| `duplicates.merge`, `duplicates.dismiss`, `duplicates.link_family` | manager, owner |
| `notice.send_bulk` (service templates only; marketing only to consented; returns the skipped list with reasons; respects quiet hours 8 pm - 8 am) | manager, owner |

The list and record render with AI off: nothing here calls a model on load.

## 7. Acceptance checks (the lead runs these)

1. Each of the 42 boards can be reproduced on local Supabase with the seed script and matches the board at 1440 wide
   (phone boards at 390). Screenshots attached to each part's ticket.
2. Front desk, signed in with the anon key, cannot read a note body, an X-ray or photo file, or a clinical document by any
   route (table, view, RPC, storage URL). Practitioner, manager, owner and read-only can. Proven in `test:rls`.
3. A patient created at Lalitpur is found from Baneshwor; the list's branch filter and All branches work; visits show their
   branch. A second org's patients never appear (test:rls).
4. Search finds by name, phone, P-number and old file number. `/` focuses search; ↑ ↓ Enter and J/K work as drawn.
5. New patient with an existing phone shows the family choice; "Add to family" links, does not flag as a duplicate.
6. An alert added by front desk shows "Not confirmed" everywhere at once; only a practitioner can confirm, change or
   remove it; each change is in the audit log.
7. Bulk notice: only manager and owner; marketing templates skip patients without marketing consent; the dialog's counts
   equal what is sent; skipped reasons listed; nothing is sent in quiet hours; each message is on the patient's timeline.
8. Archive hides the patient from list, search, agents and bulk sends; Restore brings it back unchanged. Erase is owner-only,
   needs the request file and the typed name, keeps clinical and money rows as "Erased patient P-…", and is audited.
9. Merge moves every booking, note, payment, message, alert and form to the kept record and is audited; the old P-number's
   link opens the kept record.
10. Every write goes through an action with an audit entry and a toast; Undo where the board shows it.
11. Practitioner: no Money tab, no Balance column, lands on My patients. Read-only: no action buttons anywhere.
12. No feature of today's CRM list or patient record is lost (the PR's feature list is checked against the app).
13. No raw hex; purple only on agent chips. `npm test`, `npm run build` and `npm run test:rls` (local) pass.
14. Part 0: the migration and its rollback round-trip cleanly on local; existing patients get P-numbers in created order.

## 8. Not verified (lead)

- Astryx component names come from the Foundations boards, not rendered components; the spike confirms each
  (`SegmentedControl`, `Sheet`, `Pagination` in particular).
- 21 boards were checked closely, 21 only at contact-sheet size. None checked on a real phone or at 1024-1280 wide.
- Nepali text on the boards has not been read by a Nepali reader. BS/AD date entry (BS default for new patients) was the
  lead's choice; Sadin may veto.
- Where X-rays and photos are stored today was not traced (the record reads `customers`, `bookings` and `consultations`
  through `getPatientRecord`; media grouping is in `utils/patientRecord.js`). Part 0 must find it before designing the
  clinical-access rule.
- The data design in §6 is a proposal; nothing in it has been written or tested.
