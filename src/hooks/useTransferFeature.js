import { useEffect, useState } from 'react';
import { probeTransferFeature } from '../services/api';

// null while probing, then true/false (cached across the app). Use `=== true` to show transfer UI.
export function useTransferFeature() {
  const [available, setAvailable] = useState(null);
  useEffect(() => {
    let cancelled = false;
    probeTransferFeature().then((ok) => { if (!cancelled) setAvailable(ok); });
    return () => { cancelled = true; };
  }, []);
  return available;
}
