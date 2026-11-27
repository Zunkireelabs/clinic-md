import { authenticate, corsHeaders, json, keyMissing, providerFailed, serviceClient } from '../_shared/consultation.ts';
import { openaiUrl } from '../_shared/openai.ts';
import { filterSources, type Segment } from '../_shared/sources.ts';

const SYSTEM = `You are a clinical documentation assistant for a dental clinic. Write clear, factual notes for the treating dentist from the material provided. Never invent findings, diagnoses or medications that are not in the material. If something is unclear, say so. Use short headed sections and bullet points.`;

const PRELIMINARY_PROMPT = `Summarise this dental consultation transcript. Sections: Chief Complaint, History, Findings Discussed, Proposed Treatment, Follow-up.`;
const FINAL_PROMPT = `Combine everything below into one final consultation summary. Sections: Chief Complaint, Clinical Findings, Radiograph (X-ray) Findings, Clinical Photo Findings, Assessment, Treatment Plan, Follow-up. Skip a section if there is no information for it.`;

// mode 'note': the structured six-section clinical note the consultation page edits. Returned as JSON via OpenAI structured
// outputs, so the client never parses free text. Private staff notes are deliberately NOT accepted as input here.
const NOTE_PROMPT = `Write the clinical note for this dental consultation from the material below, as structured fields for the treating dentist.
Rules: use only what is in the material; never invent findings, diagnoses, medications or numbers. If something wasn't discussed, leave that field as an empty string. Write concise clinical English even if the conversation was in another language. For "plan", use "- " bullet lines, one action per line. "previous plan" is context only: do not copy it unless it was discussed.`;

const SECTION_DESCRIPTIONS_V1: Record<string, string> = {
  chief_complaint: 'Why the patient came in',
  history: 'Relevant history and previous treatment',
  findings: 'Clinical and radiograph findings',
  assessment: 'Diagnosis or impression',
  plan: 'Treatment plan, "- " bullets',
  follow_up: 'When to see the patient next',
};

// Sources (CMD-55): for each section, the exact words from the transcript it rests on, or the image it came from. The server keeps only quotes it
// finds in the stored transcript segments (_shared/sources.ts); everything else is dropped. Strict structured outputs can't express "one of", so
// each item has both fields: image 'none' means a transcript quote.
const SOURCES_PROMPT = `For "sources": for each section you filled, list the exact words from the transcript that support it (copy them verbatim, 3 to 25 words each, at most 3 per section), or {"quote": "", "image": "xray"} / {"image": "photo"} when it came from an image analysis. Never paraphrase a quote.`;

const noteSchema = (descriptions: Record<string, string>) => {
  const keys = Object.keys(descriptions);
  const sourceItem = {
    type: 'object', additionalProperties: false, required: ['quote', 'image'],
    properties: { quote: { type: 'string' }, image: { type: 'string', enum: ['none', 'xray', 'photo'] } },
  };
  return {
    name: 'clinical_note',
    strict: true,
    schema: {
      type: 'object',
      additionalProperties: false,
      required: [...keys, 'sources'],
      properties: {
        ...Object.fromEntries(keys.map((k) => [k, { type: 'string', description: descriptions[k] }])),
        sources: {
          type: 'object', additionalProperties: false, required: keys,
          properties: Object.fromEntries(keys.map((k) => [k, { type: 'array', items: sourceItem }])),
        },
      },
    },
  };
};

// consultations.note_template -> how the note is drafted. Only dental-v1 (today's six sections); the five-section dental-v2 comes with the
// redesigned screen. Must match src/utils/consultationNote.js and public._consult_template_sections.
const NOTE_TEMPLATES: Record<string, { prompt: string; keys: string[]; schema: unknown }> = {
  'dental-v1': { prompt: NOTE_PROMPT, keys: Object.keys(SECTION_DESCRIPTIONS_V1), schema: noteSchema(SECTION_DESCRIPTIONS_V1) },
};
const MODEL = 'gpt-4o';
const PROVIDER = 'openai';

const part = (label: string, value?: string) => (value?.trim() ? `### ${label}\n${value.trim()}\n` : '');

// Body: { mode: 'preliminary' | 'final' | 'note', transcript?, preliminarySummary?,
//         xrayAnalysis?, photoAnalysis?, doctorNotes?, previousPlan?, consultationId? }
// `additionalNotes` (the private staff notes) is never read in ANY mode: it must not reach the model or any report.
//
// Migration 020 (CMD-55), mode 'note' with consultationId: the row is read through the CALLER's client (RLS proves they can see it), its
// note_template picks the prompt and schema, the model's sources are filtered against the row's stored transcript segments, and the draft,
// provenance and sources are stored by THIS function through consultation_store_draft (service role) from the same response it returns. A
// client can therefore never write an "AI drafted" record or a source itself. Role 'staff' is refused (FORBIDDEN_ROLE).
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const auth = await authenticate(req, { requireStaff: true, clinicalRole: true, requireAiEnabled: true, quota: true });
  if (auth instanceof Response) return auth;

  const apiKey = Deno.env.get('OPENAI_API_KEY');
  if (!apiKey) return keyMissing('OPENAI_API_KEY');
  const baseUrl = Deno.env.get('OPENAI_BASE_URL');

  const b = await req.json().catch(() => ({}));
  const mode = b.mode === 'final' ? 'final' : b.mode === 'note' ? 'note' : 'preliminary';
  if (mode === 'preliminary' && !b.transcript?.trim()) return json({ error: 'transcript is required' }, 400);
  if (mode === 'final' && ![b.preliminarySummary, b.transcript, b.xrayAnalysis, b.photoAnalysis, b.doctorNotes].some((v) => v?.trim())) {
    return json({ error: 'Nothing to summarise yet' }, 400);
  }

  if (mode === 'note') {
    if (![b.transcript, b.xrayAnalysis, b.photoAnalysis].some((v) => v?.trim())) return json({ error: 'Nothing to draft from yet' }, 400);

    // The consultation, read as the caller. No id (an older client) = today's behaviour: dental-v1, nothing stored.
    let row: { id: string; note_template: string; signed_at: string | null; transcript_segments: Segment[] } | null = null;
    if (typeof b.consultationId === 'string' && b.consultationId) {
      const { data } = await auth.supabase.from('consultations').select('id, note_template, signed_at, transcript_segments').eq('id', b.consultationId).maybeSingle();
      row = data ?? null;
    }
    const templateName = row?.note_template ?? 'dental-v1';
    const template = NOTE_TEMPLATES[templateName];
    if (!template) return json({ error: 'UNKNOWN_TEMPLATE', message: 'This consultation uses a note template this server does not know.' }, 400);

    const inputs = [b.transcript?.trim() && 'recording', b.xrayAnalysis?.trim() && 'xray', b.photoAnalysis?.trim() && 'photo'].filter(Boolean) as string[];
    const noteMaterial = [
      part('Transcript', b.transcript),
      part('X-ray analysis', b.xrayAnalysis),
      part('Clinical photo analysis', b.photoAnalysis),
      part('Previous plan (context only)', b.previousPlan),
    ].join('\n');
    const noteRes = await fetch(openaiUrl('/chat/completions', baseUrl), {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        temperature: 0.2,
        max_tokens: 2400,
        response_format: { type: 'json_schema', json_schema: template.schema },
        messages: [
          { role: 'system', content: SYSTEM },
          { role: 'user', content: `${template.prompt}\n${SOURCES_PROMPT}\n\n${noteMaterial}` },
        ],
      }),
    });
    if (!noteRes.ok) return providerFailed('AI_FAILED', "Couldn't process this. Try again.", await noteRes.text());
    const noteJson = await noteRes.json();
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(noteJson.choices?.[0]?.message?.content ?? '{}');
    } catch {
      return providerFailed('AI_FAILED', "Couldn't process this. Try again.", 'The model did not return valid JSON');
    }
    // the note exactly as the model returned it, template keys only (this is what ai_draft stores)
    const note = Object.fromEntries(template.keys.map((k) => [k, typeof parsed[k] === 'string' ? parsed[k] : '']));
    const rawSources = Object.fromEntries(Object.entries((parsed.sources ?? {}) as Record<string, unknown>).map(([k, list]) => [k,
      Array.isArray(list) ? list.map((it: { quote?: unknown; image?: unknown }) => (it?.image === 'xray' || it?.image === 'photo' ? { image: it.image } : { quote: it?.quote })) : []]));
    const sources = filterSources(rawSources, row?.transcript_segments ?? [], template.keys, inputs);

    let provenance: { provider: string; model: string; inputs: string[]; drafted_at: string } | null = null;
    if (row && !row.signed_at) {
      const { data: stored, error: storeError } = await serviceClient().rpc('consultation_store_draft', {
        p_consultation: row.id, p_user: auth.user.id, p_note: note, p_provider: PROVIDER, p_model: MODEL, p_inputs: inputs, p_sources: sources,
      });
      if (storeError || !stored?.ok) console.error('[DRAFT_NOT_STORED]', storeError?.message ?? stored?.code); // the note is still returned
      else provenance = { provider: PROVIDER, model: MODEL, inputs, drafted_at: stored.drafted_at };
    }
    return json({ note, provenance, sources });
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

  const res = await fetch(openaiUrl('/chat/completions', baseUrl), {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: MODEL,
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
