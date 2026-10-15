// Pure helpers for finding which connected device can record a consultation.

export const isMobileDevice = (
  ua = typeof navigator !== 'undefined' ? navigator.userAgent : '',
  touchPoints = typeof navigator !== 'undefined' ? navigator.maxTouchPoints : 0,
) => /Android|iPhone|iPad|iPod|Mobile/i.test(ua) || (/Macintosh/i.test(ua) && touchPoints > 1); // iPadOS reports as a Mac

export const deviceLabel = (ua = typeof navigator !== 'undefined' ? navigator.userAgent : '') => {
  if (/iPhone/i.test(ua)) return 'iPhone';
  if (/iPad/i.test(ua)) return 'iPad';
  if (/Android/i.test(ua)) return 'Android phone';
  return 'phone';
};

/** Other connected devices that can record (phones/tablets). */
export const recorderDevices = (devices, myId) => devices.filter((d) => d.isMobile && d.deviceId !== myId);
