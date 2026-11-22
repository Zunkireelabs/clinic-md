// Channel providers behind one interface. This file has NO remote imports on purpose: the logic here is unit-tested with Vitest (mocked fetch only).
//
//   * email  . Resend (the old outreach, unchanged)
//   * sms    . 'test' (local development) and 'aakash' (Aakash SMS, Nepal)
//   * whatsapp, viber, messenger . later; a new gateway is a new class plus one line in resolveHubProvider, selected per channel_accounts.provider.
//
// Secrets never come from the database: a channel account stores only the NAME of an env variable (secret_ref); the caller reads the value.

export type Channel = 'email' | 'sms' | 'whatsapp';

export interface ChannelSendInput {
  to: string;
  subject?: string;
  body: string;
  meta?: Record<string, unknown>;
}

export interface ChannelSendResult {
  providerMessageId: string;
  /** provider credits used, when the provider reports them (cost in NPR = credits x the account's price) */
  credits?: number;
}

export type DeliveryStatus = 'sent' | 'delivered' | 'read' | 'failed';
export interface DeliveryUpdate {
  providerMessageId: string;
  status: DeliveryStatus;
  at?: string;
  error?: string;
}
export interface PendingDelivery {
  messageId: string;
  providerMessageId: string;
  to: string;
  sentAt: string;
}

export type ParsedWebhook =
  | { kind: 'inbound'; from: string; to?: string; body: string; providerMessageId?: string; receivedAt?: string }
  | { kind: 'status'; update: DeliveryUpdate; to?: string }
  | { kind: 'ignore'; reason: string };

/** The provider refused the message (nothing was sent). Safe to mark the message failed. */
export class ProviderRejectedError extends Error {
  constructor(message: string, readonly code = 'REJECTED') {
    super(message);
    this.name = 'ProviderRejectedError';
  }
}
/** We cannot tell whether the provider sent it (network error, a 5xx, an unreadable answer). A person decides; it is never re-sent automatically. */
export class ProviderUnknownOutcomeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ProviderUnknownOutcomeError';
  }
}

export interface ChannelProvider {
  channel: Channel;
  /** the value of channel_accounts.provider */
  readonly name: string;
  /** true when sending the same message twice cannot produce two texts (no provider except 'test' offers this today) */
  readonly idempotentSend: boolean;
  send(input: ChannelSendInput): Promise<ChannelSendResult>;
  /** providers that only offer a pull report: what happened to these messages since `since` */
  fetchDeliveryUpdates?(pending: PendingDelivery[], since: Date): Promise<DeliveryUpdate[]>;
}

export class ResendEmailProvider implements ChannelProvider {
  channel = 'email' as const;
  readonly name = 'resend';
  readonly idempotentSend = false;

  constructor(
    private apiKey: string,
    private fromAddress: string,
    private fromName?: string
  ) {}

  private buildFrom(): string {
    if (!this.fromName) return this.fromAddress;
    const needsQuoting = /[",()<>:;\\]/.test(this.fromName);
    const name = needsQuoting
      ? `"${this.fromName.replace(/"/g, '\\"')}"`
      : this.fromName;
    return `${name} <${this.fromAddress}>`;
  }

  async send({
    to,
    subject,
    body,
  }: ChannelSendInput): Promise<ChannelSendResult> {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: this.buildFrom(),
        to,
        subject,
        html: body,
      }),
    });

    if (!res.ok) {
      throw new Error(
        `Resend send failed: ${res.status} ${await res.text()}`
      );
    }

    const json = (await res.json()) as { id: string };
    return { providerMessageId: json.id };
  }
}

// ── helpers shared by the hub providers ───────────────────────────────────────────────────────────────────────────────────────────────────

/** Constant-time string comparison (webhook secrets and path tokens). Different lengths still compare in the time of the longer one. */
export function safeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

// ── the TEST provider (local development) ──────────────────────────────────────────────────────────────────────────────────────────────────
// "Sends" by writing to a local log table (hub_test_outbox) through `record`. Delivery, read, failure and replies are simulated by POSTing a
// SIGNED payload to hub-inbound/test, which goes through the same path a real provider will use.
export interface TestRecorder {
  (row: { messageId?: string; to: string; body: string }): Promise<void>;
}

export class TestSmsProvider implements ChannelProvider {
  channel: Channel;
  readonly name = 'test';
  readonly idempotentSend = true;

  constructor(private record: TestRecorder, channel: Channel = 'sms') {
    this.channel = channel;
  }

  async send({ to, body, meta }: ChannelSendInput): Promise<ChannelSendResult> {
    const messageId = typeof meta?.messageId === 'string' ? meta.messageId : undefined;
    await this.record({ messageId, to, body });
    return { providerMessageId: `test-${messageId ?? crypto.randomUUID()}`, credits: 1 };
  }
}

/** The signature a test webhook must carry: `x-hub-signature: sha256=<hex of HMAC-SHA256(secret, raw body)>`. */
export async function verifyTestWebhook(rawBody: string, headers: { get(name: string): string | null }, secret: string | undefined): Promise<boolean> {
  if (!secret) return false;
  const header = headers.get('x-hub-signature') ?? '';
  const provided = header.startsWith('sha256=') ? header.slice(7) : header;
  if (!provided) return false;
  return safeEqual(provided, await hmacSha256Hex(secret, rawBody));
}

/** { type: 'inbound', from, to, text, id } or { type: 'status', to (the account's sender), id, status: 'sent'|'delivered'|'read'|'failed', error? } */
export function parseTestWebhook(json: unknown): ParsedWebhook {
  const j = (json ?? {}) as Record<string, unknown>;
  if (j.type === 'inbound' && typeof j.from === 'string' && typeof j.text === 'string') {
    return {
      kind: 'inbound',
      from: j.from,
      to: typeof j.to === 'string' ? j.to : undefined,
      body: j.text,
      providerMessageId: typeof j.id === 'string' ? j.id : undefined,
    };
  }
  if (j.type === 'status' && typeof j.id === 'string' && ['sent', 'delivered', 'read', 'failed'].includes(String(j.status))) {
    return {
      kind: 'status',
      update: { providerMessageId: j.id, status: j.status as DeliveryStatus, error: typeof j.error === 'string' ? j.error : undefined, at: typeof j.at === 'string' ? j.at : undefined },
      to: typeof j.to === 'string' ? j.to : undefined,
    };
  }
  return { kind: 'ignore', reason: 'unrecognised test webhook' };
}

// ── AAKASH SMS (Nepal) ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
// Built from Aakash's PUBLIC docs (https://aakashsms.com/documentation/ and https://bitbucket.org/aakashsms/api/raw/v4/README.md), which carry no
// date or version stamp and contradict themselves in places. NOT TESTED AGAINST THE REAL API: tests use mocked HTTP only. What the docs say and
// what this adapter does:
//   send     POST {base}/v4/send-user, JSON { to: [10-digit numbers], text: [texts] }, header "auth-token". Response: a "responses" array, each
//            { error, message, data: { valid: [{ id, mobile, text, credit, network, status:'queued' }], invalid: [{ ..., status:'aborted' }] } }.
//            Errors are plain text ("Not enough balance.", "The provided Auth Token is not valid."): there are NO numeric codes.
//   report   PULL only: POST {base}/v4/api-report, JSON { start_date, end_date } (Y-m-d), header "auth-token". The v4 row fields are not documented
//            (the v1 report has id, receiver, network, message, api_credit, delivery_at), so rows are matched on id and read tolerantly.
//            A message that never shows up in the report simply stays "sent". There is no documented way to learn that one FAILED after queueing.
//   inbound  a PUSH by GET to a URL we give them (keyword, from, text). It is NOT signed: see parseAakashInbound and hub.ts (secret path token).
//   numbers  10-digit national numbers (98XXXXXXXX). +977 numbers are converted; any other country is refused (a Nepal-only gateway).
//   unicode  Nepali text, length and rate limits are NOT documented: nothing is split or truncated here.
export function toAakashNumber(e164: string): string {
  const digits = String(e164 ?? '').replace(/\D/g, '');
  const national = digits.startsWith('977') ? digits.slice(3) : digits;
  if (!/^9\d{9}$/.test(national) || (digits.startsWith('977') ? digits.length !== 13 : digits.length !== 10)) {
    throw new ProviderRejectedError('Aakash SMS only delivers to Nepal mobile numbers (+977 98XXXXXXXX).', 'UNSUPPORTED_DESTINATION');
  }
  return national;
}

interface AakashEntry { id?: string | number; mobile?: string; status?: string; credit?: number | string }

export class AakashSmsProvider implements ChannelProvider {
  channel = 'sms' as const;
  readonly name = 'aakash';
  readonly idempotentSend = false; // no idempotency key is documented

  constructor(
    private authToken: string,
    private fetchImpl: typeof fetch = fetch,
    private baseUrl = 'https://sms.aakashsms.com/sms'
  ) {}

  private async post(path: string, payload: unknown): Promise<Response> {
    try {
      return await this.fetchImpl(`${this.baseUrl}${path}`, {
        method: 'POST',
        headers: { 'auth-token': this.authToken, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
    } catch (e) {
      // the request may have reached them: we cannot know
      throw new ProviderUnknownOutcomeError(`Aakash SMS: no answer (${(e as Error).message})`);
    }
  }

  async send({ to, body }: ChannelSendInput): Promise<ChannelSendResult> {
    const number = toAakashNumber(to);
    const res = await this.post('/v4/send-user', { to: [number], text: [body] });
    const raw = await res.text();
    if (!res.ok) {
      if (res.status >= 500) throw new ProviderUnknownOutcomeError(`Aakash SMS: HTTP ${res.status}`);
      throw new ProviderRejectedError(`Aakash SMS: HTTP ${res.status}${aakashMessage(raw) ? ` (${aakashMessage(raw)})` : ''}`);
    }
    let json: unknown;
    try { json = JSON.parse(raw); } catch { throw new ProviderUnknownOutcomeError('Aakash SMS: the answer was not JSON'); }
    const parsed = parseAakashSend(json);
    if (parsed.accepted) return { providerMessageId: parsed.id, credits: parsed.credits };
    throw new ProviderRejectedError(parsed.error);
  }

  /** Pulls the delivery report for the period and returns an update for every pending message that appears in it as delivered. */
  async fetchDeliveryUpdates(pending: PendingDelivery[], since: Date): Promise<DeliveryUpdate[]> {
    if (pending.length === 0) return [];
    const res = await this.post('/v4/api-report', { start_date: ymd(since), end_date: ymd(new Date()) });
    if (!res.ok) throw new ProviderUnknownOutcomeError(`Aakash SMS report: HTTP ${res.status}`);
    let json: unknown;
    try { json = await res.json(); } catch { throw new ProviderUnknownOutcomeError('Aakash SMS report: the answer was not JSON'); }
    return matchAakashReport(json, pending);
  }
}

/** Y-m-d in Asia/Kathmandu (+05:45, no DST). */
export function ymd(d: Date): string {
  return new Date(d.getTime() + (5 * 60 + 45) * 60000).toISOString().slice(0, 10);
}

function aakashMessage(raw: string): string | undefined {
  try {
    const j = JSON.parse(raw) as Record<string, unknown>;
    const msg = (j.message ?? (Array.isArray(j.errors) ? j.errors[0] : undefined)) as unknown;
    return typeof msg === 'string' ? msg.slice(0, 200) : undefined;
  } catch { return undefined; }
}

/** Reads the v4 send answer: one accepted message (id + credits), or the provider's own error text. Anything unrecognised is an unknown outcome. */
export function parseAakashSend(json: unknown): { accepted: true; id: string; credits?: number } | { accepted: false; error: string } {
  const j = (json ?? {}) as Record<string, unknown>;
  const responses = Array.isArray(j.responses) ? (j.responses as Record<string, unknown>[]) : [j];
  const texts: string[] = [];
  for (const r of responses) {
    const data = (r.data ?? {}) as { valid?: AakashEntry[]; invalid?: AakashEntry[] };
    const valid = Array.isArray(data.valid) ? data.valid : [];
    if (r.error !== true && valid.length > 0 && valid[0].id !== undefined && valid[0].id !== null) {
      const credit = Number(valid[0].credit);
      return { accepted: true, id: String(valid[0].id), credits: Number.isFinite(credit) ? credit : undefined };
    }
    if (typeof r.message === 'string' && r.message) texts.push(r.message);
    if (Array.isArray(data.invalid) && data.invalid.length > 0) texts.push('the number was refused (aborted)');
  }
  if (Array.isArray(j.responses) && typeof j.message === 'string' && j.message) texts.unshift(j.message);   // v4 failure: "All messages encountered errors." at the top
  if (Array.isArray(j.errors)) for (const e of j.errors) if (typeof e === 'string') texts.push(e);
  if (texts.length === 0 && !('error' in j) && !('responses' in j)) throw new ProviderUnknownOutcomeError('Aakash SMS: an answer we do not recognise');
  return { accepted: false, error: `Aakash SMS: ${[...new Set(texts)].join(' ').slice(0, 300) || 'the message was not accepted'}` };
}

/** Finds the report rows (the field names are not documented for v4, so several shapes are tried) and turns the delivered ones into updates. */
export function matchAakashReport(json: unknown, pending: PendingDelivery[]): DeliveryUpdate[] {
  const j = (json ?? {}) as Record<string, unknown>;
  const candidates: unknown[] = [j.data, (Array.isArray(j.responses) ? (j.responses[0] as Record<string, unknown> | undefined)?.data : undefined), json];
  let rows: Record<string, unknown>[] = [];
  for (const c of candidates) if (Array.isArray(c)) { rows = c as Record<string, unknown>[]; break; }
  const byId = new Map(pending.map((p) => [p.providerMessageId, p]));
  const updates: DeliveryUpdate[] = [];
  for (const row of rows) {
    const id = row.id !== undefined && row.id !== null ? String(row.id) : undefined;
    if (!id || !byId.has(id)) continue;
    const status = String(row.status ?? '').toLowerCase();
    const at = typeof row.delivery_at === 'string' ? row.delivery_at : typeof row.delivered_at === 'string' ? row.delivered_at : undefined;
    if (/fail|reject|undeliver|expired/.test(status)) updates.push({ providerMessageId: id, status: 'failed', error: `Aakash SMS report: ${status}` });
    else if (/deliver/.test(status) || (!status && at)) updates.push({ providerMessageId: id, status: 'delivered', at });
  }
  return updates;
}

/** Aakash forwards an incoming SMS by GET with ?keyword=&from=&text=. Returns null when the sender or the text is missing. */
export function parseAakashInbound(params: URLSearchParams): { from: string; body: string; keyword?: string } | null {
  const from = (params.get('from') ?? '').trim();
  const body = (params.get('text') ?? '').trim();
  if (!from || !body) return null;
  return { from, body, keyword: params.get('keyword') ?? undefined };
}

// ── choosing the provider ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────

export function resolveProvider(
  channel: string,
  config: { provider: string; from_address?: string },
  secrets: Record<string, string>,
  fromName?: string
): ChannelProvider {
  if (channel === 'email' && config.provider === 'resend') {
    return new ResendEmailProvider(
      secrets.RESEND_API_KEY,
      config.from_address ?? secrets.RESEND_FROM_ADDRESS,
      fromName
    );
  }
  throw new Error(
    `No provider registered for channel=${channel} provider=${config.provider}`
  );
}

/** The hub's providers, chosen per channel_accounts row. `secret` is the value of the env variable named by secret_ref (never read from a table). */
export function resolveHubProvider(
  channel: string,
  provider: string,
  deps: { secret?: string; fetchImpl?: typeof fetch; recordTest?: TestRecorder; aakashBaseUrl?: string }
): ChannelProvider {
  if (provider === 'test' && (channel === 'sms' || channel === 'whatsapp')) {
    if (!deps.recordTest) throw new Error('The test provider needs a recorder');
    return new TestSmsProvider(deps.recordTest, channel);
  }
  if (provider === 'aakash' && channel === 'sms') {
    if (!deps.secret) throw new Error('Aakash SMS: the API key is not configured (the env variable named by secret_ref is empty)');
    return new AakashSmsProvider(deps.secret, deps.fetchImpl ?? fetch, deps.aakashBaseUrl);
  }
  throw new Error(`No provider registered for channel=${channel} provider=${provider}`);
}
