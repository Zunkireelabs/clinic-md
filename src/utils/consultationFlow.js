// The consultation page's AI pipeline as a pure state machine, plus the stage the page shows.
//
//   record → (upload) → transcribe → draft the note → review → save to chart → (complete visit)
//
// The reducer only tracks what really happened (nothing is claimed that the backend didn't do). `deriveStage` turns it, together
// with live facts (recording now? any note text? saved?), into one of the six screens:
//   ready · recording · drafting · review · noai · saved

export const initialFlow = {
  step: 'idle',        // 'idle' | 'uploading' | 'transcribing' | 'drafting'
  recorded: null,      // seconds of the recording that was saved this round, once uploaded
  transcribed: null,   // detected language once transcribed ('' when unknown)
  aiError: null,       // { code, message } of the last failed AI step; the recording is always kept
  failedAt: null,      // which step failed: 'transcribing' | 'drafting'
  manual: false,       // the doctor chose to write the note themselves
  aiDrafted: false,    // an AI draft produced the note this session
  draftedAt: null,     // Date of the last successful draft
  draftSources: null,  // { recordings, language, xrays, photos } the last draft was written from
  draftInputs: null,   // snapshot (string) of what the draft was generated from: transcript + X-ray/photo analyses
  editing: false,      // saved note reopened for editing
};

export function flowReducer(state, event) {
  switch (event.type) {
    case 'UPLOAD_START': return { ...state, step: 'uploading', recorded: null, transcribed: null, aiError: null, failedAt: null };
    case 'UPLOADED': return { ...state, step: 'transcribing', recorded: event.seconds ?? 0 };
    case 'TRANSCRIBE_START': return { ...state, step: 'transcribing', aiError: null, failedAt: null };
    case 'TRANSCRIBED': return { ...state, step: 'drafting', transcribed: event.language || '' };
    case 'DRAFT_START': return { ...state, step: 'drafting', aiError: null, failedAt: null };
    case 'DRAFTED': return { ...state, step: 'idle', aiDrafted: true, manual: false, aiError: null, failedAt: null, draftedAt: event.at || null, draftSources: event.sources || null, draftInputs: event.inputs ?? null };
    // Transcribed but not drafted (e.g. recording more after a draft exists): the draft is offered, not forced.
    case 'TRANSCRIPT_ONLY': return { ...state, step: 'idle', transcribed: event.language || state.transcribed || '' };
    case 'FAILED': return { ...state, step: 'idle', aiError: event.error || { code: 'AI_FAILED' }, failedAt: event.at || state.step };
    case 'UPLOAD_FAILED': return { ...state, step: 'idle', aiError: event.error || { code: 'UPLOAD_FAILED' }, failedAt: 'uploading' };
    case 'WRITE_MYSELF': return { ...state, manual: true, aiError: null, failedAt: null };
    case 'SAVED': return { ...state, editing: false, aiError: null };
    case 'EDIT_NOTE': return { ...state, editing: true };
    case 'RESET': return { ...initialFlow };
    default: return state;
  }
}

/**
 * @param {object} flow   flowReducer state
 * @param {object} live   { recording: boolean (this device or the phone), hasNote: boolean, saved: boolean (consultation completed in the DB) }
 * @returns {'ready'|'recording'|'drafting'|'review'|'noai'|'saved'}
 */
export function deriveStage(flow, live) {
  if (live.recording) return 'recording';
  if (flow.step !== 'idle') return 'drafting';
  if (live.saved && !flow.editing && live.hasNote) return 'saved';
  if (live.hasNote) return 'review';
  if (flow.aiError || flow.manual) return 'noai';
  return 'ready';
}

/** A stable snapshot of the material a draft is written from (private notes are never part of it). */
export const draftInputsKey = ({ transcript = '', xrayAnalysis = '', photoAnalysis = '' } = {}) =>
  JSON.stringify([String(transcript).trim(), String(xrayAnalysis).trim(), String(photoAnalysis).trim()]);

/**
 * "Update the draft" is offered only when the inputs changed AFTER the last AI draft was generated (more recording, new analysis).
 * Never without a draft from this session, and never while the note is saved and read-only.
 */
export const draftIsStale = (flow, currentInputsKey, { readOnly = false } = {}) =>
  !readOnly && flow.aiDrafted && flow.draftInputs != null && flow.draftInputs !== currentInputsKey;

/** The banner only appears when the AI failed; choosing "write it yourself" shows the same empty sections without it. */
export const showNoAiBanner = (flow, hasNote) => !!flow.aiError && !hasNote;

/** The three honest steps shown while drafting: [{ key, label, state: 'done'|'active'|'todo' }]. */
export function draftingSteps(flow, { sources = '' } = {}) {
  const order = ['uploading', 'transcribing', 'drafting'];
  const at = order.indexOf(flow.step);
  const state = (i) => (at < 0 || i < at ? 'done' : i === at ? 'active' : 'todo');
  const mmss = (s) => `${String(Math.floor((s || 0) / 60)).padStart(2, '0')}:${String((s || 0) % 60).padStart(2, '0')}`;
  return [
    { key: 'recorded', state: state(0), label: flow.recorded != null && state(0) === 'done' ? `Recording saved · ${mmss(flow.recorded)}` : 'Saving the recording…' },
    { key: 'transcribed', state: state(1), label: state(1) === 'done' ? `Transcribed${flow.transcribed ? ` · ${flow.transcribed} detected` : ''}` : state(1) === 'active' ? 'Transcribing the recording…' : 'Transcribing' },
    { key: 'drafted', state: state(2), label: `Drafting the note from ${sources || 'the conversation'}` },
  ];
}
