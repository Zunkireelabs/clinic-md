import { useCallback } from 'react';
import {
  updateBookingStatus,
  assignDentist,
  recordPayment,
  updateBookingDetails,
  fetchBookingById,
  applyDiscount,
  updateDentistTime,
  resizeSharedBookingTime,
} from '../../../../../services/api';
import { transformBooking, toDbStatus } from '../../../../../services/bookingTransformers';

// Booking-level actions wired to the booking panel (status, assignment, edit, discount, payment) plus the
// shared-booking card resize from the grid.
export function useBookingActions({ showToast, refreshCalendar, selectedBooking, setSelectedBooking, getSelectedBookingsRef, staffLabel }) {
  const handleStatusUpdate = async (bookingId, newStatus, reason) => {
    const dbStatus = toDbStatus(newStatus);
    const result = await updateBookingStatus({ bookingId, newStatus: dbStatus, reason });
    if (result.error) {
      showToast(result.error.message || 'Failed to update status.', 'error');
      return;
    }
    showToast(`Status updated to ${newStatus}`);
  };

  const handleAssignDentist = async (bookingId, dentistIds, notes, chairId) => {
    const ids = Array.isArray(dentistIds) ? dentistIds : (dentistIds ? [dentistIds] : []);
    const result = await assignDentist({ bookingId, dentistIds: ids, chairId: chairId !== undefined ? (chairId || null) : undefined });
    if (result.error) {
      showToast(result.error.message || `Failed to assign ${staffLabel.toLowerCase()}.`, 'error');
      return;
    }
    showToast('Assignment saved successfully');
  };

  const handleBookingResize = useCallback(async (booking, deltaMinutes, direction) => {
    if (!booking.isShared || !booking._colDentistId) return;

    const [sh, sm] = (booking.startTime || '').split(':').map(Number);
    const [eh, em] = (booking.endTime || '').split(':').map(Number);
    if (isNaN(sh) || isNaN(eh)) return;

    const startMins = sh * 60 + sm;
    const endMins = eh * 60 + em;
    let newStartMins = startMins;
    let newEndMins = endMins;

    if (direction === 'top') {
      newStartMins = Math.max(startMins + deltaMinutes, 0);
    } else {
      newEndMins = Math.max(endMins + deltaMinutes, 0);
    }

    // Ensure minimum 5 min duration
    if (newEndMins - newStartMins < 5) {
      showToast('Minimum duration is 5 minutes.', 'error');
      return;
    }

    const newStartTime = `${String(Math.floor(newStartMins / 60)).padStart(2, '0')}:${String(newStartMins % 60).padStart(2, '0')}`;
    const newEndTime = `${String(Math.floor(newEndMins / 60)).padStart(2, '0')}:${String(newEndMins % 60).padStart(2, '0')}`;

    // Same default-vs-independent gate as the drag handler above: resizing an
    // explicitly Cmd/Ctrl-selected card moves only that dentist; otherwise the
    // whole shared booking (every co-dentist + the canonical bookings row)
    // resizes together, so one resize can never silently desync a co-dentist
    // from the rest of the booking (see resizeSharedBookingTime in api.js).
    const selectedBookings = getSelectedBookingsRef.current();
    const draggedKey = `${booking.id}__${booking._colDentistId}`;
    const isPartOfSelection = selectedBookings.length > 0 && selectedBookings.some(b => `${b.id}__${b._colDentistId}` === draggedKey);

    const bookingId = booking.bookingId || booking.id;
    const result = isPartOfSelection
      ? await updateDentistTime({
          bookingId,
          dentistId: booking._colDentistId,
          startTime: newStartTime,
          endTime: newEndTime,
        })
      : await resizeSharedBookingTime({ bookingId, startTime: newStartTime, endTime: newEndTime });

    if (result.error) {
      showToast(result.error.message || 'Failed to resize.', 'error');
    } else if (isPartOfSelection) {
      showToast(`Resized ${booking.dentistName || 'dentist'} independently to ${newStartTime} – ${newEndTime}`, 'success');
    } else {
      showToast(`Resized to ${newStartTime} – ${newEndTime}`, 'success');
    }
    refreshCalendar();
  }, [refreshCalendar]);

  const handleEditBooking = async (bookingId, updates) => {
    const result = await updateBookingDetails({ bookingId, ...updates });
    if (result.error) {
      showToast(result.error.message || 'Failed to update booking.', 'error');
      return { error: result.error };
    }
    showToast('Booking updated successfully');
    // Re-fetch the booking to update modal data
    const refreshed = await fetchBookingById(bookingId);
    if (!refreshed.error) {
      setSelectedBooking(transformBooking(refreshed.data));
    }
    refreshCalendar();
    return { error: null };
  };

  const handleApplyDiscount = async (bookingId, { discountType, discountValue, discountReason, requestedTo }) => {
    const result = await applyDiscount({ bookingId, discountType, discountValue, discountReason, requestedTo });
    if (result.error) return { error: result.error };
    showToast(result.data?.isPending ? 'Discount request sent for approval' : 'Discount applied successfully');
    // Refresh booking in modal
    const refreshed = await fetchBookingById(bookingId);
    if (!refreshed.error) setSelectedBooking(transformBooking(refreshed.data));
    refreshCalendar();
    return { data: result.data };
  };

  const handleRecordPayment = async (bookingId, opts) => {
    const result = await recordPayment({ bookingId, ...opts });
    if (result.error) {
      return { error: result.error };
    }
    showToast('Payment recorded successfully');
    // Only refresh the modal's displayed booking when this payment was for the
    // booking currently open (not a bundled previous-due/related payment for a
    // different booking) — otherwise the modal would flip to showing whichever
    // bundled booking happened to be paid last.
    if (selectedBooking && bookingId === selectedBooking.bookingId) {
      const refreshed = await fetchBookingById(bookingId);
      if (!refreshed.error) setSelectedBooking(transformBooking(refreshed.data));
    }
    refreshCalendar();
    return { error: null };
  };

  return { handleStatusUpdate, handleAssignDentist, handleBookingResize, handleEditBooking, handleApplyDiscount, handleRecordPayment };
}
