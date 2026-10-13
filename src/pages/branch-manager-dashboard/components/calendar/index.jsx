import React, { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { useSearchParams } from 'react-router-dom';
import { DndContext, DragOverlay, PointerSensor, useSensor, useSensors, pointerWithin } from '@dnd-kit/core';
import Icon from '../../../../components/AppIcon';
import BookingActionModal from '../../../../components/ui/BookingActionModal';
import MiniMonthCalendar from './MiniMonthCalendar';
import EmptySlotChoiceMenu from './EmptySlotChoiceMenu';
import AddBlockModal from './AddBlockModal';
import EditBlockModal from './EditBlockModal';
import BlockScopeDialog from './BlockScopeDialog';
import TransferFromCalendarModal from './TransferFromCalendarModal';
import TransferManagementModal from '../../../../components/ui/TransferManagementModal';
import { findBlockOverlap, describeBlockOverlap } from '../../../../utils/blockOverlap';
import CalendarGrid, { HOUR_HEIGHT } from './CalendarGrid';
import QuickCreatePanel from './QuickCreatePanel';
import { todayStr, addDays, addMonths, toKathmanduParts } from './calendarDates';
import { useAutoRefresh } from '../../../../hooks/useAutoRefresh';
import {
  getCalendarBookings,
  fetchBlocksForRange,
  fetchTransferOccurrences,
  isTransferFeatureMissing,
  cancelScheduledTransfer,
  revertStaffTransferNow,
  deleteBlock,
  updateBlock,
  fetchBookingById,
  updateBookingStatus,
  assignDentist,
  recordPayment,
  fetchAttendance,
  LEAVE_LIKE_ATTENDANCE_STATUSES,
  rescheduleBooking,
  fetchTreatments,
  createBooking,
  updateBookingDetails,
  updateDentistOrder,
  updateChairOrder,
  updateDentistTime,
  resizeSharedBookingTime,
  applyDiscount,
} from '../../../../services/api';
import { transformBooking, toDbStatus } from '../../../../services/bookingTransformers';
import { isAfterCheckout } from '../../../../services/dentistBranchWindow';
import { useAuth } from '../../../../contexts/AuthContext';

// ── Helpers ──────────────────────────────────────────────────

function formatDateTitle(dateStr, viewMode) {
  const d = new Date(dateStr + 'T00:00:00');
  if (viewMode === '4day') {
    const end = new Date(d);
    end.setDate(end.getDate() + 3);
    const startStr = d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
    const endStr = end.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
    return `${startStr} – ${endStr}`;
  }
  return d.toLocaleDateString('en-GB', {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }).replace(',', '');
}

function getDateRange(dateStr, viewMode) {
  if (viewMode === '4day') {
    return { start: dateStr, end: addDays(dateStr, 3) };
  }
  return { start: dateStr, end: dateStr };
}

const JUMP_OPTIONS = [
  { label: '1 week', unit: 'week', amount: 1 },
  { label: '2 weeks', unit: 'week', amount: 2 },
  { label: '3 weeks', unit: 'week', amount: 3 },
  { label: '4 weeks', unit: 'week', amount: 4 },
  { label: '5 weeks', unit: 'week', amount: 5 },
  { label: '6 weeks', unit: 'week', amount: 6 },
  { label: '7 weeks', unit: 'week', amount: 7 },
  { label: '8 weeks', unit: 'week', amount: 8 },
  { label: '6 months', unit: 'month', amount: 6 },
  { label: '1 year', unit: 'year', amount: 1 },
];

function getStepDays(viewMode) {
  return viewMode === '4day' ? 4 : 1;
}

function formatTimeFromSlot(hour, minute) {
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

function calculateEndTime(startHour, startMinute, durationMinutes) {
  const totalMinutes = startHour * 60 + startMinute + (durationMinutes || 60);
  const endHour = Math.floor(totalMinutes / 60);
  const endMinute = totalMinutes % 60;
  return `${String(endHour).padStart(2, '0')}:${String(endMinute).padStart(2, '0')}`;
}

function formatTimeDisplay(time) {
  if (!time) return '';
  // Convert HH:MM to display format
  const [h, m] = time.split(':').map(Number);
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
}

// Whether a (day, hour, minute) slot for a dentist falls at/after their recorded
// check-out for that specific day. `checkedOutByDentistAndDate` is the
// "<dentistId>_<date>" -> raw check_out_time map from getCalendarBookings.
function isCheckedOutBlockedSlot(checkedOutByDentistAndDate, dentistId, day, hour, minute) {
  const checkOutTime = checkedOutByDentistAndDate?.[`${dentistId}_${day}`];
  if (!checkOutTime) return false;
  const slotTime = `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
  return isAfterCheckout(checkOutTime, day, slotTime);
}

// Default interval (minutes) used to pre-check an empty-slot click before a treatment is chosen.
const DEFAULT_SLOT_MINUTES = 30;

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
  const [positionDropdownOpen, setPositionDropdownOpen] = useState(false);
  const positionDropdownRef = useRef(null);
  const [dateDropdownOpen, setDateDropdownOpen] = useState(false);
  const dateDropdownRef = useRef(null);
  const [tipOpen, setTipOpen] = useState(false);
  const tipRef = useRef(null);
  const [awayOpen, setAwayOpen] = useState(false);
  const awayRef = useRef(null);
  const [jumpMenuOpen, setJumpMenuOpen] = useState(null); // 'prev' | 'next' | null
  const prevJumpRef = useRef(null);
  const nextJumpRef = useRef(null);
  const [searchParams, setSearchParams] = useSearchParams();

  // Calendar data state
  const [calendarData, setCalendarData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  // Attendance indicators
  const [attendanceMap, setAttendanceMap] = useState({});

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

  // Close toolbar popovers on outside click / Esc
  useEffect(() => {
    if (!dateDropdownOpen && !tipOpen && !awayOpen && !jumpMenuOpen) return;
    const onDown = (e) => {
      const inside = (r) => r.current && r.current.contains(e.target);
      if (dateDropdownOpen && !inside(dateDropdownRef)) setDateDropdownOpen(false);
      if (tipOpen && !inside(tipRef)) setTipOpen(false);
      if (awayOpen && !inside(awayRef)) setAwayOpen(false);
      if (jumpMenuOpen && !inside(jumpMenuOpen === 'prev' ? prevJumpRef : nextJumpRef)) setJumpMenuOpen(null);
    };
    const onKey = (e) => {
      if (e.key !== 'Escape') return;
      e.preventDefault(); // claimed: the panel / rebook handlers must not also act on this Esc
      setDateDropdownOpen(false);
      setTipOpen(false);
      setAwayOpen(false);
      setJumpMenuOpen(null);
    };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDown);
      document.removeEventListener('keydown', onKey);
    };
  }, [dateDropdownOpen, tipOpen, awayOpen, jumpMenuOpen]);

  // Close position dropdown on outside click
  useEffect(() => {
    if (!positionDropdownOpen) return;
    const handle = (e) => {
      if (positionDropdownRef.current && !positionDropdownRef.current.contains(e.target)) setPositionDropdownOpen(false);
    };
    const onKey = (e) => { if (e.key === 'Escape') { e.preventDefault(); setPositionDropdownOpen(false); } };
    document.addEventListener('mousedown', handle);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', handle);
      document.removeEventListener('keydown', onKey);
    };
  }, [positionDropdownOpen]);

  // Absent / on-leave dentists (hidden from columns) for the toolbar "N away" summary
  const awayList = useMemo(() => {
    if (!calendarData?.dentists) return [];
    return Object.entries(attendanceMap)
      .map(([id, status]) => ({ id, status, name: calendarData.dentists.find(t => t.id === id)?.name }))
      .filter(a => a.name);
  }, [attendanceMap, calendarData?.dentists]);

  // Modal state
  const [selectedBooking, setSelectedBooking] = useState(null);
  const [modalOpen, setModalOpen] = useState(false);
  const [modalLoading, setModalLoading] = useState(false);
  const [previewBooking, setPreviewBooking] = useState(null); // calendar card data shown instantly while the full booking loads
  // Guards: each open panel registers a function here; callers run "switch panel / open another booking" through it so
  // unsaved edits are never lost silently. Only one panel (booking details OR quick-create) is open at a time.
  const quickGuardRef = useRef(null);
  const bookingGuardRef = useRef(null);
  const modalOpenRef = useRef(false);
  const previewBookingRef = useRef(null);
  const quickCreateSlotRef = useRef(null);
  const [actionToast, setActionToast] = useState(null);

  // Drag state
  const [activeDragId, setActiveDragId] = useState(null);
  const [activeDragBooking, setActiveDragBooking] = useState(null);
  const [overSlotData, setOverSlotData] = useState(null); // { hour, minute, day }
  const [isRescheduling, setIsRescheduling] = useState(false);
  const [dragGrabOffset, setDragGrabOffset] = useState(0); // Y offset from card top where user grabbed

  // Multi-drag: ref to get selected bookings from CalendarGrid
  const getSelectedBookingsRef = useRef(() => []);

  // Cross-column reassignment confirmation
  const [pendingReassign, setPendingReassign] = useState(null);

  // Quick-create panel state
  const [quickCreateSlot, setQuickCreateSlot] = useState(null);
  modalOpenRef.current = modalOpen;
  previewBookingRef.current = previewBooking;
  quickCreateSlotRef.current = quickCreateSlot;
  const [retargetRequest, setRetargetRequest] = useState(null); // { slot, nonce }: click-to-retarget while the panel is open
  const [draftGhost, setDraftGhost] = useState(null);           // live draft reported by the panel, drawn on the grid

  // Manual blocks + empty-slot choice menu
  const [choiceMenuSlot, setChoiceMenuSlot] = useState(null);
  const [addBlockSlot, setAddBlockSlot] = useState(null);
  const [editingBlock, setEditingBlock] = useState(null); // { blockId, day }
  const [blockDeleteRequest, setBlockDeleteRequest] = useState(null); // { blockId, day, seriesId, description }
  const [activeDragBlock, setActiveDragBlock] = useState(null);
  // False when the DB has no manual_blocks table yet (migration-001 not applied): hides "Add block".
  const [blocksAvailable, setBlocksAvailable] = useState(true);
  const lastBlockWasChairOnly = useRef(false);
  // Staff transfers. False when the DB has no transfer tables/RPCs yet (migrations 003–005 not applied).
  const [transfersAvailable, setTransfersAvailable] = useState(true);
  const [transferModalTarget, setTransferModalTarget] = useState(null);   // create (from empty-slot menu)
  const [editingTransferDentist, setEditingTransferDentist] = useState(null); // manage (header badge / shading)
  const [transferCancelRequest, setTransferCancelRequest] = useState(null);   // { kind: 'scheduled'|'active', col }
  // Block / transfer forms live in the docked SidePanel (one panel at a time, like quick-create and booking details).
  const blockPanelOpen = !!(addBlockSlot || editingBlock || transferModalTarget || editingTransferDentist);
  const blockPanelOpenRef = useRef(false);
  blockPanelOpenRef.current = blockPanelOpen;
  const blockGuardRef = useRef(null);
  const [blockRetarget, setBlockRetarget] = useState(null); // { slot, nonce } — empty-slot click while a block form is open
  const closeBlockPanels = useCallback(() => {
    setAddBlockSlot(null); setEditingBlock(null); setTransferModalTarget(null); setEditingTransferDentist(null); setBlockRetarget(null);
  }, []);
  const [treatmentsCache, setTreatmentsCache] = useState(null);
  const [treatmentsLoading, setTreatmentsLoading] = useState(false);

  // Rebook "pick and place" mode
  // Shape: { booking, customerName, customerPhone, treatmentId, treatmentName, duration }
  const [rebookSource, setRebookSource] = useState(null);
  const [rebookFallback, setRebookFallback] = useState(false);

  // Ref to the grid body for calculating time from cursor position
  const gridRef = useRef(null);

  // Rebook floating card — mouse tracking
  const rebookCardRef = useRef(null);
  const rebookOverGrid = useRef(false);

  useEffect(() => {
    if (!rebookSource) return;

    const handleMouseMove = (e) => {
      const card = rebookCardRef.current;
      if (!card) return;

      // Check if cursor is over the calendar grid
      const grid = gridRef.current;
      if (grid) {
        const rect = grid.getBoundingClientRect();
        const isOver = e.clientX >= rect.left && e.clientX <= rect.right &&
                       e.clientY >= rect.top && e.clientY <= rect.bottom;
        rebookOverGrid.current = isOver;
        card.style.opacity = isOver ? '0.95' : '0.5';
      }

      card.style.left = `${e.clientX + 12}px`;
      card.style.top = `${e.clientY - 20}px`;
    };

    const handleKeyDown = (e) => {
      if (e.key === 'Escape' && rebookSource && !e.defaultPrevented) {
        // Reopen modal with rebook inline form
        setSelectedBooking(rebookSource.booking);
        setModalOpen(true);
        setRebookFallback(true);
        setRebookSource(null);
      }
    };

    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('keydown', handleKeyDown);
    return () => {
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('keydown', handleKeyDown);
    };
  }, [rebookSource]);

  // Configure drag sensors with activation constraints
  const sensors = useSensors(
    useSensor(PointerSensor, {
      activationConstraint: {
        // Require 5px movement or 150ms delay before drag starts
        // This prevents accidental drags and allows clicks to work
        distance: 5,
      },
    })
  );

  // ── Data fetching ──────────────────────────────────────────

  const fetchData = useCallback(async (startDate, endDate) => {
    if (!branchId || !startDate || !endDate) return;

    setLoading(true);
    setError(null);

    const [result, attResult, blocksResult, transferResult] = await Promise.all([
      getCalendarBookings(branchId, startDate, endDate),
      fetchAttendance({ branchId, date: startDate }),
      fetchBlocksForRange(branchId, startDate, endDate),
      fetchTransferOccurrences(branchId, startDate, endDate),
    ]);

    if (result.error) {
      setError(result.error.message || 'Failed to load calendar data.');
      setLoading(false);
      return;
    }

    // Blocks are best-effort: a failure (e.g. DB without migration-001) must not break the calendar.
    const blocksTableMissing = ['PGRST205', '42P01'].includes(blocksResult.error?.code);
    setBlocksAvailable(!blocksTableMissing);
    setTransfersAvailable(!isTransferFeatureMissing(transferResult.error));
    setCalendarData({ ...result.data, blockOccurrences: blocksResult.data || [], transferOccurrences: transferResult.data || [] });

    const attMap = {};
    if (attResult.data) {
      for (const a of attResult.data) {
        if (a.status === 'Absent' || LEAVE_LIKE_ATTENDANCE_STATUSES.includes(a.status)) {
          attMap[a.dentistId] = a.status === 'Absent' ? 'Absent' : 'Leave';
        }
      }
    }
    setAttendanceMap(attMap);
    setLoading(false);
  }, [branchId]);

  // Reload when date or view changes
  useEffect(() => {
    if (!branchId) return;
    const { start, end } = getDateRange(currentDate, viewMode);
    fetchData(start, end);
  }, [branchId, currentDate, viewMode, fetchData]);

  const refreshCalendar = useCallback(() => {
    const { start, end } = getDateRange(currentDate, viewMode);
    fetchData(start, end);
  }, [currentDate, viewMode, fetchData]);

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
  const applyJump = (sign, unit, amount) => {
    setCurrentDate(
      unit === 'week'
        ? addDays(currentDate, sign * amount * 7)
        : addMonths(currentDate, sign * amount * (unit === 'year' ? 12 : 1))
    );
  };

  // ── Keyboard shortcuts (calendar view only; ignored while typing or when a modal dialog is open) ──
  // The handler is re-pointed every render so the single document listener always sees current state.
  const shortcutRef = useRef(null);
  shortcutRef.current = (e) => {
    if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey) return;
    const t = e.target;
    const tag = t?.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || t?.isContentEditable) return;
    // A modal dialog (add block, transfers, payment…) owns the keyboard; the docked side panel is aria-modal="false".
    if (document.querySelector('[aria-modal="true"]')) return;
    const k = e.key;
    const kl = k.length === 1 ? k.toLowerCase() : k;
    const act = (fn) => { e.preventDefault(); fn(); };
    switch (kl) {
      case 't': return act(goToday);
      case 'j': case 'ArrowLeft': return act(goPrev);
      case 'k': case 'ArrowRight': return act(goNext);
      case 'd': return act(() => setViewMode('day'));
      case 'f': return act(() => setViewMode('4day'));
      case 'n': return act(handleNewBooking);
      case '?': return act(() => setTipOpen((o) => !o));
      default:
    }
  };
  useEffect(() => {
    const onKey = (e) => shortcutRef.current?.(e);
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);

  // Ref to track current pointer Y position during drag (synchronous updates)
  const pointerYRef = useRef(null);

  // Track pointer position during drag
  useEffect(() => {
    if (!activeDragId) {
      pointerYRef.current = null;
      return;
    }

    const handlePointerMove = (e) => {
      pointerYRef.current = e.clientY;
    };

    document.addEventListener('pointermove', handlePointerMove);
    return () => document.removeEventListener('pointermove', handlePointerMove);
  }, [activeDragId]);

  // Calculate time slot from pointer Y position
  const calculateTimeFromPointer = useCallback((overData) => {
    if (!overData || !gridRef.current || pointerYRef.current === null) {
      return null;
    }

    const { day, colId, openHour } = overData;
    const gridRect = gridRef.current.getBoundingClientRect();

    // Get cursor position relative to the grid body element
    // Subtract dragGrabOffset so the card's TOP edge aligns with the time slot
    // (not the cursor position which could be anywhere on the card)
    const relativeY = pointerYRef.current - gridRect.top - dragGrabOffset;

    // Calculate hour and minute from Y position — read the live (possibly
    // pinch-zoomed) effective hour height off the grid DOM rather than the
    // static constant, so drag-drop stays accurate at any zoom level.
    const effectiveHourHeight = parseFloat(gridRef.current.dataset.hourHeight) || HOUR_HEIGHT;
    const minutesFromTop = (relativeY / effectiveHourHeight) * 60;
    const hour = Math.floor(minutesFromTop / 60) + openHour;
    const rawMinute = minutesFromTop % 60;
    const minute = Math.floor(rawMinute / 10) * 10; // Snap to 10-minute intervals (matches click + hover label)

    // Clamp to valid hours
    if (hour < openHour || minute < 0) {
      return { day, colId, hour: openHour, minute: 0 };
    }

    return { day, colId, hour, minute };
  }, [dragGrabOffset]);

  // ── Drag and Drop Handlers ────────────────────────────────

  const handleDragStart = useCallback((event) => {
    const { active, activatorEvent } = event;
    setActiveDragId(active.id);

    if (active.data.current?.type === 'manual-block') {
      setActiveDragBlock(active.data.current.block);
      // Align the block's TOP edge with the slot (not wherever on the block the cursor grabbed it).
      // Same method as bookings below: expected top from the start time (the drop math has no TOP_PAD).
      const blk = active.data.current.block;
      if (blk?.fromTime && gridRef.current) {
        const gridRect = gridRef.current.getBoundingClientRect();
        const openHour = parseInt(gridRef.current.dataset?.openHour || '9', 10);
        const hourHeight = parseFloat(gridRef.current.dataset?.hourHeight || '72');
        const [bh, bm] = blk.fromTime.split(':').map(Number);
        const expectedTop = gridRect.top + (((bh - openHour) * 60 + bm) / 60) * hourHeight;
        setDragGrabOffset((activatorEvent?.clientY ?? expectedTop) - expectedTop);
      } else {
        setDragGrabOffset(0);
      }
      return;
    }

    const booking = active.data.current?.booking;
    if (booking) {
      setActiveDragBooking(booking);
    }

    // Calculate how far down the card the user grabbed
    // This offset is used to align the card's TOP edge with the time slot
    const cursorY = activatorEvent?.clientY ?? 0;

    // Calculate expected card top position based on booking's start time
    // This is more reliable than trying to get the DOM element's position
    if (booking?.startTime && gridRef.current) {
      const gridRect = gridRef.current.getBoundingClientRect();
      const openHour = parseInt(gridRef.current.dataset?.openHour || '9', 10);
      const hourHeight = parseInt(gridRef.current.dataset?.hourHeight || '120', 10);

      const [bookingHour, bookingMinute] = booking.startTime.split(':').map(Number);
      const minutesFromOpen = (bookingHour - openHour) * 60 + bookingMinute;
      const expectedCardTop = gridRect.top + (minutesFromOpen / 60) * hourHeight;

      const grabOffset = cursorY - expectedCardTop;
      setDragGrabOffset(grabOffset);
    } else {
      setDragGrabOffset(0);
    }
  }, []);

  // Called on every mouse move during drag - calculates time from position
  const handleDragMove = useCallback((event) => {
    const { over } = event;
    if (!over?.data?.current) {
      setOverSlotData(null);
      return;
    }

    const timeData = calculateTimeFromPointer(over.data.current);
    if (timeData) {
      setOverSlotData(timeData);
    }
  }, [calculateTimeFromPointer]);

  // Called when hovering over a new droppable (less frequent than dragMove)
  const handleDragOver = useCallback((event) => {
    const { over } = event;
    if (!over?.data?.current) {
      setOverSlotData(null);
      return;
    }

    const timeData = calculateTimeFromPointer(over.data.current);
    if (timeData) {
      setOverSlotData(timeData);
    }
  }, [calculateTimeFromPointer]);

  // Build column name lookup maps for confirmation dialog
  const colNameMap = useMemo(() => {
    const map = { unassigned: 'Unassigned' };
    if (calendarData?.dentists) {
      for (const t of calendarData.dentists) map[t.id] = t.name;
    }
    if (calendarData?.chairs) {
      for (const r of calendarData.chairs) map[r.id] = r.name;
    }
    return map;
  }, [calendarData]);

  // Drag a block to a new day/time/column. Scoped to this occurrence (a recurring block's dragged
  // occurrence spins off its own one-off row). Declared above handleDragEnd because that callback's
  // dependency array references it eagerly.
  const handleMoveManualBlock = useCallback(async (block, newDate, newStartTime, targetColId) => {
    const patch = { blockId: block.blockId, scope: 'this', occurrenceDate: block.day, blockDate: newDate, startTime: newStartTime };
    // A whole-branch block renders one copy per column — moving whichever copy was grabbed must only
    // change day/time, never narrow it to that one column.
    if (!block.isWholeBranch) {
      if (columnMode === 'dentist') {
        patch.dentistId = targetColId === 'unassigned' ? null : targetColId;
      } else if (columnMode === 'chair') {
        patch.chairId = targetColId === 'unassigned' ? null : targetColId;
      }
    }
    const result = await updateBlock(patch);
    if (result.error) {
      showToast(result.error.message || 'Failed to move block.', 'error');
      return;
    }
    refreshCalendar();
  }, [columnMode, refreshCalendar]);

  const handleDragEnd = useCallback((event) => {
    const { active, over } = event;

    if (active.data.current?.type === 'manual-block') {
      const finalTimeData = over?.data?.current
        ? calculateTimeFromPointer(over.data.current)
        : overSlotData;
      const block = active.data.current.block;
      setActiveDragId(null);
      setActiveDragBlock(null);
      setOverSlotData(null);
      setDragGrabOffset(0);

      if (!finalTimeData || finalTimeData.hour === undefined) return;
      const { day: newDate, colId: targetColId, hour, minute } = finalTimeData;
      const newStartTime = formatTimeFromSlot(hour, minute);
      const effectiveTargetColId = targetColId || 'unassigned';
      const sourceColId = block.colId || 'unassigned';
      if (newDate === block.day && newStartTime === block.fromTime.slice(0, 5) && effectiveTargetColId === sourceColId) {
        return; // no change
      }
      handleMoveManualBlock(block, newDate, newStartTime, targetColId);
      return;
    }

    // Capture final position before clearing state
    // Fallback to last overSlotData if over is null (same-column drag may not trigger new over)
    const finalTimeData = over?.data?.current
      ? calculateTimeFromPointer(over.data.current)
      : overSlotData;

    // If not dropped on a valid target, just clear state
    if (!active.data.current?.booking || !finalTimeData) {
      setActiveDragId(null);
      setActiveDragBooking(null);
      setOverSlotData(null);
      setDragGrabOffset(0);
      return;
    }

    const booking = active.data.current.booking;
    const { day: newDate, colId: targetColId, hour, minute } = finalTimeData;

    if (hour === undefined || minute === undefined) {
      setActiveDragId(null);
      setActiveDragBooking(null);
      setOverSlotData(null);
      setDragGrabOffset(0);
      return;
    }

    const newStartTime = formatTimeFromSlot(hour, minute);
    const bookingId = booking.bookingId || booking.id;

    // Determine source column based on column mode
    // For shared bookings, use the column-specific dentist ID
    const sourceColId = columnMode === 'dentist'
      ? (booking._colDentistId || booking.dentistId || 'unassigned')
      : (booking.chairId || 'unassigned');
    const effectiveTargetColId = targetColId || 'unassigned';

    const isCrossColumn = sourceColId !== effectiveTargetColId;

    // Check if anything actually changed
    const oldTime = booking.startTime?.slice(0, 5);
    const oldDate = booking.date;
    if (oldTime === newStartTime && oldDate === newDate && !isCrossColumn) {
      setActiveDragId(null);
      setActiveDragBooking(null);
      setOverSlotData(null);
      setDragGrabOffset(0);
      return; // No change
    }

    // Calculate new end time
    const durationMinutes = booking.treatmentDuration ||
      (booking.startTime && booking.endTime
        ? (() => {
            const [sh, sm] = booking.startTime.split(':').map(Number);
            const [eh, em] = booking.endTime.split(':').map(Number);
            return (eh * 60 + em) - (sh * 60 + sm);
          })()
        : 60);
    const newEndTime = calculateEndTime(hour, minute, durationMinutes);

    // Clear drag state
    setActiveDragId(null);
    setActiveDragBooking(null);
    setOverSlotData(null);
    setDragGrabOffset(0);

    if (columnMode === 'dentist' && isCrossColumn) {
      if (isCheckedOutBlockedSlot(calendarData?.checkedOutByDentistAndDate, effectiveTargetColId, newDate, hour, minute)) {
        showToast('This dentist has already checked out for the day and is not bookable after their check-out time.', 'error');
        return;
      }
    }

    const manualBlockOnDrop = findBlockOverlap([...(calendarData?.blockOccurrences || []), ...(calendarData?.transferOccurrences || [])], {
      date: newDate,
      startTime: newStartTime,
      endTime: newEndTime,
      dentistId: columnMode === 'dentist' ? effectiveTargetColId : null,
      chairId: columnMode === 'chair' ? effectiveTargetColId : null,
    });
    if (manualBlockOnDrop) {
      showToast(describeBlockOverlap(manualBlockOnDrop), 'error');
      return;
    }

    if (isCrossColumn) {
      // Cross-column drop → show confirmation dialog
      setPendingReassign({
        booking,
        bookingId,
        newDate,
        newStartTime,
        newEndTime,
        durationMinutes,
        targetColId: effectiveTargetColId,
        sourceColId,
        targetColName: colNameMap[effectiveTargetColId] || effectiveTargetColId,
        sourceColName: colNameMap[sourceColId] || sourceColId,
        type: columnMode,
        timeChanged: oldTime !== newStartTime || oldDate !== newDate,
        isSharedReassign: booking.isShared && columnMode === 'dentist',
      });
    } else if (booking.isShared && booking._colDentistId) {
      // Shared booking, same column — default: move ALL dentists together (reschedule whole booking)
      // Cmd/Ctrl selected = move only selected ones independently
      const selectedBookings = getSelectedBookingsRef.current();
      const draggedKey = `${booking.id}__${booking._colDentistId}`;
      const isPartOfSelection = selectedBookings.length > 0 && selectedBookings.some(b => `${b.id}__${b._colDentistId}` === draggedKey);

      if (isPartOfSelection) {
        // Cmd/Ctrl selected: move only selected cards independently
        const [oldH, oldM] = (booking.startTime || '').split(':').map(Number);
        const [newH, newM] = newStartTime.split(':').map(Number);
        const deltaMins = (newH * 60 + newM) - (oldH * 60 + oldM);

        const updates = selectedBookings.map(b => {
          const [sh, sm] = (b.startTime || '').split(':').map(Number);
          const [eh, em] = (b.endTime || '').split(':').map(Number);
          const ns = sh * 60 + sm + deltaMins;
          const ne = eh * 60 + em + deltaMins;
          return updateDentistTime({
            bookingId: b.bookingId || b.id,
            dentistId: b._colDentistId,
            startTime: `${String(Math.floor(ns / 60)).padStart(2, '0')}:${String(ns % 60).padStart(2, '0')}`,
            endTime: `${String(Math.floor(ne / 60)).padStart(2, '0')}:${String(ne % 60).padStart(2, '0')}`,
          });
        });
        Promise.all(updates).then(results => {
          const failed = results.find(r => r.error);
          if (failed) showToast(failed.error.message || 'Failed to update.', 'error');
          else showToast(`Moved ${selectedBookings.length} selected`, 'success');
          refreshCalendar();
        });
      } else {
        // Default: show confirmation dialog to reschedule entire booking (moves all dentists)
        setPendingReassign({
          booking,
          bookingId,
          newDate,
          newStartTime,
          newEndTime,
          durationMinutes,
          targetColId: effectiveTargetColId,
          sourceColId,
          targetColName: colNameMap[effectiveTargetColId] || effectiveTargetColId,
          sourceColName: colNameMap[sourceColId] || sourceColId,
          type: columnMode,
          timeChanged: true,
          timeOnly: true,
          isSharedReschedule: true,
        });
      }
      return;
    } else {
      // Same column — time-only reschedule, show confirmation dialog
      setPendingReassign({
        booking,
        bookingId,
        newDate,
        newStartTime,
        newEndTime,
        durationMinutes,
        targetColId: effectiveTargetColId,
        sourceColId,
        targetColName: colNameMap[effectiveTargetColId] || effectiveTargetColId,
        sourceColName: colNameMap[sourceColId] || sourceColId,
        type: columnMode,
        timeChanged: true,
        timeOnly: true,
      });
    }
  }, [refreshCalendar, calculateTimeFromPointer, columnMode, colNameMap, calendarData, handleMoveManualBlock, overSlotData]);

  // Execute reschedule with optimistic update (time-only, no column change)
  const executeReschedule = useCallback(async ({ bookingId, newDate, newStartTime, newEndTime, durationMinutes }) => {
    // Optimistic UI update
    setCalendarData(prev => {
      if (!prev) return prev;
      return {
        ...prev,
        bookings: prev.bookings.map(b => {
          if (b.id === bookingId) {
            return { ...b, date: newDate, start_time: newStartTime, end_time: newEndTime };
          }
          return b;
        }),
      };
    });

    setIsRescheduling(true);
    try {
      const result = await rescheduleBooking({ bookingId, newDate, newStartTime });
      if (result.error) {
        showToast(result.error.message || 'Failed to reschedule booking.', 'error');
        refreshCalendar();
      } else {
        showToast(`Rescheduled to ${newStartTime}`, 'success');
      }
    } catch (err) {
      showToast('An error occurred while rescheduling.', 'error');
      refreshCalendar();
    } finally {
      setIsRescheduling(false);
    }
  }, [refreshCalendar]);

  // Handle cross-column reassignment confirmation
  const handleConfirmReassign = useCallback(async () => {
    if (!pendingReassign) return;

    const { bookingId, newDate, newStartTime, newEndTime, targetColId, sourceColId, type, targetColName, timeOnly, isSharedReassign, isSharedReschedule } = pendingReassign;

    setPendingReassign(null);
    setIsRescheduling(true);

    try {
      if (isSharedReschedule) {
        // Shared booking time-only reschedule: moves all dentists together
        const result = await rescheduleBooking({ bookingId, newDate, newStartTime });
        if (result.error) {
          showToast(result.error.message || 'Failed to reschedule.', 'error');
        } else {
          showToast(`Rescheduled to ${newStartTime}`, 'success');
        }
        refreshCalendar();
      } else if (isSharedReassign) {
        // Shared booking: swap dentist in junction table
        // Get current dentist IDs from the booking_dentists
        const currentBooking = calendarData?.bookings?.find(b => b.id === bookingId);
        const currentDentistIds = currentBooking?.booking_dentists?.map(bt => bt.dentist_id) || [];

        if (currentDentistIds.includes(targetColId) && targetColId !== sourceColId) {
          // Dragged to a dentist who already has this booking → consolidate (remove source)
          const newIds = currentDentistIds.filter(id => id !== sourceColId);
          const result = await assignDentist({ bookingId, dentistIds: newIds });
          if (result.error) {
            showToast(result.error.message || 'Failed to consolidate assignment.', 'error');
          } else {
            showToast(`Consolidated to ${targetColName}`, 'success');
          }
        } else {
          // Dragged to a new dentist → replace source with target
          const newIds = currentDentistIds.map(id => id === sourceColId ? targetColId : id);
          const result = await assignDentist({ bookingId, dentistIds: newIds });
          if (result.error) {
            showToast(result.error.message || 'Failed to reassign dentist.', 'error');
          } else {
            showToast(`Reassigned from ${colNameMap[sourceColId] || 'dentist'} to ${targetColName}`, 'success');
          }
        }
        refreshCalendar();
      } else {
        // Standard reassignment (non-shared)
        const apiParams = { bookingId, newDate, newStartTime };
        const optimisticFields = { date: newDate, start_time: newStartTime, end_time: newEndTime };

        if (!timeOnly) {
          if (type === 'dentist') {
            apiParams.newDentistId = targetColId === 'unassigned' ? 'unassigned' : targetColId;
            optimisticFields.dentist_id = targetColId === 'unassigned' ? null : targetColId;
          } else {
            apiParams.newChairId = targetColId === 'unassigned' ? 'unassigned' : targetColId;
            optimisticFields.chair_id = targetColId === 'unassigned' ? null : targetColId;
          }
        }

        // Optimistic UI update
        setCalendarData(prev => {
          if (!prev) return prev;
          return {
            ...prev,
            bookings: prev.bookings.map(b => {
              if (b.id === bookingId) return { ...b, ...optimisticFields };
              return b;
            }),
          };
        });

        const result = await rescheduleBooking(apiParams);
        if (result.error) {
          showToast(result.error.message || 'Failed to reassign booking.', 'error');
          refreshCalendar();
        } else {
          showToast(timeOnly ? `Rescheduled to ${newStartTime}` : `Reassigned to ${targetColName}`, 'success');
        }
      }
    } catch (err) {
      showToast('An error occurred while reassigning.', 'error');
      refreshCalendar();
    } finally {
      setIsRescheduling(false);
    }
  }, [pendingReassign, refreshCalendar, calendarData, colNameMap]);

  const handleDragCancel = useCallback(() => {
    setActiveDragId(null);
    setActiveDragBooking(null);
    setActiveDragBlock(null);
    setOverSlotData(null);
    setDragGrabOffset(0);
  }, []);

  // ── Quick-create handlers ──────────────────────────────────

  // "Add booking" choice — opens the quick-create panel at the slot (the previous direct behaviour).
  const openQuickCreateForSlot = useCallback(async (slotInfo) => {
    closeBlockPanels();
    setQuickCreateSlot(slotInfo);
    if (!treatmentsCache && !treatmentsLoading) {
      setTreatmentsLoading(true);
      const result = await fetchTreatments(branchId);
      if (result.data) setTreatmentsCache(result.data);
      setTreatmentsLoading(false);
    }
  }, [treatmentsCache, treatmentsLoading, branchId, closeBlockPanels]);

  // Toolbar "New booking" / N: quick-create at the selected date, next free 10-min slot >= now (or the open time on other days), no column.
  const handleNewBooking = useCallback(() => {
    if (quickCreateSlotRef.current) return;
    const toMin = (t, d) => { const [h, m] = (t || d).split(':').map(Number); return h * 60 + (m || 0); };
    const openMin = toMin(calendarData?.branchHours?.openTime, '09:00');
    const lastMin = Math.max(openMin, toMin(calendarData?.branchHours?.closeTime, '21:00') - 10);
    let startMin = openMin;
    if (currentDate === toKathmanduParts(new Date().toISOString()).date) {
      const nowMin = toMin(toKathmanduParts(new Date().toISOString()).time, '00:00');
      startMin = Math.min(Math.max(Math.ceil(nowMin / 10) * 10, openMin), lastMin);
    }
    runThroughPanelGuard(() => {
      setModalOpen(false);
      setSelectedBooking(null);
      setPreviewBooking(null);
      setChoiceMenuSlot(null);
      openQuickCreateForSlot({ day: currentDate, colType: null, colId: null, hour: Math.floor(startMin / 60), minute: startMin % 60 });
    });
  }, [calendarData, currentDate, openQuickCreateForSlot]);

  // Drag-to-create release: same routing as a click on an empty slot, minus the choice menu (the user already chose "new booking").
  const handleDragCreate = useCallback((slotInfo) => {
    if (rebookSource) return;
    if (slotInfo.colType === 'dentist' && isCheckedOutBlockedSlot(calendarData?.checkedOutByDentistAndDate, slotInfo.colId, slotInfo.day, slotInfo.hour, slotInfo.minute)) {
      showToast('This dentist has already checked out for the day and is not bookable after their check-out time.', 'error');
      return;
    }
    // Starting inside a block is already prevented (blocks swallow the press); a range that runs into one opens with the warning.
    if (quickCreateSlotRef.current) { setRetargetRequest({ slot: slotInfo, nonce: Date.now() }); return; }
    setChoiceMenuSlot(null);
    runThroughPanelGuard(() => {
      setModalOpen(false);
      setSelectedBooking(null);
      setPreviewBooking(null);
      openQuickCreateForSlot(slotInfo);
    });
  }, [rebookSource, calendarData, openQuickCreateForSlot]);

  const handleEmptySlotClick = useCallback(async (slotInfo) => {
    // Refuse new bookings/blocks on any slot covered by a manual block.
    const manualBlock = findBlockOverlap([...(calendarData?.blockOccurrences || []), ...(calendarData?.transferOccurrences || [])], {
      date: slotInfo.day,
      startTime: formatTimeFromSlot(slotInfo.hour, slotInfo.minute),
      durationMinutes: DEFAULT_SLOT_MINUTES,
      dentistId: slotInfo.colType === 'dentist' ? slotInfo.colId : null,
      chairId: slotInfo.colType === 'chair' ? slotInfo.colId : null,
    });
    if (manualBlock) {
      showToast(describeBlockOverlap(manualBlock), 'error');
      return;
    }

    if (slotInfo.colType === 'dentist') {
      if (isCheckedOutBlockedSlot(calendarData?.checkedOutByDentistAndDate, slotInfo.colId, slotInfo.day, slotInfo.hour, slotInfo.minute)) {
        showToast('This dentist has already checked out for the day and is not bookable after their check-out time.', 'error');
        return;
      }
    }

    // Rebook mode — place booking at clicked slot
    if (rebookSource) {
      // Capture and immediately clear to prevent double-click duplicates
      const source = rebookSource;
      setRebookSource(null);

      const startTime = `${String(slotInfo.hour).padStart(2, '0')}:${String(slotInfo.minute).padStart(2, '0')}`;
      const dentistId = slotInfo.colType === 'dentist' ? slotInfo.colId : null;
      const chairId = slotInfo.colType === 'chair' ? slotInfo.colId : null;
      const result = await createBooking({
        branchId,
        treatmentId: source.treatmentId,
        date: slotInfo.day,
        startTime,
        customerName: source.customerName,
        customerPhone: source.customerPhone,
        dentistId,
        chairId,
      });
      if (result.error) {
        showToast(result.error.message || 'Failed to rebook.', 'error');
        // Restore rebook mode on failure so user can retry
        setRebookSource(source);
      } else {
        showToast('Rebooked successfully — payment will be collected at the new appointment.');
        refreshCalendar();
      }
      return;
    }

    // Quick-create panel already open: move the draft to the clicked slot instead of opening the menu.
    if (quickCreateSlot) {
      setRetargetRequest({ slot: slotInfo, nonce: Date.now() });
      return;
    }

    // Add/Edit block panel open: the click moves the block's start / column. Transfer panels aren't retargetable.
    if (addBlockSlot || editingBlock) {
      setBlockRetarget({ slot: slotInfo, nonce: Date.now() });
      return;
    }
    if (transferModalTarget || editingTransferDentist) return;

    // Booking panel open: clicking an empty slot switches to quick-create there (through the panel's dirty guard).
    if (modalOpen) {
      runThroughPanelGuard(() => {
        setModalOpen(false);
        setSelectedBooking(null);
        setPreviewBooking(null);
        openQuickCreateForSlot(slotInfo);
      });
      return;
    }

    // Normal flow — offer a choice (Add booking / Add block); with only one option, skip the menu.
    if (!blocksAvailable) {
      openQuickCreateForSlot(slotInfo);
      return;
    }
    setChoiceMenuSlot(slotInfo);
  }, [rebookSource, branchId, refreshCalendar, calendarData, blocksAvailable, openQuickCreateForSlot, quickCreateSlot, modalOpen, addBlockSlot, editingBlock, transferModalTarget, editingTransferDentist]);

  // Transfers: cancel a scheduled transfer / bring an active one back now, via an in-app confirm.
  const handleConfirmTransferCancel = useCallback(async () => {
    const req = transferCancelRequest;
    setTransferCancelRequest(null);
    if (!req) return;
    const result = req.kind === 'scheduled'
      ? await cancelScheduledTransfer(req.col.scheduledTransfer.id)
      : await revertStaffTransferNow({ transferId: req.col.transferId });
    if (result.error) {
      showToast(result.error.message || 'Failed to cancel transfer.', 'error');
      return;
    }
    showToast(req.kind === 'scheduled' ? 'Scheduled transfer cancelled.' : `${req.col.name} is back at this branch.`);
    refreshCalendar();
  }, [transferCancelRequest, refreshCalendar]);

  // Block management from the calendar overlay: resize, and delete (via the in-app scope dialog).
  const handleDeleteManualBlock = useCallback(async ({ blockId, day, scope = 'this' }) => {
    const result = await deleteBlock({ blockId, scope, occurrenceDate: day });
    if (result.error) {
      showToast(result.error.message || 'Failed to remove block.', 'error');
      return;
    }
    showToast(scope === 'series' ? 'Block series removed.' : 'Block removed.');
    refreshCalendar();
  }, [refreshCalendar]);

  const handleResizeManualBlock = useCallback(async ({ blockId, day, durationMinutes }) => {
    const result = await updateBlock({ blockId, scope: 'this', occurrenceDate: day, durationMinutes });
    if (result.error) {
      showToast(result.error.message || 'Failed to resize block.', 'error');
      return;
    }
    refreshCalendar();
  }, [refreshCalendar]);

  const handleQuickCreateClose = useCallback(() => {
    setQuickCreateSlot(null);
    setRetargetRequest(null);
    setDraftGhost(null);
  }, []);

  // Auto-open the Quick Booking panel when the mobile FAB navigates here with
  // ?newBooking=1. Defaults to today + unassigned, no time. Param is stripped
  // afterwards so refresh/back-nav doesn't re-trigger the panel.
  useEffect(() => {
    if (!branchId) return;
    if (searchParams.get('newBooking') !== '1') return;
    handleEmptySlotClick({
      day: currentDate,
      colType: null,
      colId: null,
      colName: 'Unassigned',
    });
    const next = new URLSearchParams(searchParams);
    next.delete('newBooking');
    setSearchParams(next, { replace: true });
  }, [searchParams, branchId, currentDate, handleEmptySlotClick, setSearchParams]);

  const handleQuickCreateSubmit = useCallback(async (formData) => {
    if (!branchId) return 'Missing branch info.';
    const date = formData.bookingDate;
    const startTime = formData.bookingTime;
    if (!date || !startTime) return 'Date and time are required.';

    // Group booking: one booking per person, all sharing one booking_group_id.
    // Created sequentially so each chair-capacity check sees prior group members
    // (matters for a Couple sharing one chair, and Separate chairs running low).
    if (formData.mode === 'group') {
      const people = formData.people || [];
      if (people.length === 0) return 'Add at least one person.';
      const groupId = crypto.randomUUID();
      let created = 0;
      for (let i = 0; i < people.length; i++) {
        const person = people[i];
        const result = await createBooking({
          branchId,
          treatmentId: person.treatmentId,
          date,
          startTime,
          customerName: person.customerName,
          customerPhone: person.customerPhone,
          customerEmail: person.customerEmail,
          customerGender: person.customerGender,
          specialRequests: formData.specialRequests,
          dentistIds: person.dentistIds,
          chairId: person.chairId || 'none',
          bookingGroupId: groupId,
        });
        if (result.error) {
          const who = person.customerName || `person ${i + 1}`;
          const tail = created > 0 ? ` (${created} booking${created > 1 ? 's' : ''} already created)` : '';
          return `Failed for ${who}: ${result.error.message || 'could not create booking.'}${tail}`;
        }
        created++;
      }
      showToast(`${created} group bookings created successfully`);
      setQuickCreateSlot(null);
      refreshCalendar();
      return null;
    }

    const result = await createBooking({
      branchId,
      treatmentId: formData.treatmentId,
      date,
      startTime,
      customerName: formData.customerName,
      customerPhone: formData.customerPhone,
      customerEmail: formData.customerEmail,
      customerGender: formData.customerGender,
      specialRequests: formData.specialRequests,
      dentistIds: formData.dentistIds || (formData.dentistId ? [formData.dentistId] : null),
      chairId: formData.chairId || 'none',
      referringCustomerId: formData.referringCustomerId,
      referringRewardType: formData.referringRewardType,
      referringRewardAmount: formData.referringRewardAmount,
    });
    if (result.error) {
      return result.error.message || 'Failed to create booking.';
    }
    showToast('Booking created successfully');
    setQuickCreateSlot(null);
    refreshCalendar();
    return null;
  }, [branchId, refreshCalendar]);

  // ── Rebook "pick and place" handlers ───────────────────────

  const handleRebookStart = useCallback((booking) => {
    setRebookSource({
      booking,
      customerName: booking.customerName,
      customerPhone: booking.customerPhone,
      treatmentId: booking.treatmentId,
      treatmentName: booking.treatment,
      duration: booking.duration,
    });
    setModalOpen(false);
    setSelectedBooking(null);
  }, []);

  const handleRebookCancel = useCallback(() => setRebookSource(null), []);

  // ── Event click → modal ────────────────────────────────────

  const runThroughPanelGuard = (action) => {
    const guard = quickCreateSlotRef.current ? quickGuardRef.current
      : (modalOpenRef.current ? bookingGuardRef.current : (blockPanelOpenRef.current ? blockGuardRef.current : null));
    if (guard) guard(action); else action();
  };

  // Open a block/transfer form panel: closes quick-create and the booking panel first (the caller has already run the guard).
  const openOnlyPanel = (openFn) => {
    setQuickCreateSlot(null); setRetargetRequest(null); setDraftGhost(null);
    setModalOpen(false); setSelectedBooking(null); setPreviewBooking(null);
    setChoiceMenuSlot(null);
    closeBlockPanels();
    openFn();
  };

  const openBookingPanel = useCallback(async (booking) => {
    const bookingId = booking.bookingId || booking.id;
    if (!bookingId) return;

    // The panel opens instantly with the card's known data (skeleton for the rest); one panel at a time.
    closeBlockPanels();
    setQuickCreateSlot(null);
    setRetargetRequest(null);
    setDraftGhost(null);
    setSelectedBooking(null);
    setPreviewBooking(booking);
    setModalLoading(true);
    setModalOpen(true);

    const result = await fetchBookingById(bookingId);

    if (result.error) {
      setModalOpen(false);
      setModalLoading(false);
      setPreviewBooking(null);
      showToast(result.error.message || 'Failed to load booking.', 'error');
      return;
    }

    // Ignore a stale response if the user already clicked another booking.
    if (previewBookingRef.current && (previewBookingRef.current.bookingId || previewBookingRef.current.id) !== bookingId) return;
    setSelectedBooking(transformBooking(result.data));
    setModalLoading(false);

    // Pre-fetch treatments for "Add Another Treatment" / edit mode
    if (!treatmentsCache && !treatmentsLoading) {
      setTreatmentsLoading(true);
      const svcResult = await fetchTreatments(branchId);
      if (svcResult.data) setTreatmentsCache(svcResult.data);
      setTreatmentsLoading(false);
    }
  }, [treatmentsCache, treatmentsLoading, branchId]);

  // Clicking a card: same booking → no-op; otherwise switch (through the open panel's dirty guard).
  const handleBookingClick = useCallback((booking) => {
    const bookingId = booking.bookingId || booking.id;
    if (modalOpenRef.current && previewBookingRef.current && (previewBookingRef.current.bookingId || previewBookingRef.current.id) === bookingId) return;
    runThroughPanelGuard(() => openBookingPanel(booking));
  }, [openBookingPanel]);

  // Re-fetch the open booking after an in-place panel action (status change).
  const refreshOpenBooking = useCallback(async (bookingId) => {
    const refreshed = await fetchBookingById(bookingId);
    if (!refreshed.error) setSelectedBooking(transformBooking(refreshed.data));
    refreshCalendar();
  }, [refreshCalendar]);

  const handleModalClose = useCallback(() => {
    setModalOpen(false);
    setSelectedBooking(null);
    setPreviewBooking(null);
    setRebookFallback(false);
    refreshCalendar();
  }, [refreshCalendar]);

  // ── Action handlers ────────────────────────────────────────

  const showToast = (msg, type = 'success') => {
    setActionToast({ msg, type });
    setTimeout(() => setActionToast(null), 3000);
  };

  const handleStatusUpdate = async (bookingId, newStatus, reason) => {
    const dbStatus = toDbStatus(newStatus);
    const result = await updateBookingStatus({ bookingId, newStatus: dbStatus, reason });
    if (result.error) {
      showToast(result.error.message || 'Failed to update status.', 'error');
      return;
    }
    showToast(`Status updated to ${newStatus}`);
  };

  const handleAssignDentist = async (bookingId, dentistIds, notes, chairId) => {
    const ids = Array.isArray(dentistIds) ? dentistIds : (dentistIds ? [dentistIds] : []);
    const result = await assignDentist({ bookingId, dentistIds: ids, chairId: chairId !== undefined ? (chairId || null) : undefined });
    if (result.error) {
      showToast(result.error.message || `Failed to assign ${staffLabel.toLowerCase()}.`, 'error');
      return;
    }
    showToast('Assignment saved successfully');
  };

  const handleBookingResize = useCallback(async (booking, deltaMinutes, direction) => {
    if (!booking.isShared || !booking._colDentistId) return;

    const [sh, sm] = (booking.startTime || '').split(':').map(Number);
    const [eh, em] = (booking.endTime || '').split(':').map(Number);
    if (isNaN(sh) || isNaN(eh)) return;

    const startMins = sh * 60 + sm;
    const endMins = eh * 60 + em;
    let newStartMins = startMins;
    let newEndMins = endMins;

    if (direction === 'top') {
      newStartMins = Math.max(startMins + deltaMinutes, 0);
    } else {
      newEndMins = Math.max(endMins + deltaMinutes, 0);
    }

    // Ensure minimum 5 min duration
    if (newEndMins - newStartMins < 5) {
      showToast('Minimum duration is 5 minutes.', 'error');
      return;
    }

    const newStartTime = `${String(Math.floor(newStartMins / 60)).padStart(2, '0')}:${String(newStartMins % 60).padStart(2, '0')}`;
    const newEndTime = `${String(Math.floor(newEndMins / 60)).padStart(2, '0')}:${String(newEndMins % 60).padStart(2, '0')}`;

    // Same default-vs-independent gate as the drag handler above: resizing an
    // explicitly Cmd/Ctrl-selected card moves only that dentist; otherwise the
    // whole shared booking (every co-dentist + the canonical bookings row)
    // resizes together, so one resize can never silently desync a co-dentist
    // from the rest of the booking (see resizeSharedBookingTime in api.js).
    const selectedBookings = getSelectedBookingsRef.current();
    const draggedKey = `${booking.id}__${booking._colDentistId}`;
    const isPartOfSelection = selectedBookings.length > 0 && selectedBookings.some(b => `${b.id}__${b._colDentistId}` === draggedKey);

    const bookingId = booking.bookingId || booking.id;
    const result = isPartOfSelection
      ? await updateDentistTime({
          bookingId,
          dentistId: booking._colDentistId,
          startTime: newStartTime,
          endTime: newEndTime,
        })
      : await resizeSharedBookingTime({ bookingId, startTime: newStartTime, endTime: newEndTime });

    if (result.error) {
      showToast(result.error.message || 'Failed to resize.', 'error');
    } else if (isPartOfSelection) {
      showToast(`Resized ${booking.dentistName || 'dentist'} independently to ${newStartTime} – ${newEndTime}`, 'success');
    } else {
      showToast(`Resized to ${newStartTime} – ${newEndTime}`, 'success');
    }
    refreshCalendar();
  }, [refreshCalendar]);

  const handleEditBooking = async (bookingId, updates) => {
    const result = await updateBookingDetails({ bookingId, ...updates });
    if (result.error) {
      showToast(result.error.message || 'Failed to update booking.', 'error');
      return { error: result.error };
    }
    showToast('Booking updated successfully');
    // Re-fetch the booking to update modal data
    const refreshed = await fetchBookingById(bookingId);
    if (!refreshed.error) {
      setSelectedBooking(transformBooking(refreshed.data));
    }
    refreshCalendar();
    return { error: null };
  };

  const handleApplyDiscount = async (bookingId, { discountType, discountValue, discountReason, requestedTo }) => {
    const result = await applyDiscount({ bookingId, discountType, discountValue, discountReason, requestedTo });
    if (result.error) return { error: result.error };
    showToast(result.data?.isPending ? 'Discount request sent for approval' : 'Discount applied successfully');
    // Refresh booking in modal
    const refreshed = await fetchBookingById(bookingId);
    if (!refreshed.error) setSelectedBooking(transformBooking(refreshed.data));
    refreshCalendar();
    return { data: result.data };
  };

  const handleRecordPayment = async (bookingId, opts) => {
    const result = await recordPayment({ bookingId, ...opts });
    if (result.error) {
      return { error: result.error };
    }
    showToast('Payment recorded successfully');
    // Only refresh the modal's displayed booking when this payment was for the
    // booking currently open (not a bundled previous-due/related payment for a
    // different booking) — otherwise the modal would flip to showing whichever
    // bundled booking happened to be paid last.
    if (selectedBooking && bookingId === selectedBooking.bookingId) {
      const refreshed = await fetchBookingById(bookingId);
      if (!refreshed.error) setSelectedBooking(transformBooking(refreshed.data));
    }
    refreshCalendar();
    return { error: null };
  };

  // ── Dentist/chair column reorder ────────────────────────────
  // Gates both onDentistReorder and onChairReorder below. Branch-scoped:
  // staff can rearrange columns for their own branch only.
  const canReorderDentists = ['staff', 'manager', 'admin'].includes(profile?.role);

  const handleDentistReorder = useCallback(async (orderedIds) => {
    if (!branchId) return;
    // Optimistic: reorder dentists array in local state
    setCalendarData(prev => {
      if (!prev) return prev;
      const dentistMap = {};
      prev.dentists.forEach(t => { dentistMap[t.id] = t; });
      const reordered = orderedIds
        .map(id => dentistMap[id])
        .filter(Boolean);
      // Append any dentists not in orderedIds (safety)
      prev.dentists.forEach(t => {
        if (!orderedIds.includes(t.id)) reordered.push(t);
      });
      return { ...prev, dentists: reordered };
    });

    // Persist to DB
    const { error } = await updateDentistOrder({ branchId, orderedIds });
    if (error) {
      console.error('[Calendar] Failed to persist dentist order:', error.message);
      refreshCalendar();
    }
  }, [branchId, refreshCalendar]);

  // ── Chair column reorder ───────────────────────────────────
  const handleChairReorder = useCallback(async (orderedIds) => {
    if (!branchId) return;
    // Optimistic: reorder chairs array in local state
    setCalendarData(prev => {
      if (!prev) return prev;
      const chairMap = {};
      prev.chairs.forEach(r => { chairMap[r.id] = r; });
      const reordered = orderedIds
        .map(id => chairMap[id])
        .filter(Boolean);
      // Append any chairs not in orderedIds (safety)
      prev.chairs.forEach(r => {
        if (!orderedIds.includes(r.id)) reordered.push(r);
      });
      return { ...prev, chairs: reordered };
    });

    // Persist to DB
    const { error } = await updateChairOrder({ branchId, orderedIds });
    if (error) {
      console.error('[Calendar] Failed to persist chair order:', error.message);
      refreshCalendar();
    }
  }, [branchId, refreshCalendar]);

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

  // ── Render ─────────────────────────────────────────────────

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
          {/* Top toolbar — wraps on narrow screens; 3-column grid on sm+ (left / center / right) */}
          <div className="flex flex-wrap items-center justify-between gap-2 px-3 sm:px-4 py-2 border-b border-border bg-surface flex-shrink-0 overflow-x-clip">
            {/* Left: Dentist/Chair toggle + away summary */}
            <div className="flex items-center gap-3 justify-self-start min-w-0">
              {enableChairs ? (
                <div className="flex items-center border border-border rounded-spa bg-background p-0.5 gap-0.5 h-9">
                  {[
                    { key: 'dentist', icon: 'User', label: staffLabel },
                    { key: 'chair', icon: 'DoorOpen', label: locationLabel },
                  ].map(m => (
                    <button
                      key={m.key}
                      onClick={() => setColumnMode(m.key)}
                      className={`flex items-center gap-1.5 px-2.5 h-full text-[13px] rounded-[4px] font-body font-body-medium spa-transition-fast ${
                        columnMode === m.key ? 'bg-text-primary text-white' : 'text-text-secondary hover:text-text-primary'
                      }`}
                    >
                      <Icon name={m.icon} size={14} />
                      <span>{m.label}</span>
                    </button>
                  ))}
                </div>
              ) : (
                <div className="flex items-center gap-1.5 text-[13px] text-text-primary font-body">
                  <Icon name="User" size={14} className="text-text-secondary" />
                  <span>{staffLabelPlural}</span>
                </div>
              )}
              {awayList.length > 0 && columnMode === 'dentist' && (
                <div className="relative hidden sm:block" ref={awayRef}>
                  <button
                    onClick={() => setAwayOpen(prev => !prev)}
                    className="text-[13px] text-text-tertiary hover:text-text-secondary spa-transition-fast whitespace-nowrap"
                    aria-label="Show staff who are away"
                  >
                    {awayList.length} away
                  </button>
                  {awayOpen && (
                    <div className="absolute left-0 top-full mt-1 w-56 bg-surface border border-border rounded-spa-lg shadow-spa-elevated z-dropdown p-2 space-y-1">
                      {awayList.map(a => (
                        <div key={a.id} className="flex items-center gap-1.5 text-[13px] text-text-secondary">
                          <span className={`w-1.5 h-1.5 rounded-full flex-shrink-0 ${a.status === 'Absent' ? 'bg-error' : 'bg-warning'}`} />
                          <span className="truncate text-text-primary">{a.name}</span>
                          <span className="ml-auto text-text-tertiary">{a.status === 'Absent' ? 'Absent' : 'On leave'}</span>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              )}
            </div>

            {/* Center: jump / prev / Today / date / next / jump */}
            <div className="flex items-center gap-1.5 justify-center justify-self-center order-last sm:order-none w-full sm:w-auto">
              <div className="relative" ref={prevJumpRef}>
                <button
                  onClick={() => setJumpMenuOpen(prev => (prev === 'prev' ? null : 'prev'))}
                  className="h-9 w-9 flex items-center justify-center border border-border rounded-spa hover:bg-background spa-transition-fast"
                  aria-label="Jump back"
                >
                  <Icon name="ChevronsLeft" size={16} className="text-text-secondary" />
                </button>
                {jumpMenuOpen === 'prev' && (
                  <div className="absolute left-0 top-full mt-1 w-32 max-h-72 overflow-y-auto bg-surface border border-border rounded-spa-lg shadow-spa-elevated z-dropdown py-1">
                    {JUMP_OPTIONS.map(opt => (
                      <button
                        key={opt.label}
                        onClick={() => { applyJump(-1, opt.unit, opt.amount); setJumpMenuOpen(null); }}
                        className="w-full text-left px-3 py-1.5 text-[13px] text-text-primary hover:bg-background"
                      >
                        -{opt.label}
                      </button>
                    ))}
                  </div>
                )}
              </div>
              <button
                onClick={goPrev}
                className="h-9 w-9 flex items-center justify-center border border-border rounded-spa hover:bg-background spa-transition-fast"
                aria-label="Previous"
                title={viewMode === '4day' ? 'Previous 4 days (J or ←)' : 'Previous day (J or ←)'}
                aria-keyshortcuts="j ArrowLeft"
              >
                <Icon name="ChevronLeft" size={16} className="text-text-secondary" />
              </button>
              <button
                onClick={goToday}
                title="Today (T)"
                aria-keyshortcuts="t"
                className="h-9 px-3 text-[13px] font-body font-body-medium text-text-primary border border-border rounded-spa hover:bg-background spa-transition-fast"
              >
                Today
              </button>
              <div className="relative" ref={dateDropdownRef}>
                <button
                  onClick={() => setDateDropdownOpen(prev => !prev)}
                  className={`h-9 flex items-center gap-1.5 px-3 text-[13px] font-body font-body-medium text-text-primary border rounded-spa hover:bg-background spa-transition-fast justify-between ${
                    dateDropdownOpen ? 'border-text-primary' : 'border-border'
                  }`}
                  aria-haspopup="dialog"
                  aria-expanded={dateDropdownOpen}
                >
                  <span className="whitespace-nowrap">{formatDateTitle(currentDate, viewMode)}</span>
                  <Icon name="ChevronDown" size={14} className={`text-text-secondary spa-transition-fast ${dateDropdownOpen ? 'rotate-180' : ''}`} />
                </button>
                {dateDropdownOpen && (
                  <div className="absolute left-1/2 -translate-x-1/2 top-full mt-1 bg-surface border border-border rounded-spa-lg shadow-spa-elevated z-dropdown p-3">
                    <MiniMonthCalendar
                      selectedDate={currentDate}
                      onDateSelect={(d) => { setCurrentDate(d); setDateDropdownOpen(false); }}
                    />
                  </div>
                )}
              </div>
              <button
                onClick={goNext}
                className="h-9 w-9 flex items-center justify-center border border-border rounded-spa hover:bg-background spa-transition-fast"
                aria-label="Next"
                title={viewMode === '4day' ? 'Next 4 days (K or →)' : 'Next day (K or →)'}
                aria-keyshortcuts="k ArrowRight"
              >
                <Icon name="ChevronRight" size={16} className="text-text-secondary" />
              </button>
              <div className="relative" ref={nextJumpRef}>
                <button
                  onClick={() => setJumpMenuOpen(prev => (prev === 'next' ? null : 'next'))}
                  className="h-9 w-9 flex items-center justify-center border border-border rounded-spa hover:bg-background spa-transition-fast"
                  aria-label="Jump forward"
                >
                  <Icon name="ChevronsRight" size={16} className="text-text-secondary" />
                </button>
                {jumpMenuOpen === 'next' && (
                  <div className="absolute right-0 top-full mt-1 w-32 max-h-72 overflow-y-auto bg-surface border border-border rounded-spa-lg shadow-spa-elevated z-dropdown py-1">
                    {JUMP_OPTIONS.map(opt => (
                      <button
                        key={opt.label}
                        onClick={() => { applyJump(1, opt.unit, opt.amount); setJumpMenuOpen(null); }}
                        className="w-full text-left px-3 py-1.5 text-[13px] text-text-primary hover:bg-background"
                      >
                        +{opt.label}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            </div>

            {/* Right: tip + position filter + view toggle */}
            <div className="flex items-center gap-2 ml-auto">
              <div className="relative" ref={tipRef}>
                <button
                  type="button"
                  onClick={() => setTipOpen(prev => !prev)}
                  className="h-9 w-9 flex items-center justify-center border border-border rounded-spa hover:bg-background spa-transition-fast"
                  aria-label="Shortcuts and drag-and-drop tips"
                  title="Shortcuts (?)"
                  aria-keyshortcuts="?"
                >
                  <Icon name="Info" size={16} className="text-text-secondary" />
                </button>
                {tipOpen && (
                  <div role="dialog" aria-label="Keyboard shortcuts" className="absolute right-0 top-full mt-1 w-72 bg-surface border border-border rounded-spa-lg shadow-spa-elevated z-dropdown p-4 text-[13px] text-text-secondary leading-relaxed text-left">
                    <p className="font-body font-medium text-xs uppercase tracking-wider text-text-tertiary mb-2">Keyboard shortcuts</p>
                    <dl className="space-y-1.5">
                      {[
                        ['T', 'Today'],
                        ['J / ←', viewMode === '4day' ? 'Previous 4 days' : 'Previous day'],
                        ['K / →', viewMode === '4day' ? 'Next 4 days' : 'Next day'],
                        ['D', 'Day view'],
                        ['F', '4-Day view'],
                        ['N', 'New booking'],
                        ['Esc', 'Close popover, menu or panel'],
                        ['?', 'Show / hide this list'],
                      ].map(([key, label]) => (
                        <div key={key} className="flex items-center justify-between gap-3">
                          <dt>{label}</dt>
                          <dd><kbd className="px-1.5 py-0.5 rounded-[4px] border border-border bg-background font-data text-[11px] text-text-primary">{key}</kbd></dd>
                        </div>
                      ))}
                    </dl>
                    <p className="mt-3 pt-3 border-t border-border text-xs text-text-tertiary">
                      Drag a booking to reschedule it (Pending, or before its start time; not paid, in progress or closed). Drag on an empty column to start a new booking.
                    </p>
                  </div>
                )}
              </div>
              {columnMode === 'dentist' && (
                <div className="relative" ref={positionDropdownRef}>
                  <button
                    onClick={() => setPositionDropdownOpen(prev => !prev)}
                    className={`h-9 flex items-center gap-1.5 px-3 text-[13px] border rounded-spa spa-transition-fast ${
                      selectedPositions.length > 0 ? 'border-text-primary bg-background text-text-primary' : 'border-border bg-surface text-text-primary'
                    }`}
                  >
                    <Icon name="Filter" size={14} />
                    <span className="hidden sm:inline">{selectedPositions.length === 0 ? 'All Positions' : `${selectedPositions.length} selected`}</span>
                    <Icon name="ChevronDown" size={14} className={`spa-transition-fast ${positionDropdownOpen ? 'rotate-180' : ''}`} />
                  </button>
                  {positionDropdownOpen && (
                    <div className="absolute right-0 top-full mt-1 w-56 bg-surface border border-border rounded-spa-lg shadow-spa-elevated z-dropdown">
                      <label className="flex items-center gap-2 px-3 py-2 border-b border-border cursor-pointer hover:bg-background">
                        <input
                          type="checkbox"
                          checked={showTreatmentOnly}
                          onChange={(e) => setShowTreatmentOnly(e.target.checked)}
                          className="text-primary focus:ring-primary w-3.5 h-3.5 rounded"
                        />
                        <span className="text-[13px] text-text-primary">Treatment staff only</span>
                      </label>
                      {calendarPositionOptions.length > 0 && (
                        <>
                          <div className="p-1.5 border-b border-border">
                            <button
                              onClick={() => setSelectedPositions([])}
                              className="w-full text-left px-2 py-1 text-xs text-primary hover:bg-primary/5 rounded"
                            >
                              Clear all
                            </button>
                          </div>
                          <div className="max-h-[200px] overflow-y-auto p-1.5 space-y-0.5">
                            {calendarPositionOptions.map(pos => (
                              <label key={pos} className={`flex items-center gap-2 px-2 py-1.5 rounded cursor-pointer hover:bg-background ${selectedPositions.includes(pos) ? 'bg-background' : ''}`}>
                                <input
                                  type="checkbox"
                                  checked={selectedPositions.includes(pos)}
                                  onChange={(e) => {
                                    if (e.target.checked) {
                                      setSelectedPositions(prev => [...prev, pos]);
                                    } else {
                                      setSelectedPositions(prev => prev.filter(p => p !== pos));
                                    }
                                  }}
                                  className="text-primary focus:ring-primary w-3.5 h-3.5 rounded"
                                />
                                <span className="text-[13px] text-text-primary">{pos}</span>
                              </label>
                            ))}
                          </div>
                        </>
                      )}
                    </div>
                  )}
                </div>
              )}
              <div className="flex items-center border border-border rounded-spa bg-background p-0.5 gap-0.5 h-9">
                {[
                  { key: 'day', label: 'Day' },
                  { key: '4day', label: '4 Day' },
                ].map(v => (
                  <button
                    key={v.key}
                    onClick={() => setViewMode(v.key)}
                    title={v.key === 'day' ? 'Day view (D)' : '4-Day view (F)'}
                    aria-keyshortcuts={v.key === 'day' ? 'd' : 'f'}
                    className={`px-3 h-full text-[13px] rounded-[4px] font-body font-body-medium spa-transition-fast whitespace-nowrap ${
                      viewMode === v.key
                        ? 'bg-text-primary text-white'
                        : 'text-text-secondary hover:text-text-primary'
                    }`}
                  >
                    {v.label}
                  </button>
                ))}
              </div>
              <button
                type="button"
                onClick={handleNewBooking}
                title="New booking (N)"
                aria-keyshortcuts="n"
                className="h-9 flex items-center gap-1.5 px-3.5 text-[13px] font-body font-body-medium text-white bg-primary hover:bg-primary/90 rounded-spa spa-transition-fast whitespace-nowrap"
              >
                <Icon name="Plus" size={14} />
                New booking
              </button>
            </div>
          </div>

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

        {/* Drag overlay for visual feedback */}
        <DragOverlay>
          {activeDragBlock && (() => {
            const [fh, fm] = activeDragBlock.fromTime.split(':').map(Number);
            const [th, tm] = activeDragBlock.toTime.split(':').map(Number);
            const blockMins = (th * 60 + tm) - (fh * 60 + fm);
            return (
              <div className="bg-background rounded-spa border border-border shadow-spa-elevated px-3 py-2 min-w-[140px]">
                <div className="font-body text-[11px] text-text-secondary">{activeDragBlock.description || 'Blocked'}</div>
                {overSlotData && blockMins > 0 && (
                  <div className="font-data text-xs font-semibold text-text-primary mt-0.5">
                    {formatTimeFromSlot(overSlotData.hour, overSlotData.minute)} – {calculateEndTime(overSlotData.hour, overSlotData.minute, blockMins)}
                  </div>
                )}
              </div>
            );
          })()}
          {activeDragBooking && (() => {
            // Calculate preview time based on hovered slot
            const duration = activeDragBooking.treatmentDuration ||
              (activeDragBooking.startTime && activeDragBooking.endTime
                ? (() => {
                    const [sh, sm] = activeDragBooking.startTime.split(':').map(Number);
                    const [eh, em] = activeDragBooking.endTime.split(':').map(Number);
                    return (eh * 60 + em) - (sh * 60 + sm);
                  })()
                : 60);

            const previewStartTime = overSlotData
              ? formatTimeFromSlot(overSlotData.hour, overSlotData.minute)
              : activeDragBooking.startTime?.slice(0, 5) || '';

            const previewEndTime = overSlotData
              ? calculateEndTime(overSlotData.hour, overSlotData.minute, duration)
              : activeDragBooking.endTime?.slice(0, 5) || '';

            return (
              <div className="bg-white rounded-md border-2 border-primary shadow-lg px-3 py-2 opacity-95 min-w-[140px]">
                {/* Time display - prominent */}
                <div className="font-data text-sm font-semibold text-text-primary mb-1">
                  {previewStartTime} – {previewEndTime}
                </div>
                <div className="font-body font-semibold text-xs text-text-primary">
                  {activeDragBooking.customerName}
                </div>
                <div className="font-body text-[11px] text-text-secondary">
                  {activeDragBooking.treatmentName}
                </div>
                <div className="flex items-center justify-between mt-1">
                  <span className="font-caption text-[10px] text-text-secondary">
                    {duration} mins
                  </span>
                  {overSlotData && (
                    <span className="font-caption text-[10px] text-primary font-medium">
                      Drop here
                    </span>
                  )}
                </div>
              </div>
            );
          })()}
        </DragOverlay>
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

      {/* Reassignment Confirmation Dialog */}
      {pendingReassign && (
        <div className="fixed inset-0 bg-text-primary/50 backdrop-blur-sm z-modal flex items-center justify-center p-4">
          <div className="bg-surface rounded-spa-lg spa-shadow-modal p-6 max-w-sm w-full animate-fade-in">
            <div className="flex items-center gap-2 mb-4">
              <Icon name={pendingReassign.timeOnly ? 'Clock' : pendingReassign.isSharedReassign ? 'Users' : (pendingReassign.type === 'dentist' ? 'UserCheck' : 'DoorOpen')} size={20} className={pendingReassign.isSharedReassign ? 'text-violet-500' : 'text-primary'} />
              <h3 className="font-heading font-heading-semibold text-base text-text-primary">
                {pendingReassign.timeOnly ? 'Reschedule Booking'
                  : pendingReassign.isSharedReassign
                    ? (pendingReassign.sourceColId !== pendingReassign.targetColId && calendarData?.bookings?.find(b => b.id === pendingReassign.bookingId)?.booking_dentists?.some(bt => bt.dentist_id === pendingReassign.targetColId)
                      ? 'Consolidate Assignment'
                      : 'Reassign Shared Booking')
                    : `Reassign ${pendingReassign.type === 'dentist' ? staffLabel : locationLabel}`}
              </h3>
            </div>
            <p className="font-body text-sm text-text-secondary mb-1">
              {pendingReassign.isSharedReassign
                ? (calendarData?.bookings?.find(b => b.id === pendingReassign.bookingId)?.booking_dentists?.some(bt => bt.dentist_id === pendingReassign.targetColId)
                  ? <>Remove <span className="font-semibold text-text-primary">{pendingReassign.sourceColName}</span> from</>
                  : <>Replace <span className="font-semibold text-text-primary">{pendingReassign.sourceColName}</span> with <span className="font-semibold text-text-primary">{pendingReassign.targetColName}</span> for</>)
                : <>{pendingReassign.timeOnly ? 'Reschedule' : 'Move'}</>} <span className="font-semibold text-text-primary">{pendingReassign.booking.customerName}</span>
            </p>
            {!pendingReassign.timeOnly && !pendingReassign.isSharedReassign && (
              <p className="font-body text-sm text-text-secondary mb-3">
                from <span className="font-semibold text-text-primary">{pendingReassign.sourceColName}</span>
                {' '}&rarr;{' '}
                <span className="font-semibold text-text-primary">{pendingReassign.targetColName}</span>
              </p>
            )}
            {pendingReassign.timeChanged && (
              <p className="font-body text-xs text-text-secondary mb-3">
                {pendingReassign.timeOnly ? 'New time' : 'Time'}: {formatTimeDisplay(pendingReassign.newStartTime)} – {formatTimeDisplay(pendingReassign.newEndTime)}
                {pendingReassign.newDate !== pendingReassign.booking.date && (
                  <span> on {pendingReassign.newDate}</span>
                )}
              </p>
            )}
            <div className="flex items-center justify-end gap-2 mt-4">
              <button
                onClick={() => setPendingReassign(null)}
                className="px-4 py-2 text-sm font-body font-body-medium border border-border rounded-spa hover:bg-background spa-transition-fast"
              >
                Cancel
              </button>
              <button
                onClick={handleConfirmReassign}
                className="px-4 py-2 text-sm font-body font-body-medium bg-primary text-white rounded-spa hover:bg-primary/90 spa-transition-fast"
              >
                Confirm
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
};

export default OperationalCalendar;
