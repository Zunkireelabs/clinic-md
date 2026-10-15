// Splits a markdown consultation summary into its named sections so the patient
// chart can label them (problem, tests, diagnosis, plan…) instead of one long text.

const KEYS = [
  ['complaint', /chief complaint|complaint|presenting/i],
  ['history', /history/i],
  ['xray', /radiograph|x-?ray/i],
  ['photo', /photo/i],
  ['findings', /finding|examination/i],
  ['diagnosis', /assessment|diagnos/i],
  ['plan', /treatment plan|proposed treatment|plan/i],
  ['followup', /follow-?up/i],
];

const canonical = (title) => {
  const hit = KEYS.find(([, re]) => re.test(title));
  return hit ? hit[0] : null;
};

// A markdown heading needs a space after the #'s ('#36 distal' is body text, not a heading).
const HEADING = /^\s*(?:#{1,6}\s+(.+?)|\*\*(.+?)\*\*:?)\s*:?\s*$/;

// New-format notes (written by the consultation page) have the six exact "## " headings. In that format ONLY those lines are
// section boundaries: a bold line like "**Phase 1**" or a "### Sub" line inside a section is plain body text. Older free-form
// summaries (no exact headings) keep the lenient parsing above.
const STRICT = { 'chief complaint': 'complaint', history: 'history', findings: 'findings', assessment: 'diagnosis', plan: 'plan', 'follow-up': 'followup' };
const STRICT_LINE = /^##\s+(Chief complaint|History|Findings|Assessment|Plan|Follow-up)\s*$/;
// Structured = it has canonical headings and EVERY markdown heading line in it is one of them (the writer escapes "#" body lines, so a
// raw "## Something else" or "### Sub" means an older free-form summary). Bold-only lines never count as headings here.
export const isStructuredNote = (text = '') => {
  const heads = (text || '').split('\n').filter((l) => /^\s*#{1,6}\s+\S/.test(l));
  return heads.length > 0 && heads.every((l) => STRICT_LINE.test(l));
};

/** Returns { complaint, history, findings, xray, photo, diagnosis, plan, followup, other } (strings, empty when absent). */
export const parseSummarySections = (text = '') => {
  const out = { complaint: '', history: '', findings: '', xray: '', photo: '', diagnosis: '', plan: '', followup: '', other: '' };
  let current = 'other';
  const strict = isStructuredNote(text);
  (text || '').split('\n').forEach((line) => {
    if (strict) {
      const sm = line.match(STRICT_LINE);
      if (sm) { current = STRICT[sm[1].toLowerCase()]; return; }
      out[current] += `${line.replace(/^(\s*)\\(#)/, '$1$2')}\n`;
      return;
    }
    const m = line.match(HEADING);
    if (m) {
      current = canonical((m[1] || m[2] || '').trim()) || 'other';
      return;
    }
    out[current] += `${line.replace(/^(\s*)\\(#)/, '$1$2')}\n`; // un-escape a body line that began with '#'
  });
  // Legacy summaries had markdown bold stripped; in the structured format body text is kept exactly as written.
  Object.keys(out).forEach((k) => { out[k] = (strict ? out[k] : out[k].replace(/\*\*/g, '')).trim(); });
  return out;
};
