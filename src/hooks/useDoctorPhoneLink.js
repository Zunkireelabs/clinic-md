import { useEffect, useRef, useState, useCallback } from 'react';
import { supabase } from '../lib/supabase';

// Links a doctor's phone to their computer through the doctor's login. Both
// join one channel named after the user: the phone announces itself
// (kind 'doctor-phone') and waits; the computer sends 'open' (patient to open,
// whether to start recording) and 'close' (consultation finished).

const newDeviceId = () => (globalThis.crypto?.randomUUID?.() ?? `d-${Math.random().toString(36).slice(2)}`);

export default function useDoctorPhoneLink(userId, { kind, label, bookingId = null, onOpen, onClose } = {}) {
  const deviceIdRef = useRef(newDeviceId());
  const channelRef = useRef(null);
  const handlersRef = useRef({});
  handlersRef.current = { onOpen, onClose };
  const bookingIdRef = useRef(bookingId);
  bookingIdRef.current = bookingId;
  const [devices, setDevices] = useState([]);

  useEffect(() => {
    if (!userId) return undefined;
    const deviceId = deviceIdRef.current;
    const channel = supabase.channel(`doctor-phone-${userId}`, {
      config: { presence: { key: deviceId }, broadcast: { self: false } },
    });

    channel
      .on('presence', { event: 'sync' }, () => {
        setDevices(
          Object.values(channel.presenceState())
            .flat()
            .map((p) => ({ deviceId: p.deviceId, kind: p.kind, label: p.label, bookingId: p.bookingId || null })),
        );
      })
      .on('broadcast', { event: 'open' }, ({ payload }) => handlersRef.current.onOpen?.(payload))
      .on('broadcast', { event: 'close' }, ({ payload }) => handlersRef.current.onClose?.(payload))
      .subscribe(async (status) => {
        if (status === 'SUBSCRIBED') await channel.track({ deviceId, kind, label, bookingId: bookingIdRef.current });
      });

    channelRef.current = channel;
    return () => {
      supabase.removeChannel(channel);
      channelRef.current = null;
      setDevices([]);
    };
  }, [userId, kind, label]);

  // Tell the other device which patient this one is on whenever that changes.
  useEffect(() => {
    channelRef.current?.track({ deviceId: deviceIdRef.current, kind, label, bookingId });
  }, [bookingId, kind, label]);

  const send = useCallback((event, payload) => {
    channelRef.current?.send({ type: 'broadcast', event, payload });
  }, []);

  return {
    deviceId: deviceIdRef.current,
    devices,
    phones: devices.filter((d) => d.kind === 'doctor-phone'),
    openOnPhone: useCallback((bookingId, { autoStart = false } = {}) => send('open', { bookingId, autoStart }), [send]),
    closeOnPhone: useCallback((bookingId) => send('close', { bookingId }), [send]),
  };
}
