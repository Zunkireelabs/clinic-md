// Proves the front-desk wall holds on Realtime (LOCAL stack only): a manager and a front-desk user both subscribe to postgres_changes on
// public.consultations; a superuser UPDATE then changes one row. Expected: the manager receives the event, front desk receives none.
//   eval "$(supabase status -o env | sed 's/^/export /')"
//   LOCAL_API_URL=$API_URL LOCAL_ANON_KEY=$ANON_KEY LOCAL_SERVICE_KEY=$SERVICE_ROLE_KEY node scripts/test-consultations-realtime-local.mjs
// Never prints a password or token. The UPDATE runs through psql on the local database (postgresql://postgres:postgres@127.0.0.1:55322).
import { createClient } from '@supabase/supabase-js';
import { execFileSync } from 'node:child_process';

const URL = process.env.LOCAL_API_URL ?? 'http://127.0.0.1:55321';
const ANON = process.env.LOCAL_ANON_KEY; const SERVICE = process.env.LOCAL_SERVICE_KEY;
if (!/^https?:\/\/(127\.0\.0\.1|localhost)[:/]/.test(URL)) { console.error('Refusing: LOCAL_API_URL must be a local address.'); process.exit(2); }
if (!ANON || !SERVICE) { console.error('Set LOCAL_ANON_KEY and LOCAL_SERVICE_KEY.'); process.exit(2); }
const DB = 'postgresql://postgres:postgres@127.0.0.1:55322/postgres';
const psql = (sql) => execFileSync('psql', [DB, '-v', 'ON_ERROR_STOP=1', '-Atc', sql], { encoding: 'utf8' });
const service = createClient(URL, SERVICE, { auth: { persistSession: false } });
const sfx = Math.random().toString(36).slice(2, 8);
const made = { authUsers: [] }; let consId = null; let fails = 0;
const check = (label, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${ok ? '' : '  -> ' + detail}`); if (!ok) fails++; };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function makeUser(role, org, branch) {
  const email = `rt-${role}-${sfx}@test.invalid`; const password = `pw-${sfx}-${Math.random().toString(36).slice(2)}Aa1!`;
  const { data, error } = await service.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw error;
  made.authUsers.push(data.user.id);
  const { error: e2 } = await service.from('users').insert({ id: data.user.id, email, full_name: `RT ${role}`, role, branch_id: branch, org_id: org, is_active: true });
  if (e2) throw e2;
  const { error: eb } = await service.from('user_branches').insert({ user_id: data.user.id, branch_id: branch });
  if (eb) throw eb;
  const c = createClient(URL, ANON, { auth: { persistSession: false } });
  const { error: e3 } = await c.auth.signInWithPassword({ email, password });
  if (e3) throw e3;
  await c.realtime.setAuth((await c.auth.getSession()).data.session.access_token);
  return c;
}
async function listen(client, label, sink) {
  const ch = client.channel(`rt-${label}-${sfx}`).on('postgres_changes', { event: '*', schema: 'public', table: 'consultations' }, (p) => sink.push(p.eventType));
  await new Promise((resolve, reject) => { const t = setTimeout(() => reject(new Error(`${label}: subscribe timeout`)), 10000); ch.subscribe((s, e) => { if (s === 'SUBSCRIBED') { clearTimeout(t); resolve(); } if (s === 'CHANNEL_ERROR' || s === 'TIMED_OUT') { clearTimeout(t); reject(e ?? new Error(s)); } }); });
  return ch;
}

const channels = [];
try {
  const { data: bk } = await service.from('bookings').select('id, branch_id').limit(1).single();
  const { data: br } = await service.from('branches').select('org_id').eq('id', bk.branch_id).single();
  const manager = await makeUser('manager', br.org_id, bk.branch_id);
  const staff = await makeUser('staff', br.org_id, bk.branch_id);
  const { data: cons, error: ce } = await service.from('consultations').insert({ org_id: br.org_id, branch_id: bk.branch_id, booking_id: bk.id, patient_name: 'Realtime check', doctor_notes: 'v0', status: 'completed' }).select('id').single();
  if (ce) throw ce;
  consId = cons.id;
  const gotManager = []; const gotStaff = [];
  channels.push(await listen(manager, 'manager', gotManager), await listen(staff, 'staff', gotStaff));
  await wait(1500);
  psql(`update public.consultations set doctor_notes = 'v1 ${sfx}' where id = '${consId}'`);
  await wait(4000);
  check('control: the manager (clinical role) receives the change event', gotManager.length >= 1, `events ${JSON.stringify(gotManager)}`);
  check('front desk receives NO event for the same change', gotStaff.length === 0, `events ${JSON.stringify(gotStaff)}`);
  psql(`delete from public.consultations where id = '${consId}'`); consId = null;
  await wait(2500);
  // Supabase Realtime does not apply RLS to DELETE events (the old row is gone); the payload carries only the primary key, never a body.
  check('INFO: a DELETE reaches every subscriber (id only, RLS cannot filter it): front desk events = ' + JSON.stringify(gotStaff), true);
} catch (e) { console.error('ERROR', e?.message ?? e); fails++; }
finally {
  for (const ch of channels) { try { await ch.unsubscribe(); } catch { /* ignore */ } }
  if (consId) psql(`delete from public.consultations where id = '${consId}'`);
  for (const id of made.authUsers) { await service.from('user_branches').delete().eq('user_id', id); await service.from('users').delete().eq('id', id); await service.auth.admin.deleteUser(id); }
  console.log(fails === 0 ? 'ALL PASSED' : `${fails} FAILED`);
  process.exit(fails === 0 ? 0 : 1);
}
