// Where the consultation functions send OpenAI requests. OPENAI_BASE_URL exists ONLY so local tests can point at a fake OpenAI; it is unset in
// production, where the real API is used. Allowed: any https URL, or http to 127.0.0.1 / localhost / host.docker.internal (local tests).
// Anything else falls back to the real API, so a mistyped value can never send a recording somewhere unexpected over plain http.
// The key is never part of the URL and is never logged here.

export const OPENAI_DEFAULT_BASE = 'https://api.openai.com/v1';

export function openaiBase(raw: string | undefined | null): string {
  const value = (raw ?? '').trim();
  if (!value) return OPENAI_DEFAULT_BASE;
  let u: URL;
  try { u = new URL(value); } catch { return OPENAI_DEFAULT_BASE; }
  const localHttp = u.protocol === 'http:' && ['127.0.0.1', 'localhost', 'host.docker.internal'].includes(u.hostname);
  if (u.protocol !== 'https:' && !localHttp) return OPENAI_DEFAULT_BASE;
  if (u.username || u.password) return OPENAI_DEFAULT_BASE;
  return value.replace(/\/+$/, '');
}

/** Full URL for an OpenAI path such as '/chat/completions', honouring OPENAI_BASE_URL as above. */
export const openaiUrl = (path: string, raw: string | undefined | null): string => `${openaiBase(raw)}${path.startsWith('/') ? path : `/${path}`}`;
