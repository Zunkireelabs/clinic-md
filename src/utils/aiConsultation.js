// The per-clinic AI switch. Consultation AI is available only when the build has the feature
// (VITE_ENABLE_CONSULTATION) AND the signed-in user's clinic has been switched on (organizations.ai_consultation_enabled,
// read through the org_ai_enabled() function). Anything uncertain counts as OFF.
export const isAiConsultationAvailable = (buildFlag, orgFlag) => buildFlag === true && orgFlag === true;

// `rpc` is supabase.rpc bound to the client. Fails CLOSED: an error, a missing function (migration-010 not applied) or any
// value other than `true` means the clinic is not switched on.
export async function loadOrgAiEnabled(rpc) {
  try {
    const { data, error } = await rpc('org_ai_enabled');
    if (error) return false;
    return data === true;
  } catch {
    return false;
  }
}
