// Friendly text for a failed AI function call (shown on the consultation page, next to Retry). `status` is the HTTP status of the
// function's response when there was one (supabase-js puts the Response on `error.context`); `payload` its JSON body, if any.
export function consultationAiError(status, payload) {
  if (payload?.error === 'AI_KEY_MISSING') {
    return { code: 'AI_KEY_MISSING', message: "AI isn't set up for this clinic yet. You can still type the transcript and notes." };
  }
  if (payload?.error === 'AI_QUOTA') return { code: 'AI_QUOTA', message: 'Too many AI requests this hour. Try again later, or write the note yourself.' };
  if (payload?.error === 'AI_DISABLED') return { code: 'AI_DISABLED', message: "AI consultation isn't switched on for this clinic. You can still type the transcript and notes." };
  if (payload?.error === 'FORBIDDEN') return { code: 'FORBIDDEN', message: 'Your account cannot use consultation AI.' };
  if (payload?.error === 'FORBIDDEN_ROLE') return { code: 'FORBIDDEN_ROLE', message: 'Front desk accounts can’t use the consultation scribe. Ask a dentist or manager.' };
  if (payload?.error === 'CONSENT_REQUIRED') return { code: 'CONSENT_REQUIRED', message: 'Record that the patient agreed to the recording first. Your recording is saved.' };
  if (payload?.error === 'UNKNOWN_TEMPLATE') return { code: 'UNKNOWN_TEMPLATE', message: "This note's format isn't supported by the AI yet. Write the note yourself." };
  if (payload?.error === 'FILE_TOO_LARGE') return { code: 'FILE_TOO_LARGE', message: 'That recording is too large to transcribe. Record in shorter parts.' };
  // 404 / no response at all: the function isn't deployed or the network is down
  if (status === 404 || status == null || status === 0 || status === 502 || status === 503 || status === 504) {
    return { code: 'AI_UNAVAILABLE', message: "The AI service isn't available right now. Your recording is saved; try again later." };
  }
  return { code: 'AI_FAILED', message: "Couldn't process this. Your recording is saved; try again." };
}

/** The AI answered (200) but the note has no clinical content: not a failure, nothing was said. Redrafting the same transcript gives the same result. */
export const NO_SPEECH_ERROR = { code: 'NO_SPEECH', message: 'No clinical details were heard in the recording.' };

/** Why a draft is unusable: a real AI error wins; a 200 with an empty/missing note is NO_SPEECH only when the call succeeded. */
export const draftFailure = (aiError, drafted, empty) =>
  aiError || (!drafted ? { code: 'AI_FAILED', message: "The AI didn't return a note. Your recording is saved; try again." } : empty ? NO_SPEECH_ERROR : null);
