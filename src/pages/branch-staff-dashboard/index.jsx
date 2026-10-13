import React, { useState, useEffect, useCallback, useRef } from 'react';
import { useSearchParams } from 'react-router-dom';
import Icon from '../../components/AppIcon';
import AppShell from '../../components/ui/AppShell';
import QuickFilters from './components/QuickFilters';
import BookingsList from './components/BookingsList';
import BookingLookupPanel from './components/BookingLookupPanel';
import StaffBookingForm from './components/StaffBookingForm';
import CheckBookingPanel from './components/CheckBookingPanel';
import CollectPaymentPanel from './components/CollectPaymentPanel';
import DentistAvailability from './components/DentistAvailability';
import OperationalCalendar from '../branch-manager-dashboard/components/calendar';
import EnrollMemberModal from '../branch-manager-dashboard/components/Memberships/EnrollMemberModal';
import NewVoucherModal from '../branch-manager-dashboard/components/Vouchers/NewVoucherModal';
import { useAuth } from '../../contexts/AuthContext';
import { useBranch } from '../../contexts/BranchContext';
import { fetchBookings, fetchDentists, updateBookingStatus, assignDentist, recordPayment, applyDiscount } from '../../services/api';
import { transformBookings, toDbStatus } from '../../services/bookingTransformers';
import { supabase } from '../../lib/supabase';
import { usePersistentNotifications } from '../../hooks/usePersistentNotifications';
import { MEMBERSHIP_ENABLED, VOUCHER_ENABLED } from '../../lib/featureFlags';

const BranchStaffDashboard = () => {
  const { profile, user } = useAuth();
  const { branchId, branchName } = useBranch();
  const [searchParams, setSearchParams] = useSearchParams();
  const { items: notifications, markRead: markNotifRead, markAllRead: markAllNotifsRead } = usePersistentNotifications(user?.id);
  const unreadNotifCount = notifications.filter((n) => !n.read).length;

  const handleNotificationClick = (n) => {
    markNotifRead(n.id);
    setSearchParams({ view: 'bookings' });
  };

  const viewMode = searchParams.get('view') || 'calendar'; // staff land on the calendar; the sidebar's Dashboard link is ?view=dashboard

  const [filters, setFilters] = useState({
    dateRange: 'today',
    treatmentType: 'all',
    status: 'all',
    search: ''
  });

  // Ref to track current dateRange for real-time callbacks (avoids stale closures)
  const dateRangeRef = useRef(filters.dateRange);

  const [bookings, setBookings] = useState([]);
  const [filteredBookings, setFilteredBookings] = useState([]);
  const [dentists, setDentists] = useState([]);
  const [loading, setLoading] = useState(true);
  const [actionError, setActionError] = useState(null);
  const [actionSuccess, setActionSuccess] = useState(null);
  const [bookingCounts, setBookingCounts] = useState({
    confirmed: 0,
    pending: 0,
    inProgress: 0,
    completed: 0
  });
  const [newBookingNotification, setNewBookingNotification] = useState(null);
  const [realtimeStatus, setRealtimeStatus] = useState('connecting'); // 'connecting' | 'connected' | 'disconnected'

  // Helper to format date as YYYY-MM-DD
  const formatDate = useCallback((d) => d.toISOString().split('T')[0], []);

  // Check if a booking date falls within the current date filter
  const isDateInCurrentFilter = useCallback((bookingDate, dateRange) => {
    const today = new Date();
    const booking = new Date(bookingDate);

    switch (dateRange) {
      case 'today':
        return formatDate(booking) === formatDate(today);
      case 'tomorrow': {
        const tomorrow = new Date(today);
        tomorrow.setDate(tomorrow.getDate() + 1);
        return formatDate(booking) === formatDate(tomorrow);
      }
      case 'week': {
        const weekStart = new Date(today);
        weekStart.setDate(today.getDate() - today.getDay());
        const weekEnd = new Date(weekStart);
        weekEnd.setDate(weekStart.getDate() + 6);
        return booking >= weekStart && booking <= weekEnd;
      }
      case 'month': {
        const monthStart = new Date(today.getFullYear(), today.getMonth(), 1);
        const monthEnd = new Date(today.getFullYear(), today.getMonth() + 1, 0);
        return booking >= monthStart && booking <= monthEnd;
      }
      default:
        return formatDate(booking) === formatDate(today);
    }
  }, [formatDate]);

  // Compute date filter from dateRange value
  const getDateFilter = useCallback((dateRange) => {
    const today = new Date();
    const fmt = (d) => d.toISOString().split('T')[0];

    switch (dateRange) {
      case 'today':
        return { date: fmt(today) };
      case 'tomorrow': {
        const tomorrow = new Date(today);
        tomorrow.setDate(tomorrow.getDate() + 1);
        return { date: fmt(tomorrow) };
      }
      case 'week': {
        const weekStart = new Date(today);
        weekStart.setDate(today.getDate() - today.getDay());
        const weekEnd = new Date(weekStart);
        weekEnd.setDate(weekStart.getDate() + 6);
        return { dateFrom: fmt(weekStart), dateTo: fmt(weekEnd) };
      }
      case 'month': {
        const monthStart = new Date(today.getFullYear(), today.getMonth(), 1);
        const monthEnd = new Date(today.getFullYear(), today.getMonth() + 1, 0);
        return { dateFrom: fmt(monthStart), dateTo: fmt(monthEnd) };
      }
      default:
        return { date: fmt(today) };
    }
  }, []);

  // Extracted loadData so it can be called after mutations
  const loadData = useCallback(async (dateRange) => {
    if (!branchId) return;
    setLoading(true);

    const dateFilter = getDateFilter(dateRange || filters.dateRange);
    const [bookingsResult, dentistsResult] = await Promise.all([
      fetchBookings(branchId, dateFilter),
      fetchDentists(branchId, { date: dateFilter.date }),
    ]);

    const transformed = bookingsResult.data ? transformBookings(bookingsResult.data) : [];
    if (bookingsResult.data) {
      setBookings(transformed);
      calculateBookingCounts(transformed);
    }

    if (dentistsResult.data) {
      const mapped = dentistsResult.data.map(t => {
        // Check if dentist has an in-progress booking right now
        const activeBooking = transformed.find(b =>
          b.dentistId === t.id &&
          b.status === 'in-progress'
        );
        const upcomingBooking = transformed.find(b =>
          b.dentistId === t.id &&
          ['confirmed', 'pending'].includes(b.status)
        );
        return {
          id: t.id,
          name: t.name,
          gender: t.gender,
          specialties: t.specialties || [],
          chair: null,
          status: activeBooking ? 'busy' : upcomingBooking ? 'upcoming' : 'available',
          currentBooking: activeBooking ? activeBooking.treatment : null,
        };
      });
      setDentists(mapped);
    }

    setLoading(false);
  }, [branchId, filters.dateRange, getDateFilter]);

  // Fetch data on mount and when dateRange filter changes
  useEffect(() => {
    loadData(filters.dateRange);
  }, [loadData, filters.dateRange]);

  // Keep ref in sync with current dateRange filter
  useEffect(() => {
    dateRangeRef.current = filters.dateRange;
  }, [filters.dateRange]);

  // Real-time subscription for booking changes
  useEffect(() => {
    if (!branchId) return;


    const handleRealtimeUpdate = (payload) => {
      // Small delay to ensure DB triggers (booking_number generation, end_time calculation) complete
      setTimeout(() => {
        // Use ref to get current dateRange, avoiding stale closure
        loadData(dateRangeRef.current);

        // Show notification for new bookings outside current date filter
        if (payload.eventType === 'INSERT' && payload.new) {
          const newBooking = payload.new;
          const isInView = isDateInCurrentFilter(newBooking.date, dateRangeRef.current);

          if (!isInView && newBooking.date) {
            const bookingDate = new Date(newBooking.date);
            const formattedDate = bookingDate.toLocaleDateString('en-GB', {
              weekday: 'short',
              day: 'numeric',
              month: 'short'
            });
            setNewBookingNotification({
              message: `New booking received for ${formattedDate}`,
              customerName: newBooking.customer_name,
              date: newBooking.date,
              bookingNumber: newBooking.booking_number
            });

            // Auto-dismiss after 8 seconds
            setTimeout(() => setNewBookingNotification(null), 8000);
          }
        }
      }, 150);
    };

    const channel = supabase
      .channel(`bookings-staff-${branchId}`)
      .on('postgres_changes', {
        event: '*',
        schema: 'public',
        table: 'bookings',
        filter: `branch_id=eq.${branchId}`
      }, handleRealtimeUpdate)
      .subscribe((status, err) => {
        if (status === 'SUBSCRIBED') {
          setRealtimeStatus('connected');
        } else if (status === 'CLOSED' || status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
          setRealtimeStatus('disconnected');
        }
      });

    return () => { supabase.removeChannel(channel); };
  }, [branchId, loadData, isDateInCurrentFilter]);

  // Filter bookings based on current filters
  useEffect(() => {
    let filtered = [...bookings];

    if (filters.search) {
      const searchTerm = filters.search.toLowerCase();
      filtered = filtered.filter(booking =>
        booking.id.toLowerCase().includes(searchTerm) ||
        booking.customerName.toLowerCase().includes(searchTerm) ||
        (booking.customerPhone && booking.customerPhone.includes(searchTerm)) ||
        (booking.customerEmail && booking.customerEmail.toLowerCase().includes(searchTerm))
      );
    }

    if (filters.treatmentType !== 'all') {
      const treatmentMap = {
        massage: ['Deep Tissue Massage', 'Swedish Massage', 'Sports Massage'],
        facial: ['Facial Treatment', 'Anti-Aging Facial'],
        body: ['Body Wrap', 'Body Scrub'],
        aromatherapy: ['Aromatherapy Massage', 'Aromatherapy'],
        reflexology: ['Reflexology', 'Foot Reflexology']
      };

      if (treatmentMap[filters.treatmentType]) {
        filtered = filtered.filter(booking =>
          treatmentMap[filters.treatmentType].some(treatment =>
            booking.treatment.includes(treatment)
          )
        );
      }
    }

    if (filters.status !== 'all') {
      filtered = filtered.filter(booking => booking.status === filters.status);
    }

    filtered.sort((a, b) => a.time.localeCompare(b.time));
    setFilteredBookings(filtered);
  }, [bookings, filters]);

  const calculateBookingCounts = (bookingsList) => {
    const counts = { confirmed: 0, pending: 0, inProgress: 0, completed: 0 };
    bookingsList.forEach(booking => {
      switch (booking.status) {
        case 'confirmed': counts.confirmed++; break;
        case 'pending': counts.pending++; break;
        case 'in-progress': counts.inProgress++; break;
        case 'completed': counts.completed++; break;
        default: break;
      }
    });
    setBookingCounts(counts);
  };

  const showError = (msg) => {
    setActionError(msg);
    setTimeout(() => setActionError(null), 5000);
  };

  const showSuccess = (msg) => {
    setActionSuccess(msg);
    setTimeout(() => setActionSuccess(null), 3000);
  };

  const handleFiltersChange = (newFilters) => {
    setFilters(newFilters);
  };

  const getOverviewTitle = () => {
    switch (filters.dateRange) {
      case 'today': return "Today's Overview";
      case 'tomorrow': return "Tomorrow's Overview";
      case 'week': return "This Week's Overview";
      case 'month': return "This Month's Overview";
      default: return "Overview";
    }
  };

  // Handle viewing a booking from the new booking notification
  const handleViewNewBooking = (bookingDate) => {
    const today = new Date();
    const booking = new Date(bookingDate);
    const tomorrow = new Date(today);
    tomorrow.setDate(tomorrow.getDate() + 1);

    // Determine which filter to set based on booking date
    let newDateRange = 'today';
    if (formatDate(booking) === formatDate(today)) {
      newDateRange = 'today';
    } else if (formatDate(booking) === formatDate(tomorrow)) {
      newDateRange = 'tomorrow';
    } else {
      // For other dates, use week or month view
      const weekStart = new Date(today);
      weekStart.setDate(today.getDate() - today.getDay());
      const weekEnd = new Date(weekStart);
      weekEnd.setDate(weekStart.getDate() + 6);

      if (booking >= weekStart && booking <= weekEnd) {
        newDateRange = 'week';
      } else {
        newDateRange = 'month';
      }
    }

    setFilters(prev => ({ ...prev, dateRange: newDateRange }));
    setNewBookingNotification(null);
  };

  // Wire to real API: updateBookingStatus
  const handleStatusUpdate = async (bookingId, newStatus, reason) => {
    setActionError(null);
    const dbStatus = toDbStatus(newStatus);
    const result = await updateBookingStatus({ bookingId, newStatus: dbStatus, reason });

    if (result.error) {
      showError(result.error.message || 'Failed to update status.');
      return;
    }

    showSuccess(`Status updated to ${newStatus}`);
    await loadData();
  };

  // Wire to real API: assignDentist
  const handleAssignDentist = async (bookingId, dentistIds, notes) => {
    setActionError(null);
    const ids = Array.isArray(dentistIds) ? dentistIds : (dentistIds ? [dentistIds] : []);
    const result = await assignDentist({ bookingId, dentistIds: ids });

    if (result.error) {
      showError(result.error.message || 'Failed to assign dentist.');
      return;
    }

    showSuccess('Dentist assigned successfully');
    await loadData();
  };

  // Wire to real API: recordPayment
  const handleRecordPayment = async (bookingId, opts) => {
    setActionError(null);
    const result = await recordPayment({ bookingId, ...opts });

    if (result.error) {
      return { error: result.error };
    }

    showSuccess('Payment recorded successfully');
    await loadData();
    return { error: null };
  };

  // Wire to real API: applyDiscount
  const handleApplyDiscount = async (bookingId, { discountType, discountValue, discountReason, requestedTo }) => {
    setActionError(null);
    const result = await applyDiscount({ bookingId, discountType, discountValue, discountReason, requestedTo });
    if (result.error) {
      return { error: result.error };
    }
    showSuccess(result.data?.isPending ? 'Discount request sent for approval' : 'Discount applied successfully');
    await loadData();
    return { data: result.data };
  };

  const userRole = profile?.role || 'staff';

  return (
    <AppShell
      variant={viewMode === 'calendar' ? 'fill' : 'page'}
      header={{
        realtimeStatus,
        notifications,
        unreadCount: unreadNotifCount,
        onMarkAllRead: markAllNotifsRead,
        onItemClick: handleNotificationClick,
      }}
      floating={
        <>
        {actionError && (
          <div className="fixed top-16 sm:top-20 left-4 right-4 sm:left-1/2 sm:right-auto sm:transform sm:-translate-x-1/2 z-toast bg-error text-white px-4 sm:px-5 py-3 rounded-spa-lg spa-shadow-elevated animate-fade-in flex items-center space-x-2">
            <span className="font-body font-body-medium text-sm flex-1">{actionError}</span>
            <button onClick={() => setActionError(null)} className="ml-2 hover:opacity-80 text-white p-1">
              <Icon name="X" size={16} />
            </button>
          </div>
        )}
        {actionSuccess && (
          <div className="fixed top-16 sm:top-20 left-4 right-4 sm:left-1/2 sm:right-auto sm:transform sm:-translate-x-1/2 z-toast bg-success text-white px-4 sm:px-5 py-3 rounded-spa-lg spa-shadow-elevated animate-fade-in flex items-center space-x-2">
            <span className="font-body font-body-medium text-sm">{actionSuccess}</span>
          </div>
        )}
        {newBookingNotification && (
          <div className="fixed top-16 sm:top-20 left-4 right-4 sm:left-auto sm:right-6 z-toast bg-primary text-white px-4 sm:px-5 py-3 rounded-spa-lg spa-shadow-elevated animate-fade-in sm:max-w-sm">
            <div className="flex items-start space-x-3">
              <div className="flex-shrink-0 mt-0.5">
                <Icon name="CalendarPlus" size={20} />
              </div>
              <div className="flex-1 min-w-0">
                <p className="font-body font-body-medium text-sm">{newBookingNotification.message}</p>
                {newBookingNotification.customerName && (
                  <p className="font-caption text-xs text-white/80 mt-0.5 truncate">
                    {newBookingNotification.customerName}
                    {newBookingNotification.bookingNumber && ` - ${newBookingNotification.bookingNumber}`}
                  </p>
                )}
              </div>
              <div className="flex items-center space-x-2 flex-shrink-0">
                <button
                  onClick={() => handleViewNewBooking(newBookingNotification.date)}
                  className="px-2.5 py-1.5 bg-white/20 hover:bg-white/30 rounded text-xs font-body font-body-medium transition-colors min-h-[32px]"
                >
                  View
                </button>
                <button
                  onClick={() => setNewBookingNotification(null)}
                  className="hover:opacity-80 text-white/80 hover:text-white p-1 min-h-[32px]"
                >
                  <Icon name="X" size={16} />
                </button>
              </div>
            </div>
          </div>
        )}
        </>
      }
    >
      {viewMode === 'dashboard' ? (
        <div className="flex flex-col gap-2 sm:gap-3 min-h-[calc(100vh-120px)]">
          {/* Overview Stats */}
          <h2 className="text-base sm:text-lg font-semibold text-gray-900">{getOverviewTitle()}</h2>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-2 sm:gap-3">
            <div className="bg-white rounded-lg border border-gray-200 p-3 sm:p-4">
              <div className="text-[10px] sm:text-xs font-medium text-gray-500 mb-0.5 sm:mb-1">Confirmed</div>
              <div className="text-xl sm:text-2xl font-semibold text-emerald-600">{bookingCounts.confirmed}</div>
            </div>
            <div className="bg-white rounded-lg border border-gray-200 p-3 sm:p-4">
              <div className="text-[10px] sm:text-xs font-medium text-gray-500 mb-0.5 sm:mb-1">Pending</div>
              <div className="text-xl sm:text-2xl font-semibold text-amber-500">{bookingCounts.pending}</div>
            </div>
            <div className="bg-white rounded-lg border border-gray-200 p-3 sm:p-4">
              <div className="text-[10px] sm:text-xs font-medium text-gray-500 mb-0.5 sm:mb-1">In Progress</div>
              <div className="text-xl sm:text-2xl font-semibold text-blue-600">{bookingCounts.inProgress}</div>
            </div>
            <div className="bg-white rounded-lg border border-gray-200 p-3 sm:p-4">
              <div className="text-[10px] sm:text-xs font-medium text-gray-500 mb-0.5 sm:mb-1">Completed</div>
              <div className="text-xl sm:text-2xl font-semibold text-gray-400">{bookingCounts.completed}</div>
            </div>
          </div>

          {/* Inline Filters */}
          <QuickFilters
            onFiltersChange={handleFiltersChange}
            bookingCounts={bookingCounts}
          />

          {/* Main Grid - Responsive: stack on mobile, side-by-side on lg */}
          <div className="grid grid-cols-1 lg:grid-cols-12 gap-2 sm:gap-3 flex-1">
            {/* Bookings List - Full width on mobile/tablet, 9 cols on desktop */}
            <div className="lg:col-span-9 order-1">
              {loading ? (
                <div className="bg-white rounded-lg border border-gray-200 p-8 sm:p-12 text-center">
                  <div className="animate-spin w-8 h-8 border-2 border-primary border-t-transparent rounded-full mx-auto mb-3" />
                  <p className="text-sm text-gray-500">Loading bookings...</p>
                </div>
              ) : (
                <BookingsList
                  bookings={filteredBookings}
                  dentists={dentists}
                  onStatusUpdate={handleStatusUpdate}
                  onAssignDentist={handleAssignDentist}
                  onRecordPayment={handleRecordPayment}
                  onApplyDiscount={handleApplyDiscount}
                  userRole={profile?.role || 'staff'}
                  onRefresh={loadData}
                  dateRange={filters.dateRange}
                />
              )}
            </div>

            {/* Dentist Panel - Below bookings on mobile, sidebar on desktop */}
            <div className="lg:col-span-3 order-2">
              <DentistAvailability
                dentists={dentists}
                pendingBookings={bookings.filter(b => b.status === 'pending' && !b.dentist)}
                onAssignDentist={handleAssignDentist}
              />
            </div>
          </div>
        </div>
      ) : viewMode === 'bookings' ? (
        <BookingLookupPanel
          dentists={dentists}
          onStatusUpdate={handleStatusUpdate}
          onAssignDentist={handleAssignDentist}
          onRecordPayment={handleRecordPayment}
          onApplyDiscount={handleApplyDiscount}
          userRole={profile?.role || 'staff'}
          onRefresh={loadData}
        />
      ) : viewMode === 'calendar' ? (
        <OperationalCalendar branchId={branchId} />
      ) : viewMode === 'collect-payment' ? (
        <CollectPaymentPanel onSuccess={showSuccess} />
      ) : viewMode === 'new-booking' ? (
        <StaffBookingForm onBookingCreated={loadData} />
      ) : viewMode === 'check-booking' ? (
        <CheckBookingPanel branchId={branchId} />
      ) : viewMode === 'new-membership' && MEMBERSHIP_ENABLED ? (
        <EnrollMemberModal
          onClose={() => setSearchParams({ view: 'dashboard' })}
          onEnrolled={() => {
            setSearchParams({ view: 'dashboard' });
            showSuccess('Membership created.');
          }}
        />
      ) : viewMode === 'new-voucher' && VOUCHER_ENABLED ? (
        <NewVoucherModal
          userRole={userRole}
          onClose={() => setSearchParams({ view: 'dashboard' })}
          onIssued={() => {
            setSearchParams({ view: 'dashboard' });
            showSuccess('Voucher issued.');
          }}
        />
      ) : (
        <StaffBookingForm onBookingCreated={loadData} />
      )}
    </AppShell>
  );
};

export default BranchStaffDashboard;
