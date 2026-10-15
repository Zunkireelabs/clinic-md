// Dismissal persistence for Spotlight banners: one localStorage flag per banner id and user.
export const spotlightKey = (id, userId) => `clinicmd.spotlight.${id}.${userId || 'anon'}`;

const safe = (storage) => storage ?? (typeof window !== 'undefined' ? window.localStorage : null);

export function isSpotlightDismissed(id, userId, storage) {
  try { return safe(storage)?.getItem(spotlightKey(id, userId)) === '1'; } catch { return false; }
}

export function dismissSpotlight(id, userId, storage) {
  try { safe(storage)?.setItem(spotlightKey(id, userId), '1'); } catch { /* private mode: dismissal lasts for this page view only */ }
}
