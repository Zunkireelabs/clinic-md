import React, { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import Icon from '../../../components/AppIcon';
import { redeemPhonePairing } from '../../../services/api';
import { normalizeShortCode, isCompleteShortCode, formatShortCode } from '../../../utils/phonePairing';
import { markPhoneUnlocked } from '../../../utils/phoneSession';

// Shown while this phone (or Home Screen app) is not signed in. Type the 6-digit
// code shown on the computer's "Continue on phone" panel instead of an email and
// password. On success the app's session changes and the page behind this one
// takes over by itself.
const ConnectPhone = ({ orgSlug }) => {
  const [digits, setDigits] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submittedRef = useRef(false);

  let org = orgSlug;
  if (!org) {
    try { org = localStorage.getItem('clinicmd-phone-org'); } catch { /* ignore */ }
  }

  const submit = async (value) => {
    if (submittedRef.current) return;
    submittedRef.current = true;
    setBusy(true);
    setError(null);
    const { error: redeemError } = await redeemPhonePairing({ shortCode: value });
    if (redeemError) {
      setError(redeemError.message);
      setDigits('');
      submittedRef.current = false;
    } else {
      markPhoneUnlocked(); // typing the sign-in code counts as entering the code
    }
    setBusy(false);
  };

  // Submit as soon as the sixth digit is typed.
  useEffect(() => {
    if (isCompleteShortCode(digits)) submit(normalizeShortCode(digits));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [digits]);

  return (
    <div className="min-h-screen bg-background flex items-center justify-center p-6">
      <div className="w-full max-w-sm text-center space-y-5">
        <div className="mx-auto w-16 h-16 rounded-full bg-primary/10 flex items-center justify-center">
          <Icon name="Smartphone" size={28} className="text-primary" />
        </div>
        <div>
          <h1 className="font-heading font-heading-semibold text-xl text-text-primary">Connect this phone</h1>
          <p className="text-sm text-text-secondary mt-1">
            On the computer, open a consultation, tap <strong>Continue on phone</strong>, and type the 6-digit code shown there.
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

        {busy && <p className="text-sm text-text-secondary flex items-center justify-center gap-2"><span className="animate-spin w-4 h-4 border-2 border-primary border-t-transparent rounded-full" />Connecting…</p>}
        {error && <p className="text-sm text-error">{error}</p>}

        <Link to={org ? `/${org}/login` : '/login'} className="inline-block text-primary font-medium text-sm">
          Log in with email instead
        </Link>
      </div>
    </div>
  );
};

export default ConnectPhone;
