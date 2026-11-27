// A fake OpenAI for the consultation edge-function tests (CMD-54). LOCAL ONLY: the functions reach it through OPENAI_BASE_URL
// (http://host.docker.internal:<port>/v1). No real key, no network. Usage: node supabase/tests/edge/fake-openai.mjs [port]
import http from 'node:http';

const port = Number(process.argv[2] || 9911);

export const TRANSCRIPT = {
  text: 'Where does it hurt? Lower left when I drink cold water. We will start the root canal today.',
  language: 'english',
  segments: [
    { start: 0, end: 3.2, text: ' Where does it hurt?' },
    { start: 3.2, end: 7.9, text: ' Lower left when I drink cold water.' },
    { start: 7.9, end: 11.0, text: ' We will start the root canal today.' },
  ],
};

// The note the "model" returns: one real quote per filled section, one INVENTED quote (must never be stored), and an x-ray source although no
// x-ray was sent (must be dropped).
export const NOTE = {
  chief_complaint: 'Pain lower left with cold drinks',
  history: '',
  findings: 'Caries 36',
  assessment: '',
  plan: '- RCT 36',
  follow_up: '',
  sources: {
    chief_complaint: [{ quote: 'when I drink cold water', image: 'none' }, { quote: 'the patient reports swelling for a week', image: 'none' }],
    history: [],
    findings: [{ quote: '', image: 'xray' }],
    assessment: [],
    plan: [{ quote: 'start the root canal', image: 'none' }],
    follow_up: [],
  },
};

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const auth = req.headers.authorization || '';
    const send = (code, body) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };
    if (!auth.startsWith('Bearer ')) return send(401, { error: 'no key' });
    if (req.method === 'POST' && req.url === '/v1/audio/transcriptions') {
      console.log('[fake-openai] transcription');
      return send(200, TRANSCRIPT);
    }
    if (req.method === 'POST' && req.url === '/v1/chat/completions') {
      let body = {};
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { /* ignore */ }
      const structured = body?.response_format?.type === 'json_schema';
      console.log(`[fake-openai] chat (${structured ? 'note' : 'text'}) model=${body.model}`);
      return send(200, { choices: [{ message: { content: structured ? JSON.stringify(NOTE) : 'A plain summary.' } }], usage: { prompt_tokens: 10, completion_tokens: 10 } });
    }
    return send(404, { error: 'not faked' });
  });
});
server.listen(port, '0.0.0.0', () => console.log(`[fake-openai] listening on ${port}`));
