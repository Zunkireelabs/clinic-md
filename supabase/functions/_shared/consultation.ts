import { createClient, SupabaseClient, User } from 'https://esm.sh/@supabase/supabase-js@2';

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

// Returned when an AI provider key has not been configured yet, so the UI can
// show a friendly message instead of a generic failure.
export const keyMissing = (name: string): Response =>
  json({ error: 'AI_KEY_MISSING', message: `${name} is not configured on the server.` }, 503);

export interface AuthedRequest {
  supabase: SupabaseClient;
  user: User;
}

export interface AuthOptions {
  /** Require an active users row with role staff / manager / admin (patients and self-registered customers are rejected). */
  requireStaff?: boolean;
  /** Count this call against the per-user hourly AI quota (cost control). */
  quota?: boolean;
}

export const AI_CALLS_PER_HOUR = 60;

// A provider error is logged on the server and the client gets a generic message + a code. Never forward provider text.
export const providerFailed = (code: string, message: string, detail: string, status = 502): Response => {
  console.error(`[${code}]`, detail.slice(0, 500));
  return json({ error: code, message }, status);
};

// Verifies the caller's JWT and returns a client that acts as that user, so
// storage reads still go through RLS (branch-scoped consultation buckets).
export const authenticate = async (req: Request, opts: AuthOptions = {}): Promise<AuthedRequest | Response> => {
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Missing Authorization header' }, 401);

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) return json({ error: 'Invalid or expired session' }, 401);

  if (opts.requireStaff) {
    const { data: profile } = await supabase.from('users').select('role, is_active').eq('id', data.user.id).maybeSingle();
    if (!profile || profile.is_active === false || !['staff', 'manager', 'admin'].includes(profile.role)) {
      return json({ error: 'FORBIDDEN', message: 'Your account can’t use this feature.' }, 403); // generic: also returned by phone-pair and consultation-push
    }
  }
  if (opts.quota) {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: allowed, error: quotaError } = await admin.rpc('consume_ai_quota', { p_user: data.user.id, p_limit: AI_CALLS_PER_HOUR });
    if (quotaError) console.error('[AI_QUOTA_CHECK]', quotaError.message); // fail open on a quota-store problem, never block clinical work
    else if (allowed === false) return json({ error: 'AI_QUOTA', message: 'Too many AI requests this hour. Try again later.' }, 429);
  }
  return { supabase, user: data.user };
};
