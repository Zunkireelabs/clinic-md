// What the consultation page shows when opening it fails. Front desk (role 'staff') is refused by RLS (42501 / our own FORBIDDEN);
// that is correct, so it gets a plain sentence. Anything else is generic: the raw error goes to the console only.
export function consultationLoadError(error) {
  const denied = error && (error.code === '42501' || error.code === 'FORBIDDEN' || /row-level security/i.test(error.message || ''));
  if (denied) return { kind: 'forbidden', title: 'Consultation notes are for practitioners and managers.', hint: 'Ask the dentist to open this visit.' };
  return { kind: 'error', title: 'Something went wrong opening this consultation. Try again.', hint: null };
}

// Entry points hide the consultation button from front desk and read-only users.
export const canOpenConsultation = (role) => role !== 'admin_viewer' && role !== 'staff';
