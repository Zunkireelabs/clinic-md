import React from 'react';

// The patient details, as labelled fields: Patient, Booking, Treatment, Dentist, this
// visit's date, the last visit's date, and who attended.
const Field = ({ label, children, wide = false }) => (
  <div className={wide ? 'col-span-2' : ''}>
    <dt className="text-text-tertiary text-xs mb-0.5">{label}</dt>
    <dd className="text-sm text-text-primary break-words">{children || '—'}</dd>
  </div>
);

const PatientDetailsGrid = ({ patient, booking, treatment, dentist, attendedBy, visitDate, lastVisit }) => (
  <dl className="grid grid-cols-2 gap-x-4 gap-y-3 text-left">
    <Field label="Patient" wide><span className="font-medium">{patient}</span></Field>
    <Field label="Booking">{booking}</Field>
    <Field label="Treatment">{treatment}</Field>
    <Field label="Dentist" wide>{dentist || 'Unassigned'}</Field>
    <Field label="Visit date">{visitDate}</Field>
    <Field label="Last visit">{lastVisit || '…'}</Field>
    <Field label="Attended by" wide>{attendedBy || 'No one yet'}</Field>
  </dl>
);

export default PatientDetailsGrid;
