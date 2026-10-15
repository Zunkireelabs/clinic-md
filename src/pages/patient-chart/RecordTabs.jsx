import React, { useEffect, useRef, useState, useCallback } from 'react';
import Icon from '../../components/AppIcon';
import NoteText from '../../components/ui/NoteText';
import VisitRecord from './VisitRecord';
import { getConsultationFileUrl } from '../../services/api';
import { parseSummarySections } from '../../utils/summarySections';
import { consultationDoctor, capturedLine } from '../../utils/patientRecord';
import { shortDate } from '../../utils/patientDirectory';
import { classifyBooking } from '../../utils/bookingMoney';
import { generateConsultationPdf } from '../../utils/consultationReport';
import { rowToReportData } from '../../utils/consultationHistory';

const npr = (n) => `NPR ${Number(n || 0).toLocaleString('en-IN')}`;
const fmt = (d) => new Date(`${String(d).slice(0, 10)}T00:00:00`).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
const Empty = ({ children }) => <p className="text-center text-[13px] text-[#8A8A90] py-14">{children}</p>;
const Card = ({ children, className = '' }) => <div className={`border border-border rounded-lg bg-white ${className}`}>{children}</div>;

const STATUS = { 'In-Progress': 'In progress', 'No Show': 'No show' };

// ── Visits: hairline rows, expandable into the full visit record ─────────────────────────────
// Short money label for a booking row, from bookingMoney.
const moneyLabel = (b, today) => {
  const m = classifyBooking(b, { today });
  if (m.kind === 'void') return '';
  if (m.kind === 'unclosed') return 'Not closed';
  if (m.due > 0) return `${npr(m.due)} due`;
  if (m.upcoming > 0) return m.deposit > 0 ? `${npr(m.upcoming)} upcoming · deposit ${npr(m.deposit)}` : `${npr(m.upcoming)} upcoming`;
  return m.price > 0 ? 'Paid' : '';
};

export const VisitsTab = ({ bookings, consultations, notes, customerName, onOpenBooking, today }) => {
  const [open, setOpen] = useState({});
  const byBooking = {};
  consultations.forEach((c) => { if (!byBooking[c.booking_id]) byBooking[c.booking_id] = c; });
  if (!bookings.length) return <Empty>No visits yet.</Empty>;
  return (
    <Card>
      <ul>
        {bookings.map((b) => {
          const isOpen = !!open[b.id];
          const visit = { id: b.id, bookingNumber: b.booking_number, date: b.date, treatmentName: b.treatment_name_snapshot || '—', dentistName: b.dentist_name_snapshot || 'Unassigned' };
          return (
            <li key={b.id} className="border-b border-[#F1F1F3] last:border-0">
              <button type="button" aria-expanded={isOpen} onClick={() => setOpen((m) => ({ ...m, [b.id]: !isOpen }))} className="w-full text-left px-4 py-3 flex items-center gap-3 hover:bg-[#FAFAFB]">
                <span className="w-24 text-[12.5px] text-[#8A8A90] flex-shrink-0 tabular-nums">{fmt(b.date)}</span>
                <span className="min-w-0 flex-1">
                  <span className="block text-[13.5px] font-medium truncate">{visit.treatmentName}</span>
                  <span className="block text-[12.5px] text-[#8A8A90] truncate">{visit.dentistName} · {b.booking_number}</span>
                </span>
                <span className="text-[12.5px] text-[#515152] hidden sm:block">{STATUS[b.status] || b.status}</span>
                <span className="text-[12.5px] text-[#8A8A90] tabular-nums w-44 text-right hidden sm:block">{moneyLabel(b, today)}</span>
                <Icon name="ChevronDown" size={16} className={`text-[#8A8A90] transition-transform ${isOpen ? 'rotate-180' : ''}`} />
              </button>
              {isOpen && (
                <div className="border-t border-[#F1F1F3]">
                  <VisitRecord visit={visit} consultation={byBooking[b.id]} customerName={customerName} notes={notes.filter((n) => n.bookingId === b.id)} />
                  {onOpenBooking && <div className="px-4 pb-3"><button type="button" onClick={() => onOpenBooking(b.id)} className="text-[12.5px] text-[#515152] hover:text-text-primary underline">Open in calendar</button></div>}
                </div>
              )}
            </li>
          );
        })}
      </ul>
    </Card>
  );
};

// ── Clinical notes: consultations, newest first ──────────────────────────────────────────────
const Section = ({ label, children }) => (children ? (
  <div><h4 className="text-[11.5px] font-medium uppercase tracking-[.05em] text-[#8A8A90] mb-1">{label}</h4><NoteText text={children} className="text-[13.5px]" /></div>
) : null);

const ConsultationCard = ({ c, focus, customerName }) => {
  const ref = useRef(null);
  const [open, setOpen] = useState(!!focus);
  useEffect(() => { if (focus) { setOpen(true); ref.current?.scrollIntoView({ block: 'center' }); } }, [focus]);
  const s = parseSummarySections(c.final_summary || c.preliminary_summary || '');
  const structured = s.complaint || s.history || s.findings || s.diagnosis || s.plan || s.followup;
  const report = () => generateConsultationPdf(rowToReportData({ ...c, patient_name: c.patient_name || customerName }));
  return (
    <Card className={focus ? 'ring-2 ring-primary/30' : ''}>
      <div ref={ref}>
        <button type="button" aria-expanded={open} onClick={() => setOpen((o) => !o)} className="w-full text-left px-4 py-3 flex items-center gap-3 hover:bg-[#FAFAFB]">
          <span className="w-24 text-[12.5px] text-[#8A8A90] flex-shrink-0">{fmt(c.session_date || c.created_at)}</span>
          <span className="min-w-0 flex-1">
            <span className="block text-[13.5px] font-medium">Consultation notes</span>
            <span className="block text-[12.5px] text-[#8A8A90] truncate">{[capturedLine(c), consultationDoctor(c)].filter(Boolean).join(' · ')}</span>
          </span>
          <Icon name="ChevronDown" size={16} className={`text-[#8A8A90] transition-transform ${open ? 'rotate-180' : ''}`} />
        </button>
        {open && (
          <div className="px-4 pb-4 pt-3 border-t border-[#F1F1F3] space-y-4">
            {structured ? (<>
              <Section label="Chief complaint">{s.complaint}</Section>
              <Section label="History">{s.history}</Section>
              <Section label="Findings">{[s.findings, c.xray_analysis || s.xray, c.photo_analysis || s.photo].filter(Boolean).join('\n\n')}</Section>
              <Section label="Assessment">{s.diagnosis}</Section>
              <Section label="Plan">{s.plan}</Section>
              <Section label="Follow-up">{s.followup}</Section>
            </>) : <Section label="Summary">{c.final_summary || c.preliminary_summary}</Section>}
            <Section label="Doctor's notes">{c.doctor_notes}</Section>
            <Section label="Private notes (staff only)">{c.additional_notes}</Section>
            {c.transcript && <details className="text-[13px]"><summary className="cursor-pointer text-[#515152]">Transcript</summary><p className="mt-2 whitespace-pre-wrap text-[#515152]">{c.transcript}</p></details>}
            {!structured && !c.final_summary && !c.preliminary_summary && !c.doctor_notes && !c.additional_notes && !c.transcript && <p className="text-[13px] text-[#8A8A90]">Nothing written down for this consultation.</p>}
            <button type="button" onClick={report} className="h-7 px-2.5 rounded-md border border-border bg-white text-[12.5px] font-medium inline-flex items-center gap-1.5 hover:bg-[#FAFAFB]"><Icon name="FileText" size={13} />Download PDF report</button>
          </div>
        )}
      </div>
    </Card>
  );
};

export const ClinicalNotesTab = ({ consultations, focusId, customerName }) => (
  consultations.length === 0 ? <Empty>No consultation recorded yet.</Empty>
    : <div className="space-y-3">{consultations.map((c) => <ConsultationCard key={c.id} c={c} focus={c.id === focusId} customerName={customerName} />)}</div>
);

// ── X-rays & photos: thumbnails grouped by day, with a lightbox ──────────────────────────────
const useSignedUrl = (path) => {
  const [url, setUrl] = useState(null);
  useEffect(() => {
    let off = false;
    getConsultationFileUrl('image', path).then(({ url: u }) => { if (!off) setUrl(u); });
    return () => { off = true; };
  }, [path]);
  return url;
};

const Thumb = ({ item, onOpen }) => {
  const url = useSignedUrl(item.path);
  return (
    <button type="button" onClick={onOpen} aria-label={`Open ${item.label}`} className="relative w-32 h-32 rounded-lg border border-border bg-[#FAFAFB] overflow-hidden grid place-items-center hover:ring-2 hover:ring-primary/30">
      {url ? <img src={url} alt={item.label} loading="lazy" className="w-full h-full object-cover" /> : <Icon name="Image" size={20} className="text-[#B4B4BA]" />}
      <span className="absolute left-1.5 bottom-1.5 h-5 px-1.5 rounded bg-black/60 text-white text-[11px] font-medium inline-flex items-center">{item.label}</span>
    </button>
  );
};

const Lightbox = ({ items, index, onClose, onIndex }) => {
  const item = items[index];
  const url = useSignedUrl(item.path);
  useEffect(() => {
    const onKey = (e) => {
      if (e.key === 'Escape') { e.preventDefault(); onClose(); }
      if (e.key === 'ArrowRight' && index < items.length - 1) onIndex(index + 1);
      if (e.key === 'ArrowLeft' && index > 0) onIndex(index - 1);
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [index, items.length, onClose, onIndex]);
  return (
    <div role="dialog" aria-modal="true" aria-label={`${item.label} viewer`} className="fixed inset-0 z-modal-overlay bg-black/85 flex items-center justify-center p-6" onClick={onClose}>
      <button type="button" onClick={onClose} aria-label="Close" className="absolute top-4 right-4 w-9 h-9 rounded-md grid place-items-center text-white/80 hover:bg-white/10"><Icon name="X" size={20} /></button>
      {index > 0 && <button type="button" aria-label="Previous image" onClick={(e) => { e.stopPropagation(); onIndex(index - 1); }} className="absolute left-4 w-9 h-9 rounded-md grid place-items-center text-white/80 hover:bg-white/10"><Icon name="ChevronLeft" size={22} /></button>}
      {index < items.length - 1 && <button type="button" aria-label="Next image" onClick={(e) => { e.stopPropagation(); onIndex(index + 1); }} className="absolute right-4 w-9 h-9 rounded-md grid place-items-center text-white/80 hover:bg-white/10"><Icon name="ChevronRight" size={22} /></button>}
      <div onClick={(e) => e.stopPropagation()} className="max-w-full max-h-full text-center">
        {url ? <img src={url} alt={item.label} className="max-w-[90vw] max-h-[82vh] object-contain rounded" /> : <div className="w-64 h-64 grid place-items-center text-white/60">Loading…</div>}
        <p className="text-white/80 text-[13px] mt-2">{item.label} · {index + 1} of {items.length}</p>
      </div>
    </div>
  );
};

export const MediaTab = ({ groups }) => {
  const [open, setOpen] = useState(null);
  const flat = groups.flatMap((g) => g.items);
  const close = useCallback(() => setOpen(null), []);
  if (!flat.length) return <Empty>No X-rays or photos yet.</Empty>;
  let n = -1;
  return (
    <div className="space-y-6">
      {groups.map((g) => (
        <section key={g.date}>
          <h3 className="text-[12.5px] font-medium text-[#8A8A90] mb-2">{shortDate(g.date)} {g.date.slice(0, 4)}</h3>
          <div className="flex flex-wrap gap-2.5">{g.items.map((it) => { n += 1; const idx = n; return <Thumb key={`${it.path}`} item={it} onOpen={() => setOpen(idx)} />; })}</div>
        </section>
      ))}
      {open != null && <Lightbox items={flat} index={open} onClose={close} onIndex={setOpen} />}
    </div>
  );
};

// ── Billing ──────────────────────────────────────────────────────────────────────────────────
export const BillingTab = ({ patient, bookings, stats, today }) => {
  const rows = [['Paid to date', npr(patient.lifetime)], ['Average spend', npr(stats.avgSpend)], ['Discounts', npr(stats.totalDiscount)], ['Outstanding (due)', patient.balance > 0 ? npr(patient.balance) : '—', patient.balance > 0]];
  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 lg:grid-cols-4 border border-border rounded-lg bg-white overflow-hidden">
        {rows.map(([k, v, amber], i) => (
          <div key={k} className={`px-4 py-3 ${i ? 'border-l border-border' : ''}`}>
            <p className="text-[12px] text-[#8A8A90]">{k}</p>
            <p className={`text-[15px] font-semibold mt-1 tabular-nums ${amber ? 'text-[#B45309]' : ''}`}>{v}</p>
          </div>
        ))}
      </div>
      {bookings.length === 0 ? <Empty>No billing yet.</Empty> : (
        <Card>
          <ul>
            {bookings.map((b) => {
              const m = classifyBooking(b, { today });
              const label = moneyLabel(b, today) || (STATUS[b.status] || b.status);
              return (
                <li key={b.id} className="flex items-center justify-between gap-3 px-4 py-3 border-b border-[#F1F1F3] last:border-0 text-[13px]">
                  <div className="min-w-0"><p className="font-medium truncate">{b.treatment_name_snapshot}</p><p className="text-[12.5px] text-[#8A8A90]">{fmt(b.date)} · {b.booking_number}</p></div>
                  <div className="text-right flex-shrink-0">
                    <p className="font-medium tabular-nums">{npr(b.final_amount)}</p>
                    <p className={`text-[12.5px] ${m.due > 0 ? 'text-[#B45309]' : 'text-[#8A8A90]'}`}>{['Cancelled', 'No Show'].includes(b.status) ? STATUS[b.status] || b.status : label}</p>
                  </div>
                </li>
              );
            })}
          </ul>
        </Card>
      )}
    </div>
  );
};
