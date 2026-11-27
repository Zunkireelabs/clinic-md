// A source for every note line (CMD-55 §3.3). The model proposes quotes per section; the server keeps a quote ONLY if it is found in the
// stored transcript segments of this consultation, and then takes `start` and `audio_path` from the matching segment, never from the model.
// Image sources ({image: 'xray' | 'photo'}) are kept only when that input was actually sent. A source is never invented.

export interface Segment { audio_path: string; start: number; end: number; text: string }
export interface QuoteSource { quote: string; start: number; audio_path: string }
export interface ImageSource { image: 'xray' | 'photo' }
export type Source = QuoteSource | ImageSource;

/** Case- and whitespace-insensitive form used for matching (the brief: normalised whitespace and case). */
export const normaliseText = (s: string): string => String(s ?? '').toLowerCase().replace(/\s+/g, ' ').trim();

interface Recording { audio_path: string; text: string; marks: { at: number; start: number }[] }

// One joined, normalised text per recording, with the offset where each segment begins (a quote may span two segments).
function buildRecordings(segments: Segment[]): Recording[] {
  const byPath = new Map<string, Segment[]>();
  for (const s of segments ?? []) {
    if (!s || typeof s.text !== 'string' || typeof s.start !== 'number' || typeof s.audio_path !== 'string') continue;
    if (!byPath.has(s.audio_path)) byPath.set(s.audio_path, []);
    byPath.get(s.audio_path)!.push(s);
  }
  const out: Recording[] = [];
  for (const [audio_path, segs] of byPath) {
    segs.sort((a, b) => a.start - b.start);
    let text = '';
    const marks: { at: number; start: number }[] = [];
    for (const s of segs) {
      const t = normaliseText(s.text);
      if (!t) continue;
      if (text) text += ' ';
      marks.push({ at: text.length, start: s.start });
      text += t;
    }
    out.push({ audio_path, text, marks });
  }
  return out;
}

/** Locate a quote: the recording and the start time of the segment where the match begins, or null. */
export function locateQuote(quote: string, recordings: Recording[]): { audio_path: string; start: number } | null {
  const q = normaliseText(quote);
  if (q.length < 3) return null;                     // a one- or two-letter "quote" proves nothing
  for (const r of recordings) {
    const at = r.text.indexOf(q);
    if (at < 0) continue;
    let start = r.marks[0]?.start ?? 0;
    for (const m of r.marks) { if (m.at <= at) start = m.start; else break; }
    return { audio_path: r.audio_path, start };
  }
  return null;
}

/**
 * raw: {section_key: [{quote} | {image}]} as the model returned it. allowedKeys: the template's section keys. inputs: what was actually sent
 * ('recording', 'xray', 'photo'). Returns {section_key: Source[]} with only proven sources (sections with none are omitted).
 */
export function filterSources(raw: unknown, segments: Segment[], allowedKeys: string[], inputs: string[]): Record<string, Source[]> {
  const out: Record<string, Source[]> = {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return out;
  const recordings = buildRecordings(segments);
  for (const [key, list] of Object.entries(raw as Record<string, unknown>)) {
    if (!allowedKeys.includes(key) || !Array.isArray(list)) continue;
    const kept: Source[] = [];
    const seen = new Set<string>();
    for (const item of list.slice(0, 20)) {
      if (!item || typeof item !== 'object') continue;
      const it = item as Record<string, unknown>;
      if ((it.image === 'xray' || it.image === 'photo') && inputs.includes(it.image)) {
        if (!seen.has(`img:${it.image}`)) { kept.push({ image: it.image }); seen.add(`img:${it.image}`); }
        continue;
      }
      if (typeof it.quote !== 'string' || !inputs.includes('recording')) continue;
      const hit = locateQuote(it.quote, recordings);
      if (!hit) continue;                            // not in the transcript: dropped, never stored
      const quote = it.quote.trim().slice(0, 500);
      const dedupe = `q:${normaliseText(quote)}`;
      if (seen.has(dedupe)) continue;
      seen.add(dedupe);
      kept.push({ quote, start: hit.start, audio_path: hit.audio_path });
    }
    if (kept.length) out[key] = kept;
  }
  return out;
}
