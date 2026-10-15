import { describe, it, expect } from 'vitest';
import { isAiConsultationAvailable, loadOrgAiEnabled } from './aiConsultation';

describe('isAiConsultationAvailable (build flag AND clinic switch)', () => {
  it('is on only when both are exactly true', () => {
    expect(isAiConsultationAvailable(true, true)).toBe(true);
    expect(isAiConsultationAvailable(true, false)).toBe(false);
    expect(isAiConsultationAvailable(false, true)).toBe(false);
    expect(isAiConsultationAvailable(false, false)).toBe(false);
  });
  it('treats anything uncertain as off', () => {
    expect(isAiConsultationAvailable(true, undefined)).toBe(false);
    expect(isAiConsultationAvailable(true, null)).toBe(false);
    expect(isAiConsultationAvailable(true, 'true')).toBe(false);
    expect(isAiConsultationAvailable(undefined, true)).toBe(false);
  });
});

describe('loadOrgAiEnabled (fails closed)', () => {
  it('asks org_ai_enabled and returns true only for a literal true', async () => {
    const calls = [];
    const rpc = async (fn) => { calls.push(fn); return { data: true, error: null }; };
    expect(await loadOrgAiEnabled(rpc)).toBe(true);
    expect(calls).toEqual(['org_ai_enabled']);
  });
  it.each([false, null, undefined, 'true', 1])('is off for data=%s', async (data) => {
    expect(await loadOrgAiEnabled(async () => ({ data, error: null }))).toBe(false);
  });
  it('is off on an error (e.g. migration-010 not applied yet)', async () => {
    expect(await loadOrgAiEnabled(async () => ({ data: true, error: { message: 'function not found' } }))).toBe(false);
  });
  it('is off when the call throws', async () => {
    expect(await loadOrgAiEnabled(async () => { throw new Error('network'); })).toBe(false);
  });
});
