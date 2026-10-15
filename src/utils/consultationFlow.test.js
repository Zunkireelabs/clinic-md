import { describe, it, expect } from 'vitest';
import { initialFlow, flowReducer, deriveStage, showNoAiBanner, draftingSteps, draftInputsKey, draftIsStale } from './consultationFlow';

const run = (events, from = initialFlow) => events.reduce(flowReducer, from);
const live = (o = {}) => ({ recording: false, hasNote: false, saved: false, ...o });

describe('flowReducer', () => {
  it('happy path: upload → transcribe → draft', () => {
    let s = run([{ type: 'UPLOAD_START' }]);
    expect(s.step).toBe('uploading');
    s = run([{ type: 'UPLOADED', seconds: 408 }], s);
    expect(s).toMatchObject({ step: 'transcribing', recorded: 408 });
    s = run([{ type: 'TRANSCRIBED', language: 'Nepali' }], s);
    expect(s).toMatchObject({ step: 'drafting', transcribed: 'Nepali' });
    const at = new Date();
    s = run([{ type: 'DRAFTED', at, sources: { recordings: 2 } }], s);
    expect(s).toMatchObject({ step: 'idle', aiDrafted: true, draftedAt: at, aiError: null });
  });
  it('a failure keeps what already happened and records where it failed', () => {
    const s = run([{ type: 'UPLOAD_START' }, { type: 'UPLOADED', seconds: 60 }, { type: 'FAILED', error: { code: 'AI_KEY_MISSING' }, at: 'transcribing' }]);
    expect(s).toMatchObject({ step: 'idle', recorded: 60, aiError: { code: 'AI_KEY_MISSING' }, failedAt: 'transcribing' });
  });
  it('retrying clears the error', () => {
    const s = run([{ type: 'FAILED', error: { code: 'AI_FAILED' }, at: 'drafting' }, { type: 'DRAFT_START' }]);
    expect(s).toMatchObject({ step: 'drafting', aiError: null, failedAt: null });
  });
  it('recording more after a draft only updates the transcript', () => {
    const s = run([{ type: 'DRAFTED' }, { type: 'UPLOAD_START' }, { type: 'UPLOADED', seconds: 30 }, { type: 'TRANSCRIPT_ONLY', language: 'Nepali' }]);
    expect(s).toMatchObject({ step: 'idle', aiDrafted: true, transcribed: 'Nepali' });
  });
  it('write-it-yourself clears the error banner state; save and edit toggle editing', () => {
    let s = run([{ type: 'FAILED', error: { code: 'AI_FAILED' } }, { type: 'WRITE_MYSELF' }]);
    expect(s).toMatchObject({ manual: true, aiError: null });
    s = run([{ type: 'EDIT_NOTE' }], s);
    expect(s.editing).toBe(true);
    expect(run([{ type: 'SAVED' }], s).editing).toBe(false);
    expect(run([{ type: 'RESET' }], s)).toEqual(initialFlow);
  });
});

describe('deriveStage', () => {
  it('ready with nothing', () => expect(deriveStage(initialFlow, live())).toBe('ready'));
  it('recording wins over everything', () => {
    expect(deriveStage({ ...initialFlow, step: 'drafting' }, live({ recording: true, hasNote: true }))).toBe('recording');
  });
  it('drafting while any async step is running', () => {
    ['uploading', 'transcribing', 'drafting'].forEach((step) => expect(deriveStage({ ...initialFlow, step }, live())).toBe('drafting'));
  });
  it('review when there is note text; saved only once completed and not editing', () => {
    expect(deriveStage(initialFlow, live({ hasNote: true }))).toBe('review');
    expect(deriveStage(initialFlow, live({ hasNote: true, saved: true }))).toBe('saved');
    expect(deriveStage({ ...initialFlow, editing: true }, live({ hasNote: true, saved: true }))).toBe('review');
  });
  it('noai after an AI failure or when writing it yourself, but only without a note', () => {
    expect(deriveStage({ ...initialFlow, aiError: { code: 'AI_FAILED' } }, live())).toBe('noai');
    expect(deriveStage({ ...initialFlow, manual: true }, live())).toBe('noai');
    expect(deriveStage({ ...initialFlow, aiError: { code: 'AI_FAILED' } }, live({ hasNote: true }))).toBe('review');
  });
  it('the banner shows for an AI failure, not for manual mode', () => {
    expect(showNoAiBanner({ ...initialFlow, aiError: { code: 'AI_KEY_MISSING' } }, false)).toBe(true);
    expect(showNoAiBanner({ ...initialFlow, manual: true }, false)).toBe(false);
    expect(showNoAiBanner({ ...initialFlow, aiError: { code: 'AI_FAILED' } }, true)).toBe(false);
  });
});

describe('draftingSteps', () => {
  it('reflects the real step with checkmarks', () => {
    const s = draftingSteps({ ...initialFlow, step: 'drafting', recorded: 408, transcribed: 'Nepali' }, { sources: 'the conversation, 2 X-rays and 1 photo' });
    expect(s.map((x) => x.state)).toEqual(['done', 'done', 'active']);
    expect(s[0].label).toBe('Recording saved · 06:48');
    expect(s[1].label).toBe('Transcribed · Nepali detected');
    expect(s[2].label).toBe('Drafting the note from the conversation, 2 X-rays and 1 photo');
  });
  it('while uploading or transcribing, later steps are not claimed', () => {
    expect(draftingSteps({ ...initialFlow, step: 'uploading' }).map((x) => x.state)).toEqual(['active', 'todo', 'todo']);
    expect(draftingSteps({ ...initialFlow, step: 'transcribing', recorded: 5 }).map((x) => x.state)).toEqual(['done', 'active', 'todo']);
  });
});

describe('draft staleness ("Update the draft")', () => {
  const inputs = { transcript: 'Hello', xrayAnalysis: 'caries', photoAnalysis: '' };
  const drafted = flowReducer(initialFlow, { type: 'DRAFTED', at: new Date(), inputs: draftInputsKey(inputs) });
  it('is not stale right after drafting (nothing changed)', () => {
    expect(draftIsStale(drafted, draftInputsKey(inputs))).toBe(false);
    expect(draftIsStale(drafted, draftInputsKey({ ...inputs, transcript: ' Hello ' }))).toBe(false); // whitespace only
  });
  it('is stale once the transcript or an analysis changes after the draft', () => {
    expect(draftIsStale(drafted, draftInputsKey({ ...inputs, transcript: 'Hello\n\nMore' }))).toBe(true);
    expect(draftIsStale(drafted, draftInputsKey({ ...inputs, photoAnalysis: 'stain' }))).toBe(true);
  });
  it('a redraft takes a fresh snapshot, so the offer goes away', () => {
    const more = { ...inputs, transcript: 'Hello more' };
    const redrafted = flowReducer(drafted, { type: 'DRAFTED', inputs: draftInputsKey(more) });
    expect(draftIsStale(redrafted, draftInputsKey(more))).toBe(false);
  });
  it('never when read-only (saved), without an AI draft, or without a snapshot', () => {
    expect(draftIsStale(drafted, draftInputsKey({ ...inputs, transcript: 'changed' }), { readOnly: true })).toBe(false);
    expect(draftIsStale(initialFlow, draftInputsKey(inputs))).toBe(false);
    expect(draftIsStale(flowReducer(initialFlow, { type: 'DRAFTED' }), draftInputsKey(inputs))).toBe(false);
  });
  it('private notes are not part of the key', () => {
    expect(draftInputsKey({ ...inputs, additionalNotes: 'private' })).toBe(draftInputsKey(inputs));
  });
});

describe('a draft arriving after Save', () => {
  it('DRAFT_DISCARDED returns to idle without marking the note as AI-drafted or changing the inputs snapshot', () => {
    const saved = flowReducer(flowReducer(initialFlow, { type: 'DRAFTED', inputs: 'k1' }), { type: 'SAVED' });
    const inFlight = flowReducer(saved, { type: 'DRAFT_START' });
    const after = flowReducer(inFlight, { type: 'DRAFT_DISCARDED' });
    expect(after.step).toBe('idle');
    expect(after.draftInputs).toBe('k1');
    expect(deriveStage(after, { recording: false, hasNote: true, saved: true })).toBe('saved');
  });
});
