import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import { urlBase64ToUint8Array, subscriptionToRow, pushStatus } from '../utils/pushHelpers';

const VAPID_PUBLIC_KEY = import.meta.env.VITE_VAPID_PUBLIC_KEY;

const detect = () => {
  const ua = navigator.userAgent;
  return {
    hasPushManager: 'PushManager' in window && 'serviceWorker' in navigator,
    hasNotification: 'Notification' in window,
    permission: 'Notification' in window ? Notification.permission : 'denied',
    isIos: /iPhone|iPad|iPod/i.test(ua) || (/Macintosh/i.test(ua) && navigator.maxTouchPoints > 1),
    isStandalone: window.matchMedia?.('(display-mode: standalone)').matches || navigator.standalone === true,
  };
};

/** Turn "tap to record" notifications on for this phone. */
export default function usePushNotifications(profile) {
  const [status, setStatus] = useState(() => pushStatus(detect()));
  const [subscribed, setSubscribed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const configured = !!VAPID_PUBLIC_KEY;

  const refresh = useCallback(async () => {
    const env = detect();
    setStatus(pushStatus(env));
    if (!env.hasPushManager) return;
    try {
      const reg = await navigator.serviceWorker.getRegistration('/sw.js');
      const sub = await reg?.pushManager.getSubscription();
      setSubscribed(!!sub && env.permission === 'granted');
    } catch { /* ignore */ }
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  // Self-heal: if this phone is subscribed but the server lost the row (or it never
  // arrived), save it again so notifications keep working.
  useEffect(() => {
    if (!profile?.id || !subscribed) return;
    (async () => {
      try {
        const reg = await navigator.serviceWorker.getRegistration('/sw.js');
        const sub = await reg?.pushManager.getSubscription();
        if (!sub) return;
        await supabase.from('push_subscriptions').upsert(
          { ...subscriptionToRow(sub), user_id: profile.id, org_id: profile.org_id, user_agent: navigator.userAgent.slice(0, 200) },
          { onConflict: 'endpoint' },
        );
      } catch { /* best effort */ }
    })();
  }, [profile?.id, profile?.org_id, subscribed]);

  const enable = useCallback(async () => {
    setError(null);
    if (!configured) { setError('Notifications are not configured on this server yet.'); return; }
    setBusy(true);
    try {
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') { await refresh(); return; }

      const reg = await navigator.serviceWorker.register('/sw.js');
      await navigator.serviceWorker.ready;
      const sub = (await reg.pushManager.getSubscription())
        || (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY) }));

      const { error: saveError } = await supabase.from('push_subscriptions').upsert(
        { ...subscriptionToRow(sub), user_id: profile.id, org_id: profile.org_id, user_agent: navigator.userAgent.slice(0, 200) },
        { onConflict: 'endpoint' },
      );
      if (saveError) throw saveError;
      setSubscribed(true);
    } catch (e) {
      setError(e.message || 'Could not turn on notifications.');
    } finally {
      setBusy(false);
      refresh();
    }
  }, [configured, profile, refresh]);

  const disable = useCallback(async () => {
    setBusy(true);
    try {
      const reg = await navigator.serviceWorker.getRegistration('/sw.js');
      const sub = await reg?.pushManager.getSubscription();
      if (sub) {
        await supabase.from('push_subscriptions').delete().eq('endpoint', sub.endpoint);
        await sub.unsubscribe();
      }
      setSubscribed(false);
    } catch (e) {
      setError(e.message || 'Could not turn off notifications.');
    } finally {
      setBusy(false);
    }
  }, []);

  return { status, subscribed, busy, error, configured, enable, disable };
}
