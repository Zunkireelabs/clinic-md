import React from 'react';
import { Navigate } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import ConnectPhone from './components/ConnectPhone';

// /phone: the short address. Signed in -> straight to the clinic's phone page.
// Signed out -> the 6-digit code screen.
const PhoneEntry = () => {
  const { profile, loading } = useAuth();
  if (loading) return null;

  if (profile) {
    let slug = profile.organizations?.slug;
    if (!slug) {
      try { slug = localStorage.getItem('clinicmd-phone-org'); } catch { /* ignore */ }
    }
    return <Navigate to={slug ? `/${slug}/phone` : '/login'} replace />;
  }
  return <ConnectPhone />;
};

export default PhoneEntry;
