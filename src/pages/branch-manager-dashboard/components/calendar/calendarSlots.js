import { isAfterCheckout } from '../../../../services/dentistBranchWindow';

// Whether a (day, hour, minute) slot for a dentist falls at/after their recorded
// check-out for that specific day. `checkedOutByDentistAndDate` is the
// "<dentistId>_<date>" -> raw check_out_time map from getCalendarBookings.
export function isCheckedOutBlockedSlot(checkedOutByDentistAndDate, dentistId, day, hour, minute) {
  const checkOutTime = checkedOutByDentistAndDate?.[`${dentistId}_${day}`];
  if (!checkOutTime) return false;
  const slotTime = `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
  return isAfterCheckout(checkOutTime, day, slotTime);
}

// Default interval (minutes) used to pre-check an empty-slot click before a treatment is chosen.
export const DEFAULT_SLOT_MINUTES = 30;
