// Pure helpers behind the full patient page: latest clinical summary, the merged activity timeline, care team, treatments.
// Balance / visits / next / last / in-clinic come from patientDirectory.js (the same util as the list); nothing here recomputes them.
import { parseSummarySections } from './summarySections';
import { localISO } from './patientDirectory';
import { classifyBooking, summarizeMoney } from './bookingMoney';

const NO_VISIT = ['Cancelled', 'No Show'];
const npr = (n) => `NPR ${Number(n || 0).toLocaleString('en-IN')}`;
const pad = (n) => String(n).padStart(2, '0');
const localParts = (ts) => { const d = new Date(ts); return { date: localISO(d), time: `${pad(d.getHours())}:${pad(d.getMinutes())}` }; };
const hm = (t) => (t ? String(t).slice(0, 5) : '');

/** "Dr. A, Dr. B" — every doctor on a consultation, else whoever recorded it. */
export const consultationDoctor = (c) => {
  const names = (c.attended_by_names || []).filter(Boolean);
  return names.length ? names.join(', ') : (c.created_by_name || '');
};

/** What a consultation captured, e.g. "Transcript, summary, 2 X-rays". */
export function capturedLine(c) {
  const n = (k, one, many) => { const len = (c[k] || []).length; return len ? `${len} ${len === 1 ? one : many}` : ''; };
  return [
    c.transcript && c.transcript.trim() ? 'Transcript' : '',
    (c.final_summary || c.preliminary_summary || '').trim() ? 'summary' : '',
    n('audio_paths', 'recording', 'recordings'),
    n('xray_image_paths', 'X-ray', 'X-rays'),
    n('photo_image_paths', 'photo', 'photos'),
    c.doctor_notes && c.doctor_notes.trim() ? 'doctor notes' : '',
  ].filter(Boolean).join(', ') || 'Notes';
}

/**
 * Latest consultation that has a summary (final preferred, else preliminary).
 * `rows` is every Chief complaint / Findings / Plan row that could be parsed; when nothing parses, `raw` carries the text.
 */
export function latestClinicalSummary(consultations = []) {
  const sorted = [...consultations].sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
  const c = sorted.find((x) => (x.final_summary || x.preliminary_summary || '').trim());
  if (!c) return null;
  const text = (c.final_summary || c.preliminary_summary || '').trim();
  const s = parseSummarySections(text);
  const rows = [
    ['Chief complaint', s.complaint],
    ['Findings', s.findings || s.xray || s.photo],
    ['Plan', s.plan],
  ].filter(([, v]) => v);
  return {
    consultationId: c.id,
    rows,
    raw: rows.length ? '' : text,
    date: localParts(c.created_at).date,
    doctor: consultationDoctor(c),
    isFinal: !!(c.final_summary || '').trim(),
  };
}

// Money line for a visit, from bookingMoney: "NPR 8,000 due", "NPR 3,000 upcoming", "deposit NPR 1,000" or "paid".
const visitMoney = (m) => {
  const parts = [];
  if (m.kind === 'void' || m.kind === 'unclosed') return '';
  if (m.due > 0) parts.push(`${npr(m.due)} due`);
  if (m.upcoming > 0) parts.push(`${npr(m.upcoming)} upcoming`);
  if (m.deposit > 0) parts.push(`deposit ${npr(m.deposit)}`);
  if (!parts.length && m.price > 0) parts.push('paid');
  return parts.join(' · ');
};

/**
 * Newest-first timeline of visits (on or before today), payments and consultations.
 * bookings: raw rows with `payments[]`; consultations: raw rows.
 */
export function buildActivity({ bookings = [], consultations = [], today }) {
  const items = [];
  for (const b of bookings) {
    const date = String(b.date).slice(0, 10);
    if (date > today) continue; // upcoming bookings are shown as "Next appointment", not as history
    const time = hm(b.start_time);
    const m = classifyBooking(b, { today });
    items.push({
      kind: 'visit', notClosed: m.kind === 'unclosed', id: `v-${b.id}`, bookingId: b.id, at: `${date}T${time || '00:00'}`, date, time,
      title: b.treatment_name_snapshot || 'Visit', status: b.status,
      sub: [b.dentist_name_snapshot, b.booking_number, visitMoney(m)].filter(Boolean).join(' · '),
    });
    for (const p of (b.payments || [])) {
      const lp = localParts(p.created_at);
      items.push({
        kind: 'payment', id: `p-${p.id || `${b.id}-${p.created_at}`}`, bookingId: b.id, at: `${lp.date}T${lp.time}`, date: lp.date, time: lp.time,
        title: `Payment received · ${npr(p.amount)}`,
        sub: [p.payment_mode ? String(p.payment_mode).replace(/^./, (ch) => ch.toUpperCase()) : '', b.treatment_name_snapshot && `for ${b.treatment_name_snapshot}`].filter(Boolean).join(' · '),
      });
    }
  }
  for (const c of consultations) {
    const lp = localParts(c.created_at);
    items.push({
      kind: 'note', id: `c-${c.id}`, consultationId: c.id, bookingId: c.booking_id, at: `${lp.date}T${lp.time}`, date: lp.date, time: lp.time,
      title: 'Consultation notes', sub: [capturedLine(c), consultationDoctor(c)].filter(Boolean).join(' · '),
    });
  }
  return items.sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : a.id < b.id ? 1 : -1));
}

export const ACTIVITY_FILTERS = [
  { id: 'all', label: 'All', match: () => true },
  { id: 'visits', label: 'Visits', match: (i) => i.kind === 'visit' },
  { id: 'payments', label: 'Payments', match: (i) => i.kind === 'payment' },
  { id: 'notes', label: 'Notes', match: (i) => i.kind === 'note' },
];

const tally = (rows, keyOf) => {
  const m = new Map();
  rows.forEach((r) => { const k = keyOf(r); if (k) m.set(k, (m.get(k) || 0) + 1); });
  return [...m].map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
};
const seen = (b) => ['Completed', 'In-Progress'].includes(b.status);
/** Past Pending/Confirmed bookings that were never closed, oldest first. */
export const unclosedVisits = (bookings, today) => summarizeMoney(bookings, { today }).unclosed;

export const careTeam = (bookings) => tally(bookings.filter(seen), (b) => b.dentist_name_snapshot);
export const treatmentCounts = (bookings) => tally(bookings.filter(seen), (b) => b.treatment_name_snapshot);

/** Every uploaded image across consultations, newest consultation first, grouped by day: [{ date, items:[{path, label, consultationId}] }]. */
export function mediaGroups(consultations = []) {
  const groups = [];
  [...consultations].sort((a, b) => String(b.created_at).localeCompare(String(a.created_at))).forEach((c) => {
    const items = [
      ...(c.xray_image_paths || []).map((path) => ({ path, label: 'X-ray', consultationId: c.id })),
      ...(c.photo_image_paths || []).map((path) => ({ path, label: 'Photo', consultationId: c.id })),
    ];
    if (!items.length) return;
    const date = c.session_date || localParts(c.created_at).date;
    const last = groups[groups.length - 1];
    if (last && last.date === date) last.items.push(...items); else groups.push({ date, items });
  });
  return groups;
}
export const mediaCount = (consultations) => consultations.reduce((n, c) => n + (c.xray_image_paths || []).length + (c.photo_image_paths || []).length, 0);
