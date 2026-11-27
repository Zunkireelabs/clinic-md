import { describe, it, expect } from 'vitest';
import fixtures from './noteSections.fixtures.json';
import {
  DEFAULT_NOTE_TEMPLATE, NOTE_SECTIONS, sectionsFor, markdownToNote, noteToMarkdown, editedSections, isStrictNote,
} from './consultationNote';
import { parseSummarySections } from './summarySections';

// The same fixtures drive the SQL twin (public._consult_note_sections / _consult_edited_sections) in tenant-isolation.sql section 3i,
// so the edited_sections the server stores at signing and what the page computes can't drift apart.
describe('note templates (CMD-54, migration 020)', () => {
  it('dental-v1 is the default and is today\'s six sections', () => {
    expect(DEFAULT_NOTE_TEMPLATE).toBe('dental-v1');
    expect(sectionsFor('dental-v1')).toBe(NOTE_SECTIONS);
    expect(sectionsFor(undefined)).toBe(NOTE_SECTIONS);
    expect(sectionsFor('dental-v9')).toBe(NOTE_SECTIONS); // unknown: the page still reads the text as v1
    expect(NOTE_SECTIONS.map((s) => s.key)).toEqual(['chief_complaint', 'history', 'findings', 'assessment', 'plan', 'follow_up']);
  });

  describe.each(fixtures.map((f) => [f.name, f]))('fixture: %s', (_name, f) => {
    it('splits into sections exactly as the SQL twin does (strict notes)', () => {
      if (f.sections === null) {
        expect(isStrictNote(f.md, 'dental-v1')).toBe(false); // legacy: the SQL twin returns null
      } else {
        expect(markdownToNote(f.md, 'dental-v1')).toEqual(f.sections);
        expect(markdownToNote(f.md)).toEqual(f.sections); // no template = dental-v1
      }
    });
    it('computes the same edited sections as the server', () => {
      expect(editedSections(f.md, f.ai, 'dental-v1')).toEqual(f.edited);
    });
  });

  it('v1 rows read back unchanged whether or not the template is passed', () => {
    const legacy = '### Clinical Findings\nCaries 36\n\n### Treatment Plan\nRCT\n\nFree line';
    expect(markdownToNote(legacy, 'dental-v1')).toEqual(markdownToNote(legacy));
    const note = { chief_complaint: 'Pain', history: '', findings: 'Caries\n## escaped', assessment: '', plan: '- RCT', follow_up: '' };
    expect(noteToMarkdown(note, 'dental-v1')).toBe(noteToMarkdown(note));
    expect(markdownToNote(noteToMarkdown(note, 'dental-v1'), 'dental-v1')).toEqual(note);
    expect(parseSummarySections(noteToMarkdown(note), 'dental-v1')).toEqual(parseSummarySections(noteToMarkdown(note)));
  });

  it('an unknown template never produces edited sections', () => {
    expect(editedSections('## Plan\nx', { plan: 'y' }, 'dental-v9')).toBeNull();
  });
});
