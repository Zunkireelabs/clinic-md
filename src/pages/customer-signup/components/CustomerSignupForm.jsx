import React, { useState, useEffect, useRef } from 'react';
import { authInputClass, authButtonClass, AuthError } from 'components/ui/AuthCard';
import { useNavigate, useParams, Link } from 'react-router-dom';
import { useCustomerAuth } from 'contexts/CustomerAuthContext';
import { useTenant } from 'contexts/TenantContext';
import CountryCodeSelect from 'components/ui/CountryCodeSelect';
import { toE164 } from 'utils/phone';
import OtpCodeStep from 'pages/customer-login/components/OtpCodeStep';

const CustomerSignupForm = () => {
  const navigate = useNavigate();
  const { orgSlug } = useParams();
  const { orgId } = useTenant();
  const { requestOtp, customer, customerProfile } = useCustomerAuth();
  const [step, setStep] = useState('details'); // 'details' | 'code'
  const [fullName, setFullName] = useState('');
  const [email, setEmail] = useState('');
  const [phoneCountryCode, setPhoneCountryCode] = useState('+977');
  const [phone, setPhone] = useState('');
  const [errors, setErrors] = useState({});
  const [isLoading, setIsLoading] = useState(false);
  const hasRedirected = useRef(false);

  // Single source of truth for the post-signup redirect. handleSubmit does
  // NOT navigate itself, to avoid a second, racing navigation.
  useEffect(() => {
    if (customer && customerProfile && !hasRedirected.current) {
      hasRedirected.current = true;
      navigate(`/${orgSlug}/account`, { replace: true });
    }
  }, [customer, customerProfile, orgSlug, navigate]);

  const validateForm = () => {
    const newErrors = {};

    if (!fullName.trim()) {
      newErrors.fullName = 'Name is required';
    }

    if (!email) {
      newErrors.email = 'Email is required';
    } else if (!/\S+@\S+\.\S+/.test(email)) {
      newErrors.email = 'Please enter a valid email';
    }

    if (!phone.trim()) {
      newErrors.phone = 'Phone is required';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = async (e) => {
    e.preventDefault();

    if (!validateForm()) return;

    setIsLoading(true);
    setErrors({});

    const fullPhone = toE164(phone.trim(), phoneCountryCode);

    try {
      await requestOtp(email, { fullName: fullName.trim(), phone: fullPhone, shouldCreateUser: true });
      setStep('code');
    } catch (error) {
      setErrors({
        submit: error.message || 'An unexpected error occurred. Please try again.'
      });
    } finally {
      setIsLoading(false);
    }
  };

  if (step === 'code') {
    return (
      <OtpCodeStep
        email={email}
        orgId={orgId}
        resendPayload={{ fullName: fullName.trim(), phone: toE164(phone.trim(), phoneCountryCode), shouldCreateUser: true }}
        onVerified={() => {
          // Redirect happens via the effect above once customer/customerProfile land.
        }}
        onBack={() => setStep('details')}
      />
    );
  }

  return (
    <div className="w-full">
      {errors.submit && (
        <AuthError>
          {errors.submit}
        </AuthError>
      )}

      <form onSubmit={handleSubmit} autoComplete="off">
        <div className="mb-3">
          <input
            type="text"
            value={fullName}
            onChange={(e) => {
              setFullName(e.target.value);
              if (errors.fullName) setErrors(prev => ({ ...prev, fullName: '' }));
            }}
            placeholder="Full name"
            disabled={isLoading}
            className={authInputClass(!!errors.fullName)}
          />
          {errors.fullName && (
            <p className="mt-1.5 text-xs text-error">{errors.fullName}</p>
          )}
        </div>

        <div className="mb-3">
          <input
            type="text"
            autoComplete="off"
            value={email}
            onChange={(e) => {
              setEmail(e.target.value);
              if (errors.email) setErrors(prev => ({ ...prev, email: '' }));
            }}
            placeholder="Email address"
            disabled={isLoading}
            className={authInputClass(!!errors.email)}
          />
          {errors.email && (
            <p className="mt-1.5 text-xs text-error">{errors.email}</p>
          )}
        </div>

        <div className="mb-4">
          <div className="flex">
            <CountryCodeSelect
              value={phoneCountryCode}
              onChange={setPhoneCountryCode}
              disabled={isLoading}
            />
            <input
              type="tel"
              value={phone}
              onChange={(e) => {
                setPhone(e.target.value);
                if (errors.phone) setErrors(prev => ({ ...prev, phone: '' }));
              }}
              placeholder="9841234567"
              disabled={isLoading}
              className={`${authInputClass(!!errors.phone)} flex-1 min-w-0 rounded-l-none`}
            />
          </div>
          {errors.phone && (
            <p className="mt-1.5 text-xs text-error">{errors.phone}</p>
          )}
        </div>

        <button
          type="submit"
          disabled={isLoading}
          className={authButtonClass}
        >
          {isLoading ? 'Sending code...' : 'Create Account'}
        </button>
      </form>

      <p className="mt-5 text-center text-sm text-text-secondary">
        Already have an account?{' '}
        <Link
          to={`/${orgSlug}/customer-login`}
          className="text-text-primary font-medium underline underline-offset-2 hover:opacity-80 transition-opacity"
        >
          Sign in
        </Link>
      </p>
    </div>
  );
};

export default CustomerSignupForm;
