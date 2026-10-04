import { useEffect, useState } from 'react';
import { fetchLastVisit } from '../services/api';
import { lastVisitLabel } from '../utils/visitDates';

/** The patient's last visit before this booking, as text ("12 Sep 2026" or "First visit"); '' while loading. */
export default function useLastVisit(customerId, bookingId) {
  const [label, setLabel] = useState('');
  useEffect(() => {
    if (!bookingId) return undefined;
    let cancelled = false;
    setLabel('');
    fetchLastVisit(customerId, bookingId).then(({ data }) => { if (!cancelled) setLabel(lastVisitLabel(data)); });
    return () => { cancelled = true; };
  }, [customerId, bookingId]);
  return label;
}
