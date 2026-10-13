import { CUSTOMER_REFERRALS_ENABLED } from '../../../../lib/featureFlags';

// One source of truth for the Reports area: the internal menu, the catalogue, the sidebar's active check and the
// dashboard's renderer all read this. Roles and flags mirror the sidebar's former "Reports" group exactly.
const STAFF_UP = ['manager', 'admin', 'admin_viewer'];

export const REPORT_CATEGORIES = [
  { id: 'sales', label: 'Sales & revenue' },
  { id: 'team', label: 'Team' },
  { id: 'patients', label: 'Patients' },
];

export const REPORTS = [
  { id: 'daily', view: 'reports', title: 'Daily Report', description: "Day's bookings, revenue, payments and closing.", icon: 'FileText', category: 'sales', roles: STAFF_UP, keywords: 'revenue closing day end sales' },
  { id: 'treatment-revenue', view: 'treatment-revenue', title: 'Treatment Revenue', description: 'Revenue by treatment and category.', icon: 'PieChart', category: 'sales', roles: STAFF_UP, keywords: 'income sales procedures' },
  { id: 'discounts', view: 'discounts', title: 'Discounts', description: 'Discounts given, with who requested and who approved them.', icon: 'Percent', category: 'sales', roles: STAFF_UP, keywords: 'offers waiver' },
  { id: 'outstanding', view: 'outstanding', title: 'Outstanding', description: 'Unpaid and partially paid balances by patient.', icon: 'AlertCircle', category: 'sales', roles: STAFF_UP, keywords: 'dues unpaid balance owed receivable' },

  { id: 'performance', view: 'performance', title: 'Performance', description: 'Ranked performance score per dentist, with a full breakdown on click.', icon: 'TrendingUp', category: 'team', roles: STAFF_UP, keywords: 'ranking dentist productivity' },
  { id: 'attendance-report', view: 'attendance-report', title: 'Attendance', description: 'Presence, leave and attendance rate per staff member.', icon: 'CalendarCheck', category: 'team', roles: STAFF_UP, keywords: 'presence leave' },
  { id: 'attendance-calendar', view: 'attendance-calendar', title: 'Attendance Calendar', description: 'Calendar view of who was in, away or on leave.', icon: 'CalendarDays', category: 'team', roles: STAFF_UP, keywords: 'who was in leave' },
  { id: 'transfer-report', view: 'transfer-report', title: 'Transfers', description: 'Staff moved between branches.', icon: 'ArrowRightLeft', category: 'team', roles: STAFF_UP, needsTransfers: true, keywords: 'moved branch transfer' },

  { id: 'referrals', view: 'referrals', title: 'Referrals', description: 'Bookings and commission by referral source and referrer.', icon: 'UserPlus', category: 'patients', roles: STAFF_UP, keywords: 'commission source' },
  ...(CUSTOMER_REFERRALS_ENABLED ? [
    { id: 'customer-referrals', view: 'customer-referrals', title: 'Customer Referrals', description: 'Customers who referred other customers, and the rewards credited.', icon: 'Users', category: 'patients', roles: STAFF_UP },
    { id: 'referral-wallet', view: 'referral-wallet', title: 'Referral Wallet', description: 'Who referred whom, how much they got, and what is left.', icon: 'Wallet', category: 'patients', roles: STAFF_UP },
  ] : []),
];

export const REPORT_VIEWS = new Set(REPORTS.map((r) => r.view));
export const isReportView = (view) => view === 'all-reports' || REPORT_VIEWS.has(view);
export const getReportByView = (view) => REPORTS.find((r) => r.view === view) || null;

// Can this role open the report at all (role + feature flag)? Deep links use this.
export const canOpenReport = (report, role) => !!report && report.roles.includes(role);

// What the menu and catalogue list: role + flag + (for transfers) the DB feature gate.
export const getVisibleReports = (role, transfersAvailable) =>
  REPORTS.filter((r) => r.roles.includes(role) && !(r.needsTransfers && transfersAvailable !== true));
