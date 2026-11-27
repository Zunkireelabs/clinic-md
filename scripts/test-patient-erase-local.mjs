// Integration check of the patient erase flow against the LOCAL Supabase stack (never production).
//   eval "$(supabase status -o env | sed 's/^/export /')"   # or pass the three values yourself
//   LOCAL_API_URL=http://127.0.0.1:55321 LOCAL_ANON_KEY=... LOCAL_SERVICE_KEY=... node scripts/test-patient-erase-local.mjs
// NOTE: service_role has no write grant on the 019 tables (by design), so the erased patient row is left behind; remove it with psql (see test-patient-erase-http-local.mjs).
// It creates its own org rows (an admin and a front-desk user, a patient with a recording, a login and a written request), runs the real
// flow (runPatientErase + real Storage API + real act_patient_erase), prints PASS/FAIL, and cleans up what it can (action_log is append-only).
import { createClient } from '@supabase/supabase-js';
import { runPatientErase } from '../supabase/functions/_shared/patient-erase.ts';
import { buildEraseDeps } from '../supabase/functions/_shared/patient-erase-deps.ts';

const URL = process.env.LOCAL_API_URL ?? 'http://127.0.0.1:55321';
const ANON = process.env.LOCAL_ANON_KEY;
const SERVICE = process.env.LOCAL_SERVICE_KEY;
if (!/^https?:\/\/(127\.0\.0\.1|localhost)[:/]/.test(URL)) { console.error('Refusing: LOCAL_API_URL must be a local address.'); process.exit(2); }
if (!ANON || !SERVICE) { console.error('Set LOCAL_ANON_KEY and LOCAL_SERVICE_KEY (from `supabase status`).'); process.exit(2); }

const service = createClient(URL, SERVICE, { auth: { persistSession: false } });
let fails = 0;
const check = (label, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${ok ? '' : '  -> ' + detail}`); if (!ok) fails++; };
const sfx = Math.random().toString(36).slice(2, 8);
const made = { authUsers: [], customers: [], objects: [] };

async function signedInClient(email, password) {
  const c = createClient(URL, ANON, { auth: { persistSession: false } });
  const { error } = await c.auth.signInWithPassword({ email, password });
  if (error) throw error;
  return c;
}
async function makeUser(role, org, branch) {
  const email = `erase-${role}-${sfx}@test.invalid`; const password = `pw-${sfx}-Aa1!`;
  const { data, error } = await service.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw error;
  made.authUsers.push(data.user.id);
  const { error: e2 } = await service.from('users').insert({ id: data.user.id, email, full_name: `Erase test ${role}`, role, branch_id: branch, org_id: org, is_active: true });
  if (e2) throw e2;
  return { id: data.user.id, client: await signedInClient(email, password) };
}
const exists = async (bucket, path) => { const dir = path.split('/').slice(0, -1).join('/'); const { data } = await service.storage.from(bucket).list(dir); return (data ?? []).some((o) => o.name === path.split('/').pop()); };

try {
  const { data: br } = await service.from('branches').select('id, org_id').limit(1).single();
  const org = br.org_id; const branch = br.id;
  const { data: bk } = await service.from('bookings').select('id').eq('branch_id', branch).limit(1).single();
  const admin = await makeUser('admin', org, branch);
  const staff = await makeUser('staff', org, branch);

  const { data: cust, error: ce } = await service.from('customers').insert({ org_id: org, branch_id: branch, full_name: `Erase Flow ${sfx}`, phone: `970${Math.floor(1e6 + Math.random() * 8e6)}`, email: `erase-${sfx}@example.test` }).select('id').single();
  if (ce) throw ce;
  made.customers.push(cust.id);
  const audio = `${org}/${bk.id}/rec-${sfx}.webm`;
  const { error: ue } = await service.storage.from('consultation-audio').upload(audio, new Blob(['fake audio']), { contentType: 'audio/webm' });
  if (ue) throw ue;
  made.objects.push(['consultation-audio', audio]);
  await service.from('consultations').insert({ org_id: org, branch_id: branch, booking_id: bk.id, customer_id: cust.id, patient_name: 'Erase Flow', doctor_notes: 'kept note', transcript: 'spoken', audio_paths: [audio], status: 'completed' });
  const loginEmail = `login-${sfx}@test.invalid`;
  const { data: lu } = await service.auth.admin.createUser({ email: loginEmail, password: `pw-${sfx}-Aa1!`, email_confirm: true });
  made.authUsers.push(lu.user.id);
  await service.from('customer_accounts').insert({ org_id: org, auth_user_id: lu.user.id, email: loginEmail, full_name: 'Erase Flow', customer_id: cust.id });

  // the front-desk wall at the Storage API (not just SQL): an X-ray object, signed URL and download, as front desk and as the owner
  const xray = `${org}/${bk.id}/xray-${sfx}.jpg`;
  const { error: xe } = await service.storage.from('consultation-images').upload(xray, new Blob(['fake image']), { contentType: 'image/jpeg' });
  if (xe) throw xe;
  made.objects.push(['consultation-images', xray]);
  const sUrl = await staff.client.storage.from('consultation-images').createSignedUrl(xray, 60);
  check('WALL (Storage API): front desk cannot get a signed URL for an X-ray', !!sUrl.error || !sUrl.data?.signedUrl, JSON.stringify(sUrl));
  const sDl = await staff.client.storage.from('consultation-images').download(xray);
  check('WALL (Storage API): front desk cannot download it', !!sDl.error);
  const sAudio = await staff.client.storage.from('consultation-audio').createSignedUrl(audio, 60);
  check('WALL (Storage API): front desk cannot get a signed URL for a recording', !!sAudio.error || !sAudio.data?.signedUrl);
  const aUrl = await admin.client.storage.from('consultation-images').createSignedUrl(xray, 60);
  check('WALL (Storage API): the owner can', !aUrl.error && !!aUrl.data?.signedUrl, JSON.stringify(aUrl));
  const aDl = await admin.client.storage.from('consultation-images').download(xray);
  check('WALL (Storage API): the owner can download it', !aDl.error);

  const requestPath = `${org}/${cust.id}/request-${sfx}.pdf`;
  const input = { customerId: cust.id, requestPath, typedName: `Erase Flow ${sfx}` };
  const deps = (client, who) => buildEraseDeps(client, service, org, (level, m, d) => console.log(`   [${who} ${level}] ${m} ${JSON.stringify(d)}`));
  const run = (client, who, i = input) => runPatientErase(deps(client, who), i);

  // 1. nothing uploaded yet: refused, the recording must survive
  let r = await run(admin.client, 'admin');
  check('no written request uploaded: refused (REQUEST_FILE_MISSING)', r.body.error?.code === 'REQUEST_FILE_MISSING');
  check('  ... and the recording was NOT deleted', await exists('consultation-audio', audio));

  // 2. front desk cannot upload the request, nor run the erase
  const up = await staff.client.storage.from('erase-requests').upload(requestPath, new Blob(['x']));
  check('front desk cannot upload to erase-requests', !!up.error);
  r = await run(staff.client, 'staff');
  check('front desk: refused (FORBIDDEN), recording intact', r.body.error?.code === 'FORBIDDEN' && await exists('consultation-audio', audio));

  // 3. the owner uploads the request; the SQL function alone refuses while the recording exists
  const up2 = await admin.client.storage.from('erase-requests').upload(requestPath, new Blob(['signed request']), { contentType: 'application/pdf' });
  check('the owner uploads the written request', !up2.error, up2.error?.message);
  made.objects.push(['erase-requests', requestPath]);
  const direct = await admin.client.rpc('act_patient_erase', { p_customer: cust.id, p_request_path: requestPath, p_typed_name: input.typedName });
  check('the SQL function ALONE refuses while a recording exists (AUDIO_FILES_REMAIN)', direct.data?.error?.code === 'AUDIO_FILES_REMAIN');

  // 4. wrong typed name: nothing deleted
  r = await run(admin.client, 'admin', { ...input, typedName: 'Someone Else' });
  check('wrong typed name: refused (NAME_MISMATCH), recording intact', r.body.error?.code === 'NAME_MISMATCH' && await exists('consultation-audio', audio));

  // 5. the real thing
  r = await run(admin.client, 'admin');
  check('the owner erases: ok', r.status === 200 && r.body.ok === true, JSON.stringify(r.body));
  check('  ... the recording is gone from Storage', !(await exists('consultation-audio', audio)));
  check('  ... the patient login (auth user) is gone', (await service.auth.admin.getUserById(lu.user.id)).data?.user == null);
  const { data: after } = await service.from('customers').select('full_name, phone, email, erased_at').eq('id', cust.id).single();
  check('  ... the patient is wiped and relabelled', /^Erased patient P-\d{5}$/.test(after.full_name) && after.phone === null && after.email === null && after.erased_at !== null, JSON.stringify(after));
  const { data: con } = await service.from('consultations').select('doctor_notes, transcript, audio_paths').eq('customer_id', cust.id).single();
  check('  ... the clinical note is kept, the transcript and recording paths are gone', con.doctor_notes === 'kept note' && con.transcript === null && con.audio_paths.length === 0);
  check('  ... the result carries no auth ids', r.body.data?.auth_user_ids === undefined && r.body.data?.deleted_recordings === 1);

  // 6. again: refused
  r = await run(admin.client, 'admin');
  check('erasing twice is refused (ALREADY_ERASED)', r.body.error?.code === 'ALREADY_ERASED');
} catch (e) {
  console.error('ERROR', e);
  fails++;
} finally {
  for (const [bucket, path] of made.objects) await service.storage.from(bucket).remove([path]);
  for (const id of made.customers) {
    await service.from('patient_erasures').delete().eq('customer_id', id);
    await service.from('consultations').delete().eq('customer_id', id);
    await service.from('customers').delete().eq('id', id);
  }
  for (const id of made.authUsers) { await service.from('users').delete().eq('id', id); await service.auth.admin.deleteUser(id); }
  console.log(fails === 0 ? 'ALL PASSED' : `${fails} FAILED`);
  process.exit(fails === 0 ? 0 : 1);
}
