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

// Verifies the caller's JWT and returns a client that acts as that user, so
// storage reads still go through RLS (org-scoped consultation buckets).
export const authenticate = async (req: Request): Promise<AuthedRequest | Response> => {
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Missing Authorization header' }, 401);

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) return json({ error: 'Invalid or expired session' }, 401);
  return { supabase, user: data.user };
};
