import { describe, it, expect, vi } from 'vitest';
import { classifyReply, maskReply, parseClassification, costNpr, MODEL_CONFIG } from './model';

const KEY = 'sk-test-SECRET-KEY-123';
const okBody = (content: unknown, usage: unknown = { prompt_tokens: 100, completion_tokens: 20 }) => ({ choices: [{ message: { content: typeof content === 'string' ? content : JSON.stringify(content) } }], usage });
const res = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const deps = (fetchImpl: typeof fetch, env: Record<string, string> = { OPENAI_API_KEY: KEY }) => ({ env: (n: string) => env[n], fetchImpl });
const input = { text: 'yes see you tomorrow', treatment: 'Root canal', date: '2026-11-24' };

describe('maskReply', () => {
  it('masks emails and digit runs, trims to 500 characters', () => {
    expect(maskReply('mail me a@b.com or call +977 9801234567 now')).toBe('mail me [email] or call [number] now');
    expect(maskReply('ok 12345')).toBe('ok 12345');   // short numbers (a time like 5) stay
    expect(maskReply('x'.repeat(900)).length).toBe(500);
  });
});

describe('parseClassification', () => {
  it('accepts exactly the three keys with valid values', () => {
    expect(parseClassification({ intent: 'confirm', confidence: 0.95, also_question: false })).toEqual({ intent: 'confirm', confidence: 0.95, also_question: false });
  });
  it.each([
    [{ intent: 'confirm', confidence: 0.95 }], [{ intent: 'confirm', confidence: 0.95, also_question: false, extra: 1 }], [{ intent: 'maybe', confidence: 0.5, also_question: false }],
    [{ intent: 'confirm', confidence: 1.5, also_question: false }], [{ intent: 'confirm', confidence: '0.9', also_question: false }], [{ intent: 'confirm', confidence: 0.9, also_question: 'no' }], [null], [[]], ['x'],
  ])('rejects %j', (bad) => { expect(parseClassification(bad)).toBeNull(); });
});

describe('classifyReply', () => {
  it('returns the classification, the usage and an NPR cost', async () => {
    const f = vi.fn(async () => res(200, okBody({ intent: 'confirm', confidence: 0.97, also_question: false })));
    const out = await classifyReply(deps(f as never), input);
    expect(out).toEqual({ ok: true, result: { intent: 'confirm', confidence: 0.97, also_question: false }, call: { units: { in: 100, out: 20 }, costNpr: costNpr(100, 20) } });
    expect((out as { call: { costNpr: number } }).call.costNpr).toBeGreaterThan(0);
  });

  it('sends only the masked reply, the treatment name and the date: no name, phone or id', async () => {
    const f = vi.fn(async (_u: unknown, init?: RequestInit) => { void init; return res(200, okBody({ intent: 'other', confidence: 0.2, also_question: false })); });
    await classifyReply(deps(f as never), { text: 'call me on 9801234567', treatment: 'Cleaning', date: '2026-11-24' });
    const init = f.mock.calls[0][1] as RequestInit;
    const sent = JSON.parse(String(init.body));
    const user = JSON.parse(sent.messages[1].content);
    expect(Object.keys(user).sort()).toEqual(['date', 'reply', 'treatment']);
    expect(user.reply).toBe('call me on [number]');
    expect(String(init.body)).not.toContain('9801234567');
  });

  it('uses the key only in the Authorization header', async () => {
    const f = vi.fn(async (_u: unknown, init?: RequestInit) => { void init; return res(200, okBody({ intent: 'other', confidence: 0.1, also_question: false })); });
    await classifyReply(deps(f as never), input);
    const init = f.mock.calls[0][1] as RequestInit;
    expect((init.headers as Record<string, string>).Authorization).toBe(`Bearer ${KEY}`);
    expect(String(init.body)).not.toContain(KEY);
  });

  it('has no key: NO_KEY, and nothing is called', async () => {
    const f = vi.fn();
    expect(await classifyReply(deps(f as never, {}), input)).toEqual({ ok: false, code: 'NO_KEY' });
    expect(f).not.toHaveBeenCalled();
  });

  it('retries once on a 5xx or a network error, never on a 4xx', async () => {
    let n = 0;
    const flaky = vi.fn(async () => (++n === 1 ? res(503, {}) : res(200, okBody({ intent: 'confirm', confidence: 0.99, also_question: false }))));
    expect((await classifyReply(deps(flaky as never), input)).ok).toBe(true);
    expect(flaky).toHaveBeenCalledTimes(2);
    const four = vi.fn(async () => res(401, { error: { message: `bad key ${KEY}` } }));
    const out = await classifyReply(deps(four as never), input);
    expect(out).toEqual({ ok: false, code: 'HTTP_401' });
    expect(four).toHaveBeenCalledTimes(1);
    const down = vi.fn(async () => { throw new Error(`connect failed with ${KEY}`); });
    const o2 = await classifyReply(deps(down as never), input);
    expect(o2).toEqual({ ok: false, code: 'NETWORK' });
    expect(down).toHaveBeenCalledTimes(MODEL_CONFIG.retries + 1);
  });

  it('times out with a TIMEOUT code', async () => {
    vi.useFakeTimers();
    const hang = vi.fn((_u: unknown, init?: RequestInit) => new Promise((_r, rej) => { init?.signal?.addEventListener('abort', () => { const e = new Error('aborted'); e.name = 'AbortError'; rej(e); }); }));
    const p = classifyReply(deps(hang as never), input);
    await vi.advanceTimersByTimeAsync(MODEL_CONFIG.timeoutMs * (MODEL_CONFIG.retries + 1) + 10);
    expect(await p).toEqual({ ok: false, code: 'TIMEOUT' });
    vi.useRealTimers();
  });

  it('a malformed answer is BAD_OUTPUT (the usage is still reported so the spend is recorded)', async () => {
    const f = vi.fn(async () => res(200, okBody('this is not json')));
    const out = await classifyReply(deps(f as never), input);
    expect(out).toMatchObject({ ok: false, code: 'BAD_OUTPUT', call: { units: { in: 100, out: 20 } } });
    const f2 = vi.fn(async () => res(200, okBody({ intent: 'confirm', confidence: 0.99, also_question: false, extra: 'x' })));
    expect((await classifyReply(deps(f2 as never), input)).ok).toBe(false);
  });

  it('a parsed answer without usage is ok, with a USAGE_MISSING call record (null tokens, cost 0)', async () => {
    const f = vi.fn(async () => res(200, { choices: [{ message: { content: JSON.stringify({ intent: 'other', confidence: 0.4, also_question: false }) } }] }));
    expect(await classifyReply(deps(f as never), input)).toEqual({ ok: true, result: { intent: 'other', confidence: 0.4, also_question: false }, call: { units: { in: null, out: null, flag: 'USAGE_MISSING' }, costNpr: 0 } });
  });
  it('an HTTP error has no call record (nothing was answered)', async () => {
    const f = vi.fn(async () => res(429, {}));
    expect(await classifyReply(deps(f as never), input)).toEqual({ ok: false, code: 'HTTP_429' });
  });
  it('an error never carries the key or the reply', async () => {
    const f = vi.fn(async () => { throw new Error(`boom ${KEY} yes see you tomorrow`); });
    const out = await classifyReply(deps(f as never), input);
    expect(JSON.stringify(out)).not.toContain(KEY);
    expect(JSON.stringify(out)).not.toContain('see you tomorrow');
  });
});
