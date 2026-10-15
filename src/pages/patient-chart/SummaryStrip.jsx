import React from 'react';
import { relativeDayLabel, monthYear } from '../../utils/patientDirectory';
import { classifyBooking } from '../../utils/bookingMoney';
import { balanceSub } from '../branch-manager-dashboard/components/CRM/PatientPanel';

const npr = (n) => `NPR ${Number(n || 0).toLocaleString('en-IN')}`;
const range = (b) => `${String(b.start_time || '').slice(0, 5)}${b.end_time ? ` – ${String(b.end_time).slice(0, 5)}` : ''}`;

const Cell = ({ label, dot, value, sub, amber }) => (
  <div className="px-4 py-3.5 min-w-0 bg-white sm:last:odd:col-span-2 lg:last:odd:col-span-1">
    <div className="text-[12px] text-[#8A8A90] flex items-center gap-1.5">{dot && <span className="w-1.5 h-1.5 rounded-full bg-[#1F9D6C]" />}{label}</div>
    <div className={`text-[15px] font-semibold mt-2 truncate tabular-nums ${amber ? 'text-[#B45309]' : 'text-text-primary'}`}>{value}</div>
    <div className="text-[12.5px] text-[#8A8A90] mt-1 truncate">{sub}</div>
  </div>
);

// One bordered row: Now (or today's next booking), Next appointment, Visits, Balance, Paid to date.
const SummaryStrip = ({ patient, bookings, today }) => {
  const nowB = bookings.find((b) => b.status === 'In-Progress' && String(b.date).slice(0, 10) === today);
  const nowHM = new Date().toTimeString().slice(0, 5);
  const laterToday = !nowB && bookings
    .filter((b) => ['Pending', 'Confirmed'].includes(b.status) && String(b.date).slice(0, 10) === today && String(b.start_time).slice(0, 5) > nowHM)
    .sort((a, b) => String(a.start_time).localeCompare(String(b.start_time)))[0];
  const next = patient.nextAppointment;
  // Price (and any deposit) of the next appointment, from bookingMoney.
  const nextB = next && bookings.find((b) => String(b.date).slice(0, 10) === next.date && String(b.start_time).slice(0, 5) === next.time && ['Pending', 'Confirmed'].includes(b.status));
  const nextM = nextB && classifyBooking(nextB, { today });
  const nextSub = !next ? 'No appointment' : [next.treatment, nextM && (nextM.deposit > 0 ? `${npr(nextM.deposit)} paid · ${nextM.upcoming.toLocaleString('en-IN')} at visit` : npr(nextM.price))].filter(Boolean).join(' · ');
  const firstVisit = bookings.filter((b) => ['Completed', 'In-Progress'].includes(b.status)).map((b) => String(b.date).slice(0, 10)).sort()[0];
  const cells = [];
  if (nowB) cells.push({ label: 'Now', dot: true, value: nowB.treatment_name_snapshot, sub: [range(nowB), nowB.dentist_name_snapshot].filter(Boolean).join(' · ') });
  else if (laterToday) cells.push({ label: 'Today', value: `${String(laterToday.start_time).slice(0, 5)} · ${laterToday.treatment_name_snapshot}`, sub: laterToday.dentist_name_snapshot || '' });
  cells.push(
    { label: 'Next appointment', value: next ? `${relativeDayLabel(next.date, today)} · ${next.time}` : '—', sub: nextSub },
    { label: 'Visits', value: patient.visits, sub: firstVisit ? `since ${monthYear(firstVisit).split(' ')[0]}` : 'No visits yet' },
    { label: 'Balance', value: patient.balance > 0 ? npr(patient.balance) : patient.upcoming > 0 ? 'NPR 0' : '—', amber: patient.balance > 0, sub: balanceSub(patient) || 'Nothing due' },
    { label: 'Paid to date', value: npr(patient.lifetime), sub: `across ${patient.visits} visit${patient.visits === 1 ? '' : 's'}` },
  );
  const cols = cells.length === 5 ? 'lg:grid-cols-5' : 'lg:grid-cols-4';
  return (
    <div className={`mt-5 grid grid-cols-1 sm:grid-cols-2 ${cols} gap-px bg-border border border-border rounded-lg overflow-hidden`}>
      {cells.map((c) => <Cell key={c.label} {...c} />)}
    </div>
  );
};

export default SummaryStrip;
