import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { authenticate, corsHeaders, json } from '../_shared/consultation.ts';
import { sha256Hex, shortHash, createPairingCode, clientIp, isLockedOut, recordFailure } from '../_shared/pairing.ts';

// Signs a phone in as the user whose computer showed the code.
//   { action: 'create' }                 (logged-in computer) -> { code, shortCode, expiresAt }
//   { action: 'redeem', code }           (phone; the long code from the QR link) -> { tokenHash }
//   { action: 'redeem', shortCode }      (phone; the 6 digits typed in the Doctor app) -> { tokenHash }
//   { action: 'verify', shortCode }      (phone already signed in, after tapping a notification) -> { ok: true }
//        Confirms the code was made for the SAME user as the phone's login; it does not sign in again.
// The phone then calls auth.verifyOtp({ token_hash, type: 'magiclink' }).
// Codes are random, stored only as hashes, valid 3 minutes, and work once.
// Typed 6-digit codes are rate limited: too many wrong guesses lock redeeming for a while.

const CODE_TTL_MS = 3 * 60 * 1000;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const body = await req.json().catch(() => ({}));
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  if (body.action === 'create') {
    const auth = await authenticate(req);
    if (auth instanceof Response) return auth;

    const { data: profile } = await auth.supabase.from('users').select('role, is_active').eq('id', auth.user.id).maybeSingle();
    if (!profile || profile.is_active === false || !['staff', 'manager', 'admin'].includes(profile.role)) {
      return json({ error: 'Your account cannot pair a phone.' }, 403);
    }

    // Tidy old rows.
    const dayAgo = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    await admin.from('phone_pairings').delete().lt('expires_at', dayAgo);
    await admin.from('phone_pairing_failures').delete().lt('created_at', dayAgo);

    const created = await createPairingCode(admin, auth.user.id, CODE_TTL_MS);
    if (!created) return json({ error: 'Could not create a pairing code.' }, 500);
    return json(created);
  }

  if (body.action === 'verify') {
    const auth = await authenticate(req);
    if (auth instanceof Response) return auth;

    const shortCode = typeof body.shortCode === 'string' ? body.shortCode.replace(/\s+/g, '') : '';
    if (!/^\d{6}$/.test(shortCode)) return json({ error: 'Enter the 6-digit code shown on the computer.' }, 400);

    const ip = clientIp(req);
    if (await isLockedOut(admin, ip)) {
      return json({ error: 'Too many wrong codes. Wait a few minutes and try again.' }, 429);
    }

    // The code must belong to this same user, be unused and unexpired; it works once.
    const { data: used } = await admin
      .from('phone_pairings')
      .update({ used_at: new Date().toISOString() })
      .eq('short_hash', await shortHash(shortCode))
      .eq('user_id', auth.user.id)
      .is('used_at', null)
      .gt('expires_at', new Date().toISOString())
      .select('id')
      .maybeSingle();

    if (!used) {
      await recordFailure(admin, ip);
      return json({ error: 'That code is wrong or has expired. Check the computer for the current code.' }, 400);
    }
    return json({ ok: true });
  }

  if (body.action === 'redeem') {
    const longCode = typeof body.code === 'string' ? body.code : '';
    const shortCode = typeof body.shortCode === 'string' ? body.shortCode.replace(/\s+/g, '') : '';
    const byShort = !longCode && /^\d{6}$/.test(shortCode);
    if (!byShort && !/^[0-9a-f]{64}$/.test(longCode)) return json({ error: 'This pairing code is not valid.' }, 400);

    const ip = clientIp(req);
    if (byShort && (await isLockedOut(admin, ip))) {
      return json({ error: 'Too many wrong codes. Wait a few minutes, or scan the QR code instead.' }, 429);
    }

    // Single use: the update only matches an unused, unexpired code.
    const column = byShort ? 'short_hash' : 'code_hash';
    const hash = byShort ? await shortHash(shortCode) : await sha256Hex(longCode);
    const { data: used } = await admin
      .from('phone_pairings')
      .update({ used_at: new Date().toISOString() })
      .eq(column, hash)
      .is('used_at', null)
      .gt('expires_at', new Date().toISOString())
      .select('user_id')
      .maybeSingle();

    if (!used) {
      if (byShort) await recordFailure(admin, ip);
      return json({ error: 'This code has expired, was already used, or is wrong. Check the computer for the current code.' }, 400);
    }

    const { data: userData } = await admin.auth.admin.getUserById(used.user_id);
    const email = userData?.user?.email;
    if (!email) return json({ error: 'Could not find the account for this code.' }, 400);

    const { data: link, error: linkError } = await admin.auth.admin.generateLink({ type: 'magiclink', email });
    const tokenHash = link?.properties?.hashed_token;
    if (linkError || !tokenHash) return json({ error: 'Could not sign this phone in.' }, 500);
    return json({ tokenHash });
  }

  return json({ error: "action must be 'create' or 'redeem'" }, 400);
});
