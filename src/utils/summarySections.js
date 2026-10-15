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

/** Returns { complaint, history, findings, xray, photo, diagnosis, plan, followup, other } (strings, empty when absent). */
export const parseSummarySections = (text = '') => {
  const out = { complaint: '', history: '', findings: '', xray: '', photo: '', diagnosis: '', plan: '', followup: '', other: '' };
  let current = 'other';
  (text || '').split('\n').forEach((line) => {
    const m = line.match(HEADING);
    if (m) {
      current = canonical((m[1] || m[2] || '').trim()) || 'other';
      return;
    }
    out[current] += `${line.replace(/^(\s*)\\(#)/, '$1$2')}\n`; // un-escape a body line that began with '#'
  });
  Object.keys(out).forEach((k) => { out[k] = out[k].replace(/\*\*/g, '').trim(); });
  return out;
};
