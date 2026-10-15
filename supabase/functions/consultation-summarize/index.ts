import { authenticate, corsHeaders, json, keyMissing, providerFailed } from '../_shared/consultation.ts';

const SYSTEM = `You are a clinical documentation assistant for a dental clinic. Write clear, factual notes for the treating dentist from the material provided. Never invent findings, diagnoses or medications that are not in the material. If something is unclear, say so. Use short headed sections and bullet points.`;

const PRELIMINARY_PROMPT = `Summarise this dental consultation transcript. Sections: Chief Complaint, History, Findings Discussed, Proposed Treatment, Follow-up.`;
const FINAL_PROMPT = `Combine everything below into one final consultation summary. Sections: Chief Complaint, Clinical Findings, Radiograph (X-ray) Findings, Clinical Photo Findings, Assessment, Treatment Plan, Follow-up. Skip a section if there is no information for it.`;

// mode 'note': the structured six-section clinical note the consultation page edits. Returned as JSON via OpenAI structured
// outputs, so the client never parses free text. Private staff notes are deliberately NOT accepted as input here.
const NOTE_PROMPT = `Write the clinical note for this dental consultation from the material below, as structured fields for the treating dentist.
Rules: use only what is in the material; never invent findings, diagnoses, medications or numbers. If something wasn't discussed, leave that field as an empty string. Write concise clinical English even if the conversation was in another language. For "plan", use "- " bullet lines, one action per line. "previous plan" is context only: do not copy it unless it was discussed.`;

const NOTE_SCHEMA = {
  name: 'clinical_note',
  strict: true,
  schema: {
    type: 'object',
    additionalProperties: false,
    required: ['chief_complaint', 'history', 'findings', 'assessment', 'plan', 'follow_up'],
    properties: {
      chief_complaint: { type: 'string', description: 'Why the patient came in' },
      history: { type: 'string', description: 'Relevant history and previous treatment' },
      findings: { type: 'string', description: 'Clinical and radiograph findings' },
      assessment: { type: 'string', description: 'Diagnosis or impression' },
      plan: { type: 'string', description: 'Treatment plan, "- " bullets' },
      follow_up: { type: 'string', description: 'When to see the patient next' },
    },
  },
};

const part = (label: string, value?: string) => (value?.trim() ? `### ${label}\n${value.trim()}\n` : '');

// Body: { mode: 'preliminary' | 'final' | 'note', transcript?, preliminarySummary?,
//         xrayAnalysis?, photoAnalysis?, doctorNotes?, previousPlan? }
// `additionalNotes` (the private staff notes) is never read in ANY mode: it must not reach the model or any report.
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const auth = await authenticate(req, { requireStaff: true, quota: true });
  if (auth instanceof Response) return auth;

  const apiKey = Deno.env.get('OPENAI_API_KEY');
  if (!apiKey) return keyMissing('OPENAI_API_KEY');

  const b = await req.json().catch(() => ({}));
  const mode = b.mode === 'final' ? 'final' : b.mode === 'note' ? 'note' : 'preliminary';
  if (mode === 'preliminary' && !b.transcript?.trim()) return json({ error: 'transcript is required' }, 400);
  if (mode === 'final' && ![b.preliminarySummary, b.transcript, b.xrayAnalysis, b.photoAnalysis, b.doctorNotes].some((v) => v?.trim())) {
    return json({ error: 'Nothing to summarise yet' }, 400);
  }

  if (mode === 'note') {
    if (![b.transcript, b.xrayAnalysis, b.photoAnalysis].some((v) => v?.trim())) return json({ error: 'Nothing to draft from yet' }, 400);
    const noteMaterial = [
      part('Transcript', b.transcript),
      part('X-ray analysis', b.xrayAnalysis),
      part('Clinical photo analysis', b.photoAnalysis),
      part('Previous plan (context only)', b.previousPlan),
    ].join('\n');
    const noteRes = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'gpt-4o',
        temperature: 0.2,
        max_tokens: 1800,
        response_format: { type: 'json_schema', json_schema: NOTE_SCHEMA },
        messages: [
          { role: 'system', content: SYSTEM },
          { role: 'user', content: `${NOTE_PROMPT}\n\n${noteMaterial}` },
        ],
      }),
    });
    if (!noteRes.ok) return providerFailed('AI_FAILED', "Couldn't process this. Try again.", await noteRes.text());
    const noteJson = await noteRes.json();
    try {
      const note = JSON.parse(noteJson.choices?.[0]?.message?.content ?? '{}');
      return json({ note });
    } catch {
      return providerFailed('AI_FAILED', "Couldn't process this. Try again.", 'The model did not return valid JSON');
    }
  }

  const material = mode === 'preliminary'
    ? part('Transcript', b.transcript)
    : [
        part('Preliminary summary', b.preliminarySummary),
        part('Transcript', b.transcript),
        part('X-ray analysis', b.xrayAnalysis),
        part('Clinical photo analysis', b.photoAnalysis),
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
  if (!res.ok) return providerFailed('AI_FAILED', "Couldn't process this. Try again.", await res.text());

  const result = await res.json();
  return json({ summary: result.choices?.[0]?.message?.content ?? '' });
});
