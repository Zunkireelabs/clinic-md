// The Follow-up agent's runner (CMD-95), written against injected dependencies so it runs under Vitest with a mocked rpc and a mocked fetch.
// NO remote imports. supabase/functions/agent-run/index.ts only wires a Supabase service-role client into AgentDeps.
//
// HARD LINES (each has a test):
//   * the agent calls only rpc functions: agent_claim_jobs, agent_finish_job, agent_step_result, agent_get_reply_rules, ai_may_run, ai_record_spend and the act_* actions.
//     It never reads or writes a table.
//   * every outgoing patient message is a TEMPLATE id; the only free text the agent writes is the fixed strings in TEXT below (work item titles and
//     summaries, hand-off summaries), all first person and none quoting the patient.
//   * clinical and urgent words hand off BEFORE any model call (and before ai_may_run).
//   * only the reply text, the treatment name and the visit date go to the model (model.ts masks the rest).
//   * logs hold job ids, statuses and codes only: never a reply, a name, a number or a key.
//   * one job per (playbook, booking, event) is the database's guarantee (unique index); and every action a job takes is a STEP with a key
//     'job:<job id>:<step>' (p_ctx.step_key, kept in the action log). A retried job asks agent_step_result first and skips a step that already
//     succeeded, so a lost response or a failed finish never sends a second message, and a half-done job carries on with the rest.
import { classifyReply, MODEL_CONFIG, type ModelDeps } from './model.ts';

export interface RpcResult<T = unknown> { data: T | null; error: { message: string } | null }
export interface AgentDeps extends ModelDeps {
  rpc<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<RpcResult<T>>;
  log?: (line: string) => void;
  now?: () => Date;
}

const AGENT = 'follow_up';
export const CONFIRM_MIN_CONFIDENCE = 0.9;

interface Job {
  job_id: string; org_id: string; branch_id: string; agent: string; event: 'booking_created' | 'day_before' | 'visit_completed' | 'no_reply' | 'patient_reply';
  attempts: number; customer_id: string | null; booking_id: string; conversation_id: string | null; message_id: string | null;
  playbook: { id: string; key: string; level: number; enabled: boolean; template_id: string | null; channel: string | null; settings: Record<string, unknown> };
  agent_enabled: boolean;
  booking: { status: string; treatment: string | null; date: string } | null;
  conversation: { state: string; language: string | null } | null;
  reply_text: string | null;
}
interface ActRes { ok?: boolean; action_id?: string; data?: Record<string, unknown> | null; error?: { code?: string } | null }
interface Rule { intent: 'confirm' | 'cancel' | 'urgent' | 'clinical'; word: string; match: 'exact' | 'prefix' | 'contains'; language: string }
export interface JobOutcome { status: 'done' | 'skipped' | 'failed' | 'retry'; result: Record<string, unknown>; error?: string }
export interface RunSummary { claimed: number; done: number; skipped: number; failed: number; retried: number }

// The ONLY free text the agent writes (first person, never quoting the patient).
const TEXT = {
  handoff: {
    symptoms: 'The patient wrote about symptoms, so I handed it to the front desk. I did not answer.',
    change: 'The patient asked to change or cancel, so I handed it to the front desk. I did not answer.',
    question: 'The patient asked a question, so I handed it to the front desk. I did not answer.',
    unclear: 'I could not tell what the patient meant, so I handed it to the front desk. I did not answer.',
    ai_off: 'AI is not available right now, so I did not read this reply. I handed it to the front desk and did not answer.',
    confirm_question: 'The patient confirmed and also asked something. I confirmed the booking and handed the question to the front desk. I did not answer it.',
  },
  item: {
    booking_created: { title: 'Send the booking confirmation', summary: 'I drafted the booking confirmation for this patient. Approve it and I will send it.' },
    day_before: { title: 'Send the day-before reminder', summary: 'I drafted tomorrow\'s reminder for this patient. Approve it and I will send it.' },
    visit_completed: { title: 'Send the aftercare check-in', summary: 'I drafted an aftercare check-in for this patient. Approve it and I will send it.' },
    no_reply: { title: 'Flag the booking as not confirmed', summary: 'This booking is still not confirmed. I would like to flag it for the front desk.' },
    reply_confirm: { title: 'Confirm the booking', summary: 'The patient replied to confirm. I would like to mark the booking Confirmed.' },
    reply_thanks: { title: 'Send the confirmation reply', summary: 'After the booking is confirmed I will send the patient the confirmation reply.' },
    reply_cancel: { title: 'Cancel the booking', summary: 'The patient replied to cancel. I would like to cancel the booking.' },
  },
  reason: { confirm: 'Patient replied to confirm', cancel: 'Patient replied to cancel', noReply: 'Not confirmed by 6 pm' },
} as const;

class RunnerError extends Error { constructor(public code: string) { super(code); } }

// ── reply rules ───────────────────────────────────────────────────────────────────────────────────────────────────────────
export function normalizeReply(text: string): string {
  return String(text ?? '').normalize('NFC').toLowerCase().replace(/[\u2018\u2019\u02bc`]/g, "'").replace(/\s+/g, ' ').replace(/^[\s.,!?;:।"'()\-]+|[\s.,!?;:।"'()\-]+$/g, '');
}
const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
/** contains: the whole Latin word or phrase; prefix: a Latin word that STARTS with it (pain -> painful, pains). Devanagari has no word breaks: substring for both. */
function wordMatch(norm: string, word: string, mode: 'prefix' | 'contains'): boolean {
  const w = word.toLowerCase();
  if (/^[a-z' ]+$/.test(w)) return new RegExp(`(^|[^a-z])${escapeRe(w).replace(/ /g, '\\s+')}${mode === 'contains' ? "($|[^a-z])" : ''}`).test(norm);
  return norm.includes(w);
}
/** urgent beats clinical beats an exact cancel or confirm; confirm / cancel match only the WHOLE message. */
export function matchReply(text: string, rules: Rule[]): 'urgent' | 'clinical' | 'confirm' | 'cancel' | null {
  const norm = normalizeReply(text);
  if (!norm) return null;
  for (const intent of ['urgent', 'clinical'] as const) {
    if (rules.some((r) => r.intent === intent && (r.match === 'contains' || r.match === 'prefix') && wordMatch(norm, r.word, r.match))) return intent;
  }
  for (const intent of ['cancel', 'confirm'] as const) {
    if (rules.some((r) => r.intent === intent && r.match === 'exact' && norm === r.word.toLowerCase())) return intent;
  }
  return null;
}

// ── helpers ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
async function rpc<T>(deps: AgentDeps, fn: string, args?: Record<string, unknown>): Promise<T | null> {
  const r = await deps.rpc<T>(fn, args);
  if (r.error) throw new RunnerError('RPC_ERROR');
  return r.data;
}
async function act(deps: AgentDeps, fn: string, args: Record<string, unknown>): Promise<ActRes> {
  return (await rpc<ActRes>(deps, fn, args)) ?? { ok: false, error: { code: 'EMPTY' } };
}
const code = (r: ActRes) => r.error?.code ?? 'UNKNOWN';
const ctxFor = (j: Job, reasonSource?: string, stepKey?: string) => ({
  actor_kind: 'agent', agent: AGENT, org_id: j.org_id, branch_id: j.branch_id, reason_source: reasonSource ?? `playbook:${j.playbook.key}`, ...(stepKey ? { step_key: stepKey } : {}),
});
const skipped = (c: string, extra: Record<string, unknown> = {}): JobOutcome => ({ status: 'skipped', result: { code: c, ...extra }, error: c });
const done = (result: Record<string, unknown>): JobOutcome => ({ status: 'done', result });
const stepKeyOf = (j: Job, name: string) => `job:${j.job_id}:${name}`;

/** One idempotent step of a job: if it already succeeded (an earlier attempt), return that result; otherwise run the action with the step key in its ctx. */
async function step(deps: AgentDeps, j: Job, name: string, fn: string, args: Record<string, unknown>, reasonSource?: string): Promise<ActRes> {
  const key = stepKeyOf(j, name);
  const prior = await rpc<ActRes>(deps, 'agent_step_result', { p_org: j.org_id, p_key: key });
  if (prior && prior.ok) return prior;
  return act(deps, fn, { ...args, p_ctx: ctxFor(j, reasonSource, key) });
}
const stepDone = async (deps: AgentDeps, j: Job, name: string): Promise<boolean> => {
  const prior = await rpc<ActRes>(deps, 'agent_step_result', { p_org: j.org_id, p_key: stepKeyOf(j, name) });
  return !!(prior && prior.ok);
};

function sendArgs(j: Job, conversation: boolean): Record<string, unknown> {
  return {
    ...(conversation ? { p_conversation: j.conversation_id } : { p_customer: j.customer_id }),
    p_template: j.playbook.template_id, p_booking: j.booking_id, p_purpose: 'service', p_language: j.conversation?.language ?? null, p_on_quiet_hours: 'defer',
  };
}

function proposeArgs(deps: AgentDeps, j: Job, o: {
  action: 'act_message_send' | 'act_booking_set_status' | 'act_booking_flag_not_confirmed'; inputs: Record<string, unknown>; title: string; summary: string;
  usesAi: boolean; conversation?: boolean; sources?: unknown[]; expiresInHours?: number;
}): Record<string, unknown> {
  const now = (deps.now?.() ?? new Date()).getTime();
  return {
    p_agent: AGENT, p_kind: 'approval', p_branch: j.branch_id, p_title: o.title, p_summary: o.summary, p_action: o.action, p_inputs: o.inputs,
    p_playbook: j.playbook.id, p_sources: o.sources ?? [{ kind: 'playbook', key: j.playbook.key }], p_customer: j.customer_id, p_booking: j.booking_id,
    p_conversation: o.conversation ? j.conversation_id : null, p_urgent: false,
    p_expires_at: o.expiresInHours ? new Date(now + o.expiresInHours * 3600_000).toISOString() : null, p_uses_ai: o.usesAi,
  };
}
const itemId = (r: ActRes) => (r.data?.item_id as string | undefined) ?? null;
const templateInputs = (j: Job) => ({ template: j.playbook.template_id, purpose: 'service', on_quiet_hours: 'defer', ...(j.conversation?.language ? { language: j.conversation.language } : {}) });

function handoffStep(deps: AgentDeps, j: Job, reason: 'urgent' | 'clinical' | 'asks_to_change' | 'unclear' | 'other', summary: string, urgent = false, name = 'handoff'): Promise<ActRes> {
  return step(deps, j, name, 'act_conversation_handoff', { p_conversation: j.conversation_id, p_reason: reason, p_summary: summary, p_urgent: urgent }, 'patient_reply');
}

// ── the playbooks ──────────────────────────────────────────────────────────────────────────────────────────────────────────
async function templateEvent(deps: AgentDeps, j: Job): Promise<JobOutcome> {
  if (!j.playbook.template_id) return skipped('NO_TEMPLATE');
  const t = TEXT.item[j.event as 'booking_created' | 'day_before' | 'visit_completed'];
  const hours = j.event === 'day_before' ? 12 : 48;
  const draft = async () => {
    const p = await step(deps, j, 'draft', 'act_work_propose', proposeArgs(deps, j, { action: 'act_message_send', inputs: templateInputs(j), title: t.title, summary: t.summary, usesAi: false, expiresInHours: hours }));
    return p.ok ? done({ path: 'draft', item_id: itemId(p) }) : skipped(code(p));
  };
  if (j.playbook.level < 2) return draft();
  const r = await step(deps, j, 'send', 'act_message_send', sendArgs(j, false));
  if (r.ok) return done({ path: 'sent', action_id: r.action_id ?? null });
  if (code(r) === 'APPROVAL_REQUIRED') return draft();
  return skipped(code(r));
}

async function notConfirmed(deps: AgentDeps, j: Job): Promise<JobOutcome> {
  const t = TEXT.item.no_reply;
  const draft = async () => {
    const p = await step(deps, j, 'draft', 'act_work_propose', proposeArgs(deps, j, { action: 'act_booking_flag_not_confirmed', inputs: { reason: TEXT.reason.noReply }, title: t.title, summary: t.summary, usesAi: false, expiresInHours: 12 }));
    return p.ok ? done({ path: 'draft', item_id: itemId(p) }) : skipped(code(p));
  };
  if (j.playbook.level < 2) return draft();
  const r = await step(deps, j, 'flag', 'act_booking_flag_not_confirmed', { p_booking: j.booking_id, p_reason: TEXT.reason.noReply });
  if (r.ok) return done({ path: 'flagged', action_id: r.action_id ?? null });
  if (code(r) === 'APPROVAL_REQUIRED') return draft();
  return skipped(code(r));
}

async function confirmFlow(deps: AgentDeps, j: Job, o: { usesAi: boolean; alsoQuestion: boolean; path: string }): Promise<JobOutcome> {
  const result: Record<string, unknown> = { path: o.path };
  if (j.playbook.level >= 2) {
    const s = await step(deps, j, 'status', 'act_booking_set_status', { p_booking: j.booking_id, p_status: 'Confirmed', p_reason: TEXT.reason.confirm }, 'patient_reply');
    if (!s.ok) return skipped(code(s), { path: o.path });
    result.status_action_id = s.action_id ?? null;
    if (j.playbook.template_id) {
      const m = await step(deps, j, 'thanks', 'act_message_send', sendArgs(j, true));
      result.reply = m.ok ? 'sent' : code(m);
      if (m.ok) result.reply_action_id = m.action_id ?? null;
    } else result.reply = 'NO_TEMPLATE';
  } else {
    const a = await step(deps, j, 'draft_status', 'act_work_propose', proposeArgs(deps, j, { action: 'act_booking_set_status', inputs: { status: 'Confirmed', reason: TEXT.reason.confirm }, title: TEXT.item.reply_confirm.title,
      summary: TEXT.item.reply_confirm.summary, usesAi: o.usesAi, conversation: true, expiresInHours: 24 }));
    if (!a.ok) return skipped(code(a), { path: o.path });
    result.item_id = itemId(a);
    if (j.playbook.template_id && itemId(a)) {
      const b = await step(deps, j, 'draft_thanks', 'act_work_propose', proposeArgs(deps, j, { action: 'act_message_send', inputs: templateInputs(j), title: TEXT.item.reply_thanks.title, summary: TEXT.item.reply_thanks.summary,
        usesAi: o.usesAi, conversation: true, expiresInHours: 24, sources: [{ kind: 'playbook', key: j.playbook.key }, { kind: 'work_item', id: itemId(a), requires: true }] }));
      result.reply_item_id = b.ok ? itemId(b) : code(b);
    }
  }
  if (o.alsoQuestion) {
    const h = await handoffStep(deps, j, 'other', TEXT.handoff.confirm_question, false, 'handoff_question');
    result.question_handoff = h.ok ? 'done' : code(h);
  }
  return done(result);
}

async function cancelFlow(deps: AgentDeps, j: Job): Promise<JobOutcome> {
  const toDesk = async (why: string) => {
    const h = await handoffStep(deps, j, 'asks_to_change', TEXT.handoff.change);
    return h.ok ? done({ path: 'cancel_handoff', why }) : skipped(code(h), { path: 'cancel_handoff' });
  };
  if (j.playbook.level < 2) {
    const p = await step(deps, j, 'draft_cancel', 'act_work_propose', proposeArgs(deps, j, { action: 'act_booking_set_status', inputs: { status: 'Cancelled', reason: TEXT.reason.cancel }, title: TEXT.item.reply_cancel.title,
      summary: TEXT.item.reply_cancel.summary, usesAi: false, conversation: true, expiresInHours: 24 }));
    return p.ok ? done({ path: 'cancel_draft', item_id: itemId(p) }) : skipped(code(p));
  }
  const r = await step(deps, j, 'cancel', 'act_booking_set_status', { p_booking: j.booking_id, p_status: 'Cancelled', p_reason: TEXT.reason.cancel }, 'patient_reply');
  if (r.ok) return done({ path: 'cancelled', action_id: r.action_id ?? null });
  return toDesk(code(r));   // paid booking, locked day, ...: a person decides
}

async function patientReply(deps: AgentDeps, j: Job, rulesCache: Map<string, Rule[]>): Promise<JobOutcome> {
  if (!j.conversation_id || !j.conversation) return skipped('NO_CONVERSATION');
  if (j.conversation.state !== 'agent' && !(await stepDone(deps, j, 'handoff'))) return skipped('PERSON_HANDLING');   // (a retry of our own hand-off is not "a person took over")
  const text = j.reply_text ?? '';
  let rules = rulesCache.get(j.org_id);
  if (!rules) { rules = (await rpc<Rule[]>(deps, 'agent_get_reply_rules', { p_org: j.org_id })) ?? []; rulesCache.set(j.org_id, rules); }

  // 1. rules first. Symptoms hand off here, BEFORE ai_may_run and before any model call.
  const m = matchReply(text, rules);
  if (m === 'urgent' || m === 'clinical') {
    const h = await handoffStep(deps, j, m, TEXT.handoff.symptoms, m === 'urgent');
    return h.ok ? done({ path: `rule_${m}` }) : skipped(code(h), { path: `rule_${m}` });
  }
  if (m === 'confirm') return confirmFlow(deps, j, { usesAi: false, alsoQuestion: false, path: 'rule_confirm' });
  if (m === 'cancel') return cancelFlow(deps, j);

  // 2. free text: the model, only when AI may run
  const may = await rpc<boolean>(deps, 'ai_may_run', { p_org: j.org_id, p_branch: j.branch_id, p_agent: AGENT });
  if (!may) {
    const h = await handoffStep(deps, j, 'unclear', TEXT.handoff.ai_off);
    return h.ok ? done({ path: 'ai_off_handoff' }) : skipped(code(h), { path: 'ai_off_handoff' });
  }
  const out = await classifyReply(deps, { text, treatment: j.booking?.treatment ?? null, date: j.booking?.date ?? null });
  if (out.call) {   // the provider answered: the call is in the ledger, with null tokens and a USAGE_MISSING flag when it reported no usage
    try {
      await rpc(deps, 'ai_record_spend', { p_org: j.org_id, p_branch: j.branch_id, p_agent: AGENT, p_job: 'text', p_provider: MODEL_CONFIG.provider, p_model: MODEL_CONFIG.model,
        p_units: out.call.units, p_cost_npr: out.call.costNpr });
    } catch { deps.log?.(`job ${j.job_id} SPEND_FAILED`); }
  }
  if (!out.ok) {
    const h = await handoffStep(deps, j, 'unclear', TEXT.handoff.unclear);
    return h.ok ? done({ path: 'model_error', code: out.code }) : skipped(code(h), { path: 'model_error' });
  }
  const { intent, confidence, also_question } = out.result;
  if (intent === 'confirm' && confidence >= CONFIRM_MIN_CONFIDENCE) return confirmFlow(deps, j, { usesAi: true, alsoQuestion: also_question, path: 'model_confirm' });
  const map: Record<string, ['urgent' | 'clinical' | 'asks_to_change' | 'unclear' | 'other', string, boolean]> = {
    urgent: ['urgent', TEXT.handoff.symptoms, true], clinical: ['clinical', TEXT.handoff.symptoms, false],
    cancel: ['asks_to_change', TEXT.handoff.change, false], reschedule: ['asks_to_change', TEXT.handoff.change, false],
    question: ['other', TEXT.handoff.question, false], other: ['unclear', TEXT.handoff.unclear, false], confirm: ['unclear', TEXT.handoff.unclear, false],
  };
  const [reason, summary, urgent] = map[intent];
  const h = await handoffStep(deps, j, reason, summary, urgent);
  return h.ok ? done({ path: 'model_handoff', intent, confidence }) : skipped(code(h), { path: 'model_handoff' });
}

// ── one job, and the loop ──────────────────────────────────────────────────────────────────────────────────────────────────
async function processJob(deps: AgentDeps, j: Job, rulesCache: Map<string, Rule[]>): Promise<JobOutcome> {
  if (!j.playbook.enabled) return skipped('PLAYBOOK_OFF');
  if (!j.agent_enabled) return skipped('AGENT_OFF');
  if (!j.booking) return skipped('BOOKING_GONE');
  const okStatus = j.event === 'visit_completed' ? ['Completed'] : j.event === 'no_reply' || j.event === 'patient_reply' ? ['Pending'] : ['Pending', 'Confirmed'];
  if (!okStatus.includes(j.booking.status)) {
    // A retry of a reply job whose own status change already went through (the booking is no longer Pending because of US) carries on with the rest.
    const ownChange = j.event === 'patient_reply' && ((await stepDone(deps, j, 'status')) || (await stepDone(deps, j, 'cancel')));
    if (!ownChange) return skipped('BOOKING_NOT_ELIGIBLE');
  }
  if (j.event === 'patient_reply') return patientReply(deps, j, rulesCache);
  if (!j.customer_id) return skipped('NO_PATIENT');
  if (j.event === 'no_reply') return notConfirmed(deps, j);
  return templateEvent(deps, j);
}

export async function runAgentJobs(deps: AgentDeps, limit = 10): Promise<RunSummary> {
  const s: RunSummary = { claimed: 0, done: 0, skipped: 0, failed: 0, retried: 0 };
  const claimed = (await rpc<Job[]>(deps, 'agent_claim_jobs', { p_limit: limit })) ?? [];
  const rulesCache = new Map<string, Rule[]>();
  for (const job of claimed) {
    s.claimed++;
    let outcome: JobOutcome;
    try {
      outcome = await processJob(deps, job, rulesCache);
    } catch (e) {
      outcome = { status: 'retry', result: {}, error: e instanceof RunnerError ? e.code : 'RUNNER_ERROR' };   // a code only: never the error text
    }
    try {
      await rpc(deps, 'agent_finish_job', { p_job: job.job_id, p_status: outcome.status, p_result: outcome.result, p_error: outcome.error ?? null });
    } catch { deps.log?.(`job ${job.job_id} FINISH_FAILED`); }
    if (outcome.status === 'done') s.done++; else if (outcome.status === 'skipped') s.skipped++; else if (outcome.status === 'failed') s.failed++; else s.retried++;
    deps.log?.(`job ${job.job_id} ${outcome.status}${outcome.error ? ' ' + outcome.error : ''}`);
  }
  return s;
}
