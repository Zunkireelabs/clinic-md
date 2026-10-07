import React, { useEffect, useState } from 'react';
import Icon from '../../../../components/AppIcon';
import Button from '../../../../components/ui/Button';
import { fetchConsultationForBooking, getConsultationFileUrl } from '../../../../services/api';
import { generateConsultationPdf } from '../../../../utils/consultationReport';

const fmtDate = (d) => new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });

const useSignedUrl = (kind, path) => {
  const [url, setUrl] = useState(null);
  useEffect(() => {
    let cancelled = false;
    getConsultationFileUrl(kind, path).then(({ url: u }) => { if (!cancelled) setUrl(u); });
    return () => { cancelled = true; };
  }, [kind, path]);
  return url;
};

const Photo = ({ path, label }) => {
  const url = useSignedUrl('image', path);
  return (
    <a href={url || undefined} target="_blank" rel="noopener noreferrer" aria-label={label}
       className="w-24 h-24 rounded-spa border border-border bg-background overflow-hidden flex items-center justify-center">
      {url ? <img src={url} alt={label} className="w-full h-full object-cover" /> : <Icon name="Image" size={20} className="text-text-tertiary" />}
    </a>
  );
};

const Section = ({ title, children }) => (
  <div className="bg-background rounded-spa p-3">
    <h4 className="font-caption font-caption-medium text-[11px] uppercase tracking-wider text-text-tertiary mb-2">{title}</h4>
    {children}
  </div>
);

const Text = ({ value }) => <p className="font-body text-sm text-text-primary whitespace-pre-wrap break-words">{value}</p>;

// Read-only record of one past visit, shown inside the customer profile panel.
const VisitDetail = ({ visit, customerName, notes, onBack }) => {
  const [consultation, setConsultation] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    fetchConsultationForBooking(visit.id).then(({ data }) => {
      if (cancelled) return;
      setConsultation(data);
      setLoading(false);
    });
    return () => { cancelled = true; };
  }, [visit.id]);

  const c = consultation;
  const xrays = c?.xray_image_paths || [];
  const photos = c?.photo_image_paths || [];
  const hasConsultation = c && (c.final_summary || c.preliminary_summary || c.doctor_notes || c.additional_notes
    || c.xray_analysis || c.photo_analysis || xrays.length || photos.length);

  const downloadReport = () => generateConsultationPdf({
    patientName: c.patient_name || customerName,
    attendedBy: c.attended_by_names?.filter(Boolean).join(', ') || c.created_by_name || visit.dentistName,
    bookingNumber: visit.bookingNumber,
    treatment: visit.treatmentName,
    dentist: visit.dentistName,
    sessionDate: c.session_date,
    language: c.detected_language,
    recordingDurationSeconds: c.recording_duration_seconds,
    transcript: c.transcript,
    preliminarySummary: c.preliminary_summary,
    xrayAnalysis: c.xray_analysis,
    photoAnalysis: c.photo_analysis,
    additionalNotes: c.additional_notes,
    doctorNotes: c.doctor_notes,
    finalSummary: c.final_summary,
  });

  return (
    <div className="space-y-4">
      {onBack && (
        <button type="button" onClick={onBack} className="flex items-center gap-1 font-body font-body-medium text-sm text-primary">
          <Icon name="ArrowLeft" size={16} /> Back to profile
        </button>
      )}

      <div className="bg-background rounded-spa p-4">
        <p className="font-heading font-heading-semibold text-base text-text-primary">{visit.treatmentName}</p>
        <p className="font-body text-sm text-text-secondary mt-0.5">{customerName}</p>
        <div className="grid grid-cols-2 gap-3 mt-3 text-xs">
          <div><p className="text-text-tertiary">Date</p><p className="text-text-primary font-body-medium">{fmtDate(visit.date)}</p></div>
          <div><p className="text-text-tertiary">Dentist</p><p className="text-text-primary font-body-medium">{visit.dentistName}</p></div>
          <div><p className="text-text-tertiary">Booking</p><p className="text-text-primary font-body-medium">{visit.bookingNumber}</p></div>
          <div><p className="text-text-tertiary">Status</p><p className="text-text-primary font-body-medium">{visit.status}</p></div>
          <div><p className="text-text-tertiary">Amount</p><p className="text-text-primary font-body-medium">NPR {Number(visit.finalAmount).toLocaleString('en-IN')}</p></div>
          <div><p className="text-text-tertiary">Payment</p><p className={`font-body-medium ${visit.paymentStatus === 'paid' ? 'text-success' : 'text-error'}`}>{visit.paymentStatus === 'paid' ? 'Paid' : 'Unpaid'}</p></div>
        </div>
      </div>

      {loading && (
        <div className="flex justify-center py-8">
          <div className="animate-spin w-6 h-6 border-2 border-primary border-t-transparent rounded-full" />
        </div>
      )}

      {!loading && hasConsultation && (
        <>
          {c.final_summary && <Section title="Final summary"><Text value={c.final_summary} /></Section>}
          {c.preliminary_summary && <Section title="Consultation summary"><Text value={c.preliminary_summary} /></Section>}
          {c.doctor_notes && <Section title="Doctor's notes"><Text value={c.doctor_notes} /></Section>}
          {c.additional_notes && <Section title="Additional notes"><Text value={c.additional_notes} /></Section>}
          {(xrays.length > 0 || c.xray_analysis) && (
            <Section title="X-ray findings">
              <div className="flex flex-wrap gap-2">{xrays.map((p, i) => <Photo key={p} path={p} label={`X-ray ${i + 1}`} />)}</div>
              {c.xray_analysis && <div className="mt-3"><Text value={c.xray_analysis} /></div>}
            </Section>
          )}
          {(photos.length > 0 || c.photo_analysis) && (
            <Section title="Clinical photo findings">
              <div className="flex flex-wrap gap-2">{photos.map((p, i) => <Photo key={p} path={p} label={`Clinical photo ${i + 1}`} />)}</div>
              {c.photo_analysis && <div className="mt-3"><Text value={c.photo_analysis} /></div>}
            </Section>
          )}
          <Button variant="outline" fullWidth iconName="FileText" iconPosition="left" onClick={downloadReport}>
            Download PDF report
          </Button>
        </>
      )}

      {notes.length > 0 && (
        <Section title={`Treatment notes (${notes.length})`}>
          <div className="space-y-3">
            {notes.map((n) => (
              <div key={n.id}>
                <Text value={n.note} />
                <p className="text-xs text-text-secondary mt-1">{n.dentistName} · {fmtDate(n.createdAt)}</p>
              </div>
            ))}
          </div>
        </Section>
      )}

      {!loading && !hasConsultation && notes.length === 0 && (
        <p className="text-center font-body text-sm text-text-tertiary py-6">No consultation notes were recorded for this visit.</p>
      )}
    </div>
  );
};

export default VisitDetail;
