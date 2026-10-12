import React, { useState, useEffect, useRef, useMemo } from 'react';
import { useOrg } from '../../../../contexts/OrgContext';
import { createBlock } from '../../../../services/api';
import { countBookingsInRange, bookingsInRangeMessage } from '../../../../utils/bookingsInRange';
import {
  PanelShell, FormBody, Field, TextInput, NumberInput, SelectField, Segmented, TabBar, DateField, TimeField,
  InlineError, InlineWarning, format12h, addMinutes, formatShortDate,
} from '../../../../components/ui/PanelFormKit';

const TABS = [
  { id: 'details', label: 'Details', icon: 'FileText' },
  { id: 'recurrence', label: 'Recurrence', icon: 'Repeat' },
];

const REPEAT_OPTIONS = [
  { value: '', label: 'Does not repeat' },
  { value: 'daily', label: 'Daily' },
  { value: 'weekly', label: 'Weekly' },
  { value: 'monthly', label: 'Monthly' },
];

const END_CONDITION_OPTIONS = [
  { value: 'never', label: 'Never' },
  { value: 'date', label: 'On date' },
  { value: 'count', label: 'After N occurrences' },
];

const slotTime = (slot) => (slot?.hour != null ? `${String(slot.hour).padStart(2, '0')}:${String(slot.minute ?? 0).padStart(2, '0')}` : '');

// "Add block" form — a docked SidePanel on the calendar (variant="panel"), or the classic centered modal.
// Two tabs: Details (who/when/why) and Recurrence. While open it reports a live draft (`onDraftChange`) so the grid can
// show the block in its final hatched style, and it accepts `retarget` (click an empty slot to move the start / column).
const AddBlockModal = ({
  variant = 'modal', branchId, slotInfo, dentists, chairs, bookings = [], branchHours, retarget, guardRef,
  onClose, onSuccess, onChairOnlyChange, onDraftChange,
}) => {
  const { orgId } = useOrg();
  const [activeTab, setActiveTab] = useState('details');

  const [assigneeType, setAssigneeType] = useState(slotInfo?.colType === 'dentist' ? 'dentist' : 'location');
  const [dentistId, setDentistId] = useState(slotInfo?.colType === 'dentist' ? slotInfo.colId : '');
  const [chairId, setChairId] = useState(slotInfo?.colType === 'chair' ? slotInfo.colId : '');
  const [date, setDate] = useState(slotInfo?.day || '');
  const [startTime, setStartTime] = useState(slotTime(slotInfo));
  const [durationMinutes, setDurationMinutes] = useState('30');
  const [description, setDescription] = useState('');
  const [preventOnlineBooking, setPreventOnlineBooking] = useState(true);

  const [repeat, setRepeat] = useState('');
  const [recurrenceIntervalInput, setRecurrenceIntervalInput] = useState('1');
  const [endCondition, setEndCondition] = useState('never');
  const [endDate, setEndDate] = useState('');
  const [endCount, setEndCount] = useState('10');

  const [error, setError] = useState(null);
  const [submitting, setSubmitting] = useState(false);
  const [moveConfirm, setMoveConfirm] = useState(null);

  // Baseline for "did the user change something beyond the slot?" — the slot (date/time/column) is moved silently by retargeting.
  const baselineRef = useRef({ dentist: slotInfo?.colType === 'dentist' ? slotInfo.colId : '', chair: slotInfo?.colType === 'chair' ? slotInfo.colId : '' });
  const dirty = !!description.trim() || durationMinutes !== '30' || !preventOnlineBooking || !!repeat
    || (assigneeType === 'dentist' ? dentistId : '') !== baselineRef.current.dentist || chairId !== baselineRef.current.chair;

  const isFormComplete = !!date && !!startTime && Number(durationMinutes) > 0 && (assigneeType !== 'dentist' || !!dentistId);

  const dur = Number(durationMinutes) > 0 ? Number(durationMinutes) : 0;
  const effDentist = assigneeType === 'dentist' ? dentistId : '';
  const bookingCount = useMemo(
    () => countBookingsInRange(bookings, { date, startTime, durationMinutes: dur, dentistId: effDentist, chairId }),
    [bookings, date, startTime, dur, effDentist, chairId]
  );
  const bookingWarning = bookingsInRangeMessage(bookingCount);

  // Live preview on the grid.
  useEffect(() => {
    onDraftChange?.({
      kind: 'block', date, startTime, durationMinutes: dur || 30,
      dentistId: effDentist || null, chairId: chairId || null, wholeBranch: !effDentist && !chairId,
      overlap: bookingCount > 0, label: description.trim(),
    });
  }, [date, startTime, dur, effDentist, chairId, bookingCount, description]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => () => onDraftChange?.(null), []); // eslint-disable-line react-hooks/exhaustive-deps

  // Retarget: an empty-slot click on the grid moves the block's start / column.
  const lastRetargetRef = useRef(retarget?.nonce ?? null); // ignore a retarget request left over from an earlier panel
  const applyRetarget = (s) => {
    setDate(s.day);
    setStartTime(slotTime(s));
    if (s.colType === 'dentist' && s.colId) { setAssigneeType('dentist'); setDentistId(s.colId); }
    if (s.colType === 'chair' && s.colId) setChairId(s.colId);
    baselineRef.current = {
      dentist: s.colType === 'dentist' && s.colId ? s.colId : baselineRef.current.dentist,
      chair: s.colType === 'chair' && s.colId ? s.colId : baselineRef.current.chair,
    };
  };
  useEffect(() => {
    if (!retarget || retarget.nonce === lastRetargetRef.current) return;
    lastRetargetRef.current = retarget.nonce;
    const s = retarget.slot;
    const curCol = s.colType === 'chair' ? chairId : s.colType === 'dentist' ? (assigneeType === 'dentist' ? dentistId : '') : '';
    const changes = s.day !== date || ((s.colType === 'chair' || s.colType === 'dentist') && (s.colId || '') !== curCol);
    if (dirty && changes) setMoveConfirm(s); else applyRetarget(s);
  }, [retarget]); // eslint-disable-line react-hooks/exhaustive-deps

  const handleSubmit = async () => {
    if (!date || !startTime) { setError('Select a date and start time.'); return; }
    if (!(Number(durationMinutes) > 0)) { setError('Enter a valid duration.'); return; }
    if (assigneeType === 'dentist' && !dentistId) { setError('Select a staff member.'); return; }

    setSubmitting(true);
    setError(null);

    const result = await createBlock({
      orgId,
      branchId,
      dentistId: assigneeType === 'dentist' ? dentistId : null,
      chairId: chairId || null,
      blockDate: date,
      startTime,
      durationMinutes: Number(durationMinutes),
      description,
      preventOnlineBooking,
      recurrenceFreq: repeat || null,
      recurrenceInterval: Number(recurrenceIntervalInput) || 1,
      recurrenceEndDate: repeat && endCondition === 'date' ? endDate : null,
      recurrenceCount: repeat && endCondition === 'count' ? Number(endCount) : null,
    });

    if (result.error) {
      setError(result.error.message || 'Failed to create block.');
      setSubmitting(false);
      return;
    }

    setSubmitting(false);
    onChairOnlyChange?.(assigneeType !== 'dentist' && !!chairId);
    onSuccess?.();
  };

  const reason = !date ? 'Pick a date' : !startTime ? 'Pick a start time'
    : !(Number(durationMinutes) > 0) ? 'Enter a duration'
    : assigneeType === 'dentist' && !dentistId ? 'Select a dentist' : '';

  const moveOverride = moveConfirm ? (
    <div role="alertdialog" aria-label="Move block" className="flex items-center gap-3">
      <p className="flex-1 min-w-0 text-[13px] text-text-primary">
        Move this block to {[formatShortDate(moveConfirm.day), format12h(slotTime(moveConfirm))].filter(Boolean).join(' · ')}?
      </p>
      <button type="button" onClick={() => setMoveConfirm(null)} className="h-9 px-3 text-[13px] font-body font-body-medium border border-border rounded-spa hover:bg-background whitespace-nowrap">Keep here</button>
      <button type="button" onClick={() => { applyRetarget(moveConfirm); setMoveConfirm(null); }} className="h-9 px-3 text-[13px] font-body font-body-medium bg-text-primary text-white rounded-spa hover:opacity-90 whitespace-nowrap">Move</button>
    </div>
  ) : null;

  return (
    <PanelShell
      variant={variant}
      title="Add block"
      onClose={onClose}
      dirty={dirty}
      guardRef={guardRef}
      busy={submitting}
      reason={reason}
      footerOverride={moveOverride}
      primary={{ label: submitting ? 'Adding…' : 'Add block', onClick: handleSubmit, disabled: !isFormComplete, loading: submitting }}
    >
      <TabBar tabs={TABS} value={activeTab} onChange={setActiveTab} />
      <FormBody>
        <InlineError message={error} />
        <InlineWarning message={bookingWarning} icon="CalendarClock" />

        {activeTab === 'details' && (
          <>
            <Segmented
              options={[['dentist', 'Dentist'], ['location', 'Whole clinic']]}
              value={assigneeType}
              onChange={setAssigneeType}
            />

            {assigneeType === 'dentist' && (
              <Field label="Dentist" required>
                <SelectField
                  placeholder="Select dentist..."
                  options={(dentists || []).map((t) => ({ value: t.id, label: t.name }))}
                  value={dentistId}
                  onChange={setDentistId}
                />
              </Field>
            )}

            <Field
              label="Chair (optional)"
              hint={assigneeType === 'location' && chairId ? 'Blocks this chair for any dentist (shown in Chair view).' : undefined}
            >
              <SelectField
                placeholder="No specific chair..."
                options={[{ value: '', label: 'No specific chair' }, ...(chairs || []).map((r) => ({ value: r.id, label: r.name }))]}
                value={chairId}
                onChange={setChairId}
              />
            </Field>

            <div className="grid grid-cols-2 gap-3">
              <DateField label="Date" required value={date} onChange={setDate} />
              <TimeField
                label="Start time"
                required
                value={startTime}
                onChange={setStartTime}
                fromTime={(branchHours?.openTime || '06:00').slice(0, 5)}
                toTime="23:50"
              />
            </div>

            <Field
              label="Duration (minutes)"
              required
              hint={startTime && dur ? `Opens back up at ${format12h(addMinutes(startTime, dur))}` : undefined}
            >
              <NumberInput min="5" step="5" value={durationMinutes} onChange={(e) => setDurationMinutes(e.target.value)} />
            </Field>

            <Field label="Description (optional)">
              <TextInput value={description} onChange={(e) => setDescription(e.target.value)} placeholder="e.g. Lunch break, chair sterilisation..." />
            </Field>

            <label className="flex items-center gap-2 text-[13px] font-body text-text-primary cursor-pointer">
              <input
                type="checkbox"
                checked={preventOnlineBooking}
                onChange={(e) => setPreventOnlineBooking(e.target.checked)}
                className="w-4 h-4 rounded border-border text-primary focus:ring-primary/30"
              />
              Prevent online bookings during this time
            </label>
          </>
        )}

        {activeTab === 'recurrence' && (
          <>
            <Field label="Repeat">
              <SelectField options={REPEAT_OPTIONS} value={repeat} onChange={setRepeat} />
            </Field>

            {repeat && (
              <>
                <Field label={`Every ${recurrenceIntervalInput || 1} ${repeat === 'daily' ? 'day(s)' : repeat === 'weekly' ? 'week(s)' : 'month(s)'}`}>
                  <NumberInput min="1" value={recurrenceIntervalInput} onChange={(e) => setRecurrenceIntervalInput(e.target.value)} />
                </Field>

                <Field label="Ends">
                  <SelectField options={END_CONDITION_OPTIONS} value={endCondition} onChange={setEndCondition} />
                </Field>

                {endCondition === 'date' && <DateField label="End date" value={endDate} onChange={setEndDate} min={date} />}

                {endCondition === 'count' && (
                  <Field label="Number of occurrences">
                    <NumberInput min="1" value={endCount} onChange={(e) => setEndCount(e.target.value)} />
                  </Field>
                )}
              </>
            )}
          </>
        )}
      </FormBody>
    </PanelShell>
  );
};

export default AddBlockModal;
