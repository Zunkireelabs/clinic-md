// Recording-consent wording, by id. The id is what consultations.recording_consent_script stores (migration 020); the words live here, not in
// the row. The server accepts ONLY ids on its allow-list (public.consultation_record_consent, v_scripts): add a new id there in a migration
// before using it here, or recording consent fails with UNKNOWN_SCRIPT.
export const CONSENT_SCRIPTS = {
  'dental-en-ne-v1': {
    // The current screen's checkbox line (the read-aloud English/Nepali script comes with the redesigned page).
    checkbox: (firstName) => `${firstName} has agreed to this visit being recorded`,
  },
};

export const CURRENT_CONSENT_SCRIPT = 'dental-en-ne-v1';

/** "10:42" in the viewer's locale, for "Agreed 10:42" next to the stored consent. */
export const consentTime = (iso) => {
  if (!iso) return '';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
};
