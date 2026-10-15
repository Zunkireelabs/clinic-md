import React, { useState, useMemo, useRef, useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';
import { DndContext, pointerWithin } from '@dnd-kit/core';
import Icon from '../../../../components/AppIcon';
import BookingActionModal from '../../../../components/ui/BookingActionModal';
import EmptySlotChoiceMenu from './EmptySlotChoiceMenu';
import AddBlockModal from './AddBlockModal';
import EditBlockModal from './EditBlockModal';
import BlockScopeDialog from './BlockScopeDialog';
import TransferFromCalendarModal from './TransferFromCalendarModal';
import TransferManagementModal from '../../../../components/ui/TransferManagementModal';
import CalendarGrid from './CalendarGrid';
import CalendarToolbar from './CalendarToolbar';
import DragPreviewOverlay from './DragPreviewOverlay';
import ReassignConfirmDialog from './ReassignConfirmDialog';
import QuickCreatePanel from './QuickCreatePanel';
import { useCalendarData } from './hooks/useCalendarData';
import { useCalendarDnd } from './hooks/useCalendarDnd';
import { useCalendarPanels } from './hooks/useCalendarPanels';
import { useCalendarShortcuts } from './hooks/useCalendarShortcuts';
import { useGoTodaySignal } from './calendarSignals';
import { useBookingActions } from './hooks/useBookingActions';
import { useAutoRefresh } from '../../../../hooks/useAutoRefresh';
import { useAuth } from '../../../../contexts/AuthContext';
import { fetchBookingById } from '../../../../services/api';
import { transformBooking } from '../../../../services/bookingTransformers';
import { todayStr, addDays, getStepDays } from './calendarDates';

// ── Component ────────────────────────────────────────────────

const OperationalCalendar = ({ branchId }) => {
  const { profile } = useAuth();
  const staffLabel = 'Dentist';
  const staffLabelPlural = 'Dentists';
  const locationLabel = 'Chair';
  const locationLabelPlural = 'Chairs';
  const enableChairs = true;

  // View state
  const [currentDate, setCurrentDate] = useState(todayStr());
  const [viewMode, setViewMode] = useState('day'); // day | 4day
  // Default to staff view if chairs are disabled
  const [columnMode, setColumnMode] = useState('dentist'); // dentist | chair
  const [freezeUnassigned, setFreezeUnassigned] = useState(true);
  const [showTreatmentOnly, setShowTreatmentOnly] = useState(true);
  const [selectedPositions, setSelectedPositions] = useState([]); // empty = all
  const [tipOpen, setTipOpen] = useState(false);
  const [actionToast, setActionToast] = useState(null);

  // Ref to the grid body for calculating time from cursor position
  const gridRef = useRef(null);

  // Multi-drag: ref to get selected bookings from CalendarGrid
  const getSelectedBookingsRef = useRef(() => []);

  const showToast = (msg, type = 'success') => {
    setActionToast({ msg, type });
    setTimeout(() => setActionToast(null), 3000);
  };


  const {
    calendarData, setCalendarData, error, attendanceMap, blocksAvailable, transfersAvailable,
    fetchData, refreshCalendar, handleDentistReorder, handleChairReorder,
  } = useCalendarData({ branchId, currentDate, viewMode });

  // Available position options for filter (from treatment staff only)
  const calendarPositionOptions = useMemo(() => {
    if (!calendarData?.dentists) return [];
    const positions = new Set();
    calendarData.dentists.forEach(t => {
      if (t.is_treatment_staff !== false && t.position) {
        t.position.split('/').forEach(p => positions.add(p.trim()));
      }
    });
    return Array.from(positions).sort();
  }, [calendarData?.dentists]);

  // Filter dentists for calendar display (hide absent/leave)
  const filteredDentists = useMemo(() => {
    if (!calendarData?.dentists) return [];
    let list = calendarData.dentists;
    list = list.filter(t => !attendanceMap[t.id]);
    if (showTreatmentOnly) {
      list = list.filter(t => t.is_treatment_staff !== false);
    }
    if (selectedPositions.length > 0) {
      list = list.filter(t => t.position && t.position.split('/').some(p => selectedPositions.includes(p.trim())));
    }
    return list;
  }, [calendarData?.dentists, showTreatmentOnly, selectedPositions, attendanceMap, currentDate]);

  // Absent / on-leave dentists (hidden from columns) for the toolbar "N away" summary
  const awayList = useMemo(() => {
    if (!calendarData?.dentists) return [];
    return Object.entries(attendanceMap)
      .map(([id, status]) => ({ id, status, name: calendarData.dentists.find(t => t.id === id)?.name }))
      .filter(a => a.name);
  }, [attendanceMap, calendarData?.dentists]);

  const {
    sensors, activeDragId, activeDragBooking, activeDragBlock, overSlotData, isRescheduling, pendingReassign, setPendingReassign,
    handleDragStart, handleDragMove, handleDragOver, handleDragEnd, handleDragCancel, handleConfirmReassign,
  } = useCalendarDnd({ calendarData, setCalendarData, columnMode, refreshCalendar, showToast, gridRef, getSelectedBookingsRef });

  const {
    selectedBooking, setSelectedBooking, modalOpen, previewBooking, quickGuardRef, bookingGuardRef, blockGuardRef,
    quickCreateSlot, retargetRequest, draftGhost, setDraftGhost,
    choiceMenuSlot, setChoiceMenuSlot, addBlockSlot, setAddBlockSlot, editingBlock, setEditingBlock,
    blockDeleteRequest, setBlockDeleteRequest, lastBlockWasChairOnly,
    transferModalTarget, setTransferModalTarget, editingTransferDentist, setEditingTransferDentist,
    transferCancelRequest, setTransferCancelRequest, blockPanelOpen, blockRetarget,
    treatmentsCache, treatmentsLoading, rebookSource, rebookFallback, rebookCardRef,
    openQuickCreateForSlot, handleNewBooking, handleDragCreate, handleEmptySlotClick, handleConfirmTransferCancel,
    handleDeleteManualBlock, handleResizeManualBlock, handleQuickCreateClose, handleQuickCreateSubmit, handleRebookStart,
    runThroughPanelGuard, openOnlyPanel, handleBookingClick, refreshOpenBooking, handleModalClose,
  } = useCalendarPanels({ branchId, currentDate, calendarData, refreshCalendar, blocksAvailable, showToast, gridRef });

  const {
    handleStatusUpdate, handleAssignDentist, handleBookingResize, handleEditBooking, handleApplyDiscount, handleRecordPayment,
  } = useBookingActions({ showToast, refreshCalendar, selectedBooking, setSelectedBooking, getSelectedBookingsRef, staffLabel });

  // Auto-refresh every 60s. Paused while any modal/panel/drag/confirm is active
  // (the tab-hidden skip lives in the hook). fetchData swaps calendarData in place,
  // so scroll position, popovers and the hover label are untouched.
  const autoRefreshPaused = modalOpen || blockPanelOpen || !!activeDragId || isRescheduling || !!quickCreateSlot
    || !!pendingReassign || !!rebookSource || !!choiceMenuSlot || !!addBlockSlot || !!editingBlock || !!blockDeleteRequest
    || !!transferModalTarget || !!editingTransferDentist || !!transferCancelRequest;
  useAutoRefresh(refreshCalendar, { intervalMs: 60000, enabled: !!branchId && !autoRefreshPaused });

  // ── Navigation ─────────────────────────────────────────────

  const overlapOccurrences = useMemo(() => [...(calendarData?.blockOccurrences || []), ...(calendarData?.transferOccurrences || [])], [calendarData]);
  const goToday = () => setCurrentDate(todayStr());
  const goPrev = () => setCurrentDate(addDays(currentDate, -getStepDays(viewMode)));
  const goNext = () => setCurrentDate(addDays(currentDate, getStepDays(viewMode)));

  // Deep link `?view=calendar&booking=<id>` (patient chart / panel / Spotlight): jump to the booking's day and open its panel.
  // The param is stripped first so a reload or Back doesn't reopen it.
  const [searchParams, setSearchParams] = useSearchParams();
  const deepLinkBookingId = searchParams.get('booking');
  useEffect(() => {
    if (!deepLinkBookingId || !branchId) return;
    const next = new URLSearchParams(searchParams);
    next.delete('booking');
    setSearchParams(next, { replace: true });
    fetchBookingById(deepLinkBookingId).then(({ data, error: err }) => {
      if (err || !data || (data.branch_id && data.branch_id !== branchId)) {
        showToast(err || !data ? 'That booking could not be found.' : 'That booking is at a different branch.', 'error');
        return;
      }
      setCurrentDate(data.date);
      handleBookingClick(transformBooking(data));
    });
  }, [deepLinkBookingId, branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  useGoTodaySignal(goToday);
  useCalendarShortcuts({ goToday, goPrev, goNext, setViewMode, handleNewBooking, setTipOpen });

  // ── Dentist/chair column reorder ────────────────────────────
  // Gates both onDentistReorder and onChairReorder below. Branch-scoped:
  // staff can rearrange columns for their own branch only.
  const canReorderDentists = ['staff', 'manager', 'admin'].includes(profile?.role);

  // ── Derived data ───────────────────────────────────────────

  const dentistsForModal = useMemo(() =>
    calendarData
      ? calendarData.dentists
          .filter(t => t.is_treatment_staff !== false && !attendanceMap[t.id])
          .map(t => ({
            id: t.id,
            name: t.name,
            gender: t.gender,
            specialties: t.specialties || [],
          }))
      : [],
    [calendarData, attendanceMap]
  );

  // ── Error state ────────────────────────────────────────────

  if (error && !calendarData) {
    return (
      <div className="bg-surface rounded-spa-lg border border-border p-8">
        <div className="text-center py-8">
          <Icon name="AlertCircle" size={48} className="text-error mx-auto mb-4" />
          <h3 className="font-heading font-heading-semibold text-lg text-text-primary mb-2">
            Failed to Load Calendar
          </h3>
          <p className="font-body font-body-normal text-text-secondary mb-4">{error}</p>
          <button
            onClick={() => fetchData(currentDate, currentDate)}
            className="inline-flex items-center space-x-2 px-4 py-2 bg-primary text-white rounded-spa font-body font-body-medium text-sm hover:bg-primary/90 spa-transition-fast"
          >
            <Icon name="RefreshCw" size={16} />
            <span>Retry</span>
          </button>
        </div>
      </div>
    );
  }

  return (
    <>
      <DndContext
        sensors={sensors}
        collisionDetection={pointerWithin}
        onDragStart={handleDragStart}
        onDragMove={handleDragMove}
        onDragOver={handleDragOver}
        onDragEnd={handleDragEnd}
        onDragCancel={handleDragCancel}
      >
        <div className="bg-surface overflow-clip flex flex-col h-full pb-2">
          <CalendarToolbar
            staffLabel={staffLabel}
            staffLabelPlural={staffLabelPlural}
            locationLabel={locationLabel}
            enableChairs={enableChairs}
            columnMode={columnMode}
            setColumnMode={setColumnMode}
            awayList={awayList}
            currentDate={currentDate}
            setCurrentDate={setCurrentDate}
            viewMode={viewMode}
            setViewMode={setViewMode}
            goToday={goToday}
            goPrev={goPrev}
            goNext={goNext}
            tipOpen={tipOpen}
            setTipOpen={setTipOpen}
            showTreatmentOnly={showTreatmentOnly}
            setShowTreatmentOnly={setShowTreatmentOnly}
            selectedPositions={selectedPositions}
            setSelectedPositions={setSelectedPositions}
            calendarPositionOptions={calendarPositionOptions}
            onNewBooking={handleNewBooking}
            branchId={branchId}
          />

          {/* Main content area: Grid */}
          <div className="flex flex-1 min-h-0 overflow-clip">
            {/* Calendar grid */}
            <div className="flex-1 min-w-0 overflow-x-auto md:overflow-clip">
              {calendarData ? (
                <CalendarGrid
                  dentists={filteredDentists}
                  chairs={calendarData.chairs || []}
                  bookings={calendarData.bookings}
                  branchHours={calendarData.branchHours}
                  attendanceMap={attendanceMap}
                  checkedOutByDentistAndDate={calendarData.checkedOutByDentistAndDate}
                  onBookingClick={handleBookingClick}
                  onBookingResize={handleBookingResize}
                  onMultiDrag={(getter) => { getSelectedBookingsRef.current = getter; }}
                  onEmptySlotClick={handleEmptySlotClick}
                  currentDate={currentDate}
                  viewMode={viewMode}
                  columnMode={columnMode}
                  activeDragId={activeDragId}
                  gridRef={gridRef}
                  freezeUnassigned={freezeUnassigned}
                  onToggleFreezeUnassigned={() => setFreezeUnassigned(prev => !prev)}
                  onDentistReorder={canReorderDentists ? handleDentistReorder : undefined}
                  onChairReorder={canReorderDentists ? handleChairReorder : undefined}
                  blockOccurrences={calendarData.blockOccurrences}
                  overlapOccurrences={overlapOccurrences}
                  onDragCreate={handleDragCreate}
                  onDeleteManualBlock={setBlockDeleteRequest}
                  onResizeManualBlock={handleResizeManualBlock}
                  draftGhost={(quickCreateSlot || blockPanelOpen) && !draftGhost?.hidden ? draftGhost : null}
                  selectedBookingId={modalOpen ? (selectedBooking?.bookingId || previewBooking?.bookingId || previewBooking?.id || null) : null}
                  onEditManualBlock={(range) => runThroughPanelGuard(() => openOnlyPanel(() => setEditingBlock({ blockId: range.blockId, day: range.day })))}
                  onEditTransfer={transfersAvailable ? (col) => runThroughPanelGuard(() => openOnlyPanel(() => setEditingTransferDentist({ id: col.id, name: col.name }))) : undefined}
                  onCancelScheduledTransfer={transfersAvailable ? (col) => setTransferCancelRequest({ kind: 'scheduled', col }) : undefined}
                  onCancelActiveTransfer={transfersAvailable ? (col) => setTransferCancelRequest({ kind: 'active', col }) : undefined}
                />
              ) : (
                <div className="flex items-center justify-center h-full">
                  <div className="text-center">
                    <div className="animate-spin w-8 h-8 border-2 border-primary border-t-transparent rounded-full mx-auto mb-3" />
                    <p className="font-body text-sm text-text-secondary">Loading calendar...</p>
                  </div>
                </div>
              )}
            </div>

            {/* Quick-create: docked at lg+ (shrinks the calendar), overlay below */}
            <QuickCreatePanel
              slotInfo={quickCreateSlot}
              treatments={treatmentsCache}
              treatmentsLoading={treatmentsLoading}
              dentists={(calendarData?.dentists || []).filter(t => t.is_treatment_staff !== false && !attendanceMap[t.id])}
              chairs={calendarData?.chairs || []}
              bookings={calendarData?.bookings || []}
              onClose={handleQuickCreateClose}
              onSubmit={handleQuickCreateSubmit}
              branchId={branchId}
              branchHours={calendarData?.branchHours}
              retarget={retargetRequest}
              onDraftChange={setDraftGhost}
              columnMode={columnMode}
              allDentists={calendarData?.dentists || []}
              guardRef={quickGuardRef}
            />
          </div>
        </div>

        <DragPreviewOverlay activeDragBlock={activeDragBlock} activeDragBooking={activeDragBooking} overSlotData={overSlotData} />
      </DndContext>

      {/* Rebook floating cursor card */}
      {rebookSource && (
        <div
          ref={rebookCardRef}
          role="status"
          aria-live="polite"
          aria-label={`Rebook mode active for ${rebookSource.customerName}. Click an empty calendar slot to place, or press Escape to cancel.`}
          className="fixed pointer-events-none z-notification"
          style={{ left: -9999, top: -9999, opacity: 0 }}
        >
          <div className="bg-white rounded-md border-2 border-primary shadow-lg px-3 py-2 min-w-[140px]">
            <div className="font-body font-semibold text-xs text-text-primary">
              {rebookSource.customerName}
            </div>
            <div className="font-body text-[11px] text-text-secondary">
              {rebookSource.treatmentName}
            </div>
            <div className="flex items-center justify-between mt-1">
              <span className="font-caption text-[10px] text-text-secondary">
                {rebookSource.duration}
              </span>
              <span className="font-caption text-[10px] text-primary font-medium">
                Click to place
              </span>
            </div>
          </div>
        </div>
      )}

      {/* Booking Action Modal */}
      <BookingActionModal
        variant="panel"
        isOpen={modalOpen}
        previewBooking={previewBooking}
        onRefreshBooking={refreshOpenBooking}
        guardRef={bookingGuardRef}
        onClose={handleModalClose}
        booking={selectedBooking}
        dentists={dentistsForModal}
        chairs={calendarData?.chairs || []}
        treatments={treatmentsCache || []}
        onUpdateStatus={handleStatusUpdate}
        onAssignDentist={handleAssignDentist}
        onRecordPayment={handleRecordPayment}
        onApplyDiscount={handleApplyDiscount}
        onEditBooking={handleEditBooking}
        onCreateBooking={handleQuickCreateSubmit}
        onRebookStart={handleRebookStart}
        branchHours={calendarData?.branchHours}
        defaultNewBookingMode={rebookFallback ? 'rebook' : null}
        userRole={profile?.role || 'staff'}
      />

      {/* Toast */}
      {actionToast && (
        <div className={`fixed top-20 left-1/2 transform -translate-x-1/2 z-toast px-5 py-3 rounded-spa-lg spa-shadow-elevated animate-fade-in flex items-center space-x-2 ${
          actionToast.type === 'error' ? 'bg-error text-white' :
          actionToast.type === 'info' ? 'bg-blue-500 text-white' :
          'bg-success text-white'
        }`}>
          <Icon name={actionToast.type === 'error' ? 'AlertCircle' : actionToast.type === 'info' ? 'Clock' : 'CheckCircle'} size={16} />
          <span className="font-body font-body-medium text-sm">{actionToast.msg}</span>
        </div>
      )}

      {/* Empty-slot choice menu — add further options (e.g. 3c "Transfer staff") to this array */}
      {choiceMenuSlot && (
        <EmptySlotChoiceMenu
          x={choiceMenuSlot.clientX}
          y={choiceMenuSlot.clientY}
          onClose={() => setChoiceMenuSlot(null)}
          options={[
            { key: 'booking', label: 'Add booking', icon: 'CalendarPlus', onSelect: () => openQuickCreateForSlot(choiceMenuSlot) },
            { key: 'block', label: 'Add block', icon: 'Ban', onSelect: () => openOnlyPanel(() => setAddBlockSlot(choiceMenuSlot)) },
            // Transfer is a dentist-column action for managers/admins only (the RPC enforces it too).
            ...(transfersAvailable && choiceMenuSlot.colType === 'dentist' && ['manager', 'admin'].includes(profile?.role) ? [{
              key: 'transfer',
              label: 'Transfer dentist',
              icon: 'ArrowRightLeft',
              onSelect: () => openOnlyPanel(() => setTransferModalTarget({
                dentistId: choiceMenuSlot.colId,
                dentistName: choiceMenuSlot.colName,
                defaultDate: choiceMenuSlot.day,
                defaultTime: `${String(choiceMenuSlot.hour).padStart(2, '0')}:${String(choiceMenuSlot.minute).padStart(2, '0')}`,
              })),
            }] : []),
          ]}
        />
      )}

      {transferModalTarget && (
        <TransferFromCalendarModal
          variant="panel"
          guardRef={blockGuardRef}
          onDraftChange={setDraftGhost}
          dentistId={transferModalTarget.dentistId}
          dentistName={transferModalTarget.dentistName}
          currentBranchId={branchId}
          defaultDate={transferModalTarget.defaultDate}
          defaultTime={transferModalTarget.defaultTime}
          onClose={() => setTransferModalTarget(null)}
          onSuccess={({ applied, startDate, startTime } = {}) => {
            const name = transferModalTarget.dentistName;
            setTransferModalTarget(null);
            showToast(applied === false
              ? `${name}'s transfer is scheduled for ${startTime ? `${startDate} at ${startTime}` : startDate} — it hasn't happened yet.`
              : `${name} transferred.`);
            refreshCalendar();
          }}
        />
      )}

      {editingTransferDentist && (
        <TransferManagementModal
          variant="panel"
          guardRef={blockGuardRef}
          onDraftChange={setDraftGhost}
          dentistId={editingTransferDentist.id}
          dentistName={editingTransferDentist.name}
          currentBranchId={branchId}
          defaultStartDate={currentDate}
          onClose={() => setEditingTransferDentist(null)}
          onSuccess={(message) => {
            setEditingTransferDentist(null);
            if (message) showToast(message);
            refreshCalendar();
          }}
        />
      )}

      {transferCancelRequest && (
        <BlockScopeDialog
          title={transferCancelRequest.kind === 'scheduled'
            ? `Cancel ${transferCancelRequest.col.name}'s scheduled transfer?`
            : `Cancel ${transferCancelRequest.col.name}'s transfer and bring them back now?`}
          recurring={false}
          confirmLabel={transferCancelRequest.kind === 'scheduled' ? 'Cancel transfer' : 'Bring back now'}
          onCancel={() => setTransferCancelRequest(null)}
          onChoose={handleConfirmTransferCancel}
        />
      )}

      {addBlockSlot && (
        <AddBlockModal
          variant="panel"
          guardRef={blockGuardRef}
          onDraftChange={setDraftGhost}
          retarget={blockRetarget}
          bookings={calendarData?.bookings || []}
          branchHours={calendarData?.branchHours}
          branchId={branchId}
          slotInfo={addBlockSlot}
          dentists={calendarData?.dentists || []}
          chairs={calendarData?.chairs || []}
          onClose={() => setAddBlockSlot(null)}
          onSuccess={() => {
            const hiddenInThisView = columnMode === 'dentist' && lastBlockWasChairOnly.current;
            setAddBlockSlot(null);
            showToast(hiddenInThisView ? 'Block added. Switch to Chair view to see it.' : 'Block added.');
            refreshCalendar();
          }}
          onChairOnlyChange={(v) => { lastBlockWasChairOnly.current = v; }}
        />
      )}

      {editingBlock && (
        <EditBlockModal
          variant="panel"
          guardRef={blockGuardRef}
          onDraftChange={setDraftGhost}
          retarget={blockRetarget}
          bookings={calendarData?.bookings || []}
          branchHours={calendarData?.branchHours}
          blockId={editingBlock.blockId}
          occurrenceDate={editingBlock.day}
          dentists={calendarData?.dentists || []}
          chairs={calendarData?.chairs || []}
          onClose={() => setEditingBlock(null)}
          onSuccess={() => {
            setEditingBlock(null);
            showToast('Block updated.');
            refreshCalendar();
          }}
        />
      )}

      {blockDeleteRequest && (
        <BlockScopeDialog
          title="Remove block"
          verb="removed"
          recurring={!!blockDeleteRequest.seriesId}
          onCancel={() => setBlockDeleteRequest(null)}
          onChoose={(scope) => {
            const req = blockDeleteRequest;
            setBlockDeleteRequest(null);
            handleDeleteManualBlock({ blockId: req.blockId, day: req.day, scope });
          }}
        />
      )}

      {pendingReassign && (
        <ReassignConfirmDialog
          pendingReassign={pendingReassign}
          calendarData={calendarData}
          staffLabel={staffLabel}
          locationLabel={locationLabel}
          onCancel={() => setPendingReassign(null)}
          onConfirm={handleConfirmReassign}
        />
      )}
    </>
  );
};

export default OperationalCalendar;
