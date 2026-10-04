// After logging in, return to the page the user was sent to log in from (e.g.
// a consultation link scanned on a phone). Only same-org paths are honoured so
// a crafted ?next= link can't send someone to another site or another org.
export const safeNextPath = (next, orgSlug) => {
  if (!next || !orgSlug || typeof next !== 'string') return null;
  if (!next.startsWith(`/${orgSlug}/`) || next.startsWith('//') || next.includes('\\')) return null;
  return next;
};

export const loginPathWithNext = (orgSlug, pathname, search = '') =>
  `/${orgSlug}/login?next=${encodeURIComponent(`${pathname}${search}`)}`;
