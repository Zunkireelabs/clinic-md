import React, { useEffect, useState } from 'react';
import Icon from '../../../components/AppIcon';
import { fetchRecentConsultations } from '../../../services/api';
import { hasConsultationContent, capturedSummary, isCompletedConsultation, attendedByText } from '../../../utils/consultationHistory';

// This patient's earlier consultations (any doctor), so a doctor can look back or cover for a colleague.
const PatientEarlierVisits = ({ customerId, excludeId, onOpen }) => {
  const [rows, setRows] = useState(null);

  useEffect(() => {
    if (!customerId) { setRows([]); return undefined; }
    let cancelled = false;
    fetchRecentConsultations(30, { mine: false, customerId }).then(({ data }) => {
      if (!cancelled) setRows(data.filter((r) => r.id !== excludeId && hasConsultationContent(r)));
    });
    return () => { cancelled = true; };
  }, [customerId, excludeId]);

  if (rows === null || rows.length === 0) return null;

  return (
    <div className="bg-white rounded-lg border border-gray-200 p-4 text-left">
      <h2 className="font-heading font-heading-semibold text-base text-text-primary flex items-center gap-2 mb-3">
        <Icon name="History" size={18} className="text-primary" /> Earlier visits
      </h2>
      <div className="space-y-2">
        {rows.map((row) => (
          <button key={row.id} type="button" onClick={() => onOpen(row)}
                  className="w-full text-left rounded-md border border-gray-200 hover:border-primary p-3 flex items-center gap-3">
            <span className="min-w-0 flex-1">
              <span className="block text-sm font-medium text-text-primary">
                {new Date(row.updated_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })}
              </span>
              <span className="block text-xs text-text-tertiary truncate">{capturedSummary(row)}</span>
              {attendedByText(row) && <span className="block text-[11px] text-primary truncate">Attended by {attendedByText(row)}</span>}
            </span>
            <span className={`text-[11px] px-2 py-0.5 rounded-full shrink-0 ${isCompletedConsultation(row) ? 'bg-success/10 text-success' : 'bg-primary/10 text-primary'}`}>
              {isCompletedConsultation(row) ? 'Completed' : 'In progress'}
            </span>
          </button>
        ))}
      </div>
    </div>
  );
};

export default PatientEarlierVisits;
