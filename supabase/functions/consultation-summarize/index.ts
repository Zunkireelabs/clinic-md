import { authenticate, corsHeaders, json, keyMissing } from '../_shared/consultation.ts';

const SYSTEM = `You are a clinical documentation assistant for a dental clinic. Write clear, factual notes for the treating dentist from the material provided. Never invent findings, diagnoses or medications that are not in the material. If something is unclear, say so. Use short headed sections and bullet points.`;

const PRELIMINARY_PROMPT = `Summarise this dental consultation transcript. Sections: Chief Complaint, History, Findings Discussed, Proposed Treatment, Follow-up.`;
const FINAL_PROMPT = `Combine everything below into one final consultation summary. Sections: Chief Complaint, Clinical Findings, Radiograph (X-ray) Findings, Clinical Photo Findings, Assessment, Treatment Plan, Follow-up. Skip a section if there is no information for it.`;

const part = (label: string, value?: string) => (value?.trim() ? `### ${label}\n${value.trim()}\n` : '');

// Body: { mode: 'preliminary' | 'final', transcript?, preliminarySummary?,
//         xrayAnalysis?, photoAnalysis?, additionalNotes?, doctorNotes? }
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const auth = await authenticate(req);
  if (auth instanceof Response) return auth;

  const apiKey = Deno.env.get('OPENAI_API_KEY');
  if (!apiKey) return keyMissing('OPENAI_API_KEY');

  const b = await req.json().catch(() => ({}));
  const mode = b.mode === 'final' ? 'final' : 'preliminary';
  if (mode === 'preliminary' && !b.transcript?.trim()) return json({ error: 'transcript is required' }, 400);
  if (mode === 'final' && ![b.preliminarySummary, b.transcript, b.xrayAnalysis, b.photoAnalysis, b.doctorNotes].some((v) => v?.trim())) {
    return json({ error: 'Nothing to summarise yet' }, 400);
  }

  const material = mode === 'preliminary'
    ? part('Transcript', b.transcript)
    : [
        part('Preliminary summary', b.preliminarySummary),
        part('Transcript', b.transcript),
        part('X-ray analysis', b.xrayAnalysis),
        part('Clinical photo analysis', b.photoAnalysis),
        part('Additional notes', b.additionalNotes),
        part("Doctor's notes", b.doctorNotes),
      ].join('\n');

  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'gpt-4o',
      temperature: 0.3,
      max_tokens: mode === 'final' ? 2500 : 1500,
      messages: [
        { role: 'system', content: SYSTEM },
        { role: 'user', content: `${mode === 'final' ? FINAL_PROMPT : PRELIMINARY_PROMPT}\n\n${material}` },
      ],
    }),
  });
  if (!res.ok) return json({ error: 'Summary failed', detail: (await res.text()).slice(0, 500) }, 502);

  const result = await res.json();
  return json({ summary: result.choices?.[0]?.message?.content ?? '' });
});
