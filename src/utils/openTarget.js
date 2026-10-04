// What the Doctor app should open, from a notification link or a message from the
// service worker. `verify` means: ask for the code shown on the computer first.
export const parseOpenTarget = (input) => {
  const params = input instanceof URLSearchParams ? input : new URLSearchParams(input || '');
  const bookingId = params.get('booking');
  if (!bookingId) return null;
  return {
    bookingId,
    autoStart: params.get('autostart') === '1',
    verify: params.get('verify') === '1',
  };
};
