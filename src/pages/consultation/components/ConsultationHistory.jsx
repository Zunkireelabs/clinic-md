import React, { useEffect, useState } from 'react';
import Icon from '../../../components/AppIcon';
import { useAuth } from '../../../contexts/AuthContext';
import { useBranch } from '../../../contexts/BranchContext';
import { fetchRecentConsultations, fetchDentists } from '../../../services/api';
import { hasConsultationContent, groupByDay, capturedSummary, isCompletedConsultation, filterHistory, attendedByText, HISTORY_FILTERS } from '../../../utils/consultationHistory';

const timeOf = (iso) => new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });

// Past patients recorded, newest first, grouped by day. Tap one to open it.
const ConsultationHistory = ({ onOpen }) => {
  const [rows, setRows] = useState(null);
  const [error, setError] = useState(null);
  const [filter, setFilter] = useState('all');
  const [scope, setScope] = useState('mine'); // 'mine' | 'all' doctors
  const [doctor, setDoctor] = useState(null); // a doctor picked from the list (all-doctors view)
  const { profile } = useAuth(); // eslint-disable-line no-unused-vars
  const { branchId } = useBranch();
  const [dentistNames, setDentistNames] = useState([]);

  useEffect(() => {
    if (!branchId) return;
    fetchDentists(branchId).then(({ data }) => setDentistNames((data || []).map((d) => d.name).filter(Boolean)));
  }, [branchId]);

  const load = async (which = scope) => {
    setError(null);
    const { data, error: loadError } = await fetchRecentConsultations(60, { mine: which === 'mine' });
    if (loadError) { setError('Could not load the history.'); setRows([]); return; }
    setRows(data.filter(hasConsultationContent));
  };

  useEffect(() => { setRows(null); setDoctor(null); load(scope); }, [scope]); // eslint-disable-line react-hooks/exhaustive-deps

  if (rows === null) return <p className="text-sm text-text-tertiary text-center py-8">Loading history…</p>;

  const doctorOf = (r) => r.created_by_name || r.bookings?.dentist_name_snapshot || 'Unknown';
  const belongs = (r, name) => doctorOf(r) === name || r.bookings?.dentist_name_snapshot === name;
  const names = [...new Set([...dentistNames, ...rows.map(doctorOf)])].filter((n) => n && n !== 'Unknown');
  const doctors = names
    .map((n) => {
      const mine = rows.filter((r) => belongs(r, n));
      return { name: n, count: mine.length, last: mine[0]?.updated_at };
    })
    .sort((x, y) => y.count - x.count || x.name.localeCompare(y.name));
  const byDoctor = scope === 'all' && doctor ? rows.filter((r) => belongs(r, doctor)) : rows;
  const shown = filterHistory(byDoctor, filter);

  return (
    <div className="text-left space-y-4">
      {error && <p className="text-sm text-error text-center">{error}</p>}
      <div className="grid grid-cols-2 gap-1 p-1 bg-gray-100 rounded-xl">
        {[['mine', 'My patients', 'User'], ['all', 'All doctors', 'Users']].map(([id, label, icon]) => (
          <button key={id} type="button" onClick={() => setScope(id)}
                  className={`flex items-center justify-center gap-1.5 py-2 rounded-lg text-sm font-medium transition ${scope === id ? 'bg-white text-primary shadow-sm' : 'text-text-secondary'}`}>
            <Icon name={icon} size={14} /> {label}
          </button>
        ))}
      </div>

      {scope === 'all' && !doctor && (
        <div className="space-y-2">
          <p className="text-xs uppercase tracking-wider text-text-tertiary">Doctors ({doctors.length})</p>
          {doctors.length === 0 && <p className="text-sm text-text-tertiary text-center py-6">No doctors found.</p>}
          {doctors.map((d) => (
            <button key={d.name} type="button" onClick={() => setDoctor(d.name)}
                    className="w-full text-left bg-white rounded-2xl border border-gray-200 shadow-sm active:scale-[0.99] transition hover:border-primary p-4 flex items-center gap-3">
              <span className="w-12 h-12 rounded-full bg-primary/10 text-primary flex items-center justify-center text-lg font-semibold shrink-0">
                {d.name.replace(/^Dr\.?\s*/i, '').charAt(0).toUpperCase()}
              </span>
              <span className="min-w-0 flex-1">
                <span className="block text-base font-medium text-text-primary truncate">{d.name}</span>
                <span className="block text-xs text-text-tertiary">
                  {d.count === 0 ? 'No consultations yet' : `${d.count} consultation${d.count > 1 ? 's' : ''} · last ${new Date(d.last).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })}`}
                </span>
              </span>
              <Icon name="ChevronRight" size={18} className="text-text-tertiary shrink-0" />
            </button>
          ))}
        </div>
      )}

      {scope === 'all' && doctor && (
        <button type="button" onClick={() => setDoctor(null)} className="flex items-center gap-1 text-sm text-primary font-medium">
          <Icon name="ArrowLeft" size={16} /> All doctors
        </button>
      )}

      {!(scope === 'all' && !doctor) && (<>
      <div className="flex gap-2">
        {HISTORY_FILTERS.map((f) => {
          const count = filterHistory(byDoctor, f.id).length;
          return (
            <button key={f.id} type="button" onClick={() => setFilter(f.id)}
                    className={`px-3 py-1.5 rounded-full text-xs font-medium border ${filter === f.id ? 'bg-primary text-white border-primary' : 'bg-white text-text-secondary border-gray-200'}`}>
              {f.label} ({count})
            </button>
          );
        })}
      </div>
      <p className="text-xs text-text-tertiary">
        {scope === 'mine' ? 'Patients you recorded' : (doctor ? `${doctor}'s patients` : 'Every doctor\'s patients, so you can cover for a colleague')}
      </p>
      {!error && shown.length === 0 && (
        <p className="text-sm text-text-tertiary text-center py-8">
          {rows.length === 0 ? 'No consultations yet. Recordings and photos you capture will appear here.' : 'Nothing in this list.'}
        </p>
      )}
      {groupByDay(shown).map((group) => (
        <div key={group.label}>
          <p className="text-xs uppercase tracking-wider text-text-tertiary mb-2">{group.label}</p>
          <div className="space-y-2">
            {group.items.map((row) => (
              <button
                key={row.id}
                type="button"
                onClick={() => onOpen(row)}
                className="w-full text-left bg-white rounded-2xl border border-gray-200 shadow-sm active:scale-[0.99] transition hover:border-primary p-4 flex items-center gap-3"
              >
                <span className="w-11 h-11 rounded-full bg-primary/10 text-primary flex items-center justify-center text-base font-semibold shrink-0">
                  {(row.patient_name || '?').trim().charAt(0).toUpperCase()}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block text-base font-medium text-text-primary truncate">{row.patient_name}</span>
                  <span className="block text-xs text-text-tertiary truncate">
                    {timeOf(row.updated_at)} · {capturedSummary(row)}
                  </span>
                  <span className="mt-0.5 flex items-center gap-1 text-[11px] text-primary truncate">
                    <Icon name="Stethoscope" size={11} /> {attendedByText(row) || doctorOf(row)}
                  </span>
                </span>
                <span className={`text-[11px] px-2 py-0.5 rounded-full shrink-0 ${isCompletedConsultation(row) ? 'bg-success/10 text-success' : 'bg-primary/10 text-primary'}`}>
                  {isCompletedConsultation(row) ? 'Completed' : 'In progress'}
                </span>
              </button>
            ))}
          </div>
        </div>
      ))}
      </>)}
      <button type="button" onClick={() => load()} className="block mx-auto text-xs text-primary font-medium">Refresh</button>
    </div>
  );
};

export default ConsultationHistory;
