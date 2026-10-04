import { describe, it, expect } from 'vitest';
import { hasConsultationContent, groupByDay, capturedSummary, rowToReportData, dayLabel, isCompletedConsultation, filterHistory, attendedByText } from './consultationHistory';

const empty = { transcript: null, audio_paths: [], xray_image_paths: [], photo_image_paths: [] };

describe('hasConsultationContent', () => {
  it('ignores empty drafts', () => {
    expect(hasConsultationContent(empty)).toBe(false);
    expect(hasConsultationContent({ ...empty, transcript: '   ' })).toBe(false);
  });
  it('counts recordings, photos and notes', () => {
    expect(hasConsultationContent({ ...empty, audio_paths: ['a'] })).toBe(true);
    expect(hasConsultationContent({ ...empty, xray_image_paths: ['x'] })).toBe(true);
    expect(hasConsultationContent({ ...empty, doctor_notes: 'check 36' })).toBe(true);
  });
});

describe('groupByDay', () => {
  const now = new Date('2026-10-04T12:00:00');
  it('groups newest-first rows under Today / Yesterday / date', () => {
    const rows = [
      { id: 1, updated_at: '2026-10-04T10:00:00' },
      { id: 2, updated_at: '2026-10-04T09:00:00' },
      { id: 3, updated_at: '2026-10-03T15:00:00' },
      { id: 4, updated_at: '2026-09-20T15:00:00' },
    ];
    const groups = groupByDay(rows, now);
    expect(groups.map((g) => g.label)).toEqual(['Today', 'Yesterday', dayLabel('2026-09-20T15:00:00', now)]);
    expect(groups[0].items.map((r) => r.id)).toEqual([1, 2]);
  });
});

describe('capturedSummary', () => {
  it('lists what was captured', () => {
    expect(capturedSummary({ audio_paths: ['a', 'b'], xray_image_paths: ['x'], photo_image_paths: ['p'] })).toBe('2 recordings · 1 X-ray · 1 photo');
  });
  it('falls back sensibly', () => {
    expect(capturedSummary({ transcript: 'hi' })).toBe('Transcript');
    expect(capturedSummary({})).toBe('Notes');
  });
});

describe('rowToReportData', () => {
  it('maps a row for the PDF export', () => {
    const out = rowToReportData({ patient_name: 'Sita', session_date: '2026-10-04', final_summary: 'ok', bookings: { booking_number: 'BK-1', treatment_name_snapshot: 'Cleaning' } });
    expect(out).toMatchObject({ patientName: 'Sita', sessionDate: '2026-10-04', finalSummary: 'ok', bookingNumber: 'BK-1', treatment: 'Cleaning' });
  });
});

describe('completed vs in progress', () => {
  const saved = { id: 1, status: 'completed', bookings: { status: 'In-Progress' } };
  const visitDone = { id: 2, status: 'draft', bookings: { status: 'Completed' } };
  const open = { id: 3, status: 'draft', bookings: { status: 'In-Progress' } };

  it('counts a saved consultation or a completed visit as completed', () => {
    expect(isCompletedConsultation(saved)).toBe(true);
    expect(isCompletedConsultation(visitDone)).toBe(true);
    expect(isCompletedConsultation(open)).toBe(false);
  });

  it('filters the list', () => {
    const rows = [saved, visitDone, open];
    expect(filterHistory(rows, 'all')).toHaveLength(3);
    expect(filterHistory(rows, 'completed').map((r) => r.id)).toEqual([1, 2]);
    expect(filterHistory(rows, 'progress').map((r) => r.id)).toEqual([3]);
  });
});

describe('attendedByText', () => {
  it('lists every doctor who attended', () => {
    expect(attendedByText({ attended_by_names: ['Dr. A', 'Dr. B'] })).toBe('Dr. A, Dr. B');
  });
  it('falls back to the recorder, then to nothing', () => {
    expect(attendedByText({ attended_by_names: [], created_by_name: 'Dr. A' })).toBe('Dr. A');
    expect(attendedByText({})).toBe('');
  });
  it('is included in the report data', () => {
    expect(rowToReportData({ attended_by_names: ['Dr. A', 'Dr. B'], patient_name: 'X' }).attendedBy).toBe('Dr. A, Dr. B');
  });
});
