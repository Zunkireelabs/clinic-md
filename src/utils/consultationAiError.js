// Friendly text for a failed AI function call (shown on the consultation page, next to Retry). `status` is the HTTP status of the
// function's response when there was one (supabase-js puts the Response on `error.context`); `payload` its JSON body, if any.
export function consultationAiError(status, payload) {
  if (payload?.error === 'AI_KEY_MISSING') {
    return { code: 'AI_KEY_MISSING', message: "AI isn't set up for this clinic yet. You can still type the transcript and notes." };
  }
  if (payload?.error === 'AI_QUOTA') return { code: 'AI_QUOTA', message: 'Too many AI requests this hour. Try again later, or write the note yourself.' };
  if (payload?.error === 'FORBIDDEN') return { code: 'FORBIDDEN', message: 'Your account cannot use consultation AI.' };
  if (payload?.error === 'FILE_TOO_LARGE') return { code: 'FILE_TOO_LARGE', message: 'That recording is too large to transcribe. Record in shorter parts.' };
  // 404 / no response at all: the function isn't deployed or the network is down
  if (status === 404 || status == null || status === 0 || status === 502 || status === 503 || status === 504) {
    return { code: 'AI_UNAVAILABLE', message: "The AI service isn't available right now. Your recording is saved; try again later." };
  }
  return { code: 'AI_FAILED', message: "Couldn't process this. Your recording is saved; try again." };
}
