import React from 'react';
import { useTenant } from 'contexts/TenantContext';
import AuthCard from 'components/ui/AuthCard';
import CustomerSignupForm from './components/CustomerSignupForm';

const CustomerSignup = () => {
  const { orgName } = useTenant();

  return (
    <AuthCard
      title="Create your account"
      subtitle="Save your details and see your booking history"
      topRight={<span className="text-sm font-medium text-text-secondary">{orgName || 'ClinicMD'}</span>}
    >
      <CustomerSignupForm />
    </AuthCard>
  );
};

export default CustomerSignup;
