import { MEMBERSHIP_ENABLED, VOUCHER_ENABLED } from '../../../../lib/featureFlags';

// Small areas (2–4 pages) get tabs at the top of the page; each tab is an existing `?view=` URL, so every view URL keeps working.
// Roles, flags and `overallHidden` mirror the sidebar entries these tabs replace.
const ALL = ['staff', 'manager', 'admin', 'admin_viewer'];
const STAFF_UP = ['manager', 'admin', 'admin_viewer'];

export const AREAS = [
  {
    id: 'bookings',
    title: 'Bookings',
    description: ({ branchName, isOverall }) => `Every booking at ${isOverall ? 'all branches' : (branchName || 'this branch')}.`,
    tabs: [
      { view: 'bookings', label: 'All bookings', roles: ALL },
      { view: 'new-booking', label: 'New booking', roles: ALL, overallHidden: true },
      { view: 'check-booking', label: 'Check booking', roles: ALL, overallHidden: true },
      { view: 'collect-payment', label: 'Collect payment', roles: ['staff'] },
      ...(MEMBERSHIP_ENABLED ? [{ view: 'new-membership', label: 'New membership', roles: ['staff'] }] : []),
      ...(VOUCHER_ENABLED ? [{ view: 'new-voucher', label: 'New voucher', roles: ['staff'] }] : []),
    ],
  },
  {
    id: 'team',
    title: 'Team',
    description: ({ staffLabelPlural }) => `Your ${String(staffLabelPlural || 'staff').toLowerCase()}, attendance and payroll.`,
    tabs: [
      { view: 'dentists', label: ({ staffLabelPlural }) => staffLabelPlural || 'Staff', roles: STAFF_UP },
      { view: 'attendance', label: 'Attendance', roles: STAFF_UP, overallHidden: true },
      { view: 'payroll', label: 'Payroll', roles: ['admin', 'admin_viewer'] },
    ],
  },
  {
    id: 'packages',
    title: 'Packages',
    description: () => 'Packages you sell and the ones patients hold.',
    tabs: [
      { view: 'package-overview', label: 'All packages', roles: ['manager', 'admin'] },
      { view: 'packages', label: 'Issued', roles: ['manager', 'admin'] },
    ],
  },
];

export const getAreaForView = (view) => AREAS.find((a) => a.tabs.some((t) => t.view === view)) || null;

// Tabs this role / branch can see, in order (labels resolved).
export const getVisibleTabs = (area, { role, isOverall, ...labels }) =>
  area.tabs
    .filter((t) => t.roles.includes(role) && !(isOverall && t.overallHidden))
    .map((t) => ({ ...t, label: typeof t.label === 'function' ? t.label(labels) : t.label }));
