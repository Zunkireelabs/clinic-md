import { createClient } from '@supabase/supabase-js';

// A relative value (e.g. "/sb") is resolved against the page's own origin. The
// dev server forwards that path to local Supabase, so a phone opening the app
// over the network does not need to reach 127.0.0.1 itself.
const rawSupabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseUrl = rawSupabaseUrl?.startsWith('/') ? `${window.location.origin}${rawSupabaseUrl}` : rawSupabaseUrl;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error('Missing VITE_SUPABASE_URL or VITE_SUPABASE_ANON_KEY environment variables');
}

// Customer auth is now email-OTP (a 6-digit code typed inline, verified via
// supabaseCustomer.auth.verifyOtp) rather than email-link redirects, so no
// client actually needs to consume tokens out of a URL anymore. This was a
// real bug when it did apply, though: all three clients used to default to
// detectSessionInUrl: true, so each independently raced to parse the same
// #access_token=... fragment from a confirmation-link redirect — whichever
// client won grabbed the session, which was wrong whenever it wasn't
// supabaseCustomer (e.g. the staff AuthContext would end up "signed in" as
// the customer and 406 trying to look up a non-existent `users` row, while
// CustomerAuthContext never saw the session at all). Staff uses PIN login
// and platform uses password login — neither ever needs URL-token parsing —
// so it stays disabled here as defense-in-depth even though nothing should
// land on these routes with tokens in the URL now.
export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: { detectSessionInUrl: false },
});

// Separate client for customer-facing auth (own storage key) so a customer
// logging in on /:orgSlug/book doesn't clobber a staff session in the same
// browser, and vice versa.
export const supabaseCustomer = createClient(supabaseUrl, supabaseAnonKey, {
  auth: { storageKey: 'clinicmd-customer-auth' },
});

// Isolated client for the platform super-admin area (own storage key) so a
// platform login never triggers the staff AuthContext listener (which would
// look up a non-existent org profile and bounce to /login). Mirrors
// supabaseCustomer's isolation. Never used for email-link flows, so it's
// excluded from the URL-token race for the same reason as `supabase` above.
export const supabasePlatform = createClient(supabaseUrl, supabaseAnonKey, {
  auth: { storageKey: 'clinicmd-platform-auth', detectSessionInUrl: false },
});
