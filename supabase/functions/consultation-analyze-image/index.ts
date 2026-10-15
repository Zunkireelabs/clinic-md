import { encodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts';
import { authenticate, corsHeaders, json, keyMissing, providerFailed } from '../_shared/consultation.ts';

const PROMPTS: Record<string, string> = {
  xray: `You are assisting a dentist reviewing dental radiographs (X-rays). Describe visible findings: bone levels, caries, periapical areas, restorations, impacted or missing teeth, and anything abnormal. Be factual, note image-quality limits, and do not state a definitive diagnosis; the dentist makes the final assessment.`,
  photo: `You are assisting a dentist reviewing intraoral or facial clinical photographs. Describe visible findings: gum condition, plaque or calculus, discolouration, wear, restorations, swelling or lesions. Be factual, note image-quality limits, and do not state a definitive diagnosis; the dentist makes the final assessment.`,
};

// Body: { kind: 'xray' | 'photo', imagePaths: string[] } (paths in the
// private consultation-images bucket).
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const auth = await authenticate(req, { requireStaff: true, requireAiEnabled: true, quota: true });
  if (auth instanceof Response) return auth;

  const apiKey = Deno.env.get('OPENAI_API_KEY');
  if (!apiKey) return keyMissing('OPENAI_API_KEY');

  const { kind, imagePaths } = await req.json().catch(() => ({}));
  if (!PROMPTS[kind]) return json({ error: "kind must be 'xray' or 'photo'" }, 400);
  if (!Array.isArray(imagePaths) || imagePaths.length === 0) return json({ error: 'imagePaths is required' }, 400);

  // OpenAI vision (Chat Completions with image inputs), same model as consultation-summarize. Images are read with the
  // caller's JWT (storage RLS) and sent inline as base64 data URLs.
  const content: unknown[] = [{ type: 'text', text: PROMPTS[kind] }];
  for (const path of imagePaths.slice(0, 6)) {
    const { data: blob, error } = await auth.supabase.storage.from('consultation-images').download(path);
    if (error || !blob) return json({ error: `Could not read image ${path}` }, 404);
    const mime = blob.type || 'image/jpeg';
    content.push({ type: 'image_url', image_url: { url: `data:${mime};base64,${encodeBase64(new Uint8Array(await blob.arrayBuffer()))}` } });
  }

  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'gpt-4o',
      temperature: 0.1,
      max_tokens: 1500,
      messages: [{ role: 'user', content }],
    }),
  });
  if (!res.ok) return providerFailed('AI_FAILED', "Couldn't process this. Try again.", await res.text());

  const result = await res.json();
  return json({ analysis: result.choices?.[0]?.message?.content ?? '' });
});
