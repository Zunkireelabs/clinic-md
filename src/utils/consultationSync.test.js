import { describe, it, expect } from 'vitest';
import { EMPTY_FORM, formFromRow, columnsForChanges, mergeRemote, changedKeys } from './consultationSync';

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
