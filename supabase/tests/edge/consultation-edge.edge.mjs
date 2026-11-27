// Edge-function tests for CMD-54/55 against the FAKE OpenAI. LOCAL ONLY (refuses any non-127.0.0.1 URL).
// Needs: local Supabase with migration 020 applied, `supabase functions serve --env-file <env>` running, fake-openai.mjs running.
// Env: API_URL, ANON_KEY, SERVICE_ROLE_KEY (from `supabase status -o env`), optional FN_FLAG_ON=1 for the consent-required run,
//      PGPASSWORD (default postgres). Run: npm run test:edge
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const API = process.env.API_URL || 'http://127.0.0.1:55321';
const ANON = process.env.ANON_KEY;
const SERVICE = process.env.SERVICE_ROLE_KEY;
const FLAG_ON = process.env.FN_FLAG_ON === '1';
const CRON = process.env.CRON_BEARER_TOKEN || 'test-cron-token';
if (!/^http:\/\/127\.0\.0\.1:/.test(API)) throw new Error('LOCAL ONLY: API_URL must be http://127.0.0.1:<port>');
if (!ANON || !SERVICE) throw new Error('ANON_KEY and SERVICE_ROLE_KEY are required');

const RUN = randomUUID().slice(0, 8);
// Own tenants, created in before() and removed in after(): the suite needs nothing from seed.sql or earlier test runs.
const ORG_A = randomUUID(); const BR_A = randomUUID(); const ORG_B = randomUUID(); const BR_B = randomUUID(); const TREATMENT_A = randomUUID();

const psql = (sql) => execFileSync('psql', ['-h', '127.0.0.1', '-p', '55322', '-U', 'postgres', '-d', 'postgres', '-At', '-v', 'ON_ERROR_STOP=1', '-c', sql],
  { env: { ...process.env, PGPASSWORD: process.env.PGPASSWORD || 'postgres' }, encoding: 'utf8' }).trim();

const admin = (path, init = {}) => fetch(`${API}${path}`, { ...init, headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, ...(init.headers || {}) } });
const fn = (name, token, body) => fetch(`${API}/functions/v1/${name}`, {
  method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body ?? {}),
});
const rest = (path, token, init = {}) => fetch(`${API}/rest/v1/${path}`, { ...init, headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(init.headers || {}) } });
const rpc = (name, token, args) => fetch(`${API}/rest/v1/rpc/${name}`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });

const made = { users: [], consultations: [], bookings: [], objects: [] };
const tok = {};

async function makeUser(label, role, org, branch) {
  const email = `edge-${RUN}-${label}@example.test`;
  const password = `Pw-${RUN}-aA1!`;
  const r = await admin('/auth/v1/admin/users', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password, email_confirm: true }) });
  assert.equal(r.status, 200, `create user ${label}: ${await r.clone().text()}`);
  const id = (await r.json()).id;
  made.users.push(id);
  psql(`INSERT INTO public.users (id, email, full_name, org_id, branch_id, role, is_active) VALUES ('${id}', '${email}', 'Edge ${label}', '${org}', '${branch}', '${role}', true)`);
  const t = await fetch(`${API}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password }) });
  assert.equal(t.status, 200, `sign in ${label}`);
  tok[label] = (await t.json()).access_token;
  return id;
}

function makeBooking(org, branch) {
  const id = randomUUID();
  psql(`INSERT INTO public.bookings (id, booking_number, branch_id, treatment_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount)
        VALUES ('${id}', 'EDGE-${RUN}-${id.slice(0, 6)}', '${branch}', '${TREATMENT_A}', 'Edge Patient', current_date, '10:00', '10:30', now(), now() + interval '30 minutes', 1000, 1000)`);
  made.bookings.push(id);
  return id;
}

function makeConsultation({ org, branch, booking, audioPaths = [], signedDaysAgo = null, draft = false }) {
  const id = randomUUID();
  const paths = audioPaths.length ? `ARRAY[${audioPaths.map((p) => `'${p}'`).join(',')}]::text[]` : `'{}'::text[]`;
  psql(`INSERT INTO public.consultations (id, org_id, branch_id, booking_id, patient_name, audio_paths${signedDaysAgo !== null ? ', signed_at, status' : ''})
        VALUES ('${id}', '${org}', '${branch}', '${booking}', 'Edge Patient', ${paths}${signedDaysAgo !== null ? `, now() - interval '${signedDaysAgo} days', 'completed'` : ''})`);
  made.consultations.push(id);
  return id;
}

async function upload(path, bytes = 'RIFFfake-audio') {
  const r = await admin(`/storage/v1/object/consultation-audio/${path}`, { method: 'POST', headers: { 'Content-Type': 'audio/webm' }, body: bytes });
  assert.ok(r.status === 200, `upload ${path}: ${r.status} ${await r.text()}`);
  made.objects.push(path);
}
const exists = async (path) => (await admin(`/storage/v1/object/info/consultation-audio/${path}`)).status === 200;
const row = (id) => JSON.parse(psql(`SELECT row_to_json(c) FROM public.consultations c WHERE id = '${id}'`));

const ctx = {};
before(async () => {
  assert.equal(psql(`SELECT to_regproc('public.consultation_sign') IS NOT NULL`), 't', 'migration 020 is not applied to the local DB');
  for (const [org, br, tag] of [[ORG_A, BR_A, 'a'], [ORG_B, BR_B, 'b']]) {
    psql(`INSERT INTO public.organizations (id, name, code, slug, ai_consultation_enabled) VALUES ('${org}', 'Edge ${tag} ${RUN}', 'E${tag}${RUN}', 'edge-${tag}-${RUN}', true)`);
    psql(`INSERT INTO public.branches (id, org_id, name) VALUES ('${br}', '${org}', 'Edge branch ${tag}')`);
  }
  psql(`INSERT INTO public.treatments (id, org_id, name, duration_minutes, price_npr) VALUES ('${TREATMENT_A}', '${ORG_A}', 'Edge treatment', 30, 0)`);
  await makeUser('staffA', 'staff', ORG_A, BR_A);
  await makeUser('mgrA', 'manager', ORG_A, BR_A);
  await makeUser('adminB', 'admin', ORG_B, BR_B);
  ctx.bookingA = makeBooking(ORG_A, BR_A);
  ctx.audio = `${ORG_A}/${ctx.bookingA}/${RUN}-main.webm`;
  await upload(ctx.audio);
  ctx.consA = makeConsultation({ org: ORG_A, branch: BR_A, booking: ctx.bookingA, audioPaths: [ctx.audio] });
});

after(async () => {
  try {
    for (const p of made.objects) await admin(`/storage/v1/object/consultation-audio/${p}`, { method: 'DELETE' });
    if (made.consultations.length) {
      psql(`ALTER TABLE public.consultations DISABLE TRIGGER USER`);
      try { psql(`DELETE FROM public.consultations WHERE id IN (${made.consultations.map((c) => `'${c}'`).join(',')})`); } finally { psql(`ALTER TABLE public.consultations ENABLE TRIGGER USER`); }
    }
    if (made.bookings.length) psql(`DELETE FROM public.bookings WHERE id IN (${made.bookings.map((c) => `'${c}'`).join(',')})`);
    for (const u of made.users) {
      psql(`ALTER TABLE public.action_log DISABLE TRIGGER USER`);
      try { psql(`DELETE FROM public.action_log WHERE actor_user_id = '${u}'`); } finally { psql(`ALTER TABLE public.action_log ENABLE TRIGGER USER`); }
      psql(`DELETE FROM public.users WHERE id = '${u}'`);
      await admin(`/auth/v1/admin/users/${u}`, { method: 'DELETE' });
    }
  } finally {
    // org creation seeds agent_settings and playbooks (migration 018) and nothing cascades from org to branch: delete in dependency order
    // (replica role skips the append-only triggers on those tables; this DB is local and the ids are ours)
    for (const org of [ORG_A, ORG_B]) {
      psql(`SET session_replication_role = replica; DELETE FROM public.agent_settings WHERE org_id = '${org}'; DELETE FROM public.playbooks WHERE org_id = '${org}'; DELETE FROM public.action_log WHERE org_id = '${org}'; DELETE FROM public.treatments WHERE org_id = '${org}'; DELETE FROM public.branches WHERE org_id = '${org}'; DELETE FROM public.organizations WHERE id = '${org}'`);
    }
  }
});

test('staff gets FORBIDDEN_ROLE on all three AI functions', async () => {
  for (const [name, body] of [
    ['consultation-transcribe', { audioPath: ctx.audio, consultationId: ctx.consA }],
    ['consultation-summarize', { mode: 'note', transcript: 'x', consultationId: ctx.consA }],
    ['consultation-analyze-image', { kind: 'xray', imagePaths: ['a/b/c.png'] }],
  ]) {
    const r = await fn(name, tok.staffA, body);
    assert.equal(r.status, 403, name);
    assert.equal((await r.json()).error, 'FORBIDDEN_ROLE', name);
  }
});

test('consent gate (flag on): CONSENT_REQUIRED, then OK after consent', { skip: !FLAG_ON && 'run with FN_FLAG_ON=1 and the functions served with CONSULT_REQUIRE_CONSENT=true' }, async () => {
  const bk = makeBooking(ORG_A, BR_A);
  const path = `${ORG_A}/${bk}/${RUN}-consent.webm`;
  await upload(path);
  const c = makeConsultation({ org: ORG_A, branch: BR_A, booking: bk });
  const r0 = await fn('consultation-transcribe', tok.mgrA, { audioPath: ctx.audio, consultationId: c }); // recording of ANOTHER booking
  assert.equal(r0.status, 403); assert.equal((await r0.json()).error, 'CONSENT_REQUIRED');
  const r1 = await fn('consultation-transcribe', tok.mgrA, { audioPath: path, consultationId: c });
  assert.equal(r1.status, 403); assert.equal((await r1.json()).error, 'CONSENT_REQUIRED');
  const rc = await rpc('consultation_record_consent', tok.mgrA, { p_consultation: c, p_answer: 'agreed', p_device: 'computer', p_script: 'dental-en-ne-v1' });
  assert.equal(rc.status, 200, await rc.clone().text());
  const r2 = await fn('consultation-transcribe', tok.mgrA, { audioPath: path, consultationId: c });
  assert.equal(r2.status, 200, await r2.clone().text());
  assert.equal((await r2.json()).segments_stored, 3);
});

test('transcribe stores 3 segments', { skip: FLAG_ON && 'flag-on run covers the consent case only' }, async () => {
  const r = await fn('consultation-transcribe', tok.mgrA, { audioPath: ctx.audio, consultationId: ctx.consA });
  assert.equal(r.status, 200, await r.clone().text());
  const b = await r.json();
  assert.equal(b.segments_stored, 3);
  assert.match(b.text, /root canal/);
  const segs = row(ctx.consA).transcript_segments;
  assert.equal(segs.length, 3);
  assert.equal(segs[1].start, 3.2);
  assert.equal(segs[0].audio_path, ctx.audio);
});

test('summarize returns provenance; only real quotes survive', { skip: FLAG_ON && 'flag-on run covers the consent case only' }, async () => {
  const r = await fn('consultation-summarize', tok.mgrA, { mode: 'note', transcript: 'Where does it hurt? Lower left when I drink cold water. We will start the root canal today.', consultationId: ctx.consA });
  assert.equal(r.status, 200, await r.clone().text());
  const b = await r.json();
  assert.equal(b.provenance.provider, 'openai');
  assert.deepEqual(b.provenance.inputs, ['recording']);
  assert.equal(b.note.plan, '- RCT 36');
  const cc = b.sources.chief_complaint;
  assert.equal(cc.length, 1, JSON.stringify(cc));
  assert.equal(cc[0].quote, 'when I drink cold water');
  assert.equal(cc[0].start, 3.2);
  assert.equal(b.sources.plan[0].start, 7.9);
  assert.ok(!b.sources.findings?.length, 'x-ray source dropped when no x-ray was sent');
  const r2 = row(ctx.consA);
  assert.equal(r2.ai_provider, 'openai');
  assert.deepEqual(r2.ai_inputs, ['recording']);
  assert.equal(r2.ai_draft.plan, '- RCT 36');
  assert.equal(JSON.stringify(r2.note_sources).includes('swelling for a week'), false, 'invented quote never stored');
});

test('an org B user summarizing org A consultation stores nothing', { skip: FLAG_ON && 'flag-on run covers the consent case only' }, async () => {
  const c = makeConsultation({ org: ORG_A, branch: BR_A, booking: makeBooking(ORG_A, BR_A) });
  const r = await fn('consultation-summarize', tok.adminB, { mode: 'note', transcript: 'when I drink cold water', consultationId: c });
  assert.equal(r.status, 200, await r.clone().text()); // the note is still produced for their own transcript text...
  const b = await r.json();
  assert.equal(b.provenance, null);
  const after = row(c);
  assert.equal(after.ai_drafted_at, null);
  assert.equal(after.ai_draft, null);
  assert.equal(after.note_sources, null);
});

test('edited_sections after PATCH + sign = {plan}', { skip: FLAG_ON && 'flag-on run covers the consent case only' }, async () => {
  const before = row(ctx.consA);
  assert.ok(before.ai_drafted_at, 'needs the summarize test first');
  const md = '## Chief complaint\nPain lower left with cold drinks\n\n## Findings\nCaries 36\n\n## Plan\n- RCT 36\n- Crown 36';
  const patch = await rest(`consultations?id=eq.${ctx.consA}`, tok.mgrA, { method: 'PATCH', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ final_summary: md }) });
  assert.equal(patch.status, 200, await patch.clone().text());
  const bad = await rpc('consultation_sign', tok.mgrA, { p_consultation: ctx.consA, p_expected_drafted_at: '2000-01-01T00:00:00Z' });
  assert.equal((await bad.json()).error?.code, 'AI_DRAFT_CHANGED');
  const sign = await rpc('consultation_sign', tok.mgrA, { p_consultation: ctx.consA, p_expected_drafted_at: before.ai_drafted_at });
  const sb = await sign.json();
  assert.equal(sb.ok, true, JSON.stringify(sb));
  assert.deepEqual(row(ctx.consA).edited_sections, ['plan']);
  assert.ok(row(ctx.consA).signed_at);
});

test('retention without the bearer token is 403', async () => {
  const r = await fetch(`${API}/functions/v1/consultation-retention`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: '{}' });
  assert.equal(r.status, 403);
  const r2 = await fetch(`${API}/functions/v1/consultation-retention`, { method: 'POST', headers: { apikey: ANON, Authorization: 'Bearer wrong', 'Content-Type': 'application/json' }, body: '{}' });
  assert.equal(r2.status, 403);
});

test('retention dry-run then real run', async () => {
  const bk = makeBooking(ORG_A, BR_A);
  const old31 = `${ORG_A}/${bk}/${RUN}-31.webm`; const new29 = `${ORG_A}/${bk}/${RUN}-29.webm`; const draftP = `${ORG_A}/${bk}/${RUN}-draft.webm`;
  for (const p of [old31, new29, draftP]) await upload(p);
  const c31 = makeConsultation({ org: ORG_A, branch: BR_A, booking: bk, audioPaths: [old31], signedDaysAgo: 31 });
  const c29 = makeConsultation({ org: ORG_A, branch: BR_A, booking: bk, audioPaths: [new29], signedDaysAgo: 29 });
  const cd = makeConsultation({ org: ORG_A, branch: BR_A, booking: bk, audioPaths: [draftP] });
  psql(`UPDATE public.consultations SET transcript_segments='[{"audio_path":"x","start":0,"end":1,"text":"keep me"}]', final_summary='note stays' WHERE id='${cd}'`);
  const call = (body) => fetch(`${API}/functions/v1/consultation-retention`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${CRON}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

  const dry = await call({ dry_run: true });
  assert.equal(dry.status, 200, await dry.clone().text());
  const d = await dry.json();
  const ids = d.would_delete.map((x) => x.id);
  assert.ok(ids.includes(c31)); assert.ok(!ids.includes(c29)); assert.ok(!ids.includes(cd));
  assert.ok(await exists(old31), 'dry run deletes nothing');
  assert.deepEqual(row(c31).audio_paths, [old31]);

  const real = await call({});
  assert.equal(real.status, 200, await real.clone().text());
  const r = await real.json();
  assert.ok(r.consultations >= 1 && r.failed === 0, JSON.stringify(r));
  assert.equal(await exists(old31), false, '31-day file gone from Storage');
  assert.deepEqual(row(c31).audio_paths, []);
  assert.ok(row(c31).audio_deleted_at);
  assert.equal(await exists(new29), true); assert.deepEqual(row(c29).audio_paths, [new29]);
  assert.equal(await exists(draftP), true); assert.deepEqual(row(cd).audio_paths, [draftP]);
  assert.equal(row(cd).final_summary, 'note stays');
  assert.equal(row(cd).transcript_segments.length, 1);
});
