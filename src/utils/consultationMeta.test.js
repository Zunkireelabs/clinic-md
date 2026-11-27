import { describe, it, expect } from 'vitest';
import { EMPTY_META, metaFromRow, canUnsign, provenanceLine } from './consultationMeta';

describe('consultation meta (migration 020)', () => {
  it('reads the stored columns and keeps timestamps as strings', () => {
    const m = metaFromRow({ recording_consent: 'agreed', recording_consent_at: '2026-11-23T10:42:00.123456+00:00', ai_drafted_at: '2026-11-23T10:50:01.654321+00:00', ai_draft: { plan: 'x' } });
    expect(m.recording_consent).toBe('agreed');
    expect(m.ai_drafted_at).toBe('2026-11-23T10:50:01.654321+00:00');
    expect(m.has_ai_draft).toBe(true);
    expect(metaFromRow({})).toEqual(EMPTY_META);
  });

  it('a row from before 020 shows no provenance line', () => {
    expect(provenanceLine(metaFromRow({ status: 'completed', final_summary: 'x' }))).toBe('');
  });

  it('says AI drafted or Written by from the stored columns', () => {
    expect(provenanceLine(metaFromRow({ signed_at: '2026-11-23T11:00:00Z', signed_by_name: 'Dr Rai', ai_draft: { plan: 'x' } }))).toBe('AI drafted, reviewed by Dr Rai');
    expect(provenanceLine(metaFromRow({ signed_at: '2026-11-23T11:00:00Z', signed_by_name: 'Dr Rai' }))).toBe('Written by Dr Rai');
  });

  it('offers unsign only to the signer within 15 minutes', () => {
    const signedAt = '2026-11-23T11:00:00Z';
    const t0 = new Date(signedAt).getTime();
    const meta = metaFromRow({ signed_at: signedAt, signed_by: 'u1' });
    expect(canUnsign(meta, 'u1', t0 + 14 * 60 * 1000)).toBe(true);
    expect(canUnsign(meta, 'u1', t0 + 16 * 60 * 1000)).toBe(false);
    expect(canUnsign(meta, 'u2', t0 + 60 * 1000)).toBe(false);
    expect(canUnsign(metaFromRow({}), 'u1')).toBe(false);
  });
});
