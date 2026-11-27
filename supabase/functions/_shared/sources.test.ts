import { describe, it, expect } from 'vitest';
import { filterSources, locateQuote, normaliseText, type Segment } from './sources';
import { openaiBase, openaiUrl, OPENAI_DEFAULT_BASE } from './openai';

const segs: Segment[] = [
  { audio_path: 'org/bk/r1.webm', start: 0, end: 3.2, text: ' Where does it hurt?' },
  { audio_path: 'org/bk/r1.webm', start: 3.2, end: 7.9, text: 'Lower left, when I drink   cold water.' },
  { audio_path: 'org/bk/r2.webm', start: 0, end: 4, text: 'We will start the root canal today.' },
];
const KEYS = ['chief_complaint', 'history', 'findings', 'assessment', 'plan', 'follow_up'];

describe('source filtering (CMD-55: a source is never invented)', () => {
  it('drops a quote that is not in the transcript', () => {
    const out = filterSources({ chief_complaint: [{ quote: 'The patient reports severe swelling' }] }, segs, KEYS, ['recording']);
    expect(out).toEqual({});
  });

  it('keeps a real quote and takes start and audio_path from the segment, not from the model', () => {
    const out = filterSources({ chief_complaint: [{ quote: 'when I drink cold water', start: 999, audio_path: 'forged' }] }, segs, KEYS, ['recording']);
    expect(out).toEqual({ chief_complaint: [{ quote: 'when I drink cold water', start: 3.2, audio_path: 'org/bk/r1.webm' }] });
  });

  it('matches across case, extra whitespace, and two segments', () => {
    expect(locateQuote('HURT?   lower LEFT', [] as never)).toBeNull();
    const out = filterSources({ findings: [{ quote: 'it HURT?   lower left' }] }, segs, KEYS, ['recording']);
    expect(out.findings).toEqual([{ quote: 'it HURT?   lower left', start: 0, audio_path: 'org/bk/r1.webm' }]);
  });

  it('finds quotes in the second recording with that recording\'s own times', () => {
    const out = filterSources({ plan: [{ quote: 'start the root canal' }] }, segs, KEYS, ['recording']);
    expect(out.plan).toEqual([{ quote: 'start the root canal', start: 0, audio_path: 'org/bk/r2.webm' }]);
  });

  it('keeps an image source only when that image was actually sent', () => {
    expect(filterSources({ findings: [{ image: 'xray' }] }, segs, KEYS, ['recording'])).toEqual({});
    expect(filterSources({ findings: [{ image: 'xray' }, { image: 'xray' }] }, segs, KEYS, ['recording', 'xray'])).toEqual({ findings: [{ image: 'xray' }] });
  });

  it('ignores unknown sections, junk items, very short quotes and duplicates', () => {
    const out = filterSources({ diagnosis: [{ quote: 'cold water' }], plan: [null, 'x', { quote: 'we' }, { quote: 'root canal' }, { quote: 'Root  Canal' }] }, segs, KEYS, ['recording']);
    expect(out).toEqual({ plan: [{ quote: 'root canal', start: 0, audio_path: 'org/bk/r2.webm' }] });
  });

  it('keeps no quote when no recording was an input', () => {
    expect(filterSources({ plan: [{ quote: 'root canal' }] }, segs, KEYS, ['xray'])).toEqual({});
  });

  it('normalises whitespace and case only', () => {
    expect(normaliseText('  A\n b\tC ')).toBe('a b c');
  });
});

describe('OPENAI_BASE_URL (tests only; unset in production)', () => {
  it('defaults to the real API', () => {
    expect(openaiBase(undefined)).toBe(OPENAI_DEFAULT_BASE);
    expect(openaiBase('')).toBe(OPENAI_DEFAULT_BASE);
    expect(openaiUrl('/chat/completions', undefined)).toBe('https://api.openai.com/v1/chat/completions');
  });
  it('allows https anywhere and http only to the local machine', () => {
    expect(openaiBase('https://proxy.example.com/v1/')).toBe('https://proxy.example.com/v1');
    expect(openaiBase('http://127.0.0.1:9911/v1')).toBe('http://127.0.0.1:9911/v1');
    expect(openaiBase('http://localhost:9911/v1')).toBe('http://localhost:9911/v1');
    expect(openaiBase('http://host.docker.internal:9911/v1')).toBe('http://host.docker.internal:9911/v1');
  });
  it('falls back to the real API for plain http elsewhere, other schemes, credentials in the URL, or junk', () => {
    expect(openaiBase('http://evil.example.com/v1')).toBe(OPENAI_DEFAULT_BASE);
    expect(openaiBase('ftp://127.0.0.1/v1')).toBe(OPENAI_DEFAULT_BASE);
    expect(openaiBase('https://user:pw@proxy.example.com')).toBe(OPENAI_DEFAULT_BASE);
    expect(openaiBase('not a url')).toBe(OPENAI_DEFAULT_BASE);
  });
});
