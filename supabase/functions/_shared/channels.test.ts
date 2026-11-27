import { describe, it, expect, vi } from 'vitest';
import {
  AakashSmsProvider, ProviderRejectedError, ProviderUnknownOutcomeError, TestSmsProvider, hmacSha256Hex, matchAakashReport, parseAakashInbound, parseAakashSend,
  parseTestWebhook, resolveHubProvider, resolveProvider, safeEqual, toAakashNumber, verifyTestWebhook, ymd, type PendingDelivery,
} from './channels';

// MOCKED HTTP ONLY. Nothing here talks to Aakash. The Aakash adapter is built from their public docs and is untested against the real API.
const okResponse = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });
const accepted = (id: string | number = '8967_1731910652', credit: number | string = 1) => ({
  responses: [{ error: false, message: '1 messages have been queued for delivery.', data: { valid: [{ id, mobile: '9779812345678', text: 'hi', credit, network: 'NTC', status: 'queued', shortcode: 'X' }], invalid: [] } }],
  errors: [],
});

describe('safeEqual', () => {
  it('is true only for identical strings, whatever the length', () => {
    expect(safeEqual('abc', 'abc')).toBe(true);
    expect(safeEqual('abc', 'abd')).toBe(false);
    expect(safeEqual('abc', 'abcd')).toBe(false);
    expect(safeEqual('', '')).toBe(true);
    expect(safeEqual('', 'a')).toBe(false);
  });
});

describe('test provider', () => {
  it('writes to the recorder and returns a provider id and one credit', async () => {
    const record = vi.fn(async () => {});
    const p = new TestSmsProvider(record);
    const r = await p.send({ to: '+9779801000001', body: 'Hello', meta: { messageId: 'm-1' } });
    expect(record).toHaveBeenCalledWith({ messageId: 'm-1', to: '+9779801000001', body: 'Hello' });
    expect(r).toEqual({ providerMessageId: 'test-m-1', credits: 1 });
    expect(p.name).toBe('test');
    expect(p.idempotentSend).toBe(true);
  });

  describe('verifyTestWebhook', () => {
    const body = JSON.stringify({ type: 'inbound', from: '+9779801000001', to: '+9779700000001', text: 'hello' });
    const headersOf = (sig: string | null) => ({ get: (n: string) => (n === 'x-hub-signature' ? sig : null) });
    it('accepts a correct signature (with or without the sha256= prefix)', async () => {
      const sig = await hmacSha256Hex('s3cret', body);
      expect(await verifyTestWebhook(body, headersOf('sha256=' + sig), 's3cret')).toBe(true);
      expect(await verifyTestWebhook(body, headersOf(sig), 's3cret')).toBe(true);
    });
    it('rejects a wrong secret, a tampered body, a missing header and a missing server secret', async () => {
      const sig = await hmacSha256Hex('s3cret', body);
      expect(await verifyTestWebhook(body, headersOf('sha256=' + sig), 'other')).toBe(false);
      expect(await verifyTestWebhook(body + ' ', headersOf('sha256=' + sig), 's3cret')).toBe(false);
      expect(await verifyTestWebhook(body, headersOf(null), 's3cret')).toBe(false);
      expect(await verifyTestWebhook(body, headersOf('sha256=' + sig), undefined)).toBe(false);
      expect(await verifyTestWebhook(body, headersOf('sha256='), 's3cret')).toBe(false);
    });
  });

  describe('parseTestWebhook', () => {
    it('reads an inbound message', () => {
      expect(parseTestWebhook({ type: 'inbound', from: '+977980', to: '+977970', text: 'Hi', id: 'p1' })).toEqual({ kind: 'inbound', from: '+977980', to: '+977970', body: 'Hi', providerMessageId: 'p1' });
    });
    it('reads delivered, read and failed statuses', () => {
      for (const status of ['sent', 'delivered', 'read', 'failed']) {
        const r = parseTestWebhook({ type: 'status', id: 'p1', status, to: '+977970' });
        expect(r.kind).toBe('status');
        if (r.kind === 'status') { expect(r.update.status).toBe(status); expect(r.to).toBe('+977970'); }
      }
    });
    it('ignores anything else', () => {
      expect(parseTestWebhook({ type: 'status', id: 'p1', status: 'exploded' }).kind).toBe('ignore');
      expect(parseTestWebhook(null).kind).toBe('ignore');
      expect(parseTestWebhook({ type: 'inbound', from: 1 }).kind).toBe('ignore');
    });
  });
});

describe('Aakash: toAakashNumber', () => {
  it('converts Nepal numbers to the 10-digit national form', () => {
    expect(toAakashNumber('+9779812345678')).toBe('9812345678');
    expect(toAakashNumber('9779812345678')).toBe('9812345678');
    expect(toAakashNumber('9812345678')).toBe('9812345678');
    expect(toAakashNumber('+977 981-234-5678')).toBe('9812345678');
  });
  it.each(['+15551234567', '+9779', '+97798123456', '+97781234567890', '12345', '', '+9778123456789'])('refuses %s', (n) => {
    expect(() => toAakashNumber(n)).toThrow(ProviderRejectedError);
  });
});

describe('Aakash: send', () => {
  it('posts JSON to the v4 send endpoint with the token in the auth-token header, and returns the id and credits', async () => {
    const fetchMock = vi.fn(async () => okResponse(accepted('abc_1', 2)));
    const p = new AakashSmsProvider('KEY-123', fetchMock as unknown as typeof fetch);
    const r = await p.send({ to: '+9779812345678', body: 'Your visit is on Sunday' });
    expect(r).toEqual({ providerMessageId: 'abc_1', credits: 2 });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://sms.aakashsms.com/sms/v4/send-user');
    expect(init.method).toBe('POST');
    expect((init.headers as Record<string, string>)['auth-token']).toBe('KEY-123');
    expect(JSON.parse(init.body as string)).toEqual({ to: ['9812345678'], text: ['Your visit is on Sunday'] });
    expect(url).not.toContain('KEY-123');   // the key is never in a URL
  });
  it('accepts a numeric id and a missing credit', async () => {
    const fetchMock = vi.fn(async () => okResponse({ responses: [{ error: false, data: { valid: [{ id: 2673160, status: 'queued' }], invalid: [] } }] }));
    const r = await new AakashSmsProvider('K', fetchMock as unknown as typeof fetch).send({ to: '9812345678', body: 'x' });
    expect(r.providerMessageId).toBe('2673160');
    expect(r.credits).toBeUndefined();
  });
  it('refuses a non-Nepal number before any request is made', async () => {
    const fetchMock = vi.fn();
    await expect(new AakashSmsProvider('K', fetchMock as unknown as typeof fetch).send({ to: '+15551234567', body: 'x' })).rejects.toBeInstanceOf(ProviderRejectedError);
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it.each([
    ['Not enough balance.', { responses: [{ error: true, message: 'Not enough balance.', data: [] }], errors: ['Not enough balance.'] }],
    ['The provided Auth Token is not valid.', { responses: [{ error: true, message: 'The provided Auth Token is not valid.', data: [] }] }],
    ['All messages encountered errors.', { message: 'All messages encountered errors.', responses: [], errors: ['No valid recipients.'] }],
  ])('a refusal ("%s") is a ProviderRejectedError that keeps the provider text', async (text, body) => {
    const p = new AakashSmsProvider('K', (async () => okResponse(body)) as unknown as typeof fetch);
    const err = await p.send({ to: '9812345678', body: 'x' }).catch((e) => e);
    expect(err).toBeInstanceOf(ProviderRejectedError);
    expect((err as Error).message).toContain(text.replace(/\.$/, ''));
  });
  it('an aborted (invalid) number is a refusal', async () => {
    const body = { responses: [{ error: false, message: '0 messages queued', data: { valid: [], invalid: [{ id: 1, mobile: '988585584', status: 'aborted', credit: 0 }] } }] };
    await expect(new AakashSmsProvider('K', (async () => okResponse(body)) as unknown as typeof fetch).send({ to: '9812345678', body: 'x' })).rejects.toBeInstanceOf(ProviderRejectedError);
  });
  it('a 4xx answer is a refusal; a 5xx, a network error, a non-JSON answer and an unrecognised answer are UNKNOWN outcomes (never re-sent)', async () => {
    const send = (f: unknown) => new AakashSmsProvider('K', f as typeof fetch).send({ to: '9812345678', body: 'x' }).catch((e) => e);
    expect(await send(async () => okResponse({ message: 'nope' }, 401))).toBeInstanceOf(ProviderRejectedError);
    expect(await send(async () => okResponse({}, 503))).toBeInstanceOf(ProviderUnknownOutcomeError);
    expect(await send(async () => { throw new Error('socket hang up'); })).toBeInstanceOf(ProviderUnknownOutcomeError);
    expect(await send(async () => new Response('<html>oops</html>', { status: 200 }))).toBeInstanceOf(ProviderUnknownOutcomeError);
    expect(await send(async () => okResponse({ something: 'else' }))).toBeInstanceOf(ProviderUnknownOutcomeError);
  });
  it('declares that it is not idempotent', () => {
    expect(new AakashSmsProvider('K').idempotentSend).toBe(false);
    expect(new AakashSmsProvider('K').name).toBe('aakash');
  });
  it('parseAakashSend reads the v4 shape', () => {
    expect(parseAakashSend(accepted('x1', '3'))).toEqual({ accepted: true, id: 'x1', credits: 3 });
  });
});

describe('Aakash: delivery report (pull)', () => {
  const pending: PendingDelivery[] = [
    { messageId: 'm1', providerMessageId: 'A1', to: '+9779812345678', sentAt: '2026-11-22T04:00:00Z' },
    { messageId: 'm2', providerMessageId: 'A2', to: '+9779812345679', sentAt: '2026-11-22T04:01:00Z' },
    { messageId: 'm3', providerMessageId: 'A3', to: '+9779812345670', sentAt: '2026-11-22T04:02:00Z' },
  ];
  it('requests the report for the date range with the token in the header', async () => {
    const fetchMock = vi.fn(async () => okResponse({ error: false, data: [] }));
    await new AakashSmsProvider('KEY', fetchMock as unknown as typeof fetch).fetchDeliveryUpdates(pending, new Date('2026-11-22T04:00:00Z'));
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://sms.aakashsms.com/sms/v4/api-report');
    expect((init.headers as Record<string, string>)['auth-token']).toBe('KEY');
    expect(JSON.parse(init.body as string)).toEqual({ start_date: '2026-11-22', end_date: ymd(new Date()) });
  });
  it('turns delivered rows into updates, ignores unknown ids, and leaves absent messages alone', () => {
    const report = { error: false, response_code: '201', data: [
      { id: 'A1', receiver: '9812345678', delivery_at: '2026-11-22 10:00:05' },
      { id: 'ZZ', receiver: '9800000000', delivery_at: '2026-11-22 10:00:06' },
      { id: 'A2', status: 'Failed', receiver: '9812345679' },
    ] };
    expect(matchAakashReport(report, pending)).toEqual([
      { providerMessageId: 'A1', status: 'delivered', at: '2026-11-22 10:00:05' },
      { providerMessageId: 'A2', status: 'failed', error: 'Aakash SMS report: failed' },
    ]);   // A3 is not in the report: no update, it stays "sent"
  });
  it('reads the rows wherever the documented shapes put them, and tolerates numeric ids', () => {
    const row = { id: 'A1', delivery_at: 'x' };
    expect(matchAakashReport({ data: [row] }, pending)).toHaveLength(1);
    expect(matchAakashReport({ responses: [{ data: [row] }] }, pending)).toHaveLength(1);
    expect(matchAakashReport([row], pending)).toHaveLength(1);
    expect(matchAakashReport({ data: [{ id: 'A1', status: 'delivered' }] }, [{ ...pending[0], providerMessageId: 'A1' }])).toHaveLength(1);
    expect(matchAakashReport({ data: [{ id: 7, delivery_at: 'x' }] }, [{ ...pending[0], providerMessageId: '7' }])).toHaveLength(1);
    expect(matchAakashReport({ nothing: true }, pending)).toEqual([]);
    expect(matchAakashReport(null, pending)).toEqual([]);
    expect(matchAakashReport({ data: [{ id: 'A1' }] }, pending)).toEqual([]);   // a row with no status and no time proves nothing
  });
  it('makes no request when nothing is pending, and an HTTP error is an unknown outcome', async () => {
    const fetchMock = vi.fn();
    expect(await new AakashSmsProvider('K', fetchMock as unknown as typeof fetch).fetchDeliveryUpdates([], new Date())).toEqual([]);
    expect(fetchMock).not.toHaveBeenCalled();
    await expect(new AakashSmsProvider('K', (async () => okResponse({}, 500)) as unknown as typeof fetch).fetchDeliveryUpdates(pending, new Date())).rejects.toBeInstanceOf(ProviderUnknownOutcomeError);
  });
  it('ymd gives the Kathmandu date (+05:45)', () => {
    expect(ymd(new Date('2026-11-22T17:00:00Z'))).toBe('2026-11-22');
    expect(ymd(new Date('2026-11-22T18:30:00Z'))).toBe('2026-11-23');
  });
});

describe('Aakash: inbound (unsigned GET push)', () => {
  it('reads keyword, from and text', () => {
    expect(parseAakashInbound(new URLSearchParams('keyword=CLINIC&from=9812345678&text=Hello+there'))).toEqual({ from: '9812345678', body: 'Hello there', keyword: 'CLINIC' });
  });
  it('needs a sender and a text', () => {
    expect(parseAakashInbound(new URLSearchParams('text=Hello'))).toBeNull();
    expect(parseAakashInbound(new URLSearchParams('from=9812345678'))).toBeNull();
    expect(parseAakashInbound(new URLSearchParams('from=+&text=+'))).toBeNull();
  });
});

describe('choosing a provider', () => {
  const record = async () => {};
  it('selects the adapter by channel_accounts.provider', () => {
    expect(resolveHubProvider('sms', 'test', { recordTest: record }).name).toBe('test');
    expect(resolveHubProvider('sms', 'aakash', { secret: 'K' }).name).toBe('aakash');
  });
  it('refuses an unknown gateway, an Aakash account with no key, a test provider with no recorder', () => {
    expect(() => resolveHubProvider('sms', 'bird', { secret: 'K' })).toThrow(/No provider registered/);
    expect(() => resolveHubProvider('whatsapp', 'aakash', { secret: 'K' })).toThrow(/No provider registered/);
    expect(() => resolveHubProvider('sms', 'aakash', {})).toThrow(/API key is not configured/);
    expect(() => resolveHubProvider('sms', 'test', {})).toThrow(/recorder/);
  });
  it('the old email resolver still works', () => {
    expect(resolveProvider('email', { provider: 'resend', from_address: 'a@b.c' }, { RESEND_API_KEY: 'k' }).channel).toBe('email');
    expect(() => resolveProvider('sms', { provider: 'aakash' }, {})).toThrow(/No provider registered/);
  });
});
