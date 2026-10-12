import React, { useState, useEffect, useCallback, useMemo } from 'react';
import Icon from '../../../../components/AppIcon';
import CustomSelect from '../../../../components/ui/CustomSelect';
import FilterBar from '../../../../components/ui/FilterBar';
import TransferManagementModal from '../../../../components/ui/TransferManagementModal';
import BlockScopeDialog from '../calendar/BlockScopeDialog';
import { useAuth } from '../../../../contexts/AuthContext';
import { useTransferFeature } from '../../../../hooks/useTransferFeature';
import {
  fetchAttendance,
  fetchAttendanceSummary,
  markAttendance,
  fetchPendingTransfers,
  fetchDentistTransferStatus,
  cancelScheduledTransfer,
  revertStaffTransferNow,
} from '../../../../services/api';

const ATTENDANCE_OPTIONS = [
  { value: '', label: 'Not Marked' },
  { value: 'Present', label: 'Present' },
  { value: 'Absent', label: 'Absent' },
  { value: 'Annual Leave', label: 'Annual Leave' },
  { value: 'Sick Leave', label: 'Sick Leave' },
  { value: 'Day Off', label: 'Day Off' },
];

const STATUS_FILTER_OPTIONS = [
  { value: 'all', label: 'All Statuses' },
  { value: '', label: 'Not Marked' },
  { value: 'Present', label: 'Present' },
  { value: 'Absent', label: 'Absent' },
  { value: 'Annual Leave', label: 'Annual Leave' },
  { value: 'Sick Leave', label: 'Sick Leave' },
  { value: 'Day Off', label: 'Day Off' },
];

const STAFF_TYPE_OPTIONS = [
  { value: 'all', label: 'All Staff' },
  { value: 'treatment', label: 'Treatment Staff' },
  { value: 'support', label: 'Support Staff' },
];

function SummaryCard({ icon, iconBg, iconColor, label, value, highlight }) {
  return (
    <div className="bg-surface rounded-spa-lg border border-border p-4 flex items-center space-x-3">
      <div className={`w-9 h-9 rounded-lg ${iconBg} flex items-center justify-center flex-shrink-0`}>
        <Icon name={icon} size={18} className={iconColor} />
      </div>
      <div>
        <p className={`font-heading font-heading-semibold text-lg ${highlight || 'text-text-primary'}`}>
          {value}
        </p>
        <p className="font-caption font-caption-normal text-[11px] text-text-tertiary">{label}</p>
      </div>
    </div>
  );
}

const AttendancePanel = ({ branchId }) => {
  const { profile } = useAuth();
  const transfersAvailable = useTransferFeature() === true; // fail open: hide all transfer UI if the DB lacks the tables
  const canTransfer = transfersAvailable && ['manager', 'admin'].includes(profile?.role);
  const today = new Date().toISOString().split('T')[0];

  const [selectedDate, setSelectedDate] = useState(today);
  const [dentists, setDentists] = useState([]);
  const [summary, setSummary] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [dayLocked, setDayLocked] = useState(false);

  // Transfers (fail open: if the transfer tables/RPCs don't exist, these stay empty and nothing renders)
  const [pendingByDentist, setPendingByDentist] = useState({});
  const [transferStatusByDentist, setTransferStatusByDentist] = useState({});
  const [transferTarget, setTransferTarget] = useState(null);   // { dentistId, dentistName }
  const [transferCancel, setTransferCancel] = useState(null);   // { kind: 'scheduled'|'active', item }
  const [toast, setToast] = useState(null);

  // Track local edits per dentist: { [dentistId]: { status, checkInTime, checkOutTime, notes, dirty } }
  const [edits, setEdits] = useState({});
  const [saving, setSaving] = useState({});

  // Filters
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [staffTypeFilter, setStaffTypeFilter] = useState('all');

  // Multi-selection for bulk marking
  const [selectedIds, setSelectedIds] = useState([]);

  const hasActiveFilters = searchQuery.trim().length > 0 || statusFilter !== 'all' || staffTypeFilter !== 'all';

  const filteredDentists = useMemo(() => {
    return dentists.filter((t) => {
      const matchesSearch = !searchQuery.trim()
        || (t.dentistName || '').toLowerCase().includes(searchQuery.toLowerCase().trim());
      const currentStatus = edits[t.dentistId]?.status ?? (t.status || '');
      const matchesStatus = statusFilter === 'all' || currentStatus === statusFilter;
      const matchesType = staffTypeFilter === 'all'
        || (staffTypeFilter === 'treatment' ? t.isTreatmentStaff : !t.isTreatmentStaff);
      return matchesSearch && matchesStatus && matchesType;
    });
  }, [dentists, edits, searchQuery, statusFilter, staffTypeFilter]);

  const allFilteredSelected = filteredDentists.length > 0
    && filteredDentists.every((t) => selectedIds.includes(t.dentistId));

  const toggleSelect = (id) => {
    setSelectedIds((prev) => prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]);
  };

  const toggleSelectAll = () => {
    if (allFilteredSelected) {
      setSelectedIds((prev) => prev.filter((id) => !filteredDentists.some((t) => t.dentistId === id)));
    } else {
      setSelectedIds((prev) => [...new Set([...prev, ...filteredDentists.map((t) => t.dentistId)])]);
    }
  };

  // Away (transferred out, or scheduled to go) and visiting dentists for this branch.
  const fmtWhen = (iso) => (iso ? new Date(iso).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit', hour12: true }).replace(' am', 'am').replace(' pm', 'pm') : null);
  const transferredOut = useMemo(() => {
    const active = Object.values(transferStatusByDentist)
      .filter((s) => s.applied && !s.reverted && s.revertAt && s.fromBranchId === branchId && s.toBranchId !== branchId)
      .map((s) => ({ ...s, isPending: false }));
    const pending = Object.values(pendingByDentist).map((p) => ({
      id: p.id, dentistId: p.dentistId, dentistName: p.dentistName, toBranch: p.toBranch,
      effectiveDate: p.effectiveDate, startTime: p.startTime, revertAt: p.revertAt, isPending: true,
    }));
    return [...active, ...pending];
  }, [transferStatusByDentist, pendingByDentist, branchId]);
  const visitorStatus = (dentistId) => {
    const st = transferStatusByDentist[dentistId];
    return st?.applied && !st?.reverted && st?.revertAt && st?.toBranchId === branchId ? st : null;
  };

  const handleConfirmTransferCancel = async () => {
    const req = transferCancel;
    setTransferCancel(null);
    if (!req) return;
    const { error: cancelError } = req.kind === 'scheduled'
      ? await cancelScheduledTransfer(req.item.id)
      : await revertStaffTransferNow({ transferId: req.item.id, revertedAt: null });
    if (cancelError) {
      showToast(cancelError.message?.replace(/^revert_staff_transfer_now:\s*/, '') || 'Failed to cancel transfer.', 'error');
      return;
    }
    showToast(req.kind === 'scheduled' ? 'Scheduled transfer cancelled.' : `${req.item.dentistName} is back at this branch.`);
    await loadData();
  };

  const showToast = (msg, type = 'success') => {
    setToast({ msg, type });
    setTimeout(() => setToast(null), 3000);
  };

  const loadPendingTransfers = useCallback(async () => {
    if (!branchId) return;
    const [{ data }, { data: statusMap }] = await Promise.all([
      fetchPendingTransfers(branchId),
      fetchDentistTransferStatus(branchId),
    ]);
    const map = {};
    (data || []).forEach((t) => { map[t.dentistId] = t; });
    setPendingByDentist(map);
    setTransferStatusByDentist(statusMap || {});
  }, [branchId]);

  const loadData = useCallback(async () => {
    if (!branchId) return;
    setLoading(true);
    setError(null);
    setDayLocked(false);

    const [attendanceResult, summaryResult] = await Promise.all([
      fetchAttendance({ branchId, date: selectedDate }),
      fetchAttendanceSummary({ branchId, date: selectedDate }),
      loadPendingTransfers(),
    ]);

    if (attendanceResult.error) {
      setError(attendanceResult.error.message || 'Failed to load attendance.');
      setLoading(false);
      return;
    }

    const rows = attendanceResult.data || [];
    setDentists(rows);
    setSelectedIds([]);

    // Initialize edits from fetched data
    const initialEdits = {};
    for (const t of rows) {
      initialEdits[t.dentistId] = {
        status: t.status || '',
        checkInTime: t.checkInTime || '',
        checkOutTime: t.checkOutTime || '',
        notes: t.notes || '',
        dirty: false,
      };
    }
    setEdits(initialEdits);

    if (summaryResult.data) {
      setSummary(summaryResult.data);
    }

    setLoading(false);
  }, [branchId, selectedDate, loadPendingTransfers]);

  useEffect(() => { loadData(); }, [loadData]);

  const handleFieldChange = (dentistId, field, value) => {
    setEdits(prev => ({
      ...prev,
      [dentistId]: {
        ...prev[dentistId],
        [field]: value,
        dirty: true,
      },
    }));
  };

  const handleSave = async (dentistId) => {
    const edit = edits[dentistId];
    if (!edit || !edit.status) {
      showToast('Please select a status before saving.', 'error');
      return;
    }

    setSaving(prev => ({ ...prev, [dentistId]: true }));

    const result = await markAttendance({
      dentistId,
      date: selectedDate,
      status: edit.status,
      checkInTime: edit.checkInTime || null,
      checkOutTime: edit.checkOutTime || null,
      notes: edit.notes || null,
    });

    setSaving(prev => ({ ...prev, [dentistId]: false }));

    if (result.error) {
      if (result.error.code === 'ATTENDANCE_DAY_LOCKED') {
        setDayLocked(true);
        showToast('Day is closed. Attendance cannot be modified.', 'error');
        return;
      }
      showToast(result.error.message || 'Failed to save attendance.', 'error');
      return;
    }

    // Mark as not dirty
    setEdits(prev => ({
      ...prev,
      [dentistId]: { ...prev[dentistId], dirty: false },
    }));

    showToast(`Attendance saved for ${dentists.find(t => t.dentistId === dentistId)?.dentistName || 'dentist'}`);

    // Refresh summary
    const summaryResult = await fetchAttendanceSummary({ branchId, date: selectedDate });
    if (summaryResult.data) {
      setSummary(summaryResult.data);
    }
  };

  const handleSaveAll = async () => {
    const dirtyIds = Object.entries(edits)
      .filter(([, e]) => e.dirty && e.status)
      .map(([id]) => id);

    if (dirtyIds.length === 0) {
      showToast('No changes to save.', 'error');
      return;
    }

    let successCount = 0;
    let lockHit = false;

    for (const id of dirtyIds) {
      setSaving(prev => ({ ...prev, [id]: true }));

      const edit = edits[id];
      const result = await markAttendance({
        dentistId: id,
        date: selectedDate,
        status: edit.status,
        checkInTime: edit.checkInTime || null,
        checkOutTime: edit.checkOutTime || null,
        notes: edit.notes || null,
      });

      setSaving(prev => ({ ...prev, [id]: false }));

      if (result.error) {
        if (result.error.code === 'ATTENDANCE_DAY_LOCKED') {
          lockHit = true;
          setDayLocked(true);
          break;
        }
        continue;
      }

      setEdits(prev => ({
        ...prev,
        [id]: { ...prev[id], dirty: false },
      }));
      successCount++;
    }

    if (lockHit) {
      showToast('Day is closed. Attendance cannot be modified.', 'error');
    } else if (successCount > 0) {
      showToast(`Saved attendance for ${successCount} dentist${successCount !== 1 ? 's' : ''}`);
    }

    // Refresh summary
    const summaryResult = await fetchAttendanceSummary({ branchId, date: selectedDate });
    if (summaryResult.data) {
      setSummary(summaryResult.data);
    }
  };

  const handleBulkMark = async (status) => {
    if (selectedIds.length === 0) return;
    if (dayLocked) {
      showToast('Day is closed. Attendance cannot be modified.', 'error');
      return;
    }

    let successCount = 0;
    let lockHit = false;

    for (const id of selectedIds) {
      setSaving(prev => ({ ...prev, [id]: true }));

      const edit = edits[id] || {};
      const result = await markAttendance({
        dentistId: id,
        date: selectedDate,
        status,
        checkInTime: edit.checkInTime || null,
        checkOutTime: edit.checkOutTime || null,
        notes: edit.notes || null,
      });

      setSaving(prev => ({ ...prev, [id]: false }));

      if (result.error) {
        if (result.error.code === 'ATTENDANCE_DAY_LOCKED') {
          lockHit = true;
          setDayLocked(true);
          break;
        }
        continue;
      }

      setEdits(prev => ({
        ...prev,
        [id]: { ...prev[id], status, dirty: false },
      }));
      successCount++;
    }

    if (lockHit) {
      showToast('Day is closed. Attendance cannot be modified.', 'error');
    } else if (successCount > 0) {
      showToast(`Marked ${successCount} dentist${successCount !== 1 ? 's' : ''} ${status}`);
    }

    setSelectedIds([]);

    const summaryResult = await fetchAttendanceSummary({ branchId, date: selectedDate });
    if (summaryResult.data) {
      setSummary(summaryResult.data);
    }
  };

  const dirtyCount = Object.values(edits).filter(e => e.dirty && e.status).length;

  // ── Loading state ──────────────────────────────────────────
  if (loading) {
    return (
      <div className="space-y-4">
        <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
          {[0, 1, 2, 3, 4].map(i => (
            <div key={i} className="bg-surface rounded-spa-lg border border-border p-4 animate-pulse">
              <div className="h-5 bg-background rounded w-12 mb-2" />
              <div className="h-3 bg-background rounded w-16" />
            </div>
          ))}
        </div>
        <div className="bg-surface rounded-spa-lg border border-border p-6 animate-pulse">
          <div className="h-4 bg-background rounded w-48 mb-4" />
          <div className="space-y-3">
            {[0, 1, 2].map(i => (
              <div key={i} className="h-10 bg-background rounded" />
            ))}
          </div>
        </div>
      </div>
    );
  }

  // ── Error state ────────────────────────────────────────────
  if (error) {
    return (
      <div className="bg-error/5 border border-error/20 rounded-spa p-4 flex items-center space-x-3">
        <Icon name="AlertCircle" size={18} className="text-error flex-shrink-0" />
        <p className="font-body text-sm text-error">{error}</p>
        <button onClick={loadData} className="ml-auto font-body font-body-medium text-sm text-error underline">
          Retry
        </button>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <div>
          <h2 className="font-heading font-heading-semibold text-xl text-text-primary">Staff Attendance</h2>
          <p className="font-body text-sm text-text-secondary">Mark daily attendance for active staff.</p>
        </div>
        <div className="flex items-center space-x-3">
          <input
            type="date"
            value={selectedDate}
            onChange={(e) => setSelectedDate(e.target.value)}
            className="px-3 py-2 rounded-spa border border-border bg-surface font-body text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-primary/30"
          />
          {dirtyCount > 0 && !dayLocked && (
            <button
              onClick={handleSaveAll}
              className="inline-flex items-center space-x-2 px-4 py-2 bg-primary text-white rounded-spa font-body font-body-medium text-sm hover:bg-primary/90 spa-transition-fast"
            >
              <Icon name="Save" size={16} />
              <span>Save All ({dirtyCount})</span>
            </button>
          )}
        </div>
      </div>

      {/* Day Locked Banner */}
      {dayLocked && (
        <div className="bg-error/5 border border-error/20 rounded-spa p-4 flex items-center space-x-3">
          <Icon name="Lock" size={18} className="text-error flex-shrink-0" />
          <p className="font-body font-body-medium text-sm text-error">
            Day is closed. Attendance cannot be modified.
          </p>
        </div>
      )}

      {/* Summary Cards */}
      {summary && (
        <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
          <SummaryCard
            icon="UserCheck"
            iconBg="bg-success/10"
            iconColor="text-success"
            label="Present"
            value={summary.presentCount}
          />
          <SummaryCard
            icon="UserX"
            iconBg="bg-error/10"
            iconColor="text-error"
            label="Absent"
            value={summary.absentCount}
          />
          <SummaryCard
            icon="CalendarOff"
            iconBg="bg-warning/10"
            iconColor="text-warning"
            label="Leave / Day Off"
            value={summary.leaveCount}
          />
          <SummaryCard
            icon="Percent"
            iconBg="bg-primary/10"
            iconColor="text-primary"
            label="Attendance Rate"
            value={`${summary.attendanceRate}%`}
            highlight={summary.attendanceRate >= 80 ? 'text-success' : summary.attendanceRate >= 50 ? 'text-warning' : 'text-error'}
          />
        </div>
      )}

      {/* Search & Status Filter */}
      <FilterBar
        search={{
          value: searchQuery,
          onChange: setSearchQuery,
          placeholder: 'Search staff...',
        }}
        filters={[
          {
            value: staffTypeFilter,
            onChange: setStaffTypeFilter,
            options: STAFF_TYPE_OPTIONS,
          },
          {
            value: statusFilter,
            onChange: setStatusFilter,
            options: STATUS_FILTER_OPTIONS,
          },
        ]}
        resultCount={hasActiveFilters ? {
          filtered: filteredDentists.length,
          total: dentists.length,
        } : undefined}
        hasActiveFilters={hasActiveFilters}
        onClear={() => { setSearchQuery(''); setStatusFilter('all'); setStaffTypeFilter('all'); }}
      />

      {/* Bulk Action Bar */}
      {selectedIds.length > 0 && !dayLocked && (
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 px-4 py-3 bg-primary/5 border border-primary/20 rounded-spa-lg">
          <span className="font-body font-body-medium text-sm text-text-primary">
            {selectedIds.length} selected
          </span>
          <div className="flex items-center space-x-2">
            <button
              onClick={() => handleBulkMark('Present')}
              className="inline-flex items-center space-x-1.5 px-3 py-1.5 bg-success text-white rounded-spa font-body font-body-medium text-sm hover:bg-success/90 spa-transition-fast"
            >
              <Icon name="UserCheck" size={15} />
              <span>Mark Present</span>
            </button>
            <button
              onClick={() => handleBulkMark('Absent')}
              className="inline-flex items-center space-x-1.5 px-3 py-1.5 bg-error text-white rounded-spa font-body font-body-medium text-sm hover:bg-error/90 spa-transition-fast"
            >
              <Icon name="UserX" size={15} />
              <span>Mark Absent</span>
            </button>
            <button
              onClick={() => setSelectedIds([])}
              className="px-3 py-1.5 text-text-secondary rounded-spa font-body font-body-medium text-sm hover:bg-background spa-transition-fast"
            >
              Clear
            </button>
          </div>
        </div>
      )}

      {/* Dentist Table */}
      <div className="bg-surface rounded-spa-lg border border-border">
        {/* Table header */}
        <div className="hidden md:grid md:grid-cols-[1fr_140px_110px_110px_1fr_120px] gap-3 px-5 py-3 bg-background/50 border-b border-border rounded-t-spa-lg">
          <span className="font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide flex items-center gap-2">
            <input
              type="checkbox"
              checked={allFilteredSelected}
              onChange={toggleSelectAll}
              disabled={dayLocked || filteredDentists.length === 0}
              className="w-4 h-4 rounded border-border text-primary focus:ring-primary/30 cursor-pointer disabled:cursor-not-allowed"
              title="Select all"
            />
            Staff
          </span>
          <span className="font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide">Status</span>
          <span className="font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide">Check-in</span>
          <span className="font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide">Check-out</span>
          <span className="font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide">Notes</span>
          <span className="font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide text-center">Action</span>
        </div>

        {dentists.length === 0 ? (
          <div className="p-8 text-center">
            <Icon name="Users" size={32} className="text-text-tertiary mx-auto mb-3" />
            <p className="font-body text-sm text-text-tertiary">No active staff found for this branch.</p>
          </div>
        ) : filteredDentists.length === 0 ? (
          <div className="p-8 text-center">
            <Icon name="SearchX" size={32} className="text-text-tertiary mx-auto mb-3" />
            <p className="font-body text-sm text-text-tertiary">No staff match the current filters.</p>
          </div>
        ) : (
          <div className="divide-y divide-border">
            {filteredDentists.map(t => {
              const edit = edits[t.dentistId] || {};
              const isSaving = saving[t.dentistId];
              const isDirty = edit.dirty;
              const isDisabled = dayLocked || isSaving;

              return (
                <div
                  key={t.dentistId}
                  className={`grid grid-cols-1 md:grid-cols-[1fr_140px_110px_110px_1fr_120px] gap-3 px-5 py-3 items-center ${
                    isDirty ? 'bg-primary/5' : ''
                  }`}
                >
                  {/* Dentist name */}
                  <div className="flex items-center space-x-2 min-w-0">
                    <input
                      type="checkbox"
                      checked={selectedIds.includes(t.dentistId)}
                      onChange={() => toggleSelect(t.dentistId)}
                      disabled={dayLocked}
                      className="w-4 h-4 rounded border-border text-primary focus:ring-primary/30 cursor-pointer disabled:cursor-not-allowed flex-shrink-0"
                    />
                    <div className="w-7 h-7 rounded-full flex items-center justify-center flex-shrink-0 bg-primary/10">
                      <Icon name="User" size={14} className="text-primary" />
                    </div>
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <span className="font-body font-body-medium text-sm text-text-primary truncate">{t.dentistName}</span>
                        {transfersAvailable && visitorStatus(t.dentistId) && (
                          <span className="inline-flex items-center px-2 py-0.5 rounded text-[10px] font-caption bg-primary/10 text-primary">
                            Visiting from {visitorStatus(t.dentistId).fromBranch} · until {fmtWhen(visitorStatus(t.dentistId).revertAt)}
                          </span>
                        )}
                        {transfersAvailable && pendingByDentist[t.dentistId] && (
                          <span className="inline-flex items-center px-2 py-0.5 rounded text-[10px] font-caption bg-background text-text-secondary border border-border">
                            Transfer scheduled → {pendingByDentist[t.dentistId].toBranch}
                          </span>
                        )}
                        {edit.status && (
                          <span className={`md:hidden inline-flex items-center px-2 py-0.5 rounded text-[10px] font-caption font-caption-medium ${
                            edit.status === 'Present' ? 'bg-success/10 text-success' :
                            edit.status === 'Absent' ? 'bg-error/10 text-error' :
                            (edit.status === 'Annual Leave' || edit.status === 'Sick Leave') ? 'bg-warning/10 text-warning' :
                            'bg-accent/10 text-accent'
                          }`}>
                            {edit.status}
                          </span>
                        )}
                      </div>
                    </div>
                  </div>

                  {/* Status dropdown */}
                  <CustomSelect
                    value={edit.status || ''}
                    onChange={(val) => handleFieldChange(t.dentistId, 'status', val)}
                    options={ATTENDANCE_OPTIONS}
                    disabled={isDisabled}
                    size="sm"
                    valueClassName={
                      edit.status === 'Present' ? 'text-success' :
                      edit.status === 'Absent' ? 'text-error' :
                      (edit.status === 'Annual Leave' || edit.status === 'Sick Leave') ? 'text-warning' :
                      edit.status === 'Day Off' ? 'text-accent' :
                      'text-text-tertiary'
                    }
                  />

                  {/* Check-in */}
                  <input
                    type="time"
                    value={edit.checkInTime || ''}
                    onChange={(e) => handleFieldChange(t.dentistId, 'checkInTime', e.target.value)}
                    disabled={isDisabled}
                    className="px-2 py-1.5 rounded-spa border border-border bg-surface font-data font-data-normal text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-primary/30 disabled:opacity-50 disabled:cursor-not-allowed"
                  />

                  {/* Check-out */}
                  <input
                    type="time"
                    value={edit.checkOutTime || ''}
                    onChange={(e) => handleFieldChange(t.dentistId, 'checkOutTime', e.target.value)}
                    disabled={isDisabled}
                    className="px-2 py-1.5 rounded-spa border border-border bg-surface font-data font-data-normal text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-primary/30 disabled:opacity-50 disabled:cursor-not-allowed"
                  />

                  {/* Notes */}
                  <input
                    type="text"
                    placeholder="Optional notes..."
                    value={edit.notes || ''}
                    onChange={(e) => handleFieldChange(t.dentistId, 'notes', e.target.value)}
                    disabled={isDisabled}
                    className="px-2 py-1.5 rounded-spa border border-border bg-surface font-body text-sm text-text-primary placeholder:text-text-tertiary focus:outline-none focus:ring-2 focus:ring-primary/30 disabled:opacity-50 disabled:cursor-not-allowed"
                  />

                  {/* Actions */}
                  <div className="flex justify-center items-center gap-1.5">
                    {canTransfer && (
                      <button
                        onClick={() => setTransferTarget({ dentistId: t.dentistId, dentistName: t.dentistName })}
                        className="inline-flex items-center justify-center w-8 h-8 rounded-spa border border-border text-text-secondary hover:bg-background spa-transition-fast"
                        title="Transfer to another branch"
                        aria-label={`Transfer ${t.dentistName}`}
                      >
                        <Icon name="ArrowRightLeft" size={15} />
                      </button>
                    )}
                    <button
                      onClick={() => handleSave(t.dentistId)}
                      disabled={isDisabled || !isDirty}
                      className={`inline-flex items-center justify-center w-8 h-8 rounded-spa spa-transition-fast ${
                        isDirty && !isDisabled
                          ? 'bg-primary text-white hover:bg-primary/90'
                          : 'bg-background text-text-tertiary cursor-not-allowed'
                      }`}
                      title={isDirty ? 'Save' : 'No changes'}
                    >
                      {isSaving ? (
                        <div className="animate-spin w-4 h-4 border-2 border-white border-t-transparent rounded-full" />
                      ) : (
                        <Icon name="Check" size={16} />
                      )}
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* Transferred-out dentists (away or scheduled to go) */}
      {transfersAvailable && transferredOut.length > 0 && (
        <div className="bg-surface rounded-spa-lg border border-border">
          <div className="px-5 py-3 border-b border-border flex items-center gap-2">
            <Icon name="ArrowRightLeft" size={15} className="text-text-secondary" />
            <h3 className="font-heading font-heading-semibold text-sm text-text-primary">Transferred out ({transferredOut.length})</h3>
          </div>
          <div className="divide-y divide-border">
            {transferredOut.map((s) => (
              <div key={`${s.isPending ? 'p' : 'a'}-${s.id}`} className="px-5 py-3 flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <button
                    type="button"
                    onClick={() => canTransfer && setTransferTarget({ dentistId: s.dentistId, dentistName: s.dentistName })}
                    className="font-body font-body-medium text-sm text-text-primary hover:underline truncate text-left"
                  >
                    {s.dentistName}
                  </button>
                  <p className="font-body text-xs text-text-secondary">
                    {s.isPending
                      ? `Scheduled → ${s.toBranch} on ${s.effectiveDate}${s.startTime ? ` at ${s.startTime.slice(0, 5)}` : ''}`
                      : `At ${s.toBranch} · back ${fmtWhen(s.revertAt)}`}
                  </p>
                </div>
                {canTransfer && (
                  <button
                    type="button"
                    onClick={() => setTransferCancel({ kind: s.isPending ? 'scheduled' : 'active', item: s })}
                    className="px-3 py-1.5 text-[13px] font-body font-body-medium border border-border rounded-spa hover:bg-background spa-transition-fast flex-shrink-0"
                  >
                    {s.isPending ? 'Cancel transfer' : 'Bring back now'}
                  </button>
                )}
              </div>
            ))}
          </div>
        </div>
      )}

      {transferTarget && (
        <TransferManagementModal
          dentistId={transferTarget.dentistId}
          dentistName={transferTarget.dentistName}
          currentBranchId={branchId}
          defaultStartDate={selectedDate}
          onClose={() => setTransferTarget(null)}
          onSuccess={(message) => {
            setTransferTarget(null);
            if (message) showToast(message);
            loadData();
          }}
        />
      )}

      {transferCancel && (
        <BlockScopeDialog
          title={transferCancel.kind === 'scheduled'
            ? `Cancel ${transferCancel.item.dentistName}'s scheduled transfer?`
            : `Bring ${transferCancel.item.dentistName} back to this branch now?`}
          recurring={false}
          confirmLabel={transferCancel.kind === 'scheduled' ? 'Cancel transfer' : 'Bring back now'}
          onCancel={() => setTransferCancel(null)}
          onChoose={handleConfirmTransferCancel}
        />
      )}

      {/* Toast */}
      {toast && (
        <div className={`fixed top-20 left-1/2 transform -translate-x-1/2 z-toast px-5 py-3 rounded-spa-lg spa-shadow-elevated animate-fade-in flex items-center space-x-2 ${
          toast.type === 'error' ? 'bg-error text-white' : 'bg-success text-white'
        }`}>
          <Icon name={toast.type === 'error' ? 'AlertCircle' : 'CheckCircle'} size={16} />
          <span className="font-body font-body-medium text-sm">{toast.msg}</span>
        </div>
      )}
    </div>
  );
};

export default AttendancePanel;
