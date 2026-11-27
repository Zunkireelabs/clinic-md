// Live sync between devices (e.g. desktop + phone) editing the same
// consultation. Both devices read and write one DB row; a device keeps a
// "synced" snapshot of the last row state it saw so it can tell its own
// unsaved edits apart from changes made on the other device.

export const EMPTY_FORM = {
  transcript: '',
  language: null,
  durationSeconds: 0,
  audioPaths: [],
  preliminarySummary: '',
  xrayAnalysis: '',
  xrayPaths: [],
  photoAnalysis: '',
  photoPaths: [],
  additionalNotes: '',
  doctorNotes: '',
  finalSummary: '',
};

// form key -> consultations column
export const FIELD_COLUMNS = {
  transcript: 'transcript',
  language: 'detected_language',
  durationSeconds: 'recording_duration_seconds',
  audioPaths: 'audio_paths',
  preliminarySummary: 'preliminary_summary',
  xrayAnalysis: 'xray_analysis',
  xrayPaths: 'xray_image_paths',
  photoAnalysis: 'photo_analysis',
  photoPaths: 'photo_image_paths',
  additionalNotes: 'additional_notes',
  doctorNotes: 'doctor_notes',
  finalSummary: 'final_summary',
};

const ARRAY_KEYS = new Set(['audioPaths', 'xrayPaths', 'photoPaths']);
const TEXT_KEYS = new Set(['transcript', 'preliminarySummary', 'xrayAnalysis', 'photoAnalysis', 'additionalNotes', 'doctorNotes', 'finalSummary']);

export const formFromRow = (row) => {
  const form = { ...EMPTY_FORM };
  Object.entries(FIELD_COLUMNS).forEach(([key, column]) => {
    const value = row[column];
    if (ARRAY_KEYS.has(key)) form[key] = value || [];
    else if (TEXT_KEYS.has(key)) form[key] = value || '';
    else if (key === 'durationSeconds') form[key] = value || 0;
    else form[key] = value ?? null;
  });
  return form;
};

const same = (a, b) => (Array.isArray(a) || Array.isArray(b)
  ? JSON.stringify(a || []) === JSON.stringify(b || [])
  : (a ?? '') === (b ?? ''));

/** Form keys whose value differs between two form objects. */
export const changedKeys = (a, b) => Object.keys(FIELD_COLUMNS).filter((k) => !same(a[k], b[k]));

/** Column payload for just the fields this device changed since the last sync. */
export const columnsForChanges = (form, synced) => {
  const out = {};
  changedKeys(form, synced).forEach((k) => {
    const v = form[k];
    out[FIELD_COLUMNS[k]] = ARRAY_KEYS.has(k) ? v : (TEXT_KEYS.has(k) ? (v || null) : (v || null));
  });
  return out;
};

/**
 * The transcript only ever grows on the server (recordings are APPENDED by consultation_add_transcript_piece). If this device has typed in
 * it since `synced`, keep what was typed and add what the server appended since, so the next autosave cannot wipe the new piece.
 * Anything else (the other side rewrote the text) keeps ours, as before. CMD-146.
 */
export const rebaseText = (local, synced, remote) => {
  if (remote === synced || !String(remote).startsWith(synced)) return local;
  const suffix = String(remote).slice(synced.length);
  return local + (suffix.startsWith('\n') || !String(local).trim() ? '' : '\n\n') + suffix;
};

/** Audio paths whose words are already in the transcript (migration 023). */
// shortcut: a legacy piece (path null, from the backfill) is assumed to cover every recording the row had; a recording that was uploaded
// but never transcribed across the migration deploy would not be offered for retry. Upgrade if that ever shows up.
export const transcribedPaths = (row) => {
  const pieces = row?.transcript_pieces || [];
  return pieces.some((x) => !x.path) ? [...new Set([...(row.audio_paths || []), ...pieces.map((x) => x.path).filter(Boolean)])] : pieces.map((x) => x.path);
};

/**
 * Apply a row update that arrived from the other device. For each field:
 * - this device has not edited it since the last sync -> take the remote value
 * - this device has unsaved edits to it -> keep ours (they are saved next)
 * Returns the new form and the new synced snapshot (always the remote state).
 */
export const mergeRemote = (local, synced, remoteRow) => {
  const remote = formFromRow(remoteRow);
  const form = { ...local };
  Object.keys(FIELD_COLUMNS).forEach((k) => {
    const locallyEdited = !same(local[k], synced[k]);
    if (!locallyEdited) form[k] = remote[k];
    else if (k === 'transcript') form[k] = rebaseText(local[k], synced[k], remote[k]);
    // Two devices may each have added an X-ray/photo/recording: keep both (the remote ones first), never drop either side's.
    else if (ARRAY_KEYS.has(k)) form[k] = [...(remote[k] || []), ...(local[k] || []).filter((p) => !(remote[k] || []).includes(p))];
  });
  return { form, synced: remote };
};

/**
 * After a save returns: take the saved row for every field the user did NOT touch while the request was in flight, and keep
 * anything they typed meanwhile (so edits made during the save are never wiped). `sent` is the form as it was when Save was pressed.
 */
export const mergeAfterSave = (sent, current, rowForm) => {
  const form = { ...rowForm };
  Object.keys(FIELD_COLUMNS).forEach((k) => { if (!same(current[k], sent[k])) form[k] = current[k]; });
  return form;
};

/** Every column from the form, for a full save (empty text becomes null). */
export const allColumns = (form) => {
  const out = {};
  Object.entries(FIELD_COLUMNS).forEach(([k, column]) => {
    const v = form[k];
    out[column] = ARRAY_KEYS.has(k) ? (v || []) : (v || null);
  });
  return out;
};

/**
 * After consultation_add_transcript_piece returns { transcript, language }: the server's text is the new synced state. If this device has
 * typed in the transcript meanwhile, keep that and add the appended words (rebaseText); otherwise show the server's text. Both the form
 * and the synced snapshot move, so the autosave sees no difference and cannot send a stale transcript back. CMD-146.
 */
export const applyAppended = (form, synced, data) => {
  const language = data.language ?? null;
  const nextSynced = { ...synced, transcript: data.transcript || '', language: language ?? synced.language };
  const edited = form.transcript !== synced.transcript;
  return {
    form: { ...form, transcript: edited ? rebaseText(form.transcript, synced.transcript, data.transcript || '') : (data.transcript || ''), language: language ?? form.language },
    synced: nextSynced,
  };
};
