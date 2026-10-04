import React, { useEffect, useState } from 'react';
import Icon from '../../../components/AppIcon';
import { supabase } from '../../../lib/supabase';
import { useAuth } from '../../../contexts/AuthContext';
import { createPhonePairing } from '../../../services/api';
import { isMobileDevice } from '../../../utils/remoteDevices';
import { formatShortCode, secondsLeft } from '../../../utils/phonePairing';

// Shown on the computer, on any ClinicMD screen, when the doctor's phone asks to
// open the Doctor app. It carries a fresh one-time code to type on the phone, like
// a sign-in approval. Phones themselves never show it.
const PhoneUnlockPrompt = () => {
  const { profile } = useAuth();
  const [request, setRequest] = useState(null); // { label, shortCode, expiresAt }
  const [left, setLeft] = useState(0);

  useEffect(() => {
    if (!profile?.id || isMobileDevice()) return undefined;
    const channel = supabase
      .channel(`phone-unlock-${profile.id}`, { config: { broadcast: { self: false } } })
      .on('broadcast', { event: 'request' }, async ({ payload }) => {
        const { shortCode, expiresAt, error } = await createPhonePairing();
        if (!error) setRequest({ label: payload?.label || 'phone', shortCode, expiresAt });
      })
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [profile?.id]);

  useEffect(() => {
    if (!request) return undefined;
    setLeft(secondsLeft(request.expiresAt));
    const t = setInterval(() => {
      const s = secondsLeft(request.expiresAt);
      setLeft(s);
      if (s === 0) setRequest(null);
    }, 1000);
    return () => clearInterval(t);
  }, [request]);

  if (!request) return null;

  return (
    <div className="fixed bottom-4 right-4 z-modal-overlay w-[calc(100%-2rem)] max-w-sm">
      <div className="bg-white border border-primary/30 rounded-lg shadow-lg p-4">
        <div className="flex items-start gap-3">
          <Icon name="Smartphone" size={20} className="text-primary mt-0.5 shrink-0" />
          <div className="flex-1 text-sm">
            <p className="font-medium text-text-primary">Your {request.label} wants to open the Doctor app</p>
            <p className="text-text-secondary">Type this code on the phone. If this wasn't you, ignore it.</p>
            <p className="font-mono text-3xl tracking-widest text-text-primary my-2">{formatShortCode(request.shortCode)}</p>
            <p className="text-xs text-text-tertiary">Valid for {Math.floor(left / 60)}:{String(left % 60).padStart(2, '0')} · works once</p>
          </div>
          <button type="button" onClick={() => setRequest(null)} aria-label="Dismiss"><Icon name="X" size={16} className="text-text-tertiary" /></button>
        </div>
      </div>
    </div>
  );
};

export default PhoneUnlockPrompt;
