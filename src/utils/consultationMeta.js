// What the server stored about a consultation's consent, AI draft and signature (migration 020, CMD-54/55). The page reads these from the row;
// it never writes them (the database refuses client writes to these columns). Timestamps stay strings: ai_drafted_at goes back to
// consultation_sign and must match to the microsecond.

export const EMPTY_META = {
  recording_consent: null, recording_consent_at: null, recording_consent_device: null,
  ai_drafted_at: null, has_ai_draft: false, signed_at: null, signed_by: null, signed_by_name: null, edited_sections: null, note_template: 'dental-v1',
};

export const metaFromRow = (row) => ({
  recording_consent: row?.recording_consent ?? null,
  recording_consent_at: row?.recording_consent_at ?? null,
  recording_consent_device: row?.recording_consent_device ?? null,
  ai_drafted_at: row?.ai_drafted_at ?? null,
  has_ai_draft: row?.ai_draft != null,
  signed_at: row?.signed_at ?? null,
  signed_by: row?.signed_by ?? null,
  signed_by_name: row?.signed_by_name ?? null,
  edited_sections: row?.edited_sections ?? null,
  note_template: row?.note_template ?? 'dental-v1',
});

export const UNSIGN_WINDOW_MS = 15 * 60 * 1000;

/** The signer may undo a signature within 15 minutes (the server enforces the same rule; this only decides what the page offers). */
export const canUnsign = (meta, userId, now = Date.now()) => {
  if (!meta?.signed_at || !userId || meta.signed_by !== userId) return false;
  const at = new Date(meta.signed_at).getTime();
  return Number.isFinite(at) && now - at <= UNSIGN_WINDOW_MS;
};

/** "AI drafted, reviewed by <name>" / "Written by <name>"; '' for a note that was never signed (every note from before 020). */
export const provenanceLine = (meta) => {
  if (!meta?.signed_at) return '';
  const name = meta.signed_by_name || 'a colleague';
  return meta.has_ai_draft || meta.ai_drafted_at ? `AI drafted, reviewed by ${name}` : `Written by ${name}`;
};
