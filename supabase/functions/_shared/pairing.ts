import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

// One-time codes that tie a phone to a logged-in user. Two kinds, stored in phone_pairings.purpose:
//   'signin'  the 256-bit long code in the QR link. The ONLY thing that can sign a phone in.
//   'verify'  a 6-digit code typed on a phone that is ALREADY signed in as the same user (after a notification tap / opening the
//             Doctor app), to prove the person holding it is at the computer. It can never sign anything in.
// Only hashes are stored; codes are random, expire, and work once. Rate limiting and attempt counting happen inside SQL functions
// (see migration-006) so they are atomic.

export const sha256Hex = async (text: string): Promise<string> => {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
};

export const randomCode = (): string =>
  Array.from(crypto.getRandomValues(new Uint8Array(32))).map((b) => b.toString(16).padStart(2, '0')).join('');

// Uniform 6 digits (rejection sampling avoids modulo bias).
export const randomShortCode = (): string => {
  const limit = Math.floor(0x100000000 / 1_000_000) * 1_000_000;
  const buf = new Uint32Array(1);
  do { crypto.getRandomValues(buf); } while (buf[0] >= limit);
  return String(buf[0] % 1_000_000).padStart(6, '0');
};

export const shortHash = (shortCode: string): Promise<string> => sha256Hex(`short:${shortCode}`);

export type CodePurpose = 'signin' | 'verify';
export interface CreatedCode { code: string; shortCode: string | null; expiresAt: string }

/**
 * Creates a code for the user. 'signin' returns only the long code; 'verify' returns the 6-digit code.
 * Returns 'rate_limited' when the user already minted 5 codes in the last 10 minutes, null on any other failure.
 */
export const createPairingCode = async (
  admin: SupabaseClient,
  userId: string,
  ttlMs: number,
  purpose: CodePurpose,
): Promise<CreatedCode | 'rate_limited' | null> => {
  const code = randomCode();
  const expiresAt = new Date(Date.now() + ttlMs).toISOString();
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const shortCode = purpose === 'verify' ? randomShortCode() : null;
    const { data, error } = await admin.rpc('phone_pairing_create', {
      p_user: userId,
      p_code_hash: await sha256Hex(code),
      p_short_hash: shortCode ? await shortHash(shortCode) : null,
      p_purpose: purpose,
      p_expires: expiresAt,
    });
    if (!error) {
      if (data === 'rate_limited') return 'rate_limited';
      return { code, shortCode, expiresAt };
    }
    if (error.code !== '23505') { console.error('[PAIRING_CREATE]', error.message); return null; } // 23505: two of this user's open 6-digit codes clashed; retry
  }
  return null;
};

// The caller's address, only from the header the gateway sets itself (a client can't forge it). Informational only: attempt
// limits are counted per user and per code, so a missing address must not become one shared "unknown" bucket.
export const clientIp = (req: Request): string | null => req.headers.get('cf-connecting-ip')?.trim() || null;
