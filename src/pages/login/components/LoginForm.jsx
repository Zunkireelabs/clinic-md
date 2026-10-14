import React, { useState, useEffect } from 'react';
import { useLocation, useNavigate, useParams } from 'react-router-dom';
import Icon from '../../../components/AppIcon';
import { useAuth, getDashboardPath, getSafeRedirect } from '../../../contexts/AuthContext';
import { supabase } from '../../../lib/supabase';
import AuthCard, { AuthError, AuthDivider, authInputClass, authButtonClass, authSecondaryButtonClass } from '../../../components/ui/AuthCard';

// Helper: get saved emails for an org from localStorage
function getSavedEmails(orgSlug) {
  try {
    const key = `clinicmd_saved_emails_${orgSlug || 'default'}`;
    return JSON.parse(localStorage.getItem(key) || '[]');
  } catch { return []; }
}

// Helper: save email for an org to localStorage
function saveEmail(orgSlug, email) {
  const key = `clinicmd_saved_emails_${orgSlug || 'default'}`;
  const emails = getSavedEmails(orgSlug);
  if (!emails.includes(email)) {
    emails.unshift(email);
    // Keep max 5 saved emails
    localStorage.setItem(key, JSON.stringify(emails.slice(0, 5)));
  }
}

const LoginForm = ({ orgName, topRight }) => {
  const navigate = useNavigate();
  const location = useLocation();
  const { orgSlug: urlOrgSlug } = useParams();
  const { signIn, user, profile } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [errors, setErrors] = useState({});
  const [isLoading, setIsLoading] = useState(false);
  const [oauthLoading, setOauthLoading] = useState(null);
  const [savedEmails, setSavedEmails] = useState([]);
  const [showSavedEmails, setShowSavedEmails] = useState(false);
  // Two steps: identify (email) then authenticate (password / PIN). The step lives in the router state, so the browser Back button
  // goes from step 2 to step 1 (and `from`, the page the user was headed to, rides along untouched).
  const step = location.state?.step === 'password' ? 'password' : 'email';

  // Load saved emails on mount
  useEffect(() => {
    setSavedEmails(getSavedEmails(urlOrgSlug));
  }, [urlOrgSlug]);

  // Redirect if already authenticated
  useEffect(() => {
    if (user && profile) {
      const userOrgSlug = profile?.organizations?.slug;
      navigate(getSafeRedirect(location.state?.from, userOrgSlug) || getDashboardPath(profile.role, userOrgSlug), { replace: true });
    }
  }, [user, profile, navigate]); // eslint-disable-line react-hooks/exhaustive-deps

  const handleOAuth = async (provider) => {
    setOauthLoading(provider);
    setErrors({});

    try {
      const { error } = await supabase.auth.signInWithOAuth({
        provider,
        options: {
          redirectTo: `${window.location.origin}/auth/callback`,
        },
      });
      if (error) throw error;
    } catch (err) {
      setErrors({ submit: err.message || 'OAuth failed' });
      setOauthLoading(null);
    }
  };

  // Step 1 checks the email's format only: no server call, so nothing reveals whether the account exists.
  const validateEmail = () => {
    if (!email.trim()) { setErrors({ email: 'Email is required' }); return false; }
    if (!/\S+@\S+\.\S+/.test(email.trim())) { setErrors({ email: 'Please enter a valid email' }); return false; }
    setErrors({});
    return true;
  };

  const goToPasswordStep = (e) => {
    e.preventDefault();
    if (!validateEmail()) return;
    setEmail(email.trim());
    navigate(`${location.pathname}${location.search}`, { state: { ...(location.state || {}), step: 'password' } });
  };

  const backToEmailStep = () => {
    setErrors({});
    setPassword('');
    const { step: _step, ...rest } = location.state || {};
    navigate(`${location.pathname}${location.search}`, { replace: true, state: Object.keys(rest).length ? rest : null });
  };

  const validateForm = () => {
    const newErrors = {};

    if (!email) {
      newErrors.email = 'Email is required';
    } else if (!/\S+@\S+\.\S+/.test(email)) {
      newErrors.email = 'Please enter a valid email';
    }

    if (!password) {
      newErrors.password = 'Password or PIN is required';
    } else if (password.length < 4) {
      newErrors.password = 'Must be at least 4 characters';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const PIN_GENERIC_ERROR = 'Invalid email or password/PIN. Please try again.';

  // Request a fresh OTP from the pin-login Edge Function.
  // (service role key stays server-side, never exposed to browser)
  const requestPinOtp = async (userEmail, pin) => {
    const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;
    const res = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/pin-login`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        // Edge Function has verify_jwt enabled — the public anon key is a valid JWT.
        'apikey': anonKey,
        'Authorization': `Bearer ${anonKey}`,
      },
      body: JSON.stringify({ email: userEmail, pin, org_slug: urlOrgSlug || null }),
    });

    // A non-JSON body (function missing, gateway error) must not surface as a raw parse error.
    const pinData = await res.json().catch(() => ({}));
    // The Edge Function has shipped under two response shapes across
    // deployments (`otp` and `email_otp`); accept either so login works
    // regardless of which version a given environment is running.
    const otp = pinData.email_otp || pinData.otp;
    if (!pinData.success || !otp) {
      return { otp: null, error: pinData.error || 'PIN login failed.' };
    }
    return { otp, error: null };
  };

  const handlePinLogin = async (userEmail, pin) => {
    // The recovery OTP is single-use and is rotated on every pin-login call,
    // so a transient verify failure (network blip, races) can leave a stale
    // token. Retry once with a fresh OTP before surfacing the error.
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const { otp, error: otpReqError } = await requestPinOtp(userEmail, pin);
      if (!otp) {
        // A bad PIN won't succeed on retry — fail fast. Always show the same generic message as a wrong password, so the
        // response never hints whether the account exists; keep the server's detail in the console for debugging.
        console.warn('[LoginForm] PIN login failed:', otpReqError);
        return { success: false, error: PIN_GENERIC_ERROR };
      }

      const { data: otpData, error: otpError } = await supabase.auth.verifyOtp({
        email: userEmail,
        token: otp,
        type: 'email',
      });

      if (!otpError && otpData?.session) {
        return { success: true, session: otpData.session, user: otpData.user };
      }
      lastError = otpError?.message || 'Session creation failed.';
    }

    console.warn('[LoginForm] PIN session creation failed:', lastError);
    return { success: false, error: PIN_GENERIC_ERROR };
  };

  const handleSubmit = async (e) => {
    e.preventDefault();

    if (!validateForm()) return;

    setIsLoading(true);
    setErrors({});

    try {
      const inputValue = password.trim();
      const isPin = /^\d{4}$/.test(inputValue);

      if (isPin) {
        // PIN login flow
        const pinResult = await handlePinLogin(email, inputValue);
        if (!pinResult.success) {
          setErrors({ submit: pinResult.error });
          setIsLoading(false);
          return;
        }

        // PIN login successful — session is set, fetch profile
        saveEmail(urlOrgSlug, email);
        // Reload to let AuthContext pick up the session
        window.location.href = getSafeRedirect(location.state?.from, urlOrgSlug) || getDashboardPath(null, urlOrgSlug || 'bright-smile-dental');
        return;
      }

      // Standard password login
      const result = await signIn(email, inputValue);
      if (result.profile) {
        // Save email on successful login
        saveEmail(urlOrgSlug, email);

        const userOrgSlug = result.profile?.organizations?.slug;

        if (urlOrgSlug && userOrgSlug && urlOrgSlug !== userOrgSlug) {
          navigate(getDashboardPath(result.profile.role, userOrgSlug), { replace: true });
          return;
        }

        navigate(getSafeRedirect(location.state?.from, userOrgSlug) || getDashboardPath(result.profile.role, userOrgSlug), { replace: true });
        return;
      }
      setErrors({
        submit: 'Login succeeded but your staff profile was not found. Please contact an administrator.'
      });
    } catch (error) {
      setErrors({
        submit: error.message === 'Invalid login credentials'
          ? 'Invalid email or password/PIN. Please try again.'
          : error.message || 'An unexpected error occurred. Please try again.'
      });
    } finally {
      setIsLoading(false);
    }
  };

  const handleSelectSavedEmail = (savedEmail) => {
    setEmail(savedEmail);
    setShowSavedEmails(false);
    // Focus password field
    setTimeout(() => document.getElementById('password-field')?.focus(), 100);
  };

  const handleRemoveSavedEmail = (e, emailToRemove) => {
    e.stopPropagation();
    const key = `clinicmd_saved_emails_${urlOrgSlug || 'default'}`;
    const updated = savedEmails.filter(e => e !== emailToRemove);
    localStorage.setItem(key, JSON.stringify(updated));
    setSavedEmails(updated);
  };

  useEffect(() => { if (step === 'password') setTimeout(() => document.getElementById('password-field')?.focus(), 50); }, [step]);

  const isDisabled = isLoading || oauthLoading;

  const clinic = orgName || 'ClinicMD';

  const googleIcon = (
    <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">
      <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"/>
      <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"/>
      <path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"/>
      <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"/>
    </svg>
  );
  const microsoftIcon = (
    <svg viewBox="0 0 23 23" width="18" height="18" aria-hidden="true">
      <path fill="#f35325" d="M1 1h10v10H1z"/>
      <path fill="#81bc06" d="M12 1h10v10H12z"/>
      <path fill="#05a6f0" d="M1 12h10v10H1z"/>
      <path fill="#ffba08" d="M12 12h10v10H12z"/>
    </svg>
  );

  const savedMatches = savedEmails.filter((se) => (!email || se.toLowerCase().includes(email.toLowerCase())) && se !== email);

  const below = (
    <>
      <p className="text-center text-sm text-text-secondary">
        Don't have an account?{' '}
        <button type="button" className="text-text-primary font-medium underline underline-offset-2 hover:opacity-80 transition-opacity">
          Contact admin
        </button>
      </p>
      {step === 'email' && import.meta.env.DEV && (
        <div className="mt-6 p-4 bg-accent/5 border border-accent/20 rounded-spa-lg">
          <div className="flex items-center gap-2 mb-3">
            <Icon name="Info" size={16} className="text-accent" />
            <span className="text-sm font-medium text-text-primary">Demo Credentials</span>
          </div>
          <div className="space-y-1.5 text-xs text-text-secondary font-mono">
            <div><strong>Staff:</strong> staff@clinicmd.app / ClinicMD@Staff123</div>
            <div><strong>Manager:</strong> manager@clinicmd.app / ClinicMD@Manager123</div>
            <div><strong>Admin:</strong> admin@clinicmd.app / ClinicMD@Admin123</div>
          </div>
        </div>
      )}
    </>
  );

  if (step === 'password') {
    return (
      <AuthCard title="Enter your password" subtitle={<>Sign in to <span className="font-medium text-text-primary">{clinic}</span></>} topRight={topRight} showFooter below={below}>
        <form onSubmit={handleSubmit} autoComplete="on">
          {/* Identifier-first pattern: keep the email in a hidden username field so password managers save and fill the pair. */}
          <input type="text" name="username" autoComplete="username" value={email} readOnly tabIndex={-1} aria-hidden="true" className="sr-only" />

          <div className="mb-4 flex items-center justify-between gap-3 h-11 px-3.5 bg-background border border-border rounded-spa-lg">
            <span className="text-sm text-text-primary truncate" data-testid="email-chip">{email}</span>
            <button type="button" onClick={backToEmailStep} disabled={isDisabled} className="text-sm text-text-secondary hover:text-primary underline underline-offset-2 flex-shrink-0">
              Edit
            </button>
          </div>

          {errors.submit && <AuthError>{errors.submit}</AuthError>}

          <div className="mb-2">
            <div className="relative">
              <input
                id="password-field"
                name="password"
                autoComplete="current-password"
                type={showPassword ? 'text' : 'password'}
                value={password}
                onChange={(e) => { setPassword(e.target.value); if (errors.password) setErrors((prev) => ({ ...prev, password: '' })); }}
                placeholder="Password or PIN"
                disabled={isDisabled}
                className={`${authInputClass(!!errors.password)} pr-11`}
              />
              <button
                type="button"
                onClick={() => setShowPassword(!showPassword)}
                disabled={isDisabled}
                className="absolute right-3 top-1/2 -translate-y-1/2 p-1 text-text-secondary hover:text-text-primary transition-colors disabled:opacity-50"
                aria-label={showPassword ? 'Hide password' : 'Show password'}
              >
                <Icon name={showPassword ? 'EyeOff' : 'Eye'} size={18} />
              </button>
            </div>
            {errors.password && <p className="mt-1.5 text-xs text-error">{errors.password}</p>}
          </div>

          <div className="mb-5 text-right">
            <button type="button" className="text-sm text-text-primary font-medium hover:opacity-80 transition-opacity underline underline-offset-2">
              Forgot password?
            </button>
          </div>

          <button type="submit" disabled={isDisabled} className={authButtonClass}>
            {isLoading ? 'Signing in...' : 'Continue'}
          </button>
        </form>
      </AuthCard>
    );
  }

  return (
    <AuthCard
      title="Welcome back"
      subtitle={<>Sign in to <span className="font-medium text-text-primary">{clinic}</span></>}
      topRight={topRight}
      showFooter
      below={below}
    >
      <div className="-mt-4 mb-6 text-center">
        <button type="button" onClick={() => navigate('/login')} className="text-xs text-text-secondary hover:text-primary underline underline-offset-2">
          Not your clinic? Change
        </button>
      </div>

      {errors.submit && <AuthError>{errors.submit}</AuthError>}

      <form onSubmit={goToPasswordStep} autoComplete="on" noValidate>
        <div className="mb-3">
          <div className="relative">
            <input
              type="text"
              inputMode="email"
              name="username"
              autoComplete="username"
              autoFocus
              value={email}
              onChange={(e) => { setEmail(e.target.value); setShowSavedEmails(true); if (errors.email) setErrors((prev) => ({ ...prev, email: '' })); }}
              onFocus={() => setShowSavedEmails(true)}
              onBlur={() => setTimeout(() => setShowSavedEmails(false), 200)}
              onKeyDown={(e) => {
                // Tab to autocomplete first matching saved email
                if (e.key === 'Tab' && showSavedEmails) {
                  const matches = savedEmails.filter((se) => se.toLowerCase().includes(email.toLowerCase()) && se !== email);
                  if (matches.length > 0) { e.preventDefault(); handleSelectSavedEmail(matches[0]); }
                }
              }}
              placeholder="Enter your email address"
              disabled={isDisabled}
              className={authInputClass(!!errors.email)}
            />
            {showSavedEmails && savedMatches.length > 0 && (
              <div className="absolute z-10 mt-1 w-full bg-surface border border-border rounded-spa-lg shadow-spa-elevated overflow-hidden">
                {savedMatches.map((savedEmail) => (
                  <button
                    key={savedEmail}
                    type="button"
                    onMouseDown={() => handleSelectSavedEmail(savedEmail)}
                    className="w-full text-left px-3.5 py-2.5 text-sm text-text-primary hover:bg-background transition-colors flex items-center gap-2"
                  >
                    <Icon name="User" size={14} className="text-text-secondary" />
                    {savedEmail}
                  </button>
                ))}
              </div>
            )}
          </div>
          {errors.email && <p className="mt-1.5 text-xs text-error">{errors.email}</p>}
        </div>

        <button type="submit" disabled={isDisabled} className={authButtonClass}>Continue</button>
      </form>

      <AuthDivider />

      <button type="button" onClick={() => handleOAuth('google')} disabled={isDisabled} className={`${authSecondaryButtonClass} mb-2.5`}>
        {googleIcon}
        {oauthLoading === 'google' ? 'Connecting...' : 'Continue with Google'}
      </button>
      <button type="button" onClick={() => handleOAuth('azure')} disabled={isDisabled} className={authSecondaryButtonClass}>
        {microsoftIcon}
        {oauthLoading === 'azure' ? 'Connecting...' : 'Continue with Microsoft'}
      </button>
    </AuthCard>
  );
};

export default LoginForm;
