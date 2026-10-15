import { authenticate, corsHeaders, json, keyMissing, providerFailed } from '../_shared/consultation.ts';

// Transcribes a consultation recording already uploaded to the private
// consultation-audio bucket. Body: { audioPath: string }.
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const auth = await authenticate(req, { requireStaff: true, requireAiEnabled: true, quota: true });
  if (auth instanceof Response) return auth;

  const apiKey = Deno.env.get('OPENAI_API_KEY');
  if (!apiKey) return keyMissing('OPENAI_API_KEY');

  const { audioPath } = await req.json().catch(() => ({}));
  if (!audioPath || typeof audioPath !== 'string') return json({ error: 'audioPath is required' }, 400);

  const { data: blob, error } = await auth.supabase.storage.from('consultation-audio').download(audioPath);
  if (error || !blob) return json({ error: 'Could not read the recording' }, 404);

  // OpenAI accepts at most 25 MB; refuse early with a friendly code instead of a provider error.
  if (blob.size > 25 * 1024 * 1024) return json({ error: 'FILE_TOO_LARGE', message: 'This recording is too large to transcribe. Record in shorter parts.' }, 413);

  const form = new FormData();
  form.append('file', blob, audioPath.split('/').pop() || 'recording.webm');
  form.append('model', 'whisper-1');
  form.append('response_format', 'verbose_json');
  form.append('prompt', 'Dental consultation between a dentist and a patient. Terms: caries, extraction, root canal, crown, scaling, orthodontic.');

  const res = await fetch('https://api.openai.com/v1/audio/transcriptions', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
  });
  if (!res.ok) return providerFailed('AI_FAILED', "Couldn't process this. Try again.", await res.text());

  const result = await res.json();
  return json({ text: result.text ?? '', language: result.language ?? null });
});
