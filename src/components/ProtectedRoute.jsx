import React from 'react';
import { Navigate, useLocation, useParams } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';
import logo from 'assets/logo.png';

const LoadingScreen = () => (
  <div className="min-h-screen bg-background flex items-center justify-center">
    <div className="flex flex-col items-center space-y-4">
      <img src={logo} alt="ClinicMD" className="h-10 w-auto animate-pulse" />
      <p className="font-body font-body-normal text-sm text-text-secondary">
        Loading...
      </p>
    </div>
  </div>
);

const ProtectedRoute = ({ children, allowedRoles }) => {
  const { user, profile, loading } = useAuth();
  const { orgSlug: urlOrgSlug } = useParams();
  const location = useLocation();
  // Remember where the user was headed so login can send them back (LoginForm only honours same-org in-app paths).
  const loginState = { from: { pathname: location.pathname, search: location.search, hash: location.hash } };

  if (loading) {
    return <LoadingScreen />;
  }

  // Not authenticated - redirect to login
  if (!user) {
    // If we have an org slug in the URL, redirect to that org's login
    if (urlOrgSlug) {
      return <Navigate to={`/${urlOrgSlug}/login`} replace state={loginState} />;
    }
    return <Navigate to="/login" replace state={loginState} />;
  }

  // No profile loaded - something went wrong
  if (!profile) {
    if (urlOrgSlug) {
      return <Navigate to={`/${urlOrgSlug}/login`} replace state={loginState} />;
    }
    return <Navigate to="/login" replace state={loginState} />;
  }

  // Check role authorization
  if (allowedRoles && !allowedRoles.includes(profile.role)) {
    // User doesn't have the required role
    // Redirect to their appropriate dashboard based on their actual role
    const userOrgSlug = profile?.organizations?.slug;
    if (userOrgSlug) {
      return <Navigate to={`/${userOrgSlug}/dashboard`} replace />;
    }
    return <Navigate to="/login" replace />;
  }

  // If URL has an org slug, validate it matches the user's org
  if (urlOrgSlug) {
    const userOrgSlug = profile?.organizations?.slug;

    if (userOrgSlug && urlOrgSlug !== userOrgSlug) {
      // URL org doesn't match user's org - redirect to user's actual org
      return <Navigate to={`/${userOrgSlug}/dashboard`} replace />;
    }
  }

  return children;
};

export default ProtectedRoute;
