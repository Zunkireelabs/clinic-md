import { describe, it, expect } from 'vitest';
import { consultationLoadError, canOpenConsultation } from './consultationLoadError';

describe('consultationLoadError', () => {
  it('maps RLS to the front-desk text', () => {
    for (const e of [{ code: '42501', message: 'x' }, { code: 'FORBIDDEN', message: 'x' }, { message: 'new row violates row-level security policy for table "consultations"' }]) {
      const r = consultationLoadError(e);
      expect(r.kind).toBe('forbidden');
      expect(r.title).toBe('Consultation notes are for practitioners and managers.');
      expect(r.hint).toBe('Ask the dentist to open this visit.');
    }
  });
  it('maps anything else to the generic text, never the raw message', () => {
    const r = consultationLoadError({ code: '500', message: 'boom db' });
    expect(r.kind).toBe('error');
    expect(JSON.stringify(r)).not.toContain('boom');
    expect(consultationLoadError(null).kind).toBe('error');
  });
  it('hides entry points from staff and admin_viewer only', () => {
    expect(canOpenConsultation('staff')).toBe(false);
    expect(canOpenConsultation('admin_viewer')).toBe(false);
    for (const r of ['practitioner', 'manager', 'admin']) expect(canOpenConsultation(r)).toBe(true);
  });
});
