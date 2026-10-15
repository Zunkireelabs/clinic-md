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
