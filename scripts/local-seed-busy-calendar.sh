#!/usr/bin/env bash
# Fills the LOCAL Bright Smile calendar (Kathmandu Main) with a realistic busy week so the calendar can be
# judged at real density: yesterday through +6 days, 6 dentists, mostly back-to-back days, double-bookings,
# a "+N" overflow cluster per day, a stacked Unassigned column, a shared (two-dentist) booking per day,
# patient alerts, special requests, referrals, discounts, payments and prior dues.
#
#   ./scripts/local-seed-busy-calendar.sh          # (re)seed; removes the previous busy seed first
#   ./scripts/local-seed-busy-calendar.sh --clean  # remove the busy seed only
#
# Everything it creates is tagged (customer emails @busy.seed.test, three fixed-id seed dentists), so it
# never touches other local data. Refuses to run against anything but the local stack.
set -euo pipefail

STATUS="$(supabase status -o env 2>/dev/null)"
DB_URL="$(echo "$STATUS" | grep '^DB_URL=' | cut -d= -f2- | tr -d '"')"
case "$DB_URL" in
  *127.0.0.1*|*localhost*) ;;
  *) echo "Refusing to run: DB does not look local." >&2; exit 1 ;;
esac

CLEAN_ONLY=false
[ "${1:-}" = "--clean" ] && CLEAN_ONLY=true

psql "$DB_URL" -v ON_ERROR_STOP=1 -q -v clean_only="$CLEAN_ONLY" <<'SQL'
BEGIN;

-- ── Remove the previous busy seed ──────────────────────────────────────────
CREATE TEMP TABLE _seed_dentists (id uuid) ON COMMIT DROP;
INSERT INTO _seed_dentists VALUES
  ('00000000-0000-0000-0000-0000000003a1'), ('00000000-0000-0000-0000-0000000003a2'), ('00000000-0000-0000-0000-0000000003a3');
CREATE TEMP TABLE _seed_bookings ON COMMIT DROP AS
  SELECT id FROM public.bookings
  WHERE customer_email LIKE '%@busy.seed.test' OR dentist_id IN (SELECT id FROM _seed_dentists)
  UNION SELECT booking_id FROM public.booking_dentists WHERE dentist_id IN (SELECT id FROM _seed_dentists);
DELETE FROM public.payments WHERE booking_id IN (SELECT id FROM _seed_bookings);
DELETE FROM public.booking_dentists WHERE booking_id IN (SELECT id FROM _seed_bookings);
DELETE FROM public.bookings WHERE id IN (SELECT id FROM _seed_bookings);
DELETE FROM public.customers WHERE email LIKE '%@busy.seed.test';
DELETE FROM public.dentists WHERE id IN (SELECT id FROM _seed_dentists);

\if :clean_only
  COMMIT;
  \echo 'Busy seed removed.'
  \quit
\endif

-- ── Helpers ────────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.pick(arr text[]) RETURNS text LANGUAGE sql AS
  $$ SELECT arr[1 + floor(random() * array_length(arr, 1))::int] $$;

-- One booking, the way the app writes it: snapshots, a booking_dentists row per dentist, a chair only
-- when that chair is free (chairs have capacity 1), a status that fits the clock, and payments.
CREATE FUNCTION pg_temp.seed_booking(p_date date, p_time time, p_treatment uuid, p_dentist uuid, p_shared uuid,
                                     p_customer uuid, p_chair uuid, p_manager uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  tr record; cu record; v_start timestamptz; v_end timestamptz; v_status public.booking_status;
  v_chair uuid := p_chair; v_disc numeric := 0; v_bid uuid; r float := random(); v_paid float := random();
BEGIN
  SELECT * INTO tr FROM public.treatments WHERE id = p_treatment;
  SELECT * INTO cu FROM public.customers WHERE id = p_customer;
  v_start := (p_date + p_time) AT TIME ZONE 'Asia/Kathmandu';
  v_end := v_start + tr.duration_minutes * interval '1 minute';

  IF v_end <= now() THEN
    v_status := CASE WHEN p_dentist IS NULL THEN 'No Show' WHEN r < 0.05 THEN 'No Show' WHEN r < 0.09 THEN 'Cancelled' ELSE 'Completed' END;
  ELSIF v_start <= now() THEN
    v_status := CASE WHEN p_dentist IS NULL THEN 'Confirmed' ELSE 'In-Progress' END;
  ELSE
    v_status := CASE WHEN r < 0.04 THEN 'Cancelled' WHEN r < 0.40 OR p_dentist IS NULL THEN 'Pending' ELSE 'Confirmed' END;
  END IF;

  IF v_chair IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.bookings b WHERE b.chair_id = v_chair AND b.status NOT IN ('Cancelled', 'No Show')
      AND tstzrange(b.start_datetime, b.end_datetime) && tstzrange(v_start, v_end)) THEN
    v_chair := NULL;
  END IF;

  IF random() < 0.08 THEN v_disc := round(tr.price_npr * 0.1); END IF;

  INSERT INTO public.bookings (
    branch_id, chair_id, treatment_id, dentist_id, customer_id, customer_name, customer_phone, customer_email,
    customer_gender, date, start_time, end_time, start_datetime, end_datetime, status, base_amount, discount_amount,
    final_amount, discount_status, discount_approved_by, discount_reason, special_requests, referred_by,
    cancellation_reason, treatment_name_snapshot, treatment_duration_snapshot, treatment_price_snapshot,
    dentist_name_snapshot, chair_name_snapshot, created_by)
  VALUES (
    '00000000-0000-0000-0000-000000000101', v_chair, tr.id, p_dentist, cu.id, cu.full_name, cu.phone, cu.email,
    cu.gender, p_date, p_time, p_time + tr.duration_minutes * interval '1 minute', v_start, v_end, v_status,
    tr.price_npr, v_disc, tr.price_npr - v_disc,
    CASE WHEN v_disc > 0 THEN 'approved' ELSE 'none' END::public.discount_status_enum,
    CASE WHEN v_disc > 0 THEN p_manager END, CASE WHEN v_disc > 0 THEN 'Loyal patient' END,
    CASE WHEN random() < 0.12 THEN pg_temp.pick(ARRAY['Needs numbing gel', 'Prefers a female assistant',
      'Running 10 min late, called ahead', 'Wants an estimate before starting', 'Bring previous X-rays',
      'Child is nervous, please go slow']) END,
    CASE WHEN random() < 0.10 THEN pg_temp.pick(ARRAY['Dr. Mahesh Pandey', 'Sita Thapa', 'Instagram',
      'Nepal Medical College', 'Office health camp']) END,
    CASE WHEN v_status = 'Cancelled' THEN 'Patient rescheduled' END,
    tr.name, tr.duration_minutes, tr.price_npr,
    (SELECT name FROM public.dentists WHERE id = p_dentist), (SELECT name FROM public.chairs WHERE id = v_chair),
    p_manager)
  RETURNING id INTO v_bid;

  INSERT INTO public.booking_dentists (booking_id, dentist_id, start_time, end_time)
  SELECT v_bid, x, p_time, p_time + tr.duration_minutes * interval '1 minute'
  FROM unnest(ARRAY[p_dentist, p_shared]) AS x WHERE x IS NOT NULL;

  -- Completed visits: ~70% paid in full, ~15% part-paid, ~15% left unpaid (these become "Prev. due").
  IF v_status = 'Completed' AND v_paid < 0.85 THEN
    INSERT INTO public.payments (booking_id, amount, payment_mode, recorded_by)
    VALUES (v_bid, CASE WHEN v_paid < 0.70 THEN tr.price_npr - v_disc ELSE round((tr.price_npr - v_disc) / 2) END,
            pg_temp.pick(ARRAY['Cash', 'Cash', 'eSewa', 'Khalti', 'Card']), p_manager);
  END IF;
END $$;

-- ── Seed ───────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_org      uuid := '00000000-0000-0000-0000-000000000001';
  v_branch   uuid := '00000000-0000-0000-0000-000000000101';
  v_manager  uuid := (SELECT id FROM public.users WHERE email = 'manager@clinicmd.test');
  v_today    date := (now() AT TIME ZONE 'Asia/Kathmandu')::date;
  v_dentists uuid[]; v_chairs uuid[]; v_treatments uuid[]; v_customers uuid[] := '{}';
  first_names text[] := ARRAY['Aarav','Sita','Bikash','Pooja','Rajesh','Anisha','Suman','Kritika','Prakash','Nisha',
    'Dipesh','Sabina','Roshan','Manisha','Sunil','Asmita','Kiran','Bina','Nabin','Sarina','Ramesh','Pratiksha',
    'Ashok','Srijana','Hari','Laxmi','Bibek','Rachana','Gopal','Sunita','Saroj','Mina'];
  last_names text[] := ARRAY['Shrestha','Thapa','Gurung','Tamang','Rai','Maharjan','Karki','Adhikari','Bhattarai',
    'Magar','Joshi','Pradhan','Bajracharya','Lama','Khadka','Shakya'];
  alerts text[] := ARRAY['Allergic to penicillin','Diabetic, check sugar before procedures','On blood thinners (warfarin)',
    'Very anxious, prefers numbing gel','Pregnant, second trimester','Latex allergy',
    'High blood pressure, monitor before anaesthesia'];
  d date; t time; tr uuid; dur int; n int; i int; j int; k int; seq int := 0; cust uuid;
BEGIN
  IF v_manager IS NULL THEN RAISE EXCEPTION 'manager@clinicmd.test not found: run scripts/local-create-test-users.sh first'; END IF;
  PERFORM setseed(0.42);

  INSERT INTO public.dentists (id, branch_id, org_id, name, gender, position, is_treatment_staff, display_order) VALUES
    ('00000000-0000-0000-0000-0000000003a1', v_branch, v_org, 'Dr. Prabin Rai',   'Male',   'Orthodontist', true, 10),
    ('00000000-0000-0000-0000-0000000003a2', v_branch, v_org, 'Dr. Smriti Joshi', 'Female', 'Dentist',      true, 11),
    ('00000000-0000-0000-0000-0000000003a3', v_branch, v_org, 'Kabita Lama',      'Female', 'Hygienist',    true, 12);

  SELECT array_agg(id ORDER BY display_order, name) INTO v_dentists
    FROM public.dentists WHERE branch_id = v_branch AND is_active AND is_treatment_staff IS NOT FALSE;
  SELECT array_agg(id ORDER BY name) INTO v_chairs FROM public.chairs WHERE branch_id = v_branch AND is_active IS NOT FALSE;
  SELECT array_agg(id ORDER BY name) INTO v_treatments FROM public.treatments WHERE org_id = v_org AND is_active;

  -- Patient pool (~20% with a medical alert), plus fresh patients created per day so "New" tags appear all week.
  FOR i IN 1..70 LOOP
    INSERT INTO public.customers (branch_id, org_id, full_name, phone, email, gender, notes)
    VALUES (v_branch, v_org, pg_temp.pick(first_names) || ' ' || pg_temp.pick(last_names),
            '98' || lpad(floor(random() * 100000000)::text, 8, '0'), 'p' || i || '@busy.seed.test',
            CASE WHEN random() < 0.5 THEN 'Male' ELSE 'Female' END,
            CASE WHEN random() < 0.2 THEN pg_temp.pick(alerts) END)
    RETURNING id INTO cust;
    v_customers := v_customers || cust;
  END LOOP;

  FOR k IN -1..6 LOOP
    d := v_today + k;

    -- Dentist columns: mostly back-to-back; ~12% double-booked; one 3-deep cluster per day ("+1" badge).
    FOR i IN 1..array_length(v_dentists, 1) LOOP
      t := time '10:00' + (floor(random() * 3) * 10)::int * interval '1 minute';
      LOOP
        tr := v_treatments[1 + floor(random() * array_length(v_treatments, 1))::int];
        SELECT duration_minutes INTO dur FROM public.treatments WHERE id = tr;
        EXIT WHEN t + dur * interval '1 minute' > time '20:00';
        -- Today is the busiest day: twice the double-bookings and a second 3-deep cluster.
        n := CASE WHEN random() < (CASE WHEN k = 0 THEN 0.25 ELSE 0.12 END) THEN 2 ELSE 1 END;
        IF i = 1 + (k + 2) % array_length(v_dentists, 1) AND t >= time '14:00' AND t < time '15:00' THEN n := 3; END IF;
        IF k = 0 AND i = 1 + (k + 4) % array_length(v_dentists, 1) AND t >= time '16:00' AND t < time '17:00' THEN n := 3; END IF;
        FOR j IN 1..n LOOP
          PERFORM pg_temp.seed_booking(d, t + (j - 1) * 10 * interval '1 minute',
            CASE WHEN j = 1 THEN tr ELSE v_treatments[1 + floor(random() * array_length(v_treatments, 1))::int] END,
            v_dentists[i],
            -- one shared two-dentist booking per day: the first dentist's late-morning visit
            CASE WHEN i = 1 AND j = 1 AND t >= time '11:00' AND t < time '12:00' THEN v_dentists[2] END,
            v_customers[1 + floor(random() * array_length(v_customers, 1))::int],
            v_chairs[1 + (seq % array_length(v_chairs, 1))], v_manager);
          seq := seq + 1;
        END LOOP;
        t := t + dur * interval '1 minute'
             + (ARRAY[0, 0, 0, 10, 10, 20, 30, 60])[1 + floor(random() * 8)::int] * interval '1 minute';
      END LOOP;
    END LOOP;

    -- Unassigned column: a stack of 4 walk-ins/phone requests at the same time, plus a few singles,
    -- mostly brand-new patients. Today gets two upcoming stacks (4 deep at 2:30pm, 3 deep at 5pm) and more singles.
    t := (ARRAY[time '11:00', time '12:30', time '15:00', time '16:30'])[1 + ((k + 1) % 4)];
    FOR j IN 1..(CASE WHEN k = 0 THEN 14 ELSE 7 END) LOOP
      INSERT INTO public.customers (branch_id, org_id, full_name, phone, email, gender)
      VALUES (v_branch, v_org, pg_temp.pick(first_names) || ' ' || pg_temp.pick(last_names),
              '98' || lpad(floor(random() * 100000000)::text, 8, '0'), 'n' || k || '-' || j || '@busy.seed.test',
              CASE WHEN random() < 0.5 THEN 'Male' ELSE 'Female' END)
      RETURNING id INTO cust;
      PERFORM pg_temp.seed_booking(d,
        CASE WHEN k = 0 AND j <= 4 THEN time '14:30' + (j - 1) * 5 * interval '1 minute'
             WHEN k = 0 AND j <= 7 THEN time '17:00' + (j - 5) * 10 * interval '1 minute'
             WHEN k <> 0 AND j <= 4 THEN t + (j - 1) * 5 * interval '1 minute'
             ELSE time '10:00' + (floor(random() * 54) * 10)::int * interval '1 minute' END,
        v_treatments[1 + floor(random() * array_length(v_treatments, 1))::int],
        NULL, NULL, cust, NULL, v_manager);
    END LOOP;
  END LOOP;
END $$;

COMMIT;

SELECT 'Busy seed: ' || count(*) || ' bookings, ' || count(DISTINCT date) || ' days ('
       || min(date) || ' to ' || max(date) || ')'
FROM public.bookings WHERE customer_email LIKE '%@busy.seed.test';
SQL
