import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { safeEqual } from '../_shared/channels.ts';
import { runAgentJobs, type AgentDeps } from '../_shared/agent.ts';

// The Follow-up agent's runner. Called by pg_cron through public.agent_kick_runner() every minute when a job is due.
// Auth: the same bearer token the hub and the outreach drain use (CRON_BEARER_TOKEN). It calls only database FUNCTIONS (rpc), never a table.
// Secrets stay in this function's env; the model key is read inside _shared/model.ts and nowhere else. Nothing here logs a body or a secret.
const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req: Request): Promise<Response> => {
  const expected = Deno.env.get('CRON_BEARER_TOKEN');
  const provided = (req.headers.get('Authorization') ?? '').replace(/^Bearer /, '');
  if (!expected) return json({ ok: false, error: 'not configured' }, 500);
  if (!provided || !safeEqual(provided, expected)) return json({ ok: false, error: 'unauthorized' }, 403);

  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ ok: false, error: 'not configured' }, 500);
  const supabase = createClient(url, key, { auth: { persistSession: false } });

  const deps: AgentDeps = {
    rpc: (fn, args) => supabase.rpc(fn, args) as never,
    env: (name) => Deno.env.get(name),
    log: (line) => console.log(line),   // job ids, statuses and codes only (agent.ts never passes anything else)
  };
  try {
    const summary = await runAgentJobs(deps);
    return json({ ok: true, ...summary });
  } catch {
    return json({ ok: false, error: 'run failed' }, 500);
  }
});
