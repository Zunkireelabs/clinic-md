// What the Doctor phone should do when it is opened.
//  - exactly one patient In-Progress -> open them and start recording
//  - several -> let the doctor tap the right one
//  - none -> wait
// After the doctor taps Done we do not re-open the same patient on the next refresh.
export const decideOpenAction = ({ bookings, suppressAuto }) => {
  if (suppressAuto) return { type: bookings.length ? 'list' : 'none' };
  if (bookings.length === 1) return { type: 'auto', bookingId: bookings[0].id };
  return { type: bookings.length ? 'list' : 'none' };
};
