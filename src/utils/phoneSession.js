// Is the Doctor app unlocked right now? Kept only in memory on purpose: opening the
// app from the Home Screen is a fresh start, so it is always locked until the code
// from the computer (or a fresh QR / sign-in code) is entered. After that it stays
// open while in use, and locks again if the phone was away for LOCK_AFTER_MS (1 hour).

export const LOCK_AFTER_MS = 60 * 60 * 1000;

let state = { unlockedAt: null, lastSeen: null };

export const markPhoneUnlocked = (now = Date.now()) => { state = { unlockedAt: now, lastSeen: now }; };

/** Record that the app is in use right now (does nothing while locked). */
export const touchPhone = (now = Date.now()) => { if (state.unlockedAt != null) state.lastSeen = now; };

export const isPhoneUnlocked = (now = Date.now(), afterMs = LOCK_AFTER_MS) =>
  state.unlockedAt != null && now - state.lastSeen <= afterMs;

export const resetPhoneSession = () => { state = { unlockedAt: null, lastSeen: null }; };
