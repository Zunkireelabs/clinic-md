import { describe, it, expect, vi, afterEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { runAgentJobs, matchReply, normalizeReply, type AgentDeps } from './agent';

const KEY = 'sk-test-SECRET-KEY-123';
const r = (intent: string, match: string, words: string[]) => words.map((word) => ({ intent, word, match, language: 'en' }));
const RULES = [
  ...r('confirm', 'exact', ['yes', 'y', 'ok', 'okay', 'haa', 'ho', 'huncha', 'thik cha', 'thik chha', 'हो', 'हुन्छ', 'ठिक छ', 'ठीक छ']),
  ...r('cancel', 'exact', ['no', 'cancel', 'radda', 'रद्द']),
  ...r('urgent', 'prefix', ['bleed', 'bled', 'blood', 'fever', 'emergency', 'urgent', 'ragat', 'jaro', 'रगत', 'ज्वरो']),
  ...r('urgent', 'contains', ['cannot breathe', "can't breathe", 'cant breathe']),
  ...r('clinical', 'prefix', ['pain', 'swell', 'swollen', 'hurt', 'ache', 'toothache', 'infect', 'allerg', 'medicin', 'dukh', 'sunni', 'सुन्नि', 'दुख']),
  ...r('clinical', 'contains', ['sore', 'sores', 'pus']),
] as never[];

type Job = Record<string, unknown>;
const job = (over: Job = {}): Job => ({
  job_id: 'job-1', org_id: 'org-1', branch_id: 'br-1', agent: 'follow_up', event: 'patient_reply', attempts: 1, customer_id: 'cu-1', booking_id: 'bk-1', conversation_id: 'cv-1', message_id: 'm-1',
  playbook: { id: 'pb-1', key: 'reply_to_confirm', level: 2, enabled: true, template_id: 'tpl-1', channel: null, settings: {} },
  agent_enabled: true, booking: { status: 'Pending', treatment: 'Root canal', date: '2026-11-24' }, conversation: { state: 'agent', language: 'en' }, reply_text: 'yes', ...over,
});
type ActRes0 = { ok?: boolean };
const ok = (extra: Record<string, unknown> = {}) => ({ ok: true, action_id: 'act-1', data: extra, error: null });
const refuse = (c: string) => ({ ok: false, action_id: 'act-x', data: null, error: { code: c } });

interface Setup { jobs?: Job[]; jobsFn?: (run: number) => Job[]; may?: boolean; acts?: Record<string, unknown | ((args: Record<string, unknown>) => unknown)>; model?: unknown; env?: Record<string, string>; rpcError?: string;
  failFinishTimes?: number; lostResponse?: { fn: string; times: number }; failActAfterCommit?: { fn: string; times: number } }
function harness(s: Setup = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const logs: string[] = [];
  let itemN = 0; let claimRun = 0; let finishFails = s.failFinishTimes ?? 0; const lost = { ...(s.lostResponse ?? { fn: '', times: 0 }) }; const afterCommit = { ...(s.failActAfterCommit ?? { fn: '', times: 0 }) };
  const steps = new Map<string, unknown>(); const committed: { fn: string; key: string | null }[] = [];
  const fetchImpl = vi.fn(async () => new Response(JSON.stringify(s.model ?? { choices: [{ message: { content: JSON.stringify({ intent: 'other', confidence: 0.1, also_question: false }) } }], usage: { prompt_tokens: 50, completion_tokens: 10 } }), { status: 200 }));
  const deps: AgentDeps = {
    rpc: (async (fn: string, args: Record<string, unknown> = {}) => {
      calls.push({ fn, args });
      if (s.rpcError === fn) return { data: null, error: { message: `db exploded ${KEY}` } };
      if (fn === 'agent_claim_jobs') return { data: s.jobsFn ? s.jobsFn(claimRun++) : s.jobs ?? [], error: null };
      if (fn === 'agent_step_result') return { data: steps.get(String(args.p_key)) ?? null, error: null };
      if (fn === 'agent_finish_job' && finishFails > 0) { finishFails--; return { data: null, error: { message: 'finish failed' } }; }
      if (fn === 'agent_get_reply_rules') return { data: RULES, error: null };
      if (fn === 'ai_may_run') return { data: s.may ?? true, error: null };
      if (fn === 'agent_finish_job' || fn === 'ai_record_spend') return { data: true, error: null };
      const custom = s.acts?.[fn];
      let res: unknown;
      if (typeof custom === 'function') res = (custom as (a: Record<string, unknown>) => unknown)(args);
      else if (custom !== undefined) res = custom;
      else if (fn === 'act_work_propose') res = ok({ item_id: `item-${++itemN}` });
      else res = ok();
      // an action that succeeds COMMITS (its step key goes into the log) whether or not the answer gets back
      const key = ((args.p_ctx as Record<string, unknown> | undefined)?.step_key as string | undefined) ?? null;
      if ((res as ActRes0).ok && key) { steps.set(key, { ...(res as object), action_id: `log-${steps.size + 1}` }); committed.push({ fn, key }); }
      if (afterCommit.fn === fn && afterCommit.times > 0) { afterCommit.times--; return { data: null, error: { message: 'connection lost' } }; }
      if (lost.fn === fn && lost.times > 0) { lost.times--; return { data: null, error: { message: 'response lost' } }; }
      return { data: res, error: null };
    }) as AgentDeps['rpc'],
    env: (n) => (s.env ?? { OPENAI_API_KEY: KEY })[n],
    fetchImpl: fetchImpl as never,
    log: (l) => logs.push(l),
    now: () => new Date('2026-11-23T04:00:00Z'),
  };
  const fns = () => calls.map((c) => c.fn);
  const finish = () => calls.find((c) => c.fn === 'agent_finish_job')!.args;
  const sends = () => calls.filter((c) => c.fn === 'act_message_send');
  return { deps, calls, logs, fetchImpl, fns, finish, sends, committed };
}
const run = (s: Setup) => { const h = harness(s); return runAgentJobs(h.deps).then((summary) => ({ ...h, summary })); };

afterEach(() => vi.restoreAllMocks());

describe('reply rules', () => {
  it('matches English, Nepali and romanised confirmations on the WHOLE message, ignoring case and punctuation', () => {
    for (const t of ['YES', 'Yes!', ' ok. ', 'Haa', 'ho', 'huncha', 'Thik cha', 'ठिक छ', 'हो।', 'हुन्छ']) expect(matchReply(t, RULES)).toBe('confirm');
    for (const t of ['No.', 'CANCEL', 'radda', 'रद्द']) expect(matchReply(t, RULES)).toBe('cancel');
  });
  it('symptoms anywhere in the text win: urgent over clinical over everything', () => {
    expect(matchReply('my cheek is swollen', RULES)).toBe('clinical');
    expect(matchReply('yes, no pain now', RULES)).toBe('clinical');   // known false positive: the safe side
    expect(matchReply('there is bleeding and swelling', RULES)).toBe('urgent');
    expect(matchReply('रगत आयो', RULES)).toBe('urgent');
    expect(matchReply('गाल सुन्निएको छ', RULES)).toBe('clinical');
    expect(matchReply('sorry I am late', RULES)).toBeNull();   // 'sore' is a whole-word rule, so 'sorry' is not a symptom
    expect(matchReply('my cousin is a painter', RULES)).toBe('clinical');   // known false positive: 'pain' starts the word (also paint, painting). The safe side.
  });
  it.each([
    ['it is painful'], ['the gum pains a lot'], ['he bled all night'], ['it bleeds again'], ['feeling feverish'], ['it swelled up'], ['my tooth hurts'], ['such an ache'], ['bad toothache'],
    ['there is blood in my mouth'], ['sore gums'], ['ragat aayo'], ['dukhyo'], ['dukhchha'], ['sunniyo'], ['jaro aayo'], ['I can’t breathe'], ['cannot breathe'], ['cheek is swelling'], ['गाल दुखेको छ'], ['ज्वरो आयो'],
  ])('"%s" hands off with no model call and no ai_may_run', async (reply) => {
    const out = await run({ jobs: [job({ reply_text: reply })] });
    expect(out.fetchImpl).not.toHaveBeenCalled();
    expect(out.fns()).not.toContain('ai_may_run');
    expect(out.fns()).toContain('act_conversation_handoff');
    expect(out.fns()).not.toContain('act_booking_set_status');
    expect(JSON.stringify(out.calls)).not.toContain(reply.slice(0, 12) + 'XX');
  });
  it('anything else is free text', () => {
    expect(matchReply('can I come at 5 instead?', RULES)).toBeNull();
    expect(matchReply('yes can i come at 5', RULES)).toBeNull();
    expect(matchReply('', RULES)).toBeNull();
    expect(normalizeReply('  Thik   Cha! ')).toBe('thik cha');
  });
});

describe('patient replies: rules first', () => {
  it('clinical and urgent words hand off BEFORE ai_may_run and before any model call; the reply is never quoted', async () => {
    const r = await run({ jobs: [job({ reply_text: 'my cheek is swollen and bleeding' })] });
    expect(r.fetchImpl).not.toHaveBeenCalled();
    expect(r.fns()).not.toContain('ai_may_run');
    expect(r.fns()).not.toContain('ai_record_spend');
    const h = r.calls.find((c) => c.fn === 'act_conversation_handoff')!.args;
    expect(h).toMatchObject({ p_conversation: 'cv-1', p_reason: 'urgent', p_urgent: true });
    expect(String(h.p_summary)).toBe('The patient wrote about symptoms, so I handed it to the front desk. I did not answer.');
    expect(JSON.stringify(r.calls)).not.toContain('swollen');
    expect(r.summary).toMatchObject({ done: 1 });
  });
  it('clinical (not urgent) hands off as clinical, not urgent', async () => {
    const r = await run({ jobs: [job({ reply_text: 'my cheek is swollen' })] });
    expect(r.calls.find((c) => c.fn === 'act_conversation_handoff')!.args).toMatchObject({ p_reason: 'clinical', p_urgent: false });
  });
  it('YES at level 2: set_status Confirmed (reason_source patient_reply), then the reply TEMPLATE on the conversation; no model, no ai_may_run', async () => {
    const r = await run({ jobs: [job({ reply_text: 'YES' })] });
    const s = r.calls.find((c) => c.fn === 'act_booking_set_status')!.args;
    expect(s).toMatchObject({ p_booking: 'bk-1', p_status: 'Confirmed', p_ctx: { actor_kind: 'agent', agent: 'follow_up', reason_source: 'patient_reply', org_id: 'org-1', branch_id: 'br-1' } });
    const m = r.calls.find((c) => c.fn === 'act_message_send')!.args;
    expect(m).toMatchObject({ p_conversation: 'cv-1', p_template: 'tpl-1', p_booking: 'bk-1', p_purpose: 'service' });
    expect(m).not.toHaveProperty('p_text');
    expect(r.fns().indexOf('act_booking_set_status')).toBeLessThan(r.fns().indexOf('act_message_send'));
    expect(r.fetchImpl).not.toHaveBeenCalled();
    expect(r.fns()).not.toContain('ai_may_run');
  });
  it('"ठिक छ" confirms too', async () => {
    const r = await run({ jobs: [job({ reply_text: 'ठिक छ', conversation: { state: 'agent', language: 'ne' } })] });
    expect(r.fns()).toContain('act_booking_set_status');
    expect(r.calls.find((c) => c.fn === 'act_message_send')!.args.p_language).toBe('ne');
  });
  it('YES at level 1: two items, status first, then the template item that REQUIRES the first; both template-only drafts', async () => {
    const r = await run({ jobs: [job({ reply_text: 'ok', playbook: { id: 'pb-1', key: 'reply_to_confirm', level: 1, enabled: true, template_id: 'tpl-1', channel: null, settings: {} } })] });
    const props = r.calls.filter((c) => c.fn === 'act_work_propose').map((c) => c.args);
    expect(props).toHaveLength(2);
    expect(props[0]).toMatchObject({ p_action: 'act_booking_set_status', p_inputs: { status: 'Confirmed' }, p_uses_ai: false });
    expect(props[1]).toMatchObject({ p_action: 'act_message_send', p_uses_ai: false });
    expect(props[1].p_sources).toContainEqual({ kind: 'work_item', id: 'item-1', requires: true });
    expect(r.fns()).not.toContain('act_booking_set_status');
    expect(r.fns()).not.toContain('act_message_send');
  });
  it('cancel at level 2: cancels with reason_source patient_reply; a refusal (paid booking) hands off', async () => {
    const a = await run({ jobs: [job({ reply_text: 'cancel' })] });
    expect(a.calls.find((c) => c.fn === 'act_booking_set_status')!.args).toMatchObject({ p_status: 'Cancelled', p_ctx: { reason_source: 'patient_reply' } });
    const b = await run({ jobs: [job({ reply_text: 'No' })], acts: { act_booking_set_status: refuse('APPROVAL_REQUIRED') } });
    expect(b.calls.find((c) => c.fn === 'act_conversation_handoff')!.args).toMatchObject({ p_reason: 'asks_to_change' });
  });
  it('a conversation a person is handling is left alone', async () => {
    const r = await run({ jobs: [job({ conversation: { state: 'person', language: 'en' } })] });
    expect(r.fns().filter((f) => f.startsWith('act_'))).toEqual([]);
    expect(r.finish()).toMatchObject({ p_status: 'skipped', p_error: 'PERSON_HANDLING' });
  });
});

describe('patient replies: free text and the model', () => {
  const model = (c: unknown, u = { prompt_tokens: 50, completion_tokens: 10 }) => ({ choices: [{ message: { content: JSON.stringify(c) } }], usage: u });
  it('"can I come at 5 instead?": one model call, spend recorded, hand-off asks_to_change, never a reply to the patient', async () => {
    const r = await run({ jobs: [job({ reply_text: 'can I come at 5 instead?' })], model: model({ intent: 'reschedule', confidence: 0.95, also_question: false }) });
    expect(r.fetchImpl).toHaveBeenCalledTimes(1);
    expect(r.calls.find((c) => c.fn === 'ai_record_spend')!.args).toMatchObject({ p_org: 'org-1', p_branch: 'br-1', p_agent: 'follow_up', p_job: 'text', p_units: { in: 50, out: 10 } });
    expect(Number(r.calls.find((c) => c.fn === 'ai_record_spend')!.args.p_cost_npr)).toBeGreaterThan(0);
    expect(r.calls.find((c) => c.fn === 'act_conversation_handoff')!.args).toMatchObject({ p_reason: 'asks_to_change' });
    expect(r.fns()).not.toContain('act_message_send');
    expect(r.fns()).not.toContain('act_booking_set_status');
  });
  it('confirm at >= 0.9 acts; at 0.89 it hands off as unclear', async () => {
    const hi = await run({ jobs: [job({ reply_text: 'sure, see you then' })], model: model({ intent: 'confirm', confidence: 0.9, also_question: false }) });
    expect(hi.fns()).toContain('act_booking_set_status');
    const lo = await run({ jobs: [job({ reply_text: 'sure, see you then' })], model: model({ intent: 'confirm', confidence: 0.89, also_question: false }) });
    expect(lo.fns()).not.toContain('act_booking_set_status');
    expect(lo.calls.find((c) => c.fn === 'act_conversation_handoff')!.args).toMatchObject({ p_reason: 'unclear' });
  });
  it('a confirmation that also asks something: confirms AND hands the question off, uses_ai true on drafts', async () => {
    const r = await run({ jobs: [job({ reply_text: 'yes, is it going to be long?' })], model: model({ intent: 'confirm', confidence: 0.97, also_question: true }) });
    expect(r.fns()).toContain('act_booking_set_status');
    expect(r.calls.find((c) => c.fn === 'act_conversation_handoff')!.args).toMatchObject({ p_reason: 'other' });
    const d = await run({ jobs: [job({ reply_text: 'yes, is it going to be long?', playbook: { id: 'pb-1', key: 'reply_to_confirm', level: 1, enabled: true, template_id: 'tpl-1', channel: null, settings: {} } })], model: model({ intent: 'confirm', confidence: 0.97, also_question: false }) });
    expect(d.calls.find((c) => c.fn === 'act_work_propose')!.args.p_uses_ai).toBe(true);
  });
  it.each([['question', 'other'], ['clinical', 'clinical'], ['urgent', 'urgent'], ['cancel', 'asks_to_change'], ['other', 'unclear']])('model says %s: hand-off reason %s, nothing acted', async (intent, reason) => {
    const r = await run({ jobs: [job({ reply_text: 'something odd' })], model: model({ intent, confidence: 0.99, also_question: false }) });
    expect(r.calls.find((c) => c.fn === 'act_conversation_handoff')!.args).toMatchObject({ p_reason: reason, p_urgent: intent === 'urgent' });
    expect(r.fns()).not.toContain('act_booking_set_status');
  });
  it('a bad model answer, a model error and a missing key all hand off (never a silent drop); a bad answer still records its spend', async () => {
    const bad = await run({ jobs: [job({ reply_text: 'hmm' })], model: { choices: [{ message: { content: 'not json' } }], usage: { prompt_tokens: 5, completion_tokens: 2 } } });
    expect(bad.calls.find((c) => c.fn === 'act_conversation_handoff')!.args).toMatchObject({ p_reason: 'unclear' });
    expect(bad.fns()).toContain('ai_record_spend');
    const nokey = await run({ jobs: [job({ reply_text: 'hmm' })], env: {} });
    expect(nokey.calls.find((c) => c.fn === 'act_conversation_handoff')!.args).toMatchObject({ p_reason: 'unclear' });
    expect(nokey.fetchImpl).not.toHaveBeenCalled();
    expect(nokey.fns()).not.toContain('ai_record_spend');
  });
  it('AI off or the budget used up (ai_may_run false): free text is handed off with NO model call and no spend', async () => {
    const r = await run({ jobs: [job({ reply_text: 'can I come at 5 instead?' })], may: false });
    expect(r.fetchImpl).not.toHaveBeenCalled();
    expect(r.fns()).not.toContain('ai_record_spend');
    const h = r.calls.find((c) => c.fn === 'act_conversation_handoff')!.args;
    expect(h).toMatchObject({ p_reason: 'unclear' });
    expect(String(h.p_summary)).toContain('AI is not available');
  });
  it('AI off: rule replies and fixed-template sends still go out', async () => {
    const yes = await run({ jobs: [job({ reply_text: 'yes' })], may: false });
    expect(yes.fns()).toContain('act_booking_set_status');
    expect(yes.fns()).toContain('act_message_send');
    const conf = await run({ jobs: [job({ event: 'booking_created', conversation_id: null, conversation: null, reply_text: null, playbook: { id: 'pb-2', key: 'booking_confirmation', level: 2, enabled: true, template_id: 'tpl-2', channel: null, settings: {} } })], may: false });
    expect(conf.fns()).toContain('act_message_send');
    expect(conf.fns()).not.toContain('ai_may_run');
  });
});

describe('template events and the 6 pm flag', () => {
  const pbl = (level: number, key = 'booking_confirmation', template_id: string | null = 'tpl-2') => ({ id: 'pb-2', key, level, enabled: true, template_id, channel: null, settings: {} });
  const base = (over: Job = {}) => job({ event: 'booking_created', conversation_id: null, conversation: null, reply_text: null, message_id: null, booking: { status: 'Confirmed', treatment: 'Cleaning', date: '2026-11-24' }, playbook: pbl(2), ...over });

  it('level 2 sends the template as the agent (service ctx), deferring quiet hours; free text is never passed', async () => {
    const r = await run({ jobs: [base()] });
    const m = r.calls.find((c) => c.fn === 'act_message_send')!.args;
    expect(m).toMatchObject({ p_customer: 'cu-1', p_template: 'tpl-2', p_booking: 'bk-1', p_purpose: 'service', p_on_quiet_hours: 'defer', p_ctx: { actor_kind: 'agent', agent: 'follow_up' } });
    expect(m).not.toHaveProperty('p_text');
    expect(r.finish()).toMatchObject({ p_status: 'done' });
  });
  it('level 1 creates an approval item (template-only: p_uses_ai false) and sends nothing', async () => {
    const r = await run({ jobs: [base({ event: 'day_before', playbook: pbl(1, 'day_before_reminder') })] });
    expect(r.fns()).not.toContain('act_message_send');
    expect(r.calls.find((c) => c.fn === 'act_work_propose')!.args).toMatchObject({ p_agent: 'follow_up', p_kind: 'approval', p_action: 'act_message_send', p_uses_ai: false,
      p_inputs: { template: 'tpl-2', purpose: 'service', on_quiet_hours: 'defer' }, p_playbook: 'pb-2' });
  });
  it('APPROVAL_REQUIRED at level 2 falls back to a draft; STOPPED, CLINICAL_TEMPLATE and a missing template are skipped, with the code', async () => {
    const a = await run({ jobs: [base()], acts: { act_message_send: refuse('APPROVAL_REQUIRED') } });
    expect(a.fns()).toContain('act_work_propose');
    for (const c of ['STOPPED', 'CLINICAL_TEMPLATE', 'NO_CONSENT']) {
      const r = await run({ jobs: [base()], acts: { act_message_send: refuse(c) } });
      expect(r.fns()).not.toContain('act_work_propose');
      expect(r.finish()).toMatchObject({ p_status: 'skipped', p_error: c });
    }
    const n = await run({ jobs: [base({ playbook: pbl(2, 'booking_confirmation', null) })] });
    expect(n.finish()).toMatchObject({ p_status: 'skipped', p_error: 'NO_TEMPLATE' });
    expect(n.fns()).not.toContain('act_message_send');
  });
  it('the 6 pm flag: level 2 flags; level 1 drafts the flag', async () => {
    const f = await run({ jobs: [base({ event: 'no_reply', booking: { status: 'Pending', treatment: 'x', date: '2026-11-24' }, playbook: pbl(2, 'not_confirmed_by_6pm', null) })] });
    expect(f.calls.find((c) => c.fn === 'act_booking_flag_not_confirmed')!.args).toMatchObject({ p_booking: 'bk-1' });
    const d = await run({ jobs: [base({ event: 'no_reply', booking: { status: 'Pending', treatment: 'x', date: '2026-11-24' }, playbook: pbl(1, 'not_confirmed_by_6pm', null) })] });
    expect(d.calls.find((c) => c.fn === 'act_work_propose')!.args).toMatchObject({ p_action: 'act_booking_flag_not_confirmed', p_uses_ai: false });
  });
  it('skips a switched-off playbook or agent, a booking that is gone or no longer eligible, and a missing patient', async () => {
    const cases: [Job, string][] = [
      [{ playbook: { ...pbl(2), enabled: false } }, 'PLAYBOOK_OFF'], [{ agent_enabled: false }, 'AGENT_OFF'], [{ booking: null }, 'BOOKING_GONE'],
      [{ booking: { status: 'Cancelled', treatment: 'x', date: '2026-11-24' } }, 'BOOKING_NOT_ELIGIBLE'], [{ customer_id: null }, 'NO_PATIENT'],
    ];
    for (const [over, c] of cases) {
      const r = await run({ jobs: [base(over)] });
      expect(r.fns().filter((f) => f.startsWith('act_'))).toEqual([]);
      expect(r.finish()).toMatchObject({ p_status: 'skipped', p_error: c });
    }
  });
});

describe('failure handling and the hard lines', () => {
  it('a database error is a retry with a CODE; the error text never reaches the job row or the log', async () => {
    const r = await run({ jobs: [job({ reply_text: 'yes' })], rpcError: 'act_booking_set_status' });
    expect(r.finish()).toMatchObject({ p_status: 'retry', p_error: 'RPC_ERROR' });
    expect(JSON.stringify(r.calls)).not.toContain('db exploded');
    expect(r.logs.join('\n')).not.toContain('db exploded');
    expect(r.summary).toMatchObject({ retried: 1 });
  });
  it('the API key and the reply text never appear in a log line, a job result or a hand-off, on any path', async () => {
    const jobs = [job({ job_id: 'a', reply_text: 'my cheek is swollen' }), job({ job_id: 'b', reply_text: 'zebra crossing question' }), job({ job_id: 'c', reply_text: 'yes' })];
    const spy = [vi.spyOn(console, 'log'), vi.spyOn(console, 'error'), vi.spyOn(console, 'warn')];
    const r = await run({ jobs, model: { choices: [{ message: { content: JSON.stringify({ intent: 'question', confidence: 0.9, also_question: false }) } }], usage: { prompt_tokens: 9, completion_tokens: 3 } } });
    const out = [...r.logs, ...spy.flatMap((s) => s.mock.calls.flat().map(String))].join('\n');
    expect(out).not.toContain(KEY);
    for (const word of ['swollen', 'zebra']) {
      expect(out).not.toContain(word);
      const written = r.calls.filter((c) => c.fn !== 'agent_claim_jobs').map((c) => JSON.stringify(c.args)).join('\n');
      expect(written).not.toContain(word);
    }
    // the key only ever went to the model, as a header
    expect(JSON.stringify(r.calls)).not.toContain(KEY);
  });
  it('only database FUNCTIONS are called: act_*, the claim / finish / rules / ai_may_run / spend functions', async () => {
    const jobs = [job({ job_id: 'a', reply_text: 'swollen' }), job({ job_id: 'b', reply_text: 'yes' }), job({ job_id: 'c', reply_text: 'No' }), job({ job_id: 'd', reply_text: 'hmm odd' }),
      job({ job_id: 'e', event: 'no_reply', playbook: { id: 'p', key: 'not_confirmed_by_6pm', level: 1, enabled: true, template_id: null, channel: null, settings: {} } })];
    const r = await run({ jobs });
    const allowed = /^(act_[a-z_]+|agent_claim_jobs|agent_finish_job|agent_step_result|agent_get_reply_rules|ai_may_run|ai_record_spend)$/;
    for (const f of r.fns()) expect(f).toMatch(allowed);
  });
  it('every outgoing message is a template: act_message_send never gets p_text', async () => {
    const jobs = [job({ reply_text: 'yes' }), job({ job_id: 'x', event: 'day_before', conversation_id: null, conversation: null, reply_text: null, playbook: { id: 'p', key: 'day_before_reminder', level: 2, enabled: true, template_id: 't', channel: null, settings: {} } })];
    const r = await run({ jobs });
    const sends = r.calls.filter((c) => c.fn === 'act_message_send');
    expect(sends.length).toBe(2);
    for (const s of sends) { expect(s.args).not.toHaveProperty('p_text'); expect(s.args.p_template).toBeTruthy(); }
  });
});

describe('idempotent steps: a retry never repeats what already succeeded', () => {
  const tplJob = (over: Job = {}) => job({ event: 'booking_created', conversation_id: null, conversation: null, reply_text: null, message_id: null, booking: { status: 'Confirmed', treatment: 'Cleaning', date: '2026-11-24' },
    playbook: { id: 'pb-2', key: 'booking_confirmation', level: 2, enabled: true, template_id: 'tpl-2', channel: null, settings: {} }, ...over });

  it('every action carries a step key job:<id>:<step> in its ctx', async () => {
    const r = await run({ jobs: [tplJob()] });
    expect((r.calls.find((c) => c.fn === 'act_message_send')!.args.p_ctx as Record<string, unknown>).step_key).toBe('job:job-1:send');
  });
  it('the finish call fails, the job is claimed again: still exactly ONE send', async () => {
    const h = harness({ jobsFn: () => [tplJob()], failFinishTimes: 1 });
    await runAgentJobs(h.deps);
    await runAgentJobs(h.deps);
    expect(h.sends()).toHaveLength(1);
    expect(h.calls.filter((c) => c.fn === 'agent_finish_job')).toHaveLength(2);
    expect(h.calls.filter((c) => c.fn === 'agent_finish_job').pop()!.args).toMatchObject({ p_status: 'done' });
  });
  it('the send commits but its response is lost (RPC_ERROR, retry): the retry sends nothing more', async () => {
    const h = harness({ jobsFn: () => [tplJob()], failActAfterCommit: { fn: 'act_message_send', times: 1 } });
    await runAgentJobs(h.deps);
    expect(h.calls.find((c) => c.fn === 'agent_finish_job')!.args).toMatchObject({ p_status: 'retry', p_error: 'RPC_ERROR' });
    await runAgentJobs(h.deps);
    expect(h.sends()).toHaveLength(1);
    expect(h.calls.filter((c) => c.fn === 'agent_finish_job').pop()!.args).toMatchObject({ p_status: 'done' });
  });
  it('a refused send (nothing committed) IS tried again on a retry: the guard only skips what succeeded', async () => {
    const h = harness({ jobsFn: () => [tplJob()], acts: { act_message_send: refuse('QUIET_HOURS') } });
    await runAgentJobs(h.deps); await runAgentJobs(h.deps);
    expect(h.sends()).toHaveLength(2);
  });
  it('status changed but the thank-you failed: the retry sends the thank-you once and does not change the status again (the booking is no longer Pending)', async () => {
    const h = harness({
      jobsFn: (n) => [job({ reply_text: 'YES', booking: { status: n === 0 ? 'Pending' : 'Confirmed', treatment: 'Root canal', date: '2026-11-24' } })],
      failActAfterCommit: { fn: 'act_message_send', times: 1 },
    });
    await runAgentJobs(h.deps);
    expect(h.calls.find((c) => c.fn === 'agent_finish_job')!.args).toMatchObject({ p_status: 'retry' });
    await runAgentJobs(h.deps);
    expect(h.calls.filter((c) => c.fn === 'act_booking_set_status')).toHaveLength(1);
    expect(h.sends()).toHaveLength(1);
    expect(h.calls.filter((c) => c.fn === 'agent_finish_job').pop()!.args).toMatchObject({ p_status: 'done' });
  });
  it('a confirmation that already has its thank-you and status, retried, does nothing more and still ends done', async () => {
    const h = harness({ jobsFn: (n) => [job({ reply_text: 'ok', booking: { status: n === 0 ? 'Pending' : 'Confirmed', treatment: 'x', date: '2026-11-24' } })], failFinishTimes: 1 });
    await runAgentJobs(h.deps); await runAgentJobs(h.deps);
    expect(h.calls.filter((c) => c.fn === 'act_booking_set_status')).toHaveLength(1);
    expect(h.sends()).toHaveLength(1);
    expect(h.calls.filter((c) => c.fn === 'agent_finish_job').pop()!.args).toMatchObject({ p_status: 'done' });
  });
  it('a level-1 reply retried after both drafts were made makes no new items', async () => {
    const lvl1 = { id: 'pb-1', key: 'reply_to_confirm', level: 1, enabled: true, template_id: 'tpl-1', channel: null, settings: {} };
    const h = harness({ jobsFn: () => [job({ reply_text: 'yes', playbook: lvl1 })], failFinishTimes: 1 });
    await runAgentJobs(h.deps); await runAgentJobs(h.deps);
    expect(h.calls.filter((c) => c.fn === 'act_work_propose')).toHaveLength(2);
  });
  it('the 6 pm flag and a cancel are steps too', async () => {
    const h = harness({ jobsFn: () => [job({ reply_text: 'No' })], failFinishTimes: 1 });
    await runAgentJobs(h.deps); await runAgentJobs(h.deps);
    expect(h.calls.filter((c) => c.fn === 'act_booking_set_status')).toHaveLength(1);
  });
});

describe('the cost ledger', () => {
  const resp = (usage: unknown) => ({ choices: [{ message: { content: JSON.stringify({ intent: 'question', confidence: 0.9, also_question: false }) } }], ...(usage === undefined ? {} : { usage }) });
  it('a parsed answer with NO usage is still recorded: null tokens, cost 0, flag USAGE_MISSING, and the job carries on', async () => {
    const r = await run({ jobs: [job({ reply_text: 'is there parking?' })], model: resp(undefined) });
    const spend = r.calls.find((c) => c.fn === 'ai_record_spend')!.args;
    expect(spend).toMatchObject({ p_units: { in: null, out: null, flag: 'USAGE_MISSING' }, p_cost_npr: 0 });
    expect(r.calls.find((c) => c.fn === 'act_conversation_handoff')!.args).toMatchObject({ p_reason: 'other' });
  });
  it('an answer that does not parse is recorded too', async () => {
    const r = await run({ jobs: [job({ reply_text: 'hmm' })], model: { choices: [{ message: { content: 'nope' } }] } });
    expect(r.calls.find((c) => c.fn === 'ai_record_spend')!.args).toMatchObject({ p_units: { flag: 'USAGE_MISSING' } });
  });
  it('an HTTP error (no answer) is not recorded', async () => {
    const h = harness({ jobs: [job({ reply_text: 'hmm' })] });
    (h.fetchImpl as unknown as { mockImplementation: (f: unknown) => void }).mockImplementation(async () => new Response('{}', { status: 500 }));
    await runAgentJobs(h.deps);
    expect(h.fns()).not.toContain('ai_record_spend');
  });
});

describe('source checks', () => {
  const read = (p: string) => readFileSync(new URL(p, import.meta.url), 'utf8');
  it('agent.ts never touches a table', () => {
    const src = read('./agent.ts');
    expect(src).not.toMatch(/\.from\(/);
    expect(src).not.toMatch(/\.(insert|update|delete|upsert)\(/);
  });
  it('the agent-run entry file never reads or logs the model key, never touches a table, and logs only through deps.log', () => {
    const src = read('../agent-run/index.ts');
    expect(src).not.toContain('OPENAI_API_KEY');
    expect(src).not.toMatch(/\.from\(/);
    const consoleCalls = src.match(/console\.[a-z]+\([^)]*\)/g) ?? [];
    expect(consoleCalls).toEqual(['console.log(line)']);
    expect(src).not.toMatch(/console\.[a-z]+\([^)]*(env|KEY|key|token|Authorization)/);
  });
  it('model.ts reads the key only through deps.env and never prints it', () => {
    const src = read('./model.ts');
    expect(src).not.toMatch(/console\./);
    expect(src.match(/Bearer \$\{key\}/g)?.length).toBe(1);
  });
});
