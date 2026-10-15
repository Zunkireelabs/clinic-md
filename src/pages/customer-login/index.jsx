import React from 'react';
import { useTenant } from 'contexts/TenantContext';
import AuthCard from 'components/ui/AuthCard';
import CustomerLoginForm from './components/CustomerLoginForm';

const CustomerLoginAuthentication = () => {
  const { orgName } = useTenant();

  return (
    <AuthCard
      title="Welcome back"
      subtitle="Sign in to book and manage your visits"
      topRight={<span className="text-sm font-medium text-text-secondary">{orgName || 'ClinicMD'}</span>}
    >
      <CustomerLoginForm />
    </AuthCard>
  );
};

export default CustomerLoginAuthentication;
