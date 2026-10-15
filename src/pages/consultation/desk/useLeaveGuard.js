import { useContext, useEffect } from 'react';
import { UNSAFE_NavigationContext } from 'react-router-dom';

// While `active` (a recording or an upload is in flight): the browser asks before the tab is closed or reloaded, and in-app
// navigation (sidebar, breadcrumb, back) asks for confirmation. react-router 6.0 has no useBlocker, so this blocks the history object.
export default function useLeaveGuard(active, message = 'A recording is in progress. If you leave now it will be lost.') {
  const { navigator } = useContext(UNSAFE_NavigationContext);
  useEffect(() => {
    if (!active) return undefined;
    const onBeforeUnload = (e) => { e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', onBeforeUnload);
    let unblock = null;
    if (navigator?.block) {
      unblock = navigator.block((tx) => {
        if (window.confirm(message)) { unblock(); tx.retry(); }
      });
    }
    return () => { window.removeEventListener('beforeunload', onBeforeUnload); unblock?.(); };
  }, [active, navigator, message]);
}
