// Calls the REAL patient-erase edge function over HTTP on the LOCAL stack (`supabase functions serve patient-erase` must be running).
//   eval "$(supabase status -o env | sed 's/^/export /')"
//   LOCAL_API_URL=$API_URL LOCAL_ANON_KEY=$ANON_KEY LOCAL_SERVICE_KEY=$SERVICE_ROLE_KEY node scripts/test-patient-erase-http-local.mjs
// Local only. NOTE: service_role has no write grant on the 019 tables (by design), so the patient row left behind by an erase is removed with psql:
//   delete from patient_erasures where customer_id in (select id from customers where full_name like 'Erased patient P-%'); ... delete from customers where full_name like 'Erased patient P-%'; It never prints a password or a token. It cleans up what it creates (action_log is append-only).
import { createClient } from '@supabase/supabase-js';

const URL = process.env.LOCAL_API_URL ?? 'http://127.0.0.1:55321';
const ANON = process.env.LOCAL_ANON_KEY; const SERVICE = process.env.LOCAL_SERVICE_KEY;
if (!/^https?:\/\/(127\.0\.0\.1|localhost)[:/]/.test(URL)) { console.error('Refusing: LOCAL_API_URL must be a local address.'); process.exit(2); }
if (!ANON || !SERVICE) { console.error('Set LOCAL_ANON_KEY and LOCAL_SERVICE_KEY.'); process.exit(2); }
const service = createClient(URL, SERVICE, { auth: { persistSession: false } });
const sfx = Math.random().toString(36).slice(2, 8);
const made = { authUsers: [], customers: [], objects: [] };
let fails = 0;
const check = (label, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${ok ? '' : '  -> ' + detail}`); if (!ok) fails++; };

let n = 0;
async function makeUser(role, org, branch) {
  const email = `erasehttp-${role}-${n++}-${sfx}@test.invalid`; const password = `pw-${sfx}-${Math.random().toString(36).slice(2)}Aa1!`;
  const { data, error } = await service.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw error;
  made.authUsers.push(data.user.id);
  const { error: e2 } = await service.from('users').insert({ id: data.user.id, email, full_name: `Erase http ${role}`, role, branch_id: branch, org_id: org, is_active: true });
  if (e2) throw e2;
  const c = createClient(URL, ANON, { auth: { persistSession: false } });
  const { data: s, error: e3 } = await c.auth.signInWithPassword({ email, password });
  if (e3) throw e3;
  return { client: c, jwt: s.session.access_token };
}
const call = async (jwt, body) => {
  const res = await fetch(`${URL}/functions/v1/patient-erase`, { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: ANON, ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}) }, body: JSON.stringify(body) });
  let json = null; try { json = await res.json(); } catch { /* not json */ }
  return { status: res.status, json };
};
const exists = async (bucket, path) => { const { data } = await service.storage.from(bucket).list(path.split('/').slice(0, -1).join('/')); return (data ?? []).some((o) => o.name === path.split('/').pop()); };

try {
  const { data: bA } = await service.from('branches').select('id, org_id').limit(1).single();
  const orgA = bA.org_id;
  const { data: bB } = await service.from('branches').select('id, org_id').neq('org_id', orgA).limit(1).single();
  const { data: bk } = await service.from('bookings').select('id').eq('branch_id', bA.id).limit(1).single();
  const adminA = await makeUser('admin', orgA, bA.id);
  const managerA = await makeUser('manager', orgA, bA.id);
  const adminB = await makeUser('admin', bB.org_id, bB.id);

  const { data: cust, error: ce } = await service.from('customers').insert({ org_id: orgA, branch_id: bA.id, full_name: `Erase Http ${sfx}`, phone: `970${Math.floor(1e6 + Math.random() * 8e6)}` }).select('id').single();
  if (ce) throw ce;
  made.customers.push(cust.id);
  const audio = `${orgA}/${bk.id}/rec-${sfx}.webm`;
  await service.storage.from('consultation-audio').upload(audio, new Blob(['fake audio']), { contentType: 'audio/webm' });
  made.objects.push(['consultation-audio', audio]);
  await service.from('consultations').insert({ org_id: orgA, branch_id: bA.id, booking_id: bk.id, customer_id: cust.id, patient_name: 'x', doctor_notes: 'kept', transcript: 't', audio_paths: [audio], status: 'completed' });
  const requestPath = `${orgA}/${cust.id}/request-${sfx}.pdf`;
  const up = await adminA.client.storage.from('erase-requests').upload(requestPath, new Blob(['request']), { contentType: 'application/pdf' });
  if (up.error) throw up.error;
  made.objects.push(['erase-requests', requestPath]);
  const body = { customerId: cust.id, requestPath, typedName: `Erase Http ${sfx}` };

  let r = await call(null, body);
  check('no JWT: 401', r.status === 401, `${r.status} ${JSON.stringify(r.json)}`);
  r = await call('not-a-real-token', body);
  check('a garbage token: 401', r.status === 401, `${r.status}`);
  r = await call(managerA.jwt, body);
  check('a manager of the same org: refused (403 FORBIDDEN)', r.status === 403 && r.json?.error?.code === 'FORBIDDEN', `${r.status} ${JSON.stringify(r.json)}`);
  r = await call(adminB.jwt, body);
  check('the admin of ANOTHER org on this patient: refused (404 PATIENT_NOT_FOUND)', r.status === 404 && r.json?.error?.code === 'PATIENT_NOT_FOUND', `${r.status} ${JSON.stringify(r.json)}`);
  check('  ... nothing was deleted by the refusals', await exists('consultation-audio', audio));
  r = await call(adminA.jwt, { ...body, typedName: 'Wrong Name' });
  check('the owner with the wrong typed name: 409 NAME_MISMATCH, recording intact', r.status === 409 && r.json?.error?.code === 'NAME_MISMATCH' && await exists('consultation-audio', audio), `${r.status} ${JSON.stringify(r.json)}`);
  r = await call(adminA.jwt, { ...body, requestPath: `${orgA}/${cust.id}/missing.pdf` });
  check('the owner with no request file: 409 REQUEST_FILE_MISSING, recording intact', r.status === 409 && r.json?.error?.code === 'REQUEST_FILE_MISSING' && await exists('consultation-audio', audio), `${r.status}`);
  r = await call(adminA.jwt, body);
  check('the owner with a valid request file: 200, erased', r.status === 200 && r.json?.ok === true && r.json?.data?.deleted_recordings === 1, `${r.status} ${JSON.stringify(r.json)}`);
  check('  ... recording gone from Storage', !(await exists('consultation-audio', audio)));
  const { data: after } = await service.from('customers').select('full_name, phone, erased_at').eq('id', cust.id).single();
  check('  ... patient wiped and relabelled', /^Erased patient P-\d{5}$/.test(after.full_name) && after.phone === null && after.erased_at !== null, JSON.stringify(after));
  r = await call(adminA.jwt, body);
  check('the same call again: 409 ALREADY_ERASED', r.status === 409 && r.json?.error?.code === 'ALREADY_ERASED', `${r.status} ${JSON.stringify(r.json)}`);
} catch (e) { console.error('ERROR', e?.message ?? e); fails++; }
finally {
  for (const [b, p] of made.objects) await service.storage.from(b).remove([p]);
  for (const id of made.customers) {
    for (const t of ['patient_erasures', 'consultations', 'treatment_notes', 'patient_alerts', 'form_submissions']) { const { error } = await service.from(t).delete().eq('customer_id', id); if (error) console.log(`  cleanup ${t}: ${error.message}`); }
    const { error } = await service.from('customers').delete().eq('id', id); if (error) console.log(`  cleanup customers: ${error.message}`);
  }
  for (const id of made.authUsers) { await service.from('users').delete().eq('id', id); await service.auth.admin.deleteUser(id); }
  console.log(fails === 0 ? 'ALL PASSED' : `${fails} FAILED`);
  process.exit(fails === 0 ? 0 : 1);
}
