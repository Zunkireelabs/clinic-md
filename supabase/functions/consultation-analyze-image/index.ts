import { encodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts';
import { authenticate, corsHeaders, json, keyMissing } from '../_shared/consultation.ts';

const PROMPTS: Record<string, string> = {
  xray: `You are assisting a dentist reviewing dental radiographs (X-rays). Describe visible findings: bone levels, caries, periapical areas, restorations, impacted or missing teeth, and anything abnormal. Be factual, note image-quality limits, and do not state a definitive diagnosis; the dentist makes the final assessment.`,
  photo: `You are assisting a dentist reviewing intraoral or facial clinical photographs. Describe visible findings: gum condition, plaque or calculus, discolouration, wear, restorations, swelling or lesions. Be factual, note image-quality limits, and do not state a definitive diagnosis; the dentist makes the final assessment.`,
};

// Body: { kind: 'xray' | 'photo', imagePaths: string[] } (paths in the
// private consultation-images bucket).
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const auth = await authenticate(req);
  if (auth instanceof Response) return auth;

  const apiKey = Deno.env.get('GEMINI_API_KEY');
  if (!apiKey) return keyMissing('GEMINI_API_KEY');

  const { kind, imagePaths } = await req.json().catch(() => ({}));
  if (!PROMPTS[kind]) return json({ error: "kind must be 'xray' or 'photo'" }, 400);
  if (!Array.isArray(imagePaths) || imagePaths.length === 0) return json({ error: 'imagePaths is required' }, 400);

  const parts: unknown[] = [{ text: PROMPTS[kind] }];
  for (const path of imagePaths.slice(0, 6)) {
    const { data: blob, error } = await auth.supabase.storage.from('consultation-images').download(path);
    if (error || !blob) return json({ error: `Could not read image ${path}` }, 404);
    parts.push({ inline_data: { mime_type: blob.type || 'image/jpeg', data: encodeBase64(new Uint8Array(await blob.arrayBuffer())) } });
  }

  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent?key=${apiKey}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ contents: [{ parts }], generationConfig: { temperature: 0.1 } }),
    },
  );
  if (!res.ok) return json({ error: 'Image analysis failed', detail: (await res.text()).slice(0, 500) }, 502);

  const result = await res.json();
  const analysis = result.candidates?.[0]?.content?.parts?.map((p: { text?: string }) => p.text ?? '').join('') ?? '';
  return json({ analysis });
});
