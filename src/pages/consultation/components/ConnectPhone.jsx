import React from 'react';
import { Link } from 'react-router-dom';
import Icon from '../../../components/AppIcon';

// Shown while this phone (or Home Screen app) is not signed in. A phone can only be signed in by scanning the QR code on the
// computer's "Continue on phone" panel, or by the normal email login. (6-digit codes only confirm an already signed-in phone.)
const ConnectPhone = ({ orgSlug }) => {
  let org = orgSlug;
  if (!org) {
    try { org = localStorage.getItem('clinicmd-phone-org'); } catch { /* ignore */ }
  }
  return (
    <div className="min-h-screen bg-background flex items-center justify-center p-6">
      <div className="w-full max-w-sm text-center space-y-5">
        <div className="mx-auto w-16 h-16 rounded-full bg-primary/10 flex items-center justify-center">
          <Icon name="Smartphone" size={28} className="text-primary" />
        </div>
        <div>
          <h1 className="font-heading font-heading-semibold text-xl text-text-primary">Connect this phone</h1>
          <p className="text-sm text-text-secondary mt-1">
            Scan the QR code on the computer: open a consultation and tap <strong>Continue on phone</strong>. Or log in with email.
          </p>
        </div>
        <Link to={org ? `/${org}/login` : '/login'} className="inline-flex items-center justify-center h-10 px-5 rounded-md bg-primary text-white text-sm font-medium">
          Log in with email
        </Link>
      </div>
    </div>
  );
};

export default ConnectPhone;
