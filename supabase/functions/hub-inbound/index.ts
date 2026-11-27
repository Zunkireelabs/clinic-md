import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { handleInbound, type HubDeps } from '../_shared/hub.ts';

// The communication hub's inbound webhook: /functions/v1/hub-inbound/<provider>[/<token>]. It is PUBLIC (no Supabase JWT: see config.toml) and
// authenticates each provider its own way (see _shared/hub.ts). It uses the service role only to call act_message_receive and the status functions.
Deno.serve(async (req: Request): Promise<Response> => {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return new Response(JSON.stringify({ ok: false }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  const supabase = createClient(url, key, { auth: { persistSession: false } });
  const deps: HubDeps = {
    rpc: (fn, args) => supabase.rpc(fn, args) as never,
    env: (name) => Deno.env.get(name),
    recordTest: async () => { /* not used by the inbound path */ },
  };
  return handleInbound(req, deps);
});
