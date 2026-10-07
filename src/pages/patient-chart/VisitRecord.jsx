import React, { useEffect, useState } from 'react';
import Icon from '../../components/AppIcon';
import Button from '../../components/ui/Button';
import { getConsultationFileUrl } from '../../services/api';
import { generateConsultationPdf } from '../../utils/consultationReport';
import { rowToReportData, attendedByText } from '../../utils/consultationHistory';
import { parseSummarySections } from '../../utils/summarySections';

const useSignedUrl = (kind, path) => {
  const [url, setUrl] = useState(null);
  useEffect(() => {
    let cancelled = false;
    getConsultationFileUrl(kind, path).then(({ url: u }) => { if (!cancelled) setUrl(u); });
    return () => { cancelled = true; };
  }, [kind, path]);
  return url;
};

const Thumb = ({ path, label }) => {
  const url = useSignedUrl('image', path);
  return (
    <a href={url || undefined} target="_blank" rel="noopener noreferrer" aria-label={`Open ${label}`}
       className="w-28 h-28 rounded-lg border border-gray-200 bg-gray-50 overflow-hidden flex items-center justify-center hover:ring-2 hover:ring-primary/40">
      {url ? <img src={url} alt={label} className="w-full h-full object-cover" /> : <Icon name="Image" size={22} className="text-gray-400" />}
    </a>
  );
};

const Field = ({ icon, label, children, tone = 'text-text-tertiary' }) => (
  <div>
    <h4 className={`flex items-center gap-1.5 text-[11px] uppercase tracking-wider font-medium mb-1 ${tone}`}>
      <Icon name={icon} size={12} /> {label}
    </h4>
    <div className={`text-sm whitespace-pre-wrap break-words ${children ? 'text-text-primary' : 'text-text-tertiary italic'}`}>{children || 'Not recorded'}</div>
  </div>
);

/** Full clinical record of one visit: who attended, problem, tests, diagnosis, X-rays, PDF. */
const VisitRecord = ({ visit, consultation: c0, customerName, notes }) => {
  const c = c0 || {};
  const hasConsultation = !!c.id;

  const sec = parseSummarySections(c.final_summary || c.preliminary_summary || '');
  const xrays = c.xray_image_paths || [];
  const photos = c.photo_image_paths || [];
  const doctors = attendedByText(c) || visit.dentistName;
  const problem = sec.complaint || (sec.other && !c.final_summary?.includes('#') ? sec.other : '');
  const tests = [sec.findings, c.xray_analysis || sec.xray, c.photo_analysis || sec.photo].filter(Boolean);
  const diagnosis = sec.diagnosis;
  const hasStructured = problem || tests.length || diagnosis || sec.plan;

  const report = () => generateConsultationPdf(rowToReportData({ ...c, bookings: {
    booking_number: visit.bookingNumber, treatment_name_snapshot: visit.treatmentName, dentist_name_snapshot: visit.dentistName,
  }, patient_name: c.patient_name || customerName }));

  return (
    <div className="px-4 pb-4 pt-3 border-t border-gray-100 space-y-4">
      <div className="flex flex-wrap gap-x-6 gap-y-1 text-sm">
        <span className="text-text-secondary">Doctor: <span className="font-medium text-text-primary">{visit.dentistName}</span></span>
        {doctors && doctors !== visit.dentistName && (
          <span className="text-text-secondary">Attended by: <span className="font-medium text-text-primary">{doctors}</span></span>
        )}
      </div>

      <Field icon="AlertCircle" label="Problem / complaint">{problem}</Field>
            <Field icon="Microscope" label="Tests & findings">{tests.join('\n\n')}</Field>

      <div>
        <h4 className="flex items-center gap-1.5 text-[11px] uppercase tracking-wider font-medium mb-2 text-text-tertiary">
          <Icon name="Image" size={12} /> X-rays & photos
        </h4>
        {xrays.length + photos.length === 0 ? (
          <p className="text-sm text-text-tertiary italic">Not recorded</p>
        ) : (
          <div className="flex flex-wrap gap-2">
            {xrays.map((p, i) => <Thumb key={p} path={p} label={`X-ray ${i + 1}`} />)}
            {photos.map((p, i) => <Thumb key={p} path={p} label={`Clinical photo ${i + 1}`} />)}
          </div>
        )}
      </div>

      <div className="rounded-lg bg-primary/5 border border-primary/20 p-3">
        <Field icon="ClipboardCheck" label="Diagnosis" tone="text-primary">{diagnosis}</Field>
      </div>
      <Field icon="ListChecks" label="Treatment plan">{sec.plan}</Field>
      {sec.followup && <Field icon="CalendarCheck" label="Follow-up">{sec.followup}</Field>}
      <Field icon="Stethoscope" label="Doctor's notes">{c.doctor_notes}</Field>
      <Field icon="FileText" label="Additional notes">{c.additional_notes}</Field>

      {!hasStructured && (c.final_summary || c.preliminary_summary) && (
        <Field icon="FileText" label="Summary">{c.final_summary || c.preliminary_summary}</Field>
      )}

      <Field icon="FileText" label="Treatment notes">
        {notes.length > 0 ? notes.map((n) => <p key={n.id} className="mb-1">{n.note}</p>) : null}
      </Field>

      {hasConsultation ? <Button variant="outline" size="sm" iconName="FileText" iconPosition="left" onClick={report}>
        Download final PDF report
      </Button> : <p className="text-xs text-text-tertiary">No consultation was recorded for this visit, so there is no PDF report.</p>}
    </div>
  );
};

export default VisitRecord;
