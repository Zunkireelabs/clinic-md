// Web Push needs the public VAPID key as bytes, and the browser's subscription
// as plain JSON to store.
export const urlBase64ToUint8Array = (base64String) => {
  const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(base64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i += 1) out[i] = raw.charCodeAt(i);
  return out;
};

export const subscriptionToRow = (subscription) => {
  const json = subscription.toJSON ? subscription.toJSON() : subscription;
  return {
    endpoint: json.endpoint,
    p256dh: json.keys?.p256dh,
    auth: json.keys?.auth,
  };
};

/**
 * What the notification control should show.
 *  unsupported  - browser cannot do push at all
 *  needs-install - iPhone/iPad Safari only allows push for apps added to the Home Screen
 *  denied / granted / default - the browser permission
 */
export const pushStatus = ({ hasPushManager, hasNotification, permission, isIos, isStandalone }) => {
  if (isIos && !isStandalone) return 'needs-install';
  if (!hasPushManager || !hasNotification) return 'unsupported';
  return permission; // 'default' | 'granted' | 'denied'
};
