// Single source of truth for booking status colours (calendar cards, popover, legend).
// bar = left accent / dot, fill = soft card background, text = label colour on fill.
export const BOOKING_STATUS_COLORS = {
  'Pending':     { bar: '#C98A12', fill: '#FBF5E6', text: '#7A5408' },
  'Confirmed':   { bar: '#146EF4', fill: '#EEF4FE', text: '#0B3F8C' },
  'In-Progress': { bar: '#7B2FF7', fill: '#F3EDFE', text: '#4A1A99' },
  'Completed':   { bar: '#1F9D6C', fill: '#EAF6F0', text: '#125E41' },
  'No Show':     { bar: '#8A8A90', fill: '#F4F4F6', text: '#3A3A40' },
  'Cancelled':   { bar: '#C0392B', fill: '#FBEDEB', text: '#7A2219' },
};

export const UNPAID_DOT_COLOR = '#C98A12';

export const getBookingStatusColors = (status) =>
  BOOKING_STATUS_COLORS[status] || BOOKING_STATUS_COLORS['Pending'];
