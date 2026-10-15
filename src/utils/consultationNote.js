// The structured clinical note (six sections) ↔ the markdown stored in consultations.final_summary.
// Headings must stay exactly these: summarySections.parseSummarySections reads them back for the patient chart.

export const NOTE_SECTIONS = [
  { key: 'chief_complaint', heading: 'Chief complaint', placeholder: 'Why the patient came in' },
  { key: 'history', heading: 'History', placeholder: 'Relevant history, previous treatment' },
  { key: 'findings', heading: 'Findings', placeholder: 'Clinical and radiograph findings' },
  { key: 'assessment', heading: 'Assessment', placeholder: 'Diagnosis or impression' },
  { key: 'plan', heading: 'Plan', placeholder: 'Treatment plan' },
  { key: 'follow_up', heading: 'Follow-up', placeholder: 'When to see them next' },
];

export const emptyNote = () => Object.fromEntries(NOTE_SECTIONS.map((s) => [s.key, '']));

/** Coerce anything (AI JSON, partial object) into a clean note of six strings. */
export const normalizeNote = (n = {}) => Object.fromEntries(NOTE_SECTIONS.map((s) => [s.key, String(n?.[s.key] ?? '').trim()]));

export const isNoteEmpty = (note) => NOTE_SECTIONS.every((s) => !String(note?.[s.key] || '').trim());

export const sameNote = (a, b) => NOTE_SECTIONS.every((s) => String(a?.[s.key] || '').trim() === String(b?.[s.key] || '').trim());

// A body line that starts with "#" could be read back as a heading; a leading backslash keeps it plain text (markdown-style escape).
const escapeBody = (text) => text.split('\n').map((l) => (/^\s*#{1,6}(\s|$)/.test(l) ? `\\${l}` : l)).join('\n');
const unescapeBody = (text) => text.split('\n').map((l) => l.replace(/^(\s*)\\(#{1,6}(\s|$))/, '$1$2')).join('\n');

/** Note → markdown. Empty sections are omitted; an empty note gives ''. */
export function noteToMarkdown(note) {
  return NOTE_SECTIONS
    .map((s) => ({ s, body: String(note?.[s.key] || '').trim() }))
    .filter(({ body }) => body)
    .map(({ s, body }) => `## ${s.heading}\n${escapeBody(body)}`)
    .join('\n\n');
}

// Reads any markdown heading level (older notes used ###) or a bold-only line, so legacy summaries still split into sections.
// New format: ONLY the six exact "## " headings are section boundaries. Everything else (a "**Phase 1**" line, "### Sub", "#36 …") is body.
const STRICT_LINE = /^##\s+(Chief complaint|History|Findings|Assessment|Plan|Follow-up)\s*$/;
// Older notes (no exact headings) used other headings; those are read leniently.
const LEGACY_LINE = /^\s*(?:#{1,6}\s+(.+?)|\*\*(.+?)\*\*:?)\s*:?\s*$/;
const KEY_BY_HEADING = Object.fromEntries(NOTE_SECTIONS.map((s) => [s.heading.toLowerCase(), s.key]));

/**
 * Markdown → note. Reads exactly what noteToMarkdown writes. Text with none of the six headings is treated as a legacy summary:
 * its headings are mapped best-effort (Clinical Findings → Findings, …) and unheaded text goes to Findings so nothing is dropped.
 */
export function markdownToNote(md = '') {
  const lines = String(md || '').split('\n');
  const heads = lines.filter((l) => /^\s*#{1,6}\s+\S/.test(l));
  const strict = heads.length > 0 && heads.every((l) => STRICT_LINE.test(l)); // any other heading = an older free-form summary
  const note = emptyNote();
  const loose = [];
  let current = null;
  lines.forEach((line) => {
    if (strict) {
      const m = line.match(STRICT_LINE);
      if (m) { current = KEY_BY_HEADING[m[1].toLowerCase()]; return; }
      if (current) note[current] += `${line}\n`; else loose.push(line);
      return;
    }
    const m = line.match(LEGACY_LINE);
    if (m) { current = legacyKey((m[1] || m[2]).toLowerCase()) || '__other'; return; }
    if (current && current !== '__other') note[current] += `${line}\n`; else loose.push(line);
  });
  const out = {};
  NOTE_SECTIONS.forEach((s) => { out[s.key] = unescapeBody(note[s.key]).trim(); });
  const rest = loose.join('\n').trim();
  if (rest) out.findings = out.findings ? `${out.findings}\n${rest}` : rest;
  return out;
}

function legacyKey(h) {
  if (/complaint|presenting/.test(h)) return 'chief_complaint';
  if (/history/.test(h)) return 'history';
  if (/finding|examination|radiograph|x-?ray|photo/.test(h)) return 'findings';
  if (/assessment|diagnos/.test(h)) return 'assessment';
  if (/follow-?up/.test(h)) return 'follow_up';
  if (/plan|treatment/.test(h)) return 'plan';
  return null;
}
