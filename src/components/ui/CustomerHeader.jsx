import React, { useRef } from 'react';
import { Link, useLocation, useParams } from 'react-router-dom';
import Icon from '../AppIcon';
import { useTenant } from 'contexts/TenantContext';
import { useCustomerAuth } from 'contexts/CustomerAuthContext';
import useMeasuredHeightVar from 'hooks/useMeasuredHeightVar';
import logo from 'assets/logo.png';

const CustomerHeader = () => {
  const location = useLocation();
  const { orgSlug } = useParams();
  const headerRef = useRef(null);
  // Height varies by breakpoint (h-auto min-h-16 py-3 on mobile vs a fixed
  // h-16 from sm up) and can grow further if org branding text wraps —
  // publish the real measured height so fixed/sticky elements stacked under
  // this header (progress bars, sticky filters, content padding-top) never
  // hardcode a stale 64px and end up overlapping it.
  useMeasuredHeightVar(headerRef, '--customer-header-h');

  // Try to get tenant context, but don't fail if not available
  let tenantData = { orgName: null };
  try {
    tenantData = useTenant();
  } catch {
    // TenantContext not available, use defaults
  }

  const { orgName } = tenantData;

  // Try to get customer auth context, but don't fail if not available
  let customerAuth = { customer: null, customerProfile: null };
  try {
    customerAuth = useCustomerAuth();
  } catch {
    // CustomerAuthContext not available, use defaults
  }

  const { customer, customerProfile } = customerAuth;
  const loginPath = orgSlug ? `/${orgSlug}/customer-login` : '/login';
  const accountPath = orgSlug ? `/${orgSlug}/account` : '/';

  // Build tenant-aware paths
  const bookingPath = orgSlug ? `/${orgSlug}` : '/';

  const isBookingFlow = location.pathname === bookingPath || location.pathname === `/${orgSlug}`;

  const getTagline = () => 'Dental Care & Wellness';

  return (
    <header ref={headerRef} className="fixed top-0 left-0 right-0 z-customer-header bg-surface border-b border-border">
      <div className="relative max-w-7xl mx-auto pl-4 pr-2 sm:px-6 lg:px-8">
        <div className="flex items-center justify-between gap-3 h-auto min-h-16 py-3 sm:h-16 sm:py-0">
          {/* Logo */}
          <Link to={bookingPath} className="flex items-center space-x-2 group min-w-0 flex-1">
            <img src={logo} alt="ClinicMD" className="h-8 sm:h-10 w-auto flex-shrink-0" />
            {orgName && (
              <div className="flex flex-col min-w-0">
                <span className="font-heading font-heading-semibold text-base sm:text-lg text-text-primary truncate">
                  {orgName}
                </span>
                <span className="block font-caption font-caption-normal text-[10px] sm:text-xs text-text-secondary -mt-0.5 sm:-mt-1 truncate">
                  {getTagline()}
                </span>
              </div>
            )}
          </Link>

          {/* Navigation Links */}
          <nav className="hidden md:flex items-center flex-shrink-0">
            <Link
              to={bookingPath}
              className={`font-body font-body-normal text-sm spa-transition-fast hover:text-primary ${
                isBookingFlow ? 'text-primary' : 'text-text-secondary'
              }`}
            >
              Book Treatment
            </Link>
          </nav>

          {/* Contact & Support */}
          <div className="flex items-center space-x-2 sm:space-x-4 flex-shrink-0">
            {/* Phone Contact */}
            <a
              href="tel:+977-1-4441234"
              aria-label="Call +977-1-4441234"
              className="flex items-center justify-center sm:justify-start space-x-0 sm:space-x-2 px-0 sm:px-3 py-0 sm:py-2 rounded-spa bg-background hover:bg-border/50 spa-transition-fast group flex-shrink-0 spa-touch-target"
            >
              <Icon
                name="Phone"
                size={16}
                className="text-primary group-hover:text-primary/80"
              />
              <span className="hidden sm:inline font-body font-body-medium text-sm text-text-primary">
                +977-1-4441234
              </span>
            </a>

            {/* Login / Account */}
            <Link
              to={customer && customerProfile ? accountPath : loginPath}
              className="flex items-center space-x-2 px-3 sm:px-4 py-2 rounded-spa border border-border hover:bg-background spa-transition-fast spa-touch-target flex-shrink-0"
            >
              <Icon name="User" size={16} className="text-text-primary flex-shrink-0" />
              <span className="font-body font-body-medium text-sm text-text-primary whitespace-nowrap">
                {customer && customerProfile ? customerProfile.full_name.split(' ')[0] : 'Login'}
              </span>
            </Link>

            {/* Support Button */}
            <button className="flex items-center justify-center space-x-2 sm:w-auto sm:h-auto px-0 py-0 sm:px-4 sm:py-2 bg-primary hover:bg-primary/90 text-primary-foreground rounded-spa spa-transition-fast spa-touch-target flex-shrink-0">
              <Icon name="MessageCircle" size={14} className="sm:hidden" />
              <Icon name="MessageCircle" size={16} className="hidden sm:block" />
              <span className="hidden sm:inline font-body font-body-medium text-sm">Support</span>
            </button>
          </div>
        </div>
      </div>
    </header>
  );
};

export default CustomerHeader;