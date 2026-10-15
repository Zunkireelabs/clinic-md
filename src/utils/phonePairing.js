// Where the phone goes after pairing: the clinic's Doctor phone page, opening a
// specific patient when the QR code carried one.
export const phoneDestination = ({ org, booking }) => {
  if (!org) return '/login';
  return `/${org}/phone${booking ? `?booking=${encodeURIComponent(booking)}` : ''}`;
};

// The QR link. With a pairing code the phone signs itself in; without one
// (pairing unavailable) it falls back to the normal login.
export const buildPairingUrl = (baseUrl, { orgSlug, bookingId, code }) => {
  const base = baseUrl.replace(/\/$/, '');
  if (!code) return `${base}/${orgSlug}/phone?booking=${bookingId}`;
  const params = new URLSearchParams({ code, org: orgSlug, booking: bookingId });
  return `${base}/phone/pair?${params.toString()}`;
};

export const secondsLeft = (expiresAt, now = Date.now()) =>
  Math.max(0, Math.ceil((new Date(expiresAt).getTime() - now) / 1000));

// The 6-digit code is shown as "123 456" and typed with or without the space.
export const formatShortCode = (code) => (code && code.length === 6 ? `${code.slice(0, 3)} ${code.slice(3)}` : (code || ''));
export const normalizeShortCode = (input) => (input || '').replace(/\D/g, '').slice(0, 6);
export const isCompleteShortCode = (input) => normalizeShortCode(input).length === 6;
