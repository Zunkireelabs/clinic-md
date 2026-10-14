import React, { useState, useEffect } from 'react';
import { useTenant } from '../../contexts/TenantContext';
import LoginForm from './components/LoginForm';

const StaffLoginAuthentication = () => {
  const { orgName } = useTenant();
  const [dbStatus, setDbStatus] = useState('checking');

  // Check Supabase connection status
  useEffect(() => {
    const checkConnection = async () => {
      try {
        // Simple fetch to check if Supabase is reachable
        const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/rest/v1/`, {
          method: 'HEAD',
          headers: {
            'apikey': import.meta.env.VITE_SUPABASE_ANON_KEY,
          },
        });
        setDbStatus(response.ok ? 'online' : 'offline');
      } catch {
        setDbStatus('offline');
      }
    };

    checkConnection();
    const interval = setInterval(checkConnection, 30000);
    return () => clearInterval(interval);
  }, []);

  const connection = (
    <div className="flex items-center gap-2 text-sm text-text-secondary">
      <div
        className={`w-2 h-2 rounded-full ${
          dbStatus === 'online' ? 'bg-success' : dbStatus === 'offline' ? 'bg-error' : 'bg-text-secondary'
        }`}
      />
      <span className="hidden sm:inline">
        {dbStatus === 'online' && 'Connected'}
        {dbStatus === 'offline' && 'Offline'}
        {dbStatus === 'checking' && 'Checking...'}
      </span>
    </div>
  );

  return <LoginForm orgName={orgName} topRight={connection} />;
};

export default StaffLoginAuthentication;
