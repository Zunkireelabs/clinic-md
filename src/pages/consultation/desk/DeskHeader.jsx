import React, { useEffect, useRef, useState } from 'react';
import Icon from '../../../components/AppIcon';
import { InClinicTag } from '../../branch-manager-dashboard/components/CRM/PatientPanel';

const Menu = ({ items }) => {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const close = (e) => { if (!ref.current?.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [open]);
  return (
    <div className="relative" ref={ref}>
      <button type="button" aria-label="More actions" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen((o) => !o)} className="w-8 h-8 border border-border rounded-md grid place-items-center text-[#515152] hover:bg-[#FAFAFB]"><Icon name="MoreHorizontal" size={16} /></button>
      {open && <div role="menu" className="absolute right-0 top-9 z-30 min-w-[190px] bg-white border border-border rounded-lg shadow-[0_8px_24px_rgba(14,13,12,.1)] py-1">
        {items.map((it) => <button key={it.label} role="menuitem" type="button" disabled={it.disabled} onClick={() => { setOpen(false); it.onClick(); }} className="w-full text-left px-3 py-1.5 text-[13px] hover:bg-[#FAFAFB] disabled:opacity-50">{it.label}</button>)}
      </div>}
    </div>
  );
};

// Breadcrumb + patient identity + sync state + the three actions (Continue on phone, Save to chart / Edit note + Complete visit).
const DeskHeader = ({
  patientName, inClinic, meta, onBack, syncText, syncKind, onContinuePhone, stage, canSave, saving, onSave, onEdit,
  canComplete, completing, onComplete, readOnly, menuItems,
}) => (
  <>
    <nav aria-label="Breadcrumb" className="flex items-center gap-2 text-[13px] text-[#8A8A90]">
      <button type="button" onClick={onBack} className="inline-flex items-center gap-1 hover:text-text-primary"><Icon name="ChevronLeft" size={14} />Calendar</button>
      <span>/</span><span className="text-text-primary font-medium">Consultation</span>
    </nav>
    <div className="mt-4 flex items-start justify-between gap-4 flex-wrap">
      <div className="min-w-0">
        <h1 className="text-[24px] font-semibold tracking-[-0.5px] leading-tight flex items-center gap-2.5"><span className="truncate">{patientName}</span>{inClinic && <InClinicTag />}</h1>
        <p className="text-[13px] text-[#8A8A90] mt-1">{meta}</p>
      </div>
      <div className="flex items-center gap-2 flex-wrap">
        {syncText && <span className={`text-[12.5px] inline-flex items-center gap-1.5 mr-1 ${syncKind === 'error' ? 'text-[#B42318]' : 'text-[#8A8A90]'}`}>
          <span className={`w-1.5 h-1.5 rounded-full ${syncKind === 'error' ? 'bg-[#B42318]' : syncKind === 'saving' ? 'bg-[#F59E0B]' : 'bg-[#1F9D6C]'}`} />{syncText}</span>}
        <button type="button" onClick={onContinuePhone} className="h-8 px-3 rounded-md border border-border bg-white text-[13px] font-medium inline-flex items-center gap-1.5 hover:bg-[#FAFAFB]"><Icon name="Smartphone" size={14} />Continue on phone</button>
        {!readOnly && stage === 'saved' ? (
          <>
            <button type="button" onClick={onEdit} className="h-8 px-3 rounded-md border border-border bg-white text-[13px] font-medium hover:bg-[#FAFAFB]">Edit note</button>
            {canComplete && <button type="button" onClick={onComplete} disabled={completing} className="h-8 px-3 rounded-md bg-primary text-white text-[13px] font-medium inline-flex items-center gap-1.5 disabled:opacity-60 shadow-[0_1px_2px_rgba(123,47,247,.25)]"><Icon name="Check" size={14} />{completing ? 'Completing…' : 'Complete visit'}</button>}
          </>
        ) : !readOnly && (
          <button type="button" onClick={onSave} disabled={!canSave || saving} className="h-8 px-3 rounded-md bg-primary text-white text-[13px] font-medium inline-flex items-center gap-1.5 disabled:opacity-40 shadow-[0_1px_2px_rgba(123,47,247,.25)]"><Icon name="Check" size={14} />{saving ? 'Saving…' : 'Save to chart'}</button>
        )}
        {menuItems?.length > 0 && <Menu items={menuItems} />}
      </div>
    </div>
  </>
);

export default DeskHeader;
