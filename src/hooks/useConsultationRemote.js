import { useEffect, useRef, useState, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import { isMobileDevice, deviceLabel } from '../utils/remoteDevices';

// Lets the computer tell a phone that has the same consultation open to start
// or stop recording, and shows the phone's recording state on the computer.
// Devices find each other through Realtime presence on a per-consultation
// channel; start/stop and state updates travel as broadcast messages.

const newDeviceId = () => (globalThis.crypto?.randomUUID?.() ?? `d-${Math.random().toString(36).slice(2)}`);

export default function useConsultationRemote(consultationId, { onCommand, onState, onActivity } = {}) {
  const deviceIdRef = useRef(newDeviceId());
  const channelRef = useRef(null);
  const handlersRef = useRef({});
  handlersRef.current = { onCommand, onState, onActivity };
  const [devices, setDevices] = useState([]);

  useEffect(() => {
    if (!consultationId) return undefined;
    const deviceId = deviceIdRef.current;
    const channel = supabase.channel(`consultation-remote-${consultationId}`, {
      config: { presence: { key: deviceId }, broadcast: { self: false } },
    });

    channel
      .on('presence', { event: 'sync' }, () => {
        setDevices(
          Object.values(channel.presenceState())
            .flat()
            .map((p) => ({ deviceId: p.deviceId, isMobile: !!p.isMobile, label: p.label })),
        );
      })
      .on('broadcast', { event: 'command' }, ({ payload }) => handlersRef.current.onCommand?.(payload))
      .on('broadcast', { event: 'state' }, ({ payload }) => handlersRef.current.onState?.(payload))
      .on('broadcast', { event: 'activity' }, ({ payload }) => handlersRef.current.onActivity?.(payload))
      .subscribe(async (status) => {
        if (status === 'SUBSCRIBED') {
          await channel.track({ deviceId, isMobile: isMobileDevice(), label: deviceLabel() });
        }
      });

    channelRef.current = channel;
    return () => {
      supabase.removeChannel(channel);
      channelRef.current = null;
      setDevices([]);
    };
  }, [consultationId]);

  const send = useCallback((event, payload) => {
    channelRef.current?.send({ type: 'broadcast', event, payload: { ...payload, from: deviceIdRef.current } });
  }, []);

  return {
    deviceId: deviceIdRef.current,
    devices,
    sendCommand: useCallback((command) => send('command', command), [send]),
    sendState: useCallback((state) => send('state', state), [send]),
    sendActivity: useCallback((activity) => send('activity', activity), [send]),
  };
}
