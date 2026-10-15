import React, { useState, useCallback } from 'react';
import PaymentModal from '../components/ui/PaymentModal';
import { getCustomerOutstandingBalance, getCustomerDueBookings, recordPayment } from '../services/api';

const npr = (n) => `NPR ${Number(n || 0).toLocaleString('en-IN')}`;

// "Collect NPR X" for a patient: the same PaymentModal + recordPayment path as the Outstanding report, with every one of the patient's
// COLLECTABLE due bookings bundled into one payment. Bookings on closed (locked) days are never bundled; they are reported in
// `lockedNote` until the closed-day policy is decided. `modal` must be rendered by the caller; `onPaid` runs after payments change.
//  - pass `customerId` to collect across the same scope the chart's balance covers (all the patient's bookings you can see);
//  - otherwise the lookup is by phone within `branchId` (the calendar / booking-form scope).
export function useCollectPayment({ branchId, customerId, onPaid }) {
  const [paying, setPaying] = useState(null); // { primary, others }
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState(null);
  const [lockedNote, setLockedNote] = useState(null);

  const startCollect = useCallback(async (phone, customerIdOverride) => {
    const byCustomer = customerIdOverride || customerId;
    setError(null);
    setLockedNote(null);
    const { data: due, error: err } = byCustomer
      ? await getCustomerDueBookings(byCustomer)
      : await getCustomerOutstandingBalance({ customerPhone: phone, branchId });
    if (!err && due?.lockedDue > 0) setLockedNote(`${npr(due.lockedDue)} on closed days can’t be collected here.`);
    if (err || !due?.bookings?.length) {
      setError(err ? 'Couldn’t load what this patient owes.' : (due?.lockedDue > 0 ? 'The remaining balance is on closed days and can’t be collected here.' : 'Nothing outstanding to collect.'));
      onPaid?.();
      return;
    }
    const [primary, ...others] = due.bookings;
    setPaying({ primary, others });
  }, [branchId, customerId, onPaid]);

  const confirm = async ({ tenders, additionalAllocations, dueHolderName, notes }) => {
    setSubmitting(true);
    const result = await recordPayment({ bookingId: paying.primary.bookingId, tenders, dueHolderName, notes });
    if (result.error) { setSubmitting(false); return { error: result.error }; } // nothing recorded: the modal stays open with the reason
    // Every bundled booking is its own payment. Check each one: a failure must never be swallowed.
    const failures = [];
    for (const alloc of (additionalAllocations || [])) {
      const res = await recordPayment({ bookingId: alloc.bookingId, tenders: alloc.tenders, notes });
      if (res.error) {
        const row = paying.others.find((o) => o.bookingId === alloc.bookingId);
        failures.push(`${row?.bookingNumber || alloc.bookingId}${res.error.message ? ` (${res.error.message})` : ''}`);
      }
    }
    setSubmitting(false);
    setPaying(null);
    await onPaid?.();
    if (failures.length) {
      setError(`Payment recorded for ${paying.primary.bookingNumber}, but NOT recorded for: ${failures.join('; ')}. Those bookings still show as owed.`);
    }
    return { error: null };
  };

  const modal = paying && (
    <PaymentModal
      booking={{
        bookingId: paying.primary.bookingId,
        booking_number: paying.primary.bookingNumber,
        finalAmount: paying.primary.finalAmount,
        amountPaid: paying.primary.amountPaid,
        treatment: paying.primary.treatmentName,
        dueHolderName: '',
      }}
      additionalBookings={paying.others}
      onConfirm={confirm}
      onClose={() => setPaying(null)}
      isSubmitting={submitting}
    />
  );

  return { startCollect, modal, error, lockedNote };
}
