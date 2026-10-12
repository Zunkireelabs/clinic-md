// Count live bookings that a proposed manual block would sit on top of (preview-only; blocks are warn-only).
// `bookings` are the calendar's raw DB rows: { date, start_time, end_time, status, dentist_id, booking_dentists[], chair_id, treatment_id }.
// A block with a dentist matches that dentist's bookings; a chair-only block matches that chair's; a whole-branch block matches all.
const toMin = (t) => {
  const [h, m] = String(t || '').split(':').map(Number);
  return Number.isNaN(h) ? null : h * 60 + (m || 0);
};

export function countBookingsInRange(bookings, { date, startTime, durationMinutes, dentistId, chairId }) {
  const s = toMin(startTime);
  const dur = Number(durationMinutes) || 0;
  if (!date || s == null || dur <= 0) return 0;
  const e = s + dur;
  let n = 0;
  for (const b of bookings || []) {
    const status = String(b.status || '').toLowerCase();
    if (['cancelled', 'no show'].includes(status)) continue;
    if (b.date !== date) continue;
    const bs = toMin(b.start_time);
    const be = toMin(b.end_time);
    if (bs == null || be == null || !(s < be && e > bs)) continue;
    const bookingDentists = b.booking_dentists?.length ? b.booking_dentists.map((d) => d.dentist_id) : (b.dentist_id ? [b.dentist_id] : []);
    const matches = (!dentistId && !chairId)
      || (dentistId && bookingDentists.includes(dentistId))
      || (chairId && b.chair_id === chairId && !dentistId);
    if (matches) n += 1;
  }
  return n;
}

export const bookingsInRangeMessage = (n) => (n > 0 ? `${n} booking${n === 1 ? '' : 's'} in this time` : '');
