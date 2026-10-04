import React, { useEffect, useRef, useState } from 'react';
import Icon from '../../../components/AppIcon';
import { verifyPhoneCode } from '../../../services/api';
import { supabase } from '../../../lib/supabase';
import { useAuth } from '../../../contexts/AuthContext';
import { deviceLabel } from '../../../utils/remoteDevices';
import { normalizeShortCode, isCompleteShortCode, formatShortCode } from '../../../utils/phonePairing';

// Shown after a notification is tapped on a phone that is already signed in. The
// doctor types the 6-digit code shown on the computer; only then does the patient
// open and recording start. This keeps patient data closed if someone else picks
// up the phone and taps the notification.
const VerifyCode = ({ onVerified, onCancel, askComputer = false }) => {
  const { profile } = useAuth();
  const [requested, setRequested] = useState(false);
  const channelRef = useRef(null);
  const [digits, setDigits] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submittedRef = useRef(false);

  const submit = async (value) => {
    if (submittedRef.current) return;
    submittedRef.current = true;
    setBusy(true);
    setError(null);
    const { ok, error: verifyError } = await verifyPhoneCode(value);
    if (ok) {
      onVerified();
      return;
    }
    setError(verifyError.message);
    setDigits('');
    submittedRef.current = false;
    setBusy(false);
  };

  // Opening the app from the Home Screen: ask the computer to show a code. (A notification
  // tap does not ask: the code is already on the computer's consultation page.)
  const sendRequest = () => {
    channelRef.current?.send({ type: 'broadcast', event: 'request', payload: { label: deviceLabel() } });
    setRequested(true);
  };
  useEffect(() => {
    if (!askComputer || !profile?.id) return undefined;
    const channel = supabase.channel(`phone-unlock-${profile.id}`, { config: { broadcast: { self: false } } });
    channelRef.current = channel;
    channel.subscribe((status) => { if (status === 'SUBSCRIBED') sendRequest(); });
    return () => { supabase.removeChannel(channel); channelRef.current = null; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [askComputer, profile?.id]);

  useEffect(() => {
    if (isCompleteShortCode(digits)) submit(normalizeShortCode(digits));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [digits]);

  return (
    <div className="min-h-screen bg-background flex items-center justify-center p-6">
      <div className="w-full max-w-sm text-center space-y-5">
        <div className="mx-auto w-16 h-16 rounded-full bg-primary/10 flex items-center justify-center">
          <Icon name="ShieldCheck" size={28} className="text-primary" />
        </div>
        <div>
          <h1 className="font-heading font-heading-semibold text-xl text-text-primary">Enter the code from the computer</h1>
          <p className="text-sm text-text-secondary mt-1">
            {askComputer ? 'A 6-digit code is appearing on your computer. Type it here to open the Doctor app.' : 'The consultation page on the computer shows a 6-digit code. Type it here to open the patient.'}
          </p>
        </div>

        <input
          type="text"
          inputMode="numeric"
          autoComplete="one-time-code"
          autoFocus
          maxLength={7}
          value={formatShortCode(normalizeShortCode(digits)) || digits}
          onChange={(e) => setDigits(normalizeShortCode(e.target.value))}
          disabled={busy}
          placeholder="000 000"
          aria-label="6-digit code"
          className="w-full text-center font-mono text-3xl tracking-widest py-3 rounded-lg border-gray-300 focus:border-primary focus:ring-primary"
        />

        {busy && <p className="text-sm text-text-secondary flex items-center justify-center gap-2"><span className="animate-spin w-4 h-4 border-2 border-primary border-t-transparent rounded-full" />Checking…</p>}
        {error && <p className="text-sm text-error">{error}</p>}

        {askComputer && (
          <p className="text-xs text-text-tertiary">
            No code on the computer? Keep ClinicMD open there, then{' '}
            <button type="button" onClick={sendRequest} className="text-primary font-medium">send it again</button>
            {requested ? ' (sent)' : ''}.
          </p>
        )}
        {onCancel && <button type="button" onClick={onCancel} className="text-sm text-text-secondary font-medium">Cancel</button>}
      </div>
    </div>
  );
};

export default VerifyCode;
