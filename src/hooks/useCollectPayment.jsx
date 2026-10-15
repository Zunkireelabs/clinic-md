import React, { useState, useCallback } from 'react';
import PaymentModal from '../components/ui/PaymentModal';
import { getCustomerOutstandingBalance, recordPayment } from '../services/api';

// "Collect NPR X" for a patient: the same PaymentModal + recordPayment path as the Outstanding report, with every one of the
// patient's due bookings bundled into one payment. `modal` must be rendered by the caller; `onPaid` runs after a successful payment.
export function useCollectPayment({ branchId, onPaid }) {
  const [paying, setPaying] = useState(null); // { primary, others }
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState(null);

  const startCollect = useCallback(async (phone) => {
    setError(null);
    const { data: due, error: err } = await getCustomerOutstandingBalance({ customerPhone: phone, branchId });
    if (err || !due?.bookings?.length) {
      setError(err ? 'Couldn’t load what this patient owes.' : 'Nothing outstanding to collect.');
      onPaid?.();
      return;
    }
    const [primary, ...others] = due.bookings;
    setPaying({ primary, others });
  }, [branchId, onPaid]);

  const confirm = async ({ tenders, additionalAllocations, dueHolderName, notes }) => {
    setSubmitting(true);
    const result = await recordPayment({ bookingId: paying.primary.bookingId, tenders, dueHolderName, notes });
    if (result.error) { setSubmitting(false); return { error: result.error }; }
    for (const alloc of (additionalAllocations || [])) await recordPayment({ bookingId: alloc.bookingId, tenders: alloc.tenders, notes });
    setSubmitting(false);
    setPaying(null);
    await onPaid?.();
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

  return { startCollect, modal, error };
}
