// ClinicMD service worker: shows "tap to record" notifications for the Doctor
// phone and opens the right page when one is tapped. It does no caching.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { /* plain text push */ }

  const title = data.title || 'ClinicMD';
  const options = {
    body: data.body || 'Tap to open',
    icon: '/phone-icon-192.png',
    badge: '/phone-icon-192.png',
    tag: data.tag || 'clinicmd-consultation',
    renotify: true,
    requireInteraction: true,
    data: { url: data.url || '/phone' },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || '/phone', self.location.origin);

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const open = windows.find((c) => c.url.startsWith(self.location.origin));
    if (open) {
      // An app window is already open (iPhone often ignores navigate()), so tell it
      // which patient to open and whether to start recording.
      await open.focus();
      open.postMessage({
        type: 'open-consultation',
        bookingId: target.searchParams.get('booking'),
        autoStart: target.searchParams.get('autostart') === '1',
        verify: target.searchParams.get('verify') === '1',
      });
      return undefined;
    }
    return self.clients.openWindow(target.href);
  })());
});
