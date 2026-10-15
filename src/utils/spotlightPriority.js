// One banner per page: of the candidates (in priority order) the first that should show wins; the rest wait until it is dismissed.
export const pickSpotlight = (candidates) => candidates.find((c) => c.show)?.id ?? null;

// The money-model notice is for the people who read the money figures.
export const canSeeMoneyNotice = (role) => role === 'admin' || role === 'manager';
