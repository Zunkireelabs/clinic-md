import { authenticate, corsHeaders, json, keyMissing } from '../_shared/consultation.ts';

// Transcribes a consultation recording already uploaded to the private
// consultation-audio bucket. Body: { audioPath: string }.
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const auth = await authenticate(req);
  if (auth instanceof Response) return auth;

  const apiKey = Deno.env.get('OPENAI_API_KEY');
  if (!apiKey) return keyMissing('OPENAI_API_KEY');

  const { audioPath } = await req.json().catch(() => ({}));
  if (!audioPath || typeof audioPath !== 'string') return json({ error: 'audioPath is required' }, 400);

  const { data: blob, error } = await auth.supabase.storage.from('consultation-audio').download(audioPath);
  if (error || !blob) return json({ error: 'Could not read the recording' }, 404);

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
  if (!res.ok) return json({ error: 'Transcription failed', detail: (await res.text()).slice(0, 500) }, 502);

  const result = await res.json();
  return json({ text: result.text ?? '', language: result.language ?? null });
});
