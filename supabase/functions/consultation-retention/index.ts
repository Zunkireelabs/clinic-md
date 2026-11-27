import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { safeEqual } from '../_shared/channels.ts';

// Recording retention (CMD-54, migration 020): deletes the audio of consultations SIGNED more than 30 days ago. Transcript, note and sources stay.
// Called daily by pg_cron through public.consultation_kick_retention() with the same bearer token as agent-run (CRON_BEARER_TOKEN).
// Body: { dry_run?: boolean }. dry_run returns what it would delete and changes nothing.
// Deletion goes through the Storage API (never by deleting storage.objects rows in SQL). Only paths the Storage API confirms are cleared from the
// row (consultation_mark_audio_deleted re-checks the 30 days, so a draft or a recent note can never lose its audio); anything that failed stays and
// is retried the next night. Logs hold ids and counts only, never paths, names or tokens.
const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

const BUCKET = 'consultation-audio';
const BATCH = 200;

Deno.serve(async (req: Request): Promise<Response> => {
  const expected = Deno.env.get('CRON_BEARER_TOKEN');
  const provided = (req.headers.get('Authorization') ?? '').replace(/^Bearer /, '');
  if (!expected) return json({ ok: false, error: 'not configured' }, 500);
  if (!provided || !safeEqual(provided, expected)) return json({ ok: false, error: 'unauthorized' }, 403);

  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ ok: false, error: 'not configured' }, 500);
  const supabase = createClient(url, key, { auth: { persistSession: false } });

  const body = await req.json().catch(() => ({}));
  const dryRun = body?.dry_run === true;

  const { data: due, error } = await supabase.rpc('consultation_retention_due', { p_limit: BATCH });
  if (error) { console.error('[RETENTION_DUE_FAILED]', error.code); return json({ ok: false, error: 'could not list due recordings' }, 500); }
  const rows = (due ?? []) as { id: string; audio_paths: string[] }[];

  if (dryRun) {
    return json({ ok: true, dry_run: true, would_delete: rows.map((r) => ({ id: r.id, paths: r.audio_paths })) });
  }

  let consultations = 0; let files = 0; let failed = 0;
  for (const r of rows) {
    const paths = (r.audio_paths ?? []).filter((p) => typeof p === 'string' && p);
    if (!paths.length) continue;
    const { data: removed, error: removeError } = await supabase.storage.from(BUCKET).remove(paths);
    // remove() returns the objects it deleted. A path that no longer exists is not returned; treat it as gone (nothing left to delete).
    if (removeError) { failed += 1; console.error('[RETENTION_REMOVE_FAILED]', r.id); continue; }
    const deletedNames = new Set((removed ?? []).map((o: { name: string }) => o.name));
    const { data: existing } = await supabase.storage.from(BUCKET).list(paths[0].split('/').slice(0, 2).join('/'), { limit: 1000 });
    const stillThere = new Set((existing ?? []).map((o: { name: string }) => `${paths[0].split('/').slice(0, 2).join('/')}/${o.name}`));
    const cleared = paths.filter((p) => deletedNames.has(p) || !stillThere.has(p));
    const { data: marked, error: markError } = await supabase.rpc('consultation_mark_audio_deleted', { p_consultation: r.id, p_deleted_paths: cleared });
    if (markError || !marked?.ok) { failed += 1; console.error('[RETENTION_MARK_FAILED]', r.id, markError?.code ?? marked?.code); continue; }
    consultations += 1; files += cleared.length;
  }
  console.log(`[RETENTION] consultations=${consultations} files=${files} failed=${failed}`);
  return json({ ok: true, consultations, files, failed });
});
