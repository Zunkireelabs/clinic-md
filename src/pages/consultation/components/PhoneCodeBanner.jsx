import React, { useEffect, useState, useCallback } from 'react';
import Icon from '../../../components/AppIcon';
import Button from '../../../components/ui/Button';
import { createPhonePairing } from '../../../services/api';
import { formatShortCode, secondsLeft } from '../../../utils/phonePairing';

// Shown on the computer after a notification was sent to the doctor's phone. The
// doctor taps it, then types this code on the phone to get in and record.
const PhoneCodeBanner = ({ initial, via = 'notification' }) => {
  const [code, setCode] = useState(initial); // { shortCode, expiresAt }
  const [left, setLeft] = useState(() => (initial ? secondsLeft(initial.expiresAt) : 0));
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!code) return undefined;
    setLeft(secondsLeft(code.expiresAt));
    const t = setInterval(() => setLeft(secondsLeft(code.expiresAt)), 1000);
    return () => clearInterval(t);
  }, [code]);

  const newCode = useCallback(async () => {
    setBusy(true);
    const { shortCode, expiresAt, error } = await createPhonePairing({ purpose: 'verify' });
    if (!error) setCode({ shortCode, expiresAt });
    setBusy(false);
  }, []);

  const expired = !!code && left === 0;

  return (
    <div className="px-4 py-3 bg-primary/5 border border-primary/20 rounded-xl flex flex-wrap items-center justify-between gap-3">
      <div className="flex items-start gap-3">
        <Icon name="BellRing" size={20} className="text-primary mt-0.5 shrink-0" />
        <div className="text-sm text-text-primary">
          <p className="font-medium">{via === 'app' ? 'Your phone is asking for the code' : 'Notification sent to your phone'}</p>
          <p className="text-text-secondary">
            {via === 'app' ? 'Enter this code in the Doctor app.' : 'Tap it, then enter this code on the phone.'}
          </p>
        </div>
      </div>
      {code ? (
        <div className="text-right">
          <p className={`font-mono text-2xl leading-none tracking-widest ${expired ? 'text-text-tertiary line-through' : 'text-text-primary'}`}>
            {formatShortCode(code.shortCode)}
          </p>
          {expired ? (
            <Button variant="primary" size="xs" iconName="RefreshCw" iconPosition="left" loading={busy} onClick={newCode}>New code</Button>
          ) : (
            <p className="text-xs text-text-tertiary">Valid for {Math.floor(left / 60)}:{String(left % 60).padStart(2, '0')} · works once</p>
          )}
        </div>
      ) : (
        <Button variant="outline" size="sm" loading={busy} onClick={newCode}>Show code</Button>
      )}
    </div>
  );
};

export default PhoneCodeBanner;
