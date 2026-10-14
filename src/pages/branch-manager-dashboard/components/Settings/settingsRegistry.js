import { CUSTOMER_REFERRALS_ENABLED } from '../../../../lib/featureFlags';

// Registry for the Settings area (same shape as the report registry, plus `overallHidden`). Roles, gates and icons mirror the
// sidebar's former "Setup" group. Reward Catalog moved here from Reports.
const STAFF_UP = ['manager', 'admin', 'admin_viewer'];

export const SETTINGS_CATEGORIES = [
  { id: 'clinic', label: 'Clinic' },
  { id: 'payments', label: 'Payments' },
  { id: 'account', label: 'Account' },
];

export const SETTINGS = [
  // `location: true` -> the title uses the industry's location label (Chairs / Rooms / ...); `needsChairs` -> only when enabled.
  { id: 'chairs', view: 'chairs', title: 'Chairs', location: true, needsChairs: true, description: 'Rooms and chairs patients are booked into.', icon: 'DoorOpen', category: 'clinic', roles: STAFF_UP, overallHidden: true, keywords: 'rooms' },
  { id: 'treatments', view: 'treatments', title: 'Treatments', description: 'Services, prices and durations.', icon: 'Sparkles', category: 'clinic', roles: STAFF_UP, overallHidden: true, keywords: 'services prices' },
  { id: 'categories', view: 'categories', title: 'Categories', description: 'Groups that organise your treatments.', icon: 'Tags', category: 'clinic', roles: STAFF_UP, overallHidden: true, keywords: 'groups' },

  { id: 'payment-methods', view: 'payment-methods', title: 'Payment Methods', description: 'How patients can pay at the desk.', icon: 'CreditCard', category: 'payments', roles: ['admin'], overallHidden: true, keywords: 'cash card pay methods' },
  ...(CUSTOMER_REFERRALS_ENABLED ? [
    { id: 'reward-catalog', view: 'reward-catalog', title: 'Reward Catalog', description: 'Gift vouchers staff can pick when logging a referral.', icon: 'Gift', category: 'payments', roles: ['manager', 'admin'] },
  ] : []),

  { id: 'audit', view: 'audit', title: 'Audit Log', description: 'Every change made in this clinic, and who made it.', icon: 'History', category: 'account', roles: STAFF_UP, keywords: 'history log changes who' },
];

export const SETTINGS_VIEWS = new Set(SETTINGS.map((s) => s.view));
// 'settings' is the landing alias; 'infrastructure' is the retired combined page and now maps to it as well.
export const isSettingsView = (view) => view === 'settings' || view === 'infrastructure' || SETTINGS_VIEWS.has(view);
export const getSettingByView = (view) => SETTINGS.find((s) => s.view === view) || null;

export const canOpenSetting = (item, role, isOverall) => !!item && item.roles.includes(role) && !(isOverall && item.overallHidden);

// Visible pages for the role / branch / industry, in menu order.
export const getVisibleSettings = ({ role, isOverall, enableChairs }) =>
  SETTINGS.filter((s) => s.roles.includes(role) && !(isOverall && s.overallHidden) && !(s.needsChairs && !enableChairs));
