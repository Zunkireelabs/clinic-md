# ClinicMD — Dental Booking Web App

ClinicMD is a dental clinic booking management SPA. Staff, managers, and admins manage
bookings, dentists, chairs, treatments, payments, and discounts across multiple branches;
patients book through an org-scoped public flow.

## Tech stack

- **React 18 + Vite 5** SPA (JSX, not TypeScript)
- **Tailwind CSS 3** with a custom design-token theme (`tailwind.config.js`)
- **Supabase** — Postgres, Auth, Row-Level Security, Realtime (separate staging & production
  projects)
- **React Router v6** (Context API for state — no Redux), **Framer Motion**, **date-fns**,
  **Recharts**, **@dnd-kit**, **FullCalendar**

## Getting started

```bash
npm install
cp .env.example .env   # defaults to the staging Supabase project
npm start              # dev server on http://localhost:4028
```

Only Supabase `anon` keys belong in `.env`. Never put a `service_role` key in any env file.

## Scripts

| Command | Description |
|---------|-------------|
| `npm start` | Vite dev server (port 4028) |
| `npm run build` | Production build → `build/` |
| `npm run serve` | Preview the production build |
| `npm test` | Vitest unit tests |

## Project layout

```
src/
├── components/   # Shared + ui/ reusable components
├── contexts/     # Auth → Org → Branch → AIAssistant (+ Tenant for customer routes)
├── lib/          # supabase.js client singleton
├── pages/        # Route pages (org-scoped: /:orgSlug/...)
├── services/     # api.js (state machine + mutations), transformers, enrichment
└── styles/       # Tailwind entry
supabase/         # schema.sql, rls.sql, seed.sql
```

## Database & deployment

Schema lives in a single consolidated `supabase/schema.sql` (+ `rls.sql` for policies, `seed.sql`
for dev data) rather than a numbered migration chain — apply changes directly to each Supabase
project via `psql -f supabase/schema.sql` (and `rls.sql`) as the schema evolves. Staging and
production are separate Supabase projects that share no data.

Git flow: `feature/*` → `stage` → `main`. `stage` deploys to staging, `main` to production.

## Doctor phone (consultation on a phone)

The consultation page (`/:orgSlug/bookings/:bookingId/consultation`) can run on a computer and a phone at the same time. Both edit one shared draft, so recordings, X-ray/clinical photos and notes show up on the other screen live.

**Using it**
1. On the computer, open a consultation and tap **Continue on phone** and scan the QR code. The phone is signed in as you automatically (the code is single-use and valid for 3 minutes) and opens the **Doctor phone** page. Only show the code to your own phone.
2. Add that page to the Home Screen (Share → Add to Home Screen on iPhone). The icon opens `/phone`.
3. From then on: tap the Doctor icon and it joins the patient who is In-Progress and starts recording (a short list if there are several). If the page is already open, starting a consultation on the computer opens it on the phone by itself.
4. Optional: on the Doctor phone page tap **Turn on notifications** (on iPhone this only works from the Home Screen icon). Starting a consultation on the computer then sends a "tap to record" notification.

**Local setup**

Phones only allow the microphone/camera/notifications on `https://` pages and cannot reach `127.0.0.1`:

1. `brew install cloudflared` (once).
2. `.env.local`:
   ```
   VITE_ENABLE_CONSULTATION=true
   VITE_SUPABASE_URL=/sb                                   # the dev server forwards /sb to local Supabase
   VITE_DEV_SUPABASE_PROXY_TARGET=http://127.0.0.1:54321
   VITE_VAPID_PUBLIC_KEY=<public key>                      # Web Push, from `npx web-push generate-vapid-keys`
   ```
3. `supabase/functions/.env` (gitignored; see `.env.example`): `OPENAI_API_KEY`, `GEMINI_API_KEY`, `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`. Then `supabase functions serve`.
4. Run `scripts/dev-phone.sh`: it starts a Cloudflare tunnel (a trusted `https://...trycloudflare.com` address), points the QR code at it, and starts the dev server. Use `http://localhost:4028` on the computer.

The tunnel address changes each run, and a phone's saved login belongs to the address it was opened on, so locally you scan again after a restart. On a deployed site with a fixed address it is one time. The tunnel is public while it runs, so use a strong password for the local staff login.
