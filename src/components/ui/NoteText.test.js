import { describe, it, expect } from 'vitest';
import { parseNoteLines } from './NoteText';

describe('parseNoteLines', () => {
  it('groups "- " lines into one list and keeps other lines as paragraphs', () => {
    expect(parseNoteLines('Intro\n- a\n- b\nTail')).toEqual([{ type: 'p', text: 'Intro' }, { type: 'list', items: [{ text: 'a', children: [] }, { text: 'b', children: [] }] }, { type: 'p', text: 'Tail' }]);
  });
  it('accepts * and • bullets, skips blank lines, and handles empty input', () => {
    expect(parseNoteLines('* x\n\n• y')).toEqual([{ type: 'list', items: [{ text: 'x', children: [] }, { text: 'y', children: [] }] }]);
    expect(parseNoteLines('')).toEqual([]);
    expect(parseNoteLines(undefined)).toEqual([]);
  });
  it('indented bullets nest under the previous bullet', () => {
    expect(parseNoteLines('- Extract #38\n  - sedation\n  - antibiotics\n- Implant')).toEqual([
      { type: 'list', items: [{ text: 'Extract #38', children: ['sedation', 'antibiotics'] }, { text: 'Implant', children: [] }] },
    ]);
  });
  it('a hyphenated word is not a bullet', () => {
    expect(parseNoteLines('Follow-up in 6 months')).toEqual([{ type: 'p', text: 'Follow-up in 6 months' }]);
  });
});
