import React, { useEffect, useRef, useState } from 'react';
import { useNavigate, useSearchParams, Link } from 'react-router-dom';
import Icon from '../../components/AppIcon';
import { useAuth } from '../../contexts/AuthContext';
import { redeemPhonePairing } from '../../services/api';
import { phoneDestination } from '../../utils/phonePairing';
import { markPhoneUnlocked } from '../../utils/phoneSession';

// Landing page for the QR code: signs this phone in as the doctor who showed
// the code, then opens the Doctor phone page. No typing needed.
const PhonePair = () => {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const { profile } = useAuth();
  const code = searchParams.get('code');
  const org = searchParams.get('org');
  const booking = searchParams.get('booking');

  const [state, setState] = useState(code ? 'working' : 'error');
  const [message, setMessage] = useState(code ? '' : 'This link is missing its pairing code. Show the QR code on the computer again.');
  const startedRef = useRef(false);

  useEffect(() => {
    if (!code || startedRef.current) return;
    startedRef.current = true;
    (async () => {
      const { error } = await redeemPhonePairing({ code });
      if (error) {
        setState('error');
        setMessage(error.message);
      } else {
        markPhoneUnlocked(); // a fresh QR scan counts as entering the code
        setState('signed-in');
      }
    })();
  }, [code]);

  // Wait until the app has loaded the new session's profile before moving on.
  useEffect(() => {
    if (state === 'signed-in' && profile) {
      navigate(phoneDestination({ org: org || profile.organizations?.slug, booking }), { replace: true });
    }
  }, [state, profile, org, booking, navigate]);

  return (
    <div className="min-h-screen bg-background flex items-center justify-center p-6">
      <div className="w-full max-w-sm text-center space-y-4">
        {state !== 'error' ? (
          <>
            <div className="animate-spin w-10 h-10 border-2 border-primary border-t-transparent rounded-full mx-auto" />
            <p className="font-body text-text-secondary">Connecting your phone…</p>
          </>
        ) : (
          <>
            <Icon name="AlertCircle" size={40} className="text-error mx-auto" />
            <p className="font-body text-text-secondary">{message}</p>
            <Link to={org ? `/${org}/login` : '/login'} className="inline-block text-primary font-medium text-sm">
              Log in with email instead
            </Link>
          </>
        )}
      </div>
    </div>
  );
};

export default PhonePair;
