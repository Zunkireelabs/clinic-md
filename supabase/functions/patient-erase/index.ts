import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { authenticate, corsHeaders, json } from '../_shared/consultation.ts';
import { runPatientErase, type EraseDeps } from '../_shared/patient-erase.ts';
import { buildEraseDeps } from '../_shared/patient-erase-deps.ts';

// Owner-only erase of a patient (migration-019). Body: { customerId, requestPath, typedName }.
// The caller's JWT is verified, the role must be admin (= owner in this app; admin_viewer and everyone else are refused) and the patient
// must be in the caller's organization BEFORE the service role is used for anything. The database function re-checks all of it.
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ ok: false, error: { code: 'METHOD_NOT_ALLOWED', message: 'POST only.' } }, 405);

  const auth = await authenticate(req, { requireStaff: true });
  if (auth instanceof Response) return auth;

  const { data: me } = await auth.supabase.from('users').select('role, org_id, is_active').eq('id', auth.user.id).maybeSingle();
  if (!me || me.is_active === false || me.role !== 'admin') {
    return json({ ok: false, action_id: null, data: null, error: { code: 'FORBIDDEN', message: 'Only the owner can erase a patient.' } }, 403);
  }

  const input = await req.json().catch(() => ({}));
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ ok: false, error: { code: 'NOT_CONFIGURED', message: 'Server is not configured.' } }, 500);
  const service = createClient(url, key, { auth: { persistSession: false } });

  // the patient must belong to the caller's organization before any file is touched
  const { data: cust } = await service.from('customers').select('id, org_id').eq('id', String(input.customerId ?? '')).maybeSingle();
  if (!cust || cust.org_id !== me.org_id) {
    return json({ ok: false, action_id: null, data: null, error: { code: 'PATIENT_NOT_FOUND', message: 'Patient not found.' } }, 404);
  }

  const deps: EraseDeps = buildEraseDeps(auth.supabase, service, me.org_id, (level, message, detail) => (level === 'error' ? console.error : console.log)(message, JSON.stringify(detail ?? {})));

  const { status, body } = await runPatientErase(deps, { customerId: String(input.customerId), requestPath: String(input.requestPath ?? ''), typedName: String(input.typedName ?? '') });
  return json(body, status);
});
