import React, { useState, useEffect, useCallback, useRef } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import Icon from '../../../components/AppIcon';
import Button from '../../../components/ui/Button';
import { createPhonePairing } from '../../../services/api';
import { buildPairingUrl, secondsLeft, formatShortCode } from '../../../utils/phonePairing';

// Shows a QR code that signs a phone in as this user and opens the Doctor phone
// page. Scanning needs no typing: the code is single-use and valid for 3 minutes.
// Both devices then edit one shared draft, so the phone can record and take
// X-ray / clinical photos while this screen updates live.

const isLocalHost = (url) => /^https?:\/\/(localhost|127\.0\.0\.1)(:|\/|$)/i.test(url);

const formatLeft = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;

const PhoneHandoff = ({ orgSlug, bookingId, onClose, phoneCount = 0, phoneLabel }) => {
  const baseUrl = import.meta.env.VITE_PUBLIC_APP_URL || window.location.origin;
  const unreachable = isLocalHost(baseUrl);

  const [pairing, setPairing] = useState(null); // { code, expiresAt }
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);
  const [left, setLeft] = useState(0);
  const [copied, setCopied] = useState(false);

  const newCode = useCallback(async () => {
    setLoading(true);
    setFailed(false);
    const { code, shortCode, expiresAt, error } = await createPhonePairing();
    if (error) {
      setPairing(null);
      setFailed(true);
    } else {
      setPairing({ code, shortCode, expiresAt });
      setLeft(secondsLeft(expiresAt));
    }
    setLoading(false);
  }, []);

  useEffect(() => { newCode(); }, [newCode]);

  useEffect(() => {
    if (!pairing) return undefined;
    const t = setInterval(() => setLeft(secondsLeft(pairing.expiresAt)), 1000);
    return () => clearInterval(t);
  }, [pairing]);

  // A phone joining while this panel is open means the scan worked: confirm, then close.
  const initialPhonesRef = useRef(phoneCount);
  const connected = phoneCount > initialPhonesRef.current;
  useEffect(() => {
    if (!connected) return undefined;
    const t = setTimeout(onClose, 1600);
    return () => clearTimeout(t);
  }, [connected, onClose]);

  const expired = !!pairing && left === 0 && !connected;
  const url = buildPairingUrl(baseUrl, { orgSlug, bookingId, code: pairing?.code });

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch { /* clipboard unavailable */ }
  };

  return (
    <div className="fixed inset-0 bg-text-primary/50 backdrop-blur-sm z-modal-overlay flex items-center justify-center p-4" onClick={onClose}>
      <div className="bg-surface rounded-spa-lg spa-shadow-modal w-full max-w-sm animate-fade-in" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between p-5 border-b border-border">
          <div className="flex items-center gap-2">
            <Icon name="Smartphone" size={18} className="text-primary" />
            <h2 className="font-heading font-heading-semibold text-lg text-text-primary">Connect your phone</h2>
          </div>
          <button onClick={onClose} aria-label="Close" className="p-1.5 rounded-md hover:bg-background">
            <Icon name="X" size={18} className="text-text-secondary" />
          </button>
        </div>

        {connected ? (
          <div className="p-8 text-center space-y-3">
            <div className="mx-auto w-14 h-14 rounded-full bg-success/10 flex items-center justify-center">
              <Icon name="CheckCircle" size={30} className="text-success" />
            </div>
            <p className="font-heading font-heading-semibold text-lg text-text-primary">{phoneLabel || 'Phone'} connected</p>
            <p className="text-sm text-text-secondary">Recordings and photos from the phone will appear on this page.</p>
          </div>
        ) : (
        <div className="p-5 space-y-4 text-center">
          <div className="inline-flex items-center justify-center w-[216px] h-[216px] p-3 bg-white rounded-lg border border-gray-200 relative">
            {loading ? (
              <div className="animate-spin w-8 h-8 border-2 border-primary border-t-transparent rounded-full" />
            ) : (
              <>
                <QRCodeSVG value={url} size={192} className={expired ? 'opacity-20' : ''} />
                {expired && (
                  <div className="absolute inset-0 flex flex-col items-center justify-center gap-2">
                    <p className="text-sm text-text-secondary">Code expired</p>
                    <Button variant="primary" size="sm" iconName="RefreshCw" iconPosition="left" onClick={newCode}>New code</Button>
                  </div>
                )}
              </>
            )}
          </div>

          {!loading && pairing && !expired && (
            <p className="text-xs text-text-tertiary">Valid for {formatLeft(left)} · works once</p>
          )}

          {!loading && pairing && !expired && pairing.shortCode && (
            <div className="bg-background rounded-lg border border-border p-3">
              <p className="text-xs text-text-tertiary mb-1">Using the Doctor app on the Home Screen? Type this code there:</p>
              <p className="font-mono text-3xl tracking-widest text-text-primary">{formatShortCode(pairing.shortCode)}</p>
            </div>
          )}

          <p className="text-sm text-text-secondary">
            Scan with your phone camera. It signs in as you automatically, no password. After that, just tap the Doctor icon on the phone whenever you want to record.
          </p>

          {failed && (
            <div className="p-3 bg-warning/10 border border-warning/30 rounded-md text-left text-xs text-text-secondary">
              Couldn't create an automatic sign-in code. The code below opens the phone page, but you'll need to log in on the phone.
              <button type="button" onClick={newCode} className="ml-1 text-primary font-medium">Try again</button>
            </div>
          )}
          {unreachable && (
            <div className="p-3 bg-warning/10 border border-warning/30 rounded-md text-left text-xs text-text-secondary">
              This address ({new URL(url).host}) only works on this computer. Set <code>VITE_PUBLIC_APP_URL</code> to an address your phone can reach (see <code>scripts/dev-phone.sh</code>) and restart.
            </div>
          )}
          <p className="text-xs text-text-tertiary">Only show this code to your own phone. Anyone who scans it within the time limit is signed in as you.</p>
          <Button variant="outline" size="sm" fullWidth iconName={copied ? 'Check' : 'Copy'} iconPosition="left" onClick={copy} disabled={loading}>
            {copied ? 'Copied' : 'Copy link'}
          </Button>
        </div>
        )}
      </div>
    </div>
  );
};

export default PhoneHandoff;
