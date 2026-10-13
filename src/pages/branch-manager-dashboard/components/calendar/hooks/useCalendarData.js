import { useState, useEffect, useCallback } from 'react';
import {
  getCalendarBookings,
  fetchBlocksForRange,
  fetchTransferOccurrences,
  isTransferFeatureMissing,
  fetchAttendance,
  LEAVE_LIKE_ATTENDANCE_STATUSES,
  updateDentistOrder,
  updateChairOrder,
  invalidateBookingDayCounts,
} from '../../../../../services/api';
import { getDateRange } from '../calendarDates';

// Calendar data for the visible range: bookings/dentists/chairs, block + transfer occurrences, attendance, the
// blocks/transfers availability flags, and the optimistic column-reorder handlers. Auto-refresh is wired by the
// caller (it needs the panel/drag state that decides when to pause).
export function useCalendarData({ branchId, currentDate, viewMode }) {
  // Calendar data state
  const [calendarData, setCalendarData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  // Attendance indicators
  const [attendanceMap, setAttendanceMap] = useState({});

  // False when the DB has no manual_blocks table yet (migration-001 not applied): hides "Add block".
  const [blocksAvailable, setBlocksAvailable] = useState(true);
  // Staff transfers. False when the DB has no transfer tables/RPCs yet (migrations 003–005 not applied).
  const [transfersAvailable, setTransfersAvailable] = useState(true);

  // ── Data fetching ──────────────────────────────────────────

  const fetchData = useCallback(async (startDate, endDate) => {
    if (!branchId || !startDate || !endDate) return;

    setLoading(true);
    setError(null);

    const [result, attResult, blocksResult, transferResult] = await Promise.all([
      getCalendarBookings(branchId, startDate, endDate),
      fetchAttendance({ branchId, date: startDate }),
      fetchBlocksForRange(branchId, startDate, endDate),
      fetchTransferOccurrences(branchId, startDate, endDate),
    ]);

    if (result.error) {
      setError(result.error.message || 'Failed to load calendar data.');
      setLoading(false);
      return;
    }

    // Blocks are best-effort: a failure (e.g. DB without migration-001) must not break the calendar.
    const blocksTableMissing = ['PGRST205', '42P01'].includes(blocksResult.error?.code);
    setBlocksAvailable(!blocksTableMissing);
    setTransfersAvailable(!isTransferFeatureMissing(transferResult.error));
    setCalendarData({ ...result.data, blockOccurrences: blocksResult.data || [], transferOccurrences: transferResult.data || [] });

    const attMap = {};
    if (attResult.data) {
      for (const a of attResult.data) {
        if (a.status === 'Absent' || LEAVE_LIKE_ATTENDANCE_STATUSES.includes(a.status)) {
          attMap[a.dentistId] = a.status === 'Absent' ? 'Absent' : 'Leave';
        }
      }
    }
    setAttendanceMap(attMap);
    setLoading(false);
  }, [branchId]);

  // Reload when date or view changes
  useEffect(() => {
    if (!branchId) return;
    const { start, end } = getDateRange(currentDate, viewMode);
    fetchData(start, end);
  }, [branchId, currentDate, viewMode, fetchData]);

  const refreshCalendar = useCallback(() => {
    invalidateBookingDayCounts(); // picker counts must reflect what just changed
    const { start, end } = getDateRange(currentDate, viewMode);
    fetchData(start, end);
  }, [currentDate, viewMode, fetchData]);

  const handleDentistReorder = useCallback(async (orderedIds) => {
    if (!branchId) return;
    // Optimistic: reorder dentists array in local state
    setCalendarData(prev => {
      if (!prev) return prev;
      const dentistMap = {};
      prev.dentists.forEach(t => { dentistMap[t.id] = t; });
      const reordered = orderedIds
        .map(id => dentistMap[id])
        .filter(Boolean);
      // Append any dentists not in orderedIds (safety)
      prev.dentists.forEach(t => {
        if (!orderedIds.includes(t.id)) reordered.push(t);
      });
      return { ...prev, dentists: reordered };
    });

    // Persist to DB
    const { error } = await updateDentistOrder({ branchId, orderedIds });
    if (error) {
      console.error('[Calendar] Failed to persist dentist order:', error.message);
      refreshCalendar();
    }
  }, [branchId, refreshCalendar]);

  // ── Chair column reorder ───────────────────────────────────
  const handleChairReorder = useCallback(async (orderedIds) => {
    if (!branchId) return;
    // Optimistic: reorder chairs array in local state
    setCalendarData(prev => {
      if (!prev) return prev;
      const chairMap = {};
      prev.chairs.forEach(r => { chairMap[r.id] = r; });
      const reordered = orderedIds
        .map(id => chairMap[id])
        .filter(Boolean);
      // Append any chairs not in orderedIds (safety)
      prev.chairs.forEach(r => {
        if (!orderedIds.includes(r.id)) reordered.push(r);
      });
      return { ...prev, chairs: reordered };
    });

    // Persist to DB
    const { error } = await updateChairOrder({ branchId, orderedIds });
    if (error) {
      console.error('[Calendar] Failed to persist chair order:', error.message);
      refreshCalendar();
    }
  }, [branchId, refreshCalendar]);


  return {
    calendarData, setCalendarData, loading, error, attendanceMap, blocksAvailable, transfersAvailable,
    fetchData, refreshCalendar, handleDentistReorder, handleChairReorder,
  };
}
