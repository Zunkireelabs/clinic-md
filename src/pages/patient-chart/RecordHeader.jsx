import React, { useEffect } from 'react';
import Icon from '../../components/AppIcon';
import { formatPhoneDisplay } from '../../utils/phone';
import { initials, monthYear } from '../../utils/patientDirectory';
import { InClinicTag } from '../branch-manager-dashboard/components/CRM/PatientPanel';

const npr = (n) => `NPR ${Number(n || 0).toLocaleString('en-IN')}`;

// Breadcrumb + prev/next (when the list passed its ordered ids) and the record header with its actions.
const RecordHeader = ({ customer, patient, ids, customerId, onBack, onGoTo, readOnly, canDuplicates, onNewBooking, onCollect, onDuplicates }) => {
  const index = ids ? ids.indexOf(customerId) : -1;
  const hasPager = index >= 0;
  const prev = hasPager && index > 0 ? ids[index - 1] : null;
  const next = hasPager && index < ids.length - 1 ? ids[index + 1] : null;

  // k / j: previous / next patient, unless a field has focus.
  useEffect(() => {
    if (!hasPager) return undefined;
    const onKey = (e) => {
      const t = e.target;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable)) return;
      if (e.key === 'k' && prev) onGoTo(prev);
      if (e.key === 'j' && next) onGoTo(next);
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [hasPager, prev, next, onGoTo]);

  const meta = [formatPhoneDisplay(customer.phone), customer.email, customer.gender, customer.created_at && `Patient since ${monthYear(customer.created_at)}`].filter(Boolean);
  const arrow = (dir, target) => (
    <button type="button" disabled={!target} onClick={() => target && onGoTo(target)} aria-label={dir === 'up' ? 'Previous patient' : 'Next patient'}
      className="w-7 h-7 border border-border rounded-md grid place-items-center text-[#515152] disabled:opacity-40 hover:bg-[#FAFAFB]">
      <Icon name={dir === 'up' ? 'ArrowUp' : 'ArrowDown'} size={14} />
    </button>
  );

  return (
    <>
      {(
        <div className="flex items-center justify-between text-[13px]">
          <nav aria-label="Breadcrumb" className="flex items-center gap-2 text-[#8A8A90]">
            <button type="button" onClick={onBack} className="inline-flex items-center gap-1 hover:text-text-primary"><Icon name="ChevronLeft" size={14} />Patients</button>
            <span>/</span>
            <span className="text-text-primary font-medium truncate">{customer.full_name}</span>
          </nav>
          {hasPager && (
            <div className="flex items-center gap-2 text-[#8A8A90]">
              <span className="tabular-nums">{index + 1} of {ids.length}</span>{arrow('up', prev)}{arrow('down', next)}
            </div>
          )}
        </div>
      )}
      <div className={`flex items-center gap-4 flex-wrap mt-5`}>
        <div className="w-14 h-14 rounded-full bg-[#F1F1F3] text-[#4A4A4F] text-[18px] font-semibold grid place-items-center flex-shrink-0">{initials(customer.full_name)}</div>
        <div className="min-w-0 flex-1">
          <h1 className="text-[24px] font-semibold tracking-[-0.5px] flex items-center gap-2.5 leading-tight text-text-primary">
            <span className="truncate">{customer.full_name}</span>
            {patient.inClinic ? <InClinicTag /> : patient.isFirstTime && <span className="h-5 rounded-full px-[7px] text-[11.5px] font-medium inline-flex items-center bg-[#F3EEFF] text-[#5B21B6]">New</span>}
          </h1>
          <p className="text-[13px] text-[#515152] mt-1 flex flex-wrap gap-x-3 gap-y-0.5">{meta.map((m, i) => <span key={i} className={i === 1 ? 'break-all' : ''}>{m}</span>)}</p>
        </div>
        {!readOnly && (
          <div className="flex items-center gap-2">
            <Menu canDuplicates={canDuplicates} onDuplicates={onDuplicates} />
            {patient.balance > 0 && <button type="button" onClick={onCollect} className="h-8 px-3 rounded-md border border-border bg-white text-[13px] font-medium hover:bg-[#FAFAFB]">Collect {npr(patient.balance)}</button>}
            <button type="button" onClick={onNewBooking} className="h-8 px-3 rounded-md bg-primary text-white text-[13px] font-medium inline-flex items-center gap-1.5 shadow-[0_1px_2px_rgba(123,47,247,.25),inset_0_1px_0_rgba(255,255,255,.15)] hover:opacity-95">
              <Icon name="Plus" size={15} />New booking
            </button>
          </div>
        )}
      </div>
    </>
  );
};

// ⋯ menu: only "Check for duplicates" exists today (there is no edit-customer flow in the app).
const Menu = ({ canDuplicates, onDuplicates }) => {
  const [open, setOpen] = React.useState(false);
  const ref = React.useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const close = (e) => { if (!ref.current?.contains(e.target)) setOpen(false); };
    const esc = (e) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', close); document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('mousedown', close); document.removeEventListener('keydown', esc); };
  }, [open]);
  if (!canDuplicates) return null;
  return (
    <div className="relative" ref={ref}>
      <button type="button" aria-label="More actions" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen((o) => !o)} className="w-8 h-8 border border-border rounded-md grid place-items-center text-[#515152] hover:bg-[#FAFAFB]"><Icon name="MoreHorizontal" size={16} /></button>
      {open && (
        <div role="menu" className="absolute right-0 top-9 z-30 min-w-[200px] bg-white border border-border rounded-lg shadow-[0_8px_24px_rgba(14,13,12,.1)] py-1">
          <button type="button" role="menuitem" onClick={() => { setOpen(false); onDuplicates(); }} className="w-full text-left px-3 py-1.5 text-[13px] hover:bg-[#FAFAFB]">Check for duplicates</button>
        </div>
      )}
    </div>
  );
};

export default RecordHeader;
