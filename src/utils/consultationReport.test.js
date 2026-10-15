import { describe, it, expect } from 'vitest';
import { stripMarkdown, buildConsultationExport, consultationFileName } from './consultationReport';

describe('stripMarkdown', () => {
  it('removes headings, bold and bullet markers', () => {
    expect(stripMarkdown('## Findings\n**Caries** on 36\n- Filling advised')).toBe('Findings\nCaries on 36\n• Filling advised');
  });

  it('handles empty input', () => {
    expect(stripMarkdown()).toBe('');
  });
});

describe('consultation export', () => {
  const c = { patientName: 'Jane Doe', sessionDate: '2026-10-04', transcript: 'hello', doctorNotes: 'ok' };

  it('names files by patient and date', () => {
    expect(consultationFileName(c, 'pdf')).toBe('consultation-jane-doe-2026-10-04.pdf');
  });

  it('includes the clinical fields', () => {
    const out = buildConsultationExport(c);
    expect(out.patientName).toBe('Jane Doe');
    expect(out.transcript).toBe('hello');
    expect(out.doctorNotes).toBe('ok');
    expect(out.exportedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });
});
