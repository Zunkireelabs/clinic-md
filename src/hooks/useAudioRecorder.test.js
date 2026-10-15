import { describe, it, expect } from 'vitest';
import { pickRecordingMimeType, AUDIO_BITS_PER_SECOND, MAX_SEGMENT_BYTES } from './useAudioRecorder';

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

describe('recording limits', () => {
  it('uses a low voice bitrate and splits well under the 25 MB transcription limit', () => {
    expect(AUDIO_BITS_PER_SECOND).toBe(32000);
    expect(MAX_SEGMENT_BYTES).toBeLessThanOrEqual(24 * 1024 * 1024);
    // an hour of speech at 32 kbps is ~14 MB, so a split only happens on very long visits
    expect((AUDIO_BITS_PER_SECOND / 8) * 3600).toBeLessThan(MAX_SEGMENT_BYTES);
  });
});
