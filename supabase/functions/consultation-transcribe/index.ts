import { authenticate, corsHeaders, json, keyMissing, providerFailed, serviceClient } from '../_shared/consultation.ts';
import { openaiUrl } from '../_shared/openai.ts';

// Transcribes a consultation recording already uploaded to the private consultation-audio bucket.
// Body: { audioPath: string, consultationId?: string }.
//
// Migration 020 (CMD-54):
//  * role 'staff' (front desk) is refused (FORBIDDEN_ROLE), before the AI switch and the quota.
//  * with consultationId: the row is read through the CALLER's client (RLS proves they can see it) and must belong to the booking in audioPath
//    ("<org>/<booking>/<file>"). The whisper segments are then stored with consultation_store_segments (service role), so note sources can be
//    checked against them later.
//  * CONSULT_REQUIRE_CONSENT=true (default false): no consultationId, a row the caller can't read, a different booking, or
//    recording_consent <> 'agreed' -> 403 CONSENT_REQUIRED, checked before the quota is used and before the audio is downloaded.
//    Turn it on only after both the computer and the phone are confirmed storing consent in production (see the PR's production notes).
const requireConsent = () => (Deno.env.get('CONSULT_REQUIRE_CONSENT') ?? '').toLowerCase() === 'true';

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const body = await req.json().catch(() => ({}));
  const { audioPath, consultationId } = body ?? {};
  if (!audioPath || typeof audioPath !== 'string') return json({ error: 'audioPath is required' }, 400);

  // auth WITHOUT the quota first: a call refused for consent must not cost a quota slot
  const auth = await authenticate(req, { requireStaff: true, clinicalRole: true, requireAiEnabled: true });
  if (auth instanceof Response) return auth;

  let row: { id: string; booking_id: string; recording_consent: string | null } | null = null;
  if (typeof consultationId === 'string' && consultationId) {
    const { data } = await auth.supabase.from('consultations').select('id, booking_id, recording_consent').eq('id', consultationId).maybeSingle();
    if (data && audioPath.split('/')[1] === data.booking_id) row = data;
  }
  if (requireConsent() && row?.recording_consent !== 'agreed') {
    return json({ error: 'CONSENT_REQUIRED', message: 'Record that the patient agreed to the recording first.' }, 403);
  }

  const quota = await authenticate(req, { quota: true });     // now count it against the hourly AI quota
  if (quota instanceof Response) return quota;

  const apiKey = Deno.env.get('OPENAI_API_KEY');
  if (!apiKey) return keyMissing('OPENAI_API_KEY');

  const { data: blob, error } = await auth.supabase.storage.from('consultation-audio').download(audioPath);
  if (error || !blob) return json({ error: 'Could not read the recording' }, 404);

  // OpenAI accepts at most 25 MB; refuse early with a friendly code instead of a provider error.
  if (blob.size > 25 * 1024 * 1024) return json({ error: 'FILE_TOO_LARGE', message: 'This recording is too large to transcribe. Record in shorter parts.' }, 413);

  const form = new FormData();
  form.append('file', blob, audioPath.split('/').pop() || 'recording.webm');
  form.append('model', 'whisper-1');
  form.append('response_format', 'verbose_json');
  form.append('prompt', 'Dental consultation between a dentist and a patient. Terms: caries, extraction, root canal, crown, scaling, orthodontic.');

  const res = await fetch(openaiUrl('/audio/transcriptions', Deno.env.get('OPENAI_BASE_URL')), {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
  });
  if (!res.ok) return providerFailed('AI_FAILED', "Couldn't process this. Try again.", await res.text());

  const result = await res.json();
  let segmentsStored = 0;
  if (row && Array.isArray(result.segments)) {
    const segments = result.segments.map((s: { start?: unknown; end?: unknown; text?: unknown }) => ({ start: s.start, end: s.end, text: s.text }));
    const { data: stored, error: storeError } = await serviceClient().rpc('consultation_store_segments', {
      p_consultation: row.id, p_user: auth.user.id, p_audio_path: audioPath, p_segments: segments,
    });
    if (storeError || !stored?.ok) console.error('[SEGMENTS_NOT_STORED]', storeError?.message ?? stored?.code); // never blocks the transcript
    else segmentsStored = stored.stored ?? 0;
  }
  return json({ text: result.text ?? '', language: result.language ?? null, segments_stored: segmentsStored });
});
