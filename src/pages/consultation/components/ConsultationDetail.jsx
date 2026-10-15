import React, { useEffect, useState } from 'react';
import Icon from '../../../components/AppIcon';
import Button from '../../../components/ui/Button';
import { getConsultationFileUrl } from '../../../services/api';
import { generateConsultationPdf } from '../../../utils/consultationReport';
import { rowToReportData, isCompletedConsultation, attendedByText } from '../../../utils/consultationHistory';
import PatientDetailsGrid from './PatientDetailsGrid';
import useLastVisit from '../../../hooks/useLastVisit';
import { formatVisitDate } from '../../../utils/visitDates';

// The files live in private buckets, so each one is shown through a short-lived signed link.
const useSignedUrl = (kind, path) => {
  const [url, setUrl] = useState(null);
  useEffect(() => {
    let cancelled = false;
    getConsultationFileUrl(kind, path).then(({ url: u }) => { if (!cancelled) setUrl(u); });
    return () => { cancelled = true; };
  }, [kind, path]);
  return url;
};

const Recording = ({ path, index }) => {
  const url = useSignedUrl('audio', path);
  return (
    <div className="flex items-center gap-3">
      <span className="text-xs text-text-tertiary w-20 shrink-0">Recording {index + 1}</span>
      {url ? <audio controls src={url} className="h-9 flex-1 min-w-0" /> : <span className="text-xs text-text-tertiary">Loading…</span>}
    </div>
  );
};

const Photo = ({ path, label }) => {
  const url = useSignedUrl('image', path);
  return (
    <a href={url || undefined} target="_blank" rel="noopener noreferrer"
       className="w-24 h-24 rounded-md border border-gray-200 bg-gray-50 overflow-hidden flex items-center justify-center" aria-label={label}>
      {url ? <img src={url} alt={label} className="w-full h-full object-cover" /> : <Icon name="Image" size={20} className="text-gray-400" />}
    </a>
  );
};

const Section = ({ title, children }) => (
  <div className="bg-white rounded-lg border border-gray-200 p-4">
    <h3 className="text-xs uppercase tracking-wider text-text-tertiary mb-2">{title}</h3>
    {children}
  </div>
);

const Text = ({ value }) => <p className="text-sm text-text-primary whitespace-pre-wrap break-words">{value}</p>;

// Read-only view of one past consultation.
const ConsultationDetail = ({ row, orgName, onBack, onContinue }) => {
  const when = new Date(row.updated_at).toLocaleString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
  const canContinue = onContinue && row.bookings?.status === 'In-Progress';
  const audio = row.audio_paths || [];
  const xrays = row.xray_image_paths || [];
  const photos = row.photo_image_paths || [];

  const completed = isCompletedConsultation(row);
  const lastVisit = useLastVisit(row.customer_id, row.booking_id);

  return (
    <div className="space-y-4 text-left pb-24">
      <button type="button" onClick={onBack} className="flex items-center gap-1 text-sm text-primary font-medium">
        <Icon name="ArrowLeft" size={16} /> Back to history
      </button>

      <div className="bg-white rounded-lg border border-gray-200 p-4">
        <div className="flex items-start justify-between gap-2 mb-3">
          <p className="text-xs text-text-tertiary pt-1">{when}</p>
          <span className={`text-[11px] px-2 py-0.5 rounded-full shrink-0 ${completed ? 'bg-success/10 text-success' : 'bg-primary/10 text-primary'}`}>
            {completed ? 'Completed' : 'In progress'}
          </span>
        </div>
        <PatientDetailsGrid
          patient={row.patient_name}
          booking={row.bookings?.booking_number}
          treatment={row.bookings?.treatment_name_snapshot}
          dentist={row.bookings?.dentist_name_snapshot}
          attendedBy={attendedByText(row)}
          visitDate={formatVisitDate(row.session_date)}
          lastVisit={lastVisit}
        />
      </div>

      {canContinue && (
        <Button variant="primary" fullWidth iconName="Mic" iconPosition="left" onClick={() => onContinue(row)}>
          Continue this consultation
        </Button>
      )}

      {row.final_summary && <Section title="Final summary"><Text value={row.final_summary} /></Section>}
      {row.preliminary_summary && <Section title="Consultation summary"><Text value={row.preliminary_summary} /></Section>}
      {row.doctor_notes && <Section title="Doctor's notes"><Text value={row.doctor_notes} /></Section>}
      {row.additional_notes && <Section title="Additional notes"><Text value={row.additional_notes} /></Section>}

      {audio.length > 0 && (
        <Section title="Recordings"><div className="space-y-2">{audio.map((p, i) => <Recording key={p} path={p} index={i} />)}</div></Section>
      )}
      {row.transcript && <Section title="Transcript"><Text value={row.transcript} /></Section>}

      {xrays.length > 0 && (
        <Section title="X-ray">
          <div className="flex flex-wrap gap-2">{xrays.map((p, i) => <Photo key={p} path={p} label={`X-ray ${i + 1}`} />)}</div>
          {row.xray_analysis && <div className="mt-3"><Text value={row.xray_analysis} /></div>}
        </Section>
      )}
      {photos.length > 0 && (
        <Section title="Clinical photos">
          <div className="flex flex-wrap gap-2">{photos.map((p, i) => <Photo key={p} path={p} label={`Clinical photo ${i + 1}`} />)}</div>
          {row.photo_analysis && <div className="mt-3"><Text value={row.photo_analysis} /></div>}
        </Section>
      )}

      <Button variant="outline" fullWidth iconName="FileText" iconPosition="left"
              onClick={() => generateConsultationPdf(rowToReportData(row), orgName)}>
        Download PDF report
      </Button>

      {/* Always-visible close */}
      <div className="fixed bottom-0 inset-x-0 z-10 p-4 pb-[max(1rem,env(safe-area-inset-bottom))] bg-background/95 backdrop-blur border-t border-gray-200">
        <div className="max-w-sm mx-auto">
          <Button variant="primary" fullWidth size="lg" iconName="X" iconPosition="left" onClick={onBack}>Close</Button>
        </div>
      </div>
    </div>
  );
};

export default ConsultationDetail;
