# hub-inbound

The communication hub's inbound webhook (CMD-88, migration 013): `https://<project>.supabase.co/functions/v1/hub-inbound/<provider>[/<token>]`.
It is **public** (`verify_jwt = false` in `supabase/config.toml`) because SMS gateways carry no Supabase JWT, so **it authenticates each provider itself**.
It uses the service role only to call `hub_find_account`, `hub_rate_check`, `act_message_receive` and `hub_apply_delivery_status`.

## Providers

| Provider | Method and URL | How the request is authenticated | Env |
|---|---|---|---|
| `test` (local development) | `POST /hub-inbound/test`, JSON `{type:'inbound', from, to, text, id}` or `{type:'status', to, id, status: sent\|delivered\|read\|failed, error?}` | `x-hub-signature: sha256=<hex HMAC-SHA256 of the raw body>`, checked **before** the body is parsed | `HUB_TEST_WEBHOOK_SECRET` |
| `aakash` | `GET /hub-inbound/aakash/<token>?keyword=&from=&text=` (Aakash forwards an incoming SMS by GET) | **a secret path token only** (see below) | `<secret_ref>_INBOUND_TOKEN` per channel account |

## The Aakash limitation (read this before go-live)

Aakash's public docs describe incoming SMS as a plain GET push with `keyword`, `from` and `text`, and **document no signature or other verification**.
So an Aakash request cannot be verified the way a signed provider's can. What is done instead:

- the URL carries a long random token (generate with `openssl rand -hex 24`) that must equal the env variable named `<secret_ref>_INBOUND_TOKEN`
  of one connected Aakash channel account, compared in constant time against every account (no early exit); a missing, wrong or unknown token gets the
  same `404`;
- the channel account stores only the **name** of the variable (`secret_ref`), never a value; URLs, bodies and numbers are never logged;
- whoever holds the token can do **only** what `act_message_receive` does: add an inbound message to a thread for **the sending number**, and record
  STOP or START for **that same number**. It cannot send, read, change another number's consent, or touch any other table;
- it is rate limited per account (**60 per minute**); the rest are dropped and counted in `hub_inbound_rate.dropped`, and the gateway still gets a `200`;
- Aakash sends no message id, so a retry within the same minute is recognised by a keyed hash of sender, text and minute.

Anyone who learns the URL can still **spoof a patient's reply** (including a STOP) from any number, up to the rate limit. Treat the token like a password,
rotate it if it leaks, and ask Aakash whether they offer a signature or an IP list.

## Go-live checks for the Aakash adapter (it is NOT tested against the real API)

The adapter is built from Aakash's public docs (https://aakashsms.com/documentation/ and the v4 README on Bitbucket), which carry no date or version
and contradict themselves in places; its tests use mocked HTTP only. Sadin should check, on the real account:

1. a real send (v4 `send-user`, JSON body, `auth-token` header) and the shape of the answer;
2. a Nepali (Unicode) message: length limit, credits used, whether it is cut off (none of this is documented);
3. the delivery-report field names for v4 (`api-report`): the adapter matches on `id` and reads `status` / `delivery_at` tolerantly;
4. whether a `977` prefix is accepted on input (the adapter sends the 10-digit national form);
5. the inbound keyword / shortcode setup on Aakash's side and the exact forwarding URL they accept.
