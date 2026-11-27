// The hub's two edge-function bodies (the sender and the inbound webhook), written against injected dependencies so they run under Vitest with a
// mocked rpc and a mocked fetch. NO remote imports here. The index.ts files only wire a Supabase service-role client into HubDeps.
//
// Security notes (see hub-inbound/README.md):
//   * test provider  . every request must carry x-hub-signature = sha256 HMAC of the RAW body (HUB_TEST_WEBHOOK_SECRET); checked BEFORE parsing.
//   * aakash         . Aakash does not sign what it forwards (nothing is documented), so the URL carries a long random path token, compared in
//                      constant time against the env variable named "<secret_ref>_INBOUND_TOKEN". A request that holds the token may do only what
//                      act_message_receive does: add one inbound message to a thread for the SENDING number, and record STOP / START for that
//                      same number. It is rate limited per account (60 a minute); the rest is dropped and counted.
//   * nothing here logs a URL, a body, a phone number or a secret.
import {
  parseAakashInbound, parseTestWebhook, resolveHubProvider, safeEqual, verifyTestWebhook, hmacSha256Hex,
  ProviderRejectedError, type DeliveryUpdate, type PendingDelivery, type TestRecorder,
} from './channels.ts';

export interface RpcResult<T = unknown> { data: T | null; error: { message: string } | null }
export interface HubDeps {
  rpc<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<RpcResult<T>>;
  env(name: string): string | undefined;
  recordTest: TestRecorder;
  fetchImpl?: typeof fetch;
  now?: () => Date;
}

export const INBOUND_RATE_LIMIT_PER_MINUTE = 60;
const MAX_BODY_BYTES = 100_000;

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

interface AccountRow { id: string; org_id: string; branch_id: string | null; channel: string; status: string; secret_ref: string | null }

async function receive(deps: HubDeps, account: AccountRow, from: string, body: string, providerMessageId?: string): Promise<Response> {
  const allowed = await deps.rpc<boolean>('hub_rate_check', { p_account: account.id, p_limit: INBOUND_RATE_LIMIT_PER_MINUTE });
  if (allowed.error) return json({ ok: false }, 500);
  if (allowed.data === false) return json({ ok: true, dropped: true });   // dropped and counted in hub_inbound_rate; 200 so the gateway does not retry in a storm
  const res = await deps.rpc<{ ok: boolean; error?: { code: string } }>('act_message_receive', {
    p_account: account.id, p_from: from, p_body: body, p_provider_message_id: providerMessageId ?? null, p_received_at: null,
    p_ctx: { actor_kind: 'patient', org_id: account.org_id },
  });
  if (res.error) return json({ ok: false }, 500);
  return json({ ok: res.data?.ok === true, ...(res.data?.ok ? {} : { code: res.data?.error?.code }) });
}

export async function handleInbound(req: Request, deps: HubDeps): Promise<Response> {
  const url = new URL(req.url);
  const segments = url.pathname.split('/').filter(Boolean);
  const at = segments.indexOf('hub-inbound');
  const [provider, token] = segments.slice(at + 1);

  if (provider === 'test') {
    if (req.method !== 'POST') return json({ ok: false }, 405);
    const raw = await req.text();
    if (raw.length > MAX_BODY_BYTES) return json({ ok: false }, 413);
    if (!(await verifyTestWebhook(raw, req.headers, deps.env('HUB_TEST_WEBHOOK_SECRET')))) return json({ ok: false, error: 'unauthorized' }, 401);
    let parsedJson: unknown;
    try { parsedJson = JSON.parse(raw); } catch { return json({ ok: false, error: 'bad json' }, 400); }
    const hook = parseTestWebhook(parsedJson);
    if (hook.kind === 'ignore') return json({ ok: true, ignored: true });
    const recipient = hook.to;   // the account's sender number: how we find the org and branch
    if (!recipient) return json({ ok: false, error: 'the recipient (to) is required' }, 400);
    const found = await deps.rpc<AccountRow[]>('hub_find_account', { p_provider: 'test', p_recipient: recipient });
    const account = found.data?.[0];
    if (found.error) return json({ ok: false }, 500);
    if (!account) return json({ ok: false, error: 'unknown account' }, 404);
    if (hook.kind === 'inbound') return receive(deps, account, hook.from, hook.body, hook.providerMessageId);
    const applied = await deps.rpc<string>('hub_apply_delivery_status', {
      p_account: account.id, p_provider_message_id: hook.update.providerMessageId, p_status: hook.update.status, p_at: hook.update.at ?? null, p_error: hook.update.error ?? null,
    });
    if (applied.error) return json({ ok: false }, 500);
    return json({ ok: true, result: applied.data });
  }

  if (provider === 'aakash') {
    if (req.method !== 'GET') return json({ ok: false }, 405);
    if (!token) return json({ ok: false }, 404);
    const list = await deps.rpc<AccountRow[]>('hub_list_accounts', { p_provider: 'aakash' });
    if (list.error) return json({ ok: false }, 500);
    let matched: AccountRow | undefined;
    for (const a of list.data ?? []) {   // every account is compared: no early exit that would leak which one matched
      const expected = a.secret_ref ? deps.env(`${a.secret_ref}_INBOUND_TOKEN`) : undefined;
      if (expected && safeEqual(token, expected)) matched = a;
    }
    if (!matched) return json({ ok: false }, 404);   // the same answer for "no such account" and "wrong token"
    const inbound = parseAakashInbound(url.searchParams);
    if (!inbound) return json({ ok: false, error: 'from and text are required' }, 400);
    // Aakash sends no message id: a retry within the same minute is recognised by a keyed hash of sender, text and minute
    const minute = (deps.now?.() ?? new Date()).toISOString().slice(0, 16);
    const pid = 'aakash:' + (await hmacSha256Hex(deps.env(`${matched.secret_ref}_INBOUND_TOKEN`) ?? '', `${inbound.from}|${inbound.body}|${minute}`)).slice(0, 32);
    return receive(deps, matched, inbound.from, inbound.body, pid);
  }

  return json({ ok: false }, 404);
}

interface ClaimedMessage {
  id: string; org_id: string; conversation_id: string; to_address: string; body: string; channel: string; provider: string;
  sender: string; secret_ref: string | null; account_id: string; credit_cost_npr: number | null;
}
interface PollAccount { id: string; org_id: string; provider: string; secret_ref: string | null; last_polled_at: string | null }
interface PendingRow { message_id: string; provider_message_id: string; to_address: string; sent_at: string }

/** mode 'send': claim due messages and send them one by one. mode 'poll': pull delivery reports for providers that only offer a pull. */
export async function runHubSend(deps: HubDeps, mode: 'send' | 'poll'): Promise<Record<string, number>> {
  const out: Record<string, number> = { claimed: 0, sent: 0, failed: 0, polled: 0, updated: 0, errors: 0 };

  if (mode === 'send') {
    const claim = await deps.rpc<ClaimedMessage[]>('hub_claim_messages', { p_limit: 20 });
    if (claim.error) { out.errors++; return out; }
    for (const m of claim.data ?? []) {
      out.claimed++;
      let provider;
      try {
        provider = resolveHubProvider(m.channel, m.provider, { secret: m.secret_ref ? deps.env(m.secret_ref) : undefined, fetchImpl: deps.fetchImpl, recordTest: deps.recordTest });
      } catch (e) {
        // not configured: certainly NOT sent
        await deps.rpc('hub_record_send_result', { p_message: m.id, p_ok: false, p_provider_message_id: null, p_credits: null, p_error: (e as Error).message });
        out.failed++;
        continue;
      }
      try {
        const r = await provider.send({ to: m.to_address, body: m.body, meta: { messageId: m.id } });
        await deps.rpc('hub_record_send_result', { p_message: m.id, p_ok: true, p_provider_message_id: r.providerMessageId, p_credits: r.credits ?? null, p_error: null });
        out.sent++;
      } catch (e) {
        // an explicit refusal means nothing was sent; anything else (network, 5xx, an answer we cannot read) is an unknown outcome, never re-sent
        const certain = e instanceof ProviderRejectedError;
        await deps.rpc('hub_record_send_result', { p_message: m.id, p_ok: false, p_provider_message_id: null, p_credits: null, p_error: certain ? (e as Error).message : `outcome unknown: ${(e as Error).message}` });
        out.failed++;
      }
    }
    return out;
  }

  const accounts = await deps.rpc<PollAccount[]>('hub_poll_accounts');
  if (accounts.error) { out.errors++; return out; }
  for (const a of accounts.data ?? []) {
    try {
      const provider = resolveHubProvider('sms', a.provider, { secret: a.secret_ref ? deps.env(a.secret_ref) : undefined, fetchImpl: deps.fetchImpl, recordTest: deps.recordTest });
      if (!provider.fetchDeliveryUpdates) continue;
      const pending = await deps.rpc<PendingRow[]>('hub_pending_delivery', { p_account: a.id });
      if (pending.error) { out.errors++; continue; }
      const rows: PendingDelivery[] = (pending.data ?? []).map((p) => ({ messageId: p.message_id, providerMessageId: p.provider_message_id, to: p.to_address, sentAt: p.sent_at }));
      out.polled++;
      if (rows.length > 0) {
        const since = new Date(Math.min(...rows.map((r) => new Date(r.sentAt).getTime())));
        const updates: DeliveryUpdate[] = await provider.fetchDeliveryUpdates(rows, since);
        for (const u of updates) {
          const r = await deps.rpc<string>('hub_apply_delivery_status', { p_account: a.id, p_provider_message_id: u.providerMessageId, p_status: u.status, p_at: u.at ?? null, p_error: u.error ?? null });
          if (!r.error && r.data === 'updated') out.updated++;
        }
      }
      await deps.rpc('hub_mark_polled', { p_account: a.id });
    } catch (_e) {
      out.errors++;   // never log provider text here (it can echo numbers); the counter is the signal
    }
  }
  return out;
}
