# Brief: Consultation groundwork (consent, AI provenance, sources, recording retention) · CMD-54 + CMD-55

**Status:** Consultation boards approved by Sadin (canvas "ClinicMD Mockups", page **12 Calendar**, bottom row, 9 boards
`Consult*`). **Phase:** 1 (finish the AI pilot) · **Lead:** lead session · **Migration:** 020 (claimed on CMD-54).
**Follows:** `docs/PRODUCT-BRIEF.md` §2 (recordings deleted 30 days after signing; the Scribe is paused only by an AI outage,
never by a budget; front desk sees no clinical content), §6 principle 10 (consent first), §12 Phase 1 exit test.
**Sadin's rule (2026-11-23): groundwork first.** This brief is the data and function layer only. The redesigned screens
come in a later part once this works. Where this brief says "wire", it means the **current** consultation screens with
no visual redesign: a stored value replaces a value that today lives only in React state.

## 1. Why

The consultation feature is **live at Bright Smile** (prod, migration 006). Two things the Phase 1 exit test needs are missing:
- **Recording consent is not stored.** `src/pages/consultation/index.jsx:447` keeps it in React state only ("deliberately
  not stored (that needs a DB column)"). It is lost on reload and is not checked by the server.
- **AI provenance is not stored.** Nothing records that the note was drafted by AI (model, time, from what), who reviewed
  and signed it, or what was edited. Phase 1 is done when "consent and the 'AI drafted, reviewed by' line survive a reload".

The boards also need, at the data level: a source (quote and time in the recording) for every note line, a signed note
that cannot change silently, and recordings deleted 30 days after signing.

**This touches a live clinical table.** Additive changes only. Existing rows must keep working exactly as today.

## 2. Where to work

- Worktree `~/Projects/clinic-md-CMD-54`, branch `feature/CMD-54-consultation-data`, from `origin/feature/CMD-97-playbooks-new-orgs`
  (#22), **then merge `origin/feature/CMD-79-practitioner-access` (011, #15) into it** (a merge, no rebase): #16-#22 do not
  contain 011, but 013/016 use its `is_my_patient`, and 011 changes `consultations` policies. The PR stacks on #15 and #22.
- **Do not depend on 019** (CMD-100, built in parallel from the same base). Test both orders on local: 001-018 + 020, and
  001-018 + 019 + 020 once CMD-100's branch has a 019 to apply.
- Local DB only (`clinicmd-local`, 55322). Never prod. Edge functions are run locally (`supabase functions serve`) with a
  fake OpenAI (no real key) for tests.

## 3. Scope

### 3.1 Consent (CMD-54)
- Columns on `consultations`: `recording_consent` (`agreed` | `declined` | null), `recording_consent_at`, `recording_consent_by`
  (users.id), `recording_consent_device` (`computer` | `phone`), `recording_consent_script` (text id of the words shown,
  e.g. `dental-en-ne-v1`; the words are in code, not in the row).
- **Who:** every function in this brief refuses role `staff` (front desk). Sadin's 2026-11-22 decision: front desk has no
  clinical content, and CMD-100 (019) adds RESTRICTIVE policies that block `staff` from `consultations`. Allowed:
  `practitioner`, `manager`, `admin`. `admin_viewer` is read-only. Don't change read policies here (CMD-100 owns them).
- One SECURITY DEFINER function `consultation_record_consent(p_consultation, p_answer, p_device)`: same org, an allowed role
  with access to that consultation's booking (`can_access_consultation_booking`, plus `is_my_booking` for practitioners), answer recorded once per consultation (a second call that changes the answer is refused
  with `CONSENT_ALREADY_RECORDED`; "Record more" in the same consultation needs no new consent). Audited.
  If the action layer (012) has a suitable pattern, register it as action `consultation.record_consent`. Say in the design note
  which you chose and why.
- **Server enforcement:** `consultation-transcribe` refuses audio for a consultation whose `recording_consent` is not `agreed`
  (`CONSENT_REQUIRED`, 403). Behind a function env `CONSULT_REQUIRE_CONSENT` (default `false`) until both the desktop and the
  phone paths store consent. The design note says when it can be turned on.
- **Wire:** the existing consent control on the desktop page and on the phone path (`DoctorPhone.jsx`; find where the phone
  asks today, or say that it doesn't) call the function, and the page reads the stored value on load.

### 3.2 AI provenance and signing (CMD-55)
- Columns: `ai_drafted_at`, `ai_provider` (`openai`), `ai_model` (e.g. `gpt-4o`), `ai_inputs` (text[]: `recording`, `xray`, `photo`),
  `ai_draft` (jsonb: the note exactly as the model returned it, before any edit), `signed_at`, `signed_by`, `signed_by_name`,
  `edited_sections` (text[], computed at signing by comparing the signed note with `ai_draft`).
- `consultation-summarize` returns provider, model and inputs with the note; the client stores them through one function
  `consultation_store_draft(...)`. The note text written by the client and `ai_draft` must come from the same response.
- `consultation_sign(p_consultation)`: same org, an allowed role (above) with access to the booking. Sets `status = 'completed'`,
  `signed_*`, `edited_sections`. Audited. Whether only the attending practitioner may sign is a later ruling (write it in the hand-off).
- **Signed notes are locked:** a trigger refuses changes to the note, transcript and AI columns of a signed consultation.
  The one exception is `consultation_unsign`, allowed for the signer within 15 minutes (the board's "Undo"). Later corrections
  need an addendum feature, which is not in this ticket (write it in the hand-off as a follow-up).
- **Existing rows:** completed consultations from before 020 have no `signed_at`. They stay editable as today, and the line
  shows nothing for them. Do not backfill a signer you can't prove.
- **Wire:** the current page shows "AI drafted, reviewed by <name>" (or "Written by <name>" when there is no `ai_draft`)
  from the stored columns after reload. Use plain text in the current styles.

### 3.3 A source for every line
- `consultation-transcribe` already asks whisper for `verbose_json`. Store the segments: `transcript_segments` (jsonb
  `[{start, end, text}]`).
- `consultation-summarize` returns, per section, the sources it used: `note_sources` (jsonb `{section_key: [{quote, start}]}`).
  **The server drops any source whose quote is not found in the stored segments** (normalised whitespace and case). A source
  is never invented. Sections drafted from an image get `{image: 'xray' | 'photo'}` in place of a quote.
- Stored on draft and kept after signing. No UI in this part beyond storing it.

### 3.4 Note template version
- The boards use five sections (Complaint, Findings, Treatment today, Prescription, Plan). The code today has six
  (`src/utils/consultationNote.js`), and the chart parses those headings.
- Add `note_template` (text, default `dental-v1` = today's six). **Do not switch to the five sections in this part:** the live
  page would break. The screen part adds `dental-v2`. Here, only make the parser and summarize prompt select by
  `note_template`, with tests showing that v1 rows read back unchanged.

### 3.5 Recording retention (30 days after signing)
- New edge function `consultation-retention`. It is called by pg_cron with a bearer token, the same pattern as `agent-run`
  (CMD-95). It deletes the storage objects in `audio_paths` for consultations signed more than 30 days ago, then sets
  `audio_paths = '{}'` and `audio_deleted_at = now()`. Transcript, note and sources stay.
- Delete through the Storage API, not by deleting `storage.objects` rows in SQL. Has a `dry_run` mode that returns what it would delete.
- Unsigned consultations are never touched (a draft keeps its audio). Per-org setting: none yet (30 days is the default for all).

## 4. Out of scope (later parts, need the screens or other tickets)
Five-section template switch, safety check against the chart (needs CMD-100's `patient_alerts`), plan to next booking and
aftercare check-in, the paused/queued drafting state, the redesigned page, front-desk read rules for consultation content
(**CMD-100 owns the clinical-content rule for all tables, including `consultations`**: do not change read policies here).

## 5. Design checkpoint
Before any SQL, send the lead a design note (`docs/briefs/CMD-54-data-design.md` on your branch). It covers:
- the columns, functions and trigger;
- how each function checks org and permission, compared with the 011 policies on `consultations`;
- the action-layer choice;
- the consent wiring on desktop and phone, with file:line;
- the retention scheduling;
- the rollback.
The lead approves it above 9/10 before you write code.

## 6. Tests
- Vitest: parser by `note_template` (v1 rows unchanged), source filtering (an invented quote is dropped), edited_sections.
- SQL (local), added to `supabase/tests/` and run by `npm run test:rls`:
  - another org cannot record consent, sign or unsign;
  - a second consent with another answer is refused;
  - a signed note cannot be updated, and unsign works only for the signer within 15 min;
  - a pre-020 completed row is still editable.
- Edge functions against a fake OpenAI:
  - transcribe stores the segments;
  - with `CONSULT_REQUIRE_CONSENT=true`, transcribe is refused without consent;
  - summarize returns provenance, and its sources are filtered;
  - retention in dry-run and real mode on a row with `signed_at` set back 31 days, and a draft is untouched.
- `npm test`, `npm run build`, `npm run test:rls` pass. The migration and its rollback round-trip on local.

## 7. Acceptance checks (the lead runs these)
1. On local, a consultation with consent recorded, drafted by the (fake) model, edited in one section and signed: after a reload
   the page shows the consent time and "AI drafted, reviewed by <name>". The row has provider, model, inputs, `ai_draft`,
   `edited_sections = {prescription-or-the-edited-key}`.
2. A signed row cannot be changed by PostgREST as any role; unsign works only as described.
3. A source quote not in the transcript never reaches `note_sources`.
4. Retention deletes the audio of a row signed 31 days ago and leaves a 29-day row and a draft alone. The transcript and note remain.
5. Another org's user can do none of this (test:rls).
6. Existing rows (pre-020, six-section, completed) look and behave exactly as today on the current page and chart.
7. Rollback restores the 018 (or 019) schema, and the live pilot code still works with the rollback applied.

## 8. Production notes (for the hand-off, not for this builder to do)
- 020 is applied by a human after 011-018 (and 019 if merged first) are in prod.
- `consultation-transcribe`, `consultation-summarize` and the new `consultation-retention` need a human `supabase functions deploy`.
- The pg_cron job needs its secret.
- `CONSULT_REQUIRE_CONSENT` is turned on only after both paths are confirmed live.

## 9. Not verified (lead)
- Who signs in prod today (dentists may log in as `staff` or `manager`). Not traced. If any dentist logs in as `staff`, 019
  and 020 lock them out until they are moved to `practitioner`. CMD-100's preflight lists those users, and the design note
  repeats the check for 020.
- Whether the phone path asks for consent at all today.
- Whether whisper segment timestamps are good enough for Nepali or mixed speech to make the quotes useful. Tested only on English sample audio.
- Open with Sadin: does image analysis (X-ray or photo sent to OpenAI) need its own patient consent, or is it covered by the treatment? Not built here either way.
