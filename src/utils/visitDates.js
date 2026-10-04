// Dates shown with a patient: this visit, and the patient's last (previous) visit.

/** "4 Oct 2026" from a date-only string like "2026-10-04" (read as a local date, so no time-zone shift). */
export const formatVisitDate = (value) => {
  if (!value) return '';
  const d = new Date(String(value).length <= 10 ? `${value}T00:00:00` : value);
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
};

/** What to show for "Last visit": the date, or "First visit" when there is no earlier completed visit. */
export const lastVisitLabel = (lastVisit) => (lastVisit?.date ? formatVisitDate(lastVisit.date) : 'First visit');
