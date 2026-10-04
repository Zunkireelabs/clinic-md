import React from 'react';
import { useParams } from 'react-router-dom';
import ProtectedRoute from '../../components/ProtectedRoute';
import { useAuth } from '../../contexts/AuthContext';
import ConnectPhone from './components/ConnectPhone';
import DoctorPhone from './DoctorPhone';

// /:orgSlug/phone. A phone that is not signed in (a Home Screen app starts that
// way) gets the 6-digit code screen instead of the email login. Once the code
// is accepted the session changes and this renders the Doctor phone page.
const PhoneGate = () => {
  const { orgSlug } = useParams();
  const { user, profile, loading } = useAuth();
  if (loading) return null;

  if (!user || !profile) return <ConnectPhone orgSlug={orgSlug} />;
  return (
    <ProtectedRoute allowedRoles={['staff', 'manager', 'admin']}>
      <DoctorPhone />
    </ProtectedRoute>
  );
};

export default PhoneGate;
