import React, { useEffect, useRef, useState } from 'react';
import Icon from '../../../components/AppIcon';
import { getConsultationFileUrl } from '../../../services/api';
import { initials, monthYear, shortDate } from '../../../utils/patientDirectory';

const Card = ({ children, className = '' }) => <section className={`rounded-xl border border-border bg-white p-4 ${className}`}>{children}</section>;
const Eyebrow = ({ children, right }) => <div className="flex items-center justify-between text-[11.5px] font-medium uppercase tracking-[.05em] text-[#8A8A90] mb-3"><span>{children}</span>{right}</div>;

const Thumb = ({ path, label }) => {
  const [url, setUrl] = useState(null);
  useEffect(() => {
    let off = false;
    getConsultationFileUrl('image', path).then(({ url: u }) => { if (!off) setUrl(u); });
    return () => { off = true; };
  }, [path]);
  return (
    <a href={url || undefined} target="_blank" rel="noopener noreferrer" aria-label={`Open ${label}`}
      className="relative aspect-[4/3] rounded-lg border border-border bg-[#FAFAFB] overflow-hidden grid place-items-center hover:ring-2 hover:ring-primary/30">
      {url ? <img src={url} alt={label} loading="lazy" className="w-full h-full object-cover" /> : <Icon name="Image" size={18} className="text-[#B4B4BA]" />}
      <span className="absolute left-1.5 bottom-1.5 h-5 px-1.5 rounded bg-black/60 text-white text-[11px] font-medium inline-flex items-center">{label}</span>
    </a>
  );
};

const ConsultationRail = ({
  booking, record, lastPlan, xrayPaths, photoPaths, imageBusy, imageError, onAddImages,
  privateNotes, onPrivateNotes, onOpenChart, readOnly, phoneLinked,
}) => {
  const customer = record?.customer;
  const patient = record?.patient;
  const [picker, setPicker] = useState(null); // files waiting for "X-ray or Photo?"
  const [dragging, setDragging] = useState(false);
  const fileRef = useRef(null);
  const choose = (files) => { if (files?.length) setPicker(Array.from(files)); };
  const add = (kind) => { onAddImages(kind, picker); setPicker(null); };

  // Last visit before this one (this booking is In-Progress, so it must not count as the last visit).
  const last = (record?.bookings || []).filter((b) => b.id !== booking.id && b.status === 'Completed')
    .sort((a, b) => (String(a.date) < String(b.date) ? 1 : -1))[0];
  const visits = patient ? patient.visits : null;
  const meta = [customer?.gender, visits != null && `${visits} visit${visits === 1 ? '' : 's'}`, customer?.created_at && `since ${monthYear(customer.created_at)}`].filter(Boolean).join(' · ');
  const total = xrayPaths.length + photoPaths.length;

  return (
    <aside className="space-y-4 min-w-0">
      <Card>
        <Eyebrow right={booking.customer_id && <button type="button" onClick={onOpenChart} className="normal-case tracking-normal text-[#515152] hover:text-text-primary inline-flex items-center gap-1">Open chart<Icon name="ArrowUpRight" size={12} /></button>}>Patient</Eyebrow>
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-full bg-[#F1F1F3] text-[#4A4A4F] text-[13px] font-semibold grid place-items-center flex-shrink-0">{initials(booking.customer_name)}</div>
          <div className="min-w-0"><p className="text-[14px] font-medium truncate">{booking.customer_name}</p><p className="text-[12.5px] text-[#8A8A90] truncate">{meta || '…'}</p></div>
        </div>
        <dl className="mt-3 space-y-2 text-[13px]">
          <div className="flex justify-between gap-3"><dt className="text-[#8A8A90]">Last visit</dt><dd className="text-right">{last ? `${shortDate(String(last.date).slice(0, 10))} · ${last.treatment_name_snapshot || ''}` : record ? 'First visit' : '…'}</dd></div>
          {lastPlan && <div className="flex justify-between gap-3"><dt className="text-[#8A8A90] flex-shrink-0">Last plan</dt><dd className="text-right line-clamp-3">{lastPlan}</dd></div>}
        </dl>
        {customer?.notes && (
          <div className="mt-3">
            <p className="text-[12px] text-[#8A8A90] mb-1.5">Chart notes</p>
            <p className="bg-[#FAFAFB] border border-border rounded-lg p-3 text-[13px] whitespace-pre-wrap break-words">{customer.notes}</p>
          </div>
        )}
      </Card>

      <Card>
        <div onDragOver={(e) => { e.preventDefault(); setDragging(true); }} onDragLeave={() => setDragging(false)}
          onDrop={(e) => { e.preventDefault(); setDragging(false); if (!readOnly) choose(e.dataTransfer.files); }}
          className={dragging ? 'ring-2 ring-primary/40 rounded-lg' : ''}>
          <Eyebrow right={total > 0 && <span className="normal-case tracking-normal">{[xrayPaths.length && `${xrayPaths.length} X-ray${xrayPaths.length === 1 ? '' : 's'}`, photoPaths.length && `${photoPaths.length} photo${photoPaths.length === 1 ? '' : 's'}`].filter(Boolean).join(' · ')}</span>}>X-rays &amp; photos</Eyebrow>
          <div className="grid gap-2 [grid-template-columns:repeat(auto-fill,minmax(88px,120px))] lg:[grid-template-columns:repeat(2,minmax(0,1fr))]">
            {xrayPaths.map((p) => <Thumb key={p} path={p} label="X-ray" />)}
            {photoPaths.map((p) => <Thumb key={p} path={p} label="Photo" />)}
            {!readOnly && (
              <button type="button" onClick={() => fileRef.current?.click()} disabled={!!imageBusy}
                className="aspect-[4/3] rounded-lg border border-dashed border-[#D6D6DB] text-[#8A8A90] grid place-items-center text-[12.5px] hover:bg-[#FAFAFB] disabled:opacity-60">
                <span className="text-center"><Icon name={imageBusy ? 'Loader' : 'Plus'} size={16} className={imageBusy ? 'animate-spin mx-auto' : 'mx-auto'} /><span className="block mt-1">{imageBusy === 'uploading' ? 'Uploading…' : imageBusy === 'analyzing' ? 'Analysing…' : 'Add'}</span></span>
              </button>
            )}
          </div>
          <input ref={fileRef} type="file" accept="image/*" multiple hidden onChange={(e) => { choose(e.target.files); e.target.value = ''; }} />
          {picker && (
            <div role="group" aria-label="What are these files?" className="mt-3 rounded-lg border border-border bg-[#FAFAFB] p-3 text-[13px]">
              <p className="mb-2">Add {picker.length} file{picker.length === 1 ? '' : 's'} as</p>
              <div className="flex gap-2">
                <button type="button" onClick={() => add('xray')} className="h-7 px-3 rounded-md border border-border bg-white text-[12.5px] font-medium">X-ray</button>
                <button type="button" onClick={() => add('photo')} className="h-7 px-3 rounded-md border border-border bg-white text-[12.5px] font-medium">Photo</button>
                <button type="button" onClick={() => setPicker(null)} className="text-[12.5px] text-[#8A8A90]">Cancel</button>
              </div>
            </div>
          )}
          {imageError && <p role="alert" className="mt-2 text-[12.5px] text-[#B45309]">{imageError}</p>}
          <p className="text-[12px] text-[#8A8A90] mt-3">Drop files here{phoneLinked ? ', or take them on the paired phone' : ', or take them from a paired phone'}.</p>
        </div>
      </Card>

      <Card>
        <Eyebrow>Private notes</Eyebrow>
        <p className="text-[12.5px] text-[#8A8A90] mb-2">Staff only. Not part of the clinical note, the AI draft or the patient report.</p>
        <textarea aria-label="Private notes" value={privateNotes} onChange={(e) => onPrivateNotes(e.target.value)} rows={3} placeholder="Add a note…" readOnly={readOnly}
          className="w-full border border-border rounded-lg p-2.5 text-[13px] placeholder:text-[#B4B4BA] focus:outline-none focus:border-[#cfcfd4]" />
      </Card>
    </aside>
  );
};

export default ConsultationRail;
