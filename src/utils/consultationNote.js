// The structured clinical note ↔ the markdown stored in consultations.final_summary.
// Headings must stay exactly these: summarySections.parseSummarySections reads them back for the patient chart.
// Templates (migration 020, CMD-54): consultations.note_template names the section set. Only 'dental-v1' (today's six sections) exists;
// the five-section 'dental-v2' arrives with the redesigned screen. The SQL twin is public._consult_note_sections (same fixtures:
// noteSections.fixtures.json). An unknown template is read as dental-v1 here (the page must still show the text); the SQL returns NULL.

export const DEFAULT_NOTE_TEMPLATE = 'dental-v1';

export const NOTE_SECTIONS = [
  { key: 'chief_complaint', heading: 'Chief complaint', placeholder: 'Why the patient came in' },
  { key: 'history', heading: 'History', placeholder: 'Relevant history, previous treatment' },
  { key: 'findings', heading: 'Findings', placeholder: 'Clinical and radiograph findings' },
  { key: 'assessment', heading: 'Assessment', placeholder: 'Diagnosis or impression' },
  { key: 'plan', heading: 'Plan', placeholder: 'Treatment plan' },
  { key: 'follow_up', heading: 'Follow-up', placeholder: 'When to see them next' },
];

export const NOTE_TEMPLATES = { 'dental-v1': NOTE_SECTIONS };

/** The section list for a template; unknown or missing → dental-v1. */
export const sectionsFor = (template) => NOTE_TEMPLATES[template] || NOTE_TEMPLATES[DEFAULT_NOTE_TEMPLATE];

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\-]/g, '\\$&');
const strictLineFor = (sections) => new RegExp(`^##\\s+(${sections.map((x) => escapeRe(x.heading)).join('|')})\\s*$`);

export const emptyNote = (template) => Object.fromEntries(sectionsFor(template).map((s) => [s.key, '']));

/** Coerce anything (AI JSON, partial object) into a clean note of the template's strings. */
export const normalizeNote = (n = {}, template) => Object.fromEntries(sectionsFor(template).map((s) => [s.key, String(n?.[s.key] ?? '').trim()]));

export const isNoteEmpty = (note, template) => sectionsFor(template).every((s) => !String(note?.[s.key] || '').trim());

export const sameNote = (a, b, template) => sectionsFor(template).every((s) => String(a?.[s.key] || '').trim() === String(b?.[s.key] || '').trim());

// A body line that starts with "#" could be read back as a heading; a leading backslash keeps it plain text (markdown-style escape).
const escapeBody = (text) => text.split('\n').map((l) => (/^\s*#{1,6}(\s|$)/.test(l) ? `\\${l}` : l)).join('\n');
const unescapeBody = (text) => text.split('\n').map((l) => l.replace(/^(\s*)\\(#{1,6}(\s|$))/, '$1$2')).join('\n');

/** Note → markdown. Empty sections are omitted; an empty note gives ''. */
export function noteToMarkdown(note, template) {
  return sectionsFor(template)
    .map((s) => ({ s, body: String(note?.[s.key] || '').trim() }))
    .filter(({ body }) => body)
    .map(({ s, body }) => `## ${s.heading}\n${escapeBody(body)}`)
    .join('\n\n');
}

// Reads any markdown heading level (older notes used ###) or a bold-only line, so legacy summaries still split into sections.
// New format: ONLY the template's exact "## " headings are section boundaries. Everything else (a "**Phase 1**" line, "### Sub", "#36 …") is body.
// Older notes (no exact headings) used other headings; those are read leniently.
const LEGACY_LINE = /^\s*(?:#{1,6}\s+(.+?)|\*\*(.+?)\*\*:?)\s*:?\s*$/;

/** True when every heading line is one of the template's exact "## " headings (what noteToMarkdown writes). */
export function isStrictNote(md = '', template) {
  const strictLine = strictLineFor(sectionsFor(template));
  const heads = String(md || '').split('\n').filter((l) => /^\s*#{1,6}\s+\S/.test(l));
  return heads.length > 0 && heads.every((l) => strictLine.test(l));
}

/**
 * Markdown → note. Reads exactly what noteToMarkdown writes. Text with none of the template's headings is treated as a legacy summary:
 * its headings are mapped best-effort (Clinical Findings → Findings, …) and unheaded text goes to Findings so nothing is dropped.
 */
export function markdownToNote(md = '', template) {
  const sections = sectionsFor(template);
  const strictLine = strictLineFor(sections);
  const keyByHeading = Object.fromEntries(sections.map((s) => [s.heading.toLowerCase(), s.key]));
  const lines = String(md || '').split('\n');
  const strict = isStrictNote(md, template); // any other heading = an older free-form summary
  const note = emptyNote(template);
  const loose = [];
  let current = null;
  lines.forEach((line) => {
    if (strict) {
      const m = line.match(strictLine);
      if (m) { current = keyByHeading[m[1].toLowerCase()]; return; }
      if (current) note[current] += `${line}\n`; else loose.push(line);
      return;
    }
    const m = line.match(LEGACY_LINE);
    if (m) { current = legacyKey((m[1] || m[2]).toLowerCase()) || '__other'; return; }
    if (current && current !== '__other' && current in note) note[current] += `${line}\n`; else loose.push(line);
  });
  const out = {};
  sections.forEach((s) => { out[s.key] = unescapeBody(note[s.key]).trim(); });
  const rest = loose.join('\n').trim();
  if (rest && 'findings' in out) out.findings = out.findings ? `${out.findings}\n${rest}` : rest;
  return out;
}

/**
 * Keys whose signed text differs from the AI draft (both trimmed), in template order. null without an AI draft ("Written by") or when the
 * note is not in the strict format (a legacy summary can't be compared). Mirrors public._consult_edited_sections, which is what is stored.
 */
export function editedSections(md, aiDraft, template) {
  if (!aiDraft || typeof aiDraft !== 'object') return null;
  if (template && !NOTE_TEMPLATES[template]) return null;
  if (!isStrictNote(md, template)) return null;
  const note = markdownToNote(md, template);
  return sectionsFor(template).filter((s) => String(note[s.key] || '').trim() !== String(aiDraft[s.key] ?? '').trim()).map((s) => s.key);
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
