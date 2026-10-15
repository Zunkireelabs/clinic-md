import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { authenticate, corsHeaders, json } from '../_shared/consultation.ts';
import { createPairingCode } from '../_shared/pairing.ts';

// Sends a "tap to record" notification to the caller's own phones when they
// start a consultation on the computer. Body: { bookingId }.
// The text is deliberately generic: a lock screen must not show a patient's name.
// It also makes a one-time 6-digit code (shown on the computer). Tapping the
// notification opens the Doctor app, which asks for that code before it opens
// the patient, so a phone that is picked up by someone else cannot just tap in.
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const auth = await authenticate(req, { requireStaff: true });
  if (auth instanceof Response) return auth;

  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY');
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY');
  const subject = Deno.env.get('VAPID_SUBJECT') ?? 'mailto:admin@localhost';
  if (!publicKey || !privateKey) {
    return json({ error: 'PUSH_NOT_CONFIGURED', message: 'VAPID keys are not configured on the server.' }, 503);
  }

  const { bookingId } = await req.json().catch(() => ({}));
  if (!bookingId || typeof bookingId !== 'string') return json({ error: 'bookingId is required' }, 400);

  // RLS: only returns the booking if the caller can see it (their own clinic).
  const { data: booking } = await auth.supabase
    .from('bookings')
    .select('id, branch_id, branches(org_id, organizations(slug))')
    .eq('id', bookingId)
    .maybeSingle();
  if (!booking) return json({ error: 'Booking not found' }, 404);

  // deno-lint-ignore no-explicit-any
  const slug = (booking as any).branches?.organizations?.slug;
  if (!slug) return json({ error: 'Could not work out the clinic for this booking' }, 500);

  // RLS: the caller can only read their own subscriptions.
  const { data: subs, error: subError } = await auth.supabase
    .from('push_subscriptions')
    .select('id, endpoint, p256dh, auth');
  if (subError) return json({ error: 'Could not read subscriptions' }, 500);
  if (!subs || subs.length === 0) return json({ sent: 0, reason: 'no_subscriptions' });

  webpush.setVapidDetails(subject, publicKey, privateKey);
  const payload = JSON.stringify({
    title: 'Consultation ready',
    body: 'Tap, then enter the code shown on the computer.',
    url: `/${slug}/phone?booking=${bookingId}&verify=1`,
    tag: `consultation-${bookingId}`,
  });

  let sent = 0;
  const expired: string[] = [];
  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 120 });
      sent += 1;
    } catch (e) {
      // 404/410 = the phone unsubscribed or the subscription expired: forget it.
      const status = (e as { statusCode?: number }).statusCode;
      if (status === 404 || status === 410) expired.push(s.id);
      else console.error('push failed', status, (e as Error).message);
    }
  }));

  if (expired.length > 0) await auth.supabase.from('push_subscriptions').delete().in('id', expired);

  // The code for the doctor to type on the phone. Valid longer than a sign-in code
  // because the doctor may take a few minutes to pick the phone up.
  let shortCode: string | null = null;
  let expiresAt: string | null = null;
  if (sent > 0) {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const created = await createPairingCode(admin, auth.user.id, 5 * 60 * 1000, 'verify');
    if (created && created !== 'rate_limited') { shortCode = created.shortCode; expiresAt = created.expiresAt; }
  }
  return json({ sent, removed: expired.length, shortCode, expiresAt });
});
