import { useEffect, useState } from 'react';

// Keeps the phone screen on while the Doctor phone page is open, so the page
// stays connected and can start recording when the computer asks. Needs https.
export default function useWakeLock(enabled = true) {
  const supported = typeof navigator !== 'undefined' && 'wakeLock' in navigator;
  const [active, setActive] = useState(false);

  useEffect(() => {
    if (!supported || !enabled) { setActive(false); return undefined; }
    let lock = null;
    let cancelled = false;

    const acquire = async () => {
      try {
        lock = await navigator.wakeLock.request('screen');
        if (cancelled) { lock.release?.(); return; }
        setActive(true);
        lock.addEventListener('release', () => setActive(false));
      } catch {
        setActive(false); // e.g. battery saver, or the tab is hidden
      }
    };
    const onVisible = () => { if (document.visibilityState === 'visible') acquire(); };

    acquire();
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      cancelled = true;
      document.removeEventListener('visibilitychange', onVisible);
      lock?.release?.();
    };
  }, [supported, enabled]);

  return { supported, active };
}
