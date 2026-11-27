import { describe, it, expect } from 'vitest';
import { EMPTY_FORM, formFromRow, columnsForChanges, mergeRemote, changedKeys, mergeAfterSave } from './consultationSync';

const row = (over = {}) => ({
  transcript: null, detected_language: null, recording_duration_seconds: null, audio_paths: [],
  preliminary_summary: null, xray_analysis: null, xray_image_paths: [], photo_analysis: null,
  photo_image_paths: [], additional_notes: null, doctor_notes: null, final_summary: null, ...over,
});

describe('formFromRow', () => {
  it('turns nulls into empty form values', () => {
    expect(formFromRow(row())).toEqual(EMPTY_FORM);
  });
});

describe('columnsForChanges', () => {
  it('sends only the fields this device changed', () => {
    const synced = formFromRow(row({ transcript: 'hello' }));
    const form = { ...synced, doctorNotes: 'check 36', xrayPaths: ['a.png'] };
    expect(columnsForChanges(form, synced)).toEqual({ doctor_notes: 'check 36', xray_image_paths: ['a.png'] });
  });

  it('sends nothing when nothing changed', () => {
    const synced = formFromRow(row({ transcript: 'x' }));
    expect(columnsForChanges({ ...synced }, synced)).toEqual({});
  });

  it('clears a field emptied locally', () => {
    const synced = formFromRow(row({ doctor_notes: 'abc' }));
    expect(columnsForChanges({ ...synced, doctorNotes: '' }, synced)).toEqual({ doctor_notes: null });
  });
});

describe('mergeRemote', () => {
  it('takes remote changes for fields the device has not edited', () => {
    const synced = formFromRow(row());
    const local = { ...synced };
    const { form, synced: next } = mergeRemote(local, synced, row({ transcript: 'from phone', audio_paths: ['a.webm'] }));
    expect(form.transcript).toBe('from phone');
    expect(form.audioPaths).toEqual(['a.webm']);
    expect(next.transcript).toBe('from phone');
  });

  it('keeps unsaved local edits and still takes other remote fields', () => {
    const synced = formFromRow(row({ doctor_notes: 'old' }));
    const local = { ...synced, doctorNotes: 'typing on desktop' };
    const { form } = mergeRemote(local, synced, row({ doctor_notes: 'old', xray_analysis: 'phone xray' }));
    expect(form.doctorNotes).toBe('typing on desktop');
    expect(form.xrayAnalysis).toBe('phone xray');
  });

  it('after merging, the local edit is still seen as a pending change', () => {
    const synced = formFromRow(row());
    const local = { ...synced, doctorNotes: 'mine' };
    const merged = mergeRemote(local, synced, row({ transcript: 'phone' }));
    expect(changedKeys(merged.form, merged.synced)).toEqual(['doctorNotes']);
  });
});

describe('mergeRemote: array fields are unioned', () => {
  it('keeps an X-ray added here AND one added on the other device', () => {
    const synced = formFromRow(row({ xray_image_paths: ['a.png'] }));
    const local = { ...synced, xrayPaths: ['a.png', 'local.png'] };
    const { form } = mergeRemote(local, synced, row({ xray_image_paths: ['a.png', 'phone.png'] }));
    expect(form.xrayPaths).toEqual(['a.png', 'phone.png', 'local.png']);
  });
  it('does not duplicate a path both sides have', () => {
    const synced = formFromRow(row());
    const local = { ...synced, photoPaths: ['p.png'] };
    expect(mergeRemote(local, synced, row({ photo_image_paths: ['p.png'] })).form.photoPaths).toEqual(['p.png']);
  });
});

describe('mergeAfterSave', () => {
  it('takes the saved row but keeps what was typed while the save was in flight', () => {
    const sent = { ...EMPTY_FORM, finalSummary: 'v1', additionalNotes: 'a' };
    const current = { ...sent, additionalNotes: 'a, typed during save' };
    const saved = formFromRow(row({ final_summary: 'v1', additional_notes: 'a' }));
    const merged = mergeAfterSave(sent, current, saved);
    expect(merged.additionalNotes).toBe('a, typed during save');
    expect(merged.finalSummary).toBe('v1');
  });
  it('with no edits during the save the form simply becomes the saved row', () => {
    const sent = { ...EMPTY_FORM, transcript: 't' };
    const saved = formFromRow(row({ transcript: 't', detected_language: 'Nepali' }));
    expect(mergeAfterSave(sent, { ...sent }, saved)).toEqual(saved);
  });
});

// ── CMD-146: the transcript is appended on the server; the client must never send an older one back ──────────────────────────────
import { applyAppended, rebaseText, transcribedPaths, columnsForChanges as colsFor, mergeRemote as mergeR, formFromRow as formFrom } from './consultationSync';

describe('transcript appended by the server (CMD-146)', () => {
  const synced = { ...EMPTY_FORM, transcript: 'one' };
  it('append, then autosave, does not revert: nothing to send for the transcript', () => {
    const { form, synced: s2 } = applyAppended(synced, synced, { transcript: 'one\n\ntwo', language: 'en' });
    expect(form.transcript).toBe('one\n\ntwo');
    expect(colsFor(form, s2).transcript).toBeUndefined();
  });
  it('typed text since the last sync is kept and the appended words are added, so the autosave cannot wipe the piece', () => {
    const typed = { ...synced, transcript: 'one (typed)' };
    const { form, synced: s2 } = applyAppended(typed, synced, { transcript: 'one\n\ntwo', language: 'en' });
    expect(form.transcript).toBe('one (typed)\n\ntwo');
    expect(colsFor(form, s2).transcript).toBe('one (typed)\n\ntwo');
  });
  it('an append from the other device (realtime) while this one has typed text', () => {
    const typed = { ...synced, transcript: 'one (typed)' };
    const row = { transcript: 'one\n\nphone words' };
    const { form, synced: s2 } = mergeR(typed, synced, row);
    expect(form.transcript).toBe('one (typed)\n\nphone words');
    expect(s2.transcript).toBe('one\n\nphone words');
  });
  it('an append from the other device with nothing typed here simply takes the new text', () => {
    expect(mergeR(synced, synced, { transcript: 'one\n\nphone words' }).form.transcript).toBe('one\n\nphone words');
  });
  it('a rewrite (not a pure append) keeps ours; an empty start joins cleanly', () => {
    expect(rebaseText('mine', 'one', 'totally new')).toBe('mine');
    expect(rebaseText('typed', '', 'words')).toBe('typed\n\nwords');
    expect(rebaseText('x', 'a', 'a')).toBe('x');
  });
  it('N recordings -> N pieces: which paths count as transcribed comes from the pieces', () => {
    const row = { audio_paths: ['p1', 'p2'], transcript_pieces: [{ path: 'p1' }, { path: 'p2' }] };
    expect(transcribedPaths(row)).toEqual(['p1', 'p2']);
    expect(transcribedPaths({ audio_paths: ['p1', 'p2'], transcript_pieces: [{ path: 'p1' }] })).toEqual(['p1']);
    expect(transcribedPaths({ audio_paths: ['p1', 'p2'], transcript_pieces: [] })).toEqual([]);
  });
  it('a legacy piece (path null, from the backfill) counts every recording the row had as transcribed', () => {
    expect(transcribedPaths({ audio_paths: ['p1', 'p2'], transcript_pieces: [{ path: null, text: 'old' }] }).sort()).toEqual(['p1', 'p2']);
  });
  it('the form never carries transcript_pieces, so it is never written back', () => {
    expect(Object.keys(formFrom({ transcript_pieces: [{ path: 'p1' }] }))).not.toContain('transcript_pieces');
  });
  it('realtime row first, RPC answer second: no difference is left for the autosave (the order seen on a real run)', () => {
    const start = { ...EMPTY_FORM };
    const rt = mergeR(start, start, { transcript: 'words', detected_language: 'en' });
    const { form, synced: s2 } = applyAppended(rt.form, rt.synced, { transcript: 'words', language: 'en' });
    expect(colsFor(form, s2)).toEqual({});
  });
});
