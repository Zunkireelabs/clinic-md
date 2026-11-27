# Design note: Consultation groundwork, migration 020 · CMD-54 + CMD-55

Brief: `docs/briefs/CMD-54-consultation-data.md` (lead). This note is STEP 1 (brief §5). There is no SQL or code until the lead
approves it above 9/10.
Branch `feature/CMD-54-consultation-data`, from `origin/feature/CMD-97-playbooks-new-orgs` (b09202a) with
`origin/feature/CMD-79-practitioner-access` (011) merged in (3c53256). The only conflict was `supabase/tests/tenant-isolation.sql`.
I kept both sides and relabelled the 011 section `3h`. That file has **not been run** since the merge.

Principle throughout: **additive**. Every new column is nullable or has a default. Old code that writes none of the new columns
keeps working against 020. A row from before 020 has `signed_at IS NULL` and behaves exactly as it does today.

## 1. Columns (all on `public.consultations`)

| Column | Type | Written by | Notes |
|---|---|---|---|
| `recording_consent` | text, CHECK in (`agreed`,`declined`), null | `consultation_record_consent` | null = not asked |
| `recording_consent_at` | timestamptz | same | |
| `recording_consent_by` | uuid → users.id | same | always `auth.uid()`, never a parameter |
| `recording_consent_device` | text, CHECK in (`computer`,`phone`) | same | |
| `recording_consent_script` | text | same | e.g. `dental-en-ne-v1`. The words live in code (`src/utils/consentScripts.js`, new) |
| `transcript_segments` | jsonb, default `'[]'` | `consultation_store_segments` (service role) | `[{audio_path, start, end, text}]`. Times are seconds **within that recording** |
| `note_template` | text NOT NULL, default `'dental-v1'` | default only in this part | `dental-v1` = today's six sections |
| `ai_drafted_at` | timestamptz | `consultation_store_draft` (service role) | |
| `ai_provider` | text | same | `openai` |
| `ai_model` | text | same | `gpt-4o` |
| `ai_inputs` | text[] | same | subset of `recording`,`xray`,`photo` |
| `ai_draft` | jsonb | same | `{section_key: text}` exactly as the model returned it |
| `note_sources` | jsonb | same | `{section_key: [{quote, start, audio_path}] or [{image}]}`, filtered on the server |
| `signed_at`, `signed_by` (uuid → users.id), `signed_by_name` | | `consultation_sign` / `consultation_unsign` | |
| `edited_sections` | text[] | `consultation_sign` | null when there is no `ai_draft` |
| `audio_deleted_at` | timestamptz | `consultation_mark_audio_deleted` (service role) | |

**Deviation 1 (asking the lead): sources carry `audio_path`.** Whisper times count from the start of each recording, and
"Record more" makes several recordings. A bare `start` would be ambiguous, so every source carries the recording it came from.

Index: `idx_consultations_retention ON (signed_at) WHERE signed_at IS NOT NULL AND audio_paths <> '{}'`, for the daily retention scan.

## 2. Two guard rules, one trigger

`consultations_lock_signed`: BEFORE INSERT OR UPDATE, plpgsql, **not** SECURITY DEFINER (this matters, see below).

**Rule A: function-only columns.** All the new columns except `note_template` can only change when
`current_user NOT IN ('authenticated', 'anon')`. A direct PostgREST insert or update by a signed-in user that sets or changes
them raises `42501 FUNCTION_ONLY_COLUMN`.
Why this is needed: today's write policies (006: `staff`, `manager`, `admin`; 011: practitioner on own bookings) let those roles
UPDATE any column. Without rule A, a client could write `signed_at`, `ai_draft` or `recording_consent` directly and skip every check below.
How it works: inside a SECURITY DEFINER function, `current_user` is the function owner. The trigger fires in that context,
so writes made by our functions pass. A plain PostgREST call runs as `authenticated`, so it is caught. The trigger function must
not itself be SECURITY DEFINER, or `current_user` would always be its owner. A service-role edge function (`current_user = service_role`) passes rule A.
That is intended: those writes go through the service-role-only functions in §3.

**Rule B: signed rows are locked.** When `OLD.signed_at IS NOT NULL`, every column is frozen except `additional_notes`
(private staff notes, not part of the clinical note), `attended_by_names` (maintained by the 006 trigger) and `updated_at`.
This applies to **every** role, `service_role` and direct SQL included. Exactly two exceptions:
1. **Unsign:** `NEW.signed_at IS NULL` and `current_user NOT IN ('authenticated','anon','service_role')`, so only a
   SECURITY DEFINER function can do it, and only `consultation_unsign` does.
   The trigger checks only that pattern. The signer and 15-minute rules live in the function.
2. **Retention:** `current_user = 'service_role'`. Only `audio_paths` (and only to a subset of OLD) and `audio_deleted_at` may change.

Raises `SIGNED_LOCKED` (errcode 42501). Rows from before 020 have `signed_at IS NULL`, so rule B never touches them: they stay
editable exactly as today (test in §8).

`status` stays client-writable on unsigned rows. Today's "Edit note" (`index.jsx:644-650`) and an old cached bundle that saves
`status='completed'` directly keep working. The result is a "completed, unsigned" row, the same state every row is in today, and
it shows no provenance line.

## 3. Functions

Shared checks for the three **person** functions (record_consent, sign, unsign). They are SECURITY DEFINER, `search_path = public`,
EXECUTE revoked from PUBLIC and anon and granted to `authenticated`:

```
ctx := _act_resolve(NULL)                         -- 012/016: signed-in, active users row; anything else = FORBIDDEN
refuse if ctx.service                             -- consent and signature are a person's act; agents and service role can't
c := SELECT ... FROM consultations WHERE id = p FOR UPDATE
refuse NOT_FOUND unless c exists AND c.org_id = get_user_org_id()
                        AND can_access_consultation_booking(c.booking_id)                 -- same as the 006 read policy
refuse FORBIDDEN unless role IN ('practitioner','manager','admin')                        -- staff and admin_viewer refused
refuse NOT_FOUND if role = 'practitioner' AND NOT is_my_booking(c.booking_id)            -- same as the 011 practitioner policy
```

How this compares with the 011 and 006 policies on `consultations`:

| Role | 006/011 UPDATE policy | 020 functions |
|---|---|---|
| admin | org + `can_access_consultation_booking` (org-wide) | same |
| manager | org + branch (`can_access_consultation_booking`) | same |
| practitioner | org + `is_my_booking` + `can_access_consultation_booking` | same |
| staff (front desk) | **allowed** today | **refused** (`FORBIDDEN`): Sadin 2026-11-22; CMD-100's 019 blocks reads too |
| admin_viewer | no write | refused |
| another org / patient / anon | no | refused (`NOT_FOUND` / `FORBIDDEN`; EXECUTE revoked from anon) |

Out-of-scope rows return `NOT_FOUND`, not `FORBIDDEN`, so a caller can't probe ids in other branches or orgs. This matches 012.

### 3.1 `consultation_record_consent(p_consultation uuid, p_answer text, p_device text, p_script text) → jsonb`
- Validates the answer (`agreed`/`declined`), the device (`computer`/`phone`) and the script (`^[a-z0-9-]{3,40}$`).
- If `recording_consent` is already set: the same answer returns ok with `already_recorded: true` and changes nothing. That is how
  two devices ticking at once both succeed. A different answer returns `CONSENT_ALREADY_RECORDED`.
- Refused on a signed row (`SIGNED_LOCKED`).
- Audited: action `consultation.record_consent`. **Deviation 2 (small):** the brief gives `(p_consultation, p_answer, p_device)`.
  I add `p_script` because the column needs a value and the only party that knows which words were shown is the client.

### 3.2 `consultation_sign(p_consultation uuid, p_expected_drafted_at timestamptz DEFAULT NULL) → jsonb`
- Refuses an already signed row (`ALREADY_SIGNED`) and an empty `final_summary` (`NOTE_EMPTY`). Consent is **not** required to
  sign: a visit with no recording can be signed.
- `p_expected_drafted_at`: the `ai_drafted_at` the client last saw. If the row's value differs, it refuses `AI_DRAFT_CHANGED`.
  This covers a race: a late AI draft (the existing "arrived after you saved" case, `index.jsx:507`) is stored between the client's
  field save and its sign call. Without this check, `edited_sections` would be compared against a draft the doctor never saw.
- Sets `status='completed'`, `signed_at=now()`, `signed_by=auth.uid()`, `signed_by_name=users.full_name`, and
  `edited_sections = _consult_edited_sections(final_summary, ai_draft, note_template)`.
- `_consult_edited_sections` (IMMUTABLE SQL): splits `final_summary` on the template's exact `## ` headings (for v1 the same
  six-heading regex as `STRICT_LINE` in `consultationNote.js:39`), unescapes `\#`, trims, and compares each key with the
  trimmed `ai_draft` value. It returns the keys that differ. An unknown template, or text without the strict headings, gives null.
  A null `ai_draft` also gives null ("Written by"). Vitest and SQL share one fixture table, so JS and SQL can't drift.
- Audited: `consultation.sign`. The inputs hold ids only. **No note text goes into `action_log`**: staff can read
  `action_log` rows in their branch (012 `action_log_read`).

### 3.3 `consultation_unsign(p_consultation uuid) → jsonb`
- Only `signed_by = auth.uid()` and `now() - signed_at <= 15 min`. Otherwise `UNSIGN_NOT_ALLOWED`, with the reason
  (`not the signer` / `window passed`).
- Clears `signed_*` and `edited_sections`, sets `status='draft'`, and keeps `ai_*`, sources and consent.
- Audited: `consultation.unsign`. I don't use `act_undo`: its dispatcher and its 24 h window are booking-shaped. A separate action
  keeps the board's 15-minute "Undo" rule in one place.

### 3.4 Service-role-only writers (EXECUTE granted to `service_role` only, revoked from everyone else)
- `consultation_store_segments(p_consultation, p_user, p_audio_path, p_segments jsonb)`: replaces that recording's segments
  (idempotent on `audio_path`, so a retried transcription doesn't duplicate). Refused on a signed row.
- `consultation_store_draft(p_consultation, p_user, p_note jsonb, p_provider, p_model, p_inputs text[], p_sources jsonb)`:
  sets `ai_*` and `note_sources`, and returns `ai_drafted_at`. Refused on a signed row.
- `consultation_retention_due(p_limit int)` and `consultation_mark_audio_deleted(p_consultation, p_deleted_paths text[])`: see §6.
- Each one re-checks that `p_user` is an active user of the row's org with an allowed role. The edge function first reads the row
  **through the user's own client**, so RLS (006, 011, and 019 once it lands) proves the user can see it. Only then does it call
  the writer with the service role.

**Deviation 3 (the main one; asking the lead): the server stores the draft and sources, not the client.** The brief has the client
call `consultation_store_draft(...)`. If a signed-in user could call that function, any practitioner could write an "AI drafted"
record with made-up `ai_draft` or `note_sources`. That defeats §3.3 ("a source is never invented") and acceptance 3. So
`consultation-summarize` stores them itself, from the same model response it returns to the client. That meets "the note text and
`ai_draft` come from the same response" by construction. The client still writes the note text (`final_summary`) as today and gets
`drafted_at` back for §3.2. If the lead prefers the brief's client-call version, I'd need a signed token from summarize to stop
forgery, which is more code for the same result.

### 3.5 Action layer choice
I use 012's `_act_resolve`, `_act_finish` (`p_table='consultations'`, undo NULL) for record_consent, sign and unsign: one
transaction for check, change and the `action_log` row, the same `{ok, action_id, data, error}` envelope as every other action,
and the 016 service-role rules. I keep the brief's function names (`consultation_record_consent`, not `act_...`), so the names in
the brief and the tests stay true. The `action` value is `consultation.record_consent` / `.sign` / `.unsign`.
The service-role writers are **not** actions. They are internal plumbing for the edge functions. `ai_spend` (016) already records
each model call, and the provenance columns are the record of the draft.

## 4. Edge functions

**`consultation-transcribe`:** the body adds an optional `consultationId`.
- With `CONSULT_REQUIRE_CONSENT=true`: no `consultationId`, a row the user can't read, a row whose `booking_id` is not the booking
  in `audioPath` (`<org>/<booking>/<file>`, as `consultation_object_booking` reads it), or `recording_consent <> 'agreed'` →
  `403 {error:'CONSENT_REQUIRED'}`. This is checked **before** the quota is used and before the download.
- Flag off (default): the same checks run, but only to decide whether to store segments. Old clients (no id) get today's
  behaviour unchanged.
- After whisper: stores `result.segments` as `{audio_path, start, end, text}` through `consultation_store_segments`, and returns
  `{text, language, segments_stored}`.

**`consultation-summarize`, mode `note`:** the body adds `consultationId` and the function reads the row as the user.
- `note_template` picks the prompt and the JSON schema from a template map. `dental-v1` = today's six fields, plus a per-section
  `sources: [{quote}]` array in the strict schema. An unknown template → `400 UNKNOWN_TEMPLATE`.
- Source filter (pure function in `_shared/sources.ts`, unit tested): normalise case and whitespace, then search each recording's
  joined segment text. If not found → dropped. If found → `start`/`audio_path` are **taken from the matching segment**, never from
  the model. `{image:'xray'|'photo'}` is kept only if that input was actually sent.
- Stores the result through `consultation_store_draft` and returns
  `{note, provenance:{provider, model, inputs, drafted_at}, sources}`. If the store fails, the note is still returned with
  `provenance: null` and the error is logged. Clinical work is never blocked (same stance as the quota check).
- No `consultationId` (old client): today's behaviour, nothing stored.

**Q1 for the lead: staff in the edge functions.** `authenticate({requireStaff})` still lets `staff` transcribe and summarize. I
won't change that here (CMD-100 owns the front-desk rule, and a dentist logged in as staff would lose the Scribe). But the
service-role writers refuse staff, so a staff user's draft is returned without provenance. Is that right, or should the edge
functions refuse staff now?

**`CONSULT_REQUIRE_CONSENT` can be turned on when:** (1) 020 and this client are live; (2) a human has checked on prod that
consultations started after the deploy have `recording_consent` set from **both** `computer` and `phone`; (3) no in-flight draft
from before the deploy is still recording. Point (3) is the old-bundle case: a tab opened before the deploy sends no
`consultationId`. In practice that means one clinic day after the deploy. The hand-off will say this.

## 5. Consent wiring (current screens, no redesign)

**Desktop:** `index.jsx:447` `const [consent, setConsent] = useState(false)` becomes a value derived from the row
(`row.recording_consent === 'agreed'`), loaded with the consultation at `index.jsx:226`, and kept live by the existing realtime
subscription (`api.js subscribeToConsultation`). `RecorderBar.jsx:77,93`: ticking the box calls
`recordConsultationConsent(id, 'agreed', 'computer', script)` (new, `api.js`). Once stored, the box shows checked and disabled,
with plain text "Agreed 10:42" next to it. Unticking is no longer possible: consent is recorded once (brief). The current screen
has no "declined" control, so this part can only store `agreed`. `declined` is in the schema for the redesign.

**Phone (finding: it does NOT ask today).** `DoctorPhone.jsx` renders `ConsultationPage` with the phone view (`DoctorPhone.jsx:207`).
The phone view's record button (`index.jsx:821-826`) and the pending-start button (`index.jsx:815-818`) have no consent gate. The
remote "start" command (`index.jsx:353-357`) starts the phone microphone with no check either. Only the desktop's
"Record on phone" button is gated (`RecorderBar.jsx:95`). A doctor who opens the patient from a phone notification, or from the
phone's "tap to record" list (`DoctorPhone.jsx:282`), records with no consent today.
Wiring (the smallest change, same styles): in the phone view, when the stored consent is not `agreed`, the record button area shows
the same checkbox line as the desktop ("<first name> has agreed to this visit being recorded"), calling the function with
`device='phone'`. The record buttons are disabled until it is stored. A remote `start` command is ignored while consent is not
stored, and the phone shows the checkbox instead. This adds one control to the phone. The brief says "no redesign"; I read this as
wiring, but the lead should confirm (**Q2**).

**Save / sign wiring:** `handleSave` (`index.jsx:411`) → `saveConsultation` keeps writing the fields with the row's current status.
It then calls `signConsultation(id, lastDraftedAt)` instead of setting `status:'completed'`. The treatment-notes copy
(`api.js` after the save) runs after a successful sign. "Edit note" (`index.jsx:644`) on a signed row: if the signer is within
15 min, it calls `consultation_unsign` and continues as today. Otherwise it shows plain text: "Signed notes can't be changed.
Corrections need an addendum (coming)." The provenance line, after reload, from the stored columns: "AI drafted, reviewed by <name>"
or "Written by <name>". Nothing for a row with no `signed_at`.

## 6. Retention scheduling

- `consultation_kick_retention()`: SECURITY DEFINER, the same pattern as `agent_kick_runner` (017). It reads `function_base_url`
  and `cron_bearer_token` from `private.outreach_function_config` and does nothing if that is missing. It calls
  `net.http_post(<base>/consultation-retention)` **only if** `consultation_retention_due(1)` returns a row.
- pg_cron job `consultation-retention`, daily at `30 21 * * *` UTC (03:15 Asia/Kathmandu, outside clinic hours). It is scheduled
  only if `cron` exists, with `cron.unschedule` first so it can be re-run (017 pattern).
- Edge function `consultation-retention`: bearer check with `safeEqual` against `CRON_BEARER_TOKEN` (the agent-run pattern), then a
  service-role client.
  - `consultation_retention_due(200)` returns `{id, audio_paths}` for rows where `signed_at < now() - interval '30 days'` and
    `audio_paths <> '{}'`. Unsigned rows are never returned.
  - For each row: `storage.from('consultation-audio').remove(paths)`, then `consultation_mark_audio_deleted(id, removed_paths)`.
    Only the paths the Storage API confirms are cleared. Failures stay and are retried the next night. `audio_deleted_at` is set
    when `audio_paths` becomes empty.
  - `{dry_run:true}` returns `{would_delete:[{id, paths}]}` and changes nothing. The log holds ids and counts, never paths or names.

## 7. Rollback (`migration-020-rollback.sql`)

Unschedule `consultation-retention`. Drop the kick function, the trigger, `_consult_edited_sections` and the seven new functions,
the index and the new columns. Consent, provenance, segments and sources are lost, so export them first (a read-only `SELECT`
is listed at the top of the file). It touches nothing 019 adds, so it restores 018 or 019.
**Order: revert the client and edge functions first, then run the SQL rollback.** New client code calls the new functions. The
current `main` code writes none of the new columns, so it runs on a rolled-back schema (acceptance 7 is tested on local with
today's code).
There is also a read-only `migration-020-preflight.sql` for a human on prod: users with role `staff` who created or attended a
consultation in the last 90 days (brief §9). Any such dentist must move to `practitioner` before 020, or they lose sign and consent.

## 8. Tests (adds to the brief's §6)

- **Vitest:** `markdownToNote(md, template)` gives v1 output unchanged on today's fixtures plus legacy rows. Source filter: an
  invented quote is dropped, a real quote gets the segment's own `start`/`audio_path`, an image source is kept only with its
  input. `editedSections` fixtures (shared with SQL).
- **SQL** (`tenant-isolation.sql` section `3i. CONSULTATION GROUNDWORK (020)`, skipped if 020 isn't applied):
  - other org, staff, admin_viewer and a practitioner on someone else's booking can't record consent, sign or unsign;
  - a second consent with another answer is refused, the same answer is idempotent;
  - a client PATCH of `signed_at`, `ai_draft`, `recording_consent` or `note_sources` is refused (rule A);
  - a signed row can't be changed as authenticated or service_role (rule B), except retention's audio fields;
  - unsign works for the signer at 14 min, not at 16 min, and not for another user;
  - a pre-020 completed row is still editable;
  - the service-role writers are not executable by `authenticated`.
  - Run order: 001-018 + 020, and with 019 once CMD-100 has one.
- **Edge functions** (local `supabase functions serve`, fake OpenAI via an `OPENAI_BASE_URL` override, **new** env, default
  `https://api.openai.com`): transcribe stores segments; consent is refused with the flag on; summarize returns provenance with
  filtered sources; retention dry-run and real run on 31-day, 29-day and draft rows.

## 9. Not verified / open

- Q1 (staff in the edge functions), Q2 (adding the checkbox to the phone counts as wiring), and Deviations 1-3 need the lead's answer.
- Who signs on prod today (role of the Bright Smile dentists): not traced. Preflight query above, to be run by a human.
- `current_user` behaviour in a trigger fired from a SECURITY DEFINER function: this is standard Postgres, but I'll prove it in
  the SQL tests before relying on it.
- `OPENAI_BASE_URL` is a new env for testing only. The prod default is unchanged. Not built yet.
- The merged `tenant-isolation.sql` has not been run on local yet.
- Follow-ups for the hand-off (not built here): an addendum feature for signed notes; a ruling on whether only the attending
  practitioner may sign; a per-org retention setting; a `declined` control in the redesign.
