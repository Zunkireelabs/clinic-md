import React, { useState, useEffect, useRef } from 'react';
import { Link, useLocation, useParams } from 'react-router-dom';
import Icon from '../AppIcon';
import { useAuth } from 'contexts/AuthContext';
import { useBranch } from 'contexts/BranchContext';
import { useIndustry } from 'hooks/useIndustry';
import { useTransferFeature } from 'hooks/useTransferFeature';
import { fetchPendingApprovalCount } from 'services/api';
import { isReportView } from 'pages/branch-manager-dashboard/components/Reports/reportRegistry';
import { isSettingsView } from 'pages/branch-manager-dashboard/components/Settings/settingsRegistry';
import { MEMBERSHIP_ENABLED, VOUCHER_ENABLED, OUTREACH_ENABLED } from 'lib/featureFlags';

const StaffSidebar = ({ userRole: propRole, userName: propName, branchName: propBranch, onCollapseChange }) => {
  const transfersAvailable = useTransferFeature(); // hide transfer entries unless the DB has the tables
  const location = useLocation();
  const { orgSlug: urlOrgSlug } = useParams();
  const { profile, signOut } = useAuth();
  const { branchName: contextBranchName, branchId, isOverall } = useBranch();
  const [pendingApprovals, setPendingApprovals] = useState(0);
  const { staffLabelPlural } = useIndustry();
  const [isCollapsed, setIsCollapsed] = useState(false);
  const [mobileMoreOpen, setMobileMoreOpen] = useState(false);
  const [isScrolling, setIsScrolling] = useState(false);
  const scrollTimeoutRef = useRef(null);

  // Shrink the floating mobile nav + FAB while the user is actively scrolling
  // any scrollable container on the page. `capture: true` catches scroll events
  // from nested scrollers (e.g. the calendar grid) that don't bubble to window.
  useEffect(() => {
    const handleScroll = () => {
      setIsScrolling(true);
      clearTimeout(scrollTimeoutRef.current);
      scrollTimeoutRef.current = setTimeout(() => setIsScrolling(false), 300);
    };
    document.addEventListener('scroll', handleScroll, { capture: true, passive: true });
    return () => {
      document.removeEventListener('scroll', handleScroll, { capture: true });
      clearTimeout(scrollTimeoutRef.current);
    };
  }, []);
  const [expandedItems, setExpandedItems] = useState(['operations']); // Default expanded

  const userRole = profile?.role || propRole || 'staff';
  const userName = profile?.full_name || propName || 'Staff Member';
  const branchName = contextBranchName || profile?.branches?.name || propBranch || 'Main Branch';
  const isManagerOrAdmin = ['manager', 'admin', 'admin_viewer'].includes(userRole);

  // Pending discount-approval count for the badge on "Dashboard".
  // Only approvers (manager/admin) can receive requests; re-check on branch
  // change, on navigation, and on a slow poll so the badge stays current.
  useEffect(() => {
    if (!isManagerOrAdmin || !branchId) {
      setPendingApprovals(0);
      return;
    }
    let active = true;
    const load = async () => {
      const { count } = await fetchPendingApprovalCount(branchId);
      if (active) setPendingApprovals(count);
    };
    load();
    const interval = setInterval(load, 60000);
    window.addEventListener('pending-approvals-changed', load);
    return () => {
      active = false;
      clearInterval(interval);
      window.removeEventListener('pending-approvals-changed', load);
    };
  }, [isManagerOrAdmin, branchId, location.pathname, location.search]);

  // Get org slug from URL params or profile
  const orgSlug = urlOrgSlug || profile?.organizations?.slug;

  // Base path for navigation - uses org-scoped URL if available
  const basePath = orgSlug ? `/${orgSlug}/dashboard` : (isManagerOrAdmin ? '/branch-manager-dashboard' : '/branch-staff-dashboard');

  const handleLogout = async () => {
    await signOut();
  };

  const toggleExpand = (id) => {
    setExpandedItems((prev) =>
      prev.includes(id) ? prev.filter((item) => item !== id) : [...prev, id]
    );
  };

  // Navigation items with collapsible groups (Agentic Commerce style)
  const navigationItems = [
    {
      id: 'dashboard',
      label: 'Dashboard',
      icon: 'LayoutDashboard',
      path: `${basePath}?view=dashboard`,
      roles: ['staff', 'manager', 'admin', 'admin_viewer']
    },
    {
      id: 'calendar',
      label: 'Calendar',
      icon: 'CalendarDays',
      path: `${basePath}?view=calendar`,
      roles: ['staff', 'manager', 'admin', 'admin_viewer']
    },
    {
      id: 'operations',
      label: 'Operations',
      icon: 'ClipboardList',
      roles: ['staff', 'manager', 'admin', 'admin_viewer'],
      children: [
        {
          id: 'bookings',
          label: 'Bookings',
          icon: 'BookOpen',
          path: `${basePath}?view=bookings`,
          roles: ['staff', 'manager', 'admin', 'admin_viewer']
        },
        {
          id: 'collect-payment',
          label: 'Collect Payment',
          icon: 'CreditCard',
          path: `${basePath}?view=collect-payment`,
          roles: ['staff']
        },
        {
          id: 'new-booking',
          label: 'New Booking',
          icon: 'CalendarPlus',
          path: `${basePath}?view=new-booking`,
          roles: ['staff', 'manager', 'admin', 'admin_viewer'],
          overallHidden: true
        },
        {
          id: 'check-booking',
          label: 'Check Booking',
          icon: 'Search',
          path: `${basePath}?view=check-booking`,
          roles: ['staff', 'manager', 'admin', 'admin_viewer'],
          overallHidden: true
        },
        ...(MEMBERSHIP_ENABLED ? [{
          id: 'new-membership',
          label: 'New Membership',
          icon: 'CreditCard',
          path: `${basePath}?view=new-membership`,
          roles: ['staff'],
        }] : []),
        ...(VOUCHER_ENABLED ? [{
          id: 'new-voucher',
          label: 'New Voucher',
          icon: 'Ticket',
          path: `${basePath}?view=new-voucher`,
          roles: ['staff'],
        }] : []),
      ]
    },
    {
      id: 'customers',
      label: 'Customers',
      icon: 'Users',
      path: `${basePath}?view=customers`,
      roles: ['manager', 'admin', 'admin_viewer']
    },
    {
      id: 'insights',
      label: 'Reports',
      icon: 'BarChart3',
      path: `${basePath}?view=all-reports`,
      roles: ['manager', 'admin', 'admin_viewer']
    },
    {
      id: 'staff-mgmt',
      label: 'Staff',
      icon: 'UserCog',
      roles: ['manager', 'admin', 'admin_viewer'],
      children: [
        {
          id: 'dentists',
          label: staffLabelPlural,
          icon: 'Users',
          path: `${basePath}?view=dentists`,
          roles: ['manager', 'admin', 'admin_viewer']
        },
        {
          id: 'attendance',
          label: 'Attendance',
          icon: 'Clock',
          path: `${basePath}?view=attendance`,
          roles: ['manager', 'admin', 'admin_viewer'],
          overallHidden: true
        },
      ]
    },
    {
      id: 'payroll',
      label: 'Payroll',
      icon: 'Wallet',
      path: `${basePath}?view=payroll`,
      roles: ['admin', 'admin_viewer'],
    },
    ...(MEMBERSHIP_ENABLED ? [{
      id: 'memberships',
      label: 'Memberships',
      icon: 'CreditCard',
      roles: ['manager', 'admin'],
      children: [
        {
          id: 'all-memberships',
          label: 'All Memberships',
          icon: 'CreditCard',
          path: `${basePath}?view=memberships`,
          roles: ['manager', 'admin'],
        },
        {
          id: 'membership-collection',
          label: 'Collection',
          icon: 'PiggyBank',
          path: `${basePath}?view=membership-collection`,
          roles: ['manager', 'admin'],
        },
        {
          id: 'wallet-usage',
          label: 'Wallet Usage',
          icon: 'Wallet',
          path: `${basePath}?view=wallet-usage`,
          roles: ['manager', 'admin'],
        },
      ],
    }] : []),
    ...(VOUCHER_ENABLED ? [{
      id: 'vouchers',
      label: 'Vouchers',
      icon: 'Ticket',
      roles: ['manager', 'admin'],
      children: [
        {
          id: 'voucher-overview',
          label: 'All Voucher',
          icon: 'LayoutDashboard',
          path: `${basePath}?view=voucher-overview`,
          roles: ['manager', 'admin'],
        },
        {
          id: 'voucher-list',
          label: 'Voucher Issued',
          icon: 'Ticket',
          path: `${basePath}?view=vouchers`,
          roles: ['manager', 'admin'],
        },
      ],
    }] : []),
    {
      id: 'packages',
      label: 'Packages',
      icon: 'Layers',
      roles: ['manager', 'admin'],
      children: [
        {
          id: 'package-overview',
          label: 'All Packages',
          icon: 'LayoutDashboard',
          path: `${basePath}?view=package-overview`,
          roles: ['manager', 'admin'],
        },
        {
          id: 'package-list',
          label: 'Packages Issued',
          icon: 'Layers',
          path: `${basePath}?view=packages`,
          roles: ['manager', 'admin'],
        },
      ],
    },
    ...(OUTREACH_ENABLED ? [{
      id: 'outreach',
      label: 'Outreach',
      icon: 'Megaphone',
      path: `${basePath}?view=outreach`,
      roles: ['admin'],
    }] : []),
    {
      id: 'infrastructure',
      label: 'Settings',
      icon: 'Settings',
      path: `${basePath}?view=settings`,
      roles: ['manager', 'admin', 'admin_viewer']
    },
  ];

  // Filter items by role (and, in the Overall aggregate view, hide write/creation items
  // that have no single target branch).
  const isVisible = (item) =>
    item.roles.includes(userRole) && !(isOverall && item.overallHidden)
    && !(item.id === 'transfer-report' && transfersAvailable !== true);

  const filterByRole = (items) => {
    return items
      .filter(isVisible)
      .map(item => {
        if (item.children) {
          return {
            ...item,
            children: item.children.filter(isVisible)
          };
        }
        return item;
      })
      .filter(item => !item.children || item.children.length > 0);
  };

  const filteredNavItems = filterByRole(navigationItems);

  // Flatten for mobile nav. Tag each child with its parent group label so the
  // "More" sheet can render section headers (e.g. Reports, Staff, Setup).
  const flattenNav = (items) => {
    const result = [];
    items.forEach(item => {
      if (item.children) {
        // A group can also be a direct link itself (e.g. Memberships) — keep
        // it reachable from mobile nav alongside its children.
        if (item.path) {
          result.push({ id: item.id, label: item.label, icon: item.icon, path: item.path, groupLabel: null });
        }
        item.children.forEach(child => result.push({ ...child, groupLabel: item.label }));
      } else if (item.path) {
        result.push({ ...item, groupLabel: null });
      }
    });
    return result;
  };

  const flatNavItems = flattenNav(filteredNavItems);
  // Pull New Booking out into its own floating FAB; everything else feeds the pill nav + "More" sheet.
  const newBookingItem = flatNavItems.find(item => item.id === 'new-booking');
  const mainNavItems = flatNavItems.filter(item => item.id !== 'new-booking');
  const mobilePrimaryItems = mainNavItems.slice(0, 4);
  const mobileOverflowItems = mainNavItems.slice(4);

  const isActive = (path) => {
    // The single Settings item is active on every settings view.
    if (path === `${basePath}?view=settings`) {
      return location.pathname === basePath && isSettingsView(new URLSearchParams(location.search).get('view'));
    }
    // The single Reports item is active on every report view (and the catalogue).
    if (path === `${basePath}?view=all-reports`) {
      return location.pathname === basePath && isReportView(new URLSearchParams(location.search).get('view'));
    }
    // Bare dashboard URL = landing view: the dashboard for managers/admins, the calendar for staff.
    if (location.pathname === basePath && !new URLSearchParams(location.search).get('view')) {
      return path === `${basePath}?view=${userRole === 'staff' ? 'calendar' : 'dashboard'}`;
    }
    if (path.includes('?')) {
      return `${location.pathname}${location.search}` === path;
    }
    return location.pathname === path && !location.search;
  };

  const isParentActive = (item) => {
    if (item.path && isActive(item.path)) return true;
    if (item.children) {
      return item.children.some(child => isActive(child.path));
    }
    return false;
  };

  const getActiveChildIndex = (children) => {
    return children.findIndex(child => isActive(child.path));
  };

  return (
    <>
      {/* Desktop Sidebar */}
      <aside className={`fixed left-0 top-0 h-full z-staff-sidebar bg-surface-sidebar flex flex-col transition-all duration-200 ${
        isCollapsed ? 'w-16' : 'w-60'
      } hidden lg:flex`}>
        {/* Header */}
        <div className="px-5 py-3 h-12 flex items-center justify-between">
          {!isCollapsed && (
            <Link to={basePath} aria-label="ClinicMD Staff Portal" className="flex items-start text-gray-900">
              {/* Wordmark matches the marketing site: Clinic + superscript MD */}
              <span className="text-[20px] font-normal tracking-[-0.04em] leading-none">Clinic</span>
              <span className="text-[9px] font-medium leading-none ml-px">MD</span>
            </Link>
          )}
          <button
            onClick={() => {
              const next = !isCollapsed;
              setIsCollapsed(next);
              onCollapseChange?.(next);
            }}
            className="p-2 rounded-md hover:bg-gray-100 transition-colors"
          >
            <Icon
              name={isCollapsed ? "ChevronRight" : "ChevronLeft"}
              size={16}
              className="text-gray-500"
            />
          </button>
        </div>

        {/* Navigation — collapsible groups (Agentic Commerce style) */}
        <nav className="sidebar-scroll flex-1 overflow-y-auto p-3 space-y-1">
          {filteredNavItems.map((item) => {
            const hasChildren = item.children && item.children.length > 0;
            const isExpanded = expandedItems.includes(item.id);
            const parentActive = isParentActive(item);

            // Collapsible group
            if (hasChildren) {
              return (
                <div key={item.id}>
                  {/* Parent item — a plain toggle button, unless it also has its own
                      path (e.g. Memberships), in which case the label navigates and
                      a separate chevron control expands/collapses the children. */}
                  {item.path ? (
                    <div
                      className={`w-full flex items-center gap-1 rounded-md text-[13px] font-medium transition-colors ${
                        parentActive
                          ? 'bg-white text-gray-900 shadow-[0_0_0_1px_#E9E9EC]'
                          : 'text-gray-500 hover:bg-gray-100 hover:text-gray-900'
                      } ${isCollapsed ? 'justify-center' : ''}`}
                    >
                      <Link
                        to={item.path}
                        onClick={() => {
                          // Expand immediately (synchronous local state) instead of
                          // waiting on the route change + page data fetch to settle.
                          if (!isExpanded) toggleExpand(item.id);
                        }}
                        className={`flex-1 flex items-center gap-3 px-3 py-2 rounded-md ${isCollapsed ? 'justify-center' : ''}`}
                      >
                        <Icon name={item.icon} size={18} className="flex-shrink-0" />
                        {!isCollapsed && <span>{item.label}</span>}
                      </Link>
                      {!isCollapsed && (
                        <button
                          onClick={() => toggleExpand(item.id)}
                          aria-label={isExpanded ? `Collapse ${item.label}` : `Expand ${item.label}`}
                          className="px-2.5 py-2 rounded-md hover:bg-gray-100 flex-shrink-0"
                        >
                          <Icon
                            name="ChevronDown"
                            size={16}
                            className={`transition-transform ${isExpanded ? 'rotate-180' : ''}`}
                          />
                        </button>
                      )}
                    </div>
                  ) : (
                    <button
                      onClick={() => toggleExpand(item.id)}
                      className={`w-full flex items-center justify-between gap-3 px-3 py-2 rounded-md text-[13px] font-medium transition-colors ${
                        parentActive
                          ? 'bg-white text-gray-900 shadow-[0_0_0_1px_#E9E9EC]'
                          : 'text-gray-500 hover:bg-gray-100 hover:text-gray-900'
                      } ${isCollapsed ? 'justify-center' : ''}`}
                    >
                      <div className="flex items-center gap-3">
                        <Icon name={item.icon} size={18} className="flex-shrink-0" />
                        {!isCollapsed && <span>{item.label}</span>}
                      </div>
                      {!isCollapsed && (
                        <Icon
                          name="ChevronDown"
                          size={16}
                          className={`transition-transform ${isExpanded ? 'rotate-180' : ''}`}
                        />
                      )}
                    </button>
                  )}

                  {/* Children (expanded state) */}
                  {isExpanded && !isCollapsed && (() => {
                    const activeIndex = getActiveChildIndex(item.children);

                    return (
                      <div className="relative mt-1">
                        {/* Vertical line from parent to active item */}
                        {activeIndex >= 0 && (
                          <div
                            className="absolute bg-gray-300"
                            style={{
                              left: '20px',
                              top: '-4px',
                              width: '1.5px',
                              height: `calc(${activeIndex} * 32px + 4px)`
                            }}
                          />
                        )}

                        {item.children.map((child, index) => {
                          const isChildActive = index === activeIndex;

                          return (
                            <div key={child.id} className="relative flex items-center pl-3 h-[32px]">
                              {/* Corner connector for active item */}
                              {isChildActive && (
                                <>
                                  {/* Curved corner */}
                                  <div
                                    className="absolute"
                                    style={{
                                      left: '19.25px',
                                      top: 0,
                                      height: 'calc(50% + 1px)',
                                      width: '12px',
                                      borderLeft: '1.5px solid #d1d5db',
                                      borderBottom: '1.5px solid #d1d5db',
                                      borderBottomLeftRadius: '6px'
                                    }}
                                  />
                                  {/* Arrow */}
                                  <div
                                    className="absolute text-gray-300 text-[13px]"
                                    style={{
                                      left: '30px',
                                      top: '50%',
                                      transform: 'translateY(-50%)'
                                    }}
                                  >
                                    →
                                  </div>
                                </>
                              )}

                              {/* Spacer for alignment */}
                              <div className="w-[38px] shrink-0" />

                              <Link
                                to={child.path}
                                className={`flex-1 px-2 py-1.5 rounded-md text-[13px] transition-colors ${
                                  isChildActive
                                    ? 'text-gray-900 font-medium bg-white shadow-[0_0_0_1px_#E9E9EC]'
                                    : 'text-gray-500 hover:text-gray-900'
                                }`}
                              >
                                {child.label}
                              </Link>
                            </div>
                          );
                        })}
                      </div>
                    );
                  })()}
                </div>
              );
            }

            // Regular nav item (no children)
            const showBadge = item.id === 'dashboard' && pendingApprovals > 0;
            return (
              <Link
                key={item.id}
                to={item.path}
                title={isCollapsed ? item.label : undefined}
                className={`flex items-center gap-3 px-3 py-2 rounded-md text-[13px] font-medium transition-colors ${
                  isActive(item.path)
                    ? 'bg-white text-gray-900 shadow-[0_0_0_1px_#E9E9EC]'
                    : 'text-gray-500 hover:bg-gray-100 hover:text-gray-900'
                } ${isCollapsed ? 'justify-center' : ''}`}
              >
                <div className="relative flex-shrink-0">
                  <Icon name={item.icon} size={18} />
                  {showBadge && isCollapsed && (
                    <span className="absolute -top-1 -right-1 w-2 h-2 bg-error rounded-full ring-2 ring-surface-sidebar" />
                  )}
                </div>
                {!isCollapsed && <span className="flex-1">{item.label}</span>}
                {showBadge && !isCollapsed && (
                  <span className="ml-auto inline-flex items-center justify-center min-w-[18px] h-[18px] px-1.5 text-[11px] font-semibold text-white bg-error rounded-full">
                    {pendingApprovals > 99 ? '99+' : pendingApprovals}
                  </span>
                )}
              </Link>
            );
          })}
        </nav>

        {/* Footer - Powered by Zunkireelabs */}
        <div className="p-3">
          {isCollapsed ? (
            <div className="flex justify-center py-2">
              <img src="/zunkireelabs-icon.png" alt="Zunkireelabs" className="w-5 h-5" />
            </div>
          ) : (
            <div className="px-3 py-2 flex items-center gap-1.5">
              <span className="text-[13px] text-gray-400">A Product of</span>
              <img src="/zunkireelabs-icon.png" alt="Zunkireelabs" className="w-4 h-4" />
              <span className="text-[13px] font-medium text-gray-700">zunkireelabs</span>
            </div>
          )}
        </div>
      </aside>

      {/* Mobile Floating Pill Navigation — icon + label inside the pill; subtle shrink while scrolling */}
      <nav
        className={`js-mobile-floating-ui lg:hidden fixed left-1/2 -translate-x-1/2 z-staff-sidebar bg-surface-sidebar rounded-full shadow-spa-elevated border border-border transition-all duration-200 ease-out ${
          isScrolling ? 'bottom-3 px-1.5 py-1' : 'bottom-4 px-2 py-1.5'
        }`}
      >
        <div className="flex items-center gap-0.5">
          {mobilePrimaryItems.map((item) => {
            const showBadge = item.id === 'dashboard' && pendingApprovals > 0;
            return (
              <Link
                key={item.id}
                to={item.path}
                aria-label={item.label}
                className={`relative flex flex-col items-center justify-center rounded-full transition-all duration-200 ${
                  isScrolling ? 'px-2 py-1 gap-0.5' : 'px-2.5 py-1.5 gap-0.5'
                } ${
                  isActive(item.path)
                    ? 'bg-primary/10 text-primary'
                    : 'text-gray-500 hover:text-gray-900 hover:bg-background'
                }`}
              >
                <Icon name={item.icon} size={isScrolling ? 19 : 20} />
                <span className="text-[10px] leading-none font-medium">{item.label}</span>
                {showBadge && (
                  <span className="absolute -top-0.5 -right-0.5 inline-flex items-center justify-center min-w-[14px] h-[14px] px-1 text-[10px] font-semibold text-white bg-error rounded-full">
                    {pendingApprovals > 9 ? '9+' : pendingApprovals}
                  </span>
                )}
              </Link>
            );
          })}
          {mobileOverflowItems.length > 0 && (
            <button
              onClick={() => setMobileMoreOpen(!mobileMoreOpen)}
              aria-label="More"
              className={`flex flex-col items-center justify-center rounded-full transition-all duration-200 ${
                isScrolling ? 'px-2 py-1 gap-0.5' : 'px-2.5 py-1.5 gap-0.5'
              } ${
                mobileMoreOpen ? 'bg-primary/10 text-primary' : 'text-gray-500 hover:text-gray-900 hover:bg-background'
              }`}
            >
              <Icon name="MoreHorizontal" size={isScrolling ? 19 : 20} />
              <span className="text-[10px] leading-none font-medium">More</span>
            </button>
          )}
        </div>

      </nav>

      {/* Mobile "More" full-screen panel — slides in from the right, grouped list style */}
      {mobileMoreOpen && (
        <div className="lg:hidden fixed inset-0 z-modal bg-surface flex flex-col animate-slide-in-right">
          {/* Header */}
          <div className="flex items-center gap-3 px-4 py-3 border-b border-border bg-surface flex-shrink-0">
            <button
              onClick={() => setMobileMoreOpen(false)}
              className="p-1 -ml-1 rounded-spa hover:bg-background"
              aria-label="Back"
            >
              <Icon name="ArrowLeft" size={22} className="text-text-primary" />
            </button>
            <h2 className="font-heading font-heading-semibold text-lg text-text-primary">More</h2>
          </div>

          {/* Grouped list */}
          <div className="flex-1 overflow-y-auto">
            {(() => {
              // Group overflow items by their original parent group label.
              const groups = [];
              const groupMap = new Map();
              mobileOverflowItems.forEach(item => {
                const key = item.groupLabel || 'Other';
                if (!groupMap.has(key)) {
                  const group = { label: key, items: [] };
                  groupMap.set(key, group);
                  groups.push(group);
                }
                groupMap.get(key).items.push(item);
              });
              return groups.map(group => (
                <div key={group.label} className="border-b border-border last:border-b-0">
                  {group.label !== 'Other' && (
                    <div className="px-4 pt-4 pb-2 font-caption font-caption-medium text-[11px] uppercase tracking-wider text-text-tertiary">
                      {group.label}
                    </div>
                  )}
                  {group.items.map(item => (
                    <Link
                      key={item.id}
                      to={item.path}
                      onClick={() => setMobileMoreOpen(false)}
                      className={`flex items-center gap-3 px-4 py-3 transition-colors ${
                        isActive(item.path) ? 'bg-background' : 'hover:bg-background'
                      }`}
                    >
                      <Icon name={item.icon} size={20} className="text-text-secondary flex-shrink-0" />
                      <span className="flex-1 font-body font-body-medium text-sm text-text-primary">{item.label}</span>
                      <Icon name="ChevronRight" size={16} className="text-text-tertiary flex-shrink-0" />
                    </Link>
                  ))}
                </div>
              ));
            })()}

            {/* Logout */}
            <button
              onClick={() => { setMobileMoreOpen(false); handleLogout(); }}
              className="flex items-center gap-3 px-4 py-3 w-full text-error hover:bg-red-50 transition-colors border-t border-border"
            >
              <Icon name="LogOut" size={20} className="flex-shrink-0" />
              <span className="flex-1 text-left font-body font-body-medium text-sm">Logout</span>
              <Icon name="ChevronRight" size={16} className="flex-shrink-0" />
            </button>
          </div>
        </div>
      )}

      {/* Mobile floating New Booking FAB — chatbot-style, shrinks while scrolling.
          Routes to the calendar view with ?newBooking=1, which opens the Quick Booking panel. */}
      {newBookingItem && (
        <Link
          to={`${basePath}?view=calendar&newBooking=1`}
          aria-label="New Booking"
          className={`js-mobile-floating-ui lg:hidden fixed right-4 z-staff-sidebar inline-flex items-center justify-center rounded-full bg-primary text-white shadow-lg hover:bg-primary/90 transition-all duration-200 ease-out ${
            isScrolling ? 'bottom-[72px] w-[52px] h-[52px]' : 'bottom-20 w-14 h-14'
          }`}
        >
          <Icon name="CalendarPlus" size={isScrolling ? 22 : 24} />
        </Link>
      )}
    </>
  );
};

export default StaffSidebar;
