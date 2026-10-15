import React, { useEffect, useState } from 'react';
import Icon from '../../../../components/AppIcon';
import SidePanel from '../../../../components/ui/SidePanel';
import UnclosedNudge from '../../../../components/ui/UnclosedNudge';
import { getPatientPanelDetail } from '../../../../services/api';
import { formatPhoneDisplay } from '../../../../utils/phone';
import { CONSULTATION_ENABLED } from '../../../../lib/featureFlags';
import { initials, monthYear, dayBlock, relativeDayLabel } from '../../../../utils/patientDirectory';

const npr = (n) => `NPR ${Number(n || 0).toLocaleString('en-IN')}`;
const range = (b) => (b.end ? `${b.start} – ${b.end}` : b.start);

const Label = ({ children, action }) => (
  <div className="flex justify-between items-center mb-2 text-[11.5px] font-medium uppercase tracking-[.05em] text-[#8A8A90]">
    <span>{children}</span>{action}
  </div>
);

const DateBlock = ({ iso }) => {
  const d = dayBlock(iso);
  return (
    <div className="w-10 text-center rounded-md bg-[#FAFAFB] border border-[#E9E9EC] py-1 flex-shrink-0">
      <span className="block text-[10px] font-semibold uppercase text-[#8A8A90] leading-tight">{d.dow}</span>
      <b className="block text-[15px] font-semibold tracking-tight leading-tight">{d.day}</b>
    </div>
  );
};

const StatusPill = ({ status }) => (
  <span className={`h-5 px-2 rounded-full text-[11.5px] font-medium inline-flex items-center ${status === 'Confirmed' ? 'bg-[#EEF4FF] text-[#1D4ED8]' : 'bg-[#F1F1F3] text-[#4A4A4F]'}`}>{status}</span>
);

const SkeletonCard = () => <div className="h-[66px] rounded-lg border border-[#E9E9EC] animate-pulse bg-[#FAFAFB]" />;

const PatientPanel = ({ patient, today, readOnly, canCollect, onClose, onNewBooking, onCollect, onOpenChart, onOpenBooking, onOpenConsultation, onClosed }) => {
  const [detail, setDetail] = useState(null);
  const [failed, setFailed] = useState(false);
  const id = patient?.id;

  useEffect(() => {
    if (!id) return undefined;
    let cancelled = false;
    setDetail(null);
    setFailed(false);
    getPatientPanelDetail({ customerId: id }).then(({ data, error }) => {
      if (cancelled) return;
      if (error) setFailed(true); else setDetail(data);
    });
    return () => { cancelled = true; };
  }, [id]);

  // Keep the last patient rendered while the panel slides out.
  const [shown, setShown] = useState(patient);
  useEffect(() => { if (patient) setShown(patient); }, [patient]);
  const p = patient || shown;

  const header = p && (
    <div className="px-5 pt-[18px] pb-4 border-b border-[#E9E9EC]">
      <div className="flex items-center justify-between text-[12px] text-[#8A8A90] mb-3.5">
        <span>Patient</span>
        <div className="flex gap-1">
          <button type="button" onClick={onOpenChart} aria-label="Open full chart" className="w-7 h-7 rounded-md grid place-items-center hover:bg-background"><Icon name="Maximize2" size={15} /></button>
          <button type="button" onClick={onClose} aria-label="Close" className="w-7 h-7 rounded-md grid place-items-center hover:bg-background"><Icon name="X" size={16} /></button>
        </div>
      </div>
      <div className="flex gap-3.5 items-center">
        <div className="w-11 h-11 rounded-full bg-[#F1F1F3] text-[#4A4A4F] text-[15px] font-semibold grid place-items-center flex-shrink-0">{initials(p.fullName)}</div>
        <div className="min-w-0">
          <h3 id="patient-panel-title" className="text-[17px] font-semibold tracking-[-0.3px] flex items-center gap-2 leading-tight">
            <span className="truncate">{p.fullName}</span>
            {p.inClinic && <InClinicTag />}
          </h3>
          <p className="text-[12.5px] text-[#8A8A90] mt-0.5 truncate">{[formatPhoneDisplay(p.phone), p.createdAt && `Patient since ${monthYear(p.createdAt)}`].filter(Boolean).join(' · ')}</p>
        </div>
      </div>
      <div className="flex gap-2 mt-4">
        {!readOnly && (
          <button type="button" onClick={onNewBooking} className="h-8 px-3 rounded-md bg-primary text-white text-[13px] font-medium inline-flex items-center gap-1.5 shadow-[0_1px_2px_rgba(123,47,247,.25)] hover:opacity-95">
            <Icon name="Plus" size={15} />New booking
          </button>
        )}
        {!readOnly && canCollect && p.balance > 0 && (
          <button type="button" onClick={onCollect} className="h-8 px-3 rounded-md border border-[#E9E9EC] bg-white text-[13px] font-medium hover:bg-[#FAFAFB]">Collect {npr(p.balance)}</button>
        )}
        <button type="button" onClick={onOpenChart} className="h-8 px-3 rounded-md border border-[#E9E9EC] bg-white text-[13px] font-medium inline-flex items-center gap-1.5 ml-auto hover:bg-[#FAFAFB]">
          <Icon name="FileText" size={14} />Open chart
        </button>
      </div>
    </div>
  );

  return (
    <SidePanel isOpen={!!patient} onClose={onClose} title="Patient" titleId="patient-panel-title" width="460px" header={header}>
      {p && (
        <div className="px-5 py-[18px] flex flex-col gap-[22px]">
          <UnclosedNudge unclosed={p.unclosed} stale={p.staleInProgress} readOnly={readOnly} onChanged={onClosed} onSeeAll={onOpenChart} />
          {failed && <p className="text-[13px] text-[#B45309]">Couldn’t load this patient’s appointments. Close and reopen to retry.</p>}

          {detail?.now && (
            <section>
              <Label>Now</Label>
              <div role="link" tabIndex={0} onClick={() => onOpenBooking?.(detail.now.id)} onKeyDown={(e) => { if (e.key === 'Enter') onOpenBooking?.(detail.now.id); }} className="border border-[#E9E9EC] rounded-lg px-3.5 py-3 flex items-center gap-3 cursor-pointer hover:bg-[#FAFAFB]">
                <DateBlock iso={detail.now.date} />
                <div className="min-w-0 flex-1">
                  <p className="text-[13.5px] font-medium truncate">{detail.now.treatment} <span className="text-[#515152] font-normal">· in progress</span></p>
                  <p className="text-[12.5px] text-[#8A8A90] truncate">{range(detail.now)}{detail.now.dentist ? ` · ${detail.now.dentist}` : ''}</p>
                </div>
                {CONSULTATION_ENABLED && !readOnly && (
                  <button type="button" onClick={(e) => { e.stopPropagation(); onOpenConsultation(detail.now.id); }} className="h-[26px] px-2.5 rounded-md border border-[#E9E9EC] bg-white text-[12px] font-medium inline-flex items-center gap-1.5 hover:bg-[#FAFAFB]">
                    <Icon name="Mic" size={13} />Consultation
                  </button>
                )}
              </div>
            </section>
          )}

          <section>
            <Label>Upcoming</Label>
            {!detail && !failed ? <SkeletonCard /> : detail?.upcoming ? (
              <div role="link" tabIndex={0} onClick={() => onOpenBooking?.(detail.upcoming.id)} onKeyDown={(e) => { if (e.key === 'Enter') onOpenBooking?.(detail.upcoming.id); }} className="border border-[#E9E9EC] rounded-lg px-3.5 py-3 flex items-center gap-3 cursor-pointer hover:bg-[#FAFAFB]">
                <DateBlock iso={detail.upcoming.date} />
                <div className="min-w-0 flex-1">
                  <p className="text-[13.5px] font-medium truncate">{detail.upcoming.treatment}</p>
                  <p className="text-[12.5px] text-[#8A8A90] break-words">{relativeDayLabel(detail.upcoming.date, today)} · {range(detail.upcoming)}{detail.upcoming.dentist ? ` · ${detail.upcoming.dentist}` : ''}</p>
                </div>
                <div className="text-right flex-shrink-0">
                  <StatusPill status={detail.upcoming.status} />
                  <p className="text-[12px] text-[#8A8A90] mt-1 tabular-nums">{detail.upcoming.money.deposit > 0 ? `${npr(detail.upcoming.money.deposit)} paid · ${Number(detail.upcoming.money.upcoming).toLocaleString('en-IN')} at visit` : npr(detail.upcoming.money.price)}</p>
                </div>
              </div>
            ) : <p className="text-[13px] text-[#B4B4BA]">No appointment</p>}
          </section>

          <div className="grid grid-cols-3 border border-[#E9E9EC] rounded-lg">
            <Stat label="Visits" value={p.visits} />
            <Stat label="Balance" value={p.balance > 0 ? npr(p.balance) : p.upcoming > 0 ? 'NPR 0' : '—'} amber={p.balance > 0} divider />
            <Stat label="Paid to date" value={npr(p.lifetime)} divider />
          </div>

          {balanceSub(p) && <p className="text-[12px] text-[#8A8A90] -mt-4">{balanceSub(p)}</p>}

          <section>
            <Label action={<button type="button" onClick={onOpenChart} className="normal-case tracking-normal text-[#515152] font-medium hover:text-[#0E0D0C]">View all</button>}>Recent visits</Label>
            {!detail && !failed ? <div className="space-y-2"><SkeletonCard /><SkeletonCard /></div> : detail?.recent.length ? (
              <div className="flex flex-col">
                {detail.recent.map((v) => (
                  <div key={v.id} className="flex justify-between items-center py-[9px] border-b border-[#F1F1F3] last:border-0 text-[13px] gap-3">
                    <span className="min-w-0 truncate"><span className="font-medium">{v.treatment}</span>{v.dentist && <span className="text-[#8A8A90]"> · {v.dentist}</span>}</span>
                    <span className="text-[#8A8A90] flex-shrink-0">{relativeDayLabel(v.date, today)}</span>
                  </div>
                ))}
              </div>
            ) : <p className="text-[13px] text-[#B4B4BA]">No visits yet</p>}
          </section>

          <section>
            <Label>Contact</Label>
            <dl className="grid grid-cols-[90px_1fr] gap-y-2 text-[13px]">
              <dt className="text-[#8A8A90]">Phone</dt><dd className="break-all">{formatPhoneDisplay(p.phone) || '—'}</dd>
              <dt className="text-[#8A8A90]">Email</dt><dd className="break-all">{p.email || '—'}</dd>
              <dt className="text-[#8A8A90]">Gender</dt><dd>{p.gender || '—'}</dd>
            </dl>
          </section>
        </div>
      )}
    </SidePanel>
  );
};

/** Grey subline under the Balance figure: whichever of unpaid visits / upcoming / deposit / credit apply. */
export const balanceSub = (p) => [
  p.balance > 0 && `${p.unpaidVisits} unpaid visit${p.unpaidVisits === 1 ? '' : 's'}`,
  p.upcoming > 0 && `+ ${npr(p.upcoming)} upcoming`,
  p.deposit > 0 && `${npr(p.deposit)} deposit held`,
  p.credit > 0 && `${npr(p.credit)} credit`,
].filter(Boolean).join(' · ');

const Stat = ({ label, value, amber, divider, sub }) => (
  <div className={`px-3.5 py-3 ${divider ? 'border-l border-[#E9E9EC]' : ''}`}>
    <span className="text-[12px] text-[#8A8A90]">{label}</span>
    <b className={`block text-[16px] font-semibold tracking-[-0.3px] mt-[3px] tabular-nums ${amber ? 'text-[#B45309]' : ''}`}>{value}</b>
    {sub && <span className="block text-[11.5px] text-[#8A8A90] mt-0.5 leading-snug">{sub}</span>}
  </div>
);

export const InClinicTag = () => (
  <span className="h-5 rounded-full pl-1.5 pr-[7px] text-[11.5px] font-medium inline-flex items-center gap-[5px] bg-[#ECFDF5] text-[#137A53] flex-shrink-0">
    <i className="w-1.5 h-1.5 rounded-full bg-[#1F9D6C] shadow-[0_0_0_3px_rgba(31,157,108,.18)]" />In clinic
  </span>
);

export default PatientPanel;
