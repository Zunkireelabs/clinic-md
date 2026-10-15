import React, { useState } from 'react';
import Icon from '../../components/AppIcon';
import { ACTIVITY_FILTERS } from '../../utils/patientRecord';
import { shortDate, localISO } from '../../utils/patientDirectory';
import { formatPhoneDisplay } from '../../utils/phone';

const PAGE = 20;
const dayShort = (iso, today) => {
  if (iso === today) return 'Today';
  const yr = iso.slice(0, 4) !== today.slice(0, 4) ? ` ${iso.slice(0, 4)}` : '';
  return `${shortDate(iso)}${yr}`;
};

const STATUS_PILL = {
  'In-Progress': ['In progress', 'bg-[#ECFDF5] text-[#137A53]'],
  Completed: ['Completed', 'bg-[#ECFDF5] text-[#137A53]'],
  Confirmed: ['Confirmed', 'bg-[#EEF4FF] text-[#1D4ED8]'],
  Pending: ['Pending', 'bg-[#F1F1F3] text-[#4A4A4F]'],
  Cancelled: ['Cancelled', 'bg-[#F1F1F3] text-[#4A4A4F]'],
  'No Show': ['No show', 'bg-[#F1F1F3] text-[#4A4A4F]'],
};
const KIND_ICON = { visit: 'Check', payment: 'CreditCard', note: 'Mic' };

const Card = ({ children, className = '' }) => <section className={`border border-border rounded-lg bg-white ${className}`}>{children}</section>;
const Eyebrow = ({ children }) => <h3 className="text-[11.5px] font-medium uppercase tracking-[.05em] text-[#8A8A90]">{children}</h3>;
const Btn = ({ icon, children, ...p }) => (
  <button type="button" {...p} className="h-7 px-2.5 rounded-md border border-border bg-white text-[12.5px] font-medium inline-flex items-center gap-1.5 hover:bg-[#FAFAFB]">
    <Icon name={icon} size={13} />{children}
  </button>
);

export const SummaryCard = ({ summary, canStart, onFull, onStart }) => (
  <Card>
    <div className="flex items-center justify-between gap-3 px-4 pt-3.5 flex-wrap">
      <h3 className="text-[11px] font-semibold tracking-[.06em] uppercase text-primary">Latest clinical summary</h3>
      {summary && <span className="text-[12.5px] text-[#8A8A90]">From consultation · {shortDate(summary.date)}{summary.doctor ? ` · ${summary.doctor}` : ''}</span>}
    </div>
    <div className="px-4 py-3 border-t border-[#F1F1F3] mt-3">
      {summary ? (
        summary.rows.length ? (
          <dl className="grid grid-cols-[110px_1fr] gap-y-2 text-[13.5px]">
            {summary.rows.map(([k, v]) => (<React.Fragment key={k}><dt className="text-[#8A8A90]">{k}</dt><dd className="whitespace-pre-wrap break-words">{v}</dd></React.Fragment>))}
          </dl>
        ) : <p className="text-[13.5px] whitespace-pre-wrap break-words line-clamp-6">{summary.raw}</p>
      ) : <p className="text-[13.5px] text-[#8A8A90]">No consultation recorded yet</p>}
      <div className="flex gap-2 mt-3 flex-wrap">
        {summary && <Btn icon="FileText" onClick={onFull}>Full consultation</Btn>}
        {canStart && <Btn icon="Mic" onClick={onStart}>Start consultation</Btn>}
      </div>
    </div>
  </Card>
);

export const ActivityFeed = ({ items, today, onOpen }) => {
  const [filter, setFilter] = useState('all');
  const [shown, setShown] = useState(PAGE);
  const match = ACTIVITY_FILTERS.find((f) => f.id === filter).match;
  const list = items.filter(match);
  return (
    <Card>
      <div className="flex items-center justify-between px-4 h-11 border-b border-[#F1F1F3]">
        <h3 className="text-[14px] font-semibold">Activity</h3>
        <div className="flex gap-2.5 text-[12.5px]" role="group" aria-label="Activity filter">
          {ACTIVITY_FILTERS.map((f) => (
            <button key={f.id} type="button" aria-pressed={filter === f.id} onClick={() => { setFilter(f.id); setShown(PAGE); }}
              className={filter === f.id ? 'text-text-primary font-medium' : 'text-[#8A8A90] hover:text-text-primary'}>{f.label}</button>
          ))}
        </div>
      </div>
      {list.length === 0 ? <p className="px-4 py-8 text-center text-[13px] text-[#8A8A90]">Nothing here yet.</p> : (
        <ul>
          {list.slice(0, shown).map((i) => {
            const pill = i.kind === 'visit' ? STATUS_PILL[i.status] : null;
            return (
              <li key={i.id} className="border-b border-[#F1F1F3] last:border-0">
                <button type="button" onClick={() => onOpen(i)} className="w-full text-left px-4 py-3 flex gap-3 hover:bg-[#FAFAFB]">
                  <span className="w-8 h-8 rounded-full border border-border grid place-items-center text-[#515152] flex-shrink-0 mt-0.5"><Icon name={KIND_ICON[i.kind]} size={14} /></span>
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center gap-2 text-[13.5px] font-medium"><span className="truncate">{i.title}</span>
                      {pill && <span className={`h-5 rounded-full px-2 text-[11.5px] font-medium inline-flex items-center flex-shrink-0 ${pill[1]}`}>{pill[0]}</span>}</span>
                    <span className="block text-[12.5px] text-[#8A8A90] truncate">{i.sub}</span>
                  </span>
                  <span className="text-[12.5px] text-[#8A8A90] flex-shrink-0 tabular-nums">{dayShort(i.date, today)}{i.date === today && i.time ? `, ${i.time}` : ''}</span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {list.length > shown && <div className="p-3 text-center border-t border-[#F1F1F3]"><Btn icon="ChevronDown" onClick={() => setShown((n) => n + PAGE)}>Show more</Btn></div>}
    </Card>
  );
};

const RailLabel = ({ children, action }) => (
  <div className="flex items-center justify-between text-[11.5px] font-medium uppercase tracking-[.05em] text-[#8A8A90] mb-2.5"><span>{children}</span>{action}</div>
);
const Row = ({ k, children }) => (<div className="flex items-center justify-between gap-3 py-1 text-[13px] min-h-[28px]"><span className="text-[#8A8A90]">{k}</span><span className="text-right min-w-0 break-all">{children}</span></div>);

export const DetailsRail = ({ customer, careTeam, treatments, canEdit, onSaveDob, onSaveNotes }) => {
  const [dobEdit, setDobEdit] = useState(false);
  const [dob, setDob] = useState('');
  const [notesEdit, setNotesEdit] = useState(false);
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);
  const saveDob = async () => { if (!dob) return; setBusy(true); const ok = await onSaveDob(dob); setBusy(false); if (ok) setDobEdit(false); };
  const saveNotes = async () => { setBusy(true); const ok = await onSaveNotes(notes); setBusy(false); if (ok) setNotesEdit(false); };
  return (
    <aside className="space-y-6">
      <div>
        <RailLabel>Details</RailLabel>
        <Row k="Date of birth">
          {dobEdit ? (
            <span className="inline-flex items-center gap-1.5">
              <input type="date" aria-label="Date of birth" value={dob} max={localISO(new Date())} onChange={(e) => setDob(e.target.value)} className="h-7 border border-border rounded-md px-1.5 text-[12.5px]" />
              <button type="button" disabled={busy || !dob} onClick={saveDob} className="text-primary font-medium disabled:opacity-50">Save</button>
              <button type="button" onClick={() => setDobEdit(false)} className="text-[#8A8A90]">Cancel</button>
            </span>
          ) : customer.date_of_birth ? (
            <span>{new Date(`${customer.date_of_birth}T00:00:00`).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })}
              {canEdit && <button type="button" onClick={() => { setDob(customer.date_of_birth); setDobEdit(true); }} className="ml-2 text-[12px] text-[#8A8A90] hover:text-text-primary">Edit</button>}</span>
          ) : canEdit ? (
            <button type="button" onClick={() => { setDob(''); setDobEdit(true); }} className="h-6 px-2 border border-dashed border-[#D6D6DB] rounded-md text-[12px] text-[#8A8A90] hover:bg-[#FAFAFB]">+ Add</button>
          ) : '—'}
        </Row>
        <Row k="Gender">{customer.gender || '—'}</Row>
        <Row k="Phone">{formatPhoneDisplay(customer.phone) || '—'}</Row>
        <Row k="Email">{customer.email || '—'}</Row>
      </div>
      <div>
        <RailLabel>Care team</RailLabel>
        {careTeam.length === 0 ? <p className="text-[13px] text-[#8A8A90]">No doctor assigned yet</p> : careTeam.map((d) => (
          <div key={d.name} className="flex justify-between py-1 text-[13px]"><span className="font-medium truncate">{d.name}</span><span className="text-[#8A8A90]">{d.count} visit{d.count === 1 ? '' : 's'}</span></div>))}
      </div>
      <div>
        <RailLabel>Treatments</RailLabel>
        {treatments.length === 0 ? <p className="text-[13px] text-[#8A8A90]">None yet</p> : treatments.map((t) => (
          <div key={t.name} className="flex justify-between py-1 text-[13px]"><span className="font-medium truncate">{t.name}</span><span className="text-[#8A8A90]">×{t.count}</span></div>))}
      </div>
      <div>
        <RailLabel action={canEdit && !notesEdit && <button type="button" onClick={() => { setNotes(customer.notes || ''); setNotesEdit(true); }} className="normal-case tracking-normal text-[#515152] hover:text-text-primary">{customer.notes ? 'Edit' : '+ Add'}</button>}>Notes</RailLabel>
        {notesEdit ? (
          <div>
            <textarea aria-label="Notes" value={notes} onChange={(e) => setNotes(e.target.value)} rows={4} className="w-full border border-border rounded-lg p-2.5 text-[13px] focus:outline-none focus:border-[#cfcfd4]" />
            <div className="flex gap-2 mt-2">
              <button type="button" disabled={busy} onClick={saveNotes} className="h-7 px-3 rounded-md bg-primary text-white text-[12.5px] font-medium disabled:opacity-60">Save</button>
              <button type="button" onClick={() => setNotesEdit(false)} className="h-7 px-3 rounded-md border border-border text-[12.5px]">Cancel</button>
            </div>
          </div>
        ) : customer.notes ? <p className="bg-[#FAFAFB] border border-border rounded-lg p-3 text-[13px] whitespace-pre-wrap break-words">{customer.notes}</p>
          : <p className="text-[13px] text-[#8A8A90]">No notes</p>}
      </div>
    </aside>
  );
};
