import { jsPDF } from 'jspdf';

// AI summaries come back as light markdown; plain text reads better in a PDF.
export const stripMarkdown = (text = '') =>
  text
    .replace(/^#{1,6}\s*/gm, '')
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/\*(.+?)\*/g, '$1')
    .replace(/^\s*[-*]\s+/gm, '• ')
    .trim();

const safeFilePart = (s = '') => s.replace(/[^a-z0-9]+/gi, '-').replace(/^-+|-+$/g, '').toLowerCase() || 'patient';

// Sections shown in both the PDF and the JSON export, in report order. Private staff notes (additional_notes) are never included.
const sections = (c) => [
  ['Final Summary', c.finalSummary],
  ['Consultation Summary', c.preliminarySummary],
  ['X-ray Analysis', c.xrayAnalysis],
  ['Clinical Photo Analysis', c.photoAnalysis],
  ["Doctor's Notes", c.doctorNotes],
  ['Transcript', c.transcript],
].filter(([, body]) => body && body.trim());

export const consultationFileName = (c, ext) =>
  `consultation-${safeFilePart(c.patientName)}-${c.sessionDate}.${ext}`;

/** Plain object for the "Export Data" JSON download. */
export const buildConsultationExport = (c) => ({
  patientName: c.patientName,
  bookingNumber: c.bookingNumber,
  treatment: c.treatment,
  dentist: c.dentist,
  attendedBy: c.attendedBy,
  sessionDate: c.sessionDate,
  language: c.language,
  recordingDurationSeconds: c.recordingDurationSeconds,
  transcript: c.transcript,
  preliminarySummary: c.preliminarySummary,
  xrayAnalysis: c.xrayAnalysis,
  photoAnalysis: c.photoAnalysis,
  doctorNotes: c.doctorNotes,
  finalSummary: c.finalSummary,
  exportedAt: new Date().toISOString(),
});

export const downloadBlob = (blob, filename) => {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
};

export const exportConsultationJson = (c) =>
  downloadBlob(
    new Blob([JSON.stringify(buildConsultationExport(c), null, 2)], { type: 'application/json' }),
    consultationFileName(c, 'json'),
  );

export const generateConsultationPdf = (c, clinicName = 'ClinicMD') => {
  const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const margin = 48;
  const width = doc.internal.pageSize.getWidth() - margin * 2;
  const bottom = doc.internal.pageSize.getHeight() - margin;
  let y = margin;

  const ensureSpace = (needed) => {
    if (y + needed > bottom) {
      doc.addPage();
      y = margin;
    }
  };

  doc.setFont('helvetica', 'bold').setFontSize(18).setTextColor(15, 110, 140);
  doc.text(clinicName, margin, y);
  y += 22;
  doc.setFontSize(13).setTextColor(40, 40, 40);
  doc.text('Consultation Report', margin, y);
  y += 24;

  const meta = [
    ['Patient', c.patientName],
    ['Date', c.sessionDate],
    ['Booking', c.bookingNumber],
    ['Treatment', c.treatment],
    ['Dentist', c.dentist],
    ['Attended by', c.attendedBy],
  ].filter(([, v]) => v);
  doc.setFontSize(10);
  meta.forEach(([label, value]) => {
    doc.setFont('helvetica', 'bold').text(`${label}:`, margin, y);
    doc.setFont('helvetica', 'normal').text(String(value), margin + 70, y);
    y += 15;
  });
  y += 6;
  doc.setDrawColor(210).line(margin, y, margin + width, y);
  y += 20;

  sections(c).forEach(([title, body]) => {
    ensureSpace(40);
    doc.setFont('helvetica', 'bold').setFontSize(12).setTextColor(15, 110, 140);
    doc.text(title, margin, y);
    y += 16;
    doc.setFont('helvetica', 'normal').setFontSize(10).setTextColor(40, 40, 40);
    doc.splitTextToSize(stripMarkdown(body), width).forEach((line) => {
      ensureSpace(14);
      doc.text(line, margin, y);
      y += 13;
    });
    y += 14;
  });

  const pages = doc.getNumberOfPages();
  for (let i = 1; i <= pages; i += 1) {
    doc.setPage(i);
    doc.setFontSize(8).setTextColor(140);
    doc.text(`Page ${i} of ${pages}`, margin + width, doc.internal.pageSize.getHeight() - 24, { align: 'right' });
  }

  doc.save(consultationFileName(c, 'pdf'));
};
