import { describe, it, expect } from 'vitest';
import { latestClinicalSummary, buildActivity, careTeam, treatmentCounts, unclosedVisits, mediaGroups, mediaCount, capturedLine, ACTIVITY_FILTERS } from './patientRecord';

const TODAY = '2026-10-14';
const cons = (id, extra = {}) => ({ id, booking_id: `b-${id}`, created_at: '2026-10-02T05:00:00Z', attended_by_names: ['Dr. Sarita Gurung'], ...extra });

describe('latestClinicalSummary', () => {
  it('parses sections from the final summary', () => {
    const s = latestClinicalSummary([cons('1', { final_summary: '## Chief Complaint\nSensitivity.\n## Findings\nEarly caries #36.\n## Treatment Plan\nComposite filling.' })]);
    expect(s.rows).toEqual([['Chief complaint', 'Sensitivity.'], ['Findings', 'Early caries #36.'], ['Plan', 'Composite filling.']]);
    expect(s.raw).toBe('');
    expect(s.doctor).toBe('Dr. Sarita Gurung');
    expect(s.isFinal).toBe(true);
  });
  it('falls back to the raw text when nothing parses', () => {
    const s = latestClinicalSummary([cons('1', { preliminary_summary: 'Patient reports tooth pain; advise X-ray.' })]);
    expect(s.rows).toEqual([]);
    expect(s.raw).toBe('Patient reports tooth pain; advise X-ray.');
    expect(s.isFinal).toBe(false);
  });
  it('uses the newest consultation that has a summary', () => {
    const s = latestClinicalSummary([cons('old', { final_summary: 'Old', created_at: '2026-09-01T00:00:00Z' }), cons('new', { created_at: '2026-10-10T00:00:00Z' }), cons('mid', { final_summary: 'Mid', created_at: '2026-10-05T00:00:00Z' })]);
    expect(s.consultationId).toBe('mid');
  });
  it('is null with no summaries', () => {
    expect(latestClinicalSummary([cons('1')])).toBeNull();
    expect(latestClinicalSummary([])).toBeNull();
  });
});

describe('buildActivity', () => {
  const bookings = [
    { id: 'b1', date: '2026-10-02', start_time: '10:00:00', status: 'Completed', payment_status: 'partial', final_amount: 7000, treatment_name_snapshot: 'Dental Cleaning', dentist_name_snapshot: 'Dr. Sarita Gurung', booking_number: 'BK-1',
      payments: [{ id: 'p1', amount: 4000, payment_mode: 'cash', created_at: '2026-10-02T06:30:00Z' }] },
    { id: 'b2', date: '2026-10-14', start_time: '10:00:00', status: 'In-Progress', payment_status: 'unpaid', final_amount: 8000, treatment_name_snapshot: 'Teeth Whitening', dentist_name_snapshot: 'Dr. Bishal Karki', booking_number: 'BK-2', payments: [] },
    { id: 'b3', date: '2026-10-19', start_time: '11:30:00', status: 'Confirmed', payment_status: 'unpaid', final_amount: 3000, treatment_name_snapshot: 'Cavity Filling', payments: [] },
    { id: 'b0', date: '2026-09-18', start_time: '09:00:00', status: 'Completed', payment_status: 'paid', final_amount: 8000, treatment_name_snapshot: 'Pediatric Checkup', dentist_name_snapshot: 'Dr. Anjali Shrestha', booking_number: 'BK-0', payments: [{ id: 'p0', amount: 8000, payment_mode: 'cash', created_at: '2026-09-18T05:00:00Z' }] },
  ];
  const items = buildActivity({ bookings, consultations: [cons('c1', { xray_image_paths: ['a', 'b'], transcript: 'x', final_summary: 'y' })], today: TODAY });
  it('excludes upcoming bookings and sorts newest first', () => {
    expect(items.find((i) => i.bookingId === 'b3')).toBeUndefined();
    const ats = items.map((i) => i.at);
    expect([...ats].sort().reverse()).toEqual(ats);
    expect(items[0].bookingId).toBe('b2');
  });
  it('builds money lines', () => {
    expect(items.find((i) => i.id === 'v-b1').sub).toBe('Dr. Sarita Gurung · BK-1 · NPR 3,000 due');
    expect(items.find((i) => i.id === 'v-b0').sub).toContain('· paid');
    expect(items.find((i) => i.id === 'v-b2').sub).toContain('NPR 8,000 due');
  });
  it('adds payments and consultations', () => {
    const p = items.find((i) => i.kind === 'payment');
    expect(p.title).toBe('Payment received · NPR 4,000');
    expect(p.sub).toBe('Cash · for Dental Cleaning');
    const n = items.find((i) => i.kind === 'note');
    expect(n.sub).toBe('Transcript, summary, 2 X-rays · Dr. Sarita Gurung');
  });
  it('filters by kind', () => {
    const f = (id) => items.filter(ACTIVITY_FILTERS.find((x) => x.id === id).match);
    expect(f('visits')).toHaveLength(3);
    expect(f('payments')).toHaveLength(2);
    expect(f('notes')).toHaveLength(1);
    expect(f('all')).toHaveLength(items.length);
  });
});

describe('rail + media', () => {
  const seenB = (id, dentist, treatment, extra = {}) => ({ id, status: 'Completed', payment_status: 'paid', final_amount: 100, dentist_name_snapshot: dentist, treatment_name_snapshot: treatment, ...extra });
  it('care team and treatments count completed/in-progress visits only', () => {
    const b = [seenB('1', 'A', 'X'), seenB('2', 'A', 'Y'), seenB('3', 'B', 'X'), seenB('4', 'C', 'Z', { status: 'Cancelled' })];
    expect(careTeam(b)).toEqual([{ name: 'A', count: 2 }, { name: 'B', count: 1 }]);
    expect(treatmentCounts(b)).toEqual([{ name: 'X', count: 2 }, { name: 'Y', count: 1 }]);
  });
  it('lists unclosed visits (past Pending/Confirmed) and flags them in the activity', () => {
    const b = [{ id: 'u', date: '2026-10-12', start_time: '10:00:00', status: 'Confirmed', final_amount: 500, treatment_name_snapshot: 'Filling', payments: [] }, seenB('1', 'A', 'X')];
    expect(unclosedVisits(b, TODAY).map((x) => x.id)).toEqual(['u']);
    const act = buildActivity({ bookings: b, consultations: [], today: TODAY });
    expect(act.find((i) => i.bookingId === 'u').notClosed).toBe(true);
    expect(act.find((i) => i.bookingId === 'u').sub).not.toContain('due');
  });
  it('a deposit on a booking later today shows as deposit + upcoming', () => {
    const act = buildActivity({ bookings: [{ id: 't', date: TODAY, start_time: '17:00:00', status: 'Confirmed', final_amount: 3000, treatment_name_snapshot: 'F', payments: [{ id: 'p', amount: 1000, created_at: '2026-10-14T05:00:00Z' }] }], consultations: [], today: TODAY });
    expect(act.find((i) => i.kind === 'visit').sub).toBe('NPR 2,000 upcoming · deposit NPR 1,000');
  });
  it('groups media by day and counts it', () => {
    const c = [cons('1', { session_date: '2026-10-02', xray_image_paths: ['a', 'b'], photo_image_paths: ['c'] }), cons('2', { session_date: '2026-10-02', created_at: '2026-10-02T09:00:00Z', xray_image_paths: ['d'] }), cons('3')];
    expect(mediaCount(c)).toBe(4);
    const g = mediaGroups(c);
    expect(g).toHaveLength(1);
    expect(g[0].items.map((i) => i.label)).toEqual(['X-ray', 'X-ray', 'X-ray', 'Photo']);
  });
  it('captured line falls back to Notes', () => { expect(capturedLine({})).toBe('Notes'); });
});
