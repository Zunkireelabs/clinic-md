import { describe, it, expect } from 'vitest';
import { consultationAiError } from './consultationAiError';

describe('consultationAiError', () => {
  it('AI_KEY_MISSING (a 503 with a body) is "not set up", not "unavailable"', () => {
    const e = consultationAiError(503, { error: 'AI_KEY_MISSING' });
    expect(e.code).toBe('AI_KEY_MISSING');
    expect(e.message).toBe("AI isn't set up for this clinic yet. You can still type the transcript and notes.");
  });
  it.each([404, 502, 503, 504, 0, null])('status %s with no usable body is "not available"', (status) => {
    const e = consultationAiError(status, null);
    expect(e.code).toBe('AI_UNAVAILABLE');
    expect(e.message).toBe("The AI service isn't available right now. Your recording is saved; try again later.");
  });
  it.each([400, 401, 422, 500])('status %s is the generic failure', (status) => {
    const e = consultationAiError(status, { error: 'boom' });
    expect(e.code).toBe('AI_FAILED');
    expect(e.message).toBe("Couldn't process this. Your recording is saved; try again.");
  });
  it('AI_DISABLED (403, clinic switch off) gets its own message and is not the generic FORBIDDEN', () => {
    const e = consultationAiError(403, { error: 'AI_DISABLED' });
    expect(e.code).toBe('AI_DISABLED');
    expect(e.message).toBe("AI consultation isn't switched on for this clinic. You can still type the transcript and notes.");
  });
});
