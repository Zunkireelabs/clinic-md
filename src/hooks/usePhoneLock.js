import { useState, useEffect, useCallback, useRef } from 'react';
import { isPhoneUnlocked, markPhoneUnlocked, touchPhone } from '../utils/phoneSession';

/** Lock state for the Doctor app. Starts locked; locks again after the phone was away for a minute. */
export default function usePhoneLock() {
  const [locked, setLocked] = useState(() => !isPhoneUnlocked());
  const lockedRef = useRef(locked);
  lockedRef.current = locked;

  useEffect(() => {
    const touch = () => { if (!lockedRef.current) touchPhone(); };
    const onVisibility = () => {
      if (document.visibilityState === 'hidden') { touch(); return; }
      if (!isPhoneUnlocked()) setLocked(true);
      else touch();
    };
    const timer = setInterval(() => { if (document.visibilityState === 'visible') touch(); }, 15000);
    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('pagehide', touch);
    window.addEventListener('pointerdown', touch);
    return () => {
      clearInterval(timer);
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('pagehide', touch);
      window.removeEventListener('pointerdown', touch);
    };
  }, []);

  const unlock = useCallback(() => { markPhoneUnlocked(); setLocked(false); }, []);
  return { locked, unlock };
}
