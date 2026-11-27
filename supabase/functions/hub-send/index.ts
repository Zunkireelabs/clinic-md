import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { safeEqual } from '../_shared/channels.ts';
import { runHubSend, type HubDeps } from '../_shared/hub.ts';

// The communication hub's sender. Called by pg_cron through public.hub_kick_sender(): every minute with {"mode":"send"} when a message is due,
// every 5 minutes with {"mode":"poll"} to pull delivery reports from providers that only offer a pull (Aakash).
// Auth: the same bearer token the outreach drain uses (CRON_BEARER_TOKEN). Secrets stay in this function's env: a channel account stores only
// the NAME of the variable (secret_ref), e.g. AAKASH_AUTH_TOKEN.
const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req: Request): Promise<Response> => {
  const expected = Deno.env.get('CRON_BEARER_TOKEN');
  const provided = (req.headers.get('Authorization') ?? '').replace(/^Bearer /, '');
  if (!expected) return json({ ok: false, error: 'not configured' }, 500);
  if (!provided || !safeEqual(provided, expected)) return json({ ok: false, error: 'unauthorized' }, 403);

  let mode: 'send' | 'poll' = 'send';
  try {
    const body = await req.json();
    if (body?.mode === 'poll') mode = 'poll';
  } catch { /* no body: send */ }

  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ ok: false, error: 'not configured' }, 500);
  const supabase = createClient(url, key, { auth: { persistSession: false } });

  const deps: HubDeps = {
    rpc: (fn, args) => supabase.rpc(fn, args) as never,
    env: (name) => Deno.env.get(name),
    recordTest: async ({ messageId, to, body }) => {
      const { error } = await supabase.from('hub_test_outbox').insert({ message_id: messageId ?? crypto.randomUUID(), to_address: to, body });
      if (error) throw new Error('could not write the test outbox');
    },
  };
  const summary = await runHubSend(deps, mode);
  return json({ ok: true, mode, ...summary });
});
