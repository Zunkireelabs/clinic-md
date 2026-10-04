import { describe, it, expect } from 'vitest';
import { pickRecordingMimeType } from './useAudioRecorder';

describe('pickRecordingMimeType', () => {
  it('prefers webm/opus when supported', () => {
    expect(pickRecordingMimeType(() => true)).toBe('audio/webm;codecs=opus');
  });

  it('falls back to mp4 for Safari', () => {
    expect(pickRecordingMimeType((t) => t === 'audio/mp4')).toBe('audio/mp4');
  });

  it('returns an empty string when nothing is supported', () => {
    expect(pickRecordingMimeType(() => false)).toBe('');
  });
});
