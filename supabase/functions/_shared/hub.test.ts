import { describe, it, expect, vi, beforeEach } from 'vitest';
import { handleInbound, runHubSend, INBOUND_RATE_LIMIT_PER_MINUTE, type HubDeps } from './hub';
import { hmacSha256Hex } from './channels';

// Everything is mocked: the database (rpc) and the network (fetch). No real gateway is ever called.
const ACCOUNT = { id: 'acc-1', org_id: 'org-1', branch_id: null, channel: 'sms', status: 'connected', secret_ref: 'AAKASH_AUTH_TOKEN' };
const ACCOUNT2 = { id: 'acc-2', org_id: 'org-2', branch_id: null, channel: 'sms', status: 'connected', secret_ref: 'AAKASH_CLINIC2' };

function makeDeps(over: { rpc?: (fn: string, args?: Record<string, unknown>) => unknown; env?: Record<string, string>; fetchImpl?: typeof fetch; now?: Date } = {}) {
  const calls: { fn: string; args?: Record<string, unknown> }[] = [];
  const recorded: { messageId?: string; to: string; body: string }[] = [];
  const deps: HubDeps = {
    rpc: (async (fn: string, args?: Record<string, unknown>) => {
      calls.push({ fn, args });
      const data = over.rpc ? over.rpc(fn, args) : undefined;
      return { data: data === undefined ? null : data, error: null };
    }) as HubDeps['rpc'],
    env: (n) => over.env?.[n],
    recordTest: async (row) => { recorded.push(row); },
    fetchImpl: over.fetchImpl,
    now: () => over.now ?? new Date('2026-11-22T10:00:30Z'),
  };
  return { deps, calls, recorded };
}
const rpcOk = (extra: Record<string, unknown> = {}) => (fn: string) => {
  if (fn === 'hub_find_account') return [ACCOUNT];
  if (fn === 'hub_list_accounts') return [ACCOUNT, ACCOUNT2];
  if (fn === 'hub_rate_check') return true;
  if (fn === 'act_message_receive') return { ok: true, action_id: 'a1', data: { conversation_id: 'c1' }, error: null };
  if (fn === 'hub_apply_delivery_status') return 'updated';
  return extra[fn];
};

async function signedTest(payload: unknown, secret = 'whsec') {
  const raw = JSON.stringify(payload);
  const sig = await hmacSha256Hex(secret, raw);
  return new Request('https://x.test/functions/v1/hub-inbound/test', { method: 'POST', body: raw, headers: { 'x-hub-signature': 'sha256=' + sig } });
}

describe('hub-inbound: the test provider (signed)', () => {
  const env = { HUB_TEST_WEBHOOK_SECRET: 'whsec' };

  it('rejects an unsigned, wrongly signed or tampered request with 401 and does nothing', async () => {
    const { deps, calls } = makeDeps({ env, rpc: rpcOk() });
    const payload = { type: 'inbound', from: '+9779801000001', to: '+9779700000001', text: 'hello' };
    const unsigned = new Request('https://x.test/functions/v1/hub-inbound/test', { method: 'POST', body: JSON.stringify(payload) });
    expect((await handleInbound(unsigned, deps)).status).toBe(401);
    expect((await handleInbound(await signedTest(payload, 'wrong-secret'), deps)).status).toBe(401);
    const good = await signedTest(payload);
    const tampered = new Request(good.url, { method: 'POST', body: JSON.stringify({ ...payload, text: 'something else' }), headers: { 'x-hub-signature': good.headers.get('x-hub-signature')! } });
    expect((await handleInbound(tampered, deps)).status).toBe(401);
    expect(calls).toHaveLength(0);
  });

  it('401s when the server has no secret configured, and 405s anything but POST', async () => {
    const { deps } = makeDeps({ env: {}, rpc: rpcOk() });
    expect((await handleInbound(await signedTest({ type: 'inbound', from: 'a', to: 'b', text: 'c' }), deps)).status).toBe(401);
    const { deps: d2 } = makeDeps({ env, rpc: rpcOk() });
    expect((await handleInbound(new Request('https://x.test/functions/v1/hub-inbound/test'), d2)).status).toBe(405);
  });

  it('a signed inbound message: finds the account, checks the rate, then calls message.receive as the patient of that org', async () => {
    const { deps, calls } = makeDeps({ env, rpc: rpcOk() });
    const res = await handleInbound(await signedTest({ type: 'inbound', from: '+9779801000001', to: '+9779700000001', text: 'Thanks', id: 'p-77' }), deps);
    expect(res.status).toBe(200);
    expect((await res.json()).ok).toBe(true);
    expect(calls.map((c) => c.fn)).toEqual(['hub_find_account', 'hub_rate_check', 'act_message_receive']);
    expect(calls[0].args).toEqual({ p_provider: 'test', p_recipient: '+9779700000001' });
    expect(calls[2].args).toEqual({ p_account: 'acc-1', p_from: '+9779801000001', p_body: 'Thanks', p_provider_message_id: 'p-77', p_received_at: null, p_ctx: { actor_kind: 'patient', org_id: 'org-1' } });
  });

  it('a signed delivery status goes to hub_apply_delivery_status (including read and failed)', async () => {
    for (const status of ['delivered', 'read', 'failed']) {
      const { deps, calls } = makeDeps({ env, rpc: rpcOk() });
      const res = await handleInbound(await signedTest({ type: 'status', id: 'test-m-1', status, to: '+9779700000001', error: status === 'failed' ? 'handset off' : undefined }), deps);
      expect(res.status).toBe(200);
      const apply = calls.find((c) => c.fn === 'hub_apply_delivery_status')!;
      expect(apply.args).toMatchObject({ p_account: 'acc-1', p_provider_message_id: 'test-m-1', p_status: status });
      expect(calls.some((c) => c.fn === 'act_message_receive')).toBe(false);
    }
  });

  it('404s an unknown account, 400s a missing recipient, ignores an unrecognised payload, 413s an oversized body', async () => {
    const { deps } = makeDeps({ env, rpc: (fn) => (fn === 'hub_find_account' ? [] : undefined) });
    expect((await handleInbound(await signedTest({ type: 'inbound', from: '+977980', to: '+977999', text: 'x' }), deps)).status).toBe(404);
    const { deps: d2 } = makeDeps({ env, rpc: rpcOk() });
    expect((await handleInbound(await signedTest({ type: 'inbound', from: '+977980', text: 'x' }), d2)).status).toBe(400);
    const ign = await handleInbound(await signedTest({ type: 'who-knows' }), d2);
    expect(ign.status).toBe(200);
    expect((await ign.json()).ignored).toBe(true);
    const huge = await signedTest({ type: 'inbound', from: 'a', to: 'b', text: 'x'.repeat(150_000) });
    expect((await handleInbound(huge, d2)).status).toBe(413);
  });

  it('beyond the rate limit the message is dropped (and counted in the database), not recorded, and the gateway gets a 200', async () => {
    const { deps, calls } = makeDeps({ env, rpc: (fn) => (fn === 'hub_find_account' ? [ACCOUNT] : fn === 'hub_rate_check' ? false : undefined) });
    const res = await handleInbound(await signedTest({ type: 'inbound', from: '+977980', to: '+977970', text: 'flood' }), deps);
    expect(res.status).toBe(200);
    expect((await res.json()).dropped).toBe(true);
    expect(calls.some((c) => c.fn === 'act_message_receive')).toBe(false);
    expect(calls.find((c) => c.fn === 'hub_rate_check')!.args).toEqual({ p_account: 'acc-1', p_limit: INBOUND_RATE_LIMIT_PER_MINUTE });
    expect(INBOUND_RATE_LIMIT_PER_MINUTE).toBe(60);
  });
});

describe('hub-inbound: Aakash (unsigned: a secret path token)', () => {
  const env = { AAKASH_AUTH_TOKEN_INBOUND_TOKEN: 'tok-account-one-0123456789', AAKASH_CLINIC2_INBOUND_TOKEN: 'tok-account-two-9876543210' };
  const get = (path: string) => new Request(`https://x.test/functions/v1/hub-inbound/aakash${path}`);

  it('rejects a missing token, a wrong token and a token of nobody with the SAME 404 answer, and records nothing', async () => {
    const { deps, calls } = makeDeps({ env, rpc: rpcOk() });
    const bodies = [];
    for (const path of ['', '/', '/wrong-token', '/tok-account-one-0123456789x', '/tok-account-one-012345678']) {
      const r = await handleInbound(get(`${path}?from=9812345678&text=hi`), deps);
      expect(r.status).toBe(404);
      bodies.push(await r.text());
    }
    expect(new Set(bodies).size).toBe(1);
    expect(calls.some((c) => c.fn === 'act_message_receive')).toBe(false);
  });

  it("the right token records the message for ITS account and org; another account's token reaches that account", async () => {
    const { deps, calls } = makeDeps({ env, rpc: rpcOk() });
    expect((await handleInbound(get('/tok-account-one-0123456789?keyword=C&from=9812345678&text=Hello+there'), deps)).status).toBe(200);
    let rec = calls.find((c) => c.fn === 'act_message_receive')!;
    expect(rec.args).toMatchObject({ p_account: 'acc-1', p_from: '9812345678', p_body: 'Hello there', p_ctx: { actor_kind: 'patient', org_id: 'org-1' } });
    calls.length = 0;
    expect((await handleInbound(get('/tok-account-two-9876543210?from=9812345678&text=Hi'), deps)).status).toBe(200);
    rec = calls.find((c) => c.fn === 'act_message_receive')!;
    expect(rec.args).toMatchObject({ p_account: 'acc-2', p_ctx: { actor_kind: 'patient', org_id: 'org-2' } });
  });

  it('an account with no secret_ref, or whose token env is not set, can never match', async () => {
    const { deps } = makeDeps({ env: {}, rpc: (fn) => (fn === 'hub_list_accounts' ? [{ ...ACCOUNT, secret_ref: null }, ACCOUNT] : undefined) });
    expect((await handleInbound(get('/anything?from=1&text=2'), deps)).status).toBe(404);
    expect((await handleInbound(get('/?from=1&text=2'), deps)).status).toBe(404);
  });

  it('400s when from or text is missing, 405s a POST, and never calls message.receive in those cases', async () => {
    const { deps, calls } = makeDeps({ env, rpc: rpcOk() });
    expect((await handleInbound(get('/tok-account-one-0123456789?text=Hello'), deps)).status).toBe(400);
    expect((await handleInbound(get('/tok-account-one-0123456789?from=9812345678'), deps)).status).toBe(400);
    expect((await handleInbound(new Request('https://x.test/functions/v1/hub-inbound/aakash/tok-account-one-0123456789?from=1&text=2', { method: 'POST' }), deps)).status).toBe(405);
    expect(calls.some((c) => c.fn === 'act_message_receive')).toBe(false);
  });

  it('a retry within the same minute carries the same provider id (so the database drops it); another minute does not', async () => {
    const ids: string[] = [];
    for (const now of ['2026-11-22T10:00:10Z', '2026-11-22T10:00:50Z', '2026-11-22T10:01:10Z']) {
      const { deps, calls } = makeDeps({ env, rpc: rpcOk(), now: new Date(now) });
      await handleInbound(get('/tok-account-one-0123456789?from=9812345678&text=Hello'), deps);
      ids.push(calls.find((c) => c.fn === 'act_message_receive')!.args!.p_provider_message_id as string);
    }
    expect(ids[0]).toBe(ids[1]);
    expect(ids[1]).not.toBe(ids[2]);
    expect(ids[0]).toMatch(/^aakash:[0-9a-f]{32}$/);
    expect(ids[0]).not.toContain('tok-account-one');   // the token is not leaked into stored ids
  });

  it('drops (and counts) beyond the rate limit', async () => {
    const { deps, calls } = makeDeps({ env, rpc: (fn) => (fn === 'hub_list_accounts' ? [ACCOUNT] : fn === 'hub_rate_check' ? false : undefined) });
    const r = await handleInbound(get('/tok-account-one-0123456789?from=9812345678&text=Hello'), deps);
    expect((await r.json()).dropped).toBe(true);
    expect(calls.some((c) => c.fn === 'act_message_receive')).toBe(false);
  });

  it('never puts the token in a response', async () => {
    const { deps } = makeDeps({ env, rpc: rpcOk() });
    for (const path of ['/tok-account-one-0123456789?from=9812345678&text=Hello', '/wrong?from=1&text=2']) {
      expect(await (await handleInbound(get(path), deps)).text()).not.toContain('tok-account');
    }
  });

  it('an unknown provider is 404', async () => {
    const { deps } = makeDeps({ env, rpc: rpcOk() });
    expect((await handleInbound(new Request('https://x.test/functions/v1/hub-inbound/bird'), deps)).status).toBe(404);
    expect((await handleInbound(new Request('https://x.test/functions/v1/hub-inbound'), deps)).status).toBe(404);
  });
});

describe('hub-send: the sender', () => {
  const claimed = (over: Record<string, unknown> = {}) => ({ id: 'm1', org_id: 'org-1', conversation_id: 'c1', to_address: '+9779812345678', body: 'Your visit is on Sunday', channel: 'sms',
    provider: 'aakash', sender: 'CLINIC', secret_ref: 'AAKASH_AUTH_TOKEN', account_id: 'acc-1', credit_cost_npr: 1.5, ...over });
  const result = (calls: { fn: string; args?: Record<string, unknown> }[]) => calls.filter((c) => c.fn === 'hub_record_send_result').map((c) => c.args);
  const ok = (id = 'A1', credit = 1) => (async () => new Response(JSON.stringify({ responses: [{ error: false, data: { valid: [{ id, credit, status: 'queued' }], invalid: [] } }] }), { status: 200 })) as unknown as typeof fetch;

  it('sends a claimed Aakash message and records the provider id and credits', async () => {
    const { deps, calls } = makeDeps({ env: { AAKASH_AUTH_TOKEN: 'KEY' }, fetchImpl: ok('A1', 2), rpc: (fn) => (fn === 'hub_claim_messages' ? [claimed()] : undefined) });
    const out = await runHubSend(deps, 'send');
    expect(out).toMatchObject({ claimed: 1, sent: 1, failed: 0 });
    expect(result(calls)).toEqual([{ p_message: 'm1', p_ok: true, p_provider_message_id: 'A1', p_credits: 2, p_error: null }]);
  });

  it('sends through the test provider (writes the local outbox) without a key', async () => {
    const { deps, calls, recorded } = makeDeps({ rpc: (fn) => (fn === 'hub_claim_messages' ? [claimed({ provider: 'test', secret_ref: null })] : undefined) });
    await runHubSend(deps, 'send');
    expect(recorded).toEqual([{ messageId: 'm1', to: '+9779812345678', body: 'Your visit is on Sunday' }]);
    expect(result(calls)[0]).toMatchObject({ p_ok: true, p_provider_message_id: 'test-m1', p_credits: 1 });
  });

  it('an explicit refusal is recorded as failed with the provider text (nothing was sent)', async () => {
    const fetchImpl = (async () => new Response(JSON.stringify({ responses: [{ error: true, message: 'Not enough balance.', data: [] }] }), { status: 200 })) as unknown as typeof fetch;
    const { deps, calls } = makeDeps({ env: { AAKASH_AUTH_TOKEN: 'KEY' }, fetchImpl, rpc: (fn) => (fn === 'hub_claim_messages' ? [claimed()] : undefined) });
    const out = await runHubSend(deps, 'send');
    expect(out.failed).toBe(1);
    expect(result(calls)[0]).toMatchObject({ p_ok: false });
    expect(String(result(calls)[0]!.p_error)).toContain('Not enough balance');
    expect(String(result(calls)[0]!.p_error)).not.toContain('outcome unknown');
  });

  it('a network error is "outcome unknown", never retried by the sender', async () => {
    const fetchImpl = (async () => { throw new Error('socket hang up'); }) as unknown as typeof fetch;
    const { deps, calls } = makeDeps({ env: { AAKASH_AUTH_TOKEN: 'KEY' }, fetchImpl, rpc: (fn) => (fn === 'hub_claim_messages' ? [claimed()] : undefined) });
    await runHubSend(deps, 'send');
    expect(String(result(calls)[0]!.p_error)).toMatch(/^outcome unknown:/);
    expect(calls.filter((c) => c.fn === 'hub_record_send_result')).toHaveLength(1);
  });

  it('a non-Nepal number is refused by the adapter, with no request made', async () => {
    const fetchImpl = vi.fn();
    const { deps, calls } = makeDeps({ env: { AAKASH_AUTH_TOKEN: 'KEY' }, fetchImpl: fetchImpl as unknown as typeof fetch, rpc: (fn) => (fn === 'hub_claim_messages' ? [claimed({ to_address: '+15551234567' })] : undefined) });
    await runHubSend(deps, 'send');
    expect(fetchImpl).not.toHaveBeenCalled();
    expect(String(result(calls)[0]!.p_error)).toContain('Nepal');
  });

  it('a missing key or an unknown provider fails the message with a clear text (certainly not sent)', async () => {
    const { deps, calls } = makeDeps({ env: {}, rpc: (fn) => (fn === 'hub_claim_messages' ? [claimed(), claimed({ id: 'm2', provider: 'bird' })] : undefined) });
    const out = await runHubSend(deps, 'send');
    expect(out).toMatchObject({ claimed: 2, failed: 2, sent: 0 });
    expect(String(result(calls)[0]!.p_error)).toMatch(/API key is not configured/);
    expect(String(result(calls)[1]!.p_error)).toMatch(/No provider registered/);
    expect(result(calls).every((r) => !String(r!.p_error).includes('KEY'))).toBe(true);
  });

  it('one message failing does not stop the next', async () => {
    let n = 0;
    const fetchImpl = (async () => (++n === 1 ? new Response('{}', { status: 503 }) : new Response(JSON.stringify({ responses: [{ error: false, data: { valid: [{ id: 'B2', credit: 1 }], invalid: [] } }] }), { status: 200 }))) as unknown as typeof fetch;
    const { deps } = makeDeps({ env: { AAKASH_AUTH_TOKEN: 'KEY' }, fetchImpl, rpc: (fn) => (fn === 'hub_claim_messages' ? [claimed(), claimed({ id: 'm2' })] : undefined) });
    expect(await runHubSend(deps, 'send')).toMatchObject({ claimed: 2, sent: 1, failed: 1 });
  });

  it('an error claiming is counted and sends nothing', async () => {
    const deps: HubDeps = { rpc: (async () => ({ data: null, error: { message: 'boom' } })) as HubDeps['rpc'], env: () => undefined, recordTest: async () => {} };
    expect(await runHubSend(deps, 'send')).toMatchObject({ claimed: 0, errors: 1 });
  });
});

describe('hub-send: the delivery poller (pull-only providers)', () => {
  const account = { id: 'acc-1', org_id: 'org-1', provider: 'aakash', secret_ref: 'AAKASH_AUTH_TOKEN', last_polled_at: null };
  const pendingRows = [
    { message_id: 'm1', provider_message_id: 'A1', to_address: '+9779812345678', sent_at: '2026-11-22T04:00:00Z' },
    { message_id: 'm2', provider_message_id: 'A2', to_address: '+9779812345679', sent_at: '2026-11-22T04:05:00Z' },
  ];
  const report = (rows: unknown[]) => vi.fn(async () => new Response(JSON.stringify({ error: false, data: rows }), { status: 200 }));

  it('pulls the report, applies "delivered" for messages that appear, leaves the others as "sent", and marks the account polled', async () => {
    const fetchImpl = report([{ id: 'A1', delivery_at: '2026-11-22 10:00:05' }]);
    const { deps, calls } = makeDeps({ env: { AAKASH_AUTH_TOKEN: 'KEY' }, fetchImpl: fetchImpl as unknown as typeof fetch,
      rpc: (fn) => (fn === 'hub_poll_accounts' ? [account] : fn === 'hub_pending_delivery' ? pendingRows : fn === 'hub_apply_delivery_status' ? 'updated' : undefined) });
    const out = await runHubSend(deps, 'poll');
    expect(out).toMatchObject({ polled: 1, updated: 1, errors: 0 });
    const applies = calls.filter((c) => c.fn === 'hub_apply_delivery_status');
    expect(applies).toHaveLength(1);
    expect(applies[0].args).toMatchObject({ p_account: 'acc-1', p_provider_message_id: 'A1', p_status: 'delivered' });
    expect(calls.some((c) => c.fn === 'hub_mark_polled' && c.args!.p_account === 'acc-1')).toBe(true);
    expect(JSON.parse((fetchImpl.mock.calls[0] as unknown as [string, RequestInit])[1].body as string).start_date).toBe('2026-11-22');
  });

  it('does not call the provider when nothing is waiting, and skips providers with no pull report (test)', async () => {
    const fetchImpl = report([]);
    const { deps, calls } = makeDeps({ env: { AAKASH_AUTH_TOKEN: 'KEY' }, fetchImpl: fetchImpl as unknown as typeof fetch,
      rpc: (fn) => (fn === 'hub_poll_accounts' ? [account, { ...account, id: 'acc-t', provider: 'test', secret_ref: null }] : fn === 'hub_pending_delivery' ? [] : undefined) });
    await runHubSend(deps, 'poll');
    expect(fetchImpl).not.toHaveBeenCalled();
    expect(calls.filter((c) => c.fn === 'hub_pending_delivery')).toHaveLength(1);   // only the Aakash account was asked
  });

  it('an error for one account (no key, HTTP 500) is counted and the next account is still polled', async () => {
    const fetchImpl = vi.fn(async () => new Response('{}', { status: 500 }));
    const { deps, calls } = makeDeps({ env: { AAKASH_AUTH_TOKEN: 'KEY', AAKASH_CLINIC2: 'K2' }, fetchImpl: fetchImpl as unknown as typeof fetch,
      rpc: (fn) => (fn === 'hub_poll_accounts' ? [{ ...account, id: 'acc-nokey', secret_ref: 'MISSING' }, account, { ...account, id: 'acc-2', secret_ref: 'AAKASH_CLINIC2' }]
        : fn === 'hub_pending_delivery' ? pendingRows : undefined) });
    const out = await runHubSend(deps, 'poll');
    expect(out.errors).toBe(3);   // no key, then two HTTP 500s: none stops the loop
    expect(calls.filter((c) => c.fn === 'hub_pending_delivery')).toHaveLength(2);
    expect(calls.some((c) => c.fn === 'hub_mark_polled')).toBe(false);   // a failed poll is not marked as done
  });
});
