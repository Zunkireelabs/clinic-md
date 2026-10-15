import { describe, it, expect } from 'vitest';
import { newQueueItem, enqueue, update, remove, hasUnuploaded, failedItems, hasUploadFailure, isBusy, seedTranscribed, untranscribedPaths, readTranscribed, writeTranscribed } from './recordingQueue';

const blob = { size: 10 };
const mem = () => { const m = new Map(); return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, v) }; };

describe('recording queue', () => {
  it('keeps several failed recordings (no single slot that a second failure overwrites)', () => {
    let q = enqueue([], newQueueItem({ blob, mimeType: 'audio/webm', durationSeconds: 60 }));
    q = enqueue(q, newQueueItem({ blob, mimeType: 'audio/webm', durationSeconds: 30 }));
    q = update(q, q[0].id, { status: 'failed-upload' });
    q = update(q, q[1].id, { status: 'failed-upload' });
    expect(failedItems(q)).toHaveLength(2);
    expect(hasUploadFailure(q)).toBe(true);
  });
  it('leave guard stays on while any blob is un-uploaded, and goes off once uploaded (even if transcription failed)', () => {
    let q = enqueue([], newQueueItem({ blob, mimeType: 'audio/webm', durationSeconds: 5 }));
    expect(hasUnuploaded(q)).toBe(true);
    q = update(q, q[0].id, { audioPath: 'org/b/x.webm', status: 'failed-transcribe' });
    expect(hasUnuploaded(q)).toBe(false);
    expect(failedItems(q)).toHaveLength(1);
  });
  it('a retry after a transcription failure starts at transcribing, not uploading', () => {
    expect(newQueueItem({ blob, mimeType: 'audio/webm', durationSeconds: 5, audioPath: 'p' }).status).toBe('transcribing');
  });
  it('isBusy and remove', () => {
    const it1 = newQueueItem({ blob, mimeType: 'a', durationSeconds: 1 });
    expect(isBusy([it1])).toBe(true);
    expect(remove([it1], it1.id)).toEqual([]);
  });
});

describe('per-path transcription tracking', () => {
  it('seeds from an existing transcript, else nothing is transcribed', () => {
    expect(seedTranscribed(['a', 'b'], 'hello')).toEqual(['a', 'b']);
    expect(seedTranscribed(['a', 'b'], '  ')).toEqual([]);
  });
  it('lists every audio path not yet transcribed (all failed ones, not just the last)', () => {
    expect(untranscribedPaths(['a', 'b', 'c'], ['b'])).toEqual(['a', 'c']);
    expect(untranscribedPaths(['a'], null)).toEqual(['a']);
  });
  it('persists across a reload', () => {
    const s = mem();
    expect(readTranscribed('c1', s)).toBeNull();
    writeTranscribed('c1', ['a', 'a', 'b'], s);
    expect(readTranscribed('c1', s)).toEqual(['a', 'b']);
  });
});
