import { useAuth } from '../contexts/AuthContext';
import { CONSULTATION_ENABLED } from '../lib/featureFlags';
import { isAiConsultationAvailable } from '../utils/aiConsultation';

// True only when this build has consultations AND the signed-in clinic's AI switch is on. The flag is read once when the profile
// loads (AuthContext), not per component.
export const useAiConsultationEnabled = () => {
  const { aiEnabled } = useAuth();
  return isAiConsultationAvailable(CONSULTATION_ENABLED, aiEnabled);
};
