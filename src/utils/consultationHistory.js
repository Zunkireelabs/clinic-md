// Helpers for listing and showing past consultations (phone history).

export const hasConsultationContent = (row) =>
  !!(
    (row.transcript && row.transcript.trim())
    || (row.preliminary_summary && row.preliminary_summary.trim())
    || (row.final_summary && row.final_summary.trim())
    || (row.doctor_notes && row.doctor_notes.trim())
    || (row.additional_notes && row.additional_notes.trim())
    || (row.xray_analysis && row.xray_analysis.trim())
    || (row.photo_analysis && row.photo_analysis.trim())
    || (row.audio_paths || []).length > 0
    || (row.xray_image_paths || []).length > 0
    || (row.photo_image_paths || []).length > 0
  );

const dayKey = (iso) => new Date(iso).toLocaleDateString('en-CA');

/** "Today", "Yesterday", or a readable date, for section headings. */
export const dayLabel = (iso, now = new Date()) => {
  const d = new Date(iso);
  const today = dayKey(now.toISOString());
  const yesterday = dayKey(new Date(now.getTime() - 24 * 3600 * 1000).toISOString());
  const k = dayKey(d.toISOString());
  if (k === today) return 'Today';
  if (k === yesterday) return 'Yesterday';
  return d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
};

/** Newest first, grouped under day headings: [{ label, items }]. */
export const groupByDay = (rows, now = new Date()) => {
  const groups = [];
  rows.forEach((row) => {
    const label = dayLabel(row.updated_at, now);
    const last = groups[groups.length - 1];
    if (last && last.label === label) last.items.push(row);
    else groups.push({ label, items: [row] });
  });
  return groups;
};

/** One short line saying what was captured, e.g. "2 recordings · 1 X-ray · 1 photo". */
export const capturedSummary = (row) => {
  const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
  const parts = [];
  const rec = (row.audio_paths || []).length;
  const xr = (row.xray_image_paths || []).length;
  const ph = (row.photo_image_paths || []).length;
  if (rec) parts.push(plural(rec, 'recording', 'recordings'));
  if (xr) parts.push(plural(xr, 'X-ray', 'X-rays'));
  if (ph) parts.push(plural(ph, 'photo', 'photos'));
  if (!parts.length && row.transcript) parts.push('Transcript');
  if (!parts.length) parts.push('Notes');
  return parts.join(' · ');
};

/** "Dr. A, Dr. B": every doctor who attended this patient (falls back to whoever recorded it). */
export const attendedByText = (row) => {
  const names = (row.attended_by_names || []).filter(Boolean);
  if (names.length) return names.join(', ');
  return row.created_by_name || '';
};

/** Shape expected by the PDF / JSON export in consultationReport.js. */
export const rowToReportData = (row) => ({
  patientName: row.patient_name,
  attendedBy: attendedByText(row),
  bookingNumber: row.bookings?.booking_number,
  treatment: row.bookings?.treatment_name_snapshot,
  dentist: row.bookings?.dentist_name_snapshot,
  sessionDate: row.session_date,
  language: row.detected_language,
  recordingDurationSeconds: row.recording_duration_seconds,
  transcript: row.transcript,
  preliminarySummary: row.preliminary_summary,
  xrayAnalysis: row.xray_analysis,
  photoAnalysis: row.photo_analysis,
  additionalNotes: row.additional_notes,
  doctorNotes: row.doctor_notes,
  finalSummary: row.final_summary,
});

/** Completed = the doctor saved/finished the consultation (or the visit itself was completed). */
export const isCompletedConsultation = (row) => row.status === 'completed' || row.bookings?.status === 'Completed';

export const HISTORY_FILTERS = [
  { id: 'all', label: 'All' },
  { id: 'progress', label: 'In progress' },
  { id: 'completed', label: 'Completed' },
];

export const filterHistory = (rows, filter) => {
  if (filter === 'completed') return rows.filter(isCompletedConsultation);
  if (filter === 'progress') return rows.filter((r) => !isCompletedConsultation(r));
  return rows;
};
