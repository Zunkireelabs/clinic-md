import React, { useState } from 'react';
import Icon from '../../../../components/AppIcon';
import Select from '../../../../components/ui/Select';
import Input from '../../../../components/ui/Input';
import Button from '../../../../components/ui/Button';
import { useOrg } from '../../../../contexts/OrgContext';
import { createBlock } from '../../../../services/api';
import { to12h } from '../../../../services/bookingTransformers';

// 'HH:MM' + minutes -> 'HH:MM', for the "ends at" preview next to the duration field.
function addMinutesToTime(timeStr, minutes) {
  const [h, m] = timeStr.split(':').map(Number);
  const total = h * 60 + m + minutes;
  const wrapped = ((total % 1440) + 1440) % 1440;
  return `${String(Math.floor(wrapped / 60)).padStart(2, '0')}:${String(wrapped % 60).padStart(2, '0')}`;
}

const TABS = [
  { id: 'details', label: 'Details' },
  { id: 'recurrence', label: 'Recurrence' },
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

// Two-tab modal for blocking time off on the Calendar — Details (who/when/why) and
// Recurrence (Repeat + end condition), matching the Fresha-style reference the request was
// scoped against. Tab-switcher visual pattern copied from ProductDetailDrawer.jsx.
const AddBlockModal = ({ branchId, slotInfo, dentists, chairs, onClose, onSuccess, onChairOnlyChange }) => {
  const { orgId } = useOrg();
  const [activeTab, setActiveTab] = useState('details');

  const [assigneeType, setAssigneeType] = useState(slotInfo?.colType === 'dentist' ? 'dentist' : 'location');
  const [dentistId, setDentistId] = useState(slotInfo?.colType === 'dentist' ? slotInfo.colId : '');
  const [chairId, setChairId] = useState(slotInfo?.colType === 'chair' ? slotInfo.colId : '');
  const [date, setDate] = useState(slotInfo?.day || '');
  const [startTime, setStartTime] = useState(
    slotInfo?.hour != null ? `${String(slotInfo.hour).padStart(2, '0')}:${String(slotInfo.minute ?? 0).padStart(2, '0')}` : ''
  );
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

  const isFormComplete = !!date && !!startTime && Number(durationMinutes) > 0
    && (assigneeType !== 'dentist' || !!dentistId);

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

  return (
    <div className="fixed inset-0 z-modal-overlay bg-black/50 flex items-center justify-center p-4" onClick={() => !submitting && onClose()}>
      <div className="bg-surface rounded-spa-lg shadow-spa-modal max-w-md w-full p-5 space-y-4" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between">
          <h3 className="font-heading font-heading-medium text-lg text-text-primary">Add Block</h3>
          <button onClick={() => !submitting && onClose()} className="p-1 rounded hover:bg-background">
            <Icon name="X" size={18} className="text-text-secondary" />
          </button>
        </div>

        <div className="flex gap-1 border-b border-border">
          {TABS.map((tab) => (
            <button
              key={tab.id}
              type="button"
              onClick={() => setActiveTab(tab.id)}
              className={`px-3 py-2 text-[13px] font-body font-body-medium spa-transition-fast border-b-2 -mb-[1px] ${
                activeTab === tab.id
                  ? 'border-text-primary text-text-primary'
                  : 'border-transparent text-text-secondary hover:text-text-primary'
              }`}
            >
              {tab.label}
            </button>
          ))}
        </div>

        {error && (
          <div className="flex items-center gap-2 p-3 bg-error/10 border border-error/20 rounded-spa text-error text-sm">
            <Icon name="AlertCircle" size={16} />
            <span>{error}</span>
          </div>
        )}

        {activeTab === 'details' && (
          <div className="space-y-3">
            <div className="flex rounded-spa border border-border p-0.5 bg-background w-fit">
              <button
                type="button"
                onClick={() => setAssigneeType('dentist')}
                className={`px-3 py-1.5 rounded text-sm font-body font-body-medium transition-colors ${
                  assigneeType === 'dentist' ? 'bg-text-primary text-white' : 'text-text-secondary hover:text-text-primary'
                }`}
              >
                Dentist
              </button>
              <button
                type="button"
                onClick={() => setAssigneeType('location')}
                className={`px-3 py-1.5 rounded text-sm font-body font-body-medium transition-colors ${
                  assigneeType === 'location' ? 'bg-text-primary text-white' : 'text-text-secondary hover:text-text-primary'
                }`}
              >
                Whole clinic
              </button>
            </div>

            {assigneeType === 'dentist' && (
              <Select
                label="Dentist"
                placeholder="Select dentist..."
                options={(dentists || []).map(t => ({ value: t.id, label: t.name }))}
                value={dentistId}
                onChange={setDentistId}
              />
            )}

            <Select
              label="Chair (optional)"
              placeholder="No specific chair..."
              options={(chairs || []).map(r => ({ value: r.id, label: r.name }))}
              value={chairId}
              onChange={setChairId}
            />
            {assigneeType === 'location' && chairId && (
              <p className="text-xs text-text-secondary -mt-1">Blocks this chair for any dentist (shown in Chair view).</p>
            )}

            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1">
                <label className="block font-body font-body-medium text-sm text-text-primary">Date</label>
                <input
                  type="date"
                  value={date}
                  onChange={(e) => setDate(e.target.value)}
                  className="w-full px-2 py-1.5 rounded-spa border border-border bg-surface font-data font-data-normal text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-text-primary/20"
                />
              </div>
              <div className="space-y-1">
                <label className="block font-body font-body-medium text-sm text-text-primary">Start Time</label>
                <input
                  type="time"
                  value={startTime}
                  onChange={(e) => setStartTime(e.target.value)}
                  className="w-full px-2 py-1.5 rounded-spa border border-border bg-surface font-data font-data-normal text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-text-primary/20"
                />
              </div>
            </div>

            <div className="space-y-1">
              <label className="block font-body font-body-medium text-sm text-text-primary">Duration (minutes)</label>
              <Input
                type="number"
                min="5"
                step="5"
                value={durationMinutes}
                onChange={(e) => setDurationMinutes(e.target.value)}
              />
              {startTime && Number(durationMinutes) > 0 && (
                <p className="text-xs text-text-secondary">
                  Opens back up at <span className="font-data font-data-medium text-text-primary">{to12h(addMinutesToTime(startTime, Number(durationMinutes)))}</span>
                </p>
              )}
            </div>

            <div className="space-y-1">
              <label className="block font-body font-body-medium text-sm text-text-primary">Description (optional)</label>
              <Input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="e.g. Lunch break, chair sterilisation..." />
            </div>

            <label className="flex items-center gap-2 text-sm font-body text-text-primary cursor-pointer">
              <input
                type="checkbox"
                checked={preventOnlineBooking}
                onChange={(e) => setPreventOnlineBooking(e.target.checked)}
                className="rounded border-border"
              />
              Prevent online bookings during this time?
            </label>
          </div>
        )}

        {activeTab === 'recurrence' && (
          <div className="space-y-3">
            <Select label="Repeat" options={REPEAT_OPTIONS} value={repeat} onChange={setRepeat} />

            {repeat && (
              <>
                <div className="space-y-1">
                  <label className="block font-body font-body-medium text-sm text-text-primary">
                    Every {recurrenceIntervalInput || 1} {repeat === 'daily' ? 'day(s)' : repeat === 'weekly' ? 'week(s)' : 'month(s)'}
                  </label>
                  <Input type="number" min="1" value={recurrenceIntervalInput} onChange={(e) => setRecurrenceIntervalInput(e.target.value)} />
                </div>

                <Select label="Ends" options={END_CONDITION_OPTIONS} value={endCondition} onChange={setEndCondition} />

                {endCondition === 'date' && (
                  <div className="space-y-1">
                    <label className="block font-body font-body-medium text-sm text-text-primary">End date</label>
                    <input
                      type="date"
                      value={endDate}
                      onChange={(e) => setEndDate(e.target.value)}
                      className="w-full px-2 py-1.5 rounded-spa border border-border bg-surface font-data font-data-normal text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-text-primary/20"
                    />
                  </div>
                )}

                {endCondition === 'count' && (
                  <div className="space-y-1">
                    <label className="block font-body font-body-medium text-sm text-text-primary">Number of occurrences</label>
                    <Input type="number" min="1" value={endCount} onChange={(e) => setEndCount(e.target.value)} />
                  </div>
                )}
              </>
            )}
          </div>
        )}

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="ghost" size="sm" onClick={onClose} disabled={submitting}>Cancel</Button>
          <Button variant="primary" size="sm" onClick={handleSubmit} loading={submitting} disabled={!isFormComplete}>
            Add Block
          </Button>
        </div>
      </div>
    </div>
  );
};

export default AddBlockModal;
