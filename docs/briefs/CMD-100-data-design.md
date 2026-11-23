# CMD-100 · Patients Part 0 (data layer): design for approval

**Status:** APPROVED 9.2/10 by the lead (2026-11-23) with rulings; SQL written and tested on local. See "As built" below, which wins over the text under it where they differ. · **Migration:** 019 (PM to claim on CMD-100; no `019` exists on any remote branch as of 2026-11-23)
**Branch:** `feature/CMD-100-patients-data`, from `origin/feature/CMD-97-playbooks-new-orgs` (#22). Local DB only (55322).
**Brief:** `docs/briefs/CMD-99-patients.md` §2 row 0, §6, checks 2, 3, 6, 8, 9, 10, 13, 14 at data level.


## As built (what the code does; read this first)

Files: `supabase/migration-019-patients-data.sql`, `-rollback.sql`, `-preflight.sql`; `src/services/actions.js` (+ test); `supabase/functions/patient-erase/` and
`_shared/patient-erase*.ts` (+ test); `scripts/test-patient-erase-local.mjs`; `supabase/tests/tenant-isolation.sql` section 3e (131 checks).
Branch merged `origin/feature/CMD-79-practitioner-access` (011) as ruled; the PR says "stacks on #15 and #22".

**Rulings folded in:** (1) 011 merged. (2) Phone rule A, plus `patient_message_target(p_customer)` (messages to ANY family member go to the contact's phone
and name the patient). The anon booking pair never errors and returns one row: `_pick_customer_for_booking` takes the exact (case/space-normalised) name, else the
family contact, else the oldest; `find_customer_for_booking` gained an optional 4th argument `p_full_name` (the 3-argument call still works). Phones are now
matched **normalised** (`normalize_phone_e164`), because stored phones are normalised by an existing trigger and the old exact compare never matched raw input.
Staff upsert never renames a family member to a different typed name. (3) Front desk cannot read or write `consultations` / `treatment_notes` or touch
`consultation-audio` / `-images` (RESTRICTIVE policies; also proven through the Storage API: signed URL and download). **Forms are NOT clinical**: no policy on
`form_submissions`; front desk reads and types the answers. Preflight lists staff users who wrote clinical content. (4) `customers.notes`, `bookings.notes` stay
readable. (5) Patient actions are org-wide for every allowed role; the audit `branch_id` is the actor's first branch. (6) `notice.send_bulk` is not in 019.
(7) Alerts are kept on erase. A. Erase: edge function `patient-erase` + SQL refusing while audio exists. B. Form token: 32 random bytes (64 hex), only the sha256 is
stored, 3 days, one submission, `public_get_form` returns title/body/first name/status only. C. Erase role is `admin` = owner; `admin_viewer` refused. D. Only
§4 touches `consultations`. E. See "api.js reads Part 1 must change" below.

**Differences from the draft above:**
- **Merge** deletes the dropped row (as today's `merge_customers` does) and writes `patient_redirects (org, old P-number -> kept id)`; there is no `merged_into` column.
  One routine `_merge_customer_rows` serves `act_duplicates_merge` and the legacy `merge_customers` RPC. It repoints **every** referencing table; the old RPC missed
  treatment_notes, consultations, conversations, patient_channels, agent rows and packages (their FKs are ON DELETE SET NULL / NO ACTION, so a merge would have orphaned
  notes). Duplicate dismissals reuse the existing `customer_duplicate_dismissals`; `customer_duplicate_candidates` now ignores same-family pairs.
- **Undo:** `patient.create`, `patient.update`, forms, archive, erase and merge have none (create keeps numbers gapless; update would copy personal values into the audit log).
  Undo exists for alert add / confirm / remove and family link / unlink, through `act_patient_undo` (action name `patient.undo`), kept apart from `act_undo` so 012 / 013 / 016 are untouched.
  The audit rows hold ids and field NAMES only, never values.
- **`list_patients` has no balance column** (money is a separate read; practitioners have no money access). Part 1 adds it for the roles that may see it.
- **Archive** also skips queued `agent_jobs`, expires open `agent_work_items`, and a trigger on `messages` cancels any outbound agent / rule / system message to an archived or erased patient
  (`PATIENT_ARCHIVED`). Bulk sends do not exist yet (Part 1 must filter `archived_at IS NULL AND erased_at IS NULL`).
- **Erase order** in the edge function: ask the database first (it checks role, request file, typed name); only `AUDIO_FILES_REMAIN` triggers deletion of the recordings, then the
  database step again. A bad request therefore never deletes a file. It also removes the patient's login (auth user).
- **`patient.erase` in the client** calls the edge function (`runAction` gained an `fn` kind), not an RPC.
- Not changed: migration-013 line 226 (staff/manager reach a patient's conversation only by the patient's HOME branch). Under "one record across branches" a front desk at another branch cannot open that
  patient's thread. Proposed follow-up ticket, not scope creep here.

**Known gap:** `action_log` is append-only, so personal words recorded by EARLIER actions (013 consent `evidence` text) stay in the log after an erase. 019's own actions log no values.

## PR body notes (production)

- **Stacks on #15 (011) and #22.** Prod order: #15 applied and merged first, then 012..018, then 019.
- **019 is applied only after the users listed by `migration-019-preflight.sql` section 1 and 2 are moved to practitioner, and only with Part 2's lock lines or Sadin's explicit go-ahead.** After 019 front desk loses all access to consultations, notes and consultation files.
- Not applied to production. Rehearse on a prod-schema copy (CMD-11). Rollback file stops if any patient was erased or any family shares a phone.
- Deploy the `patient-erase` edge function before the owner uses erase; the `erase-requests` bucket is created by 019 (it is not deleted by the rollback).

### api.js reads Part 1 must change (E)
- `fetchCustomers(branchId)` (api.js:6187): `.eq('branch_id', ...)`; replace with `list_patients(p_branch, ...)` (org-wide, branch is a filter).
- `getCustomerIntelligence({ branchId })` (api.js:6533): `withBranch(custQuery, branchId)`; decide per widget whether branch (home branch) or org.
- `getPatientsDirectory({ branchId })` (api.js:6716, 6731): patients with a booking at the branch; replace with the org list.
- Already org-wide, only add `archived_at IS NULL` / `erased_at IS NULL` and P-number / old-file search: `searchCustomers` (4022), `findCustomerByPhone` (4067), `updateBookingDetails` (2025), `findOrCreateCustomer` (8856-8911; note phones are now matched normalised).
- `updateCustomerFields` (6515) should call `patient.update`; `mergeCustomers` (6273) should call `duplicates.merge`.
- `getPatientRecord` (6478) reads `treatment_notes` / `consultations` directly: for front desk it now returns no notes; Part 2 must use `patient_clinical_index` for the lock lines.

## 0. Problems found first (need a ruling)

1. **#22 does not contain 011 (practitioner access, CMD-79, PR #15).** `is_my_patient` and `is_my_booking` are *used* by 013/016 but
   *defined* only in `origin/feature/CMD-79-practitioner-access`, which is not an ancestor of the base (`git merge-base --is-ancestor` fails).
   The local DB has 011 applied by hand, so tests pass locally; a clean rebuild from the repo files would not have the `practitioner` role.
   Everything below uses `practitioner` and `is_my_patient`. **Ask:** merge CMD-79 into the stack, or I merge `origin/feature/CMD-79-practitioner-access` into my branch. I recommend the second now, and the PR note says "stacks on #15 and #22".
2. **The phone is unique per org** (`customers_org_nphone_uniq`, schema.sql:4706), so two family members cannot share the contact phone, which is
   exactly what "Add to family" needs. See §2.4 for the proposed change (needs your ruling).
3. **"Clinical content" today is not one thing.** It is three stores (§4). `customers.notes` (general note) and `bookings.notes` are NOT clinical
   in my reading, so front desk keeps them. **Ask:** confirm.

## 1. Tables and columns

All new tables: `org_id uuid NOT NULL REFERENCES organizations`, RLS on, no direct write grants for API roles (writes only through `act_*`
functions, same as `action_log`), SELECT policy by org + role. Names follow the brief's proposals.

**`customers` (new columns)**
| Column | Type | Note |
|---|---|---|
| `patient_no` | integer NOT NULL | per org, §2.1; shown `P-01234`; `UNIQUE (org_id, patient_no)` |
| `old_file_no` | text | btree index on `(org_id, lower(old_file_no))`; prefix search |
| `full_name_ne` | text | name in Nepali |
| `language` | text CHECK in ('ne','en') | |
| `preferred_channel` | text CHECK in the 013 channel list | reuses 013's channel names; the *addresses and consent* stay in `patient_channels` (no duplicate) |
| `address`, `found_us` | text | |
| `emergency_contact_name`, `emergency_contact_phone` | text | |
| `dob_bs` | text | BS date as entered; `date_of_birth` stays the AD source of truth |
| `family_id` | uuid REFERENCES families ON DELETE SET NULL | |
| `archived_at`, `archived_by`, `archive_reason` | timestamptz / uuid / text | |
| `erased_at`, `erased_by`, `erase_request_path` | timestamptz / uuid / text | |
| `merged_into` | uuid REFERENCES customers | set by merge; old P-number resolves to the kept record |

**`families`**: `id`, `org_id`, `name`, `contact_customer_id` (REFERENCES customers, nullable), `created_at`. `family.set_contact` validates the contact is a member.

**`patient_alerts`**: `id`, `org_id`, `customer_id`, `type` (allergy / medication / condition / other), `text`, `details`, `source` ('front_desk' | 'practitioner' | 'intake_form' | 'import'),
`severity` ('note' | 'caution' | 'danger'), `created_by`, `created_at`, `confirmed_by`, `confirmed_at`, `removed_at`, `removed_by`. Not confirmed = `confirmed_at IS NULL`. Soft remove, so audit and undo stay possible.

**`form_templates`**: `id`, `org_id` (NULL = specialty-pack default), `key`, `title`, `body jsonb`, `valid_days int`, `is_active`. Seeded with the dental pack's intake + consent templates. Editing them is Settings, not this ticket.

**`form_submissions`**: `id`, `org_id`, `customer_id`, `template_id`, `channel` ('tablet'|'link'|'typed'), `status` ('sent'|'signed'|'expired'), `token_hash` (link, valid 3 days: `expires_at`), `signed_at`, `device`, `answers jsonb`, `pdf_path`, `created_by`, `created_at`.
Link flow: only a **hash** of the token is stored; an anon function `public_get_form(token)` / `public_submit_form(token, answers)` reads/writes one submission by hash. They return nothing else (added to the 009 anon allow-list: 2 names, tenant-scoped by the token).
`answers` are clinical-adjacent (medical history): treated like clinical content in §4 (front desk reads status/date, not answers).

**`patient_counters`**: `org_id PK`, `last_no int`: the gapless sequence (§2.1).

**`patient_erasures`**: `id`, `org_id`, `customer_id`, `patient_no`, `requested_by_name`, `request_path`, `erased_by`, `erased_at`, `fields_wiped text[]`. The audit-grade record.

**`patient_needs_attention`** (SQL function `patient_needs_attention(p_branch uuid DEFAULT NULL)`, SECURITY INVOKER so RLS applies; not a view so the optional branch filter works):
unconfirmed alerts; forms due before next booking (template `valid_days` vs last signed); forms older than 1 year; same-phone pairs not in one family; bounced phones (from 013 `messages` failed status; confirm column name when writing SQL). Sorted by next booking date.

**Duplicate check:** same function family, `patient_duplicates()` ignores pairs with equal non-null `family_id`.

## 2. Number, backfill, org-scoped reads

### 2.1 `patient_no`
- `BEFORE INSERT` trigger `customers_assign_patient_no` (SECURITY DEFINER, `search_path=public`; needed because `anon_insert_customers` exists):
  `INSERT INTO patient_counters (org_id,last_no) VALUES (NEW.org_id,1) ON CONFLICT (org_id) DO UPDATE SET last_no = patient_counters.last_no + 1 RETURNING last_no`. The row lock serialises concurrent inserts per org; a rolled-back insert rolls the counter back too, so it is gapless. Caller-supplied `patient_no` is overwritten.
- Backfill: `ROW_NUMBER() OVER (PARTITION BY org_id ORDER BY created_at, id)`, then seed `patient_counters.last_no = max`. Column added nullable, filled, then `SET NOT NULL` + unique constraint, all in one transaction.
- Display `P-` + lpad 5 is **client-side formatting** (not stored). Search by `P-01287`, `1287` or `01287` handled in the search function (§5).
- Erase never reuses a number; a deleted row would break gapless, so customers are never hard-deleted (existing practitioner policy already blocks delete).

### 2.2 Old reads that scope customers by branch (all in `src/services/api.js`)
| Line | Function | Scope today | Change needed |
|---|---|---|---|
| 2025 | `updateBookingDetails` | `org_id` | none |
| 4022 | `searchCustomers(branchId,…)` | `org_id` (branch only used to find org) | already org-wide; add `archived_at IS NULL`, P-number and old-file-no search |
| 4067 | `findCustomerByPhone(branchId,…)` | `org_id` | add `archived_at IS NULL` filter option; return family info |
| 4434 | `getCalendarBookings` | by booking id | none |
| **6187** | **`fetchCustomers(branchId)`** | **`.eq('branch_id', resolvedBranchId)`** | **branch-only today: becomes org-scoped with optional branch filter (Part 1 change; Part 0 provides `list_patients` RPC)** |
| 6308 | `fetchCustomerProfile(id)` | by id | none (RLS org) |
| 6478 | `getPatientRecord(id)` | by id; reads `branch_id` | none; consumes new fields later |
| 6515 | `updateCustomerFields` | by id | moves into `patient.update` action |
| **6533** | **`getCustomerIntelligence({branchId})`** | **`withBranch(custQuery, branchId)`** | **branch-only: list for Part 1 to decide (stays branch = home branch for analytics)** |
| 6716/6731 | `getPatientsDirectory({branchId})` | via bookings' branch | patient directory is "customers with a booking at this branch": stays; Part 1 replaces with the org list |
| 8856–8911 | `findOrCreateCustomer` | `org_id`; insert uses `branchId` as home branch | none; sets home branch as today |

Database side: `customers` RLS (rls.sql:224, 236, migration-008) has **both** a branch policy ("Staff can read branch customers") and an org policy ("Staff can read own org customers"), both PERMISSIVE, so a signed-in staff user can already read every patient in the org at table level (local DB confirms 6 policies). **UNVERIFIED for prod** (CMD-11).
So the real work is the UI queries above, plus these SQL spots that use the branch rule on a customer:
- `migration-013-communication-hub.sql:226` (`conversation access`): staff/manager reach a patient's conversation only if `customers.branch_id` is in their branches. A patient at another branch → no thread. **Change:** for patient-linked conversations use org scope for staff/manager (thread is shown on the record), keep branch rule for unlinked.
- `migration-012` action_log read policy (branch of the action): unchanged; actions carry the *visit's* branch.
- `can_access_consultation_booking` (006): booking-branch rule: unchanged by design ("visits keep their own branch").
- `public.find_customer_for_booking` / `upsert_customer_for_booking`: org-scoped already.
I will re-grep every migration and `functions/` again when writing SQL and add anything missed to the PR table.

### 2.3 Practitioner
`is_my_patient(customer)` (011) already decides "My patients". No change.

### 2.4 Phone uniqueness vs families (ruling needed)
Replace `customers_org_nphone_uniq` by: `UNIQUE (org_id, nphone) WHERE family_id IS NULL AND nphone IS NOT NULL` plus a constraint trigger
`customers_phone_family_guard`: a phone shared by several rows must have **all** of them in one family. Result: same-phone new patient is rejected as before unless the action puts them in that family.
`findOrCreateCustomer` and `upsert_customer_for_booking` handle the 23505 race the same way (still raised for non-family). Alternative (B): family members have no own phone and use the contact's. I recommend A: patients keep their own number, and 013 messaging uses `families.contact_customer_id`'s phone only for minors/non-phone members.

## 3. Archive, erase, merge (functions)
- **Archive**: `act_patient_archive(p_customer, p_reason, p_ctx)`: sets the 3 columns, cancels future bookings (reuses the 012 booking status path so audit/undo per booking), keeps dues (no money rows touched), returns counts shown in the dialog. `act_patient_restore` clears the 3 columns, does not restore bookings. Archived rows excluded in `list_patients`, search, the agent queue readers (`agent_*` candidates in 016/017 get `AND c.archived_at IS NULL`; I list each when editing) and `notice.send_bulk`.
- **Erase** `act_patient_erase(p_customer, p_request_path, p_typed_name, p_ctx)`: SECURITY DEFINER, role must be `admin` **and** org match. Requires `p_request_path` to exist in a new private bucket `erase-requests` under `<org>/<customer>/` (checked in `storage.objects`), and `p_typed_name` equal to the current `full_name`. Wipes: `full_name` → `'Erased patient P-NNNNN'`, `phone`, `email`, `notes`, `full_name_ne`, `address`, `found_us`, emergency contact, `date_of_birth`, `dob_bs`, `gender`; sets `family_id=NULL` (and clears contact if they were); deletes `patient_channels` rows; keeps `patient_alerts` (clinical, stays with "Erased patient"); deletes `conversations`/`messages` bodies (13) and **recordings** (`consultation-audio` objects + `audio_paths`, `transcript`). Keeps `consultations` clinical fields, `treatment_notes`, X-ray/photo files, bookings and payments (denormalised `bookings.customer_name/phone/email` and `consultations.patient_name` are overwritten with the erased label). Writes `patient_erasures` + action_log (inputs include the request path, not the personal data). Not undoable.
- **Merge** `act_duplicates_merge(p_keep, p_drop, p_ctx)`: moves bookings, `treatment_notes`, `consultations`, payments (by customer ref columns; the PR lists each FK found via `pg_constraint`), conversations/messages/`patient_channels` (dedup by unique key), alerts, form submissions; sets `customers.merged_into = keep` on the dropped row (archived, kept for the old-P-number link). `list_patients`/lookup by P-number follows `merged_into`. Undo: no (audited with the moved id lists).
- `duplicates.dismiss`: table `duplicate_dismissals(org_id, a, b)` (sorted pair), so pairs stay dismissed. `duplicates.link_family`: puts both into one family.

## 4. Front desk blocked from clinical content (database and storage)
**Where clinical content is today** (traced in code and schema):
| Content | Where | Today front desk (`staff`) |
|---|---|---|
| Note bodies | `treatment_notes.note` (read at api.js:1837, 1858, 6339, 11804) | **can read** (policy "Staff can read own org treatment notes", rls.sql:498, no role test) |
| Consultation record: transcript, summaries, `doctor_notes`, `xray_analysis`, `photo_analysis`, `additional_notes`, image path arrays | `consultations` table (api.js:11723-11843) | **can read** and write (006 policies allow `staff`, `manager`, `admin`) |
| X-ray and photo **files** | **Private bucket `consultation-images`**, path `<org>/<booking>/<file>`, read by signed URL (api.js:11684) | **can read** (006 storage policy: org + booking branch, no role test) |
| Recordings | private bucket `consultation-audio` | same |
| Clinical documents / uploaded PDFs | **do not exist yet** (Part 5). Bucket `treatment-images` is **public** (rls.sql:533) and holds treatment catalogue pictures, not patient files, so it is out of scope. | n/a |
| Form answers | new `form_submissions.answers` | new |
Not clinical (front desk keeps): `customers.notes`, `bookings.notes`, alerts (the brief lets front desk add and see them).

**Mechanism: RLS row denial plus a metadata function, no column privileges** (column grants are per DB role, and all staff share `authenticated`, so they cannot separate `staff` from `practitioner`).
1. **RESTRICTIVE SELECT policies** `frontdesk_no_clinical_read` on `treatment_notes`, `consultations`, `form_submissions`: `USING (public.get_user_role()::text IS DISTINCT FROM 'staff')`. Same pattern as 011's `practitioner_no_payments`. Also RESTRICTIVE INSERT/UPDATE/DELETE for `staff` on `treatment_notes` and `consultations` (front desk never writes notes; today the UI hides it, this makes the database agree). **Check:** the `staff` role is also used by the practitioner-less clinics where one person does both. The Settings access level (011) is the fix: they get `practitioner`. **Ask:** confirm no flow needs `staff` to write a consultation.
2. **Storage**: replace the SELECT/INSERT/DELETE policies on `consultation-audio` and `-images` (006:323-342) with versions adding `public.get_user_role()::text <> 'staff'` (read), `IN ('manager','admin','practitioner')` (write). `admin_viewer` read stays. Signed-URL creation goes through the same policy, so a staff user's `createSignedUrl` fails. The edge functions use the service role and are unchanged.
3. **Metadata for front desk**: `SECURITY DEFINER` function `patient_clinical_index(p_customer uuid)` returns **author, date, type, id** (kind: note/xray/photo/document/consultation) and **never** body/text/path, role-gated to the caller's own org and the existing patient-access rule. The record's lock lines ("hidden: lock line + author + date") read this. Also granted to every role, so one code path.
4. **RPC leak check**: I grep every SECURITY DEFINER function for `treatment_notes`, `consultations`, `doctor_notes`: none return note bodies today (grep shows only 012/013/016 *existence* checks on `consultations`). The `test:rls` covers each function that touches the tables via a list.
5. **Realtime**: `consultations` is in `supabase_realtime` (006). Realtime applies RLS to the subscriber, so the restrictive policy applies; the test subscribes as staff and expects no row. (If the local harness cannot test Realtime, it goes on the Not verified list.)
6. **Views**: none exist for these tables; the rule is "no view over them without `security_invoker`", stated in the migration header.
7. Existing `patient_chart`/`getPatientRecord` call (api.js:6339) will return an empty notes array for staff once enforced: Part 2 must render lock lines. Until Part 2, the current UI would show "no notes" to front desk. I note this in the PR as a **behaviour change for prod front desk** (they lose note reading) and it needs your go-ahead before the migration reaches prod.

## 5. Actions (added to `ACTIONS` in `src/services/actions.js`, SQL `act_*` functions in 019)
All through `_act_resolve` / `_act_finish`; each writes one `action_log` row; undo where noted.
| Action | RPC | Roles | Undo |
|---|---|---|---|
| `patient.create` (same-phone check; returns `{matches, needs_family_choice}` when phone exists, unless `family` arg given) | `act_patient_create` | staff, manager, admin | yes |
| `patient.update` | `act_patient_update` | staff, manager, admin, practitioner | yes |
| `alert.add` | `act_alert_add` | all who edit (staff, manager, admin, practitioner) | yes |
| `alert.confirm` / `alert.update` / `alert.remove` | `act_alert_*` | **practitioner only** (the brief: owner not, unless also a practitioner, i.e. a `practitioner` login) | yes |
| `family.link` / `family.unlink` / `family.set_contact` | `act_family_*` | staff, manager, admin | yes |
| `form.send_link` / `form.start_on_device` / `form.record_typed` | `act_form_*` | staff, manager, admin, practitioner | no |
| `consent.record_marketing_yes` | `act_consent_marketing_yes` (writes `patient_channels` via 013's rule, needs `evidence` = patient's words) | staff, manager, admin | yes |
| `patient.archive` / `patient.restore` | `act_patient_archive` / `_restore` | manager, admin | restore only |
| `patient.erase` | `act_patient_erase` | admin | no |
| `duplicates.merge` / `.dismiss` / `.link_family` | `act_duplicates_*` | manager, admin | dismiss only |
| `notice.send_bulk` | **not in this ticket** (needs the hub send path and quiet-hours rules; goes with Part 1). I will add only `patient_bulk_audience(p_template, p_filter)` if you want the counts function now. | manager, admin | n/a |
`admin_viewer` and `practitioner` where not listed are refused with `FORBIDDEN`. Branch scope: staff/manager act on patients whose home branch OR any visit is in their branches **or** (new, per the one-record rule) any patient in the org for `patient.update`, `alert.add`, `family.*`, `form.*`? **Ask:** I propose org-wide for all patient actions for every role (the brief: "one record across branches"), and keep the audit's `branch_id` = the actor's branch.
Reads (not actions): `list_patients(p_branch, p_view, p_q, p_limit, p_offset)` (SECURITY INVOKER, excludes archived, search by name/phone/P-no/old-file-no, balance column omitted when role is `practitioner`: the money columns are not selected at all), `patient_lookup(p_no)` (follows `merged_into`), `patient_needs_attention`, `patient_duplicates`, `patient_clinical_index`.

## 6. Tests
- `supabase/tests/tenant-isolation.sql`: add cases (counts reported in `COVERAGE`): front desk, via PostgREST role switch + JWT claims, cannot SELECT `treatment_notes`, `consultations`, `form_submissions`; cannot read or sign `consultation-images`/`-audio`; cannot call any listed function to get a body; **can** call `patient_clinical_index` and sees author/date only; practitioner/manager/admin/admin_viewer can read. Cross-org: org B user never sees org A patients, alerts, families, forms, counters, erasures. Cross-branch: a patient created at branch A is found from branch B by name, phone, P-no, old file no. Phone-share guard. `patient_no` gapless under 20 concurrent inserts (local psql). Alert flow roles. Archive/erase/merge permissions and effects. Anon: `public_get_form` with a wrong/expired token returns nothing.
- Vitest: `actions.test.js` for each new action name → rpc + args mapping and error pass-through (same style as the existing file).
- Round trip: apply 019, `\copy` row counts and P-number order check against `created_at`, run rollback, re-apply.

## 7. Rollback (`migration-019-rollback.sql`)
Drop in reverse: new functions, anon form functions, triggers (patient_no, phone guard), new policies and the restored 006 storage / 011-era policies (the original definitions are copied into the rollback), tables (`patient_erasures`, `duplicate_dismissals`, `form_submissions`, `form_templates`, `patient_alerts`, `families`, `patient_counters`), the new `customers` columns, the `erase-requests` bucket policies, and `customers_org_nphone_uniq` is recreated (**fails if family members already share a phone: the rollback begins with a preflight that lists them and aborts**). Erase is destructive and cannot be rolled back: the rollback file says so at the top, and the round trip is only valid before any erase. `migration-019-preflight.sql` (read-only, like 007's) counts customers per org, phone duplicates, rows `staff` would lose access to.

## 8. Not decided / needs your answer
1. Merge CMD-79 (011) under this branch? (§0.1, recommend yes, my branch merges it.)
2. Phone-sharing rule A (relax unique for one family) vs B. Recommend A. (§2.4)
3. Front desk loses write access to `consultations`/`treatment_notes` and read access to them in prod: confirm, and that this ships only with Part 2's lock lines or with your explicit prod go-ahead. (§4.1, §4.7)
4. `customers.notes` and `bookings.notes` stay readable by front desk. (§0.3)
5. Patient actions org-wide for every role (not branch-limited). (§5)
6. `notice.send_bulk` moved to Part 1. (§5)
7. Alerts are kept (not wiped) on erase. (§3)
