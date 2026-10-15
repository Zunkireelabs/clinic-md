import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { authenticate, corsHeaders, json } from '../_shared/consultation.ts';
import { sha256Hex, shortHash, createPairingCode, clientIp } from '../_shared/pairing.ts';

// Phone pairing.
//   { action: 'create' }                 (logged-in computer) -> { code, expiresAt }       the QR link's 256-bit sign-in code
//   { action: 'create', purpose: 'verify' } (logged-in computer) -> { shortCode, expiresAt } a 6-digit code to type on the phone
//   { action: 'redeem', code }           (phone; the long code from the QR link) -> { tokenHash }   SIGNS THE PHONE IN
//   { action: 'verify', shortCode }      (phone ALREADY signed in as the same user) -> { ok: true }  never signs in
// 6-digit codes can't sign anyone in: only the long QR code can. Verify attempts are counted atomically in the database
// (per user and per code) and codes are minted at most 5 per 10 minutes per user.
// The phone then calls auth.verifyOtp({ token_hash, type: 'magiclink' }).

const SIGNIN_TTL_MS = 3 * 60 * 1000;
const VERIFY_TTL_MS = 5 * 60 * 1000;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const body = await req.json().catch(() => ({}));
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  if (body.action === 'create') {
    const auth = await authenticate(req, { requireStaff: true });
    if (auth instanceof Response) return auth;

    // Tidy old rows.
    const dayAgo = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    await admin.from('phone_pairings').delete().lt('expires_at', dayAgo);
    await admin.from('phone_pairing_failures').delete().lt('created_at', dayAgo);

    const purpose = body.purpose === 'verify' ? 'verify' : 'signin';
    const created = await createPairingCode(admin, auth.user.id, purpose === 'verify' ? VERIFY_TTL_MS : SIGNIN_TTL_MS, purpose);
    if (created === 'rate_limited') return json({ error: 'RATE_LIMITED', message: 'Too many codes requested. Wait a few minutes and try again.' }, 429);
    if (!created) return json({ error: 'PAIRING_FAILED', message: 'Could not create a pairing code.' }, 500);
    return json(purpose === 'verify'
      ? { shortCode: created.shortCode, expiresAt: created.expiresAt }
      : { code: created.code, expiresAt: created.expiresAt });
  }

  if (body.action === 'verify') {
    const auth = await authenticate(req, { requireStaff: true });
    if (auth instanceof Response) return auth;

    const shortCode = typeof body.shortCode === 'string' ? body.shortCode.replace(/\s+/g, '') : '';
    if (!/^\d{6}$/.test(shortCode)) return json({ error: 'BAD_CODE', message: 'Enter the 6-digit code shown on the computer.' }, 400);

    // Atomic in SQL: lock this user, count recent failures, check the code (same user only), record a failure otherwise.
    const { data: result, error } = await admin.rpc('phone_pairing_verify', {
      p_user: auth.user.id, p_short_hash: await shortHash(shortCode), p_ip: clientIp(req),
    });
    if (error) { console.error('[PAIRING_VERIFY]', error.message); return json({ error: 'PAIRING_FAILED', message: 'Could not check the code. Try again.' }, 500); }
    if (result === 'locked') return json({ error: 'LOCKED', message: 'Too many wrong codes. Wait a few minutes and try again.' }, 429);
    if (result !== 'ok') return json({ error: 'WRONG_CODE', message: 'That code is wrong or has expired. Check the computer for the current code.' }, 400);
    return json({ ok: true });
  }

  if (body.action === 'redeem') {
    // Only the long QR code signs a phone in (256-bit: it can't be guessed). 6-digit codes are not accepted here.
    const longCode = typeof body.code === 'string' ? body.code : '';
    if (!/^[0-9a-f]{64}$/.test(longCode)) return json({ error: 'BAD_CODE', message: 'This pairing code is not valid. Scan the QR code on the computer.' }, 400);

    const { data: userId, error: redeemError } = await admin.rpc('phone_pairing_redeem', { p_code_hash: await sha256Hex(longCode) });
    if (redeemError) { console.error('[PAIRING_REDEEM]', redeemError.message); return json({ error: 'PAIRING_FAILED', message: 'Could not sign this phone in.' }, 500); }
    if (!userId) return json({ error: 'WRONG_CODE', message: 'This code has expired, was already used, or is wrong. Show the QR code on the computer again.' }, 400);

    const { data: userData } = await admin.auth.admin.getUserById(userId as string);
    const email = userData?.user?.email;
    if (!email) return json({ error: 'PAIRING_FAILED', message: 'Could not find the account for this code.' }, 400);

    const { data: link, error: linkError } = await admin.auth.admin.generateLink({ type: 'magiclink', email });
    const tokenHash = link?.properties?.hashed_token;
    if (linkError || !tokenHash) { console.error('[PAIRING_LINK]', linkError?.message); return json({ error: 'PAIRING_FAILED', message: 'Could not sign this phone in.' }, 500); }
    return json({ tokenHash });
  }

  return json({ error: 'BAD_ACTION', message: "action must be 'create', 'verify' or 'redeem'" }, 400);
});
