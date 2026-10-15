import { describe, it, expect } from 'vitest';
import { NOTE_SECTIONS, emptyNote, normalizeNote, isNoteEmpty, noteToMarkdown, markdownToNote, sameNote } from './consultationNote';
import { parseSummarySections } from './summarySections';

const full = {
  chief_complaint: 'Sensitivity on the lower-left molar for two weeks.',
  history: 'Scaling and polish on 2 Oct.',
  findings: 'Early distal caries on #36.\nGums healthy.',
  assessment: 'Dentine hypersensitivity secondary to caries #36.',
  plan: '- Composite filling #36\n- Whitening 2 weeks after\n- Sensitivity toothpaste',
  follow_up: 'Review in 6 months.',
};

describe('note ↔ markdown', () => {
  it('has exactly the six headings in order', () => {
    expect(noteToMarkdown(full).match(/^## .+$/gm)).toEqual(['## Chief complaint', '## History', '## Findings', '## Assessment', '## Plan', '## Follow-up']);
  });
  it('round-trips a full note, bullets included', () => {
    expect(markdownToNote(noteToMarkdown(full))).toEqual(full);
  });
  it('round-trips with empty sections (they are omitted, then come back empty)', () => {
    const n = { ...emptyNote(), chief_complaint: 'Pain', plan: '- Extract #38' };
    const md = noteToMarkdown(n);
    expect(md).not.toContain('## History');
    expect(markdownToNote(md)).toEqual(n);
  });
  it('an empty note is an empty string and back', () => {
    expect(noteToMarkdown(emptyNote())).toBe('');
    expect(markdownToNote('')).toEqual(emptyNote());
    expect(isNoteEmpty(emptyNote())).toBe(true);
    expect(isNoteEmpty({ plan: '  ' })).toBe(true);
    expect(isNoteEmpty({ plan: 'x' })).toBe(false);
  });
  it('body lines that start with # (tooth numbers) survive and are not read as headings', () => {
    const n = { ...emptyNote(), findings: '#36 distal caries\n## not a heading either' };
    expect(markdownToNote(noteToMarkdown(n))).toEqual(n);
  });
  it('the chart parser reads the same sections back (complaint/history/findings/diagnosis/plan/followup)', () => {
    const s = parseSummarySections(noteToMarkdown(full));
    expect(s.complaint).toBe(full.chief_complaint);
    expect(s.history).toBe(full.history);
    expect(s.findings).toBe(full.findings);
    expect(s.diagnosis).toBe(full.assessment);
    expect(s.plan).toBe(full.plan);
    expect(s.followup).toBe(full.follow_up);
    expect(s.other).toBe('');
  });
  it('the chart parser keeps "#36" body lines as text, un-escaped', () => {
    const s = parseSummarySections(noteToMarkdown({ ...emptyNote(), findings: '#36 distal caries' }));
    expect(s.findings).toBe('#36 distal caries');
  });
  it('maps older free-form headings and keeps unheaded text', () => {
    const n = markdownToNote('### Chief Complaint\nPain\n### Clinical Findings\nCaries\n### Treatment Plan\nFilling\nstray line');
    expect(n.chief_complaint).toBe('Pain');
    expect(n.findings).toBe('Caries');
    expect(n.plan).toBe('Filling\nstray line');
    expect(markdownToNote('Just some old text').findings).toBe('Just some old text');
  });
  it('normalizeNote coerces AI output and sameNote ignores whitespace', () => {
    expect(normalizeNote({ chief_complaint: ' a ', plan: null })).toEqual({ ...emptyNote(), chief_complaint: 'a' });
    expect(sameNote({ plan: 'x ' }, { plan: 'x' })).toBe(true);
    expect(NOTE_SECTIONS).toHaveLength(6);
  });
});
