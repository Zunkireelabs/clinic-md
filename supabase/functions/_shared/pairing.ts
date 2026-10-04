import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

// One-time codes that tie a phone to a logged-in user. Used to sign a phone in
// (phone-pair) and to confirm the person holding the phone is at the computer
// when they tap a notification (consultation-push + phone-pair 'verify').
// Only hashes are stored; codes are random, expire, and work once.

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

/** Creates a code row for the user. Retries on the rare clash of two open 6-digit codes. */
export const createPairingCode = async (
  admin: SupabaseClient,
  userId: string,
  ttlMs: number,
): Promise<{ code: string; shortCode: string; expiresAt: string } | null> => {
  const code = randomCode();
  const expiresAt = new Date(Date.now() + ttlMs).toISOString();
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const shortCode = randomShortCode();
    const { error } = await admin.from('phone_pairings').insert({
      user_id: userId,
      code_hash: await sha256Hex(code),
      short_hash: await shortHash(shortCode),
      expires_at: expiresAt,
    });
    if (!error) return { code, shortCode, expiresAt };
    if (error.code !== '23505') return null;
  }
  return null;
};

// Wrong 6-digit guesses are counted so a 6-digit code cannot be brute-forced.
const FAIL_WINDOW_MS = 10 * 60 * 1000;
const MAX_FAILS_PER_IP = 5;
const MAX_FAILS_TOTAL = 20;

export const clientIp = (req: Request): string =>
  (req.headers.get('cf-connecting-ip') || req.headers.get('x-forwarded-for') || 'unknown').split(',')[0].trim();

/** True when too many wrong guesses happened recently (from this address, or overall). */
export const isLockedOut = async (admin: SupabaseClient, ip: string): Promise<boolean> => {
  const since = new Date(Date.now() - FAIL_WINDOW_MS).toISOString();
  const [{ count: fromIp }, { count: total }] = await Promise.all([
    admin.from('phone_pairing_failures').select('id', { count: 'exact', head: true }).eq('ip', ip).gt('created_at', since),
    admin.from('phone_pairing_failures').select('id', { count: 'exact', head: true }).gt('created_at', since),
  ]);
  return (fromIp ?? 0) >= MAX_FAILS_PER_IP || (total ?? 0) >= MAX_FAILS_TOTAL;
};

export const recordFailure = (admin: SupabaseClient, ip: string) => admin.from('phone_pairing_failures').insert({ ip });
