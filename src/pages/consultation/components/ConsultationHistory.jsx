import React, { useEffect, useState } from 'react';
import Icon from '../../../components/AppIcon';
import { useAuth } from '../../../contexts/AuthContext';
import { fetchRecentConsultations } from '../../../services/api';
import { hasConsultationContent, groupByDay, capturedSummary, isCompletedConsultation, filterHistory, attendedByText, HISTORY_FILTERS } from '../../../utils/consultationHistory';

const timeOf = (iso) => new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });

// Past patients recorded, newest first, grouped by day. Tap one to open it.
const ConsultationHistory = ({ onOpen }) => {
  const [rows, setRows] = useState(null);
  const [error, setError] = useState(null);
  const [filter, setFilter] = useState('all');
  const [scope, setScope] = useState('mine'); // 'mine' | 'all' doctors
  const { profile } = useAuth();

  const load = async (which = scope) => {
    setError(null);
    const { data, error: loadError } = await fetchRecentConsultations(60, { mine: which === 'mine' });
    if (loadError) { setError('Could not load the history.'); setRows([]); return; }
    setRows(data.filter(hasConsultationContent));
  };

  useEffect(() => { setRows(null); load(scope); }, [scope]); // eslint-disable-line react-hooks/exhaustive-deps

  if (rows === null) return <p className="text-sm text-text-tertiary text-center py-8">Loading history…</p>;

  const shown = filterHistory(rows, filter);

  return (
    <div className="text-left space-y-4">
      {error && <p className="text-sm text-error text-center">{error}</p>}
      <div className="grid grid-cols-2 gap-1 p-1 bg-gray-100 rounded-lg">
        {[['mine', 'My patients'], ['all', 'All doctors']].map(([id, label]) => (
          <button key={id} type="button" onClick={() => setScope(id)}
                  className={`py-1.5 rounded-md text-xs font-medium ${scope === id ? 'bg-white text-text-primary shadow-sm' : 'text-text-secondary'}`}>
            {label}
          </button>
        ))}
      </div>
      <div className="flex gap-2">
        {HISTORY_FILTERS.map((f) => {
          const count = filterHistory(rows, f.id).length;
          return (
            <button key={f.id} type="button" onClick={() => setFilter(f.id)}
                    className={`px-3 py-1.5 rounded-full text-xs font-medium border ${filter === f.id ? 'bg-primary text-white border-primary' : 'bg-white text-text-secondary border-gray-200'}`}>
              {f.label} ({count})
            </button>
          );
        })}
      </div>
      <p className="text-xs text-text-tertiary">
        {scope === 'mine' ? 'Patients you recorded' : 'Every doctor\'s patients, so you can cover for a colleague'}
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
                className="w-full text-left bg-white rounded-lg border border-gray-200 hover:border-primary p-3 flex items-center gap-3"
              >
                <span className="w-9 h-9 rounded-full bg-primary/10 text-primary flex items-center justify-center text-sm font-medium shrink-0">
                  {(row.patient_name || '?').trim().charAt(0).toUpperCase()}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block text-sm font-medium text-text-primary truncate">{row.patient_name}</span>
                  <span className="block text-xs text-text-tertiary truncate">
                    {timeOf(row.updated_at)} · {capturedSummary(row)}
                  </span>
                  {attendedByText(row) && (
                    <span className="block text-[11px] text-primary truncate">Attended by {attendedByText(row)}</span>
                  )}
                </span>
                <span className={`text-[11px] px-2 py-0.5 rounded-full shrink-0 ${isCompletedConsultation(row) ? 'bg-success/10 text-success' : 'bg-primary/10 text-primary'}`}>
                  {isCompletedConsultation(row) ? 'Completed' : 'In progress'}
                </span>
              </button>
            ))}
          </div>
        </div>
      ))}
      <button type="button" onClick={load} className="block mx-auto text-xs text-primary font-medium">Refresh</button>
    </div>
  );
};

export default ConsultationHistory;
