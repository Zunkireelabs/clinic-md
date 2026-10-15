import { describe, it, expect } from 'vitest';
import { parseNoteLines } from './NoteText';

describe('parseNoteLines', () => {
  it('groups "- " lines into one list and keeps other lines as paragraphs', () => {
    expect(parseNoteLines('Intro\n- a\n- b\nTail')).toEqual([{ type: 'p', text: 'Intro' }, { type: 'list', items: ['a', 'b'] }, { type: 'p', text: 'Tail' }]);
  });
  it('accepts * and • bullets, skips blank lines, and handles empty input', () => {
    expect(parseNoteLines('* x\n\n• y')).toEqual([{ type: 'list', items: ['x', 'y'] }]);
    expect(parseNoteLines('')).toEqual([]);
    expect(parseNoteLines(undefined)).toEqual([]);
  });
  it('a hyphenated word is not a bullet', () => {
    expect(parseNoteLines('Follow-up in 6 months')).toEqual([{ type: 'p', text: 'Follow-up in 6 months' }]);
  });
});
