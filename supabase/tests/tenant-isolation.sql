-- supabase/tests/tenant-isolation.sql
-- Tenant-isolation (row-level security) test. Run it against the LOCAL stack:   npm run test:rls
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tenant-isolation.sql
-- It creates its own temporary orgs, branches and users inside ONE transaction and ROLLS BACK at the end (nothing persists).
-- Exit code is non-zero when anything FAILs (a final RAISE), so it can gate CI or a migration rehearsal.
--
-- WHAT IT CHECKS
--  1. STATIC, every public table (listed from pg_class, so a new table is covered automatically):
--       a. RLS is ENABLED;
--       b. no permissive policy for authenticated/public mentions get_user_role() without org scoping
--          (org_id / get_user_org_id / branch_in_my_org / organizations), except the allow-list below;
--       c. no permissive policy for authenticated/public is just `true` (open to everyone), except the allow-list below.
--  2. DYNAMIC, two temporary orgs (A, B) seeded with rows in the tables we know how to seed. Every caller (admin, admin_viewer,
--     manager with TWO branches, staff, customer with no staff row, anonymous, and an admin of the OTHER org) must see 0 rows of
--     the other org and must be DENIED when trying to UPDATE / DELETE / INSERT another org's row. Own-org visible counts are printed
--     (OWN lines) so two runs (before / after a migration) can be diffed to prove nobody lost access to their own data.
--     Tables that exist but are not seeded here are listed as COVERAGE 'not seeded' (static checks still apply): add a seed below
--     when you add an org-scoped table.
-- Output lines:  PASS|FAIL|WARN|INFO | caller | subject | detail
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\pset footer off
BEGIN;

CREATE TEMP TABLE t_res  (kind text, caller text, subject text, status text, detail text);
CREATE TEMP TABLE t_seed (tbl text, pkcol text, pk text, org uuid);
CREATE TEMP TABLE t_actor(name text PRIMARY KEY, uid uuid, org uuid, db_role text);
GRANT ALL ON t_res, t_seed, t_actor TO PUBLIC;

-- ───────────────────────────── 1. STATIC CHECKS ─────────────────────────────
DO $static$
DECLARE
  r record;
  org_scoping constant text := 'get_user_org_id|org_id|branch_in_my_org|organizations|get_user_org|platform';
  -- (table, policy) pairs that are knowingly fine / knowingly open. Keep this list short and justified.
  allow_role_only constant text[] := ARRAY[
    'chairs|Staff can reorder branch chairs',        -- staff may only touch their OWN single branch (branch_id = get_user_branch_id())
    'dentists|Staff can reorder branch dentists'     -- same
  ];
  -- names-only public catalog: every signed-in user may READ treatment categories (patients see them while booking); writes are org-scoped
  allow_true_select constant text[] := ARRAY['treatment_categories|treatment_categories_select'];
BEGIN
  FOR r IN SELECT c.relname, c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relkind = 'r' ORDER BY c.relname LOOP
    INSERT INTO t_res VALUES ('STATIC', '-', r.relname, CASE WHEN r.relrowsecurity THEN 'PASS' ELSE 'FAIL' END,
                              CASE WHEN r.relrowsecurity THEN 'RLS enabled' ELSE 'RLS is DISABLED on a public table' END);
  END LOOP;

  FOR r IN SELECT tablename, policyname, cmd, roles, coalesce(qual,'') q, coalesce(with_check,'') w
           FROM pg_policies WHERE schemaname = 'public' AND permissive = 'PERMISSIVE'
             AND (roles && ARRAY['authenticated'::name, 'public'::name]) ORDER BY 1, 2 LOOP
    IF (r.q || ' ' || r.w) ~ 'get_user_role\(\)' AND (r.q || ' ' || r.w) !~ org_scoping
       AND NOT (r.tablename || '|' || r.policyname) = ANY (allow_role_only) THEN
      INSERT INTO t_res VALUES ('STATIC', '-', r.tablename || ' / ' || r.policyname, 'FAIL', 'role check without org scoping (' || r.cmd || ')');
    END IF;
    IF (nullif(r.q, '') IS NULL OR r.q = 'true') AND (nullif(r.w, '') IS NULL OR r.w = 'true') AND NOT (r.q = '' AND r.w = '')
       AND NOT (r.tablename || '|' || r.policyname) = ANY (allow_role_only || allow_true_select) THEN
      INSERT INTO t_res VALUES ('STATIC', '-', r.tablename || ' / ' || r.policyname, 'FAIL', 'policy is literally "true" for authenticated (' || r.cmd || ')');
    END IF;
  END LOOP;

  -- anon policies that accept anything (reported; the public booking flow needs anon INSERTs, so this is a WARN, not a FAIL)
  FOR r IN SELECT tablename, policyname, cmd FROM pg_policies WHERE schemaname = 'public' AND permissive = 'PERMISSIVE'
             AND roles && ARRAY['anon'::name] AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL') AND coalesce(with_check, qual) = 'true' LOOP
    INSERT INTO t_res VALUES ('STATIC', 'anon', r.tablename || ' / ' || r.policyname, 'WARN', 'anon ' || r.cmd || ' accepts any row (nothing ties it to an org/branch)');
  END LOOP;
END $static$;

-- ───────────────────────────── 2. SEED TWO TEMPORARY ORGS ─────────────────────────────
CREATE FUNCTION pg_temp.sd(p_tbl text, p_pkcol text, p_pk text, p_org uuid) RETURNS void LANGUAGE sql AS
$$ INSERT INTO t_seed VALUES (p_tbl, p_pkcol, p_pk, p_org) $$;

DO $seed$
DECLARE
  oa uuid := gen_random_uuid(); ob uuid := gen_random_uuid();
  a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid(); b1 uuid := gen_random_uuid();
  u_admin uuid := gen_random_uuid(); u_viewer uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_staff uuid := gen_random_uuid();
  u_cust uuid := gen_random_uuid(); u_adminb uuid := gen_random_uuid(); u_prac uuid := gen_random_uuid(); u_prac_nolink uuid := gen_random_uuid();
  bk_a1b uuid; bk_a1c uuid; ca_id uuid;
  has011 boolean := to_regprocedure('public.get_user_dentist_id()') IS NOT NULL;   -- migration-011 present? (the test also runs on a pre-011 copy)
  tr_a uuid; tr_b uuid; d_a1 uuid; d_a2 uuid; d_b uuid; c_a1 uuid; c_a2 uuid; c_b uuid; bk_a1 uuid; bk_a2 uuid; bk_b uuid;
  run_a1 uuid; run_a2 uuid; run_b uuid; x uuid; sfx text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  seq int := 0;
BEGIN
  INSERT INTO organizations (id, name, code, slug) VALUES (oa, 'RLS Test A', 'rlsa' || sfx, 'rls-a-' || sfx), (ob, 'RLS Test B', 'rlsb' || sfx, 'rls-b-' || sfx);
  PERFORM pg_temp.sd('organizations', 'id', oa::text, oa); PERFORM pg_temp.sd('organizations', 'id', ob::text, ob);
  -- migration-018 seeds agent_settings and playbooks for every new organization; the sections below were written for test orgs that start
  -- with none and seed their own, so clear them here. Section 3g tests the 018 seed on organizations of its own.
  DELETE FROM playbooks WHERE org_id IN (oa, ob); DELETE FROM agent_settings WHERE org_id IN (oa, ob);
  INSERT INTO branches (id, name, org_id) VALUES (a1, 'A1', oa), (a2, 'A2', oa), (b1, 'B1', ob);
  PERFORM pg_temp.sd('branches', 'id', a1::text, oa); PERFORM pg_temp.sd('branches', 'id', a2::text, oa); PERFORM pg_temp.sd('branches', 'id', b1::text, ob);

  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at) VALUES
    (u_admin,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-admin-' || sfx || '@test.invalid', now(), now()),
    (u_viewer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-viewer-' || sfx || '@test.invalid', now(), now()),
    (u_mgr,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-mgr-' || sfx || '@test.invalid', now(), now()),
    (u_staff,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-staff-' || sfx || '@test.invalid', now(), now()),
    (u_cust,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-cust-' || sfx || '@test.invalid', now(), now()),
    (u_adminb, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-adminb-' || sfx || '@test.invalid', now(), now()),
    (u_prac,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-prac-' || sfx || '@test.invalid', now(), now()),
    (u_prac_nolink, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-pracnl-' || sfx || '@test.invalid', now(), now());
  INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active) VALUES
    (u_admin,  'rls-admin-' || sfx || '@test.invalid',  'RLS admin A',  'admin',        a1, oa, true),
    (u_viewer, 'rls-viewer-' || sfx || '@test.invalid', 'RLS viewer A', 'admin_viewer', a1, oa, true),
    (u_mgr,    'rls-mgr-' || sfx || '@test.invalid',    'RLS mgr A',    'manager',      a1, oa, true),
    (u_staff,  'rls-staff-' || sfx || '@test.invalid',  'RLS staff A',  'staff',        a1, oa, true),
    (u_adminb, 'rls-adminb-' || sfx || '@test.invalid', 'RLS admin B',  'admin',        b1, ob, true);
  IF has011 THEN
    INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active) VALUES
      (u_prac,   'rls-prac-' || sfx || '@test.invalid',   'RLS practitioner A', 'practitioner', a1, oa, true),
      (u_prac_nolink, 'rls-pracnl-' || sfx || '@test.invalid', 'RLS practitioner A (no profile)', 'practitioner', a1, oa, true);
  END IF;
  INSERT INTO user_branches (user_id, branch_id) VALUES (u_mgr, a2); -- the manager works in TWO branches
  PERFORM pg_temp.sd('users', 'id', u_admin::text, oa); PERFORM pg_temp.sd('users', 'id', u_viewer::text, oa); PERFORM pg_temp.sd('users', 'id', u_mgr::text, oa);
  PERFORM pg_temp.sd('users', 'id', u_staff::text, oa); PERFORM pg_temp.sd('users', 'id', u_adminb::text, ob);
  PERFORM pg_temp.sd('user_branches', 'user_id', u_mgr::text, oa);
  IF has011 THEN PERFORM pg_temp.sd('users', 'id', u_prac::text, oa); PERFORM pg_temp.sd('users', 'id', u_prac_nolink::text, oa); END IF;

  INSERT INTO t_actor VALUES ('admin', u_admin, oa, 'authenticated'), ('admin_viewer', u_viewer, oa, 'authenticated'),
    ('manager_2_branches', u_mgr, oa, 'authenticated'), ('staff', u_staff, oa, 'authenticated'),
    ('customer_no_staff_row', u_cust, oa, 'authenticated'), ('anon', NULL, oa, 'anon'), ('admin_of_OTHER_org', u_adminb, ob, 'authenticated');
  IF has011 THEN INSERT INTO t_actor VALUES ('practitioner', u_prac, oa, 'authenticated'), ('practitioner_no_profile', u_prac_nolink, oa, 'authenticated'); END IF;

  -- treatments, dentists, customers
  INSERT INTO treatments (name, duration_minutes, price_npr, org_id) VALUES ('T A', 30, 1000, oa) RETURNING id INTO tr_a;
  INSERT INTO treatments (name, duration_minutes, price_npr, org_id) VALUES ('T B', 30, 1000, ob) RETURNING id INTO tr_b;
  PERFORM pg_temp.sd('treatments', 'id', tr_a::text, oa); PERFORM pg_temp.sd('treatments', 'id', tr_b::text, ob);
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (a1, 'Dr A1', 'Male', oa) RETURNING id INTO d_a1;
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (a2, 'Dr A2', 'Male', oa) RETURNING id INTO d_a2;
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (b1, 'Dr B', 'Male', ob) RETURNING id INTO d_b;
  PERFORM pg_temp.sd('dentists', 'id', d_a1::text, oa); PERFORM pg_temp.sd('dentists', 'id', d_a2::text, oa); PERFORM pg_temp.sd('dentists', 'id', d_b::text, ob);
  IF has011 THEN UPDATE public.users SET dentist_id = d_a1 WHERE id = u_prac; END IF;   -- the practitioner is Dr A1 (migration-011)
  INSERT INTO customers (branch_id, full_name, org_id) VALUES (a1, 'Cust A1', oa) RETURNING id INTO c_a1;
  INSERT INTO customers (branch_id, full_name, org_id) VALUES (a2, 'Cust A2', oa) RETURNING id INTO c_a2;
  INSERT INTO customers (branch_id, full_name, org_id) VALUES (b1, 'Cust B', ob) RETURNING id INTO c_b;
  PERFORM pg_temp.sd('customers', 'id', c_a1::text, oa); PERFORM pg_temp.sd('customers', 'id', c_a2::text, oa); PERFORM pg_temp.sd('customers', 'id', c_b::text, ob);
  INSERT INTO chairs (branch_id, name) VALUES (a1, 'Chair A1') RETURNING id INTO x; PERFORM pg_temp.sd('chairs', 'id', x::text, oa);
  INSERT INTO chairs (branch_id, name) VALUES (a2, 'Chair A2') RETURNING id INTO x; PERFORM pg_temp.sd('chairs', 'id', x::text, oa);
  INSERT INTO chairs (branch_id, name) VALUES (b1, 'Chair B') RETURNING id INTO x; PERFORM pg_temp.sd('chairs', 'id', x::text, ob);

  -- bookings + payments + refunds + notes
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount)
    VALUES (a1, tr_a, c_a1, 'Cust A1', '2031-01-10', '10:00', '10:30', '2031-01-10 10:00+00', '2031-01-10 10:30+00', 1000, 1000) RETURNING id INTO bk_a1;
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount)
    VALUES (a2, tr_a, c_a2, 'Cust A2', '2031-01-10', '11:00', '11:30', '2031-01-10 11:00+00', '2031-01-10 11:30+00', 1000, 1000) RETURNING id INTO bk_a2;
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount)
    VALUES (b1, tr_b, c_b, 'Cust B', '2031-01-10', '10:00', '10:30', '2031-01-10 10:00+00', '2031-01-10 10:30+00', 1000, 1000) RETURNING id INTO bk_b;
  PERFORM pg_temp.sd('bookings', 'id', bk_a1::text, oa); PERFORM pg_temp.sd('bookings', 'id', bk_a2::text, oa); PERFORM pg_temp.sd('bookings', 'id', bk_b::text, ob);
  -- practitioner cases (migration-011): bk_a1 is Dr A1's via booking_dentists; bk_a1b (branch A1) belongs to nobody; bk_a1c is Dr A1's via bookings.dentist_id only
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount)
    VALUES (a1, tr_a, c_a1, 'Cust A1', '2031-01-11', '10:00', '10:30', '2031-01-11 10:00+00', '2031-01-11 10:30+00', 1000, 1000) RETURNING id INTO bk_a1b;
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, dentist_id)
    VALUES (a1, tr_a, c_a1, 'Cust A1', '2031-01-12', '10:00', '10:30', '2031-01-12 10:00+00', '2031-01-12 10:30+00', 1000, 1000, d_a1) RETURNING id INTO bk_a1c;
  PERFORM pg_temp.sd('bookings', 'id', bk_a1b::text, oa); PERFORM pg_temp.sd('bookings', 'id', bk_a1c::text, oa);
  CREATE TEMP TABLE IF NOT EXISTS t_prac (k text PRIMARY KEY, v uuid); GRANT ALL ON t_prac TO PUBLIC;
  INSERT INTO t_prac VALUES ('bk_mine_bd', bk_a1), ('bk_nobody', bk_a1b), ('bk_mine_col', bk_a1c), ('d_a1', d_a1), ('d_a2', d_a2), ('d_b', d_b), ('c_a1', c_a1), ('bk_b', bk_b);
  -- a patient login for the NULL-role case: own booking + own org's voucher type
  INSERT INTO customer_accounts (org_id, auth_user_id, email, full_name, customer_id) VALUES (oa, u_cust, 'rls-cust-' || sfx || '@test.invalid', 'Cust A1', c_a1) RETURNING id INTO ca_id;
  UPDATE bookings SET customer_account_id = ca_id WHERE id = bk_a1b;
  INSERT INTO voucher_types (org_id, name, code_prefix) VALUES (oa, 'VT A', 'VA');
  INSERT INTO payments (booking_id, amount, payment_mode, recorded_by) VALUES (bk_a1, 100, 'Cash', u_admin) RETURNING id INTO x; PERFORM pg_temp.sd('payments', 'id', x::text, oa);
  INSERT INTO payments (booking_id, amount, payment_mode, recorded_by) VALUES (bk_a2, 100, 'Cash', u_admin) RETURNING id INTO x; PERFORM pg_temp.sd('payments', 'id', x::text, oa);
  INSERT INTO payments (booking_id, amount, payment_mode, recorded_by) VALUES (bk_b, 100, 'Cash', u_adminb) RETURNING id INTO x; PERFORM pg_temp.sd('payments', 'id', x::text, ob);
  INSERT INTO payment_refunds (booking_id, org_id, amount) VALUES (bk_a1, oa, 10) RETURNING id INTO x; PERFORM pg_temp.sd('payment_refunds', 'id', x::text, oa);
  INSERT INTO payment_refunds (booking_id, org_id, amount) VALUES (bk_b, ob, 10) RETURNING id INTO x; PERFORM pg_temp.sd('payment_refunds', 'id', x::text, ob);
  INSERT INTO treatment_notes (note, booking_id, customer_id, dentist_id) VALUES ('note A1', bk_a1, c_a1, d_a1) RETURNING id INTO x; PERFORM pg_temp.sd('treatment_notes', 'id', x::text, oa);
  INSERT INTO treatment_notes (note, booking_id, customer_id, dentist_id) VALUES ('note B', bk_b, c_b, d_b) RETURNING id INTO x; PERFORM pg_temp.sd('treatment_notes', 'id', x::text, ob);
  INSERT INTO booking_dentists (booking_id, dentist_id) VALUES (bk_a1, d_a1) RETURNING id INTO x; PERFORM pg_temp.sd('booking_dentists', 'id', x::text, oa);
  INSERT INTO booking_dentists (booking_id, dentist_id) VALUES (bk_b, d_b) RETURNING id INTO x; PERFORM pg_temp.sd('booking_dentists', 'id', x::text, ob);

  -- payroll, closing, attendance, audit
  INSERT INTO payroll_runs (branch_id, period_month) VALUES (a1, '2031-01-01') RETURNING id INTO run_a1; PERFORM pg_temp.sd('payroll_runs', 'id', run_a1::text, oa);
  INSERT INTO payroll_runs (branch_id, period_month) VALUES (a2, '2031-01-01') RETURNING id INTO run_a2; PERFORM pg_temp.sd('payroll_runs', 'id', run_a2::text, oa);
  INSERT INTO payroll_runs (branch_id, period_month) VALUES (b1, '2031-01-01') RETURNING id INTO run_b;  PERFORM pg_temp.sd('payroll_runs', 'id', run_b::text, ob);
  INSERT INTO payroll_items (payroll_run_id, dentist_id, dentist_name, days_in_month) VALUES (run_a1, d_a1, 'Dr A1', 31) RETURNING id INTO x; PERFORM pg_temp.sd('payroll_items', 'id', x::text, oa);
  INSERT INTO payroll_items (payroll_run_id, dentist_id, dentist_name, days_in_month) VALUES (run_a2, d_a2, 'Dr A2', 31) RETURNING id INTO x; PERFORM pg_temp.sd('payroll_items', 'id', x::text, oa);
  INSERT INTO payroll_items (payroll_run_id, dentist_id, dentist_name, days_in_month) VALUES (run_b, d_b, 'Dr B', 31) RETURNING id INTO x; PERFORM pg_temp.sd('payroll_items', 'id', x::text, ob);
  INSERT INTO staff_compensation (dentist_id) VALUES (d_a1), (d_a2), (d_b);
  PERFORM pg_temp.sd('staff_compensation', 'dentist_id', d_a1::text, oa); PERFORM pg_temp.sd('staff_compensation', 'dentist_id', d_a2::text, oa); PERFORM pg_temp.sd('staff_compensation', 'dentist_id', d_b::text, ob);
  INSERT INTO daily_reports (branch_id, report_date, closed_by) VALUES (a1, '2031-01-01', u_admin) RETURNING id INTO x; PERFORM pg_temp.sd('daily_reports', 'id', x::text, oa);
  INSERT INTO daily_reports (branch_id, report_date, closed_by) VALUES (a2, '2031-01-01', u_admin) RETURNING id INTO x; PERFORM pg_temp.sd('daily_reports', 'id', x::text, oa);
  INSERT INTO daily_reports (branch_id, report_date, closed_by) VALUES (b1, '2031-01-01', u_adminb) RETURNING id INTO x; PERFORM pg_temp.sd('daily_reports', 'id', x::text, ob);
  INSERT INTO dentist_attendance (branch_id, dentist_id, date) VALUES (a1, d_a1, '2031-01-01') RETURNING id INTO x; PERFORM pg_temp.sd('dentist_attendance', 'id', x::text, oa);
  INSERT INTO dentist_attendance (branch_id, dentist_id, date) VALUES (a2, d_a2, '2031-01-01') RETURNING id INTO x; PERFORM pg_temp.sd('dentist_attendance', 'id', x::text, oa);
  INSERT INTO dentist_attendance (branch_id, dentist_id, date) VALUES (b1, d_b, '2031-01-01') RETURNING id INTO x; PERFORM pg_temp.sd('dentist_attendance', 'id', x::text, ob);
  INSERT INTO audit_logs (table_name, action_type, branch_id) VALUES ('rls_test', 'test', a1) RETURNING id INTO x; PERFORM pg_temp.sd('audit_logs', 'id', x::text, oa);
  INSERT INTO audit_logs (table_name, action_type, branch_id) VALUES ('rls_test', 'test', a2) RETURNING id INTO x; PERFORM pg_temp.sd('audit_logs', 'id', x::text, oa);
  INSERT INTO audit_logs (table_name, action_type, branch_id) VALUES ('rls_test', 'test', b1) RETURNING id INTO x; PERFORM pg_temp.sd('audit_logs', 'id', x::text, ob);

  INSERT INTO treatment_categories (org_id, name) VALUES (oa, 'Cat A') RETURNING id INTO x; PERFORM pg_temp.sd('treatment_categories', 'id', x::text, oa);
  INSERT INTO treatment_categories (org_id, name) VALUES (ob, 'Cat B') RETURNING id INTO x; PERFORM pg_temp.sd('treatment_categories', 'id', x::text, ob);

  -- consultations (migration-006 tables) and notifications
  INSERT INTO consultations (org_id, branch_id, booking_id, patient_name) VALUES (oa, a1, bk_a1, 'Cust A1') RETURNING id INTO x; PERFORM pg_temp.sd('consultations', 'id', x::text, oa);
  INSERT INTO consultations (org_id, branch_id, booking_id, patient_name) VALUES (ob, b1, bk_b, 'Cust B') RETURNING id INTO x;  PERFORM pg_temp.sd('consultations', 'id', x::text, ob);
  INSERT INTO notifications (user_id, type, title) VALUES (u_admin, 'test', 'n A') RETURNING id INTO x; PERFORM pg_temp.sd('notifications', 'id', x::text, oa);
  INSERT INTO notifications (user_id, type, title) VALUES (u_adminb, 'test', 'n B') RETURNING id INTO x; PERFORM pg_temp.sd('notifications', 'id', x::text, ob);
END $seed$;

-- ───────────────────────────── 3. DYNAMIC MATRIX ─────────────────────────────
-- anon may read these by design (the public booking flow shows active clinics/chairs/dentists/treatments).
CREATE TEMP VIEW t_anon_public AS
  SELECT DISTINCT tablename FROM pg_policies WHERE schemaname = 'public' AND roles && ARRAY['anon'::name] AND cmd IN ('SELECT', 'ALL');
GRANT SELECT ON t_anon_public TO PUBLIC;
-- the public booking flow inserts as anon into bookings/customers by design (WARNed in the static section, not failed here)
CREATE TEMP VIEW t_anon_insert AS
  SELECT DISTINCT tablename FROM pg_policies WHERE schemaname = 'public' AND roles && ARRAY['anon'::name] AND cmd IN ('INSERT', 'ALL');
GRANT SELECT ON t_anon_insert TO PUBLIC;

DO $matrix$
DECLARE
  a record; t record; own_n bigint; other_n bigint; n bigint; rj jsonb; state text; has_id boolean;
  claims text; verdict text; emsg text := '';
BEGIN
  FOR a IN SELECT * FROM t_actor ORDER BY name LOOP
    claims := CASE WHEN a.uid IS NULL THEN '{"role":"anon"}' ELSE json_build_object('sub', a.uid, 'role', 'authenticated')::text END;
    FOR t IN SELECT DISTINCT tbl, pkcol FROM t_seed ORDER BY tbl LOOP
      -- other-org row (read as the table owner, before switching role) to attempt a cross-org INSERT with
      EXECUTE 'RESET ROLE';
      EXECUTE format('SELECT to_jsonb(x) FROM %I x JOIN t_seed s ON s.tbl = %L AND s.pk = x.%I::text AND s.org <> $1 LIMIT 1', t.tbl, t.tbl, t.pkcol) INTO rj USING a.org;
      has_id := rj ? 'id';
      EXECUTE format('SET LOCAL ROLE %I', a.db_role);
      PERFORM set_config('request.jwt.claims', claims, true);

      -- READ
      EXECUTE format('SELECT count(*) FILTER (WHERE s.org = $1), count(*) FILTER (WHERE s.org <> $1) FROM %I x JOIN t_seed s ON s.tbl = %L AND s.pk = x.%I::text', t.tbl, t.tbl, t.pkcol)
        INTO own_n, other_n USING a.org;
      verdict := CASE WHEN other_n = 0 THEN 'PASS'
                      WHEN a.db_role = 'anon' AND t.tbl IN (SELECT tablename FROM t_anon_public) THEN 'PASS'
                      WHEN t.tbl = 'treatment_categories' THEN 'PASS' ELSE 'FAIL' END;
      INSERT INTO t_res VALUES ('READ', a.name, t.tbl, verdict, format('other-org rows visible=%s%s', other_n, CASE WHEN verdict = 'PASS' AND other_n > 0 THEN ' (public by design)' ELSE '' END));
      INSERT INTO t_res VALUES ('OWN', a.name, t.tbl, 'INFO', format('own-org rows visible=%s', own_n));

      IF rj IS NULL THEN CONTINUE; END IF;

      -- UPDATE another org's rows
      n := -1; state := 'denied';
      BEGIN
        EXECUTE format('UPDATE %I x SET %I = x.%I WHERE x.%I::text IN (SELECT pk FROM t_seed WHERE tbl = %L AND org <> $1)', t.tbl, t.pkcol, t.pkcol, t.pkcol, t.tbl) USING a.org;
        GET DIAGNOSTICS n = ROW_COUNT;
        RAISE EXCEPTION 'rollback_test';
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'rollback_test' THEN n := -2; state := SQLSTATE; END IF;
      END;
      INSERT INTO t_res VALUES ('UPDATE', a.name, t.tbl, CASE WHEN n > 0 THEN 'FAIL' ELSE 'PASS' END, CASE WHEN n > 0 THEN format('updated %s other-org rows', n) WHEN n = -2 THEN 'error ' || state || ' (denied)' ELSE 'no rows updated' END);

      -- DELETE another org's rows
      n := -1; state := 'denied';
      BEGIN
        EXECUTE format('DELETE FROM %I x WHERE x.%I::text IN (SELECT pk FROM t_seed WHERE tbl = %L AND org <> $1)', t.tbl, t.pkcol, t.tbl) USING a.org;
        GET DIAGNOSTICS n = ROW_COUNT;
        RAISE EXCEPTION 'rollback_test';
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'rollback_test' THEN n := -2; state := SQLSTATE; END IF;
      END;
      INSERT INTO t_res VALUES ('DELETE', a.name, t.tbl, CASE WHEN n > 0 THEN 'FAIL' ELSE 'PASS' END, CASE WHEN n > 0 THEN format('deleted %s other-org rows', n) WHEN n = -2 THEN 'error ' || state || ' (denied)' ELSE 'no rows deleted' END);

      -- INSERT a copy of another org's row. The RLS WITH CHECK runs before constraint checks: 42501 = denied by policy; success or a
      -- constraint error (23xxx) = the policy PASSED the row; any other error (a trigger) is inconclusive.
      state := 'inserted';
      BEGIN
        IF has_id THEN rj := jsonb_set(rj, '{id}', to_jsonb(gen_random_uuid())); END IF;
        EXECUTE format('INSERT INTO %I SELECT * FROM jsonb_populate_record(NULL::%I, $1)', t.tbl, t.tbl) USING rj;
        RAISE EXCEPTION 'rollback_test';
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'rollback_test' THEN state := SQLSTATE; emsg := left(SQLERRM, 70); END IF;
      END;
      INSERT INTO t_res VALUES ('INSERT', a.name, t.tbl,
        CASE WHEN state = '42501' THEN 'PASS'
             WHEN a.db_role = 'anon' AND t.tbl IN (SELECT tablename FROM t_anon_insert) AND (state = 'inserted' OR state LIKE '23%') THEN 'WARN'
             WHEN state = 'inserted' OR state LIKE '23%' THEN 'FAIL' ELSE 'WARN' END,
        CASE WHEN state = '42501' THEN 'denied by RLS' WHEN state = 'inserted' THEN 'another org''s row was INSERTED' WHEN state LIKE '23%' THEN 'policy let the row through (stopped later by constraint ' || state || ')' ELSE 'inconclusive (' || state || ': ' || emsg || ')' END);
    END LOOP;
    EXECUTE 'RESET ROLE';
  END LOOP;
END $matrix$;

-- ───────────────────────────── 3b. FUNCTIONS (SECURITY DEFINER) ─────────────────────────────
-- Static: a SECURITY DEFINER function bypasses RLS, so who may EXECUTE it matters. Anon (anyone on the internet) may only run the
-- explicit public-booking allow-list; trigger functions must not be callable by anon/authenticated at all.
DO $fstatic$
DECLARE
  r record;
  public_allow constant text[] := ARRAY[
    'public_check_branch_bookings_range', 'public_check_customer_exists', 'public_check_slot_availability',
    'public_find_customer_match', 'public_get_booking_by_id', 'public_lookup_referrer_by_phone',
    'public_record_customer_referral', 'public_search_booking', 'find_customer_for_booking', 'upsert_customer_for_booking'
  ];
BEGIN
  FOR r IN SELECT p.oid::regprocedure::text AS sig, p.proname, (p.prorettype = 'trigger'::regtype) AS is_trigger,
                  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_x, has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_x,
                  coalesce(p.proacl::text, '') LIKE '%{=X/%' OR coalesce(p.proacl::text, '') LIKE '%,=X/%' AS public_x
           FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef ORDER BY p.proname LOOP
    INSERT INTO t_res VALUES ('FUNC', 'anon', r.sig,
      CASE WHEN r.anon_x AND NOT r.proname = ANY (public_allow) THEN 'FAIL' ELSE 'PASS' END,
      CASE WHEN r.anon_x AND r.proname = ANY (public_allow) THEN 'anon may execute (public booking allow-list)'
           WHEN r.anon_x THEN 'SECURITY DEFINER function EXECUTE-able by anon and not on the public allow-list'
           ELSE 'anon cannot execute' END);
    IF r.public_x THEN
      INSERT INTO t_res VALUES ('FUNC', 'PUBLIC', r.sig, 'FAIL', 'EXECUTE granted to PUBLIC (everyone)');
    END IF;
    IF r.is_trigger AND (r.anon_x OR r.auth_x) THEN
      INSERT INTO t_res VALUES ('FUNC', 'authenticated', r.sig, 'FAIL', 'trigger function callable by anon/authenticated');
    END IF;
  END LOOP;
  -- future-proofing: a new function must not be executable by anon/authenticated until granted explicitly
  IF EXISTS (SELECT 1 FROM pg_default_acl d WHERE d.defaclrole = 'postgres'::regrole AND d.defaclobjtype = 'f'
             AND d.defaclnamespace = 'public'::regnamespace AND d.defaclacl::text ~ '(anon|authenticated)=X')
     OR NOT EXISTS (SELECT 1 FROM pg_default_acl d WHERE d.defaclrole = 'postgres'::regrole AND d.defaclobjtype = 'f' AND d.defaclnamespace = 0) THEN
    INSERT INTO t_res VALUES ('FUNC', '-', 'default privileges', 'FAIL', 'new functions in public are still executable by anon/authenticated by default');
  ELSE
    INSERT INTO t_res VALUES ('FUNC', '-', 'default privileges', 'PASS', 'new functions in public are closed by default');
  END IF;
END $fstatic$;

-- Dynamic: call functions as each caller and classify the outcome. 'denied' = 42501 (no EXECUTE / not authorized);
-- 'raised:<SQLSTATE>' = the function's own check refused; 'ok:<n>' = it ran (n = rows or the scalar returned).
CREATE FUNCTION pg_temp.fn_try(p_actor text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE a record; claims text; res text := 'ok'; n bigint;
BEGIN
  SELECT * INTO a FROM t_actor WHERE name = p_actor;
  claims := CASE WHEN a.uid IS NULL THEN '{"role":"anon"}'
                 ELSE json_build_object('sub', a.uid, 'role', 'authenticated', 'email', (SELECT email FROM auth.users WHERE id = a.uid))::text END;
  BEGIN
    EXECUTE format('SET LOCAL ROLE %I', a.db_role);
    PERFORM set_config('request.jwt.claims', claims, true);
    EXECUTE p_sql;  -- (not wrapped in count(*): the planner drops unreferenced columns, which would skip the EXECUTE privilege check)
    GET DIAGNOSTICS n = ROW_COUNT;
    res := 'ok:' || n;
    RAISE EXCEPTION 'rollback_test';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'rollback_test' THEN res := CASE WHEN SQLSTATE = '42501' THEN 'denied' ELSE 'raised:' || SQLSTATE END; END IF;
  END;
  RETURN res;
END $$;

DO $fdyn$
DECLARE
  oa uuid; ob uuid; bk_a uuid; bk_b uuid; br_b uuid; cu_b uuid; cu_b2 uuid; ch_b uuid; dn_b uuid; no_b text; ph text := '+9779800000001';
  t record; r text;
BEGIN
  SELECT org INTO oa FROM t_actor WHERE name = 'admin';
  SELECT org INTO ob FROM t_actor WHERE name = 'admin_of_OTHER_org';
  SELECT pk::uuid INTO bk_a FROM t_seed WHERE tbl = 'bookings' AND org = oa LIMIT 1;
  SELECT pk::uuid INTO bk_b FROM t_seed WHERE tbl = 'bookings' AND org = ob LIMIT 1;
  SELECT pk::uuid INTO br_b FROM t_seed WHERE tbl = 'branches' AND org = ob LIMIT 1;
  SELECT pk::uuid INTO cu_b FROM t_seed WHERE tbl = 'customers' AND org = ob LIMIT 1;
  SELECT pk::uuid INTO ch_b FROM t_seed WHERE tbl = 'chairs' AND org = ob LIMIT 1;
  SELECT pk::uuid INTO dn_b FROM t_seed WHERE tbl = 'dentists' AND org = ob LIMIT 1;
  -- make the org-B booking "old" (public_get_booking_by_id only serves just-created bookings to outsiders) and give it a phone
  UPDATE bookings SET created_at = now() - interval '1 day', customer_phone = ph WHERE id = bk_b;
  SELECT booking_number INTO no_b FROM bookings WHERE id = bk_b;

  FOR t IN SELECT * FROM (VALUES
    -- (caller, label, sql, expectation: 'blocked' = denied or raised, 'zero' = 0 rows, 'rows' = at least 1 row and 'callable' = runs without error (must still work))
    ('anon', 'platform_org_sales_base(any org)',            format('SELECT platform_org_sales_base(%L, ''2030-01-01'', ''2032-01-01'')', ob), 'blocked'),
    ('anon', 'platform_org_branch_breakdown(any org)',      format('SELECT platform_org_branch_breakdown(%L, ''2030-01-01'', ''2032-01-01'')', ob), 'blocked'),
    ('anon', 'platform_get_revenue_rollup()',               'SELECT platform_get_revenue_rollup(''2030-01-01'', ''2032-01-01'')', 'blocked'),
    ('anon', 'outreach_ai_consume(any org)',                format('SELECT outreach_ai_consume(%L, 1)', ob), 'blocked'),
    ('anon', 'outreach_scan_winback()',                     'SELECT outreach_scan_winback()', 'blocked'),
    ('anon', 'outreach_drain_outbox()',                     'SELECT outreach_drain_outbox()', 'blocked'),
    ('anon', 'notify_outreach_review(any org)',             format('SELECT notify_outreach_review(%L)', ob), 'blocked'),
    ('anon', 'outreach_enqueue_for_completed(booking)',     format('SELECT outreach_enqueue_for_completed(%L)', bk_b), 'blocked'),
    ('anon', 'login_with_pin()',                            'SELECT login_with_pin(''a@b.c'', ''0000'', NULL)', 'blocked'),
    ('anon', 'verify_pin()',                                'SELECT verify_pin(''a@b.c'', ''0000'', NULL)', 'blocked'),
    ('anon', 'sync_booking_payment_status(booking)',        format('SELECT sync_booking_payment_status(%L)', bk_b), 'blocked'),
    ('anon', 'customer_duplicate_candidates(any org)',      format('SELECT * FROM customer_duplicate_candidates(%L)', ob), 'blocked'),
    ('anon', 'issue_voucher / issue_package (staff RPC)',   format('SELECT issue_package(%L, %L, gen_random_uuid(), NULL, ''x'', NULL, NULL, NULL, 1, 1, NULL)', ob, br_b), 'blocked'),
    ('anon', 'consume_ai_quota(any user)',                  'SELECT consume_ai_quota(gen_random_uuid(), 60)', 'blocked'),
    ('anon', 'phone_pairing_create(any user)',              'SELECT phone_pairing_create(gen_random_uuid(), ''h'', ''s'', ''verify'', now() + interval ''1 min'')', 'blocked'),
    ('authenticated: admin of org A', 'platform_org_sales_base(org B)',   format('SELECT platform_org_sales_base(%L, ''2030-01-01'', ''2032-01-01'')', ob), 'blocked'),
    ('authenticated: admin of org A', 'platform_get_org_bookings(org B)', format('SELECT platform_get_org_bookings(%L, ''2030-01-01'', ''2032-01-01'')', ob), 'blocked'),
    ('authenticated: admin of org A', 'outreach_ai_consume(org B)',       format('SELECT outreach_ai_consume(%L, 1)', ob), 'blocked'),
    ('authenticated: admin of org A', 'login_with_pin()',                 'SELECT login_with_pin(''a@b.c'', ''0000'', NULL)', 'blocked'),
    ('authenticated: admin of org A', 'outreach_enqueue_for_completed(org B booking)', format('SELECT outreach_enqueue_for_completed(%L)', bk_b), 'blocked'),
    ('authenticated: admin of org A', 'customer_duplicate_candidates(org B)', format('SELECT * FROM customer_duplicate_candidates(%L)', ob), 'blocked'),
    ('authenticated: admin of org A', 'issue_package(org B ids)',         format('SELECT issue_package(%L, %L, gen_random_uuid(), %L, NULL, NULL, NULL, NULL, 1, 1, NULL)', ob, br_b, cu_b), 'blocked'),
    ('authenticated: admin of org A', 'transfer_dentist(org B dentist)',  format('SELECT transfer_dentist(%L, %L, NULL, NULL, NULL, NULL, NULL, true)', dn_b, (SELECT pk::uuid FROM t_seed WHERE tbl = 'branches' AND org = oa LIMIT 1)), 'blocked'),
    ('authenticated: admin of org A', 'upsert_customer_for_booking(org B)', format('SELECT upsert_customer_for_booking(%L, %L, ''Evil'', ''+9779811111111'', NULL, NULL)', ob, br_b), 'blocked'),
    ('authenticated: admin of org A', 'merge_customers(org B customers)', format('SELECT merge_customers(%L, %L)', cu_b, cu_b), 'blocked'),
    ('authenticated: admin of org A', 'create_customer_account(someone else''s email)', format('SELECT create_customer_account(%L, ''victim@test.invalid'', ''1'', ''x'')', oa), 'blocked'),
    ('authenticated: admin of org A', 'public_get_booking_by_id(old org B booking)', format('SELECT * FROM public_get_booking_by_id(%L)', bk_b), 'zero'),
    ('authenticated: admin of org A', 'get_referral_credit_balance(org B customer)', format('SELECT 1 WHERE get_referral_credit_balance(%L) <> 0', cu_b), 'zero'),
    ('anon', 'public_get_booking_by_id(old booking)',                     format('SELECT * FROM public_get_booking_by_id(%L)', bk_b), 'zero'),
    ('anon', 'public_search_booking(partial booking number)',             format('SELECT * FROM public_search_booking(%L, ''BK-'')', br_b), 'zero'),
    ('anon', 'public_search_booking(partial phone)',                      format('SELECT * FROM public_search_booking(%L, %L)', br_b, right(ph, 4)), 'zero'),
    ('anon', 'public_search_booking(wildcard)',                           format('SELECT * FROM public_search_booking(%L, ''%%'')', br_b), 'zero'),
    ('anon', 'public_search_booking(exact booking number) still works',   format('SELECT * FROM public_search_booking(%L, %L)', br_b, no_b), 'rows'),
    ('anon', 'public_search_booking(exact phone) still works',            format('SELECT * FROM public_search_booking(%L, %L)', br_b, ph), 'rows'),
    ('anon', 'public_check_slot_availability still callable',             format('SELECT * FROM public_check_slot_availability(%L, ''2031-01-10'')', br_b), 'callable'),
    ('anon', 'upsert_customer_for_booking(branch of another org)',        format('SELECT upsert_customer_for_booking(%L, %L, ''Evil'', ''+9779822222222'', NULL, NULL)', oa, br_b), 'blocked'),
    ('anon', 'upsert_customer_for_booking(new patient) still works',      format('SELECT 1 WHERE upsert_customer_for_booking(%L, %L, ''New Patient'', ''+9779833333333'', NULL, NULL) IS NOT NULL', ob, br_b), 'rows'),
    ('admin_of_OTHER_org', 'public_get_booking_by_id(own old booking) still works', format('SELECT * FROM public_get_booking_by_id(%L)', bk_b), 'rows')
  ) AS v(caller, label, q, expect) LOOP
    r := pg_temp.fn_try(CASE t.caller WHEN 'authenticated: admin of org A' THEN 'admin' ELSE t.caller END, t.q);
    INSERT INTO t_res VALUES ('FUNCCALL', t.caller, t.label,
      CASE t.expect WHEN 'blocked' THEN CASE WHEN r = 'denied' OR r LIKE 'raised:%' THEN 'PASS' ELSE 'FAIL' END
                    WHEN 'zero'    THEN CASE WHEN r = 'ok:0' OR r = 'denied' THEN 'PASS' ELSE 'FAIL' END
                    WHEN 'callable' THEN CASE WHEN r LIKE 'ok:%' THEN 'PASS' ELSE 'FAIL' END
                    ELSE CASE WHEN r LIKE 'ok:%' AND r <> 'ok:0' THEN 'PASS' ELSE 'FAIL' END END,
      CASE t.expect WHEN 'blocked' THEN 'expected blocked; got ' || r WHEN 'zero' THEN 'expected 0 rows; got ' || r ELSE 'expected to still work; got ' || r END);
  END LOOP;
  EXECUTE 'RESET ROLE';
END $fdyn$;

-- ───────────────────────────── 3b. ACTION LAYER (migration-012) ─────────────────────────────
-- The booking actions (act_booking_set_status / reschedule / flag_not_confirmed / act_undo). Needs 011 (practitioner) and 012; otherwise skipped.
-- Callers: signed-in staff by role, a practitioner linked to Dr A1, the service role (agent / rule), anon, other-org admin, and
-- two forged calls (an authenticated session carrying a service_role JWT claim). The section seeds its own rows and removes them at the end.
CREATE FUNCTION pg_temp.act_chk(p_label text, p_ok boolean, p_detail text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO t_res VALUES ('ACT', '-', p_label, CASE WHEN COALESCE(p_ok, false) THEN 'PASS' ELSE 'FAIL' END, p_detail);
  -- a NOTICE survives even if the section later crashes (the t_res rows of a crashed block are rolled back with it)
  IF NOT COALESCE(p_ok, false) THEN RAISE NOTICE 'FAILED CHECK: % -- %', p_label, left(p_detail, 300); END IF;
END $$;

-- Runs one call as an actor, WITHOUT rolling back (the next call builds on it), and checks it wrote exactly p_expect action_log rows.
-- Actors: a t_actor name, 'service' (db role service_role + claim), 'forged' (authenticated + staff sub + a service_role CLAIM),
-- 'forged_nosub' (authenticated + only the service_role claim).
CREATE FUNCTION pg_temp.act_run(p_actor text, p_sql text, p_expect int DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; n0 bigint; n1 bigint; a record; claims text; dbrole text;
BEGIN
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO n0 FROM public.action_log;
  IF p_actor = 'service' THEN dbrole := 'service_role'; claims := '{"role":"service_role"}';
  ELSIF p_actor = 'forged' THEN dbrole := 'authenticated'; claims := json_build_object('sub', (SELECT uid FROM t_actor WHERE name = 'staff'), 'role', 'service_role')::text;
  ELSIF p_actor = 'forged_nosub' THEN dbrole := 'authenticated'; claims := '{"role":"service_role"}';
  ELSE
    SELECT * INTO a FROM t_actor WHERE name = p_actor; dbrole := a.db_role;
    claims := CASE WHEN a.uid IS NULL THEN '{"role":"anon"}' ELSE json_build_object('sub', a.uid, 'role', 'authenticated')::text END;
  END IF;
  EXECUTE format('SET LOCAL ROLE %I', dbrole);
  PERFORM set_config('request.jwt.claims', claims, true);
  BEGIN EXECUTE p_sql INTO r; EXCEPTION WHEN OTHERS THEN r := jsonb_build_object('raised', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO n1 FROM public.action_log;
  INSERT INTO t_res VALUES ('ACT', p_actor, 'rows written: ' || left(regexp_replace(p_sql, '\s+', ' ', 'g'), 70), CASE WHEN n1 - n0 = p_expect THEN 'PASS' ELSE 'FAIL' END,
                            format('expected %s new action_log row(s), got %s', p_expect, n1 - n0));
  RETURN r;
END $$;

CREATE FUNCTION pg_temp.act_code(r jsonb) RETURNS text LANGUAGE sql AS
$$ SELECT CASE WHEN r ? 'raised' THEN 'raised:' || (r ->> 'raised') WHEN (r ->> 'ok')::boolean THEN 'ok' ELSE r #>> '{error,code}' END $$;

DO $act$
DECLARE
  oa uuid; ob uuid; a1 uuid; tr uuid; cu uuid; d1 uuid; d1b uuid; cz uuid; bk record;
  u_prac uuid := gen_random_uuid(); u_staff uuid; u_adm uuid; u_adminb uuid; u_mgr uuid; sfx text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid; bR1 uuid; bR2 uuid; bR3 uuid; bD uuid; bPaid uuid; bX uuid; aCancelX uuid;
  r jsonb; r2 jsonb; l record; x_id uuid; tot bigint;
BEGIN
  IF to_regprocedure('public.act_undo(uuid,text,jsonb)') IS NULL OR to_regprocedure('public.is_my_booking_row(uuid,uuid)') IS NULL THEN
    INSERT INTO t_res VALUES ('ACT', '-', 'migration-011/012 checks', 'INFO', 'skipped: act_* (012) or the practitioner role (011) not present');
    RETURN;
  END IF;
  SELECT org, uid INTO oa, u_staff FROM t_actor WHERE name = 'staff';
  SELECT uid INTO u_adm FROM t_actor WHERE name = 'admin'; SELECT uid INTO u_mgr FROM t_actor WHERE name = 'manager_2_branches';
  SELECT org, uid INTO ob, u_adminb FROM t_actor WHERE name = 'admin_of_OTHER_org';
  SELECT s.pk::uuid INTO a1 FROM t_seed s JOIN branches b ON b.id = s.pk::uuid WHERE s.tbl = 'branches' AND s.org = oa AND b.name = 'A1';
  SELECT s.pk::uuid INTO tr FROM t_seed s WHERE s.tbl = 'treatments' AND s.org = oa LIMIT 1;
  SELECT s.pk::uuid INTO cu FROM t_seed s JOIN customers c ON c.id = s.pk::uuid WHERE s.tbl = 'customers' AND s.org = oa AND c.branch_id = a1 LIMIT 1;
  SELECT d.id INTO d1 FROM dentists d JOIN t_seed s ON s.tbl = 'dentists' AND s.pk = d.id::text WHERE d.branch_id = a1 AND d.name = 'Dr A1';

  -- a practitioner (Dr A1), a second dentist in the branch, a one-seat chair
  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at) VALUES (u_prac, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-actprac-' || sfx || '@test.invalid', now(), now());
  UPDATE public.users SET dentist_id = NULL WHERE id IN (SELECT uid FROM t_actor WHERE name = 'practitioner');   -- merge glue (CMD-79 + CMD-78): dentist_id is unique; the shared practitioner is re-linked at the start of section 3d
  INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active, dentist_id) VALUES (u_prac, 'rls-actprac-' || sfx || '@test.invalid', 'RLS act practitioner', 'practitioner', a1, oa, true, d1);
  INSERT INTO t_actor VALUES ('act_practitioner', u_prac, oa, 'authenticated');
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (a1, 'Dr A1b', 'Male', oa) RETURNING id INTO d1b;
  INSERT INTO chairs (branch_id, name, capacity) VALUES (a1, 'Chair Z', 1) RETURNING id INTO cz;

  -- bookings (org A, branch A1), spread over distinct days so no dentist / chair clash by accident
  FOR bk IN SELECT * FROM (VALUES
      ('b1', '2031-02-01', 'Pending',   NULL::uuid, NULL::uuid, 'unpaid'),
      ('b2', '2031-02-02', 'Pending',   NULL, NULL, 'unpaid'),
      ('b3', '2031-02-03', 'Confirmed', d1,   NULL, 'unpaid'),
      ('b4', '2031-02-04', 'Confirmed', d1b,  NULL, 'unpaid'),
      ('b5', '2031-02-05', 'Pending',   NULL, NULL, 'unpaid'),
      ('r1', '2031-02-06', 'Confirmed', NULL, cz,   'unpaid'),
      ('r2', '2031-02-06', 'Confirmed', NULL, NULL, 'unpaid'),
      ('d',  '2031-02-07', 'Confirmed', d1,   NULL, 'unpaid'),
      ('pd', '2031-02-08', 'Pending',   NULL, NULL, 'partial'),
      ('x',  '2031-02-09', 'Pending',   NULL, NULL, 'unpaid')) v(k, dt, st, den, ch, pay) LOOP
    INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, dentist_id, chair_id, payment_status)
      VALUES (a1, tr, cu, 'Cust A1', bk.dt::date, CASE WHEN bk.k = 'r2' THEN '11:00'::time ELSE '10:00'::time END, CASE WHEN bk.k = 'r2' THEN '11:30'::time ELSE '10:30'::time END,
              (bk.dt || ' ' || CASE WHEN bk.k = 'r2' THEN '11:00' ELSE '10:00' END || '+00')::timestamptz, (bk.dt || ' ' || CASE WHEN bk.k = 'r2' THEN '11:30' ELSE '10:30' END || '+00')::timestamptz,
              1000, 1000, bk.st::booking_status, bk.den, bk.ch, bk.pay)
      RETURNING id INTO x_id;
    IF bk.den IS NOT NULL THEN INSERT INTO booking_dentists (booking_id, dentist_id) VALUES (x_id, bk.den); END IF;
    CASE bk.k WHEN 'b1' THEN b1 := x_id; WHEN 'b2' THEN b2 := x_id; WHEN 'b3' THEN b3 := x_id; WHEN 'b4' THEN b4 := x_id; WHEN 'b5' THEN b5 := x_id;
              WHEN 'r1' THEN bR1 := x_id; WHEN 'r2' THEN bR2 := x_id; WHEN 'd' THEN bD := x_id; WHEN 'pd' THEN bPaid := x_id; WHEN 'x' THEN bX := x_id; END CASE;
  END LOOP;

  -- ── set_status: staff ──
  r := pg_temp.act_run('staff', format('SELECT public.act_booking_set_status(%L, ''Confirmed'')', b1));
  PERFORM pg_temp.act_chk('staff: Pending -> Confirmed works', pg_temp.act_code(r) = 'ok' AND (SELECT status FROM bookings WHERE id = b1) = 'Confirmed', 'got ' || coalesce(r::text, 'null'));
  SELECT * INTO l FROM action_log WHERE id = (r ->> 'action_id')::uuid;
  PERFORM pg_temp.act_chk('log row: actor is the signed-in person, action, target', l.actor_kind = 'person' AND l.actor_user_id = u_staff AND l.action = 'booking.set_status' AND l.target_id = b1 AND l.ok AND l.org_id = oa AND l.actor_agent IS NULL, row_to_json(l)::text);
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_set_status(%L, ''Completed'')', b1));
  PERFORM pg_temp.act_chk('staff: Confirmed -> Completed is refused (INVALID_STATUS_TRANSITION), and logged', pg_temp.act_code(r2) = 'INVALID_STATUS_TRANSITION' AND EXISTS (SELECT 1 FROM action_log WHERE id = (r2 ->> 'action_id')::uuid AND NOT ok AND error_code = 'INVALID_STATUS_TRANSITION'), 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_set_status(%L, ''Cancelled'')', b2));
  PERFORM pg_temp.act_chk('staff: cancelling without a reason is refused (REASON_REQUIRED)', pg_temp.act_code(r2) = 'REASON_REQUIRED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_booking_set_status(%L, ''Cancelled'', ''patient asked'')', b2));
  PERFORM pg_temp.act_chk('manager: cancel with a reason works and stores the reason', pg_temp.act_code(r2) = 'ok' AND (SELECT cancellation_reason FROM bookings WHERE id = b2) = 'patient asked', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_set_status(%L, ''Confirmed'')', b2));
  PERFORM pg_temp.act_chk('a Cancelled booking is immutable (BOOKING_IMMUTABLE)', pg_temp.act_code(r2) = 'BOOKING_IMMUTABLE', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_viewer', format('SELECT public.act_booking_set_status(%L, ''Confirmed'')', b5));
  PERFORM pg_temp.act_chk('admin_viewer cannot change a booking (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));

  -- cross-org, patients, anon
  r2 := pg_temp.act_run('admin_of_OTHER_org', format('SELECT public.act_booking_set_status(%L, ''Confirmed'')', b5));
  PERFORM pg_temp.act_chk('another org''s admin gets BOOKING_NOT_FOUND, the booking is untouched, and the refusal is logged in THEIR org', pg_temp.act_code(r2) = 'BOOKING_NOT_FOUND'
    AND (SELECT status FROM bookings WHERE id = b5) = 'Pending' AND (SELECT org_id FROM action_log WHERE id = (r2 ->> 'action_id')::uuid) = ob, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('customer_no_staff_row', format('SELECT public.act_booking_set_status(%L, ''Confirmed'')', b5), 0);
  PERFORM pg_temp.act_chk('a signed-in patient (no users row) is refused (FORBIDDEN), nothing logged', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('anon', format('SELECT public.act_booking_set_status(%L, ''Confirmed'')', b5), 0);
  PERFORM pg_temp.act_chk('anon cannot execute the action (permission denied)', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('anon', format('SELECT public.act_undo(%L)', gen_random_uuid()), 0);
  PERFORM pg_temp.act_chk('anon cannot execute act_undo', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));

  -- ── p_ctx: honoured for the service role only ──
  r := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Confirmed'', NULL, %L::jsonb)', b5, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa)));
  SELECT * INTO l FROM action_log WHERE id = (r ->> 'action_id')::uuid;
  PERFORM pg_temp.act_chk('service role: p_ctx honoured, logged as the agent (no user)', pg_temp.act_code(r) = 'ok' AND l.actor_kind = 'agent' AND l.actor_agent = 'follow_up' AND l.actor_user_id IS NULL AND l.org_id = oa, row_to_json(l)::text);
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_set_status(%L, ''Cancelled'', ''no'', %L::jsonb)', bX, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', ob, 'approved_by', u_adm)));
  SELECT * INTO l FROM action_log WHERE id = (r2 ->> 'action_id')::uuid;
  PERFORM pg_temp.act_chk('a user''s p_ctx is IGNORED: the same call as a signed-in user logs the user, not the agent', pg_temp.act_code(r2) = 'ok' AND l.actor_kind = 'person' AND l.actor_user_id = u_staff AND l.actor_agent IS NULL AND l.approved_by IS NULL AND l.org_id = oa AND (l.inputs ->> 'ctx_ignored')::boolean, row_to_json(l)::text);
  r2 := pg_temp.act_run('forged', format('SELECT public.act_booking_set_status(%L, ''Confirmed'', NULL, %L::jsonb)', b4, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa)));
  SELECT * INTO l FROM action_log WHERE id = (r2 ->> 'action_id')::uuid;
  PERFORM pg_temp.act_chk('forged: an authenticated session with a service_role JWT claim is still treated as the signed-in user', l.actor_kind = 'person' AND l.actor_agent IS NULL, 'got ' || coalesce(r2::text, 'null') || ' / ' || coalesce(row_to_json(l)::text, ''));
  r2 := pg_temp.act_run('forged_nosub', format('SELECT public.act_booking_set_status(%L, ''Confirmed'', NULL, %L::jsonb)', b5, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa)), 0);
  PERFORM pg_temp.act_chk('forged claim with no user: refused (FORBIDDEN), nothing logged', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Confirmed'')', b5), 0);
  PERFORM pg_temp.act_chk('service role without a p_ctx: INVALID_CONTEXT, nothing logged', pg_temp.act_code(r2) = 'INVALID_CONTEXT', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Confirmed'', NULL, %L::jsonb)', b5, jsonb_build_object('actor_kind', 'human', 'org_id', oa)), 0);
  PERFORM pg_temp.act_chk('service role with a bad actor_kind: INVALID_CONTEXT', pg_temp.act_code(r2) = 'INVALID_CONTEXT', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Cancelled'', ''x'', %L::jsonb)', bX, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa, 'approved_by', u_adminb)), 0);
  PERFORM pg_temp.act_chk('agent approved_by a user of ANOTHER org: INVALID_CONTEXT', pg_temp.act_code(r2) = 'INVALID_CONTEXT', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Confirmed'', NULL, %L::jsonb)', b1, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', ob)));
  PERFORM pg_temp.act_chk('agent for org B cannot touch an org A booking (BOOKING_NOT_FOUND)', pg_temp.act_code(r2) = 'BOOKING_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));

  -- ── agent rules (set_status) ──
  UPDATE bookings SET status = 'Confirmed' WHERE id = bX;   -- as owner, so the agent tests below start from a clean state
  UPDATE bookings SET status = 'Pending', cancellation_reason = NULL WHERE id = bX;   -- clear the 'no' left by the cancel above
  FOR l IN SELECT * FROM (VALUES ('No Show'), ('In-Progress'), ('Completed')) v(s) LOOP
    r2 := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, %L, ''x'', %L::jsonb)', bX, l.s, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa, 'approved_by', u_adm)));
    PERFORM pg_temp.act_chk('agent cannot set ' || l.s || ', even with approval (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  END LOOP;
  r2 := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Cancelled'', ''x'', %L::jsonb)', bX, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa)));
  PERFORM pg_temp.act_chk('agent cancel needs approval (APPROVAL_REQUIRED) without reason_source patient_reply', pg_temp.act_code(r2) = 'APPROVAL_REQUIRED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Cancelled'', ''x'', %L::jsonb)', bPaid, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa, 'reason_source', 'patient_reply')));
  PERFORM pg_temp.act_chk('agent cannot cancel a PAID / part-paid booking alone, even if the patient said no', pg_temp.act_code(r2) = 'APPROVAL_REQUIRED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Cancelled'', ''patient said no'', %L::jsonb)', bX, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa, 'reason_source', 'patient_reply')));
  PERFORM pg_temp.act_chk('agent cancels an UNPAID booking without approval when the patient said no', pg_temp.act_code(r2) = 'ok' AND (SELECT status FROM bookings WHERE id = bX) = 'Cancelled', 'got ' || coalesce(r2::text, 'null'));
  aCancelX := (r2 ->> 'action_id')::uuid;   -- undone below; picked by id because every created_at in this transaction is the same now()
  r := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Cancelled'', ''staff asked'', %L::jsonb)', bPaid, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa, 'approved_by', u_adm)));
  SELECT * INTO l FROM action_log WHERE id = (r ->> 'action_id')::uuid;
  PERFORM pg_temp.act_chk('agent cancel WITH approval works and logs approved_by', pg_temp.act_code(r) = 'ok' AND l.approved_by = u_adm AND l.actor_agent = 'follow_up', 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Confirmed'', NULL, %L::jsonb)', b3, jsonb_build_object('actor_kind', 'rule', 'org_id', oa)));
  PERFORM pg_temp.act_chk('a rule cannot change status (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));

  -- ── practitioner ──
  r2 := pg_temp.act_run('act_practitioner', format('SELECT public.act_booking_set_status(%L, ''In-Progress'')', b4));
  PERFORM pg_temp.act_chk('practitioner: another dentist''s booking is refused with a clear error (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN' AND r2 #>> '{error,message}' LIKE '%your own%', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('act_practitioner', format('SELECT public.act_booking_set_status(%L, ''In-Progress'')', bR2));
  PERFORM pg_temp.act_chk('practitioner: a booking with NO dentist is not theirs (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN' AND (SELECT status FROM bookings WHERE id = bR2) = 'Confirmed', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_set_status(%L, NULL)', b5));
  PERFORM pg_temp.act_chk('a NULL status is refused (INVALID_INPUT)', pg_temp.act_code(r2) = 'INVALID_INPUT', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('act_practitioner', format('SELECT public.act_booking_set_status(%L, ''Cancelled'', ''x'')', b3));
  PERFORM pg_temp.act_chk('practitioner: cannot cancel even their own booking (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('act_practitioner', format('SELECT public.act_booking_reschedule(%L, ''2031-03-01'', ''10:00'')', b3));
  PERFORM pg_temp.act_chk('practitioner: cannot reschedule (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('act_practitioner', format('SELECT public.act_booking_flag_not_confirmed(%L)', b5));
  PERFORM pg_temp.act_chk('practitioner: cannot flag (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r := pg_temp.act_run('act_practitioner', format('SELECT public.act_booking_set_status(%L, ''In-Progress'')', b3));
  PERFORM pg_temp.act_chk('practitioner: starts their OWN visit (Confirmed -> In-Progress)', pg_temp.act_code(r) = 'ok' AND (SELECT status FROM bookings WHERE id = b3) = 'In-Progress', 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('act_practitioner', format('SELECT public.act_undo(%L, ''oops'')', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('practitioner can undo their own status change', pg_temp.act_code(r2) = 'ok' AND (SELECT status FROM bookings WHERE id = b3) = 'Confirmed', 'got ' || coalesce(r2::text, 'null'));
  r := pg_temp.act_run('staff', format('SELECT public.act_booking_set_status(%L, ''In-Progress'')', bD));
  r2 := pg_temp.act_run('act_practitioner', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('practitioner cannot undo an action front desk ran, even on their own booking (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN' AND (SELECT status FROM bookings WHERE id = bD) = 'In-Progress', 'got ' || coalesce(r2::text, 'null'));
  UPDATE bookings SET status = 'Pending' WHERE id = b5;
  r := pg_temp.act_run('staff', format('SELECT public.act_booking_flag_not_confirmed(%L)', b5));
  r2 := pg_temp.act_run('act_practitioner', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('practitioner cannot undo a flag action (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));

  -- ── reschedule ──
  r := pg_temp.act_run('staff', format('SELECT public.act_booking_reschedule(%L, ''2031-02-10'', ''12:00'')', bR1));
  PERFORM pg_temp.act_chk('staff: reschedule works, end time from the treatment duration', pg_temp.act_code(r) = 'ok' AND (SELECT (date, start_time, end_time) FROM bookings WHERE id = bR1) = ('2031-02-10'::date, '12:00'::time, '12:30'::time), 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_reschedule(%L, ''2031-02-10'', ''12:00'', %L::jsonb)', bR2, jsonb_build_object('chair_id', cz)));
  PERFORM pg_temp.act_chk('reschedule into a chair that is not free is refused (CHAIR_CONFLICT)', pg_temp.act_code(r2) = 'CHAIR_CONFLICT', 'got ' || coalesce(r2::text, 'null'));
  -- chair cz is free at its old slot now (R1 moved away), so put R2 there; then undoing R1's move must be refused
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_reschedule(%L, ''2031-02-06'', ''10:00'', %L::jsonb)', bR2, jsonb_build_object('chair_id', cz)));
  PERFORM pg_temp.act_chk('...and the same move is fine once the chair is free', pg_temp.act_code(r2) = 'ok' AND (SELECT chair_id FROM bookings WHERE id = bR2) = cz, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('undo of a reschedule is refused when the old slot was taken (UNDO_BLOCKED)', pg_temp.act_code(r2) = 'UNDO_BLOCKED' AND (SELECT start_time FROM bookings WHERE id = bR1) = '12:00'::time, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_reschedule(%L, ''2031-02-11'', ''09:00'', %L::jsonb)', b4, jsonb_build_object('dentist_id', (SELECT s.pk FROM t_seed s WHERE s.tbl = 'dentists' AND s.org = ob LIMIT 1))));
  PERFORM pg_temp.act_chk('reschedule with ANOTHER org''s dentist is refused (INVALID_DENTIST)', pg_temp.act_code(r2) = 'INVALID_DENTIST', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_reschedule(%L, ''2031-02-11'', ''09:00'', %L::jsonb)', b4, jsonb_build_object('chair_id', (SELECT s.pk FROM t_seed s WHERE s.tbl = 'chairs' AND s.org = ob LIMIT 1))));
  PERFORM pg_temp.act_chk('reschedule with ANOTHER org''s chair is refused (INVALID_CHAIR)', pg_temp.act_code(r2) = 'INVALID_CHAIR', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_reschedule(%L, ''2031-02-11'', ''09:00'', ''{"dentist_id": "unassigned"}'')', b4));
  PERFORM pg_temp.act_chk('reschedule can clear the dentist ("unassigned"), and booking_dentists follows', pg_temp.act_code(r2) = 'ok' AND (SELECT dentist_id FROM bookings WHERE id = b4) IS NULL AND NOT EXISTS (SELECT 1 FROM booking_dentists WHERE booking_id = b4), 'got ' || coalesce(r2::text, 'null'));
  r := pg_temp.act_run('staff', format('SELECT public.act_undo(%L, ''back'')', r2 ->> 'action_id'));
  PERFORM pg_temp.act_chk('undo restores the old date, time, dentist and booking_dentists', pg_temp.act_code(r) = 'ok' AND (SELECT dentist_id FROM bookings WHERE id = b4) = d1b AND (SELECT date FROM bookings WHERE id = b4) = '2031-02-04'::date AND EXISTS (SELECT 1 FROM booking_dentists WHERE booking_id = b4 AND dentist_id = d1b), 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_booking_reschedule(%L, ''2031-02-12'', ''09:00'', ''{}'', %L::jsonb)', b4, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa)));
  PERFORM pg_temp.act_chk('agent reschedule needs approval (APPROVAL_REQUIRED)', pg_temp.act_code(r2) = 'APPROVAL_REQUIRED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_booking_reschedule(%L, ''2031-02-12'', ''09:00'', ''{}'', %L::jsonb)', b4, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa, 'approved_by', u_staff)));
  PERFORM pg_temp.act_chk('agent reschedule WITH approval works', pg_temp.act_code(r2) = 'ok' AND (SELECT date FROM bookings WHERE id = b4) = '2031-02-12'::date, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_reschedule(%L, ''2031-02-12'', ''09:00'')', bPaid));
  PERFORM pg_temp.act_chk('a cancelled (immutable) booking cannot be rescheduled', pg_temp.act_code(r2) = 'BOOKING_IMMUTABLE', 'got ' || coalesce(r2::text, 'null'));
  UPDATE bookings SET payment_status = 'paid' WHERE id = b1;   -- as owner
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_reschedule(%L, ''2031-02-12'', ''09:00'')', b1));
  PERFORM pg_temp.act_chk('a paid booking cannot be rescheduled', pg_temp.act_code(r2) = 'BOOKING_IMMUTABLE' AND r2 #>> '{error,message}' = 'Cannot reschedule a paid booking.', 'got ' || coalesce(r2::text, 'null'));
  UPDATE bookings SET payment_status = 'unpaid' WHERE id = b1;
  r2 := pg_temp.act_run('admin_of_OTHER_org', format('SELECT public.act_booking_reschedule(%L, ''2031-02-12'', ''09:00'')', b1));
  PERFORM pg_temp.act_chk('reschedule across orgs: BOOKING_NOT_FOUND', pg_temp.act_code(r2) = 'BOOKING_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));

  -- ── flag_not_confirmed ──
  r2 := pg_temp.act_run('service', format('SELECT public.act_booking_flag_not_confirmed(%L, ''6 pm rule'', %L::jsonb)', b2, jsonb_build_object('actor_kind', 'rule', 'org_id', oa)));
  PERFORM pg_temp.act_chk('a rule cannot flag a Cancelled booking (NOT_PENDING)', pg_temp.act_code(r2) = 'NOT_PENDING', 'got ' || coalesce(r2::text, 'null'));
  UPDATE bookings SET status = 'Pending' WHERE id = b5;
  UPDATE booking_flags SET cleared_at = now() WHERE booking_id = b5 AND cleared_at IS NULL;
  r := pg_temp.act_run('service', format('SELECT public.act_booking_flag_not_confirmed(%L, ''6 pm rule'', %L::jsonb)', b5, jsonb_build_object('actor_kind', 'rule', 'org_id', oa)));
  SELECT * INTO l FROM action_log WHERE id = (r ->> 'action_id')::uuid;
  PERFORM pg_temp.act_chk('a rule flags a Pending booking; logged as kind rule, one open flag', pg_temp.act_code(r) = 'ok' AND l.actor_kind = 'rule' AND (SELECT count(*) FROM booking_flags WHERE booking_id = b5 AND cleared_at IS NULL) = 1, 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_flag_not_confirmed(%L)', b5));
  PERFORM pg_temp.act_chk('flagging twice: ok, already_flagged, still one open flag', pg_temp.act_code(r2) = 'ok' AND (r2 #>> '{data,already_flagged}')::boolean AND (SELECT count(*) FROM booking_flags WHERE booking_id = b5 AND cleared_at IS NULL) = 1, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('undo of a flag clears it', pg_temp.act_code(r2) = 'ok' AND NOT EXISTS (SELECT 1 FROM booking_flags WHERE booking_id = b5 AND cleared_at IS NULL), 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_viewer', format('SELECT public.act_booking_flag_not_confirmed(%L)', b5));
  PERFORM pg_temp.act_chk('admin_viewer cannot flag (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  UPDATE bookings SET status = 'Confirmed' WHERE id = b5;
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_flag_not_confirmed(%L)', b5));
  PERFORM pg_temp.act_chk('only a Pending booking can be flagged (NOT_PENDING)', pg_temp.act_code(r2) = 'NOT_PENDING', 'got ' || coalesce(r2::text, 'null'));
  UPDATE bookings SET status = 'Pending' WHERE id = b5;

  -- ── undo ──
  r := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Confirmed'', NULL, %L::jsonb)', b5, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa)));
  r2 := pg_temp.act_run('service', format('SELECT public.act_undo(%L, ''x'', %L::jsonb)', r ->> 'action_id', jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa)));
  PERFORM pg_temp.act_chk('an agent cannot undo without approval (APPROVAL_REQUIRED)', pg_temp.act_code(r2) = 'APPROVAL_REQUIRED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_of_OTHER_org', format('SELECT public.act_undo(%L, ''x'')', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('undo across orgs: ACTION_NOT_FOUND', pg_temp.act_code(r2) = 'ACTION_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_viewer', format('SELECT public.act_undo(%L, ''x'')', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('admin_viewer cannot undo (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_undo(%L, ''front desk changed their mind'')', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('FRONT DESK can undo an AGENT''s action; status restored to the prior state directly (Confirmed -> Pending)', pg_temp.act_code(r2) = 'ok' AND (SELECT status FROM bookings WHERE id = b5) = 'Pending', 'got ' || coalesce(r2::text, 'null'));
  SELECT * INTO l FROM action_log WHERE id = (r ->> 'action_id')::uuid;
  PERFORM pg_temp.act_chk('the original row is stamped (undone_by_action, undone_reason) and the undo has its own row', l.undone_by_action = (r2 ->> 'action_id')::uuid AND l.undone_reason = 'front desk changed their mind'
    AND (SELECT action FROM action_log WHERE id = (r2 ->> 'action_id')::uuid) = 'undo' AND (SELECT actor_user_id FROM action_log WHERE id = (r2 ->> 'action_id')::uuid) = u_staff, row_to_json(l)::text);
  r2 := pg_temp.act_run('staff', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('a second undo is refused (UNDO_ALREADY)', pg_temp.act_code(r2) = 'UNDO_ALREADY', 'got ' || coalesce(r2::text, 'null'));

  r := pg_temp.act_run('staff', format('SELECT public.act_booking_set_status(%L, ''Confirmed'')', b5));
  -- anything else touching the booking afterwards. Inside this one test transaction now() never advances, so move updated_at by hand.
  ALTER TABLE public.bookings DISABLE TRIGGER trg_updated_at;
  UPDATE bookings SET special_requests = 'changed later', updated_at = now() + interval '1 second' WHERE id = b5;
  ALTER TABLE public.bookings ENABLE TRIGGER trg_updated_at;
  r2 := pg_temp.act_run('staff', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('undo after a later change is refused (UNDO_STALE)', pg_temp.act_code(r2) = 'UNDO_STALE' AND (SELECT status FROM bookings WHERE id = b5) = 'Confirmed', 'got ' || coalesce(r2::text, 'null'));

  r := pg_temp.act_run('staff', format('SELECT public.act_booking_set_status(%L, ''In-Progress'')', bD));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_booking_set_status(%L, ''Completed'')', bD));
  PERFORM pg_temp.act_chk('Pending..Completed path: Completed works', pg_temp.act_code(r2) = 'ok' AND (SELECT status FROM bookings WHERE id = bD) = 'Completed', 'got ' || coalesce(r2::text, 'null'));
  r := pg_temp.act_run('staff', format('SELECT public.act_undo(%L)', r2 ->> 'action_id'));
  PERFORM pg_temp.act_chk('Completed is NOT undoable (UNDO_NOT_POSSIBLE)', pg_temp.act_code(r) = 'UNDO_NOT_POSSIBLE', 'got ' || coalesce(r::text, 'null'));
  SELECT jsonb_build_object('action_id', id) INTO r2 FROM action_log WHERE target_id = bPaid AND action = 'booking.set_status' AND ok ORDER BY created_at DESC LIMIT 1;
  r := pg_temp.act_run('staff', format('SELECT public.act_undo(%L)', r2 ->> 'action_id'));
  PERFORM pg_temp.act_chk('cancelling a part-paid booking is NOT undoable (UNDO_NOT_POSSIBLE)', pg_temp.act_code(r) = 'UNDO_NOT_POSSIBLE', 'got ' || coalesce(r::text, 'null'));
  r2 := jsonb_build_object('action_id', aCancelX);
  r := pg_temp.act_run('staff', format('SELECT public.act_undo(%L, ''patient called back'')', r2 ->> 'action_id'));
  PERFORM pg_temp.act_chk('cancelling an UNPAID booking IS undoable, and the cancellation reason is restored', pg_temp.act_code(r) = 'ok' AND (SELECT status FROM bookings WHERE id = bX) = 'Pending' AND (SELECT cancellation_reason FROM bookings WHERE id = bX) IS NULL, 'got ' || coalesce(r::text, 'null'));
  -- the 24 h window
  r := pg_temp.act_run('staff', format('SELECT public.act_booking_set_status(%L, ''Confirmed'')', bX));
  ALTER TABLE public.action_log DISABLE TRIGGER trg_action_log_guard_row;   -- owner only; to age the stored undo
  UPDATE public.action_log SET undo = jsonb_set(undo, '{expires_at}', to_jsonb(now() - interval '1 minute')) WHERE id = (r ->> 'action_id')::uuid;
  ALTER TABLE public.action_log ENABLE TRIGGER trg_action_log_guard_row;
  r2 := pg_temp.act_run('staff', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('undo after the 24 h window is refused (UNDO_EXPIRED)', pg_temp.act_code(r2) = 'UNDO_EXPIRED', 'got ' || coalesce(r2::text, 'null'));

  -- ── action_log: nobody writes it directly; reads are scoped ──
  FOR l IN SELECT * FROM (VALUES ('staff'), ('admin'), ('act_practitioner'), ('service')) v(who) LOOP
    r2 := pg_temp.act_run(l.who, 'INSERT INTO public.action_log (org_id, action, actor_kind, ok) SELECT org_id, ''x'', ''person'', true FROM public.action_log LIMIT 1 RETURNING to_jsonb(action_log)', 0);
    PERFORM pg_temp.act_chk(l.who || ': direct INSERT into action_log is denied', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
    r2 := pg_temp.act_run(l.who, 'UPDATE public.action_log SET ok = ok RETURNING to_jsonb(action_log)', 0);
    PERFORM pg_temp.act_chk(l.who || ': direct UPDATE of action_log is denied', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
    r2 := pg_temp.act_run(l.who, 'DELETE FROM public.action_log RETURNING to_jsonb(action_log)', 0);
    PERFORM pg_temp.act_chk(l.who || ': direct DELETE from action_log is denied', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
  END LOOP;
  r2 := pg_temp.act_run('staff', 'INSERT INTO public.booking_flags (org_id, branch_id, booking_id, kind) SELECT org_id, branch_id, booking_id, ''not_confirmed'' FROM public.booking_flags LIMIT 1 RETURNING to_jsonb(booking_flags)', 0);
  PERFORM pg_temp.act_chk('staff: direct INSERT into booking_flags is denied', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
  BEGIN DELETE FROM public.action_log WHERE id = (SELECT id FROM public.action_log LIMIT 1); r2 := '{"deleted":true}'; EXCEPTION WHEN OTHERS THEN r2 := jsonb_build_object('raised', SQLSTATE); END;
  PERFORM pg_temp.act_chk('even the owner role cannot DELETE from action_log (append-only trigger)', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
  BEGIN UPDATE public.action_log SET inputs = '{}'::jsonb WHERE id = (SELECT id FROM public.action_log LIMIT 1); r2 := '{"updated":true}'; EXCEPTION WHEN OTHERS THEN r2 := jsonb_build_object('raised', SQLSTATE); END;
  PERFORM pg_temp.act_chk('even the owner role cannot rewrite an action_log row (only the undo stamp can be set)', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));

  SELECT count(*) INTO tot FROM action_log WHERE org_id = oa;
  r2 := pg_temp.act_run('admin_viewer', 'SELECT jsonb_build_object(''n'', count(*)) FROM public.action_log', 0);
  PERFORM pg_temp.act_chk('admin_viewer reads the whole org''s log', (r2 ->> 'n')::bigint = tot, format('saw %s of %s', r2 ->> 'n', tot));
  r2 := pg_temp.act_run('admin', 'SELECT jsonb_build_object(''n'', count(*)) FROM public.action_log', 0);
  PERFORM pg_temp.act_chk('admin reads the whole org''s log', (r2 ->> 'n')::bigint = tot, format('saw %s of %s', r2 ->> 'n', tot));
  r2 := pg_temp.act_run('staff', 'SELECT jsonb_build_object(''n'', count(*)) FROM public.action_log', 0);
  PERFORM pg_temp.act_chk('staff reads their branch''s log rows (some, and not the other org''s)', (r2 ->> 'n')::bigint > 0 AND (r2 ->> 'n')::bigint <= tot, format('saw %s of %s', r2 ->> 'n', tot));
  r2 := pg_temp.act_run('act_practitioner', 'SELECT jsonb_build_object(''n'', count(*), ''foreign'', count(*) FILTER (WHERE target_id NOT IN (SELECT id FROM public.bookings WHERE dentist_id = public.get_user_dentist_id()))) FROM public.action_log', 0);
  PERFORM pg_temp.act_chk('practitioner reads ONLY log rows about their own bookings', (r2 ->> 'n')::bigint > 0 AND (r2 ->> 'foreign')::bigint = 0 AND (r2 ->> 'n')::bigint < tot, format('saw %s, %s foreign, of %s', r2 ->> 'n', r2 ->> 'foreign', tot));
  r2 := pg_temp.act_run('admin_of_OTHER_org', 'SELECT jsonb_build_object(''n'', count(*), ''ours'', count(*) FILTER (WHERE org_id <> (SELECT org_id FROM public.users WHERE id = auth.uid()))) FROM public.action_log', 0);
  PERFORM pg_temp.act_chk('another org''s admin sees none of org A''s log', (r2 ->> 'ours')::bigint = 0, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('anon', 'SELECT jsonb_build_object(''n'', count(*)) FROM public.action_log', 0);
  PERFORM pg_temp.act_chk('anon cannot read the log', pg_temp.act_code(r2) = 'raised:42501' OR (r2 ->> 'n')::bigint = 0, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('act_practitioner', 'SELECT jsonb_build_object(''n'', count(*)) FROM public.booking_flags', 0);
  PERFORM pg_temp.act_chk('practitioner reads no booking_flags of bookings that are not theirs', (r2 ->> 'n')::bigint = 0, 'got ' || coalesce(r2::text, 'null'));

  -- clean up everything this section created (the action_log rows stay until the final ROLLBACK: the log is append-only)
  EXECUTE 'RESET ROLE';
  DELETE FROM booking_flags WHERE org_id = oa;
  DELETE FROM booking_dentists WHERE booking_id IN (b1, b2, b3, b4, b5, bR1, bR2, bD, bPaid, bX);
  DELETE FROM bookings WHERE id IN (b1, b2, b3, b4, b5, bR1, bR2, bD, bPaid, bX);
  DELETE FROM t_actor WHERE name = 'act_practitioner';
  DELETE FROM public.users WHERE id = u_prac;
  DELETE FROM auth.users WHERE id = u_prac;
  DELETE FROM dentists WHERE id = d1b;
  DELETE FROM chairs WHERE id = cz;
END $act$;

-- HUB-BEGIN
-- ───────────────────────────── 3b2. COMMUNICATION HUB (migration-013) ─────────────────────────────
-- Conversations, messages, consent, channel accounts and templates; the actions message.send / retry / receive and conversation.take_over / hand_back /
-- assign / handoff, consent.record; the sender and delivery-status functions; the consent backfill. Reuses pg_temp.act_run / act_chk / act_code from the
-- action-layer section above. Needs 011, 012 and 013, otherwise skipped. Seeds its own rows (two practitioners, a profile-holding manager, patients in
-- two branches and in the other org, accounts, templates) and removes them at the end.
DO $hub$
DECLARE
  oa uuid; ob uuid; a1 uuid; a2 uuid; b1 uuid; tr uuid; sfx text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  u_staff uuid; u_mgr uuid; u_adm uuid; u_viewer uuid; u_adminb uuid;
  u_p1 uuid := gen_random_uuid(); u_p2 uuid := gen_random_uuid(); u_prof uuid := gen_random_uuid(); u_staff2 uuid := gen_random_uuid(); u_staffb uuid;
  d1 uuid; d2 uuid; dprof uuid; pat1 uuid; pat2 uuid; pat3 uuid; pat4 uuid; patb uuid; bk1 uuid; bk2 uuid; bk3 uuid; bkx uuid;
  acc uuid; acc_wa uuid; acc_b uuid; acc_a2 uuid; acc_ak uuid; t_conf uuid; t_clin uuid; t_mkt uuid; t_bad uuid; t_ne uuid; t_conf_ne uuid;
  r jsonb; r2 jsonb; l record; n bigint; x_id uuid; conv1 uuid; conv2 uuid; convu uuid; convb uuid; m1 uuid; m2 uuid; lt time; v_when timestamptz;
  agent_ctx jsonb; rule_ctx jsonb; agent_appr jsonb; pat_ctx jsonb; patb_ctx jsonb; cnt_before bigint;
BEGIN
  IF to_regprocedure('public.act_message_send(uuid,uuid,text,uuid,text,jsonb,text,uuid,text,text,jsonb)') IS NULL OR to_regprocedure('public.act_undo(uuid,text,jsonb)') IS NULL THEN
    INSERT INTO t_res VALUES ('HUB', '-', 'migration-013 checks', 'INFO', 'skipped: the communication hub (013) is not present');
    RETURN;
  END IF;
  SELECT org, uid INTO oa, u_staff FROM t_actor WHERE name = 'staff';
  SELECT uid INTO u_mgr FROM t_actor WHERE name = 'manager_2_branches'; SELECT uid INTO u_adm FROM t_actor WHERE name = 'admin'; SELECT uid INTO u_viewer FROM t_actor WHERE name = 'admin_viewer';
  SELECT org, uid INTO ob, u_adminb FROM t_actor WHERE name = 'admin_of_OTHER_org';
  SELECT s.pk::uuid INTO a1 FROM t_seed s JOIN branches b ON b.id = s.pk::uuid WHERE s.tbl = 'branches' AND s.org = oa AND b.name = 'A1';
  SELECT s.pk::uuid INTO a2 FROM t_seed s JOIN branches b ON b.id = s.pk::uuid WHERE s.tbl = 'branches' AND s.org = oa AND b.name = 'A2';
  SELECT s.pk::uuid INTO b1 FROM t_seed s JOIN branches b ON b.id = s.pk::uuid WHERE s.tbl = 'branches' AND s.org = ob AND b.name = 'B1';
  SELECT s.pk::uuid INTO tr FROM t_seed s WHERE s.tbl = 'treatments' AND s.org = oa LIMIT 1;
  SELECT uid INTO u_staffb FROM t_actor WHERE name = 'admin_of_OTHER_org';
  agent_ctx := jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa);
  rule_ctx := jsonb_build_object('actor_kind', 'rule', 'org_id', oa);
  pat_ctx := jsonb_build_object('actor_kind', 'patient', 'org_id', oa);
  patb_ctx := jsonb_build_object('actor_kind', 'patient', 'org_id', ob);

  -- people: practitioner 1 (Dr A1x), practitioner 2 (Dr A1y), a MANAGER who also has a practitioner profile (Dr Owner), front desk of branch A2 only
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (a1, 'Dr Hub1', 'Male', oa) RETURNING id INTO d1;
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (a1, 'Dr Hub2', 'Female', oa) RETURNING id INTO d2;
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (a1, 'Dr Hub Owner', 'Male', oa) RETURNING id INTO dprof;
  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at) VALUES
    (u_p1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-hubp1-' || sfx || '@test.invalid', now(), now()),
    (u_p2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-hubp2-' || sfx || '@test.invalid', now(), now()),
    (u_prof, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-hubprof-' || sfx || '@test.invalid', now(), now()),
    (u_staff2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-hubs2-' || sfx || '@test.invalid', now(), now());
  UPDATE public.users SET dentist_id = NULL WHERE id IN (SELECT uid FROM t_actor WHERE name = 'practitioner');   -- merge glue (CMD-79 + CMD-78): dentist_id is unique; the shared practitioner is re-linked at the start of section 3d
  INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active, dentist_id) VALUES
    (u_p1, 'rls-hubp1-' || sfx || '@test.invalid', 'Hub Practitioner One', 'practitioner', a1, oa, true, d1),
    (u_p2, 'rls-hubp2-' || sfx || '@test.invalid', 'Hub Practitioner Two', 'practitioner', a1, oa, true, d2),
    (u_prof, 'rls-hubprof-' || sfx || '@test.invalid', 'Hub Owner Manager', 'manager', a1, oa, true, dprof),
    (u_staff2, 'rls-hubs2-' || sfx || '@test.invalid', 'Hub Front Desk A2', 'staff', a2, oa, true, NULL);
  INSERT INTO t_actor VALUES ('hub_p1', u_p1, oa, 'authenticated'), ('hub_p2', u_p2, oa, 'authenticated'), ('hub_prof', u_prof, oa, 'authenticated'), ('hub_staff_a2', u_staff2, oa, 'authenticated');

  -- patients (phones are unique per org) and bookings: pat1 sees Dr Hub1 and the owner, pat2 sees Dr Hub2, pat3 is a branch A2 patient, pat4 has no phone
  INSERT INTO customers (branch_id, full_name, org_id, phone, email) VALUES (a1, 'Hub Pat One', oa, '+9779801000001', NULL) RETURNING id INTO pat1;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Hub Pat Two', oa, '+9779801000002') RETURNING id INTO pat2;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a2, 'Hub Pat Three', oa, '+9779801000003') RETURNING id INTO pat3;
  INSERT INTO customers (branch_id, full_name, org_id) VALUES (a1, 'Hub Pat Four', oa) RETURNING id INTO pat4;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (b1, 'Hub Pat B', ob, '+9779801000009') RETURNING id INTO patb;
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, dentist_id, customer_phone)
    VALUES (a1, tr, pat1, 'Hub Pat One', current_date + 30, '10:00', '10:30', (current_date + 30)::timestamp + time '10:00', (current_date + 30)::timestamp + time '10:30', 1000, 1000, 'Confirmed', d1, '+9779801000001') RETURNING id INTO bk1;
  INSERT INTO booking_dentists (booking_id, dentist_id) VALUES (bk1, d1);
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, dentist_id)
    VALUES (a1, tr, pat1, 'Hub Pat One', current_date - 40, '10:00', '10:30', (current_date - 40)::timestamp + time '10:00', (current_date - 40)::timestamp + time '10:30', 1000, 1000, 'Completed', dprof) RETURNING id INTO bkx;
  INSERT INTO booking_dentists (booking_id, dentist_id) VALUES (bkx, dprof);
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, dentist_id)
    VALUES (a1, tr, pat2, 'Hub Pat Two', current_date + 31, '10:00', '10:30', (current_date + 31)::timestamp + time '10:00', (current_date + 31)::timestamp + time '10:30', 1000, 1000, 'Confirmed', d2) RETURNING id INTO bk2;
  INSERT INTO booking_dentists (booking_id, dentist_id) VALUES (bk2, d2);
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status)
    VALUES (a2, tr, pat3, 'Hub Pat Three', current_date + 32, '10:00', '10:30', (current_date + 32)::timestamp + time '10:00', (current_date + 32)::timestamp + time '10:30', 1000, 1000, 'Pending') RETURNING id INTO bk3;

  -- channel accounts (the test provider) and templates
  INSERT INTO channel_accounts (org_id, channel, provider, sender, status, priority, credit_cost_npr) VALUES (oa, 'sms', 'test', '+9779700' || substr(sfx, 1, 1) || '000001', 'connected', 100, 1.5) RETURNING id INTO acc;
  UPDATE channel_accounts SET sender = '+977970000' || lpad((random() * 9999)::int::text, 4, '0') WHERE id = acc;
  INSERT INTO channel_accounts (org_id, channel, provider, sender, status, priority) VALUES (ob, 'sms', 'test', '+977971' || lpad((random() * 999999)::int::text, 6, '0'), 'connected', 100) RETURNING id INTO acc_b;
  INSERT INTO message_templates (org_id, name, channel, language, body, purpose, clinical) VALUES
    (oa, 'confirm-' || sfx, NULL, 'en', 'Hi {patient_name}, your {treatment} at {clinic} is on {date} at {time}.', 'service', false) RETURNING id INTO t_conf;
  INSERT INTO message_templates (org_id, name, channel, language, body, purpose, clinical) VALUES
    (oa, 'confirm-' || sfx, NULL, 'ne', 'नमस्ते {patient_name}, {clinic} मा तपाईंको समय {date} {time} बजे हो।', 'service', false) RETURNING id INTO t_conf_ne;
  INSERT INTO message_templates (org_id, name, channel, language, body, purpose, clinical) VALUES
    (oa, 'followup-' || sfx, NULL, 'en', 'How is your {treatment} healing, {patient_name}?', 'service', true) RETURNING id INTO t_clin;
  INSERT INTO message_templates (org_id, name, channel, language, body, purpose, clinical) VALUES
    (oa, 'promo-' || sfx, NULL, 'en', 'Hi {patient_name}, this month at {clinic}: free check-up.', 'marketing', false) RETURNING id INTO t_mkt;
  INSERT INTO message_templates (org_id, name, channel, language, body, purpose, clinical) VALUES
    (oa, 'bad-' || sfx, NULL, 'en', 'Hi {patient_name}, {nonsense_field}.', 'service', false) RETURNING id INTO t_bad;

  -- consent as the backfill / front desk would have left it: pat1 and pat2 agreed to service SMS
  INSERT INTO patient_channels (org_id, customer_id, channel, address, purpose, status, source, evidence) VALUES
    (oa, pat1, 'sms', '+9779801000001', 'service', 'agreed', 'booking', 'Phone given when booking'),
    (oa, pat2, 'sms', '+9779801000002', 'service', 'agreed', 'booking', 'Phone given when booking')
  ON CONFLICT (org_id, channel, address, purpose) DO NOTHING;   -- 015's booking trigger may already have recorded these (same values)
  DELETE FROM patient_channels WHERE customer_id = pat3;          -- pat3 is the 'no consent yet' patient: remove the row 015's booking trigger recorded for her booking

  -- ═══ message.send ═══
  r := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L)', pat1, t_conf, bk1));
  m1 := (r #>> '{data,message_id}')::uuid; conv1 := (r #>> '{data,conversation_id}')::uuid;
  PERFORM pg_temp.act_chk('send: staff sends a template to a patient with consent: queued, one log row', pg_temp.act_code(r) = 'ok' AND (SELECT status FROM messages WHERE id = m1) = 'queued'
    AND (SELECT provider FROM messages WHERE id = m1) = 'test' AND (SELECT author_kind FROM messages WHERE id = m1) = 'person' AND (SELECT action_id FROM messages WHERE id = m1) = (r ->> 'action_id')::uuid, 'got ' || coalesce(r::text, 'null'));
  PERFORM pg_temp.act_chk('send: the fields are filled by code from the booking (no literal {x} left)', (SELECT body FROM messages WHERE id = m1) LIKE 'Hi Hub Pat One, your %' AND (SELECT body FROM messages WHERE id = m1) NOT LIKE '%{%', (SELECT body FROM messages WHERE id = m1));
  PERFORM pg_temp.act_chk('send: a new thread is created for the patient, in their branch, handled by the sender', (SELECT (customer_id, branch_id, state, handled_by, channel) FROM conversations WHERE id = conv1) = (pat1, a1, 'person'::text, u_staff, 'sms'::text), (SELECT row_to_json(c)::text FROM conversations c WHERE id = conv1));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_template => %L)', pat1, t_bad));
  PERFORM pg_temp.act_chk('send: a placeholder with no value is refused (TEMPLATE_FIELD_MISSING), nothing queued', pg_temp.act_code(r2) = 'TEMPLATE_FIELD_MISSING' AND (SELECT count(*) FROM messages WHERE conversation_id = conv1 AND kind = 'message') = 1, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat3));
  PERFORM pg_temp.act_chk('send: another branch''s patient is not found for front desk (PATIENT_NOT_FOUND)', pg_temp.act_code(r2) = 'PATIENT_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat3));
  PERFORM pg_temp.act_chk('send: no consent yet is refused (NO_CONSENT)', pg_temp.act_code(r2) = 'NO_CONSENT', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat4));
  PERFORM pg_temp.act_chk('send: a patient with no phone (NO_ADDRESS)', pg_temp.act_code(r2) = 'NO_ADDRESS', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_template => %L)', pat1, t_mkt));
  PERFORM pg_temp.act_chk('send: marketing needs its own explicit agreement (NO_CONSENT)', pg_temp.act_code(r2) = 'NO_CONSENT', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'', p_channel => ''whatsapp'')', pat1));
  PERFORM pg_temp.act_chk('send: a channel with no connected account (CHANNEL_NOT_CONNECTED)', pg_temp.act_code(r2) = 'CHANNEL_NOT_CONNECTED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L)', pat1));
  PERFORM pg_temp.act_chk('send: neither text nor template (INVALID_INPUT)', pg_temp.act_code(r2) = 'INVALID_INPUT', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_viewer', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat1));
  PERFORM pg_temp.act_chk('send: admin_viewer cannot send (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_of_OTHER_org', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat1));
  PERFORM pg_temp.act_chk('send: another org''s admin cannot reach this patient (PATIENT_NOT_FOUND), logged in THEIR org', pg_temp.act_code(r2) = 'PATIENT_NOT_FOUND'
    AND (SELECT org_id FROM action_log WHERE id = (r2 ->> 'action_id')::uuid) = ob, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_of_OTHER_org', format('SELECT public.act_message_send(p_conversation => %L, p_text => ''Hello'')', conv1));
  PERFORM pg_temp.act_chk('send: another org''s conversation id (CONVERSATION_NOT_FOUND)', pg_temp.act_code(r2) = 'CONVERSATION_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('anon', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat1), 0);
  PERFORM pg_temp.act_chk('send: anon cannot execute it', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('customer_no_staff_row', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat1), 0);
  PERFORM pg_temp.act_chk('send: a signed-in patient (no users row) is refused (FORBIDDEN), nothing logged', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_language => ''ne'', p_booking => %L)', pat1, t_conf, bk1));
  PERFORM pg_temp.act_chk('send: the Nepali version of a template is used when asked for', pg_temp.act_code(r2) = 'ok' AND (SELECT body FROM messages WHERE id = (r2 #>> '{data,message_id}')::uuid) LIKE 'नमस्ते Hub Pat One%'
    AND (SELECT language FROM messages WHERE id = (r2 #>> '{data,message_id}')::uuid) = 'ne', 'got ' || coalesce(r2::text, 'null'));

  -- who sends what: the clinical rule, agents, rules, practitioners
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L)', pat1, t_clin, bk1));
  PERFORM pg_temp.act_chk('clinical: front desk cannot send a clinical template (CLINICAL_TEMPLATE)', pg_temp.act_code(r2) = 'CLINICAL_TEMPLATE', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L)', pat1, t_clin, bk1));
  PERFORM pg_temp.act_chk('clinical: neither can an admin without a practitioner profile', pg_temp.act_code(r2) = 'CLINICAL_TEMPLATE', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p1', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L)', pat1, t_clin, bk1));
  PERFORM pg_temp.act_chk('clinical: the practitioner of this patient can', pg_temp.act_code(r2) = 'ok', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p1', format('SELECT public.act_message_send(p_customer => %L, p_template => %L)', pat2, t_clin));
  PERFORM pg_temp.act_chk('clinical: a practitioner cannot reach another practitioner''s patient (PATIENT_NOT_FOUND)', pg_temp.act_code(r2) = 'PATIENT_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_prof', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L)', pat1, t_clin, bkx));
  PERFORM pg_temp.act_chk('clinical: a MANAGER with a practitioner profile can, to their own patient', pg_temp.act_code(r2) = 'ok', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_prof', format('SELECT public.act_message_send(p_customer => %L, p_template => %L)', pat2, t_clin));
  PERFORM pg_temp.act_chk('clinical: ...but not to a patient who is not theirs (CLINICAL_TEMPLATE)', pg_temp.act_code(r2) = 'CLINICAL_TEMPLATE', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_ctx => %L::jsonb)', pat1, t_clin, agent_ctx || jsonb_build_object('approved_by', u_adm)));
  PERFORM pg_temp.act_chk('clinical: an agent never sends one, even with approval (CLINICAL_TEMPLATE)', pg_temp.act_code(r2) = 'CLINICAL_TEMPLATE', 'got ' || coalesce(r2::text, 'null'));
  r := pg_temp.act_run('service', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L, p_ctx => %L::jsonb)', pat1, t_conf, bk1, agent_ctx));
  SELECT * INTO l FROM action_log WHERE id = (r ->> 'action_id')::uuid;
  PERFORM pg_temp.act_chk('agent: a service message from a template needs no approval; logged as the agent', pg_temp.act_code(r) = 'ok' AND l.actor_kind = 'agent' AND l.actor_agent = 'follow_up'
    AND (SELECT author_kind FROM messages WHERE id = (r #>> '{data,message_id}')::uuid) = 'agent', 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Free text'', p_ctx => %L::jsonb)', pat1, agent_ctx));
  PERFORM pg_temp.act_chk('agent: free text needs approval (APPROVAL_REQUIRED)', pg_temp.act_code(r2) = 'APPROVAL_REQUIRED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Free text'', p_ctx => %L::jsonb)', pat1, agent_ctx || jsonb_build_object('approved_by', u_adm)));
  PERFORM pg_temp.act_chk('agent: free text with approval works, and logs approved_by', pg_temp.act_code(r2) = 'ok' AND (SELECT approved_by FROM action_log WHERE id = (r2 ->> 'action_id')::uuid) = u_adm, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_ctx => %L::jsonb)', pat1, t_mkt, agent_ctx));
  PERFORM pg_temp.act_chk('agent: marketing needs approval (APPROVAL_REQUIRED)', pg_temp.act_code(r2) = 'APPROVAL_REQUIRED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hi'', p_ctx => %L::jsonb)', pat1, rule_ctx));
  PERFORM pg_temp.act_chk('rule: free text is refused (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L, p_ctx => %L::jsonb)', pat1, t_conf, bk1, rule_ctx));
  PERFORM pg_temp.act_chk('rule: a service template works', pg_temp.act_code(r2) = 'ok', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p1', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L)', pat1, t_conf, bk1));
  PERFORM pg_temp.act_chk('practitioner: a service template to their own patient works', pg_temp.act_code(r2) = 'ok', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('forged', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hi'', p_ctx => %L::jsonb)', pat1, agent_ctx));
  SELECT * INTO l FROM action_log WHERE id = (r2 ->> 'action_id')::uuid;
  PERFORM pg_temp.act_chk('forged service_role claim: logged as the signed-in person, p_ctx ignored', l.actor_kind = 'person' AND l.actor_agent IS NULL, row_to_json(l)::text);

  -- fallback order and per-branch accounts
  INSERT INTO channel_accounts (org_id, channel, provider, sender, status, priority) VALUES (oa, 'whatsapp', 'test', '+977972' || lpad((random() * 999999)::int::text, 6, '0'), 'connected', 10) RETURNING id INTO acc_wa;
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat1));
  PERFORM pg_temp.act_chk('fallback: whatsapp comes first by priority but has no consent, so sms is used', pg_temp.act_code(r2) = 'ok' AND r2 #>> '{data,channel}' = 'sms', 'got ' || coalesce(r2::text, 'null'));
  INSERT INTO patient_channels (org_id, customer_id, channel, address, purpose, status, source, evidence) VALUES (oa, pat1, 'whatsapp', '+9779801000001', 'service', 'agreed', 'front_desk', 'Agreed at the front desk');
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat1));
  PERFORM pg_temp.act_chk('fallback: once whatsapp is agreed, the lower priority number wins', pg_temp.act_code(r2) = 'ok' AND r2 #>> '{data,channel}' = 'whatsapp', 'got ' || coalesce(r2::text, 'null'));
  UPDATE channel_accounts SET status = 'not_connected' WHERE id = acc_wa;
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat1));
  PERFORM pg_temp.act_chk('fallback: a not-connected account is skipped', pg_temp.act_code(r2) = 'ok' AND r2 #>> '{data,channel}' = 'sms', 'got ' || coalesce(r2::text, 'null'));
  INSERT INTO channel_accounts (org_id, branch_id, channel, provider, sender, status, priority) VALUES (oa, a2, 'whatsapp', 'test', '+977973' || lpad((random() * 999999)::int::text, 6, '0'), 'connected', 1) RETURNING id INTO acc_a2;
  UPDATE channel_accounts SET status = 'connected' WHERE id = acc_wa;
  UPDATE channel_accounts SET status = 'not_connected' WHERE id = acc_wa;
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat1));
  PERFORM pg_temp.act_chk('accounts: another branch''s own account is not used for a branch A1 patient', pg_temp.act_code(r2) = 'ok' AND r2 #>> '{data,channel}' = 'sms', 'got ' || coalesce(r2::text, 'null'));
  DELETE FROM channel_accounts WHERE id = acc_a2;

  -- ═══ quiet hours ═══
  lt := (now() AT TIME ZONE 'Asia/Kathmandu')::time;
  UPDATE channel_accounts SET quiet_start = lt - interval '1 hour', quiet_end = lt + interval '1 hour' WHERE id = acc;
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat1));
  PERFORM pg_temp.act_chk('quiet hours: refused by default (QUIET_HOURS), nothing queued', pg_temp.act_code(r2) = 'QUIET_HOURS', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Deferred hello'', p_on_quiet_hours => ''defer'')', pat1));
  m2 := (r2 #>> '{data,message_id}')::uuid;
  PERFORM pg_temp.act_chk('quiet hours: "defer" queues it for the end of the window', pg_temp.act_code(r2) = 'ok' AND (SELECT scheduled_for FROM messages WHERE id = m2) > now() + interval '30 minutes' AND (r2 #>> '{data,deferred}')::boolean, 'got ' || coalesce(r2::text, 'null'));
  UPDATE messages SET scheduled_for = now() - interval '1 minute' WHERE id = m2;   -- pretend the window ended; the worker re-checks at claim time
  r2 := pg_temp.act_run('service', 'SELECT coalesce(jsonb_agg(c.id), ''[]''::jsonb) FROM public.hub_claim_messages(50) c', 0);
  PERFORM pg_temp.act_chk('quiet hours: the worker re-checks at claim time and pushes it past the window instead of sending', NOT (r2 @> to_jsonb(m2::text)) AND (SELECT status FROM messages WHERE id = m2) = 'queued' AND (SELECT scheduled_for FROM messages WHERE id = m2) > now(), 'claimed: ' || coalesce(r2::text, 'null'));
  UPDATE channel_accounts SET quiet_start = NULL, quiet_end = NULL WHERE id = acc;
  UPDATE channel_accounts SET quiet_start = lt + interval '2 hours', quiet_end = lt + interval '3 hours' WHERE id = acc;
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Outside the window'')', pat1));
  PERFORM pg_temp.act_chk('quiet hours: outside the window (and across midnight) is fine', pg_temp.act_code(r2) = 'ok', 'got ' || coalesce(r2::text, 'null'));
  UPDATE channel_accounts SET quiet_start = NULL, quiet_end = NULL WHERE id = acc;
  UPDATE messages SET scheduled_for = now() - interval '1 minute' WHERE id IN (m1, m2);   -- the claim above pushed both past the quiet window

  -- ═══ the sender: claim, result, stale, delivery status ═══
  UPDATE messages SET status = 'cancelled' WHERE conversation_id = conv1 AND direction = 'out' AND kind = 'message' AND id <> m1 AND id <> m2;   -- keep this part small
  r2 := pg_temp.act_run('service', 'SELECT coalesce(jsonb_agg(c.id), ''[]''::jsonb) FROM public.hub_claim_messages(50) c', 0);
  PERFORM pg_temp.act_chk('claim: a due queued message is handed to the sender and set to sending ', r2 @> to_jsonb(m2::text) AND (SELECT status FROM messages WHERE id = m2) = 'sending' AND (SELECT status FROM messages WHERE id = m1) = 'sending', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', 'SELECT coalesce(jsonb_agg(c.id), ''[]''::jsonb) FROM public.hub_claim_messages(50) c', 0);
  PERFORM pg_temp.act_chk('claim: a second claim gets nothing (a claimed message is never handed out twice)', r2 = '[]'::jsonb, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', 'SELECT coalesce(jsonb_agg(c.id), ''[]''::jsonb) FROM public.hub_claim_messages(50) c', 0);
  PERFORM pg_temp.act_chk('claim: only the service role can call it', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT to_jsonb(public.hub_record_send_result(%L, true, ''prov-1'', 2, NULL))', m1), 0);
  PERFORM pg_temp.act_chk('result: ok -> sent with the provider id, credits and cost (credits x the account''s price)', r2 = 'true'::jsonb AND (SELECT (status, provider_message_id, credits, cost_npr) FROM messages WHERE id = m1) = ('sent'::text, 'prov-1'::text, 2.00::numeric, 3.0000::numeric), (SELECT row_to_json(m)::text FROM messages m WHERE id = m1));
  r2 := pg_temp.act_run('service', format('SELECT to_jsonb(public.hub_record_send_result(%L, false, NULL, NULL, ''Not enough balance.''))', m2), 0);
  PERFORM pg_temp.act_chk('result: a failure is recorded with its error', (SELECT (status, error) FROM messages WHERE id = m2) = ('failed'::text, 'Not enough balance.'::text), (SELECT row_to_json(m)::text FROM messages m WHERE id = m2));
  r2 := pg_temp.act_run('service', format('SELECT to_jsonb(public.hub_record_send_result(%L, true, ''prov-x'', 1, NULL))', m1), 0);
  PERFORM pg_temp.act_chk('result: only a message in "sending" can be recorded (a second result is ignored)', r2 = 'false'::jsonb, 'got ' || coalesce(r2::text, 'null'));

  -- delivery receipts only move forward
  r2 := pg_temp.act_run('service', format('SELECT to_jsonb(public.hub_apply_delivery_status(%L, ''prov-1'', ''delivered'', now(), NULL))', acc), 0);
  PERFORM pg_temp.act_chk('status: sent -> delivered', r2 = '"updated"'::jsonb AND (SELECT status FROM messages WHERE id = m1) = 'delivered' AND (SELECT delivered_at FROM messages WHERE id = m1) IS NOT NULL, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT to_jsonb(public.hub_apply_delivery_status(%L, ''prov-1'', ''sent'', now(), NULL))', acc), 0);
  PERFORM pg_temp.act_chk('status: a late "sent" never moves it backwards', r2 = '"ignored"'::jsonb AND (SELECT status FROM messages WHERE id = m1) = 'delivered', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT to_jsonb(public.hub_apply_delivery_status(%L, ''prov-1'', ''failed'', now(), ''late''))', acc), 0);
  PERFORM pg_temp.act_chk('status: a "failed" after delivery is ignored', r2 = '"ignored"'::jsonb AND (SELECT status FROM messages WHERE id = m1) = 'delivered', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT to_jsonb(public.hub_apply_delivery_status(%L, ''prov-1'', ''read'', now(), NULL))', acc), 0);
  PERFORM pg_temp.act_chk('status: delivered -> read', r2 = '"updated"'::jsonb AND (SELECT status FROM messages WHERE id = m1) = 'read', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT to_jsonb(public.hub_apply_delivery_status(%L, ''no-such-id'', ''delivered'', now(), NULL))', acc), 0);
  PERFORM pg_temp.act_chk('status: an unknown provider id is "not_found"', r2 = '"not_found"'::jsonb, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT to_jsonb(public.hub_apply_delivery_status(%L, ''prov-1'', ''read'', now(), NULL))', acc), 0);
  PERFORM pg_temp.act_chk('status: only the service role can report delivery', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));

  -- stale "sending": an idempotent provider is re-queued, any other is failed as "outcome unknown", never re-sent
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, status, channel_account_id, provider, purpose) VALUES
    (oa, conv1, 'out', 'message', 'stale test', 'person', 'sending', acc, 'test', 'service') RETURNING id INTO x_id;
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, status, channel_account_id, provider, purpose) VALUES
    (oa, conv1, 'out', 'message', 'stale aakash', 'person', 'sending', acc, 'aakash', 'service') RETURNING id INTO m2;
  ALTER TABLE public.messages DISABLE TRIGGER trg_messages_updated_at;
  UPDATE messages SET updated_at = now() - interval '11 minutes' WHERE id IN (x_id, m2);
  ALTER TABLE public.messages ENABLE TRIGGER trg_messages_updated_at;
  r2 := pg_temp.act_run('service', 'SELECT coalesce(jsonb_agg(c.id), ''[]''::jsonb) FROM public.hub_claim_messages(50) c', 0);
  PERFORM pg_temp.act_chk('stale: a test-provider message stuck in "sending" is re-queued (and then claimed again)', r2 @> to_jsonb(x_id::text), 'got ' || coalesce(r2::text, 'null'));
  PERFORM pg_temp.act_chk('stale: a non-idempotent provider''s message becomes failed "outcome unknown", and is NOT handed out again', (SELECT (status, error) FROM messages WHERE id = m2) = ('failed'::text, 'outcome unknown: check the provider report'::text) AND NOT (r2 @> to_jsonb(m2::text)), (SELECT row_to_json(m)::text FROM messages m WHERE id = m2));
  UPDATE messages SET status = 'cancelled' WHERE id = x_id;
  r2 := pg_temp.act_run('service', format('SELECT coalesce(jsonb_agg(p.provider_message_id), ''[]''::jsonb) FROM public.hub_pending_delivery(%L) p', acc), 0);
  PERFORM pg_temp.act_chk('poll: hub_pending_delivery lists only "sent" messages that have a provider id', NOT (r2 @> to_jsonb('prov-1'::text)), 'got ' || coalesce(r2::text, 'null'));

  -- ═══ message.retry ═══
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_retry(%L)', m1));
  PERFORM pg_temp.act_chk('retry: only a failed message can be retried (NOT_FAILED)', pg_temp.act_code(r2) = 'NOT_FAILED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_retry(%L)', m2));
  PERFORM pg_temp.act_chk('retry: a failed message is re-queued as a NEW row linked by meta.retry_of; the old row stays failed', pg_temp.act_code(r2) = 'ok'
    AND (SELECT status FROM messages WHERE id = m2) = 'failed' AND (r2 #>> '{data,message_id}')::uuid <> m2 AND (SELECT meta ->> 'retry_of' FROM messages WHERE id = (r2 #>> '{data,message_id}')::uuid) = m2::text
    AND (SELECT body FROM messages WHERE id = (r2 #>> '{data,message_id}')::uuid) = 'stale aakash', 'got ' || coalesce(r2::text, 'null'));
  r := r2;
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_retry(%L)', m2));
  PERFORM pg_temp.act_chk('retry: a message already retried cannot be retried again (ALREADY_RETRIED)', pg_temp.act_code(r2) = 'ALREADY_RETRIED', 'got ' || coalesce(r2::text, 'null'));
  UPDATE messages SET status = 'failed', error = 'x' WHERE id = (r #>> '{data,message_id}')::uuid;
  UPDATE channel_accounts SET status = 'connected' WHERE id = acc_wa;
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_retry(%L, ''whatsapp'')', (r #>> '{data,message_id}')::uuid));
  PERFORM pg_temp.act_chk('retry: on another channel (the owner''s "Send by SMS" board in reverse) it creates the thread there and re-checks consent', pg_temp.act_code(r2) = 'ok' AND r2 #>> '{data,channel}' = 'whatsapp', 'got ' || coalesce(r2::text, 'null'));
  UPDATE channel_accounts SET status = 'not_connected' WHERE id = acc_wa;
  r2 := pg_temp.act_run('admin_of_OTHER_org', format('SELECT public.act_message_retry(%L)', m2));
  PERFORM pg_temp.act_chk('retry: another org''s message (MESSAGE_NOT_FOUND)', pg_temp.act_code(r2) = 'MESSAGE_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_viewer', format('SELECT public.act_message_retry(%L)', m2));
  PERFORM pg_temp.act_chk('retry: admin_viewer cannot (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN' OR pg_temp.act_code(r2) = 'ALREADY_RETRIED', 'got ' || coalesce(r2::text, 'null'));

  -- ═══ STOP and START (message.receive) ═══
  r := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''+977 980-1000001'', ''Thanks, see you'', ''in-1'', NULL, %L::jsonb)', acc, pat_ctx));
  convb := (r #>> '{data,conversation_id}')::uuid;
  PERFORM pg_temp.act_chk('receive: a reply from a patient lands in the same thread (matched by normalised phone), logged as the patient', pg_temp.act_code(r) = 'ok' AND convb = conv1 AND (r #>> '{data,matched}')::boolean
    AND (SELECT actor_kind FROM action_log WHERE id = (r ->> 'action_id')::uuid) = 'patient' AND (SELECT (direction, author_kind, status) FROM messages WHERE id = (r #>> '{data,message_id}')::uuid) = ('in'::text, 'patient'::text, 'delivered'::text), 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''+977 980-1000001'', ''Thanks, see you'', ''in-1'', NULL, %L::jsonb)', acc, pat_ctx));
  PERFORM pg_temp.act_chk('receive: the same provider message id again is a duplicate, nothing inserted twice', pg_temp.act_code(r2) = 'ok' AND (r2 #>> '{data,duplicate}')::boolean
    AND (SELECT count(*) FROM messages WHERE channel_account_id = acc AND provider_message_id = 'in-1') = 1, 'got ' || coalesce(r2::text, 'null'));
  UPDATE messages SET status = 'cancelled' WHERE conversation_id = conv1 AND direction = 'out' AND kind = 'message' AND status IN ('queued', 'sending');
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9801000001'', ''Please cancel my appointment'', ''in-2'', NULL, %L::jsonb)', acc, pat_ctx));
  PERFORM pg_temp.act_chk('receive: "cancel my appointment" is NOT a stop word', pg_temp.act_code(r2) = 'ok' AND r2 #>> '{data,keyword}' IS NULL AND (SELECT status FROM patient_channels WHERE org_id = oa AND address = '+9779801000001' AND channel = 'sms' AND purpose = 'service') = 'agreed', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9801000001'', ''cancel'', ''in-2b'', NULL, %L::jsonb)', acc, pat_ctx));
  PERFORM pg_temp.act_chk('receive: a bare "cancel" is not a stop word either', r2 #>> '{data,keyword}' IS NULL AND (SELECT status FROM patient_channels WHERE org_id = oa AND address = '+9779801000001' AND channel = 'sms' AND purpose = 'service') = 'agreed', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9801000001'', '' Stop. '', ''in-3'', NULL, %L::jsonb)', acc, pat_ctx));
  PERFORM pg_temp.act_chk('STOP: both purposes become stopped, with an event line and ONE queued confirmation reply', pg_temp.act_code(r2) = 'ok' AND r2 #>> '{data,keyword}' = 'stop'
    AND (SELECT count(*) FROM patient_channels WHERE org_id = oa AND address = '+9779801000001' AND channel = 'sms' AND status = 'stopped' AND source = 'patient_reply') = 2
    AND EXISTS (SELECT 1 FROM messages WHERE conversation_id = conv1 AND event_type = 'stop_recorded')
    AND (SELECT count(*) FROM messages WHERE conversation_id = conv1 AND meta ->> 'opt_out_confirmation' = 'true' AND status = 'queued') = 1, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L)', pat1, t_conf, bk1));
  PERFORM pg_temp.act_chk('STOP: the next send is refused with STOPPED', pg_temp.act_code(r2) = 'STOPPED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9801000001'', ''STOP'', ''in-4'', NULL, %L::jsonb)', acc, pat_ctx));
  PERFORM pg_temp.act_chk('STOP: a second STOP sends no second confirmation', (SELECT count(*) FROM messages WHERE conversation_id = conv1 AND meta ->> 'opt_out_confirmation' = 'true') = 1, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', 'SELECT coalesce(jsonb_agg(c.body), ''[]''::jsonb) FROM public.hub_claim_messages(50) c', 0);
  PERFORM pg_temp.act_chk('STOP: the confirmation reply IS sent to the stopped number (the only message allowed there)', r2::text LIKE '%no longer receive%', 'got ' || coalesce(r2::text, 'null'));
  UPDATE patient_channels SET status = 'stopped', source = 'patient_reply' WHERE org_id = oa AND address = '+9779801000001' AND channel = 'sms';
  r2 := pg_temp.act_run('staff', format('SELECT public.act_consent_record(p_customer => %L, p_evidence => ''Agreed at the front desk, 4 Feb'')', pat1));
  PERFORM pg_temp.act_chk('STOP: plain front desk CANNOT un-stop a number (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN' AND (SELECT status FROM patient_channels WHERE org_id = oa AND address = '+9779801000001' AND channel = 'sms' AND purpose = 'service') = 'stopped', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_consent_record(p_customer => %L, p_evidence => ''ok'')', pat1));
  PERFORM pg_temp.act_chk('STOP: a manager needs real evidence to record a new agreement (FORBIDDEN when it is too short)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_consent_record(p_customer => %L, p_evidence => ''Signed paper form, 5 Feb, checked by the manager'')', pat1));
  PERFORM pg_temp.act_chk('STOP: a manager with written evidence can record a new agreement', pg_temp.act_code(r2) = 'ok' AND (SELECT (status, source) FROM patient_channels WHERE org_id = oa AND address = '+9779801000001' AND channel = 'sms' AND purpose = 'service') = ('agreed'::text, 'front_desk'::text), 'got ' || coalesce(r2::text, 'null'));
  UPDATE patient_channels SET status = 'stopped', source = 'patient_reply' WHERE org_id = oa AND address = '+9779801000001' AND channel = 'sms';
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9801000001'', ''START'', ''in-5'', NULL, %L::jsonb)', acc, pat_ctx));
  PERFORM pg_temp.act_chk('START: the patient''s own START brings service messages back; marketing goes to "not asked", never to agreed', pg_temp.act_code(r2) = 'ok' AND r2 #>> '{data,keyword}' = 'start'
    AND (SELECT status FROM patient_channels WHERE org_id = oa AND address = '+9779801000001' AND channel = 'sms' AND purpose = 'service') = 'agreed'
    AND (SELECT status FROM patient_channels WHERE org_id = oa AND address = '+9779801000001' AND channel = 'sms' AND purpose = 'marketing') = 'not_asked', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L)', pat1, t_conf, bk1));
  PERFORM pg_temp.act_chk('START: a send is allowed again', pg_temp.act_code(r2) = 'ok', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9801000002'', ''रोक'', ''in-6'', NULL, %L::jsonb)', acc, pat_ctx));
  PERFORM pg_temp.act_chk('STOP in Nepali (रोक) works, the confirmation is in Nepali, and it does not touch another number''s consent', pg_temp.act_code(r2) = 'ok' AND r2 #>> '{data,keyword}' = 'stop'
    AND (SELECT status FROM patient_channels WHERE org_id = oa AND address = '+9779801000002' AND channel = 'sms' AND purpose = 'service') = 'stopped'
    AND (SELECT status FROM patient_channels WHERE org_id = oa AND address = '+9779801000001' AND channel = 'sms' AND purpose = 'service') = 'agreed'
    AND EXISTS (SELECT 1 FROM messages WHERE meta ->> 'opt_out_confirmation' = 'true' AND language = 'ne' AND body LIKE 'तपाईंले%'), 'got ' || coalesce(r2::text, 'null'));
  UPDATE patient_channels SET status = 'agreed' WHERE org_id = oa AND address = '+9779801000002' AND channel = 'sms';
  UPDATE messages SET status = 'cancelled' WHERE org_id = oa AND status IN ('queued', 'sending') AND direction = 'out' AND kind = 'message';

  -- a message queued, then the patient says STOP before it is sent: cancelled at claim time
  r := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Reminder'')', pat2));
  m2 := (r #>> '{data,message_id}')::uuid;
  PERFORM pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9801000002'', ''STOP'', ''in-7'', NULL, %L::jsonb)', acc, pat_ctx));
  r2 := pg_temp.act_run('service', 'SELECT coalesce(jsonb_agg(c.id), ''[]''::jsonb) FROM public.hub_claim_messages(50) c', 0);
  PERFORM pg_temp.act_chk('STOP between queue and send: the queued message is cancelled, not sent', (SELECT (status, error) FROM messages WHERE id = m2) = ('cancelled'::text, 'cancelled: the patient replied STOP before this was sent'::text) AND NOT (r2 @> to_jsonb(m2::text)), (SELECT row_to_json(m)::text FROM messages m WHERE id = m2));
  UPDATE patient_channels SET status = 'agreed' WHERE org_id = oa AND address = '+9779801000002' AND channel = 'sms';

  -- ═══ inbound from a number that is not a patient ═══
  r := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''+977 980-5512345'', ''Hello, do you do braces?'', ''in-u1'', NULL, %L::jsonb)', acc, pat_ctx));
  convu := (r #>> '{data,conversation_id}')::uuid;
  PERFORM pg_temp.act_chk('unknown number: a thread with no patient and no branch is created ("No patient match")', pg_temp.act_code(r) = 'ok' AND NOT (r #>> '{data,matched}')::boolean AND (SELECT (customer_id IS NULL, branch_id IS NULL, state) FROM conversations WHERE id = convu) = (true, true, 'agent'::text), 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT jsonb_build_object(''n'', count(*)) FROM public.conversations WHERE id = %L', convu), 0);
  PERFORM pg_temp.act_chk('unknown number: front desk of branch A1 can see it', (r2 ->> 'n')::int = 1, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_staff_a2', format('SELECT jsonb_build_object(''n'', count(*)) FROM public.conversations WHERE id = %L', convu), 0);
  PERFORM pg_temp.act_chk('unknown number: so can front desk of ANY other branch', (r2 ->> 'n')::int = 1, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p1', format('SELECT jsonb_build_object(''n'', count(*)) FROM public.conversations WHERE id = %L', convu), 0);
  PERFORM pg_temp.act_chk('unknown number: a practitioner cannot', (r2 ->> 'n')::int = 0, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_of_OTHER_org', format('SELECT jsonb_build_object(''n'', count(*)) FROM public.conversations WHERE id = %L', convu), 0);
  PERFORM pg_temp.act_chk('unknown number: another org cannot', (r2 ->> 'n')::int = 0, 'got ' || coalesce(r2::text, 'null'));
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a2, 'Hub Newly Registered', oa, '+9779805512345') RETURNING id INTO x_id;
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9805512345'', ''I booked now'', ''in-u2'', NULL, %L::jsonb)', acc, pat_ctx));
  PERFORM pg_temp.act_chk('unknown number: once the number belongs to a patient, the thread is linked to them and takes their branch', pg_temp.act_code(r2) = 'ok'
    AND (r2 #>> '{data,conversation_id}')::uuid = convu AND (SELECT (customer_id, branch_id) FROM conversations WHERE id = convu) = (x_id, a2), 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9805512345'', ''STOP'', ''in-u3'', NULL, %L::jsonb)', acc, pat_ctx));
  PERFORM pg_temp.act_chk('STOP from a number that was not a patient is stored by ADDRESS and linked to the patient once known', (SELECT (customer_id, status) FROM patient_channels WHERE org_id = oa AND address = '+9779805512345' AND purpose = 'service' AND channel = 'sms') = (x_id, 'stopped'::text), 'got ' || coalesce(r2::text, 'null'));
  UPDATE conversations SET state = 'closed' WHERE id = conv1;
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9801000001'', ''Hello again'', ''in-8'', NULL, %L::jsonb)', acc, pat_ctx));
  PERFORM pg_temp.act_chk('a closed thread is reopened by an inbound message', (r2 #>> '{data,reopened}')::boolean AND (SELECT state FROM conversations WHERE id = conv1) IN ('agent', 'needs_person'), 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_message_receive(%L, ''9801000001'', ''spoof'', ''in-x'', NULL, %L::jsonb)', acc, pat_ctx), 0);
  PERFORM pg_temp.act_chk('receive: a signed-in user cannot record an incoming message (FORBIDDEN)', pg_temp.act_code(r2) IN ('raised:42501', 'FORBIDDEN'), 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('forged', format('SELECT public.act_message_receive(%L, ''9801000001'', ''spoof'', ''in-y'', NULL, %L::jsonb)', acc, pat_ctx), 0);
  PERFORM pg_temp.act_chk('receive: a forged service_role claim is not enough', pg_temp.act_code(r2) IN ('raised:42501', 'FORBIDDEN') AND NOT EXISTS (SELECT 1 FROM messages WHERE provider_message_id = 'in-y'), 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('anon', format('SELECT public.act_message_receive(%L, ''9801000001'', ''spoof'', ''in-z'', NULL, %L::jsonb)', acc, pat_ctx), 0);
  PERFORM pg_temp.act_chk('receive: anon cannot execute it', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9801000001'', ''hi'', ''in-w'', NULL, %L::jsonb)', acc, patb_ctx));
  PERFORM pg_temp.act_chk('receive: an account of another org (ACCOUNT_NOT_FOUND)', pg_temp.act_code(r2) = 'ACCOUNT_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9801000001'', '''', ''in-v'', NULL, %L::jsonb)', acc, pat_ctx));
  PERFORM pg_temp.act_chk('receive: an empty text (INVALID_INPUT)', pg_temp.act_code(r2) = 'INVALID_INPUT', 'got ' || coalesce(r2::text, 'null'));

  -- the webhook helpers
  r2 := pg_temp.act_run('service', format('SELECT to_jsonb(f) FROM public.hub_find_account(''test'', (SELECT sender FROM public.channel_accounts WHERE id = %L)) f', acc), 0);
  PERFORM pg_temp.act_chk('webhook: hub_find_account finds the account by provider and recipient', (r2 ->> 'id')::uuid = acc, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT to_jsonb(f) FROM public.hub_find_account(''aakash'', (SELECT sender FROM public.channel_accounts WHERE id = %L)) f', acc), 0);
  PERFORM pg_temp.act_chk('webhook: ...and not under another provider', r2 IS NULL OR r2 = 'null'::jsonb, 'got ' || coalesce(r2::text, 'null'));
  cnt_before := 0;
  FOR n IN 1..60 LOOP
    IF (pg_temp.act_run('service', format('SELECT to_jsonb(public.hub_rate_check(%L, 60))', acc), 0)) = 'true'::jsonb THEN cnt_before := cnt_before + 1; END IF;
  END LOOP;
  r2 := pg_temp.act_run('service', format('SELECT to_jsonb(public.hub_rate_check(%L, 60))', acc), 0);
  PERFORM pg_temp.act_chk('rate limit: 60 per minute are accepted, the 61st is dropped and counted', cnt_before = 60 AND r2 = 'false'::jsonb AND (SELECT dropped FROM hub_inbound_rate WHERE channel_account_id = acc ORDER BY bucket DESC LIMIT 1) >= 1, 'accepted ' || cnt_before || ', then ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT to_jsonb(public.hub_rate_check(%L, 60))', acc), 0);
  PERFORM pg_temp.act_chk('rate limit: only the service role can call it', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));

  -- ═══ conversation actions ═══
  UPDATE conversations SET state = 'agent', handled_by = NULL, needs_person_since = NULL WHERE id = conv1;
  r := pg_temp.act_run('staff', format('SELECT public.act_conversation_take_over(%L)', conv1));
  PERFORM pg_temp.act_chk('take over: the person becomes handled_by, state person, one event line, one log row', pg_temp.act_code(r) = 'ok' AND (SELECT (state, handled_by) FROM conversations WHERE id = conv1) = ('person'::text, u_staff)
    AND EXISTS (SELECT 1 FROM messages WHERE conversation_id = conv1 AND event_type = 'took_over' AND action_id = (r ->> 'action_id')::uuid AND body LIKE '% took over'), 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_conversation_take_over(%L)', conv1));
  PERFORM pg_temp.act_chk('take over: a manager can take it over from front desk', pg_temp.act_code(r2) = 'ok' AND (SELECT handled_by FROM conversations WHERE id = conv1) = u_mgr, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_conversation_take_over(%L)', conv1));
  PERFORM pg_temp.act_chk('take over: front desk cannot take it back from a manager (ALREADY_HANDLED)', pg_temp.act_code(r2) = 'ALREADY_HANDLED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_staff_a2', format('SELECT public.act_conversation_take_over(%L)', conv1));
  PERFORM pg_temp.act_chk('take over: front desk of another branch cannot see it (CONVERSATION_NOT_FOUND)', pg_temp.act_code(r2) = 'CONVERSATION_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_viewer', format('SELECT public.act_conversation_take_over(%L)', conv1));
  PERFORM pg_temp.act_chk('take over: admin_viewer is read-only (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p2', format('SELECT public.act_conversation_take_over(%L)', conv1));
  PERFORM pg_temp.act_chk('take over: a practitioner cannot take over another practitioner''s patient''s thread (CONVERSATION_NOT_FOUND)', pg_temp.act_code(r2) = 'CONVERSATION_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));
  UPDATE conversations SET state = 'agent', handled_by = NULL WHERE id = conv1;
  r2 := pg_temp.act_run('hub_p1', format('SELECT public.act_conversation_take_over(%L)', conv1));
  PERFORM pg_temp.act_chk('take over: a practitioner can for their own patient', pg_temp.act_code(r2) = 'ok' AND (SELECT handled_by FROM conversations WHERE id = conv1) = u_p1, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_conversation_take_over(%L, %L::jsonb)', conv1, agent_ctx));
  PERFORM pg_temp.act_chk('take over: an agent cannot (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));

  -- hand back, and its undo
  UPDATE conversations SET handled_by = u_staff WHERE id = conv1;
  r := pg_temp.act_run('hub_p1', format('SELECT public.act_conversation_hand_back(%L)', conv1));
  PERFORM pg_temp.act_chk('hand back: state agent, event line, one log row', pg_temp.act_code(r) = 'ok' AND (SELECT (state, handled_by) FROM conversations WHERE id = conv1) IS NOT DISTINCT FROM ('agent'::text, NULL::uuid)
    AND EXISTS (SELECT 1 FROM messages WHERE conversation_id = conv1 AND event_type = 'handed_back' AND action_id = (r ->> 'action_id')::uuid), 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('hub_p1', format('SELECT public.act_conversation_hand_back(%L)', conv1));
  PERFORM pg_temp.act_chk('hand back: when the agent already has it (NOT_HANDLED)', pg_temp.act_code(r2) = 'NOT_HANDLED', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p1', format('SELECT public.act_undo(%L, ''oops'')', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('hand back UNDO: the practitioner who handed back can undo it; state and handler are restored, and an event line is added', pg_temp.act_code(r2) = 'ok' AND (SELECT (state, handled_by) FROM conversations WHERE id = conv1) = ('person'::text, u_staff)
    AND EXISTS (SELECT 1 FROM messages WHERE conversation_id = conv1 AND event_type = 'handed_back_undone'), 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p1', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('hand back UNDO: a second undo is refused (UNDO_ALREADY)', pg_temp.act_code(r2) = 'UNDO_ALREADY', 'got ' || coalesce(r2::text, 'null'));
  r := pg_temp.act_run('staff', format('SELECT public.act_conversation_hand_back(%L)', conv1));
  PERFORM pg_temp.act_run('service', format('SELECT public.act_message_receive(%L, ''9801000001'', ''One more thing'', ''in-9'', NULL, %L::jsonb)', acc, pat_ctx));
  ALTER TABLE public.conversations DISABLE TRIGGER trg_conversations_updated_at;
  UPDATE conversations SET updated_at = now() + interval '1 second' WHERE id = conv1;   -- inside one test transaction now() never advances
  ALTER TABLE public.conversations ENABLE TRIGGER trg_conversations_updated_at;
  r2 := pg_temp.act_run('staff', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('hand back UNDO: refused when the conversation changed since (UNDO_STALE)', pg_temp.act_code(r2) = 'UNDO_STALE', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p2', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.act_chk('hand back UNDO: a practitioner who did not make it, and whose patient this is not (ACTION_NOT_FOUND / FORBIDDEN)', pg_temp.act_code(r2) IN ('ACTION_NOT_FOUND', 'FORBIDDEN'), 'got ' || coalesce(r2::text, 'null'));

  -- assign
  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_conversation_assign(%L, %L, ''He is a regular. Can you decide on the discount?'')', conv1, u_staff));
  PERFORM pg_temp.act_chk('assign: a manager assigns to front desk with a note; who, when and why are stored, and the note is in the event', pg_temp.act_code(r) = 'ok'
    AND (SELECT (assigned_to, assigned_by, assign_note) FROM conversations WHERE id = conv1) = (u_staff, u_mgr, 'He is a regular. Can you decide on the discount?'::text)
    AND (SELECT meta ->> 'note' FROM messages WHERE conversation_id = conv1 AND event_type = 'assigned' AND action_id = (r ->> 'action_id')::uuid) = 'He is a regular. Can you decide on the discount?', 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_conversation_assign(%L, %L, ''Please decide'')', conv1, u_mgr));
  PERFORM pg_temp.act_chk('assign: front desk can assign to a manager ("Assign to manager")', pg_temp.act_code(r2) = 'ok' AND (SELECT assigned_by FROM conversations WHERE id = conv1) = u_staff, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_conversation_assign(%L, %L)', conv1, u_staff));
  PERFORM pg_temp.act_chk('assign: front desk cannot assign to another front desk (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p1', format('SELECT public.act_conversation_assign(%L, %L)', conv1, u_mgr));
  PERFORM pg_temp.act_chk('assign: a practitioner cannot assign (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_conversation_assign(%L, %L)', conv1, u_staff2));
  PERFORM pg_temp.act_chk('assign: to someone with no access to the branch (ASSIGNEE_NO_ACCESS)', pg_temp.act_code(r2) = 'ASSIGNEE_NO_ACCESS', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_conversation_assign(%L, %L)', conv1, u_adminb));
  PERFORM pg_temp.act_chk('assign: to a user of another org (ASSIGNEE_NOT_FOUND)', pg_temp.act_code(r2) = 'ASSIGNEE_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_conversation_assign(%L, %L)', conv1, u_p2));
  PERFORM pg_temp.act_chk('assign: to a practitioner who does not see this patient (ASSIGNEE_NO_ACCESS)', pg_temp.act_code(r2) = 'ASSIGNEE_NO_ACCESS', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_conversation_assign(%L, %L)', conv1, u_p1));
  PERFORM pg_temp.act_chk('assign: to the practitioner of this patient', pg_temp.act_code(r2) = 'ok', 'got ' || coalesce(r2::text, 'null'));

  -- handoff (agents and rules only)
  UPDATE conversations SET state = 'agent', handled_by = NULL, needs_person_since = NULL, urgent = false, practitioner_id = NULL WHERE id = conv1;
  r := pg_temp.act_run('service', format('SELECT public.act_conversation_handoff(%L, ''clinical'', ''It is still bleeding after the extraction.'', true, NULL, %L::jsonb)', conv1, agent_ctx));
  PERFORM pg_temp.act_chk('handoff: an agent hands off as clinical and urgent; needs_person_since is set; the practitioner is the dentist who sees this patient', pg_temp.act_code(r) = 'ok'
    AND (SELECT (state, handoff_reason, urgent, practitioner_id, needs_person_since IS NOT NULL, handoff_summary) FROM conversations WHERE id = conv1) = ('needs_person'::text, 'clinical'::text, true, d1, true, 'It is still bleeding after the extraction.'::text)
    AND EXISTS (SELECT 1 FROM messages WHERE conversation_id = conv1 AND event_type = 'handoff' AND author_kind = 'agent' AND author_agent = 'follow_up'), 'got ' || coalesce(r::text, 'null') || ' / ' || coalesce((SELECT row_to_json(c)::text FROM conversations c WHERE id = conv1), ''));
  r2 := pg_temp.act_run('hub_p1', format('SELECT jsonb_build_object(''n'', count(*)) FROM public.conversations WHERE id = %L', conv1), 0);
  PERFORM pg_temp.act_chk('handoff: that practitioner can read the thread', (r2 ->> 'n')::int = 1, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p2', format('SELECT jsonb_build_object(''n'', count(*), ''m'', (SELECT count(*) FROM public.messages WHERE conversation_id = %L)) FROM public.conversations WHERE id = %L', conv1, conv1), 0);
  PERFORM pg_temp.act_chk('handoff: a second practitioner can read neither the thread nor its messages', (r2 ->> 'n')::int = 0 AND (r2 ->> 'm')::int = 0, 'got ' || coalesce(r2::text, 'null'));
  SELECT needs_person_since INTO v_when FROM conversations WHERE id = conv1;
  r2 := pg_temp.act_run('service', format('SELECT public.act_conversation_handoff(%L, ''urgent'', ''Second handoff.'', true, NULL, %L::jsonb)', conv1, agent_ctx));
  PERFORM pg_temp.act_chk('handoff: a second handoff keeps the original "waiting since"', pg_temp.act_code(r2) = 'ok' AND (SELECT needs_person_since FROM conversations WHERE id = conv1) = v_when, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_conversation_handoff(%L, ''clinical'', ''x'', true)', conv1));
  PERFORM pg_temp.act_chk('handoff: a person cannot (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_conversation_handoff(%L, ''whatever'', ''x'', false, NULL, %L::jsonb)', conv1, agent_ctx));
  PERFORM pg_temp.act_chk('handoff: an unknown reason (INVALID_INPUT)', pg_temp.act_code(r2) = 'INVALID_INPUT', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_conversation_handoff(%L, ''clinical'', ''x'', false, %L, %L::jsonb)', conv1, (SELECT s.pk FROM t_seed s WHERE s.tbl = 'dentists' AND s.org = ob LIMIT 1), agent_ctx));
  PERFORM pg_temp.act_chk('handoff: a practitioner of another org is refused (INVALID_INPUT)', pg_temp.act_code(r2) = 'INVALID_INPUT', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_conversation_handoff(%L, ''clinical'', ''x'', false, NULL, %L::jsonb)', conv1, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', ob)));
  PERFORM pg_temp.act_chk('handoff: an agent of another org (CONVERSATION_NOT_FOUND)', pg_temp.act_code(r2) = 'CONVERSATION_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));
  r := pg_temp.act_run('staff', format('SELECT public.act_conversation_take_over(%L)', conv1));
  PERFORM pg_temp.act_chk('take over clears "waiting since"', (SELECT needs_person_since FROM conversations WHERE id = conv1) IS NULL, 'got ' || coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_conversation_handoff(%L, ''clinical'', ''x'', false, NULL, %L::jsonb)', conv1, agent_ctx));
  PERFORM pg_temp.act_chk('handoff: when a person is already handling it (ALREADY_HANDLED)', pg_temp.act_code(r2) = 'ALREADY_HANDLED', 'got ' || coalesce(r2::text, 'null'));

  -- consent.record
  r2 := pg_temp.act_run('staff', format('SELECT public.act_consent_record(p_customer => %L, p_evidence => '''')', pat3));
  PERFORM pg_temp.act_chk('consent: evidence is required (INVALID_INPUT)', pg_temp.act_code(r2) = 'INVALID_INPUT', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_consent_record(p_customer => %L, p_evidence => ''Agreed at the front desk, 4 Feb'')', pat3));
  PERFORM pg_temp.act_chk('consent: front desk cannot record for another branch''s patient (PATIENT_NOT_FOUND)', pg_temp.act_code(r2) = 'PATIENT_NOT_FOUND', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_consent_record(p_customer => %L, p_evidence => ''Agreed at the front desk, 4 Feb'')', pat3));
  PERFORM pg_temp.act_chk('consent: a manager records service consent with its evidence', pg_temp.act_code(r2) = 'ok' AND (SELECT (status, source, recorded_by, evidence) FROM patient_channels WHERE org_id = oa AND address = '+9779801000003' AND channel = 'sms' AND purpose = 'service') = ('agreed'::text, 'front_desk'::text, u_mgr, 'Agreed at the front desk, 4 Feb'::text), 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_message_send(p_customer => %L, p_text => ''Hello'')', pat3));
  PERFORM pg_temp.act_chk('consent: and the patient can now be messaged', pg_temp.act_code(r2) = 'ok', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p1', format('SELECT public.act_consent_record(p_customer => %L, p_evidence => ''Agreed at the front desk, 4 Feb'')', pat1));
  PERFORM pg_temp.act_chk('consent: a practitioner cannot record it (FORBIDDEN)', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('service', format('SELECT public.act_consent_record(p_customer => %L, p_evidence => ''Agent says so'', p_ctx => %L::jsonb)', pat1, agent_ctx));
  PERFORM pg_temp.act_chk('consent: an agent cannot record it (FORBIDDEN): only the patient''s own reply or a person can', pg_temp.act_code(r2) = 'FORBIDDEN', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_consent_record(p_customer => %L, p_purpose => ''marketing'', p_evidence => ''Ticked the marketing box on the paper form'')', pat1));
  PERFORM pg_temp.act_chk('consent: marketing agreement is recorded separately and only when explicit', pg_temp.act_code(r2) = 'ok' AND (SELECT status FROM patient_channels WHERE org_id = oa AND address = '+9779801000001' AND channel = 'sms' AND purpose = 'marketing') = 'agreed', 'got ' || coalesce(r2::text, 'null'));

  -- ═══ RLS ═══
  FOR l IN SELECT * FROM (VALUES ('conversations'), ('messages'), ('patient_channels'), ('channel_accounts'), ('message_templates'), ('conversation_reads')) v(t) LOOP
    PERFORM pg_temp.act_chk('RLS on ' || l.t, (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || l.t)::regclass), l.t);
  END LOOP;
  FOR l IN SELECT * FROM (VALUES ('staff'), ('admin'), ('hub_p1'), ('service'), ('manager_2_branches')) v(who) LOOP
    BEGIN
      r2 := pg_temp.act_run(l.who, 'INSERT INTO public.conversations (org_id, channel, address) SELECT org_id, channel, address || ''x'' FROM public.conversations LIMIT 1 RETURNING to_jsonb(conversations)', 0);
      PERFORM pg_temp.act_chk(l.who || ': direct INSERT into conversations is denied', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
      r2 := pg_temp.act_run(l.who, 'UPDATE public.messages SET body = body RETURNING to_jsonb(messages)', 0);
      PERFORM pg_temp.act_chk(l.who || ': direct UPDATE of messages is denied', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
      r2 := pg_temp.act_run(l.who, 'DELETE FROM public.patient_channels RETURNING to_jsonb(patient_channels)', 0);
      PERFORM pg_temp.act_chk(l.who || ': direct DELETE from patient_channels is denied', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
      r2 := pg_temp.act_run(l.who, 'UPDATE public.channel_accounts SET status = status RETURNING to_jsonb(channel_accounts)', 0);
      PERFORM pg_temp.act_chk(l.who || ': direct UPDATE of channel_accounts is denied', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
      r2 := pg_temp.act_run(l.who, 'INSERT INTO public.message_templates (org_id, name, body) SELECT org_id, ''x'', ''x'' FROM public.message_templates LIMIT 1 RETURNING to_jsonb(message_templates)', 0);
      PERFORM pg_temp.act_chk(l.who || ': direct INSERT into message_templates is denied', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
    END;
  END LOOP;
  r2 := pg_temp.act_run('hub_staff_a2', format('SELECT jsonb_build_object(''n'', count(*)) FROM public.conversations WHERE id = %L', conv1), 0);
  PERFORM pg_temp.act_chk('RLS: front desk of branch A2 cannot read a branch A1 thread', (r2 ->> 'n')::int = 0, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_staff_a2', format('SELECT jsonb_build_object(''n'', (SELECT count(*) FROM public.messages WHERE conversation_id = %L), ''c'', (SELECT count(*) FROM public.patient_channels WHERE customer_id IN (%L, %L))) ', conv1, pat1, pat2), 0);
  PERFORM pg_temp.act_chk('RLS: ...nor its messages, nor branch A1 patients'' consent rows', (r2 ->> 'n')::int = 0 AND (r2 ->> 'c')::int = 0, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT jsonb_build_object(''n'', (SELECT count(*) FROM public.conversations WHERE id = %L), ''m'', (SELECT count(*) FROM public.messages WHERE conversation_id = %L), ''c'', (SELECT count(*) FROM public.patient_channels WHERE customer_id = %L))', conv1, conv1, pat1), 0);
  PERFORM pg_temp.act_chk('RLS: front desk of branch A1 reads the thread, its messages and the patient''s consent', (r2 ->> 'n')::int = 1 AND (r2 ->> 'm')::int > 0 AND (r2 ->> 'c')::int > 0, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_viewer', format('SELECT jsonb_build_object(''n'', (SELECT count(*) FROM public.conversations WHERE org_id = %L), ''t'', (SELECT count(*) FROM public.conversations))', oa), 0);
  PERFORM pg_temp.act_chk('RLS: admin_viewer reads the whole org (read-only)', (r2 ->> 'n')::int = (r2 ->> 't')::int AND (r2 ->> 'n')::int >= 3, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('admin_of_OTHER_org', format('SELECT jsonb_build_object(''c'', (SELECT count(*) FROM public.conversations WHERE org_id = %L), ''m'', (SELECT count(*) FROM public.messages WHERE org_id = %L), ''p'', (SELECT count(*) FROM public.patient_channels WHERE org_id = %L), ''a'', (SELECT count(*) FROM public.channel_accounts WHERE org_id = %L), ''t'', (SELECT count(*) FROM public.message_templates WHERE org_id = %L))', oa, oa, oa, oa, oa), 0);
  PERFORM pg_temp.act_chk('RLS: another org sees nothing of org A in any hub table', (r2 ->> 'c')::int + (r2 ->> 'm')::int + (r2 ->> 'p')::int + (r2 ->> 'a')::int + (r2 ->> 't')::int = 0, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('anon', 'SELECT jsonb_build_object(''n'', count(*)) FROM public.conversations', 0);
  PERFORM pg_temp.act_chk('RLS: anon reads nothing', pg_temp.act_code(r2) = 'raised:42501' OR (r2 ->> 'n')::int = 0, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('customer_no_staff_row', 'SELECT jsonb_build_object(''c'', (SELECT count(*) FROM public.conversations), ''m'', (SELECT count(*) FROM public.messages), ''t'', (SELECT count(*) FROM public.message_templates), ''p'', (SELECT count(*) FROM public.patient_channels))', 0);
  PERFORM pg_temp.act_chk('RLS: a signed-in patient (no users row) reads none of it', (r2 ->> 'c')::int + (r2 ->> 'm')::int + (r2 ->> 't')::int + (r2 ->> 'p')::int = 0, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p1', format('SELECT jsonb_build_object(''mine'', (SELECT count(*) FROM public.conversations WHERE customer_id = %L), ''others'', (SELECT count(*) FROM public.conversations WHERE customer_id IS DISTINCT FROM %L), ''consent_other'', (SELECT count(*) FROM public.patient_channels WHERE customer_id IS DISTINCT FROM %L), ''tpl'', (SELECT count(*) FROM public.message_templates))', pat1, pat1, pat1), 0);
  PERFORM pg_temp.act_chk('RLS: a practitioner reads ONLY their own patients'' threads and consent, plus the templates', (r2 ->> 'mine')::int >= 1 AND (r2 ->> 'others')::int = 0 AND (r2 ->> 'consent_other')::int = 0 AND (r2 ->> 'tpl')::int >= 4, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p2', format('SELECT jsonb_build_object(''mine'', (SELECT count(*) FROM public.conversations WHERE customer_id = %L), ''pat1'', (SELECT count(*) FROM public.conversations WHERE customer_id = %L))', pat2, pat1), 0);
  PERFORM pg_temp.act_chk('RLS: the second practitioner sees their own patient''s thread, never the first one''s', (r2 ->> 'pat1')::int = 0, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p1', format('SELECT jsonb_build_object(''a'', public.is_my_patient(%L), ''b'', public.is_my_patient(%L), ''c'', public.is_my_patient(NULL))', pat1, pat2), 0);
  PERFORM pg_temp.act_chk('is_my_patient: true for my patient, false for another''s and for NULL', r2 = '{"a": true, "b": false, "c": false}'::jsonb, 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('anon', format('SELECT to_jsonb(public.is_my_patient(%L))', pat1), 0);
  PERFORM pg_temp.act_chk('is_my_patient: anon cannot execute it', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));

  -- read state
  r2 := pg_temp.act_run('staff', format('SELECT to_jsonb(public.hub_mark_read(%L))', conv1), 0);
  PERFORM pg_temp.act_chk('read state: marking a visible thread read stores my row', EXISTS (SELECT 1 FROM conversation_reads WHERE conversation_id = conv1 AND user_id = u_staff), 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('hub_p2', format('SELECT to_jsonb(public.hub_mark_read(%L))', conv1), 0);
  PERFORM pg_temp.act_chk('read state: a thread I cannot see stores nothing and reveals nothing', NOT EXISTS (SELECT 1 FROM conversation_reads WHERE conversation_id = conv1 AND user_id = u_p2), 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('anon', format('SELECT to_jsonb(public.hub_mark_read(%L))', conv1), 0);
  PERFORM pg_temp.act_chk('read state: anon cannot execute it', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT jsonb_build_object(''n'', count(*)) FROM public.conversation_reads WHERE user_id = %L', u_staff), 0);
  PERFORM pg_temp.act_chk('read state: I read only my own rows', (r2 ->> 'n')::int >= 1, 'got ' || coalesce(r2::text, 'null'));

  -- ═══ the consent backfill ═══
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Hub Backfill One', oa, '+9779801000041') RETURNING id INTO x_id;
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status)
    VALUES (a1, tr, x_id, 'Hub Backfill One', current_date + 40, '10:00', '10:30', (current_date + 40)::timestamp + time '10:00', (current_date + 40)::timestamp + time '10:30', 1000, 1000, 'Pending');
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Hub Backfill Stopped', oa, '+9779801000042') RETURNING id INTO pat4;
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status)
    VALUES (a1, tr, pat4, 'Hub Backfill Stopped', current_date + 41, '10:00', '10:30', (current_date + 41)::timestamp + time '10:00', (current_date + 41)::timestamp + time '10:30', 1000, 1000, 'Pending');
  INSERT INTO patient_channels (org_id, customer_id, channel, address, purpose, status, source, evidence) VALUES (oa, pat4, 'sms', '+9779801000042', 'service', 'stopped', 'patient_reply', 'STOP')
    ON CONFLICT (org_id, channel, address, purpose) DO UPDATE SET status = 'stopped', source = 'patient_reply', evidence = 'STOP';   -- 015's booking trigger may have recorded 'agreed' first
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Hub Backfill NoBooking', oa, '+9779801000043');
  DELETE FROM patient_channels WHERE org_id = oa AND address = '+9779801000041';   -- the backfill is for bookings made BEFORE 015's trigger: remove the row the trigger just recorded
  r2 := pg_temp.act_run('service', format('SELECT public.hub_backfill_booking_consent(%L, true)', oa), 0);
  PERFORM pg_temp.act_chk('backfill: not callable by the service role (owner only)', pg_temp.act_code(r2) = 'raised:42501', 'got ' || coalesce(r2::text, 'null'));
  r2 := public.hub_backfill_booking_consent(oa, true);
  PERFORM pg_temp.act_chk('backfill: a dry run counts and inserts nothing', (r2 ->> 'would_insert')::int >= 1 AND (r2 ->> 'inserted')::int = 0
    AND NOT EXISTS (SELECT 1 FROM patient_channels WHERE address = '+9779801000041'), 'got ' || coalesce(r2::text, 'null'));
  r2 := public.hub_backfill_booking_consent(oa, false);
  PERFORM pg_temp.act_chk('backfill: a patient with a phone and a booking gets service sms "agreed", source booking, with evidence', (SELECT (status, source, purpose, recorded_by IS NULL, evidence LIKE 'Phone given when booking%') FROM patient_channels WHERE org_id = oa AND address = '+9779801000041' AND channel = 'sms' AND purpose = 'service') = ('agreed'::text, 'booking'::text, 'service'::text, true, true), 'got ' || coalesce(r2::text, 'null'));
  PERFORM pg_temp.act_chk('backfill: never touches a stopped row', (SELECT status FROM patient_channels WHERE org_id = oa AND address = '+9779801000042' AND purpose = 'service') = 'stopped', 'stopped row');
  PERFORM pg_temp.act_chk('backfill: never creates a marketing row, and skips patients with no booking', NOT EXISTS (SELECT 1 FROM patient_channels WHERE org_id = oa AND address IN ('+9779801000041', '+9779801000043') AND purpose = 'marketing')
    AND NOT EXISTS (SELECT 1 FROM patient_channels WHERE address = '+9779801000043'), 'marketing / no booking');
  n := (r2 ->> 'inserted')::int;
  r2 := public.hub_backfill_booking_consent(oa, false);
  PERFORM pg_temp.act_chk('backfill: running it twice inserts nothing new', (r2 ->> 'inserted')::int = 0 AND n >= 1, 'got ' || coalesce(r2::text, 'null'));

  -- every hub action wrote exactly one log row (asserted on each call above); the log is still append-only
  r2 := pg_temp.act_run('staff', 'SELECT jsonb_build_object(''n'', count(*)) FROM public.action_log WHERE action LIKE ''message.%'' OR action LIKE ''conversation.%'' OR action = ''consent.record''', 0);
  PERFORM pg_temp.act_chk('hub actions are in the log and staff of the branch can read their own', (r2 ->> 'n')::int >= 10, 'got ' || coalesce(r2::text, 'null'));

  -- clean up everything this section created (action_log rows stay until the final ROLLBACK: the log is append-only)
  EXECUTE 'RESET ROLE';
  DELETE FROM conversations WHERE org_id IN (oa, ob);   -- messages and reads go with them
  DELETE FROM patient_channels WHERE org_id IN (oa, ob);
  DELETE FROM channel_accounts WHERE org_id IN (oa, ob);
  DELETE FROM message_templates WHERE org_id IN (oa, ob);
  DELETE FROM bookings WHERE customer_id IN (SELECT id FROM customers WHERE full_name LIKE 'Hub %');
  DELETE FROM customers WHERE full_name LIKE 'Hub %';
  DELETE FROM t_actor WHERE name IN ('hub_p1', 'hub_p2', 'hub_prof', 'hub_staff_a2');
  DELETE FROM public.users WHERE id IN (u_p1, u_p2, u_prof, u_staff2);
  DELETE FROM auth.users WHERE id IN (u_p1, u_p2, u_prof, u_staff2);
  DELETE FROM dentists WHERE id IN (d1, d2, dprof);
END $hub$;
-- HUB-END

-- ───────────────────────────── 3c. PER-CLINIC AI SWITCH + PHONE CODE LIMITS (migration-010) ─────────────────────────────
DO $ai$
DECLARE
  oa uuid; ob uuid; ua uuid; r text; n int; last_r text;
BEGIN
  -- a database that has not had migration-010 yet (e.g. a pre-010 production copy) skips this whole section
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'organizations' AND column_name = 'ai_consultation_enabled')
     OR to_regprocedure('public.org_ai_enabled()') IS NULL THEN
    INSERT INTO t_res VALUES ('AISWITCH', '-', 'migration-010 checks', 'INFO', 'skipped: ai_consultation_enabled / org_ai_enabled() not present (migration-010 not applied)');
    RETURN;
  END IF;
  SELECT org, uid INTO oa, ua FROM t_actor WHERE name = 'admin';
  SELECT org INTO ob FROM t_actor WHERE name = 'admin_of_OTHER_org';

  -- (a) nobody but the platform may flip the switch: a clinic admin's / manager's UPDATE must touch 0 rows (no UPDATE policy on organizations)
  FOR r IN SELECT unnest(ARRAY['admin', 'manager_2_branches', 'admin_of_OTHER_org']) LOOP
    INSERT INTO t_res VALUES ('AISWITCH', r, 'UPDATE organizations SET ai_consultation_enabled',
      CASE WHEN pg_temp.fn_try(r, format('UPDATE organizations SET ai_consultation_enabled = true WHERE id IN (%L, %L) RETURNING 1', oa, ob)) IN ('ok:0', 'denied') THEN 'PASS' ELSE 'FAIL' END,
      'got ' || pg_temp.fn_try(r, format('UPDATE organizations SET ai_consultation_enabled = true WHERE id IN (%L, %L) RETURNING 1', oa, ob)));
  END LOOP;

  -- (b) org_ai_enabled(): false by default, true only for an enabled clinic, never callable by anon
  INSERT INTO t_res VALUES ('AISWITCH', 'admin', 'org_ai_enabled() default org is false',
    CASE WHEN pg_temp.fn_try('admin', 'SELECT 1 WHERE org_ai_enabled()') = 'ok:0' THEN 'PASS' ELSE 'FAIL' END, 'default is off');
  UPDATE organizations SET ai_consultation_enabled = true WHERE id = ob;   -- as the table owner, rolled back with the test
  INSERT INTO t_res VALUES ('AISWITCH', 'admin_of_OTHER_org', 'org_ai_enabled() enabled org is true',
    CASE WHEN pg_temp.fn_try('admin_of_OTHER_org', 'SELECT 1 WHERE org_ai_enabled()') = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'enabled org B');
  INSERT INTO t_res VALUES ('AISWITCH', 'admin', 'org_ai_enabled() still false for org A while B is on',
    CASE WHEN pg_temp.fn_try('admin', 'SELECT 1 WHERE org_ai_enabled()') = 'ok:0' THEN 'PASS' ELSE 'FAIL' END, 'org A unaffected');
  INSERT INTO t_res VALUES ('AISWITCH', 'anon', 'org_ai_enabled() denied',
    CASE WHEN pg_temp.fn_try('anon', 'SELECT org_ai_enabled()') = 'denied' THEN 'PASS' ELSE 'FAIL' END, 'anon has no EXECUTE');
  INSERT INTO t_res VALUES ('AISWITCH', 'customer_no_staff_row', 'org_ai_enabled() is false without a clinic',
    CASE WHEN pg_temp.fn_try('customer_no_staff_row', 'SELECT 1 WHERE org_ai_enabled()') = 'ok:0' THEN 'PASS' ELSE 'FAIL' END, 'no staff row');

  -- (c) phone code limits (service_role function, called here as the table owner): signin 5 / 10 min, verify 30 / 10 min, counted per purpose
  last_r := '';
  FOR n IN 1..6 LOOP
    last_r := phone_pairing_create(ua, 'h-signin-' || n, 's-signin-' || n, 'signin', now() + interval '5 minutes');
    IF n = 5 THEN INSERT INTO t_res VALUES ('PAIRLIMIT', 'service', 'signin code #5', CASE WHEN last_r = 'ok' THEN 'PASS' ELSE 'FAIL' END, last_r); END IF;
  END LOOP;
  INSERT INTO t_res VALUES ('PAIRLIMIT', 'service', 'signin code #6 is rate limited', CASE WHEN last_r = 'rate_limited' THEN 'PASS' ELSE 'FAIL' END, last_r);
  FOR n IN 1..31 LOOP
    last_r := phone_pairing_create(ua, 'h-verify-' || n, 's-verify-' || n, 'verify', now() + interval '5 minutes');
    IF n = 30 THEN INSERT INTO t_res VALUES ('PAIRLIMIT', 'service', 'verify code #30 (after 5 signin)', CASE WHEN last_r = 'ok' THEN 'PASS' ELSE 'FAIL' END, last_r); END IF;
  END LOOP;
  INSERT INTO t_res VALUES ('PAIRLIMIT', 'service', 'verify code #31 is rate limited', CASE WHEN last_r = 'rate_limited' THEN 'PASS' ELSE 'FAIL' END, last_r);
  INSERT INTO t_res VALUES ('PAIRLIMIT', 'authenticated', 'phone_pairing_create is not callable by clients',
    CASE WHEN pg_temp.fn_try('admin', format('SELECT phone_pairing_create(%L, ''x'', ''y'', ''verify'', now())', ua)) = 'denied' THEN 'PASS' ELSE 'FAIL' END, 'service_role only');
END $ai$;

-- ───────────────────────────── 3c. MONEY FUNCTION GUARD (migration-014, CMD-83) ─────────────────────────────
-- SECURITY DEFINER money functions skip RLS, so each must refuse roles that may not touch money. practitioner: no money at all;
-- admin_viewer: money reads only. Needs 011 (practitioner) and 014; otherwise skipped. Seeds its own rows (rolled back with the script).
CREATE FUNCTION pg_temp.m_val(p_actor text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE a record; claims text; res text;
BEGIN
  SELECT * INTO a FROM t_actor WHERE name = p_actor;
  claims := CASE WHEN a.uid IS NULL THEN '{"role":"anon"}' ELSE json_build_object('sub', a.uid, 'role', 'authenticated')::text END;
  BEGIN
    EXECUTE format('SET LOCAL ROLE %I', a.db_role);
    PERFORM set_config('request.jwt.claims', claims, true);
    EXECUTE p_sql INTO res;
    res := 'ok:' || coalesce(res, 'NULL');
  EXCEPTION WHEN OTHERS THEN res := CASE WHEN SQLSTATE = '42501' THEN 'denied' ELSE 'raised:' || SQLSTATE END;
  END;
  EXECUTE 'RESET ROLE';
  RETURN res;
END $$;
CREATE FUNCTION pg_temp.m_chk(p_label text, p_ok boolean, p_detail text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO t_res VALUES ('MONEY', '-', p_label, CASE WHEN COALESCE(p_ok, false) THEN 'PASS' ELSE 'FAIL' END, p_detail);
  IF NOT COALESCE(p_ok, false) THEN RAISE NOTICE 'FAILED CHECK: % -- %', p_label, left(p_detail, 300); END IF;
END $$;

DO $money$
DECLARE
  oa uuid; ob uuid; a1 uuid; tr uuid; cu uuid; cu2 uuid; cu3 uuid; d1 uuid; u_staff uuid; u_adm uuid; sfx text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  u_prac uuid := gen_random_uuid(); bk uuid; bk2 uuid; bk_b uuid; tier uuid; vt uuid; ref uuid; ref2 uuid; r jsonb; v text; z uuid := gen_random_uuid();
  t record; w record; cnt int; bad text;
BEGIN
  IF to_regprocedure('public.can_write_money()') IS NULL OR to_regprocedure('public.is_my_booking_row(uuid,uuid)') IS NULL THEN
    INSERT INTO t_res VALUES ('MONEY', '-', 'migration-011/014 checks', 'INFO', 'skipped: can_write_money() (014) or the practitioner role (011) not present');
    RETURN;
  END IF;
  SELECT org, uid INTO oa, u_staff FROM t_actor WHERE name = 'staff'; SELECT uid INTO u_adm FROM t_actor WHERE name = 'admin';
  SELECT org INTO ob FROM t_actor WHERE name = 'admin_of_OTHER_org';
  SELECT s.pk::uuid INTO a1 FROM t_seed s JOIN branches b ON b.id = s.pk::uuid WHERE s.tbl = 'branches' AND s.org = oa AND b.name = 'A1';
  SELECT s.pk::uuid INTO tr FROM t_seed s WHERE s.tbl = 'treatments' AND s.org = oa LIMIT 1;
  SELECT s.pk::uuid INTO cu FROM t_seed s JOIN customers c ON c.id = s.pk::uuid WHERE s.tbl = 'customers' AND s.org = oa AND c.branch_id = a1 LIMIT 1;
  SELECT d.id INTO d1 FROM dentists d JOIN t_seed s ON s.tbl = 'dentists' AND s.pk = d.id::text WHERE d.branch_id = a1 AND d.name = 'Dr A1';
  SELECT s.pk::uuid INTO bk_b FROM t_seed s WHERE s.tbl = 'bookings' AND s.org = ob LIMIT 1;

  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at) VALUES (u_prac, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-mprac-' || sfx || '@test.invalid', now(), now());
  UPDATE public.users SET dentist_id = NULL WHERE id IN (SELECT uid FROM t_actor WHERE name = 'practitioner');   -- merge glue (CMD-79 + CMD-78): dentist_id is unique; the shared practitioner is re-linked at the start of section 3d
  INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active, dentist_id) VALUES (u_prac, 'rls-mprac-' || sfx || '@test.invalid', 'RLS money practitioner', 'practitioner', a1, oa, true, d1);
  INSERT INTO t_actor VALUES ('money_practitioner', u_prac, oa, 'authenticated');
  INSERT INTO customers (branch_id, full_name, org_id) VALUES (a1, 'Referred Cust', oa) RETURNING id INTO cu2;

  -- 1. helpers: allow-lists, and not executable by anon
  PERFORM pg_temp.m_chk('can_read_money: staff, admin, admin_viewer yes; practitioner no',
    pg_temp.m_val('staff', 'SELECT can_read_money()') = 'ok:true' AND pg_temp.m_val('admin', 'SELECT can_read_money()') = 'ok:true'
    AND pg_temp.m_val('admin_viewer', 'SELECT can_read_money()') = 'ok:true' AND pg_temp.m_val('money_practitioner', 'SELECT can_read_money()') = 'ok:false', 'allow-list');
  PERFORM pg_temp.m_chk('can_write_money: staff, manager, admin yes; admin_viewer and practitioner no',
    pg_temp.m_val('staff', 'SELECT can_write_money()') = 'ok:true' AND pg_temp.m_val('manager_2_branches', 'SELECT can_write_money()') = 'ok:true'
    AND pg_temp.m_val('admin', 'SELECT can_write_money()') = 'ok:true' AND pg_temp.m_val('admin_viewer', 'SELECT can_write_money()') = 'ok:false'
    AND pg_temp.m_val('money_practitioner', 'SELECT can_write_money()') = 'ok:false', 'allow-list');
  PERFORM pg_temp.m_chk('can_*_money: customer with no staff row gets false (unknown role = false)',
    pg_temp.m_val('customer_no_staff_row', 'SELECT can_read_money()') = 'ok:false' AND pg_temp.m_val('customer_no_staff_row', 'SELECT can_write_money()') = 'ok:false', 'no role');
  PERFORM pg_temp.m_chk('can_read_money / can_write_money are not executable by anon',
    pg_temp.m_val('anon', 'SELECT can_read_money()') = 'denied' AND pg_temp.m_val('anon', 'SELECT can_write_money()') = 'denied', 'anon');

  -- 2. every guarded WRITE function is refused for practitioner and admin_viewer, and not refused by the guard for staff
  FOR t IN SELECT * FROM (VALUES
    ('record_membership_payment',            format('SELECT record_membership_payment(%L, 10, NULL)', z)),
    ('record_voucher_wallet_payment',        format('SELECT record_voucher_wallet_payment(%L, %L, 10, NULL)', z, z)),
    ('record_voucher_wallet_payment_pooled', format('SELECT record_voucher_wallet_payment_pooled(%L, 10, NULL)', z)),
    ('record_referral_wallet_payment',       format('SELECT record_referral_wallet_payment(%L, 10, NULL)', z)),
    ('redeem_referral_voucher',              format('SELECT redeem_referral_voucher(%L, %L)', z, z)),
    ('record_customer_referral (7 args)',    format('SELECT record_customer_referral(%L, %L, %L, NULL::text, NULL::text, NULL::numeric, NULL::uuid)', z, z, z))
  ) x(label, q) LOOP
    PERFORM pg_temp.m_chk('write ' || t.label || ': practitioner refused', pg_temp.m_val('money_practitioner', t.q) = 'denied', pg_temp.m_val('money_practitioner', t.q));
    PERFORM pg_temp.m_chk('write ' || t.label || ': admin_viewer refused', pg_temp.m_val('admin_viewer', t.q) = 'denied', pg_temp.m_val('admin_viewer', t.q));
    v := pg_temp.m_val('staff', t.q);
    PERFORM pg_temp.m_chk('write ' || t.label || ': staff is past the guard (fails later on the dummy ids, not with 42501)', v LIKE 'raised:%' AND v <> 'denied', v);
  END LOOP;

  -- the 4- and 6-argument overloads cannot be called unambiguously with dummy ids (Postgres sees 42725 between the defaulted overloads), so check their bodies
  PERFORM pg_temp.m_chk('write record_customer_referral (' || o.nargs || ' args): body starts with the can_write_money() guard',
    pg_get_functiondef(o.oid) ~ 'BEGIN\s+IF NOT public\.can_write_money\(\) THEN', pg_get_functiondef(o.oid))
    FROM (SELECT oid, pronargs AS nargs FROM pg_proc WHERE proname = 'record_customer_referral' AND pronamespace = 'public'::regnamespace) o;

  -- 3. READ functions: practitioner gets nothing; admin_viewer and staff still read. Seed rows so "reads work" is a real signal.
  INSERT INTO membership_tiers (org_id, name, code_prefix, advance_amount) VALUES (oa, 'Money tier ' || sfx, 'MT', 100) RETURNING id INTO tier;
  INSERT INTO memberships (org_id, customer_id, tier_id) VALUES (oa, cu, tier);
  INSERT INTO voucher_types (org_id, name, code_prefix) VALUES (oa, 'Money vt ' || sfx, 'MV') RETURNING id INTO vt;
  INSERT INTO vouchers (org_id, branch_id, customer_id, voucher_type_id, voucher_code, guest_name, actual_price, total_amount_issued, issued_date, expiry_date)
    VALUES (oa, a1, cu, vt, 'MV-' || sfx, 'Money Guest', 100, 100, current_date, current_date + 30);
  UPDATE users SET pin = '1234' WHERE id = u_adm;
  INSERT INTO customer_referrals (org_id, referring_customer_id, referred_customer_id, booking_id, reward_status, reward_type, requested_reward_amount)
    SELECT oa, cu, cu2, b.id, 'pending', 'wallet', 50 FROM bookings b WHERE b.customer_id = cu LIMIT 1 RETURNING id INTO ref;
  FOR t IN SELECT * FROM (VALUES
    ('list_membership_status_for_org', format('SELECT count(*)::text FROM list_membership_status_for_org(%L)', cu)),
    ('list_vouchers_for_customer',     format('SELECT count(*)::text FROM list_vouchers_for_customer(%L)', cu)),
    ('search_vouchers_for_payment',    format('SELECT count(*)::text FROM search_vouchers_for_payment(%L)', 'MV-' || sfx)),
    ('list_discount_approvers',        'SELECT count(*)::text FROM list_discount_approvers()')
  ) x(label, q) LOOP
    v := pg_temp.m_val('money_practitioner', t.q);
    PERFORM pg_temp.m_chk('read ' || t.label || ': practitioner gets no rows', v = 'ok:0', v);
    v := pg_temp.m_val('admin_viewer', t.q);
    PERFORM pg_temp.m_chk('read ' || t.label || ': admin_viewer still reads', v LIKE 'ok:%' AND v <> 'ok:0', v);
    v := pg_temp.m_val('staff', t.q);
    PERFORM pg_temp.m_chk('read ' || t.label || ': staff still reads', v LIKE 'ok:%' AND v <> 'ok:0', v);
  END LOOP;
  INSERT INTO customer_referral_credits (org_id, referral_id, customer_id, amount) VALUES (oa, ref, cu, 25);
  PERFORM pg_temp.m_chk('read get_referral_credit_balance: practitioner NULL, admin_viewer and staff 25',
    pg_temp.m_val('money_practitioner', format('SELECT get_referral_credit_balance(%L)', cu)) = 'ok:NULL'
    AND pg_temp.m_val('admin_viewer', format('SELECT get_referral_credit_balance(%L)', cu)) = 'ok:25.00'
    AND pg_temp.m_val('staff', format('SELECT get_referral_credit_balance(%L)', cu)) = 'ok:25.00', 'balance');
  DELETE FROM customer_referral_credits WHERE referral_id = ref;
  DELETE FROM customer_referrals WHERE id = ref;

  -- 4. referral credit: the public name is a guarded wrapper; the body is internal. Complete a paid booking with a pending referral.
  PERFORM pg_temp.m_chk('internal _credit_pending_referral_for_booking: not executable by anon or authenticated',
    NOT has_function_privilege('anon', 'public._credit_pending_referral_for_booking(uuid)', 'execute')
    AND NOT has_function_privilege('authenticated', 'public._credit_pending_referral_for_booking(uuid)', 'execute')
    AND pg_temp.m_val('staff', format('SELECT _credit_pending_referral_for_booking(%L)', z)) = 'denied', 'internal');
  -- (a) a practitioner completes their own paid booking -> the referrer is credited (through act_booking_set_status)
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, dentist_id, payment_status)
    VALUES (a1, tr, cu2, 'Referred Cust', '2031-04-01', '10:00', '10:30', '2031-04-01 10:00+00', '2031-04-01 10:30+00', 1000, 1000, 'In-Progress', d1, 'paid') RETURNING id INTO bk;
  INSERT INTO booking_dentists (booking_id, dentist_id) VALUES (bk, d1);
  INSERT INTO customer_referrals (org_id, referring_customer_id, referred_customer_id, booking_id, reward_status, reward_type, requested_reward_amount)
    VALUES (oa, cu, cu2, bk, 'pending', 'wallet', 50) RETURNING id INTO ref;
  r := pg_temp.act_run('money_practitioner', format('SELECT public.act_booking_set_status(%L, ''Completed'')', bk));
  PERFORM pg_temp.m_chk('practitioner completes a paid booking with a pending referral: the credit happens',
    pg_temp.act_code(r) = 'ok' AND (SELECT reward_status FROM customer_referrals WHERE id = ref) = 'credited'
    AND (SELECT amount FROM customer_referral_credits WHERE referral_id = ref) = 50, 'got ' || coalesce(r::text, 'null'));
  -- (b) the service role (an agent) completes one -> the credit happens
  INSERT INTO customers (branch_id, full_name, org_id) VALUES (a1, 'Referred Cust 3', oa) RETURNING id INTO cu3;
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, dentist_id, payment_status)
    VALUES (a1, tr, cu3, 'Referred Cust 3', '2031-04-02', '10:00', '10:30', '2031-04-02 10:00+00', '2031-04-02 10:30+00', 1000, 1000, 'In-Progress', d1, 'paid') RETURNING id INTO bk2;
  INSERT INTO customer_referrals (org_id, referring_customer_id, referred_customer_id, booking_id, reward_status, reward_type, requested_reward_amount)
    VALUES (oa, cu, cu3, bk2, 'pending', 'wallet', 50) RETURNING id INTO ref2;
  -- today an agent cannot set Completed at all (act_booking_set_status refuses it), so this path never reaches the credit; check that, then
  -- check the internal function itself works without a signed-in user (auth.uid() NULL) for any future agent / rule caller
  r := pg_temp.act_run('service', format('SELECT public.act_booking_set_status(%L, ''Completed'', NULL, %L::jsonb)', bk2, jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa)));
  PERFORM pg_temp.m_chk('service role (agent) cannot complete a booking (FORBIDDEN): booking and referral untouched',
    pg_temp.act_code(r) = 'FORBIDDEN' AND (SELECT status FROM bookings WHERE id = bk2) = 'In-Progress' AND (SELECT reward_status FROM customer_referrals WHERE id = ref2) = 'pending', 'got ' || coalesce(r::text, 'null'));
  UPDATE bookings SET status = 'Completed' WHERE id = bk2;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM public._credit_pending_referral_for_booking(bk2);
  PERFORM pg_temp.m_chk('internal credit function works with no signed-in user (auth.uid() NULL): the credit happens',
    (SELECT reward_status FROM customer_referrals WHERE id = ref2) = 'credited' AND (SELECT amount FROM customer_referral_credits WHERE referral_id = ref2) = 50
    AND (SELECT credited_by FROM customer_referrals WHERE id = ref2) IS NULL, 'internal');
  -- (c) another org's user calling the public wrapper is a no-op; the referral stays pending (reset the first referral; the booking is Completed and paid)
  DELETE FROM customer_referral_credits WHERE referral_id = ref;
  UPDATE customer_referrals SET reward_status = 'pending', reward_amount = NULL, credited_at = NULL, credited_by = NULL WHERE id = ref;
  v := pg_temp.m_val('admin_of_OTHER_org', format('SELECT credit_pending_referral_for_booking(%L)', bk));
  PERFORM pg_temp.m_chk('another org''s admin calling credit_pending_referral_for_booking: no-op, referral still pending',
    v = 'ok:NULL' AND (SELECT reward_status FROM customer_referrals WHERE id = ref) = 'pending'
    AND NOT EXISTS (SELECT 1 FROM customer_referral_credits WHERE referral_id = ref), v);
  -- (d) admin_viewer gets no credit trigger; a same-org staff call still credits
  v := pg_temp.m_val('admin_viewer', format('SELECT credit_pending_referral_for_booking(%L)', bk));
  PERFORM pg_temp.m_chk('admin_viewer calling credit_pending_referral_for_booking: no-op', v = 'ok:NULL' AND (SELECT reward_status FROM customer_referrals WHERE id = ref) = 'pending', v);
  v := pg_temp.m_val('staff', format('SELECT credit_pending_referral_for_booking(%L)', bk));
  PERFORM pg_temp.m_chk('staff calling credit_pending_referral_for_booking (booking Completed and paid): credits',
    v LIKE 'ok:%' AND v <> 'ok:NULL' AND (SELECT reward_status FROM customer_referrals WHERE id = ref) = 'credited', v);

  -- 5. role coverage: no SECURITY DEFINER function executable by authenticated that reads a money table lacks a role check
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef AND p.prokind = 'f' AND has_function_privilege('authenticated', p.oid, 'execute')
    AND pg_get_functiondef(p.oid) ~* '\m(memberships|membership_transactions|membership_tiers|vouchers|voucher_claims|voucher_types|packages|customer_packages|payments|payroll[a-z_]*|commission[a-z_]*|expenses|customer_referral_credits|customer_referral_debits|customer_referrals|reward_catalog)\M'
    AND pg_get_functiondef(p.oid) !~* '(not in \(|in \(''|can_(read|write)_money|is_platform_admin|is distinct from ''(admin|manager|staff)|_act_resolve|_hub_scope)'
    -- named exceptions: anon-executable booking-flow function, tracked in CMD-44 (not fixed by CMD-83)
    AND p.oid::regprocedure::text <> 'public_record_customer_referral(text,uuid,uuid,uuid)';
  PERFORM pg_temp.m_chk('role coverage: every authenticated-executable definer function reading a money table has a role check', bad IS NULL, coalesce(bad, 'none'));
END $money$;

-- ───────────────────────────── 3d. BOOKING CONSENT (migration-015, CMD-93) ─────────────────────────────
-- A booking records service-SMS consent for the patient's phone (patient_channels: sms / service / agreed / booking) by trigger, unless the
-- clinic's switch is off. It never changes an existing row, never creates marketing, and never fails the booking. Skipped if 015 is absent.
CREATE FUNCTION pg_temp.c_book(p_branch uuid, p_tr uuid, p_cust uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE i uuid := gen_random_uuid(); d date := date '2032-01-01' + (random() * 3000)::int;
BEGIN
  INSERT INTO bookings (id, branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, payment_status)
    VALUES (i, p_branch, p_tr, p_cust, 'Consent test', d, '10:00', '10:30', (d || ' 10:00+00')::timestamptz, (d || ' 10:30+00')::timestamptz, 1000, 1000, 'Pending', 'unpaid');
  RETURN i;
END $$;
CREATE FUNCTION pg_temp.c_chk(p_label text, p_ok boolean, p_detail text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO t_res VALUES ('CONSENT', '-', p_label, CASE WHEN COALESCE(p_ok, false) THEN 'PASS' ELSE 'FAIL' END, p_detail);
  IF NOT COALESCE(p_ok, false) THEN RAISE NOTICE 'FAILED CHECK: % -- %', p_label, left(p_detail, 300); END IF;
END $$;

DO $consent$
DECLARE
  oa uuid; a1 uuid; tr uuid; sfx text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  c1 uuid; c2 uuid; c3 uuid; c4 uuid; c5 uuid; c6 uuid; c7 uuid; ca uuid; bk uuid;
  p1 text; p2 text; p4 text; p6 text; p7 text; pa text; a1e text; r record; n int; ok boolean;
BEGIN
  IF to_regprocedure('public.trg_booking_record_service_consent()') IS NULL OR to_regclass('public.patient_channels') IS NULL THEN
    INSERT INTO t_res VALUES ('CONSENT', '-', 'migration-015 checks', 'INFO', 'skipped: trg_booking_record_service_consent (015) not present');
    RETURN;
  END IF;
  SELECT org INTO oa FROM t_actor WHERE name = 'admin';
  SELECT s.pk::uuid INTO a1 FROM t_seed s JOIN branches b ON b.id = s.pk::uuid WHERE s.tbl = 'branches' AND s.org = oa AND b.name = 'A1';
  SELECT s.pk::uuid INTO tr FROM t_seed s WHERE s.tbl = 'treatments' AND s.org = oa LIMIT 1;
  p1 := '98' || lpad((random() * 99999999)::int::text, 8, '0'); p2 := '97' || lpad((random() * 99999999)::int::text, 8, '0');
  p4 := '98' || lpad((random() * 99999999)::int::text, 8, '0'); p6 := '97' || lpad((random() * 99999999)::int::text, 8, '0');
  p7 := '98' || lpad((random() * 99999999)::int::text, 8, '0'); pa := '97' || lpad((random() * 99999999)::int::text, 8, '0');
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Consent new ' || sfx, oa, p1) RETURNING id INTO c1;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Consent stopped ' || sfx, oa, p2) RETURNING id INTO c2;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Consent nophone ' || sfx, oa, NULL) RETURNING id INTO c3;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Consent switchoff ' || sfx, oa, p4) RETURNING id INTO c4;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Consent badphone ' || sfx, oa, 'n/a') RETURNING id INTO c5;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Consent rowfail ' || sfx, oa, p6) RETURNING id INTO c6;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Consent later ' || sfx, oa, p7) RETURNING id INTO c7;

  -- 1. a new booking for a patient with a phone and no row: one agreed service-sms row from 'booking'
  bk := pg_temp.c_book(a1, tr, c1);
  SELECT count(*) AS n, min(status) AS st, min(source) AS src, min(evidence) AS ev, min(customer_id::text) AS cu INTO r FROM patient_channels
    WHERE org_id = oa AND channel = 'sms' AND address = public.normalize_phone_e164(p1) AND purpose = 'service';
  PERFORM pg_temp.c_chk('new booking, patient with a phone, no row: one agreed service-sms row (source booking, evidence names the booking)',
    r.n = 1 AND r.st = 'agreed' AND r.src = 'booking' AND r.ev LIKE 'Phone given when booking %' AND r.cu = c1::text, row_to_json(r)::text);
  -- 1b. a second booking for the same patient changes nothing
  bk := pg_temp.c_book(a1, tr, c1);
  SELECT count(*) INTO n FROM patient_channels WHERE org_id = oa AND address = public.normalize_phone_e164(p1);
  PERFORM pg_temp.c_chk('a second booking for the same patient adds no row', n = 1, n::text);
  -- 2. already stopped: stays stopped, no new row
  INSERT INTO patient_channels (org_id, customer_id, channel, address, purpose, status, source, evidence)
    VALUES (oa, c2, 'sms', public.normalize_phone_e164(p2), 'service', 'stopped', 'patient_reply', 'replied STOP');
  bk := pg_temp.c_book(a1, tr, c2);
  SELECT count(*) AS n, min(status) AS st, min(source) AS src INTO r FROM patient_channels WHERE org_id = oa AND address = public.normalize_phone_e164(p2);
  PERFORM pg_temp.c_chk('patient already stopped: still stopped after a new booking, no new row, source unchanged', r.n = 1 AND r.st = 'stopped' AND r.src = 'patient_reply', row_to_json(r)::text);
  -- 3. marketing is never created
  SELECT count(*) INTO n FROM patient_channels WHERE org_id = oa AND purpose = 'marketing' AND address IN (public.normalize_phone_e164(p1), public.normalize_phone_e164(p2));
  PERFORM pg_temp.c_chk('marketing consent is never created by a booking', n = 0, n::text);
  -- 4. switch off for the clinic: no row; back on: the next booking records it
  UPDATE organizations SET booking_phone_is_service_consent = false WHERE id = oa;
  bk := pg_temp.c_book(a1, tr, c4);
  SELECT count(*) INTO n FROM patient_channels WHERE org_id = oa AND address = public.normalize_phone_e164(p4);
  PERFORM pg_temp.c_chk('clinic switch false: no row', n = 0, n::text);
  UPDATE organizations SET booking_phone_is_service_consent = true WHERE id = oa;
  bk := pg_temp.c_book(a1, tr, c4);
  SELECT count(*) INTO n FROM patient_channels WHERE org_id = oa AND address = public.normalize_phone_e164(p4) AND status = 'agreed';
  PERFORM pg_temp.c_chk('clinic switch back on: the next booking records the row', n = 1, n::text);
  SELECT booking_phone_is_service_consent INTO ok FROM organizations WHERE id = oa;
  PERFORM pg_temp.c_chk('the switch defaults to true', (SELECT column_default FROM information_schema.columns WHERE table_name = 'organizations' AND column_name = 'booking_phone_is_service_consent') = 'true' AND ok, 'default');
  -- 5. no phone / unparseable phone: the booking succeeds, no row
  bk := pg_temp.c_book(a1, tr, c3);
  PERFORM pg_temp.c_chk('patient with no phone: booking succeeds, no row', EXISTS (SELECT 1 FROM bookings WHERE id = bk) AND NOT EXISTS (SELECT 1 FROM patient_channels WHERE customer_id = c3), 'no phone');
  bk := pg_temp.c_book(a1, tr, c5);
  PERFORM pg_temp.c_chk('patient with an unparseable phone: booking succeeds, no row', EXISTS (SELECT 1 FROM bookings WHERE id = bk) AND NOT EXISTS (SELECT 1 FROM patient_channels WHERE customer_id = c5), 'bad phone');
  -- 6. a booking that gets its patient later (UPDATE customer_id)
  INSERT INTO bookings (id, branch_id, treatment_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, payment_status)
    VALUES (gen_random_uuid(), a1, tr, 'Walk-in', '2033-05-05', '10:00', '10:30', '2033-05-05 10:00+00', '2033-05-05 10:30+00', 1000, 1000, 'Pending', 'unpaid') RETURNING id INTO bk;
  PERFORM pg_temp.c_chk('walk-in booking (no patient) records nothing', NOT EXISTS (SELECT 1 FROM patient_channels WHERE address = public.normalize_phone_e164(p7)), 'before');
  UPDATE bookings SET customer_id = c7 WHERE id = bk;
  PERFORM pg_temp.c_chk('booking that gets its patient later (UPDATE customer_id) records the row',
    EXISTS (SELECT 1 FROM patient_channels WHERE org_id = oa AND address = public.normalize_phone_e164(p7) AND status = 'agreed' AND purpose = 'service'), 'after');
  -- 7. never fails a booking: make the consent insert fail (a constraint nothing satisfies), the booking must still succeed, with a WARNING
  ALTER TABLE patient_channels ADD CONSTRAINT zz_consent_test_fail CHECK (false) NOT VALID;
  bk := pg_temp.c_book(a1, tr, c6);
  ALTER TABLE patient_channels DROP CONSTRAINT zz_consent_test_fail;
  PERFORM pg_temp.c_chk('consent insert fails: the booking still succeeds, no row', EXISTS (SELECT 1 FROM bookings WHERE id = bk) AND NOT EXISTS (SELECT 1 FROM patient_channels WHERE customer_id = c6), 'error became a warning');
  -- 8. the public booking flow (anon): upsert_customer_for_booking, then a direct booking insert with the customer id
  EXECUTE 'SET LOCAL ROLE anon';
  PERFORM set_config('request.jwt.claims', '{"role":"anon"}', true);
  BEGIN
    ca := public.upsert_customer_for_booking(oa, a1, 'Consent anon ' || sfx, pa, NULL, NULL);
    bk := gen_random_uuid();
    INSERT INTO bookings (id, branch_id, treatment_id, customer_id, customer_name, customer_phone, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, payment_status)
      VALUES (bk, a1, tr, ca, 'Consent anon ' || sfx, pa, '2033-06-06', '10:00', '10:30', '2033-06-06 10:00+00', '2033-06-06 10:30+00', 1000, 1000, 'Pending', 'unpaid');
    ok := true;
  EXCEPTION WHEN OTHERS THEN ok := false; RAISE NOTICE 'anon booking failed: % %', SQLSTATE, SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.c_chk('public booking flow (anon): the booking is created', ok, 'anon');
  PERFORM pg_temp.c_chk('public booking flow (anon): the service-sms row is recorded',
    EXISTS (SELECT 1 FROM patient_channels WHERE org_id = oa AND address = public.normalize_phone_e164(pa) AND purpose = 'service' AND status = 'agreed' AND source = 'booking' AND customer_id = ca), 'anon row');
  -- 9. the trigger function is not callable by anon or authenticated
  PERFORM pg_temp.c_chk('trg_booking_record_service_consent is not executable by anon or authenticated',
    NOT has_function_privilege('anon', 'public.trg_booking_record_service_consent()', 'execute')
    AND NOT has_function_privilege('authenticated', 'public.trg_booking_record_service_consent()', 'execute'), 'revoked');
END $consent$;

-- ───────────────────────────── 3e. AGENT PLATFORM (migration-016, CMD-90) ─────────────────────────────
-- Settings / ceiling / playbooks / AI switch and budget actions, the work queue (propose, approve with the one-use grant, reject, expire), the
-- budget states, undo ('restore') and the read policies. Seeds its own rows (rolled back with the test). Skipped if 016 is absent.
CREATE FUNCTION pg_temp.g_chk(p_label text, p_ok boolean, p_detail text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO t_res VALUES ('AGENT', '-', p_label, CASE WHEN COALESCE(p_ok, false) THEN 'PASS' ELSE 'FAIL' END, p_detail);
  IF NOT COALESCE(p_ok, false) THEN RAISE NOTICE 'FAILED CHECK: % -- %', p_label, left(p_detail, 300); END IF;
END $$;

DO $agent$
DECLARE
  oa uuid; ob uuid; a1 uuid; a2 uuid; a3 uuid; b1 uuid; tr uuid; sfx text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  u_adm uuid; u_mgr uuid; u_staff uuid; u_view uuid; u_admb uuid; u_pr1 uuid := gen_random_uuid(); u_pr2 uuid := gen_random_uuid(); u_sa2 uuid := gen_random_uuid();
  d_pr1 uuid; d_pr2 uuid; pat uuid; pat_pr uuid; pat_stop uuid; pat_b uuid; bk uuid; bk_pr uuid; bk_pend uuid; acc uuid; t1 uuid; t2 uuid;
  pb1 uuid; pb2 uuid; pbb uuid; pb_off uuid; it uuid; it2 uuid; it3 uuid; it_pr uuid; it_exp uuid; it_stop uuid; it_ed uuid; it_st uuid; it_rej uuid;
  r jsonb; r2 jsonb; l record; n bigint; s jsonb; acts_a uuid; acts_b uuid; x text; svc_a text;
  ctx_fu text; ctx_sc text; ctx_b text; okx boolean;
  e_org uuid; e_br uuid; e_uid uuid := gen_random_uuid(); e_seed timestamptz; e_sfx text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
BEGIN
  IF to_regprocedure('public.act_work_approve(uuid,jsonb,jsonb)') IS NULL OR to_regclass('public.agent_work_items') IS NULL THEN
    INSERT INTO t_res VALUES ('AGENT', '-', 'migration-016 checks', 'INFO', 'skipped: the agent platform (016) is not present');
    RETURN;
  END IF;
  SELECT org, uid INTO oa, u_staff FROM t_actor WHERE name = 'staff';
  SELECT uid INTO u_adm FROM t_actor WHERE name = 'admin'; SELECT uid INTO u_mgr FROM t_actor WHERE name = 'manager_2_branches'; SELECT uid INTO u_view FROM t_actor WHERE name = 'admin_viewer';
  SELECT org, uid INTO ob, u_admb FROM t_actor WHERE name = 'admin_of_OTHER_org';
  SELECT s2.pk::uuid INTO a1 FROM t_seed s2 JOIN branches b ON b.id = s2.pk::uuid WHERE s2.tbl = 'branches' AND s2.org = oa AND b.name = 'A1';
  SELECT s2.pk::uuid INTO a2 FROM t_seed s2 JOIN branches b ON b.id = s2.pk::uuid WHERE s2.tbl = 'branches' AND s2.org = oa AND b.name = 'A2';
  SELECT s2.pk::uuid INTO b1 FROM t_seed s2 JOIN branches b ON b.id = s2.pk::uuid WHERE s2.tbl = 'branches' AND s2.org = ob AND b.name = 'B1';
  SELECT s2.pk::uuid INTO tr FROM t_seed s2 WHERE s2.tbl = 'treatments' AND s2.org = oa LIMIT 1;
  INSERT INTO branches (name, org_id) VALUES ('A3 agent test', oa) RETURNING id INTO a3;   -- a branch the manager does NOT work in
  ctx_fu := jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa)::text;
  ctx_sc := jsonb_build_object('actor_kind', 'agent', 'agent', 'scribe', 'org_id', oa)::text;
  ctx_b  := jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', ob)::text;

  -- people: two practitioners, front desk of A2 only
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (a1, 'Dr Agent1', 'Male', oa) RETURNING id INTO d_pr1;
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (a1, 'Dr Agent2', 'Female', oa) RETURNING id INTO d_pr2;
  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at) VALUES
    (u_pr1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-agpr1-' || sfx || '@test.invalid', now(), now()),
    (u_pr2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-agpr2-' || sfx || '@test.invalid', now(), now()),
    (u_sa2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-agsa2-' || sfx || '@test.invalid', now(), now());
  UPDATE public.users SET dentist_id = NULL WHERE id IN (SELECT uid FROM t_actor WHERE name = 'practitioner');   -- merge glue (CMD-79 + CMD-78): dentist_id is unique; the shared practitioner is re-linked at the start of section 3d
  INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active, dentist_id) VALUES
    (u_pr1, 'rls-agpr1-' || sfx || '@test.invalid', 'Agent Practitioner One', 'practitioner', a1, oa, true, d_pr1),
    (u_pr2, 'rls-agpr2-' || sfx || '@test.invalid', 'Agent Practitioner Two', 'practitioner', a1, oa, true, d_pr2),
    (u_sa2, 'rls-agsa2-' || sfx || '@test.invalid', 'Agent Front Desk A2', 'staff', a2, oa, true, NULL);
  INSERT INTO t_actor VALUES ('g_pr1', u_pr1, oa, 'authenticated'), ('g_pr2', u_pr2, oa, 'authenticated'), ('g_staff_a2', u_sa2, oa, 'authenticated');

  -- patients with consent (pat: any; pat_pr: Dr Agent1's patient; pat_stop: replied STOP), bookings, an sms test account, two templates
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Agent Pat', oa, '+9779802000001') RETURNING id INTO pat;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Agent Pat PR', oa, '+9779802000002') RETURNING id INTO pat_pr;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Agent Pat Stop', oa, '+9779802000003') RETURNING id INTO pat_stop;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (b1, 'Agent Pat B', ob, '+9779802000009') RETURNING id INTO pat_b;
  DELETE FROM patient_channels WHERE customer_id IN (pat, pat_pr, pat_stop);
  INSERT INTO patient_channels (org_id, customer_id, channel, address, purpose, status, source, evidence) VALUES
    (oa, pat, 'sms', '+9779802000001', 'service', 'agreed', 'booking', 'test'), (oa, pat_pr, 'sms', '+9779802000002', 'service', 'agreed', 'booking', 'test'),
    (oa, pat_stop, 'sms', '+9779802000003', 'service', 'stopped', 'patient_reply', 'replied STOP')
  ON CONFLICT (org_id, channel, address, purpose) DO UPDATE SET status = EXCLUDED.status;
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, customer_phone)
    VALUES (a1, tr, pat, 'Agent Pat', current_date + 200, '10:00', '10:30', (current_date + 200)::timestamp + time '10:00', (current_date + 200)::timestamp + time '10:30', 1000, 1000, 'Confirmed', '+9779802000001') RETURNING id INTO bk;
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, dentist_id)
    VALUES (a1, tr, pat_pr, 'Agent Pat PR', current_date + 201, '10:00', '10:30', (current_date + 201)::timestamp + time '10:00', (current_date + 201)::timestamp + time '10:30', 1000, 1000, 'Pending', d_pr1) RETURNING id INTO bk_pr;
  INSERT INTO booking_dentists (booking_id, dentist_id) VALUES (bk_pr, d_pr1);
  INSERT INTO bookings (branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status)
    VALUES (a1, tr, pat, 'Agent Pat', current_date + 202, '10:00', '10:30', (current_date + 202)::timestamp + time '10:00', (current_date + 202)::timestamp + time '10:30', 1000, 1000, 'Pending') RETURNING id INTO bk_pend;
  SELECT id INTO acc FROM channel_accounts WHERE org_id = oa AND channel = 'sms' AND provider = 'test' AND status = 'connected' LIMIT 1;
  IF acc IS NULL THEN
    INSERT INTO channel_accounts (org_id, channel, provider, sender, status, priority, credit_cost_npr)
      VALUES (oa, 'sms', 'test', '+977972' || lpad((random() * 999999)::int::text, 6, '0'), 'connected', 100, 1.5) RETURNING id INTO acc;
  END IF;
  UPDATE channel_accounts SET quiet_start = NULL, quiet_end = NULL WHERE id = acc;
  INSERT INTO message_templates (org_id, name, channel, language, body, purpose, clinical) VALUES
    (oa, 'agent-a-' || sfx, NULL, 'en', 'Hi {patient_name}, see you at {clinic}.', 'service', false) RETURNING id INTO t1;
  INSERT INTO message_templates (org_id, name, channel, language, body, purpose, clinical) VALUES
    (oa, 'agent-b-' || sfx, NULL, 'en', 'Hello {patient_name}, a reminder from {clinic}.', 'service', false) RETURNING id INTO t2;

  -- playbooks: clinic-wide (A), branch A2 only, switched off, and another org's
  INSERT INTO playbooks (org_id, branch_id, agent, key, name, event, level, enabled) VALUES (oa, NULL, 'follow_up', 'day_before_reminder', 'Day before reminder', 'day_before', 1, true) RETURNING id INTO pb1;
  INSERT INTO playbooks (org_id, branch_id, agent, key, name, event, level, enabled) VALUES (oa, a2, 'follow_up', 'aftercare_check_in', 'Aftercare check-in', 'visit_completed', 2, true) RETURNING id INTO pb2;
  INSERT INTO playbooks (org_id, branch_id, agent, key, name, event, level, enabled) VALUES (oa, NULL, 'follow_up', 'booking_confirmation', 'Booking confirmation', 'booking_created', 1, false) RETURNING id INTO pb_off;
  INSERT INTO playbooks (org_id, branch_id, agent, key, name, event, level, enabled) VALUES (ob, NULL, 'follow_up', 'day_before_reminder', 'Day before reminder B', 'day_before', 1, true) RETURNING id INTO pbb;

  -- ═══ 0. structure ═══
  PERFORM pg_temp.g_chk('no API role can write the five agent tables directly',
    NOT EXISTS (SELECT 1 FROM unnest(ARRAY['agent_settings', 'playbooks', 'agent_work_items', 'ai_spend', 'ai_budgets']) t, unnest(ARRAY['anon', 'authenticated', 'service_role']) ro, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) pr
                WHERE has_table_privilege(ro, 'public.' || t, pr)), 'grants');
  PERFORM pg_temp.g_chk('private.approval_grants: no API role has any privilege',
    NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) ro WHERE has_schema_privilege(ro, 'private', 'USAGE') OR has_table_privilege(ro, 'private.approval_grants', 'SELECT')), 'grants');
  PERFORM pg_temp.g_chk('helper functions are not callable by API roles',
    NOT EXISTS (SELECT 1 FROM unnest(ARRAY['_agent_snap(text,jsonb)', '_agent_apply(text,jsonb,jsonb)', '_ai_block_reason(uuid,uuid,text)', '_work_keys(text,boolean)']) f, unnest(ARRAY['anon', 'authenticated', 'service_role']) ro
                WHERE has_function_privilege(ro, 'public.' || f, 'EXECUTE')), 'helpers closed');
  PERFORM pg_temp.g_chk('service functions are service_role only (not authenticated, not anon)',
    has_function_privilege('service_role', 'public.ai_record_spend(uuid,uuid,text,text,text,text,jsonb,numeric,uuid,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.ai_record_spend(uuid,uuid,text,text,text,text,jsonb,numeric,uuid,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.ai_budget_status(uuid)', 'EXECUTE') AND NOT has_function_privilege('authenticated', 'public.ai_may_run(uuid,uuid,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.agent_expire_work_items()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.act_work_propose(text,text,uuid,text,text,text,jsonb,uuid,jsonb,uuid,uuid,uuid,boolean,timestamptz,jsonb,boolean)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.act_work_approve(uuid,jsonb,jsonb)', 'EXECUTE'), 'grants');
  -- A seeded row nobody has changed since: every app write sets updated_by and updated_at = now() (an undo restores both exactly), local setup scripts
  -- bump updated_at, and the seed wrote neither; all seed rows share the 016 transaction's now(), the earliest updated_at of any clinic-wide row.
  e_seed := (SELECT min(s0.updated_at) FROM agent_settings s0 WHERE s0.branch_id IS NULL AND s0.org_id NOT IN (SELECT org FROM t_seed));
  PERFORM pg_temp.g_chk('seed (decision f): every organization that existed before the test has a scribe and a follow_up clinic-wide row; every row still as seeded (updated_by NULL, updated_at = the seed time) has the scribe ENABLED (CMD-109: the AI switch alone gates it, as with no row) and follow_up DISABLED, ceiling 1; at least one such row exists',
    NOT EXISTS (SELECT 1 FROM organizations o WHERE o.id NOT IN (SELECT org FROM t_seed)
                AND (NOT EXISTS (SELECT 1 FROM agent_settings s WHERE s.org_id = o.id AND s.branch_id IS NULL AND s.agent = 'scribe')
                  OR NOT EXISTS (SELECT 1 FROM agent_settings s WHERE s.org_id = o.id AND s.branch_id IS NULL AND s.agent = 'follow_up')))
    AND NOT EXISTS (SELECT 1 FROM agent_settings s WHERE s.branch_id IS NULL AND s.org_id NOT IN (SELECT org FROM t_seed) AND s.updated_by IS NULL AND s.updated_at = e_seed
                      AND ((s.agent = 'scribe' AND (NOT s.enabled OR s.max_level IS DISTINCT FROM 1)) OR (s.agent = 'follow_up' AND (s.enabled OR s.max_level IS DISTINCT FROM 1))))
    AND EXISTS (SELECT 1 FROM agent_settings s WHERE s.branch_id IS NULL AND s.agent = 'follow_up' AND s.org_id NOT IN (SELECT org FROM t_seed) AND s.updated_by IS NULL AND s.updated_at = e_seed)
    AND EXISTS (SELECT 1 FROM agent_settings s WHERE s.branch_id IS NULL AND s.agent = 'scribe' AND s.org_id NOT IN (SELECT org FROM t_seed) AND s.updated_by IS NULL AND s.updated_at = e_seed),
    'seed rows');
  -- CMD-109, end to end on a row 016 really seeded: a clinic whose AI is off switches it on, and its Scribe may run (no AGENT_OFF from the seeded row).
  -- Picks an organization whose scribe row is still as seeded (a disabled one first); AI is turned off for it inside this rolled-back transaction.
  SELECT s.org_id INTO e_org FROM agent_settings s WHERE s.branch_id IS NULL AND s.agent = 'scribe' AND s.org_id NOT IN (SELECT org FROM t_seed) AND s.updated_by IS NULL AND s.updated_at = e_seed
   ORDER BY s.enabled, s.org_id LIMIT 1;
  IF e_org IS NULL THEN
    PERFORM pg_temp.g_chk('CMD-109: a clinic switching AI on can run the Scribe (seeded row)', false, 'no organization with a scribe row still as seeded');
  ELSE
    SELECT b.id INTO e_br FROM branches b WHERE b.org_id = e_org ORDER BY b.id LIMIT 1;
    IF e_br IS NULL THEN INSERT INTO branches (name, org_id) VALUES ('CMD-109 test', e_org) RETURNING id INTO e_br; END IF;
    UPDATE organizations SET ai_consultation_enabled = false WHERE id = e_org;   -- as owner; rolled back with the test
    INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      VALUES (e_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-cmd109-' || e_sfx || '@test.invalid', now(), now());
    INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active) VALUES (e_uid, 'rls-cmd109-' || e_sfx || '@test.invalid', 'RLS admin CMD-109', 'admin', e_br, e_org, true);
    INSERT INTO t_actor VALUES ('cmd109_admin', e_uid, e_org, 'authenticated');
    PERFORM pg_temp.g_chk('CMD-109: with the AI switch off, the Scribe is blocked by the switch (AI_OFF)', public._ai_block_reason(e_org, e_br, 'scribe') = 'AI_OFF',
      coalesce(public._ai_block_reason(e_org, e_br, 'scribe'), 'null'));
    r := pg_temp.act_run('cmd109_admin', 'SELECT public.act_ai_budget_set(1000)');
    r := pg_temp.act_run('cmd109_admin', 'SELECT public.act_ai_set_enabled(true)');
    PERFORM pg_temp.g_chk('CMD-109: after the owner sets a budget and switches AI on, the Scribe may run: the scribe row 016 seeded does not keep it off (no AGENT_OFF)',
      pg_temp.act_code(r) = 'ok' AND public._ai_block_reason(e_org, e_br, 'scribe') IS NULL AND public.ai_may_run(e_org, e_br, 'scribe'),
      pg_temp.act_code(r) || ' / block reason ' || coalesce(public._ai_block_reason(e_org, e_br, 'scribe'), 'null') || ' / org ' || e_org);
  END IF;
  PERFORM pg_temp.g_chk('seed: a Scribe with no row follows the AI switch (on), follow_up with no row is off',
    public._agent_org_enabled(oa, 'scribe') AND NOT public._agent_org_enabled(oa, 'follow_up') AND public._agent_ceiling(oa, 'follow_up') = 1, 'defaults');

  -- ═══ 1. who may do what: ceiling, levels, enable ═══
  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_playbook_set_level(%L, 2)', pb1));
  PERFORM pg_temp.g_chk('ceiling default 1: manager asks for level 2 -> LEVEL_ABOVE_CEILING, level unchanged', pg_temp.act_code(r) = 'LEVEL_ABOVE_CEILING' AND (SELECT level FROM playbooks WHERE id = pb1) = 1, pg_temp.act_code(r));
  FOR x IN SELECT unnest(ARRAY['manager_2_branches', 'staff', 'admin_viewer', 'g_pr1']) LOOP
    r := pg_temp.act_run(x, format('SELECT public.act_agent_set_ceiling(%L, 3)', 'follow_up'));
    PERFORM pg_temp.g_chk('set_ceiling: ' || x || ' refused', pg_temp.act_code(r) = 'FORBIDDEN' AND NOT EXISTS (SELECT 1 FROM agent_settings WHERE org_id = oa AND agent = 'follow_up' AND max_level = 3), pg_temp.act_code(r));
  END LOOP;
  r := pg_temp.act_run('service', format('SELECT public.act_agent_set_ceiling(%L, 3, %L::jsonb)', 'follow_up', ctx_fu));
  PERFORM pg_temp.g_chk('set_ceiling: an agent (service role) is refused', pg_temp.act_code(r) = 'FORBIDDEN', pg_temp.act_code(r));
  r := pg_temp.act_run('admin', format('SELECT public.act_agent_set_ceiling(%L, 3)', 'follow_up'));
  PERFORM pg_temp.g_chk('set_ceiling: the owner (admin) sets 3; a new row keeps the agent off', pg_temp.act_code(r) = 'ok'
    AND (SELECT max_level FROM agent_settings WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up') = 3
    AND NOT (SELECT enabled FROM agent_settings WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up'), coalesce(r::text, 'null'));
  r := pg_temp.act_run('admin', format('SELECT public.act_agent_set_ceiling(%L, 4)', 'follow_up'));
  PERFORM pg_temp.g_chk('set_ceiling: level 4 -> INVALID_INPUT', pg_temp.act_code(r) = 'INVALID_INPUT', pg_temp.act_code(r));
  r := pg_temp.act_run('admin', format('SELECT public.act_agent_set_ceiling(%L, 2)', 'scribe'));
  PERFORM pg_temp.g_chk('set_ceiling on the scribe keeps it ON (a new row takes the effective default)', pg_temp.act_code(r) = 'ok' AND public._agent_org_enabled(oa, 'scribe'), 'scribe still on');

  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_playbook_set_level(%L, 2)', pb1));
  PERFORM pg_temp.g_chk('set_level: the manager sets a CLINIC-WIDE playbook to 2 within the ceiling (logged with branch NULL)', pg_temp.act_code(r) = 'ok' AND (SELECT level FROM playbooks WHERE id = pb1) = 2
    AND (SELECT branch_id FROM action_log WHERE id = (r ->> 'action_id')::uuid) IS NULL, coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.g_chk('undo: the manager undoes their own clinic-wide level change; level back to 1', pg_temp.act_code(r2) = 'ok' AND (SELECT level FROM playbooks WHERE id = pb1) = 1, coalesce(r2::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.g_chk('undo: a second undo -> UNDO_ALREADY', pg_temp.act_code(r2) = 'UNDO_ALREADY', pg_temp.act_code(r2));
  FOR x IN SELECT unnest(ARRAY['staff', 'admin_viewer', 'g_pr1']) LOOP
    r := pg_temp.act_run(x, format('SELECT public.act_playbook_set_level(%L, 1)', pb1));
    PERFORM pg_temp.g_chk('set_level: ' || x || ' refused', pg_temp.act_code(r) = 'FORBIDDEN', pg_temp.act_code(r));
    r := pg_temp.act_run(x, format('SELECT public.act_playbook_set_enabled(%L, false)', pb1));
    PERFORM pg_temp.g_chk('set_enabled (playbook): ' || x || ' refused', pg_temp.act_code(r) = 'FORBIDDEN' AND (SELECT enabled FROM playbooks WHERE id = pb1), pg_temp.act_code(r));
  END LOOP;
  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_playbook_set_level(%L, 2)', pbb));
  PERFORM pg_temp.g_chk('set_level: another organization''s playbook -> PLAYBOOK_NOT_FOUND', pg_temp.act_code(r) = 'PLAYBOOK_NOT_FOUND' AND (SELECT level FROM playbooks WHERE id = pbb) = 1, pg_temp.act_code(r));
  r := pg_temp.act_run('admin_of_OTHER_org', format('SELECT public.act_playbook_set_enabled(%L, false)', pb1));
  PERFORM pg_temp.g_chk('set_enabled (playbook): another organization''s admin -> PLAYBOOK_NOT_FOUND', pg_temp.act_code(r) = 'PLAYBOOK_NOT_FOUND' AND (SELECT enabled FROM playbooks WHERE id = pb1), pg_temp.act_code(r));
  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_playbook_set_level(%L, 4)', pb1));
  PERFORM pg_temp.g_chk('set_level: level 4 -> INVALID_INPUT', pg_temp.act_code(r) = 'INVALID_INPUT', pg_temp.act_code(r));
  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_playbook_set_enabled(%L, false)', pb1));
  PERFORM pg_temp.g_chk('set_enabled (playbook): the manager switches it off', pg_temp.act_code(r) = 'ok' AND NOT (SELECT enabled FROM playbooks WHERE id = pb1), pg_temp.act_code(r));
  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_playbook_set_enabled(%L, true)', pb1));
  PERFORM pg_temp.g_chk('set_enabled (playbook): and on again', pg_temp.act_code(r) = 'ok' AND (SELECT enabled FROM playbooks WHERE id = pb1), pg_temp.act_code(r));

  -- ceiling lowering lowers playbooks; undo restores them; undo is the owner's; a later change makes it stale
  PERFORM pg_temp.act_run('admin', format('SELECT public.act_playbook_set_level(%L, 3)', pb1));
  r := pg_temp.act_run('admin', format('SELECT public.act_agent_set_ceiling(%L, 1)', 'follow_up'), 1);
  PERFORM pg_temp.g_chk('set_ceiling 1: every follow_up playbook above it is lowered in the same action (2 here), others untouched',
    pg_temp.act_code(r) = 'ok' AND (r #>> '{data,playbooks_lowered}')::int = 2 AND (SELECT level FROM playbooks WHERE id = pb1) = 1 AND (SELECT level FROM playbooks WHERE id = pb2) = 1
    AND (SELECT level FROM playbooks WHERE id = pbb) = 1, coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.g_chk('undo of a ceiling change: the manager is refused', pg_temp.act_code(r2) = 'FORBIDDEN' AND (SELECT max_level FROM agent_settings WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up') = 1, pg_temp.act_code(r2));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.g_chk('undo of a ceiling change: staff are refused (it is outside their branch scope)', pg_temp.act_code(r2) IN ('FORBIDDEN', 'ACTION_NOT_FOUND') AND (SELECT max_level FROM agent_settings WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up') = 1, pg_temp.act_code(r2));
  r2 := pg_temp.act_run('admin', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.g_chk('undo of a ceiling change: the owner restores the ceiling AND the lowered levels (3 and 2)', pg_temp.act_code(r2) = 'ok'
    AND (SELECT max_level FROM agent_settings WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up') = 3 AND (SELECT level FROM playbooks WHERE id = pb1) = 3 AND (SELECT level FROM playbooks WHERE id = pb2) = 2, coalesce(r2::text, 'null'));
  r := pg_temp.act_run('admin', format('SELECT public.act_agent_set_ceiling(%L, 2)', 'follow_up'));
  PERFORM pg_temp.act_run('manager_2_branches', format('SELECT public.act_playbook_set_level(%L, 1)', pb1));
  r2 := pg_temp.act_run('admin', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.g_chk('undo is refused as stale when a lowered playbook changed again', pg_temp.act_code(r2) = 'UNDO_STALE'
    AND (SELECT max_level FROM agent_settings WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up') = 2, pg_temp.act_code(r2));
  PERFORM pg_temp.act_run('admin', format('SELECT public.act_agent_set_ceiling(%L, 3)', 'follow_up'));
  PERFORM pg_temp.act_run('admin', format('SELECT public.act_playbook_set_level(%L, 1)', pb1));

  -- agent on / off
  FOR x IN SELECT unnest(ARRAY['staff', 'admin_viewer', 'g_pr1']) LOOP
    r := pg_temp.act_run(x, format('SELECT public.act_agent_set_enabled(%L, NULL, true)', 'follow_up'));
    PERFORM pg_temp.g_chk('agent set_enabled: ' || x || ' refused', pg_temp.act_code(r) = 'FORBIDDEN', pg_temp.act_code(r));
  END LOOP;
  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_agent_set_enabled(%L, NULL, true)', 'follow_up'));
  PERFORM pg_temp.g_chk('agent set_enabled: a manager cannot switch the whole clinic', pg_temp.act_code(r) = 'FORBIDDEN', pg_temp.act_code(r));
  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_agent_set_enabled(%L, %L, true)', 'follow_up', a3));
  PERFORM pg_temp.g_chk('agent set_enabled: a manager cannot act in a branch that is not theirs', pg_temp.act_code(r) = 'FORBIDDEN', pg_temp.act_code(r));
  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_agent_set_enabled(%L, %L, true)', 'follow_up', b1));
  PERFORM pg_temp.g_chk('agent set_enabled: another organization''s branch -> BRANCH_NOT_FOUND', pg_temp.act_code(r) = 'BRANCH_NOT_FOUND', pg_temp.act_code(r));
  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_agent_set_enabled(%L, %L, true)', 'follow_up', a1));
  PERFORM pg_temp.g_chk('agent set_enabled: a branch cannot switch on what the owner left off -> CLINIC_AGENT_OFF', pg_temp.act_code(r) = 'CLINIC_AGENT_OFF', pg_temp.act_code(r));
  r := pg_temp.act_run('admin', format('SELECT public.act_agent_set_enabled(%L, NULL, true)', 'follow_up'));
  PERFORM pg_temp.g_chk('agent set_enabled: the owner switches follow_up on for the clinic', pg_temp.act_code(r) = 'ok' AND public._agent_enabled(oa, a1, 'follow_up') AND public._agent_enabled(oa, a2, 'follow_up'), coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.g_chk('agent set_enabled: undo of a clinic-wide switch is the owner''s (manager refused)', pg_temp.act_code(r2) = 'FORBIDDEN' AND public._agent_org_enabled(oa, 'follow_up'), pg_temp.act_code(r2));
  r := pg_temp.act_run('manager_2_branches', format('SELECT public.act_agent_set_enabled(%L, %L, false)', 'follow_up', a1));
  PERFORM pg_temp.g_chk('agent set_enabled: the manager switches follow_up off in THEIR branch only', pg_temp.act_code(r) = 'ok' AND NOT public._agent_enabled(oa, a1, 'follow_up') AND public._agent_enabled(oa, a2, 'follow_up'), coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.g_chk('agent set_enabled: staff cannot undo it', pg_temp.act_code(r2) = 'FORBIDDEN' AND NOT public._agent_enabled(oa, a1, 'follow_up'), pg_temp.act_code(r2));
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.g_chk('agent set_enabled: the manager undoes it (the branch row is removed)', pg_temp.act_code(r2) = 'ok' AND public._agent_enabled(oa, a1, 'follow_up')
    AND NOT EXISTS (SELECT 1 FROM agent_settings WHERE org_id = oa AND branch_id = a1 AND agent = 'follow_up'), coalesce(r2::text, 'null'));
  INSERT INTO agent_settings (org_id, branch_id, agent, enabled) VALUES (oa, a2, 'follow_up', true);
  UPDATE agent_settings SET enabled = false WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up';
  PERFORM pg_temp.g_chk('a branch can only NARROW: org row off + branch row on = off', NOT public._agent_enabled(oa, a2, 'follow_up'), 'narrow only');
  UPDATE agent_settings SET enabled = true WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up';
  DELETE FROM agent_settings WHERE org_id = oa AND branch_id = a2 AND agent = 'follow_up';

  -- ═══ 2. AI switch and budget ═══
  s := public.ai_budget_status(oa);
  PERFORM pg_temp.g_chk('budget status with no budget at all is none', s ->> 'state' = 'none' AND s -> 'amount' = 'null'::jsonb, s::text);
  UPDATE organizations SET ai_consultation_enabled = true WHERE id = oa;   -- already ON when the budget is missing (decision g)
  PERFORM pg_temp.g_chk('(g) none: the Scribe still runs and the switch stays on; follow_up is blocked',
    public.ai_may_run(oa, a1, 'scribe') AND NOT public.ai_may_run(oa, a1, 'follow_up') AND public._ai_block_reason(oa, a1, 'follow_up') = 'BUDGET_USED_UP'
    AND (SELECT ai_consultation_enabled FROM organizations WHERE id = oa), 'none state');
  UPDATE organizations SET ai_consultation_enabled = false WHERE id = oa;
  r := pg_temp.act_run('admin', 'SELECT public.act_ai_set_enabled(true)');
  PERFORM pg_temp.g_chk('(g) none blocks switching AI ON -> NO_BUDGET', pg_temp.act_code(r) = 'NO_BUDGET' AND NOT (SELECT ai_consultation_enabled FROM organizations WHERE id = oa), pg_temp.act_code(r));
  FOR x IN SELECT unnest(ARRAY['manager_2_branches', 'staff', 'admin_viewer', 'g_pr1']) LOOP
    r := pg_temp.act_run(x, 'SELECT public.act_ai_budget_set(1000)');
    PERFORM pg_temp.g_chk('ai budget_set: ' || x || ' refused', pg_temp.act_code(r) = 'FORBIDDEN' AND NOT EXISTS (SELECT 1 FROM ai_budgets WHERE org_id = oa), pg_temp.act_code(r));
    r := pg_temp.act_run(x, 'SELECT public.act_ai_set_enabled(true)');
    PERFORM pg_temp.g_chk('ai set_enabled: ' || x || ' refused', pg_temp.act_code(r) = 'FORBIDDEN' AND NOT (SELECT ai_consultation_enabled FROM organizations WHERE id = oa), pg_temp.act_code(r));
  END LOOP;
  r := pg_temp.act_run('admin', 'SELECT public.act_ai_budget_set(-5)');
  PERFORM pg_temp.g_chk('ai budget_set: a negative amount -> INVALID_INPUT', pg_temp.act_code(r) = 'INVALID_INPUT', pg_temp.act_code(r));
  r := pg_temp.act_run('admin', 'SELECT public.act_ai_budget_set(1000)');
  s := public.ai_budget_status(oa);
  PERFORM pg_temp.g_chk('ai budget_set: the owner sets 1000; state ok, 0 spent', pg_temp.act_code(r) = 'ok' AND s ->> 'state' = 'ok' AND (s ->> 'amount')::numeric = 1000 AND (s ->> 'spent')::numeric = 0, s::text);
  r2 := pg_temp.act_run('manager_2_branches', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.g_chk('ai budget_set: undo is the owner''s (manager refused)', pg_temp.act_code(r2) = 'FORBIDDEN', pg_temp.act_code(r2));
  r := pg_temp.act_run('admin', 'SELECT public.act_ai_set_enabled(true)');
  PERFORM pg_temp.g_chk('ai set_enabled: the owner switches AI on (010''s switch, through the action)', pg_temp.act_code(r) = 'ok' AND (SELECT ai_consultation_enabled FROM organizations WHERE id = oa), coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('admin', format('SELECT public.act_undo(%L)', r ->> 'action_id'));
  PERFORM pg_temp.g_chk('ai set_enabled: undo puts it back off', pg_temp.act_code(r2) = 'ok' AND NOT (SELECT ai_consultation_enabled FROM organizations WHERE id = oa), coalesce(r2::text, 'null'));
  PERFORM pg_temp.act_run('admin', 'SELECT public.act_ai_set_enabled(true)');
  PERFORM pg_temp.g_chk('010''s rule still holds: an admin''s direct UPDATE of the switch touches 0 rows',
    pg_temp.fn_try('admin', format('UPDATE organizations SET ai_consultation_enabled = false WHERE id = %L RETURNING 1', oa)) IN ('ok:0', 'denied')
    AND (SELECT ai_consultation_enabled FROM organizations WHERE id = oa), 'still on');
  r2 := pg_temp.act_run('manager_2_branches', 'SELECT public.act_ai_set_enabled(false)');
  PERFORM pg_temp.g_chk('ai set_enabled(false): the manager cannot switch it off either', pg_temp.act_code(r2) = 'FORBIDDEN' AND (SELECT ai_consultation_enabled FROM organizations WHERE id = oa), pg_temp.act_code(r2));

  -- budget states: ok below 80%, warn at 80%, used_up at 100%; the ledger is written by the service role only
  PERFORM pg_temp.g_chk('ai_record_spend is refused to signed-in users', pg_temp.fn_try('admin', format('SELECT public.ai_record_spend(%L, NULL, ''follow_up'', ''text'', ''p'', ''m'', ''{}'', 1)', oa)) = 'denied', 'denied');
  PERFORM public.ai_record_spend(oa, a1, 'follow_up', 'text', 'anthropic', 'm', '{"in":10,"out":5}', 799.99);
  s := public.ai_budget_status(oa);
  PERFORM pg_temp.g_chk('budget state: 79.999% is ok', s ->> 'state' = 'ok', s::text);
  PERFORM public.ai_record_spend(oa, a1, 'follow_up', 'text', 'anthropic', 'm', '{}', 0.01);
  s := public.ai_budget_status(oa);
  PERFORM pg_temp.g_chk('budget state: exactly 80% is warn', s ->> 'state' = 'warn' AND (s ->> 'pct')::numeric = 80, s::text);
  PERFORM pg_temp.g_chk('budget warn: agents still run', public.ai_may_run(oa, a1, 'follow_up'), 'warn still runs');
  PERFORM public.ai_record_spend(oa, NULL, 'scribe', 'transcription', 'whisper', 'm', '{"seconds":60}', 199.99);
  s := public.ai_budget_status(oa);
  PERFORM pg_temp.g_chk('budget state: 99.99% is still warn', s ->> 'state' = 'warn', s::text);
  PERFORM public.ai_record_spend(oa, NULL, 'scribe', 'vision', 'p', 'm', '{}', 0.01);
  s := public.ai_budget_status(oa);
  PERFORM pg_temp.g_chk('budget state: 100% is used_up', s ->> 'state' = 'used_up' AND (s ->> 'pct')::numeric = 100, s::text);
  PERFORM pg_temp.g_chk('used up: follow_up is blocked, the Scribe still runs',
    NOT public.ai_may_run(oa, a1, 'follow_up') AND public._ai_block_reason(oa, a1, 'follow_up') = 'BUDGET_USED_UP' AND public.ai_may_run(oa, a1, 'scribe'), 'used up');
  UPDATE organizations SET ai_consultation_enabled = false WHERE id = ob;   -- (the 010 section above left org B on)
  PERFORM pg_temp.g_chk('ai_may_run: false when the clinic''s AI is off, for every agent', NOT public.ai_may_run(ob, b1, 'scribe') AND NOT public.ai_may_run(ob, b1, 'follow_up'), 'org B AI off');
  okx := false;
  BEGIN PERFORM public.ai_record_spend(oa, b1, 'follow_up', 'text', 'p', 'm', '{}', 1); EXCEPTION WHEN OTHERS THEN okx := true; END;
  PERFORM pg_temp.g_chk('ai_record_spend: a branch of another organization is refused', okx, 'cross-org spend');

  -- last month's amount carries over; last month's spending does not count
  INSERT INTO ai_budgets (org_id, month, amount_npr, warn_pct) VALUES (ob, (public._ai_month_start() - interval '1 month')::date, 500, 50);
  INSERT INTO ai_spend (org_id, agent, job, provider, model, cost_npr, created_at) VALUES (ob, 'follow_up', 'text', 'p', 'm', 400, now() - interval '40 days');
  s := public.ai_budget_status(ob);
  PERFORM pg_temp.g_chk('budget carry-over: no row this month uses last month''s amount and warn %; last month''s spend is not counted',
    (s ->> 'amount')::numeric = 500 AND (s ->> 'spent')::numeric = 0 AND s ->> 'state' = 'ok', s::text);
  INSERT INTO ai_spend (org_id, agent, job, provider, model, cost_npr) VALUES (ob, 'follow_up', 'text', 'p', 'm', 250);
  PERFORM pg_temp.g_chk('budget carry-over: the carried warn_pct (50) applies: 250 of 500 is warn', public.ai_budget_status(ob) ->> 'state' = 'warn', public.ai_budget_status(ob)::text);

  -- raise the budget so the queue tests below run in state ok again
  r := pg_temp.act_run('admin', 'SELECT public.act_ai_budget_set(100000)');
  PERFORM pg_temp.g_chk('ai budget_set: raising it brings the state back to ok', pg_temp.act_code(r) = 'ok' AND public.ai_budget_status(oa) ->> 'state' = 'ok', public.ai_budget_status(oa)::text);

  -- ═══ 3. the work queue: propose ═══
  FOR x IN SELECT unnest(ARRAY['staff', 'admin', 'forged', 'forged_nosub', 'anon']) LOOP
    r := pg_temp.act_run(x, format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_message_send'', ''{"template":"%s"}''::jsonb, NULL, NULL, %L, %L)', 'follow_up', a1, t1, pat, bk), 0);
    PERFORM pg_temp.g_chk('propose: ' || x || ' cannot call it (service role only)', pg_temp.act_code(r) LIKE 'raised:%', pg_temp.act_code(r));
  END LOOP;
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Send the day-before reminder'', ''I drafted a reminder for Agent Pat.'', ''act_message_send'', %L::jsonb, %L, NULL, %L, %L, NULL, false, NULL, %L::jsonb)',
                      'follow_up', a1, jsonb_build_object('template', t1, 'purpose', 'service')::text, pb1, pat, bk, ctx_fu));
  it := (r #>> '{data,item_id}')::uuid;
  PERFORM pg_temp.g_chk('propose: the agent puts a draft in the queue (open, 48 h expiry, logged as the agent)', pg_temp.act_code(r) = 'ok'
    AND (SELECT status FROM agent_work_items WHERE id = it) = 'open' AND (SELECT expires_at FROM agent_work_items WHERE id = it) > now() + interval '47 hours'
    AND (SELECT actor_kind || ':' || actor_agent FROM action_log WHERE id = (r ->> 'action_id')::uuid) = 'agent:follow_up', coalesce(r::text, 'null'));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_message_send'', ''{}''::jsonb, NULL, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)', 'scribe', a1, pat, ctx_fu));
  PERFORM pg_temp.g_chk('propose: an agent can propose only as itself', pg_temp.act_code(r) = 'FORBIDDEN', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_booking_reschedule'', ''{}''::jsonb, NULL, NULL, %L, %L, NULL, false, NULL, %L::jsonb)', 'follow_up', a1, pat, bk, ctx_fu));
  PERFORM pg_temp.g_chk('propose: an action outside the allow-list -> ACTION_NOT_ALLOWED', pg_temp.act_code(r) = 'ACTION_NOT_ALLOWED', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_message_send'', %L::jsonb, NULL, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)', 'follow_up', a1, jsonb_build_object('template', t1, 'customer_id', pat_b)::text, pat, ctx_fu));
  PERFORM pg_temp.g_chk('propose: a target id inside the inputs is an unknown key -> INVALID_INPUT', pg_temp.act_code(r) = 'INVALID_INPUT', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_message_send'', %L::jsonb, NULL, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)', 'follow_up', a1, jsonb_build_object('template', t1)::text, pat_b, ctx_fu));
  PERFORM pg_temp.g_chk('propose: another organization''s patient -> TARGET_NOT_FOUND', pg_temp.act_code(r) = 'TARGET_NOT_FOUND', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_message_send'', %L::jsonb, NULL, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)', 'follow_up', b1, jsonb_build_object('template', t1)::text, pat, ctx_fu));
  PERFORM pg_temp.g_chk('propose: another organization''s branch -> BRANCH_NOT_FOUND', pg_temp.act_code(r) = 'BRANCH_NOT_FOUND', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_message_send'', %L::jsonb, %L, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)', 'follow_up', a1, jsonb_build_object('template', t1)::text, pb_off, pat, ctx_fu));
  PERFORM pg_temp.g_chk('propose: a playbook that is switched off -> PLAYBOOK_OFF', pg_temp.act_code(r) = 'PLAYBOOK_OFF', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_message_send'', %L::jsonb, %L, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)', 'follow_up', a1, jsonb_build_object('template', t1)::text, pbb, pat, ctx_fu));
  PERFORM pg_temp.g_chk('propose: another organization''s playbook -> PLAYBOOK_NOT_FOUND', pg_temp.act_code(r) = 'PLAYBOOK_NOT_FOUND', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_message_send'', %L::jsonb, NULL, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)', 'follow_up', a1, jsonb_build_object('template', t1)::text, pat, ctx_b));
  PERFORM pg_temp.g_chk('propose: an agent of organization B cannot propose into organization A''s branch -> BRANCH_NOT_FOUND', pg_temp.act_code(r) = 'BRANCH_NOT_FOUND', pg_temp.act_code(r));
  -- the three refusals
  UPDATE agent_settings SET enabled = false WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up';
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_message_send'', %L::jsonb, NULL, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)', 'follow_up', a1, jsonb_build_object('template', t1)::text, pat, ctx_fu));
  PERFORM pg_temp.g_chk('propose: refused when the agent is off -> AGENT_OFF', pg_temp.act_code(r) = 'AGENT_OFF', pg_temp.act_code(r));
  UPDATE agent_settings SET enabled = true WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up';
  UPDATE organizations SET ai_consultation_enabled = false WHERE id = oa;
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_message_send'', %L::jsonb, NULL, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)', 'follow_up', a1, jsonb_build_object('template', t1)::text, pat, ctx_fu));
  PERFORM pg_temp.g_chk('propose: refused when the clinic''s AI is off -> AI_OFF', pg_temp.act_code(r) = 'AI_OFF', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''exception'', %L, ''Scribe note'', ''s'', NULL, ''{}''::jsonb, NULL, NULL, NULL, NULL, NULL, false, NULL, %L::jsonb)', 'scribe', a1, ctx_sc));
  PERFORM pg_temp.g_chk('propose: the Scribe is refused too when AI is off', pg_temp.act_code(r) = 'AI_OFF', pg_temp.act_code(r));
  UPDATE organizations SET ai_consultation_enabled = true WHERE id = oa;
  PERFORM pg_temp.act_run('admin', 'SELECT public.act_ai_budget_set(10)');   -- 10 NPR: already far past it
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''t'', ''s'', ''act_message_send'', %L::jsonb, NULL, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)', 'follow_up', a1, jsonb_build_object('template', t1)::text, pat, ctx_fu));
  PERFORM pg_temp.g_chk('propose: refused when the budget is used up -> BUDGET_USED_UP', pg_temp.act_code(r) = 'BUDGET_USED_UP', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''exception'', %L, ''Scribe note'', ''I could not read the X-ray.'', NULL, ''{}''::jsonb, NULL, NULL, NULL, NULL, NULL, false, NULL, %L::jsonb)', 'scribe', a1, ctx_sc));
  PERFORM pg_temp.g_chk('propose: the Scribe is still allowed when the budget is used up', pg_temp.act_code(r) = 'ok', pg_temp.act_code(r));
  PERFORM pg_temp.act_run('admin', 'SELECT public.act_ai_budget_set(100000)');

  -- ═══ 4. approve / reject ═══
  r := pg_temp.act_run('admin_viewer', format('SELECT public.act_work_approve(%L)', it));
  PERFORM pg_temp.g_chk('approve: admin_viewer refused', pg_temp.act_code(r) = 'FORBIDDEN' AND (SELECT status FROM agent_work_items WHERE id = it) = 'open', pg_temp.act_code(r));
  r := pg_temp.act_run('g_staff_a2', format('SELECT public.act_work_approve(%L)', it));
  PERFORM pg_temp.g_chk('approve: front desk of another branch -> ITEM_NOT_FOUND', pg_temp.act_code(r) = 'ITEM_NOT_FOUND' AND (SELECT status FROM agent_work_items WHERE id = it) = 'open', pg_temp.act_code(r));
  r := pg_temp.act_run('admin_of_OTHER_org', format('SELECT public.act_work_approve(%L)', it));
  PERFORM pg_temp.g_chk('approve: another organization''s admin -> ITEM_NOT_FOUND', pg_temp.act_code(r) = 'ITEM_NOT_FOUND' AND (SELECT status FROM agent_work_items WHERE id = it) = 'open', pg_temp.act_code(r));
  r := pg_temp.act_run('g_pr2', format('SELECT public.act_work_approve(%L)', it));
  PERFORM pg_temp.g_chk('approve: a practitioner who is not this patient''s dentist -> ITEM_NOT_FOUND', pg_temp.act_code(r) = 'ITEM_NOT_FOUND' AND (SELECT status FROM agent_work_items WHERE id = it) = 'open', pg_temp.act_code(r));
  r := pg_temp.act_run('forged_nosub', format('SELECT public.act_work_approve(%L)', it), 0);
  PERFORM pg_temp.g_chk('approve: a service_role claim without a signed-in person cannot approve', pg_temp.act_code(r) IN ('INVALID_CONTEXT', 'FORBIDDEN') AND (SELECT status FROM agent_work_items WHERE id = it) = 'open', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_approve(%L, NULL, %L::jsonb)', it, ctx_fu), 1);
  PERFORM pg_temp.g_chk('approve: an agent (service role) cannot approve its own draft', pg_temp.act_code(r) = 'FORBIDDEN' AND (SELECT status FROM agent_work_items WHERE id = it) = 'open', pg_temp.act_code(r));

  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L)', it), 2);
  PERFORM pg_temp.g_chk('approve: staff of the branch approves; item approved by them; the action ran', pg_temp.act_code(r) = 'ok' AND (SELECT status FROM agent_work_items WHERE id = it) = 'approved'
    AND (SELECT decided_by FROM agent_work_items WHERE id = it) = u_staff AND (SELECT final_inputs FROM agent_work_items WHERE id = it) IS NULL, coalesce(r::text, 'null'));
  SELECT * INTO l FROM action_log WHERE id = (SELECT result_action_id FROM agent_work_items WHERE id = it);
  PERFORM pg_temp.g_chk('approve: the inner action_log row is the AGENT acting, approved by the person (not the person acting)',
    l.action = 'message.send' AND l.actor_kind = 'agent' AND l.actor_agent = 'follow_up' AND l.approved_by = u_staff AND l.actor_user_id IS NULL AND l.ok, row_to_json(l)::text);
  PERFORM pg_temp.g_chk('approve: the message is queued with the agent as its author', EXISTS (SELECT 1 FROM messages m WHERE m.action_id = l.id AND m.author_kind = 'agent' AND m.author_agent = 'follow_up' AND m.status = 'queued' AND m.direction = 'out'), 'message');
  PERFORM pg_temp.g_chk('approve: the grant is gone after use', NOT EXISTS (SELECT 1 FROM private.approval_grants), 'grants empty');
  PERFORM pg_temp.g_chk('approve: its own work.approve row is logged for the person', EXISTS (SELECT 1 FROM action_log a WHERE a.id = (r ->> 'action_id')::uuid AND a.action = 'work.approve' AND a.actor_kind = 'person' AND a.actor_user_id = u_staff AND a.target_id = it), 'approve row');
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L)', it));
  PERFORM pg_temp.g_chk('approve: a second approval -> ITEM_NOT_OPEN, nothing else queued', pg_temp.act_code(r) = 'ITEM_NOT_OPEN' AND (SELECT count(*) FROM messages m WHERE m.action_id = l.id) = 1, pg_temp.act_code(r));
  r := pg_temp.act_run('staff', format('SELECT public.act_work_reject(%L, ''changed my mind'')', it));
  PERFORM pg_temp.g_chk('reject: an approved item cannot be rejected -> ITEM_NOT_OPEN', pg_temp.act_code(r) = 'ITEM_NOT_OPEN' AND (SELECT status FROM agent_work_items WHERE id = it) = 'approved', pg_temp.act_code(r));

  -- a forged agent p_ctx from a signed-in call with NO grant is ignored: the call is logged as the person
  r := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L, p_ctx => %L::jsonb)', pat, t1, bk,
                                       jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa, 'approved_by', u_staff)::text));
  SELECT * INTO l FROM action_log WHERE id = (r ->> 'action_id')::uuid;
  PERFORM pg_temp.g_chk('forged: an agent p_ctx without a grant is ignored (logged as the person, no approved_by, p_ctx noted as ignored)',
    pg_temp.act_code(r) = 'ok' AND l.actor_kind = 'person' AND l.actor_user_id = u_staff AND l.actor_agent IS NULL AND l.approved_by IS NULL AND (l.inputs ->> 'ctx_ignored')::boolean, row_to_json(l)::text);
  r := pg_temp.act_run('staff', format('SELECT public.act_message_send(p_customer => %L, p_template => %L, p_booking => %L, p_ctx => %L::jsonb)', pat, t1, bk,
                                       jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa, 'approved_by', u_adm)::text));
  SELECT * INTO l FROM action_log WHERE id = (r ->> 'action_id')::uuid;
  PERFORM pg_temp.g_chk('forged: naming someone else as approver changes nothing either', l.actor_kind = 'person' AND l.approved_by IS NULL, row_to_json(l)::text);

  -- edits: content keys only; ids come from the stored item
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Reminder'', ''A reminder.'', ''act_message_send'', %L::jsonb, %L, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)',
                      'follow_up', a1, jsonb_build_object('template', t1)::text, pb1, pat, ctx_fu));
  it_ed := (r #>> '{data,item_id}')::uuid;
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L, %L::jsonb)', it_ed, jsonb_build_object('customer_id', pat_pr)::text));
  PERFORM pg_temp.g_chk('approve: an edit that changes customer_id is refused (EDIT_NOT_ALLOWED), the item stays open', pg_temp.act_code(r) = 'EDIT_NOT_ALLOWED' AND (SELECT status FROM agent_work_items WHERE id = it_ed) = 'open', pg_temp.act_code(r));
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L, %L::jsonb)', it_ed, jsonb_build_object('channel', 'email')::text));
  PERFORM pg_temp.g_chk('approve: an edit of the channel is refused too', pg_temp.act_code(r) = 'EDIT_NOT_ALLOWED' AND (SELECT status FROM agent_work_items WHERE id = it_ed) = 'open', pg_temp.act_code(r));
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L, %L::jsonb)', it_ed, jsonb_build_object('booking_id', bk_pr)::text));
  PERFORM pg_temp.g_chk('approve: an edit that changes booking_id is refused too', pg_temp.act_code(r) = 'EDIT_NOT_ALLOWED', pg_temp.act_code(r));
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L, %L::jsonb)', it_ed, jsonb_build_object('template', t2)::text), 2);
  PERFORM pg_temp.g_chk('approve: an edited approval runs with the edit, status edited, final_inputs stored',
    pg_temp.act_code(r) = 'ok' AND (SELECT status FROM agent_work_items WHERE id = it_ed) = 'edited' AND (SELECT final_inputs ->> 'template' FROM agent_work_items WHERE id = it_ed) = t2::text
    AND (SELECT proposed_inputs ->> 'template' FROM agent_work_items WHERE id = it_ed) = t1::text
    AND EXISTS (SELECT 1 FROM messages m WHERE m.action_id = (SELECT result_action_id FROM agent_work_items WHERE id = it_ed) AND m.template_id = t2), coalesce(r::text, 'null'));

  -- an inner refusal (the patient replied STOP): failed, nothing else changes
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Reminder'', ''A reminder.'', ''act_message_send'', %L::jsonb, NULL, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)',
                      'follow_up', a1, jsonb_build_object('template', t1)::text, pat_stop, ctx_fu));
  it_stop := (r #>> '{data,item_id}')::uuid;
  SELECT count(*) INTO n FROM messages WHERE org_id = oa;
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L)', it_stop), 2);
  PERFORM pg_temp.g_chk('approve: an inner refusal (patient replied STOP) marks the item failed with the code, nothing is queued',
    pg_temp.act_code(r) = 'STOPPED' AND (SELECT status FROM agent_work_items WHERE id = it_stop) = 'failed' AND (SELECT decision_reason FROM agent_work_items WHERE id = it_stop) = 'STOPPED'
    AND (SELECT decided_by FROM agent_work_items WHERE id = it_stop) = u_staff AND (SELECT count(*) FROM messages WHERE org_id = oa) = n AND NOT EXISTS (SELECT 1 FROM private.approval_grants), pg_temp.act_code(r));

  -- an inner action with its own undo: set_status. The queue's approval is undone through act_undo on the inner action.
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Confirm the booking'', ''She replied YES.'', ''act_booking_set_status'', %L::jsonb, NULL, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)',
                      'follow_up', a1, jsonb_build_object('status', 'Confirmed')::text, pat, ctx_fu));
  -- (the booking is a target column of the item: set it directly, as the real agent code will through the same function's p_booking)
  it_st := (r #>> '{data,item_id}')::uuid;
  PERFORM pg_temp.g_chk('propose: a booking action without its booking is refused', pg_temp.act_code(r) = 'INVALID_INPUT', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Confirm the booking'', ''She replied YES.'', ''act_booking_set_status'', %L::jsonb, NULL, NULL, %L, %L, NULL, false, NULL, %L::jsonb)',
                      'follow_up', a1, jsonb_build_object('status', 'Confirmed')::text, pat, bk_pend, ctx_fu));
  it_st := (r #>> '{data,item_id}')::uuid;
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L)', it_st), 2);
  SELECT * INTO l FROM action_log WHERE id = (SELECT result_action_id FROM agent_work_items WHERE id = it_st);
  PERFORM pg_temp.g_chk('approve: set_status runs as the agent, approved by staff; the booking is Confirmed', pg_temp.act_code(r) = 'ok' AND l.action = 'booking.set_status' AND l.actor_kind = 'agent' AND l.approved_by = u_staff
    AND (SELECT status FROM bookings WHERE id = bk_pend) = 'Confirmed', coalesce(r::text, 'null'));
  r2 := pg_temp.act_run('staff', format('SELECT public.act_undo(%L)', l.id));
  PERFORM pg_temp.g_chk('approve: the inner action''s own undo works (booking back to Pending)', pg_temp.act_code(r2) = 'ok' AND (SELECT status FROM bookings WHERE id = bk_pend) = 'Pending', coalesce(r2::text, 'null'));

  -- practitioner: own patient's item yes, not another's; reject needs a reason
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Flag it'', ''Not confirmed.'', ''act_booking_flag_not_confirmed'', ''{}''::jsonb, NULL, NULL, %L, %L, NULL, false, NULL, %L::jsonb)',
                      'follow_up', a1, pat_pr, bk_pr, ctx_fu));
  it_pr := (r #>> '{data,item_id}')::uuid;
  r := pg_temp.act_run('g_pr2', format('SELECT public.act_work_reject(%L, ''no'')', it_pr));
  PERFORM pg_temp.g_chk('reject: a practitioner cannot reject another dentist''s patient''s item', pg_temp.act_code(r) = 'ITEM_NOT_FOUND' AND (SELECT status FROM agent_work_items WHERE id = it_pr) = 'open', pg_temp.act_code(r));
  r := pg_temp.act_run('g_pr1', format('SELECT public.act_work_reject(%L, '' '')', it_pr));
  PERFORM pg_temp.g_chk('reject: a reason is required -> REASON_REQUIRED', pg_temp.act_code(r) = 'REASON_REQUIRED' AND (SELECT status FROM agent_work_items WHERE id = it_pr) = 'open', pg_temp.act_code(r));
  r := pg_temp.act_run('admin_viewer', format('SELECT public.act_work_reject(%L, ''x'')', it_pr));
  PERFORM pg_temp.g_chk('reject: admin_viewer refused', pg_temp.act_code(r) = 'FORBIDDEN', pg_temp.act_code(r));
  r := pg_temp.act_run('g_pr1', format('SELECT public.act_work_approve(%L)', it_pr), 2);
  PERFORM pg_temp.g_chk('approve: a practitioner approves their OWN patient''s item', pg_temp.act_code(r) = 'ok' AND (SELECT status FROM agent_work_items WHERE id = it_pr) = 'approved' AND (SELECT decided_by FROM agent_work_items WHERE id = it_pr) = u_pr1, coalesce(r::text, 'null'));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Reminder'', ''A reminder.'', ''act_message_send'', %L::jsonb, NULL, NULL, %L, NULL, NULL, false, NULL, %L::jsonb)',
                      'follow_up', a1, jsonb_build_object('template', t1)::text, pat, ctx_fu));
  it_rej := (r #>> '{data,item_id}')::uuid;
  r := pg_temp.act_run('staff', format('SELECT public.act_work_reject(%L, ''Patient asked us not to'')', it_rej));
  PERFORM pg_temp.g_chk('reject: staff reject with a reason; status rejected, reason kept, nothing sent', pg_temp.act_code(r) = 'ok' AND (SELECT status FROM agent_work_items WHERE id = it_rej) = 'rejected'
    AND (SELECT decision_reason FROM agent_work_items WHERE id = it_rej) = 'Patient asked us not to' AND (SELECT result_action_id FROM agent_work_items WHERE id = it_rej) IS NULL, coalesce(r::text, 'null'));

  -- expiry
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Old'', ''Too late.'', ''act_message_send'', %L::jsonb, NULL, NULL, %L, NULL, NULL, false, now() - interval ''1 hour'', %L::jsonb)',
                      'follow_up', a1, jsonb_build_object('template', t1)::text, pat, ctx_fu));
  it_exp := (r #>> '{data,item_id}')::uuid;
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L)', it_exp));
  PERFORM pg_temp.g_chk('approve: an expired item -> ITEM_EXPIRED, status expired, nothing sent', pg_temp.act_code(r) = 'ITEM_EXPIRED' AND (SELECT status FROM agent_work_items WHERE id = it_exp) = 'expired', pg_temp.act_code(r));
  INSERT INTO agent_work_items (org_id, branch_id, agent, kind, title, summary, proposed_action, customer_id, expires_at)
    VALUES (oa, a1, 'follow_up', 'approval', 'old', 'old', 'act_message_send', pat, now() - interval '1 minute') RETURNING id INTO it2;
  n := public.agent_expire_work_items();
  PERFORM pg_temp.g_chk('expiry job: agent_expire_work_items expires open items past their time and not callable by signed-in users',
    n >= 1 AND (SELECT status FROM agent_work_items WHERE id = it2) = 'expired' AND pg_temp.fn_try('admin', 'SELECT public.agent_expire_work_items()') = 'denied', 'expired ' || n);

  -- ═══ 5. who reads what ═══
  PERFORM public.ai_record_spend(ob, b1, 'follow_up', 'text', 'p', 'm', '{}', 1);
  INSERT INTO agent_work_items (org_id, branch_id, agent, kind, title, summary, customer_id) VALUES (ob, b1, 'follow_up', 'exception', 'org B item', 's', pat_b);
  INSERT INTO agent_work_items (org_id, branch_id, agent, kind, title, summary, customer_id) VALUES (oa, a2, 'follow_up', 'exception', 'A2 item', 's', NULL);
  INSERT INTO agent_work_items (org_id, branch_id, agent, kind, title, summary, customer_id) VALUES (oa, a1, 'follow_up', 'exception', 'A1 item for practitioner 1', 's', pat_pr) RETURNING id INTO it3;
  INSERT INTO conversations (org_id, branch_id, channel, address, state, needs_person_since, handoff_reason, handoff_summary, customer_id)
    VALUES (oa, a1, 'sms', '+9779802000077', 'needs_person', now(), 'unclear', 'Asked something odd', pat);
  FOR l IN SELECT * FROM (VALUES
    ('admin',               'agent_work_items', 'org_id = ''' || oa || '''', 1),
    ('admin_viewer',        'agent_work_items', 'org_id = ''' || oa || '''', 1),
    ('admin_of_OTHER_org',  'agent_work_items', 'org_id = ''' || oa || '''', 0),
    ('admin_of_OTHER_org',  'playbooks',        'org_id = ''' || oa || '''', 0),
    ('admin_of_OTHER_org',  'agent_settings',   'org_id = ''' || oa || '''', 0),
    ('admin_of_OTHER_org',  'ai_spend',         'org_id = ''' || oa || '''', 0),
    ('admin_of_OTHER_org',  'ai_budgets',       'org_id = ''' || oa || '''', 0),
    ('admin_of_OTHER_org',  'work_queue',       'org_id = ''' || oa || '''', 0),
    ('staff',               'agent_work_items', 'title = ''A2 item''', 0),
    ('staff',               'agent_work_items', 'title = ''A1 item for practitioner 1''', 1),
    ('g_staff_a2',          'agent_work_items', 'title = ''A2 item''', 1),
    ('g_staff_a2',          'agent_work_items', 'title = ''A1 item for practitioner 1''', 0),
    ('manager_2_branches',  'agent_work_items', 'title = ''A2 item''', 1),
    ('g_pr1',               'agent_work_items', 'title = ''A1 item for practitioner 1''', 1),
    ('g_pr2',               'agent_work_items', 'title = ''A1 item for practitioner 1''', 0),
    ('g_pr1',               'agent_work_items', 'title = ''A2 item''', 0),
    ('g_pr1',               'playbooks',        'id = ''' || pb1 || '''', 1),
    ('g_pr1',               'agent_settings',   'org_id = ''' || oa || ''' AND branch_id IS NULL', 1),
    ('staff',               'playbooks',        'id = ''' || pb2 || '''', 0),
    ('g_staff_a2',          'playbooks',        'id = ''' || pb2 || '''', 1),
    ('staff',               'playbooks',        'id = ''' || pb1 || '''', 1),
    ('g_pr1',               'ai_spend',         'org_id = ''' || oa || '''', 0),
    ('g_pr1',               'ai_budgets',       'org_id = ''' || oa || '''', 0),
    ('staff',               'ai_spend',         'org_id = ''' || oa || '''', 1),
    ('manager_2_branches',  'ai_budgets',       'org_id = ''' || oa || '''', 1),
    ('admin_viewer',        'ai_spend',         'org_id = ''' || oa || '''', 1),
    ('g_pr1',               'work_queue',       'title = ''A1 item for practitioner 1''', 1),
    ('g_pr2',               'work_queue',       'title = ''A1 item for practitioner 1''', 0),
    ('staff',               'work_queue',       'source = ''conversation''', 1),
    ('g_staff_a2',          'work_queue',       'source = ''conversation''', 0),
    ('admin',               'work_queue',       'source = ''conversation''', 1),
    ('anon',                'agent_work_items', 'true', -1),
    ('anon',                'ai_spend',         'true', -1)
  ) v(actor, tbl, cond, want) LOOP
    x := pg_temp.fn_try(l.actor, format('SELECT 1 FROM public.%I WHERE %s', l.tbl, l.cond));
    PERFORM pg_temp.g_chk('read: ' || l.actor || ' on ' || l.tbl || ' where ' || l.cond || CASE WHEN l.want = 0 THEN ' sees nothing' WHEN l.want < 0 THEN ' is denied' ELSE ' sees it' END,
      CASE WHEN l.want < 0 THEN x = 'denied' WHEN l.want = 0 THEN x IN ('ok:0', 'denied') ELSE x LIKE 'ok:%' AND x <> 'ok:0' END, 'got ' || x);
  END LOOP;
END $agent$;

-- ───────────────────────────── 3f. FOLLOW-UP AGENT (migration-017, CMD-95) ─────────────────────────────
-- Jobs (enqueue once, only for enabled playbooks and agents, triggers that never fail the source write), the scans, the claim / finish functions,
-- reply rules, the read functions (scorecard, usage), p_uses_ai and ORDER_REQUIRED. Seeds its own rows (rolled back with the test).
-- The two-connection SKIP LOCKED proof is scripts/local-agent-claim-check.sh (it cannot be shown inside one transaction). Skipped if 017 is absent.
CREATE FUNCTION pg_temp.f_chk(p_label text, p_ok boolean, p_detail text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO t_res VALUES ('FOLLOWUP', '-', p_label, CASE WHEN COALESCE(p_ok, false) THEN 'PASS' ELSE 'FAIL' END, p_detail);
  IF NOT COALESCE(p_ok, false) THEN RAISE NOTICE 'FAILED CHECK: % -- %', p_label, left(p_detail, 300); END IF;
END $$;
CREATE FUNCTION pg_temp.f_book(p_branch uuid, p_tr uuid, p_cust uuid, p_start timestamptz, p_status text DEFAULT 'Pending') RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE i uuid := gen_random_uuid();
BEGIN
  INSERT INTO bookings (id, branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, payment_status)
    VALUES (i, p_branch, p_tr, p_cust, 'Followup test', (p_start AT TIME ZONE 'Asia/Kathmandu')::date, (p_start AT TIME ZONE 'Asia/Kathmandu')::time, ((p_start + interval '30 minutes') AT TIME ZONE 'Asia/Kathmandu')::time,
            p_start, p_start + interval '30 minutes', 1000, 1000, p_status::booking_status, 'unpaid');
  RETURN i;
END $$;

DO $follow$
DECLARE
  oa uuid; ob uuid; a1 uuid; a2 uuid; b1 uuid; tr uuid; sfx text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8); x text;
  u_adm uuid; u_staff uuid; u_adminb uuid;
  c1 uuid; c2 uuid; c3 uuid; cb uuid; al uuid; pb_bc uuid; pb_db uuid; pb_nr uuid; pb_vc uuid; pb_pr uuid; pb_off uuid; pb_b uuid;
  bk uuid; bk2 uuid; bk3 uuid; bk4 uuid; bk5 uuid; bk6 uuid; bk7 uuid; bkb uuid; n bigint; n2 bigint; conv uuid; convn uuid; m1 uuid; m2 uuid; m3 uuid;
  j jsonb; r jsonb; r2 jsonb; l record; v text; tname text; tr_name text; tom timestamptz; acc uuid; t1 uuid; it_a uuid; it_b uuid; it_c uuid; it_d uuid; ctx_fu text; jid uuid;
  u_pr uuid; d1 uuid;
BEGIN
  IF to_regclass('public.agent_jobs') IS NULL OR to_regprocedure('public.agent_claim_jobs(integer)') IS NULL THEN
    INSERT INTO t_res VALUES ('FOLLOWUP', '-', 'migration-017 checks', 'INFO', 'skipped: the Follow-up agent (017) is not present');
    RETURN;
  END IF;
  SELECT org, uid INTO oa, u_staff FROM t_actor WHERE name = 'staff'; SELECT uid INTO u_adm FROM t_actor WHERE name = 'admin';
  SELECT org, uid INTO ob, u_adminb FROM t_actor WHERE name = 'admin_of_OTHER_org';
  SELECT s2.pk::uuid INTO a1 FROM t_seed s2 JOIN branches b ON b.id = s2.pk::uuid WHERE s2.tbl = 'branches' AND s2.org = oa AND b.name = 'A1';
  SELECT s2.pk::uuid INTO a2 FROM t_seed s2 JOIN branches b ON b.id = s2.pk::uuid WHERE s2.tbl = 'branches' AND s2.org = oa AND b.name = 'A2';
  SELECT s2.pk::uuid INTO b1 FROM t_seed s2 JOIN branches b ON b.id = s2.pk::uuid WHERE s2.tbl = 'branches' AND s2.org = ob AND b.name = 'B1';
  SELECT s2.pk::uuid INTO tr FROM t_seed s2 WHERE s2.tbl = 'treatments' AND s2.org = oa LIMIT 1;
  SELECT name INTO tr_name FROM treatments WHERE id = tr;
  SELECT uid INTO u_pr FROM t_actor WHERE name = 'g_pr1';
  ctx_fu := jsonb_build_object('actor_kind', 'agent', 'agent', 'follow_up', 'org_id', oa)::text;

  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Followup Pat One', oa, '+9779803000001') RETURNING id INTO c1;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Followup Pat Two', oa, '+9779803000002') RETURNING id INTO c2;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a2, 'Followup Pat Three', oa, '+9779803000003') RETURNING id INTO c3;
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (b1, 'Followup Pat B', ob, '+9779803000009') RETURNING id INTO cb;
  DELETE FROM patient_channels WHERE customer_id IN (c1, c2, c3);
  INSERT INTO patient_channels (org_id, customer_id, channel, address, purpose, status, source, evidence) VALUES
    (oa, c1, 'sms', '+9779803000001', 'service', 'agreed', 'booking', 'test') ON CONFLICT (org_id, channel, address, purpose) DO NOTHING;

  -- start clean: the 016 section above left playbooks and branch settings in these two organizations
  DELETE FROM playbooks WHERE org_id IN (oa, ob);
  DELETE FROM agent_settings WHERE org_id IN (oa, ob) AND branch_id IS NOT NULL;
  INSERT INTO agent_settings (org_id, branch_id, agent, enabled, max_level) VALUES (ob, NULL, 'follow_up', true, 3) ON CONFLICT ON CONSTRAINT agent_settings_key DO UPDATE SET enabled = true;
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (a1, 'Dr Followup', 'Male', oa) RETURNING id INTO d1;
  -- the agent is on for org A; five playbooks (org A) and one (org B)
  INSERT INTO agent_settings (org_id, branch_id, agent, enabled, max_level) VALUES (oa, NULL, 'follow_up', true, 3) ON CONFLICT ON CONSTRAINT agent_settings_key DO UPDATE SET enabled = true, max_level = 3;
  INSERT INTO playbooks (org_id, branch_id, agent, key, name, event, level, enabled, settings) VALUES (oa, NULL, 'follow_up', 'booking_confirmation', 'Booking confirmation', 'booking_created', 2, true, '{}') RETURNING id INTO pb_bc;
  INSERT INTO playbooks (org_id, branch_id, agent, key, name, event, level, enabled, settings) VALUES (oa, NULL, 'follow_up', 'day_before_reminder', 'Day before', 'day_before', 1, true, '{"send_time":"00:00"}') RETURNING id INTO pb_db;
  INSERT INTO playbooks (org_id, branch_id, agent, key, name, event, level, enabled, settings) VALUES (oa, NULL, 'follow_up', 'not_confirmed_by_6pm', 'Not confirmed', 'no_reply', 2, true, '{"send_time":"00:00"}') RETURNING id INTO pb_nr;
  INSERT INTO playbooks (org_id, branch_id, agent, key, name, event, level, enabled, settings) VALUES (oa, NULL, 'follow_up', 'aftercare_check_in', 'Aftercare', 'visit_completed', 1, true, jsonb_build_object('send_time', '09:00', 'treatments', jsonb_build_array(tr_name))) RETURNING id INTO pb_vc;
  INSERT INTO playbooks (org_id, branch_id, agent, key, name, event, level, enabled, settings) VALUES (oa, NULL, 'follow_up', 'reply_to_confirm', 'Reply to confirm', 'patient_reply', 2, true, '{}') RETURNING id INTO pb_pr;
  INSERT INTO playbooks (org_id, branch_id, agent, key, name, event, level, enabled, settings) VALUES (ob, NULL, 'follow_up', 'booking_confirmation', 'B confirmation', 'booking_created', 2, true, '{}') RETURNING id INTO pb_b;
  tom := (((now() AT TIME ZONE 'Asia/Kathmandu')::date + 1) + time '15:00') AT TIME ZONE 'Asia/Kathmandu';

  -- ═══ 0. structure ═══
  PERFORM pg_temp.f_chk('no API role can write agent_jobs or agent_reply_rules directly',
    NOT EXISTS (SELECT 1 FROM unnest(ARRAY['agent_jobs', 'agent_reply_rules']) t, unnest(ARRAY['anon', 'authenticated', 'service_role']) ro, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) pr
                WHERE has_table_privilege(ro, 'public.' || t, pr)), 'grants');
  PERFORM pg_temp.f_chk('runner functions are service_role only; scans, enqueue and trigger functions are nobody''s',
    has_function_privilege('service_role', 'public.agent_claim_jobs(integer)', 'EXECUTE') AND has_function_privilege('service_role', 'public.agent_finish_job(uuid,text,jsonb,text)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.agent_get_reply_rules(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.agent_claim_jobs(integer)', 'EXECUTE') AND NOT has_function_privilege('authenticated', 'public.agent_finish_job(uuid,text,jsonb,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.agent_get_reply_rules(uuid)', 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM unnest(ARRAY['agent_scan_day_before()', 'agent_scan_not_confirmed()', 'agent_kick_runner()', 'trg_agent_booking_created()', 'trg_agent_visit_completed()', 'trg_agent_patient_reply()',
                                               '_agent_enqueue(uuid,uuid,text,uuid,uuid,timestamptz,uuid,uuid,text)']) f, unnest(ARRAY['anon', 'authenticated', 'service_role']) ro
                    WHERE has_function_privilege(ro, 'public.' || f, 'EXECUTE')), 'grants');
  PERFORM pg_temp.f_chk('read functions: authenticated yes, anon no',
    has_function_privilege('authenticated', 'public.agent_scorecard(text,uuid,timestamptz,timestamptz)', 'EXECUTE') AND has_function_privilege('authenticated', 'public.ai_usage_summary(date)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.agent_scorecard(text,uuid,timestamptz,timestamptz)', 'EXECUTE') AND NOT has_function_privilege('anon', 'public.ai_usage_summary(date)', 'EXECUTE'), 'grants');
  -- still as seeded = nobody changed it: the seed writes no created_by / updated_by and created_at = updated_at; every app write sets updated_by and
  -- updated_at = now() (an undo restores both exactly); local-agent-setup.sh bumps updated_at.
  PERFORM pg_temp.f_chk('seed: the five follow_up playbooks exist for every pre-existing organization; every one still as seeded (no created_by / updated_by, updated_at = created_at) is DISABLED, level 1, with no template, and at least one such row exists',
    NOT EXISTS (SELECT 1 FROM organizations o WHERE o.id NOT IN (SELECT org FROM t_seed)
                AND (SELECT count(*) FROM playbooks p WHERE p.org_id = o.id AND p.branch_id IS NULL AND p.agent = 'follow_up' AND p.key IN ('booking_confirmation', 'day_before_reminder', 'reply_to_confirm', 'not_confirmed_by_6pm', 'aftercare_check_in')) < 5)
    AND NOT EXISTS (SELECT 1 FROM playbooks p WHERE p.org_id NOT IN (SELECT org FROM t_seed) AND p.branch_id IS NULL AND p.agent = 'follow_up'
                      AND p.key IN ('booking_confirmation', 'day_before_reminder', 'reply_to_confirm', 'not_confirmed_by_6pm', 'aftercare_check_in')
                      AND p.created_by IS NULL AND p.updated_by IS NULL AND p.updated_at = p.created_at
                      AND (p.enabled OR p.level <> 1 OR p.template_id IS NOT NULL))
    AND EXISTS (SELECT 1 FROM playbooks p WHERE p.org_id NOT IN (SELECT org FROM t_seed) AND p.branch_id IS NULL AND p.agent = 'follow_up'
                  AND p.key IN ('booking_confirmation', 'day_before_reminder', 'reply_to_confirm', 'not_confirmed_by_6pm', 'aftercare_check_in')
                  AND p.created_by IS NULL AND p.updated_by IS NULL AND p.updated_at = p.created_at), 'seeded');
  PERFORM pg_temp.f_chk('built-in reply rules: confirm in English, Nepali and romanised; symptoms in English and Nepali',
    (SELECT count(*) FROM agent_reply_rules WHERE org_id IS NULL AND intent = 'confirm' AND word IN ('yes', 'ho', 'huncha', 'हो', 'ठिक छ')) = 5
    AND (SELECT count(*) FROM agent_reply_rules WHERE org_id IS NULL AND intent IN ('urgent', 'clinical') AND match = 'prefix' AND word IN ('bleed', 'bled', 'blood', 'fever', 'ragat', 'jaro', 'pain', 'swell', 'hurt', 'ache', 'toothache', 'dukh', 'sunni', 'रगत', 'सुन्नि', 'दुख')) = 16, 'rules');

  -- ═══ 1. enqueue: a booking is created ═══
  bk := pg_temp.f_book(a1, tr, c1, tom);
  SELECT count(*) INTO n FROM agent_jobs WHERE booking_id = bk AND event = 'booking_created' AND playbook_id = pb_bc AND status = 'queued';
  PERFORM pg_temp.f_chk('booking insert: one job for the enabled booking_created playbook (queued, due now, customer set)', n = 1 AND (SELECT run_after <= now() FROM agent_jobs WHERE booking_id = bk AND event = 'booking_created'), n::text);
  PERFORM pg_temp.f_chk('booking insert: nothing for the other events', (SELECT count(*) FROM agent_jobs WHERE booking_id = bk) = 1, 'only booking_created');
  n := public._agent_enqueue(oa, a1, 'booking_created', bk, c1, now());
  PERFORM pg_temp.f_chk('idempotent: enqueueing the same (playbook, booking, event) again adds nothing', n = 0 AND (SELECT count(*) FROM agent_jobs WHERE booking_id = bk AND event = 'booking_created') = 1, n::text);
  PERFORM pg_temp.f_chk('idempotent: the unique index itself refuses a duplicate job row', (SELECT count(*) FROM pg_indexes WHERE indexname = 'agent_jobs_once') = 1, 'index');
  UPDATE playbooks SET enabled = false WHERE id = pb_bc;
  bk2 := pg_temp.f_book(a1, tr, c1, tom + interval '1 hour');
  PERFORM pg_temp.f_chk('nothing is enqueued for a disabled playbook', (SELECT count(*) FROM agent_jobs WHERE booking_id = bk2) = 0, 'disabled playbook');
  UPDATE playbooks SET enabled = true WHERE id = pb_bc;
  INSERT INTO agent_settings (org_id, branch_id, agent, enabled) VALUES (oa, a2, 'follow_up', false);
  bk3 := pg_temp.f_book(a2, tr, c3, tom);
  PERFORM pg_temp.f_chk('nothing is enqueued when the agent is off for that branch (a branch only narrows)', (SELECT count(*) FROM agent_jobs WHERE booking_id = bk3) = 0, 'agent off at A2');
  DELETE FROM agent_settings WHERE org_id = oa AND branch_id = a2 AND agent = 'follow_up';
  UPDATE agent_settings SET enabled = false WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up';
  bk4 := pg_temp.f_book(a1, tr, c1, tom + interval '2 hours');
  PERFORM pg_temp.f_chk('nothing is enqueued when the agent is off for the clinic', (SELECT count(*) FROM agent_jobs WHERE booking_id = bk4) = 0, 'agent off');
  UPDATE agent_settings SET enabled = true WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up';
  bk5 := pg_temp.f_book(a1, tr, c1, tom + interval '3 hours', 'Cancelled');
  bk6 := pg_temp.f_book(a1, tr, c1, now() - interval '2 days', 'Pending');
  PERFORM pg_temp.f_chk('nothing is enqueued for a cancelled booking or one in the past', (SELECT count(*) FROM agent_jobs WHERE booking_id IN (bk5, bk6)) = 0, 'cancelled / past');
  bkb := pg_temp.f_book(b1, (SELECT s2.pk::uuid FROM t_seed s2 WHERE s2.tbl = 'treatments' AND s2.org = ob LIMIT 1), cb, tom);
  PERFORM pg_temp.f_chk('org B''s booking enqueues only org B''s playbook', (SELECT count(*) FROM agent_jobs WHERE booking_id = bkb) = 1 AND (SELECT org_id FROM agent_jobs WHERE booking_id = bkb) = ob
    AND (SELECT playbook_id FROM agent_jobs WHERE booking_id = bkb) = pb_b, 'org B');

  -- the trigger never fails the booking: make agent_jobs reject every insert for a moment
  EXECUTE 'CREATE FUNCTION pg_temp.f_boom() RETURNS trigger LANGUAGE plpgsql AS $b$ BEGIN RAISE EXCEPTION ''boom''; END $b$';
  EXECUTE 'CREATE TRIGGER f_boom BEFORE INSERT ON public.agent_jobs FOR EACH ROW EXECUTE FUNCTION pg_temp.f_boom()';
  BEGIN
    bk7 := pg_temp.f_book(a1, tr, c1, tom + interval '4 hours');
    PERFORM pg_temp.f_chk('a failing enqueue never fails the booking insert', EXISTS (SELECT 1 FROM bookings WHERE id = bk7) AND NOT EXISTS (SELECT 1 FROM agent_jobs WHERE booking_id = bk7), 'booking saved');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.f_chk('a failing enqueue never fails the booking insert', false, SQLERRM);
  END;
  EXECUTE 'DROP TRIGGER f_boom ON public.agent_jobs';

  -- ═══ 2. scans ═══
  bk2 := pg_temp.f_book(a1, tr, c2, tom + interval '5 hours', 'Confirmed');   -- tomorrow, Confirmed: a day-before reminder, no 6 pm flag
  DELETE FROM agent_jobs WHERE booking_id = bk2;
  n := public.agent_scan_day_before();
  PERFORM pg_temp.f_chk('day-before scan: tomorrow''s Pending and Confirmed bookings get a day_before job once the send time has passed',
    (SELECT count(*) FROM agent_jobs WHERE booking_id IN (bk, bk2) AND event = 'day_before') = 2, n::text);
  n2 := public.agent_scan_day_before();
  PERFORM pg_temp.f_chk('day-before scan: a second run adds nothing', n2 = 0, n2::text);
  PERFORM pg_temp.f_chk('day-before scan: not for a cancelled booking, one today, or another organization''s playbook', NOT EXISTS (SELECT 1 FROM agent_jobs WHERE booking_id IN (bk5, bk6) AND event = 'day_before')
    AND NOT EXISTS (SELECT 1 FROM agent_jobs WHERE booking_id = bkb AND event = 'day_before'), 'scope');
  UPDATE playbooks SET settings = '{"send_time":"23:59"}' WHERE id = pb_db;
  DELETE FROM agent_jobs WHERE event = 'day_before' AND booking_id IN (bk, bk2);
  IF (now() AT TIME ZONE 'Asia/Kathmandu')::time < time '23:58' THEN
    PERFORM public.agent_scan_day_before();
    PERFORM pg_temp.f_chk('day-before scan: before the playbook''s send time nothing is enqueued', NOT EXISTS (SELECT 1 FROM agent_jobs WHERE booking_id IN (bk, bk2) AND event = 'day_before'), 'send_time 23:59');
  END IF;
  UPDATE playbooks SET settings = '{"send_time":"00:00"}' WHERE id = pb_db;
  n := public.agent_scan_not_confirmed();
  PERFORM pg_temp.f_chk('6 pm scan: a Pending booking tomorrow gets a no_reply job; a Confirmed one does not; a second run adds nothing',
    (SELECT count(*) FROM agent_jobs WHERE booking_id = bk AND event = 'no_reply') = 1 AND (SELECT count(*) FROM agent_jobs WHERE booking_id = bk2 AND event = 'no_reply') = 0 AND public.agent_scan_not_confirmed() = 0, n::text);

  -- ═══ 3. visit completed ═══
  bk3 := pg_temp.f_book(a1, tr, c2, now() + interval '30 days', 'Confirmed');
  UPDATE bookings SET dentist_id = d1 WHERE id = bk3; UPDATE bookings SET status = 'In-Progress' WHERE id = bk3; UPDATE bookings SET status = 'Completed' WHERE id = bk3;
  SELECT * INTO l FROM agent_jobs WHERE booking_id = bk3 AND event = 'visit_completed';
  PERFORM pg_temp.f_chk('completed visit of a listed treatment: one visit_completed job, due the NEXT day at 09:00 clinic time',
    l.id IS NOT NULL AND l.run_after = (((now() AT TIME ZONE 'Asia/Kathmandu')::date + 1) + time '09:00') AT TIME ZONE 'Asia/Kathmandu', coalesce(l.run_after::text, 'no job'));
  UPDATE playbooks SET settings = jsonb_build_object('send_time', '09:00', 'treatments', jsonb_build_array('Some other treatment')) WHERE id = pb_vc;
  bk4 := pg_temp.f_book(a1, tr, c2, now() + interval '31 days', 'Confirmed');
  UPDATE bookings SET dentist_id = d1 WHERE id = bk4; UPDATE bookings SET status = 'In-Progress' WHERE id = bk4; UPDATE bookings SET status = 'Completed' WHERE id = bk4;
  PERFORM pg_temp.f_chk('completed visit of a treatment the playbook does not list: no job', NOT EXISTS (SELECT 1 FROM agent_jobs WHERE booking_id = bk4 AND event = 'visit_completed'), 'not listed');
  UPDATE playbooks SET settings = jsonb_build_object('send_time', '09:00', 'treatments', jsonb_build_array(tr_name)) WHERE id = pb_vc;

  -- ═══ 4. a patient replies ═══
  -- A reply is tied to a booking only when the agent sent a confirmation or reminder ABOUT THAT BOOKING in the same conversation in the last 48 hours.
  INSERT INTO conversations (org_id, branch_id, channel, address, state, customer_id, language) VALUES (oa, a1, 'sms', '+9779803000001', 'agent', c1, 'en') RETURNING id INTO conv;
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, status) VALUES (oa, conv, 'in', 'message', 'no', 'patient', 'delivered');
  PERFORM pg_temp.f_chk('a bare "no" with NO recent agent message about the booking: no job, so nothing can be cancelled', NOT EXISTS (SELECT 1 FROM agent_jobs WHERE booking_id = bk AND event = 'patient_reply'), 'no agent message yet');
  INSERT INTO action_log (org_id, branch_id, action, actor_kind, actor_agent, inputs, ok, target_table, target_id, created_at)
    VALUES (oa, a1, 'message.send', 'agent', 'follow_up', jsonb_build_object('booking_id', bk), true, 'conversations', conv, now() - interval '3 days') RETURNING id INTO al;
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, author_agent, status, action_id, created_at)
    VALUES (oa, conv, 'out', 'message', 'old confirmation', 'agent', 'follow_up', 'delivered', al, now() - interval '3 days');
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, status) VALUES (oa, conv, 'in', 'message', 'no', 'patient', 'delivered');
  PERFORM pg_temp.f_chk('the agent''s message about the booking is 3 days old (outside 48 h): still no job', NOT EXISTS (SELECT 1 FROM agent_jobs WHERE booking_id = bk AND event = 'patient_reply'), 'stale');
  INSERT INTO action_log (org_id, branch_id, action, actor_kind, actor_agent, inputs, ok, target_table, target_id) VALUES (oa, a1, 'message.send', 'agent', 'follow_up', jsonb_build_object('booking_id', bk2), true, 'conversations', conv) RETURNING id INTO al;
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, author_agent, status, action_id) VALUES (oa, conv, 'out', 'message', 'about another booking', 'agent', 'follow_up', 'queued', al);
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, status) VALUES (oa, conv, 'in', 'message', 'no', 'patient', 'delivered');
  PERFORM pg_temp.f_chk('a recent agent message about a DIFFERENT booking does not tie the reply to this one', NOT EXISTS (SELECT 1 FROM agent_jobs WHERE booking_id = bk AND event = 'patient_reply'), 'other booking');
  INSERT INTO action_log (org_id, branch_id, action, actor_kind, actor_agent, inputs, ok, target_table, target_id) VALUES (oa, a1, 'message.send', 'agent', 'follow_up', jsonb_build_object('booking_id', bk), true, 'conversations', conv) RETURNING id INTO al;
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, author_agent, status, action_id) VALUES (oa, conv, 'out', 'message', 'confirmation', 'agent', 'follow_up', 'delivered', al);
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, status) VALUES (oa, conv, 'in', 'message', 'yes', 'patient', 'delivered') RETURNING id INTO m1;
  SELECT count(*) INTO n FROM agent_jobs WHERE message_id = m1 AND event = 'patient_reply' AND booking_id = bk AND conversation_id = conv AND playbook_id = pb_pr;
  PERFORM pg_temp.f_chk('inbound reply after the agent''s confirmation of THAT booking (48 h): one patient_reply job for that booking and message', n = 1, n::text);
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, status) VALUES (oa, conv, 'in', 'message', 'actually, can I come at 5?', 'patient', 'delivered') RETURNING id INTO m2;
  PERFORM pg_temp.f_chk('a SECOND reply on the same booking gets its own job (the key includes the message)', (SELECT count(*) FROM agent_jobs WHERE booking_id = bk AND event = 'patient_reply') = 2, 'two replies, two jobs');
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, status) VALUES (oa, conv, 'in', 'message', 'STOP', 'patient', 'delivered') RETURNING id INTO m3;
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, status) VALUES (oa, conv, 'out', 'message', 'hello', 'agent', 'queued');
  INSERT INTO messages (org_id, conversation_id, direction, kind, event_type, body, author_kind, status) VALUES (oa, conv, 'in', 'event', 'took_over', 'x', 'system', 'delivered');
  PERFORM pg_temp.f_chk('a STOP word, an outgoing message and a timeline event enqueue nothing', (SELECT count(*) FROM agent_jobs WHERE booking_id = bk AND event = 'patient_reply') = 2, 'still two');
  INSERT INTO conversations (org_id, branch_id, channel, address, state, customer_id, language) VALUES (oa, a1, 'sms', '+9779803000002', 'agent', c2, 'en') RETURNING id INTO convn;
  UPDATE bookings SET status = 'Confirmed' WHERE id IN (bk2);
  INSERT INTO action_log (org_id, branch_id, action, actor_kind, actor_agent, inputs, ok, target_table, target_id) VALUES (oa, a1, 'message.send', 'agent', 'follow_up', jsonb_build_object('booking_id', bk2), true, 'conversations', convn) RETURNING id INTO al;
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, author_agent, status, action_id) VALUES (oa, convn, 'out', 'message', 'reminder', 'agent', 'follow_up', 'delivered', al);
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, status) VALUES (oa, convn, 'in', 'message', 'yes', 'patient', 'delivered');
  PERFORM pg_temp.f_chk('a reply about a booking that is no longer Pending: no job', NOT EXISTS (SELECT 1 FROM agent_jobs WHERE conversation_id = convn), 'no pending booking');
  INSERT INTO conversations (org_id, branch_id, channel, address, state, customer_id, language) VALUES (oa, a1, 'sms', '+9779803009999', 'agent', NULL, 'en') RETURNING id INTO convn;
  INSERT INTO messages (org_id, conversation_id, direction, kind, body, author_kind, status) VALUES (oa, convn, 'in', 'message', 'yes', 'patient', 'delivered');
  PERFORM pg_temp.f_chk('a reply on a thread with no matched patient: no job', NOT EXISTS (SELECT 1 FROM agent_jobs WHERE conversation_id = convn), 'unmatched');

  -- ═══ 5. claim and finish ═══
  DELETE FROM agent_jobs WHERE org_id = oa AND id NOT IN (SELECT id FROM agent_jobs WHERE booking_id = bk);
  UPDATE agent_jobs SET status = 'done' WHERE booking_id <> bk;   -- jobs a local database already holds (real bookings, the cron scans) must not take part in the claim checks
  SELECT count(*) INTO n FROM agent_jobs WHERE booking_id = bk;
  SELECT count(*) INTO n2 FROM agent_claim_jobs(50);
  PERFORM pg_temp.f_chk('claim: returns every due queued job once and marks them running (attempts 1)', n2 >= n AND NOT EXISTS (SELECT 1 FROM agent_jobs WHERE booking_id = bk AND (status <> 'running' OR attempts <> 1)), n || ' / ' || n2);
  PERFORM pg_temp.f_chk('claim: a second claim returns nothing for them', NOT EXISTS (SELECT 1 FROM agent_claim_jobs(50) q WHERE (q ->> 'booking_id')::uuid = bk), 'already running');
  UPDATE agent_jobs SET status = 'queued', attempts = 0 WHERE booking_id = bk;
  SELECT q INTO j FROM agent_claim_jobs(50) q WHERE (q ->> 'event') = 'patient_reply' AND (q ->> 'message_id')::uuid = m2 LIMIT 1;
  PERFORM pg_temp.f_chk('claim payload: reply text for a patient_reply job, the treatment NAME and the visit DATE, the playbook, conversation state', j IS NOT NULL AND j ->> 'reply_text' = 'actually, can I come at 5?'
    AND j #>> '{booking,treatment}' = tr_name AND j #>> '{booking,date}' ~ '^\d{4}-\d{2}-\d{2}$' AND (j #>> '{playbook,level}')::int = 2 AND j #>> '{conversation,state}' = 'agent' AND (j ->> 'agent_enabled')::boolean, coalesce(j::text, 'null'));
  PERFORM pg_temp.f_chk('claim payload: no patient name, phone or email anywhere in it', j::text NOT LIKE '%Followup Pat%' AND j::text NOT LIKE '%98030%' AND j::text NOT LIKE '%@%', 'privacy');
  SELECT q INTO j FROM agent_claim_jobs(50) q WHERE FALSE;
  UPDATE agent_jobs SET status = 'queued', attempts = 0 WHERE booking_id = bk;
  SELECT q INTO j FROM agent_claim_jobs(50) q WHERE (q ->> 'event') = 'booking_created' LIMIT 1;
  PERFORM pg_temp.f_chk('claim payload: reply_text is NULL for every other event', j IS NOT NULL AND j -> 'reply_text' = 'null'::jsonb, coalesce(j::text, 'null'));
  jid := (j ->> 'job_id')::uuid;
  v := public.agent_finish_job(jid, 'done', '{"path":"sent"}', NULL)::text;
  PERFORM pg_temp.f_chk('finish: done stores the result and the code', v = 'true' AND (SELECT status || result::text FROM agent_jobs WHERE id = jid) = 'done{"path": "sent"}', v);
  v := public.agent_finish_job(jid, 'failed', '{}', 'X')::text;
  PERFORM pg_temp.f_chk('finish: a job that is not running returns false and changes nothing', v = 'false' AND (SELECT status FROM agent_jobs WHERE id = jid) = 'done', v);
  UPDATE agent_jobs SET status = 'running', attempts = 1, claimed_at = now() WHERE id = jid;
  PERFORM public.agent_finish_job(jid, 'retry', '{}', 'RPC_ERROR');
  PERFORM pg_temp.f_chk('finish: retry re-queues for attempts x 5 minutes later', (SELECT status = 'queued' AND run_after > now() + interval '4 minutes' AND run_after < now() + interval '6 minutes' AND last_error = 'RPC_ERROR' FROM agent_jobs WHERE id = jid), 'retry');
  UPDATE agent_jobs SET status = 'running', attempts = 3, claimed_at = now() WHERE id = jid;
  PERFORM public.agent_finish_job(jid, 'retry', '{}', 'RPC_ERROR');
  PERFORM pg_temp.f_chk('finish: the third failed attempt is failed for good', (SELECT status FROM agent_jobs WHERE id = jid) = 'failed', 'exhausted');
  UPDATE agent_jobs SET status = 'running', attempts = 1, claimed_at = now() - interval '11 minutes', run_after = now() - interval '1 day' WHERE id = jid;
  PERFORM count(*) FROM agent_claim_jobs(1);
  PERFORM pg_temp.f_chk('claim: a job stuck running for 10+ minutes is put back in the queue and claimed again', (SELECT attempts FROM agent_jobs WHERE id = jid) = 2, 'reclaimed');
  UPDATE agent_jobs SET status = 'running', attempts = 3, claimed_at = now() - interval '11 minutes' WHERE id = jid;
  PERFORM count(*) FROM agent_claim_jobs(1);
  PERFORM pg_temp.f_chk('claim: a stuck job on its third attempt is failed, not run again', (SELECT status || last_error FROM agent_jobs WHERE id = jid) = 'failedSTALE', 'stale');
  v := 'ok';
  BEGIN PERFORM public.agent_finish_job(jid, 'exploded', '{}', NULL); EXCEPTION WHEN OTHERS THEN v := 'raised'; END;
  PERFORM pg_temp.f_chk('finish: an unknown status is refused', v = 'raised', v);
  FOR x IN SELECT unnest(ARRAY['staff', 'admin', 'anon', 'g_pr1']) LOOP
    PERFORM pg_temp.f_chk('claim / finish / rules are not callable by ' || x, pg_temp.m_val(x, 'SELECT count(*) FROM public.agent_claim_jobs(1)') = 'denied'
      AND pg_temp.m_val(x, format('SELECT public.agent_get_reply_rules(%L)', oa)) = 'denied', pg_temp.m_val(x, 'SELECT count(*) FROM public.agent_claim_jobs(1)'));
  END LOOP;

  -- ═══ 6. reads: jobs and rules ═══
  INSERT INTO agent_jobs (org_id, branch_id, agent, playbook_id, event, booking_id, customer_id) VALUES (oa, a2, 'follow_up', pb_bc, 'booking_created', bk3, c3);
  FOR l IN SELECT * FROM (VALUES
    ('admin', 'org_id = ''' || oa || '''', 1), ('admin_viewer', 'org_id = ''' || oa || '''', 1), ('manager_2_branches', 'branch_id = ''' || a2 || '''', 1),
    ('staff', 'branch_id = ''' || a2 || '''', 0), ('staff', 'branch_id = ''' || a1 || '''', 1), ('g_staff_a2', 'branch_id = ''' || a2 || '''', 1), ('g_staff_a2', 'branch_id = ''' || a1 || '''', 0),
    ('g_pr1', 'org_id = ''' || oa || '''', 0), ('admin_of_OTHER_org', 'org_id = ''' || oa || '''', 0), ('admin_of_OTHER_org', 'org_id = ''' || ob || '''', 1), ('anon', 'true', -1)
  ) v(actor, cond, want) LOOP
    x := pg_temp.fn_try(l.actor, format('SELECT 1 FROM public.agent_jobs WHERE %s', l.cond));
    PERFORM pg_temp.f_chk('jobs read: ' || l.actor || ' where ' || l.cond || CASE WHEN l.want = 0 THEN ' sees nothing' WHEN l.want < 0 THEN ' is denied' ELSE ' sees them' END,
      CASE WHEN l.want < 0 THEN x = 'denied' WHEN l.want = 0 THEN x IN ('ok:0', 'denied') ELSE x LIKE 'ok:%' AND x <> 'ok:0' END, 'got ' || x);
  END LOOP;
  INSERT INTO agent_reply_rules (org_id, language, intent, word, match) VALUES (oa, 'en', 'confirm', 'sure thing', 'exact'), (oa, 'en', 'clinical', 'throbbing', 'contains');
  UPDATE agent_reply_rules SET enabled = false WHERE org_id IS NULL AND word = 'y';
  PERFORM pg_temp.f_chk('rules for org A: built-ins plus its own, disabled ones left out', public.agent_get_reply_rules(oa)::text LIKE '%sure thing%' AND public.agent_get_reply_rules(oa)::text LIKE '%bleed%'
    AND NOT (public.agent_get_reply_rules(oa) @> '[{"word":"y"}]'::jsonb), 'rules for A');
  PERFORM pg_temp.f_chk('rules for org B never include org A''s words', public.agent_get_reply_rules(ob)::text NOT LIKE '%sure thing%' AND public.agent_get_reply_rules(ob)::text LIKE '%bleed%', 'rules for B');
  PERFORM pg_temp.f_chk('rules read: org A staff and practitioner see A''s words and the built-ins; org B''s admin does not see A''s',
    pg_temp.fn_try('staff', 'SELECT 1 FROM public.agent_reply_rules WHERE word = ''sure thing''') = 'ok:1' AND pg_temp.fn_try('g_pr1', 'SELECT 1 FROM public.agent_reply_rules WHERE word = ''bleed''') = 'ok:1'
    AND pg_temp.fn_try('admin_of_OTHER_org', 'SELECT 1 FROM public.agent_reply_rules WHERE word = ''sure thing''') = 'ok:0' AND pg_temp.fn_try('anon', 'SELECT 1 FROM public.agent_reply_rules') = 'denied', 'rules read');

  -- ═══ 7. scorecard and usage ═══
  DELETE FROM agent_jobs WHERE org_id = oa;
  INSERT INTO action_log (org_id, branch_id, action, actor_kind, actor_user_id, inputs, ok, target_table, created_at)
    VALUES (oa, NULL, 'agent.set_enabled', 'person', u_adm, '{"agent":"fu_qa","enabled":true}', true, 'agent_settings', now() - interval '10 days');
  bk := pg_temp.f_book(a1, tr, c1, now() - interval '3 days', 'Completed');       -- confirmed by the agent before the visit
  bk2 := pg_temp.f_book(a1, tr, c1, now() - interval '3 days' + interval '1 hour', 'No Show');
  bk3 := pg_temp.f_book(a1, tr, c1, now() - interval '3 days' + interval '2 hours', 'Cancelled');
  bk4 := pg_temp.f_book(a1, tr, c1, now() - interval '3 days' + interval '3 hours', 'Completed');   -- confirmed by a person
  bk5 := pg_temp.f_book(a2, tr, c3, now() - interval '3 days', 'Completed');      -- other branch
  INSERT INTO action_log (org_id, branch_id, action, actor_kind, actor_agent, approved_by, inputs, ok, target_table, target_id, created_at) VALUES
    (oa, a1, 'booking.set_status', 'agent', 'fu_qa', NULL, '{"status":"Confirmed"}', true, 'bookings', bk, now() - interval '4 days');
  INSERT INTO action_log (org_id, branch_id, action, actor_kind, actor_user_id, inputs, ok, target_table, target_id, created_at) VALUES
    (oa, a1, 'booking.set_status', 'person', u_staff, '{"status":"Confirmed"}', true, 'bookings', bk4, now() - interval '4 days');
  -- baseline window: the 28 days before the agent was switched on (10 days ago): 2 bookings, 1 no-show, 1 completed
  PERFORM pg_temp.f_book(a1, tr, c1, now() - interval '20 days', 'Completed');
  PERFORM pg_temp.f_book(a1, tr, c1, now() - interval '21 days', 'No Show');
  INSERT INTO ai_budgets (org_id, month, amount_npr) VALUES (oa, public._ai_month_start(), 1000) ON CONFLICT (org_id, month) DO UPDATE SET amount_npr = 1000;
  DELETE FROM ai_spend WHERE org_id = oa;
  PERFORM public.ai_record_spend(oa, a1, 'follow_up', 'text', 'openai', 'gpt-4o', '{"in":10,"out":5}', 100);
  PERFORM public.ai_record_spend(oa, a2, 'scribe', 'transcription', 'whisper', 'm', '{}', 50);
  INSERT INTO action_log (org_id, branch_id, action, actor_kind, actor_agent, inputs, ok, target_table, target_id, created_at, undone_by_action)
    VALUES (oa, a1, 'booking.set_status', 'agent', 'fu_qa', '{"status":"Confirmed"}', true, 'bookings', bk2, now() - interval '4 days', NULL);

  v := pg_temp.m_val('admin', format('SELECT public.agent_scorecard(''fu_qa'', %L, now() - interval ''3 days 12 hours'', now() - interval ''2 days 12 hours'')::text', a1));
  j := CASE WHEN v LIKE 'ok:%' THEN substr(v, 4)::jsonb END;
  PERFORM pg_temp.f_chk('scorecard (branch A1, a 1-day window 3 days ago): 4 bookings, 1 cancelled, 3 visits, 1 no-show (33.3%), confirmed before the visit 3 of 3 visits (2 by the agent)',
    j IS NOT NULL AND (j #>> '{current,bookings}')::int = 4 AND (j #>> '{current,cancelled}')::int = 1 AND (j #>> '{current,visits}')::int = 3 AND (j #>> '{current,no_show}')::int = 1
    AND (j #>> '{current,no_show_pct}')::numeric = 33.3 AND (j #>> '{current,confirmed_before_visit}')::int = 3 AND (j #>> '{current,confirmed_by_agent}')::int = 2, left(v, 400));
  PERFORM pg_temp.f_chk('scorecard baseline: the 28 days before it was switched on (2 bookings, 1 no-show = 50%), with the turned-on time and a note',
    j IS NOT NULL AND (j #>> '{baseline,bookings}')::int = 2 AND (j #>> '{baseline,no_show_pct}')::numeric = 50.0 AND j ->> 'turned_on_at' IS NOT NULL AND j ->> 'baseline_note' LIKE 'Baseline%', left(v, 400));
  v := pg_temp.m_val('admin', 'SELECT public.agent_scorecard(''fu_qa'', NULL, now() - interval ''3 days 12 hours'', now() - interval ''2 days 12 hours'')::text');
  PERFORM pg_temp.f_chk('scorecard with no branch counts the whole clinic (one more completed booking at A2)', v LIKE 'ok:%' AND (substr(v, 4)::jsonb #>> '{current,bookings}')::int = 5, left(v, 200));
  v := pg_temp.m_val('staff', 'SELECT public.agent_scorecard(''fu_qa'', NULL, now() - interval ''3 days 12 hours'', now() - interval ''2 days 12 hours'')::text');
  PERFORM pg_temp.f_chk('scorecard for staff of A1 counts only their branch', v LIKE 'ok:%' AND (substr(v, 4)::jsonb #>> '{current,bookings}')::int = 4, left(v, 200));
  PERFORM pg_temp.f_chk('scorecard: staff cannot ask for a branch that is not theirs', pg_temp.m_val('staff', format('SELECT public.agent_scorecard(''fu_qa'', %L, now() - interval ''3 days 12 hours'', now() - interval ''2 days 12 hours'')::text', a2)) = 'denied', 'branch scope');
  PERFORM pg_temp.f_chk('scorecard: a practitioner and anon are refused; admin_viewer and manager are not',
    pg_temp.m_val('g_pr1', 'SELECT public.agent_scorecard(''fu_qa'', NULL, now() - interval ''3 days 12 hours'', now() - interval ''2 days 12 hours'')::text') = 'denied'
    AND pg_temp.m_val('anon', 'SELECT public.agent_scorecard(''fu_qa'', NULL, now() - interval ''3 days 12 hours'', now() - interval ''2 days 12 hours'')::text') = 'denied'
    AND pg_temp.m_val('admin_viewer', 'SELECT public.agent_scorecard(''fu_qa'', NULL, now() - interval ''3 days 12 hours'', now() - interval ''2 days 12 hours'')::text') LIKE 'ok:%'
    AND pg_temp.m_val('manager_2_branches', 'SELECT public.agent_scorecard(''fu_qa'', NULL, now() - interval ''3 days 12 hours'', now() - interval ''2 days 12 hours'')::text') LIKE 'ok:%', 'role matrix');
  v := pg_temp.m_val('admin_of_OTHER_org', 'SELECT public.agent_scorecard(''fu_qa'', NULL, now() - interval ''3 days 12 hours'', now() - interval ''2 days 12 hours'')::text');
  PERFORM pg_temp.f_chk('scorecard: organization B''s admin sees none of organization A''s bookings', v LIKE 'ok:%' AND (substr(v, 4)::jsonb #>> '{current,bookings}')::int = 0, left(v, 200));
  PERFORM pg_temp.f_chk('scorecard: bad arguments are refused', pg_temp.m_val('admin', 'SELECT public.agent_scorecard(''x y'', NULL, now(), now() + interval ''1 day'')::text') LIKE 'raised:%'
    AND pg_temp.m_val('admin', 'SELECT public.agent_scorecard(''fu_qa'', NULL, now(), now() - interval ''1 day'')::text') LIKE 'raised:%', 'args');

  v := pg_temp.m_val('admin', 'SELECT public.ai_usage_summary()::text');
  j := CASE WHEN v LIKE 'ok:%' THEN substr(v, 4)::jsonb END;
  PERFORM pg_temp.f_chk('usage summary: spent 150 of 1000 (15%, ok), by agent and by branch, cost per agent-confirmed visit', j IS NOT NULL AND (j ->> 'spent')::numeric = 150 AND (j ->> 'amount')::numeric = 1000 AND (j ->> 'pct')::numeric = 15
    AND j ->> 'state' = 'ok' AND jsonb_array_length(j -> 'by_agent') = 2 AND jsonb_array_length(j -> 'by_branch') = 2, left(v, 400));
  n := (j ->> 'confirmed_by_agent')::int;
  PERFORM pg_temp.f_chk('usage summary: cost per agent-confirmed visit = spent / confirmed (null when none)', (n = 0 AND j -> 'cost_per_confirmed_visit' = 'null'::jsonb) OR (n > 0 AND (j ->> 'cost_per_confirmed_visit')::numeric = round(150.0 / n, 4)), left(v, 400));
  PERFORM pg_temp.f_chk('usage summary: staff, practitioner and anon are refused (no cost data)', pg_temp.m_val('staff', 'SELECT public.ai_usage_summary()::text') = 'denied'
    AND pg_temp.m_val('g_pr1', 'SELECT public.ai_usage_summary()::text') = 'denied' AND pg_temp.m_val('anon', 'SELECT public.ai_usage_summary()::text') = 'denied' AND pg_temp.m_val('g_staff_a2', 'SELECT public.ai_usage_summary()::text') = 'denied', 'money roles');
  v := pg_temp.m_val('admin_viewer', 'SELECT public.ai_usage_summary()::text');
  PERFORM pg_temp.f_chk('usage summary: the read-only owner sees the clinic (150, scope clinic)', v LIKE 'ok:%' AND (substr(v, 4)::jsonb ->> 'spent')::numeric = 150 AND (substr(v, 4)::jsonb ->> 'scope') = 'clinic', left(v, 300));
  v := pg_temp.m_val('manager_2_branches', 'SELECT public.ai_usage_summary()::text');
  PERFORM pg_temp.f_chk('usage summary: a manager (branches A1 and A2) sees their branches, scope branches, with the clinic''s budget state', v LIKE 'ok:%' AND (substr(v, 4)::jsonb ->> 'scope') = 'branches'
    AND (substr(v, 4)::jsonb ->> 'spent')::numeric = 150 AND jsonb_array_length(substr(v, 4)::jsonb -> 'by_branch') = 2 AND (substr(v, 4)::jsonb ->> 'amount')::numeric = 1000, left(v, 300));
  INSERT INTO t_actor VALUES ('f_mgr_a2', (SELECT uid FROM t_actor WHERE name = 'g_staff_a2'), oa, 'authenticated') ON CONFLICT DO NOTHING;
  UPDATE public.users SET role = 'manager' WHERE id = (SELECT uid FROM t_actor WHERE name = 'g_staff_a2');
  v := pg_temp.m_val('f_mgr_a2', 'SELECT public.ai_usage_summary()::text');
  PERFORM pg_temp.f_chk('usage summary: a manager of ONE branch (A2) sees only that branch''s spend (50), never A1''s 100', v LIKE 'ok:%' AND (substr(v, 4)::jsonb ->> 'spent')::numeric = 50 AND jsonb_array_length(substr(v, 4)::jsonb -> 'by_branch') = 1
    AND (substr(v, 4)::jsonb -> 'by_branch' -> 0 ->> 'name') = 'A2', left(v, 300));
  UPDATE public.users SET role = 'staff' WHERE id = (SELECT uid FROM t_actor WHERE name = 'g_staff_a2');
  v := pg_temp.m_val('admin_of_OTHER_org', 'SELECT public.ai_usage_summary()::text');
  PERFORM pg_temp.f_chk('usage summary: organization B''s admin sees only organization B''s spend (none of A''s 150, none of A''s branches)', v LIKE 'ok:%' AND (substr(v, 4)::jsonb ->> 'spent')::numeric <> 150 AND v NOT LIKE '%"A1"%' AND v NOT LIKE '%"A2"%', left(v, 300));

  -- ═══ 8. act_work_propose: p_uses_ai ═══
  UPDATE organizations SET ai_consultation_enabled = false WHERE id = oa;
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''exception'', %L, ''t'', ''s'', NULL, ''{}''::jsonb, NULL, NULL, NULL, NULL, NULL, false, NULL, %L::jsonb)', 'follow_up', a1, ctx_fu));
  PERFORM pg_temp.f_chk('propose without p_uses_ai still refuses when AI is off (the 016 behaviour is the default)', pg_temp.act_code(r) = 'AI_OFF', pg_temp.act_code(r));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''exception'', %L, ''t'', ''s'', NULL, ''{}''::jsonb, NULL, NULL, NULL, NULL, NULL, false, NULL, %L::jsonb, false)', 'follow_up', a1, ctx_fu));
  PERFORM pg_temp.f_chk('propose with p_uses_ai = false works with AI off (a template draft needs no model)', pg_temp.act_code(r) = 'ok', pg_temp.act_code(r));
  UPDATE agent_settings SET enabled = false WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up';
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''exception'', %L, ''t'', ''s'', NULL, ''{}''::jsonb, NULL, NULL, NULL, NULL, NULL, false, NULL, %L::jsonb, false)', 'follow_up', a1, ctx_fu));
  PERFORM pg_temp.f_chk('propose with p_uses_ai = false is still refused when the agent is off -> AGENT_OFF', pg_temp.act_code(r) = 'AGENT_OFF', pg_temp.act_code(r));
  UPDATE agent_settings SET enabled = true WHERE org_id = oa AND branch_id IS NULL AND agent = 'follow_up';
  -- idempotency keys: an action that carries p_ctx.step_key can be found again, and only if it succeeded
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''exception'', %L, ''t'', ''s'', NULL, ''{}''::jsonb, NULL, NULL, NULL, NULL, NULL, false, NULL, %L::jsonb, false)', 'follow_up', a1,
                       (ctx_fu::jsonb || '{"step_key":"job:11111111-1111-1111-1111-111111111111:draft"}')::text));
  r2 := public.agent_step_result(oa, 'job:11111111-1111-1111-1111-111111111111:draft');
  PERFORM pg_temp.f_chk('agent_step_result returns the successful action''s result (with its action id) for a step key', pg_temp.act_code(r) = 'ok' AND r2 IS NOT NULL AND (r2 ->> 'ok')::boolean AND (r2 ->> 'action_id') = (r ->> 'action_id')
    AND (r2 #>> '{data,item_id}') = (r #>> '{data,item_id}'), coalesce(r2::text, 'null'));
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''exception'', %L, ''t'', ''s'', ''act_nope'', ''{}''::jsonb, NULL, NULL, NULL, NULL, NULL, false, NULL, %L::jsonb, false)', 'follow_up', a1,
                       (ctx_fu::jsonb || '{"step_key":"job:22222222-2222-2222-2222-222222222222:draft"}')::text));
  PERFORM pg_temp.f_chk('agent_step_result: a REFUSED action does not count as done, another organization''s key and a non-job key find nothing',
    pg_temp.act_code(r) <> 'ok' AND public.agent_step_result(oa, 'job:22222222-2222-2222-2222-222222222222:draft') IS NULL
    AND public.agent_step_result(ob, 'job:11111111-1111-1111-1111-111111111111:draft') IS NULL AND public.agent_step_result(oa, 'draft') IS NULL, 'not done');
  PERFORM pg_temp.f_chk('agent_step_result is service_role only', pg_temp.m_val('staff', format('SELECT public.agent_step_result(%L, ''job:x'')::text', oa)) = 'denied' AND pg_temp.m_val('anon', format('SELECT public.agent_step_result(%L, ''job:x'')::text', oa)) = 'denied'
    AND has_function_privilege('service_role', 'public.agent_step_result(uuid,text)', 'EXECUTE'), 'grants');
  PERFORM pg_temp.f_chk('act_work_propose: still service_role only, 16 arguments', NOT has_function_privilege('authenticated', 'public.act_work_propose(text,text,uuid,text,text,text,jsonb,uuid,jsonb,uuid,uuid,uuid,boolean,timestamptz,jsonb,boolean)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.act_work_propose(text,text,uuid,text,text,text,jsonb,uuid,jsonb,uuid,uuid,uuid,boolean,timestamptz,jsonb,boolean)', 'EXECUTE')
    AND (SELECT count(*) FROM pg_proc WHERE proname = 'act_work_propose') = 1, 'one function');

  -- ═══ 9. act_work_approve: ORDER_REQUIRED ═══
  SELECT id INTO acc FROM channel_accounts WHERE org_id = oa AND channel = 'sms' AND provider = 'test' AND status = 'connected' LIMIT 1;
  IF acc IS NULL THEN
    INSERT INTO channel_accounts (org_id, channel, provider, sender, status, priority, credit_cost_npr) VALUES (oa, 'sms', 'test', '+977973' || lpad((random() * 999999)::int::text, 6, '0'), 'connected', 100, 1.5) RETURNING id INTO acc;
  END IF;
  UPDATE channel_accounts SET quiet_start = NULL, quiet_end = NULL WHERE id = acc;
  INSERT INTO message_templates (org_id, name, channel, language, body, purpose, clinical) VALUES (oa, 'follow-thanks-' || sfx, NULL, 'en', 'Thanks {patient_name}, see you at {clinic}.', 'service', false) RETURNING id INTO t1;
  bk := pg_temp.f_book(a1, tr, c1, now() + interval '10 days', 'Pending');
  DELETE FROM agent_jobs WHERE booking_id = bk;
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Confirm the booking'', ''She said yes.'', ''act_booking_set_status'', %L::jsonb, NULL, NULL, %L, %L, NULL, false, NULL, %L::jsonb, false)',
                       'follow_up', a1, '{"status":"Confirmed"}', c1, bk, ctx_fu));
  it_a := (r #>> '{data,item_id}')::uuid;
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Send the confirmation reply'', ''After that I will thank her.'', ''act_message_send'', %L::jsonb, NULL, %L::jsonb, %L, %L, NULL, false, NULL, %L::jsonb, false)',
                       'follow_up', a1, jsonb_build_object('template', t1)::text, jsonb_build_array(jsonb_build_object('kind', 'work_item', 'id', it_a, 'requires', true))::text, c1, bk, ctx_fu));
  it_b := (r #>> '{data,item_id}')::uuid;
  PERFORM pg_temp.f_chk('two linked items were proposed (the second requires the first)', it_a IS NOT NULL AND it_b IS NOT NULL, coalesce(r::text, 'null'));
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L)', it_b));
  PERFORM pg_temp.f_chk('approve the template item BEFORE the status item: ORDER_REQUIRED, nothing sent, the item stays open', pg_temp.act_code(r) = 'ORDER_REQUIRED' AND (SELECT status FROM agent_work_items WHERE id = it_b) = 'open'
    AND NOT EXISTS (SELECT 1 FROM messages WHERE action_id IN (SELECT id FROM action_log WHERE target_id = it_b)), pg_temp.act_code(r));
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L)', it_a), 2);
  PERFORM pg_temp.f_chk('approve the status item first: the booking is Confirmed (as the agent, approved by staff)', pg_temp.act_code(r) = 'ok' AND (SELECT status FROM bookings WHERE id = bk) = 'Confirmed', pg_temp.act_code(r));
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L)', it_b), 2);
  PERFORM pg_temp.f_chk('then the template item goes through', pg_temp.act_code(r) = 'ok' AND (SELECT status FROM agent_work_items WHERE id = it_b) = 'approved'
    AND EXISTS (SELECT 1 FROM messages m WHERE m.action_id = (SELECT result_action_id FROM agent_work_items WHERE id = it_b) AND m.author_kind = 'agent' AND m.status = 'queued'), pg_temp.act_code(r));
  bk := pg_temp.f_book(a1, tr, c1, now() + interval '11 days', 'Pending');
  DELETE FROM agent_jobs WHERE booking_id = bk;
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Confirm the booking'', ''She said yes.'', ''act_booking_set_status'', %L::jsonb, NULL, NULL, %L, %L, NULL, false, NULL, %L::jsonb, false)',
                       'follow_up', a1, '{"status":"Confirmed"}', c1, bk, ctx_fu));
  it_c := (r #>> '{data,item_id}')::uuid;
  r := pg_temp.act_run('service', format('SELECT public.act_work_propose(%L, ''approval'', %L, ''Send the confirmation reply'', ''After that I will thank her.'', ''act_message_send'', %L::jsonb, NULL, %L::jsonb, %L, %L, NULL, false, NULL, %L::jsonb, false)',
                       'follow_up', a1, jsonb_build_object('template', t1)::text, jsonb_build_array(jsonb_build_object('kind', 'work_item', 'id', it_c, 'requires', true))::text, c1, bk, ctx_fu));
  it_d := (r #>> '{data,item_id}')::uuid;
  PERFORM pg_temp.act_run('staff', format('SELECT public.act_work_reject(%L, ''not now'')', it_c));
  r := pg_temp.act_run('staff', format('SELECT public.act_work_approve(%L)', it_d));
  PERFORM pg_temp.f_chk('when the earlier step was rejected, the later one cannot go ahead (ORDER_REQUIRED) and nothing is sent', pg_temp.act_code(r) = 'ORDER_REQUIRED' AND (SELECT status FROM agent_work_items WHERE id = it_d) = 'open', pg_temp.act_code(r));
END $follow$;

-- ───────────────────────────── 3g. AGENT ROWS FOR NEW ORGANIZATIONS (migration-018, CMD-97) ─────────────────────────────
-- A new organization gets the 016 agent_settings rows and the five 017 playbooks from trg_agent_seed_new_org, with the same values as the
-- 016 / 017 seeds; re-running adds nothing; a failing seed never fails the organization insert; another organization never sees the rows.
-- Seeds its own organizations (rolled back with the test). The 018 rollback round trip is run outside this file. Skipped if 018 is absent.
CREATE FUNCTION pg_temp.n_chk(p_label text, p_ok boolean, p_detail text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO t_res VALUES ('NEWORG', '-', p_label, CASE WHEN COALESCE(p_ok, false) THEN 'PASS' ELSE 'FAIL' END, p_detail);
  IF NOT COALESCE(p_ok, false) THEN RAISE NOTICE 'FAILED CHECK: % -- %', p_label, left(p_detail, 300); END IF;
END $$;

DO $neworg$
DECLARE
  n1 uuid := gen_random_uuid(); n2 uuid := gen_random_uuid(); n3 uuid := gen_random_uuid(); ref uuid; r jsonb; k int;
  n4 uuid := gen_random_uuid(); br4 uuid := gen_random_uuid(); u4 uuid := gen_random_uuid(); sfx4 text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  sfx text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  keys text[] := ARRAY['booking_confirmation', 'day_before_reminder', 'reply_to_confirm', 'not_confirmed_by_6pm', 'aftercare_check_in'];
BEGIN
  IF to_regprocedure('public._agent_seed_org(uuid)') IS NULL THEN
    INSERT INTO t_res VALUES ('NEWORG', '-', 'migration-018 checks', 'INFO', 'skipped: the new-organization seed (018) is not present');
    RETURN;
  END IF;

  -- the function and the trigger
  PERFORM pg_temp.n_chk('the seed and trigger functions are SECURITY DEFINER with search_path set, and nobody but the owner may EXECUTE them',
    (SELECT bool_and(p.prosecdef AND p.proconfig::text LIKE '%search_path=public%') FROM pg_proc p WHERE p.oid IN ('public._agent_seed_org(uuid)'::regprocedure, 'public.trg_agent_seed_new_org()'::regprocedure))
    AND NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon', 'authenticated', 'service_role', 'public']) ro, unnest(ARRAY['public._agent_seed_org(uuid)', 'public.trg_agent_seed_new_org()']) f
                    WHERE has_function_privilege(ro, f, 'EXECUTE')), 'grants');
  PERFORM pg_temp.n_chk('trg_agent_seed_new_org is an enabled AFTER INSERT row trigger on organizations',
    EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = 'public.organizations'::regclass AND t.tgname = 'trg_agent_seed_new_org' AND t.tgenabled = 'O'
              AND (t.tgtype & 1) = 1 AND (t.tgtype & 2) = 0 AND (t.tgtype & 4) = 4), 'trigger');

  -- a new organization (AI switch off) and one with the AI switch on
  INSERT INTO organizations (id, name, code, slug) VALUES (n1, 'RLS New 1', 'rlsn1' || sfx, 'rls-n1-' || sfx);
  INSERT INTO organizations (id, name, code, slug, ai_consultation_enabled) VALUES (n2, 'RLS New 2', 'rlsn2' || sfx, 'rls-n2-' || sfx, true);
  PERFORM pg_temp.n_chk('a new organization gets exactly 2 clinic-wide settings rows (scribe ENABLED even with the AI switch off, so only the switch gates it; follow_up DISABLED; ceiling 1) and nothing else',
    (SELECT count(*) FROM agent_settings WHERE org_id = n1) = 2
    AND EXISTS (SELECT 1 FROM agent_settings WHERE org_id = n1 AND branch_id IS NULL AND agent = 'scribe' AND enabled AND max_level = 1 AND updated_by IS NULL)
    AND EXISTS (SELECT 1 FROM agent_settings WHERE org_id = n1 AND branch_id IS NULL AND agent = 'follow_up' AND NOT enabled AND max_level = 1 AND updated_by IS NULL),
    (SELECT coalesce(jsonb_agg(to_jsonb(s)), '[]')::text FROM agent_settings s WHERE org_id = n1));
  PERFORM pg_temp.n_chk('a new organization gets exactly the five follow_up playbooks, clinic-wide, DISABLED, level 1, no template, and no other playbook',
    (SELECT count(*) FROM playbooks WHERE org_id = n1) = 5
    AND (SELECT array_agg(key ORDER BY key) FROM playbooks WHERE org_id = n1) = (SELECT array_agg(x ORDER BY x) FROM unnest(keys) x)
    AND NOT EXISTS (SELECT 1 FROM playbooks WHERE org_id = n1 AND (branch_id IS NOT NULL OR agent <> 'follow_up' OR enabled OR level <> 1 OR template_id IS NOT NULL
                                                                OR created_by IS NOT NULL OR updated_by IS NOT NULL)),
    (SELECT coalesce(jsonb_agg(jsonb_build_object('key', key, 'enabled', enabled, 'level', level, 'template', template_id)), '[]')::text FROM playbooks WHERE org_id = n1));
  PERFORM pg_temp.n_chk('the scribe row is ENABLED whether the AI switch is on or off, as 016 seeds it since CMD-109 (scribe = the switch left the Scribe stuck off after AI was switched on)',
    EXISTS (SELECT 1 FROM agent_settings WHERE org_id = n2 AND branch_id IS NULL AND agent = 'scribe' AND enabled AND max_level = 1)
    AND EXISTS (SELECT 1 FROM agent_settings WHERE org_id = n2 AND branch_id IS NULL AND agent = 'follow_up' AND NOT enabled AND max_level = 1)
    AND (SELECT count(*) FROM playbooks WHERE org_id = n2 AND NOT enabled AND level = 1) = 5, 'scribe');

  -- the same settings as 016's own seed (since CMD-109): compare with a pre-existing organization whose two rows nobody has changed
  SELECT o.id INTO ref FROM organizations o
   WHERE o.id NOT IN (SELECT org FROM t_seed) AND o.id NOT IN (n1, n2)
     AND (SELECT count(*) FROM agent_settings s WHERE s.org_id = o.id AND s.branch_id IS NULL AND s.agent IN ('scribe', 'follow_up') AND s.updated_by IS NULL
            AND s.updated_at = (SELECT min(s0.updated_at) FROM agent_settings s0 WHERE s0.branch_id IS NULL AND s0.org_id NOT IN (SELECT org FROM t_seed))) = 2
   ORDER BY o.id LIMIT 1;
  PERFORM pg_temp.n_chk('the new organization''s settings rows equal 016''s seed value by value (agent, branch, enabled, ceiling), compared with an untouched 016-seeded organization',
    ref IS NOT NULL
    AND NOT EXISTS ((SELECT agent, branch_id, enabled, max_level FROM agent_settings WHERE org_id = n1)
                    EXCEPT (SELECT agent, branch_id, enabled, max_level FROM agent_settings WHERE org_id = ref AND branch_id IS NULL AND agent IN ('scribe', 'follow_up')))
    AND NOT EXISTS ((SELECT agent, branch_id, enabled, max_level FROM agent_settings WHERE org_id = ref AND branch_id IS NULL AND agent IN ('scribe', 'follow_up'))
                    EXCEPT (SELECT agent, branch_id, enabled, max_level FROM agent_settings WHERE org_id = n1)),
    'reference org ' || coalesce(ref::text, 'none (no untouched 016-seeded organization)'));
  -- the same values as 017's own seed: compare with a pre-existing organization whose five playbooks nobody has changed
  SELECT o.id INTO ref FROM organizations o
   WHERE o.id NOT IN (SELECT org FROM t_seed) AND o.id NOT IN (n1, n2)
     AND (SELECT count(*) FROM playbooks p WHERE p.org_id = o.id AND p.branch_id IS NULL AND p.agent = 'follow_up' AND p.key = ANY (keys)
            AND p.created_by IS NULL AND p.updated_by IS NULL AND p.updated_at = p.created_at) = 5
   ORDER BY o.id LIMIT 1;
  PERFORM pg_temp.n_chk('the new organization''s playbooks equal 017''s seed value by value (key, name, event, level, enabled, settings, template, channel), compared with an untouched 017-seeded organization',
    ref IS NOT NULL
    AND NOT EXISTS ((SELECT key, name, event, level, enabled, settings, template_id, channel FROM playbooks WHERE org_id = n1)
                    EXCEPT (SELECT key, name, event, level, enabled, settings, template_id, channel FROM playbooks WHERE org_id = ref AND branch_id IS NULL AND agent = 'follow_up' AND key = ANY (keys)))
    AND NOT EXISTS ((SELECT key, name, event, level, enabled, settings, template_id, channel FROM playbooks WHERE org_id = ref AND branch_id IS NULL AND agent = 'follow_up' AND key = ANY (keys))
                    EXCEPT (SELECT key, name, event, level, enabled, settings, template_id, channel FROM playbooks WHERE org_id = n1)),
    'reference org ' || coalesce(ref::text, 'none (no untouched 017-seeded organization)'));

  -- re-running adds nothing and never overwrites a clinic's choices
  UPDATE playbooks SET enabled = true, level = 2 WHERE org_id = n1 AND key = 'booking_confirmation';
  UPDATE agent_settings SET enabled = true, max_level = 2 WHERE org_id = n1 AND agent = 'follow_up' AND branch_id IS NULL;
  k := public._agent_seed_org(n1);
  PERFORM public._agent_seed_org(o.id) FROM organizations o
   WHERE NOT EXISTS (SELECT 1 FROM playbooks p WHERE p.org_id = o.id AND p.branch_id IS NULL AND p.agent = 'follow_up');   -- the migration's backfill
  PERFORM pg_temp.n_chk('seeding again (and the backfill) adds nothing and does not overwrite what the clinic changed',
    k = 0 AND (SELECT count(*) FROM agent_settings WHERE org_id = n1) = 2 AND (SELECT count(*) FROM playbooks WHERE org_id = n1) = 5
    AND (SELECT count(*) FROM playbooks WHERE org_id = n2) = 5
    AND EXISTS (SELECT 1 FROM playbooks WHERE org_id = n1 AND key = 'booking_confirmation' AND enabled AND level = 2)
    AND EXISTS (SELECT 1 FROM agent_settings WHERE org_id = n1 AND agent = 'follow_up' AND branch_id IS NULL AND enabled AND max_level = 2), 'inserted ' || k);

  -- a failing seed never fails the organization insert, and leaves all seven rows or none
  ALTER TABLE public.playbooks ADD CONSTRAINT zz_seed_test_fail CHECK (key <> 'aftercare_check_in') NOT VALID;
  BEGIN
    INSERT INTO organizations (id, name, code, slug) VALUES (n3, 'RLS New 3', 'rlsn3' || sfx, 'rls-n3-' || sfx);
    r := jsonb_build_object('ok', true);
  EXCEPTION WHEN OTHERS THEN r := jsonb_build_object('raised', SQLSTATE);
  END;
  ALTER TABLE public.playbooks DROP CONSTRAINT zz_seed_test_fail;
  PERFORM pg_temp.n_chk('a seed that fails (forced) still creates the organization, and none of its seven rows are left half-written',
    r ? 'ok' AND EXISTS (SELECT 1 FROM organizations WHERE id = n3)
    AND NOT EXISTS (SELECT 1 FROM agent_settings WHERE org_id = n3) AND NOT EXISTS (SELECT 1 FROM playbooks WHERE org_id = n3), r::text);
  k := public._agent_seed_org(n3);
  PERFORM pg_temp.n_chk('such an organization is fixed by running the seed by hand (7 rows)', k = 7, 'inserted ' || k);

  -- the Scribe of a new clinic (AI off at creation) can run once the owner switches AI on: the seeded scribe row must not keep it off.
  -- (_agent_org_enabled: no row = the Scribe follows the AI switch; _ai_block_reason checks the switch first, AI_OFF, then the agent, AGENT_OFF.)
  INSERT INTO organizations (id, name, code, slug) VALUES (n4, 'RLS New 4', 'rlsn4' || sfx4, 'rls-n4-' || sfx4);
  INSERT INTO branches (id, name, org_id) VALUES (br4, 'N4', n4);
  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    VALUES (u4, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-n4admin-' || sfx4 || '@test.invalid', now(), now());
  INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active) VALUES (u4, 'rls-n4admin-' || sfx4 || '@test.invalid', 'RLS admin N4', 'admin', br4, n4, true);
  INSERT INTO t_actor VALUES ('neworg_admin', u4, n4, 'authenticated');
  PERFORM pg_temp.n_chk('a new clinic created with AI off: the Scribe is blocked by the AI switch (AI_OFF), not by its own row',
    public._ai_block_reason(n4, br4, 'scribe') = 'AI_OFF', coalesce(public._ai_block_reason(n4, br4, 'scribe'), 'null'));
  r := pg_temp.act_run('neworg_admin', 'SELECT public.act_ai_budget_set(1000)');
  r := pg_temp.act_run('neworg_admin', 'SELECT public.act_ai_set_enabled(true)');
  PERFORM pg_temp.n_chk('after its owner sets a budget and switches AI on, the new clinic''s Scribe may run (no AGENT_OFF from the seeded row)',
    pg_temp.act_code(r) = 'ok' AND public._ai_block_reason(n4, br4, 'scribe') IS NULL AND public.ai_may_run(n4, br4, 'scribe'),
    pg_temp.act_code(r) || ' / block reason ' || coalesce(public._ai_block_reason(n4, br4, 'scribe'), 'null'));

  -- the new rows are not visible to another organization
  FOR ref IN SELECT unnest(ARRAY[n1, n2]) LOOP
    FOREACH sfx IN ARRAY ARRAY['admin', 'staff', 'admin_of_OTHER_org', 'anon'] LOOP
      r := pg_temp.act_run(sfx, format('SELECT jsonb_build_object(''pb'', (SELECT count(*) FROM public.playbooks WHERE org_id = %L), ''st'', (SELECT count(*) FROM public.agent_settings WHERE org_id = %L))', ref, ref), 0);
      PERFORM pg_temp.n_chk(sfx || ' (another organization or anon) sees none of a new organization''s playbooks or agent settings (anon: refused outright)',
        r = '{"pb": 0, "st": 0}'::jsonb OR (sfx = 'anon' AND r = '{"raised": "42501"}'::jsonb), r::text);
    END LOOP;
  END LOOP;
END $neworg$;

-- ───────────────────────────── 3d. PRACTITIONER ACCESS LEVEL (migration-011) ─────────────────────────────
-- Actors: 'practitioner' (users.role = practitioner, linked to Dr A1), 'practitioner_no_profile' (role only, no dentist link),
-- 'staff' (control), 'customer_no_staff_row' (a signed-in patient: NO users row, so get_user_role() IS NULL).
-- Seeded: bk_mine_bd (Dr A1 via booking_dentists), bk_mine_col (Dr A1 via bookings.dentist_id only), bk_nobody (branch A1, nobody's).
DO $prac$
DECLARE
  oa uuid; ob uuid; bk_bd uuid; bk_none uuid; bk_col uuid; d1 uuid; d2 uuid; db uuid; c1 uuid; bk_b uuid; u_staff uuid; u_prac uuid; r text; t record;
BEGIN
  IF to_regprocedure('public.get_user_dentist_id()') IS NULL THEN
    INSERT INTO t_res VALUES ('PRACT', '-', 'migration-011 checks', 'INFO', 'skipped: migration-011 not applied');
    RETURN;
  END IF;
  SELECT org INTO oa FROM t_actor WHERE name = 'admin'; SELECT org INTO ob FROM t_actor WHERE name = 'admin_of_OTHER_org';
  SELECT uid INTO u_staff FROM t_actor WHERE name = 'staff'; SELECT uid INTO u_prac FROM t_actor WHERE name = 'practitioner';
  SELECT v INTO bk_bd FROM t_prac WHERE k = 'bk_mine_bd'; SELECT v INTO bk_none FROM t_prac WHERE k = 'bk_nobody'; SELECT v INTO bk_col FROM t_prac WHERE k = 'bk_mine_col';
  SELECT v INTO d1 FROM t_prac WHERE k = 'd_a1'; SELECT v INTO d2 FROM t_prac WHERE k = 'd_a2'; SELECT v INTO db FROM t_prac WHERE k = 'd_b';
  UPDATE public.users SET dentist_id = NULL WHERE dentist_id = d1 AND id <> u_prac;
  UPDATE public.users SET dentist_id = d1 WHERE id = u_prac AND dentist_id IS DISTINCT FROM d1;   -- merge glue: re-link the shared practitioner
  SELECT v INTO c1 FROM t_prac WHERE k = 'c_a1'; SELECT v INTO bk_b FROM t_prac WHERE k = 'bk_b';

  -- (1) money: the practitioner reads NO rows, while staff (control) reads some. Not vacuous: staff must see > 0.
  FOR t IN SELECT unnest(ARRAY['payments', 'payment_refunds', 'payroll_runs', 'payroll_items', 'staff_compensation', 'daily_reports', 'audit_logs']) AS tbl LOOP
    r := pg_temp.fn_try('practitioner', format('SELECT 1 FROM %I', t.tbl));
    INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot read ' || t.tbl, CASE WHEN r = 'ok:0' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  END LOOP;
  FOR t IN SELECT unnest(ARRAY['payments', 'payment_refunds']) AS tbl LOOP
    r := pg_temp.fn_try('staff', format('SELECT 1 FROM %I', t.tbl));
    INSERT INTO t_res VALUES ('PRACT', 'staff', 'control: staff still reads ' || t.tbl, CASE WHEN r LIKE 'ok:%' AND r <> 'ok:0' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  END LOOP;
  r := pg_temp.fn_try('practitioner', format('INSERT INTO payments (booking_id, amount, payment_mode, recorded_by) VALUES (%L, 1, ''Cash'', %L)', bk_bd, u_prac));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot record a payment', CASE WHEN r = 'denied' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('staff', format('INSERT INTO payments (booking_id, amount, payment_mode, recorded_by) VALUES (%L, 1, ''Cash'', %L)', bk_bd, u_staff));
  INSERT INTO t_res VALUES ('PRACT', 'staff', 'control: staff can still record a payment', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);

  -- (2) the restrictive deny exists on every money/marketing table named in the approved table (some are empty in the seed, so check the policy)
  FOR t IN SELECT unnest(ARRAY['payments', 'payment_refunds', 'memberships', 'membership_transactions', 'vouchers', 'voucher_claims', 'voucher_types',
                               'membership_tiers', 'reward_catalog', 'outreach_rules', 'outreach_templates', 'daily_reports', 'customer_referrals',
                               'customer_referral_credits', 'customer_referral_debits']) AS tbl LOOP
    INSERT INTO t_res VALUES ('PRACT', '-', 'restrictive deny exists on ' || t.tbl,
      CASE WHEN EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = t.tbl AND permissive = 'RESTRICTIVE' AND qual ~ 'practitioner') THEN 'PASS' ELSE 'FAIL' END, 'pg_policies');
  END LOOP;

  -- (3) what a practitioner CAN read (same as front desk for their branch)
  FOR t IN SELECT unnest(ARRAY['bookings', 'customers', 'dentists', 'chairs', 'treatments']) AS tbl LOOP
    r := pg_temp.fn_try('practitioner', format('SELECT 1 FROM %I', t.tbl));
    INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'can read ' || t.tbl, CASE WHEN r LIKE 'ok:%' AND r <> 'ok:0' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  END LOOP;
  r := pg_temp.fn_try('practitioner', 'SELECT 1 FROM users');
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'reads only their own users row', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', 'SELECT 1 FROM user_branches');
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot read org branch grants', CASE WHEN r IN ('ok:0', 'denied') THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);

  -- (4) bookings: no INSERT / DELETE; UPDATE only own; cannot hand a booking to someone else
  r := pg_temp.fn_try('practitioner', format('INSERT INTO bookings SELECT * FROM jsonb_populate_record(NULL::bookings, jsonb_set(jsonb_set((SELECT to_jsonb(b) FROM bookings b WHERE id = %L), ''{id}'', to_jsonb(gen_random_uuid())), ''{booking_number}'', ''null''))', bk_none));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot create a booking', CASE WHEN r = 'denied' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', format('DELETE FROM bookings WHERE id IN (%L, %L, %L)', bk_bd, bk_col, bk_none));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot delete bookings', CASE WHEN r IN ('ok:0', 'denied') THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', format('UPDATE bookings SET status = status WHERE id = %L', bk_bd));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'can update own booking (via booking_dentists)', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', format('UPDATE bookings SET status = status WHERE id = %L', bk_col));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'can update own booking (via bookings.dentist_id)', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', format('UPDATE bookings SET status = status WHERE id = %L', bk_none));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot update a booking that is not theirs', CASE WHEN r IN ('ok:0', 'denied') THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('staff', format('UPDATE bookings SET status = status WHERE id = %L', bk_none));
  INSERT INTO t_res VALUES ('PRACT', 'staff', 'control: staff can update that same booking', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', format('UPDATE bookings SET dentist_id = %L WHERE id = %L', d2, bk_col));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot hand a booking to another dentist', CASE WHEN r = 'denied' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner_no_profile', format('UPDATE bookings SET status = status WHERE id = %L', bk_bd));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner_no_profile', 'a practitioner with no profile owns no bookings', CASE WHEN r IN ('ok:0', 'denied') THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', format('INSERT INTO booking_dentists (booking_id, dentist_id) VALUES (%L, %L)', bk_none, d1));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot assign themselves to a booking (booking_dentists)', CASE WHEN r = 'denied' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);

  -- (5) customers: read + UPDATE yes (medical alerts, CMD-56); INSERT / DELETE no
  r := pg_temp.fn_try('practitioner', format('UPDATE customers SET full_name = full_name WHERE id = %L', c1));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'can update a patient', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', format('INSERT INTO customers (branch_id, full_name, org_id) SELECT branch_id, ''New'', org_id FROM customers WHERE id = %L', c1));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot create a patient', CASE WHEN r = 'denied' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('staff', format('INSERT INTO customers (branch_id, full_name, org_id) SELECT branch_id, ''New'', org_id FROM customers WHERE id = %L', c1));
  INSERT INTO t_res VALUES ('PRACT', 'staff', 'control: staff can still create a patient', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', format('DELETE FROM customers WHERE id = %L', c1));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot delete a patient', CASE WHEN r IN ('ok:0', 'denied') THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);

  -- (6) treatment notes and consultations: own bookings only
  r := pg_temp.fn_try('practitioner', format('INSERT INTO treatment_notes (note, booking_id, customer_id, dentist_id) VALUES (''n'', %L, %L, %L)', bk_col, c1, d1));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'can write a note on their own booking', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', format('INSERT INTO treatment_notes (note, booking_id, customer_id, dentist_id) VALUES (''n'', %L, %L, %L)', bk_none, c1, d1));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot write a note on another booking', CASE WHEN r = 'denied' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', format('INSERT INTO consultations (org_id, branch_id, booking_id, patient_name, customer_id, dentist_id) SELECT org_id, branch_id, id, ''P'', customer_id, %L FROM bookings_org WHERE id = %L', d1, bk_col));
  IF r LIKE 'raised:42P01' THEN  -- no helper view: read org/branch via the bookings table
    r := pg_temp.fn_try('practitioner', format('INSERT INTO consultations (org_id, branch_id, booking_id, patient_name, customer_id, dentist_id) SELECT %L, branch_id, id, ''P'', customer_id, %L FROM bookings WHERE id = %L', oa, d1, bk_col));
  END IF;
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'can create a consultation on their own booking', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('practitioner', format('INSERT INTO consultations (org_id, branch_id, booking_id, patient_name, customer_id, dentist_id) SELECT %L, branch_id, id, ''P'', customer_id, %L FROM bookings WHERE id = %L', oa, d1, bk_none));
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'cannot create a consultation on another booking', CASE WHEN r = 'denied' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);

  -- (7) linking: set_user_access is admin-only, same org, and a dentist links to one login
  r := pg_temp.fn_try('admin', format('SELECT set_user_access(%L, ''practitioner'', %L)', u_staff, d2));
  INSERT INTO t_res VALUES ('PRACT', 'admin', 'set_user_access links a same-org user to a same-org dentist', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('admin', format('SELECT set_user_access(%L, ''manager'', %L)', (SELECT uid FROM t_actor WHERE name = 'manager_2_branches'), d2));
  INSERT INTO t_res VALUES ('PRACT', 'admin', 'an admin can link another login (a manager) to a profile and keep the manager role', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('admin', format('SELECT set_user_access(%L, ''staff'', NULL)', (SELECT uid FROM t_actor WHERE name = 'admin')));
  INSERT INTO t_res VALUES ('PRACT', 'admin', 'an admin cannot change their OWN role (no demoting the last admin)', CASE WHEN r LIKE 'raised:%' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('admin', format('SELECT set_user_access(%L, ''admin'', %L)', (SELECT uid FROM t_actor WHERE name = 'admin'), d2));
  INSERT INTO t_res VALUES ('PRACT', 'admin', 'an admin cannot link their OWN login to a profile either', CASE WHEN r LIKE 'raised:%' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('admin', format('SELECT set_user_access(%L, ''practitioner'', %L)', u_staff, db));
  INSERT INTO t_res VALUES ('PRACT', 'admin', 'cannot link a user to ANOTHER org''s dentist', CASE WHEN r LIKE 'raised:%' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('admin', format('SELECT set_user_access(%L, ''practitioner'', %L)', (SELECT uid FROM t_actor WHERE name = 'admin_of_OTHER_org'), d1));
  INSERT INTO t_res VALUES ('PRACT', 'admin', 'cannot change a user of ANOTHER org', CASE WHEN r LIKE 'raised:%' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('admin_of_OTHER_org', format('SELECT set_user_access(%L, ''practitioner'', NULL)', u_staff));
  INSERT INTO t_res VALUES ('PRACT', 'admin_of_OTHER_org', 'an admin of another org cannot change my user', CASE WHEN r LIKE 'raised:%' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  FOR r IN SELECT unnest(ARRAY['manager_2_branches', 'staff', 'practitioner', 'admin_viewer']) LOOP
    INSERT INTO t_res VALUES ('PRACT', r, 'set_user_access refused', CASE WHEN pg_temp.fn_try(r, format('SELECT set_user_access(%L, ''practitioner'', %L)', u_staff, d2)) LIKE 'raised:%' THEN 'PASS' ELSE 'FAIL' END,
                              'got ' || pg_temp.fn_try(r, format('SELECT set_user_access(%L, ''admin'', NULL)', u_staff)));
  END LOOP;
  -- one dentist cannot be linked to two logins (Dr A1 is already the practitioner's)
  r := pg_temp.fn_try('admin', format('SELECT set_user_access(%L, ''practitioner'', %L)', u_staff, d1));
  INSERT INTO t_res VALUES ('PRACT', 'admin', 'one dentist cannot be linked to two logins', CASE WHEN r = 'raised:23505' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);

  -- (8) anon cannot run the new functions; the helper returns the link for the practitioner and NULL otherwise
  FOR t IN SELECT * FROM (VALUES ('get_user_dentist_id()', 'SELECT get_user_dentist_id()'),
                                 ('is_my_booking(uuid)', format('SELECT is_my_booking(%L)', bk_bd)),
                                 ('set_user_access(...)', format('SELECT set_user_access(%L, ''staff'', NULL)', u_staff))) v(label, q) LOOP
    INSERT INTO t_res VALUES ('PRACT', 'anon', t.label || ' not executable', CASE WHEN pg_temp.fn_try('anon', t.q) = 'denied' THEN 'PASS' ELSE 'FAIL' END, 'got ' || pg_temp.fn_try('anon', t.q));
  END LOOP;
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'get_user_dentist_id() is their dentist', CASE WHEN pg_temp.fn_try('practitioner', format('SELECT 1 WHERE get_user_dentist_id() = %L', d1)) = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'Dr A1');
  INSERT INTO t_res VALUES ('PRACT', 'staff', 'get_user_dentist_id() is NULL without a link', CASE WHEN pg_temp.fn_try('staff', 'SELECT 1 WHERE get_user_dentist_id() IS NULL') = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'staff');
  INSERT INTO t_res VALUES ('PRACT', 'practitioner', 'is_my_booking true for own, false for others',
    CASE WHEN pg_temp.fn_try('practitioner', format('SELECT 1 WHERE is_my_booking(%L) AND is_my_booking(%L) AND NOT is_my_booking(%L) AND NOT is_my_booking(%L)', bk_bd, bk_col, bk_none, bk_b)) = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'bd / col / nobody / other org');

  -- (9) a signed-in patient has NO users row (get_user_role() IS NULL): the new RESTRICTIVE policies must NOT block them
  INSERT INTO t_res VALUES ('PRACT', 'customer_no_staff_row', 'NULL role: the restrictive test passes (IS DISTINCT FROM)',
    CASE WHEN pg_temp.fn_try('customer_no_staff_row', 'SELECT 1 WHERE get_user_role() IS NULL AND get_user_role()::text IS DISTINCT FROM ''practitioner''') = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'NULL IS DISTINCT FROM x is true');
  r := pg_temp.fn_try('customer_no_staff_row', 'SELECT 1 FROM bookings');
  INSERT INTO t_res VALUES ('PRACT', 'customer_no_staff_row', 'patient still reads their own booking', CASE WHEN r = 'ok:1' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('customer_no_staff_row', 'SELECT 1 FROM voucher_types');
  INSERT INTO t_res VALUES ('PRACT', 'customer_no_staff_row', 'patient still reads their org''s voucher types (table has a restrictive policy)', CASE WHEN r LIKE 'ok:%' AND r <> 'ok:0' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r || ' (>= 1: the money section adds a second voucher type to org A)');   -- merge glue: same fix as CMD-54
  r := pg_temp.fn_try('customer_no_staff_row', 'SELECT 1 FROM payments');
  INSERT INTO t_res VALUES ('PRACT', 'customer_no_staff_row', 'patient on payments: unchanged (0 rows, no error)', CASE WHEN r = 'ok:0' THEN 'PASS' ELSE 'FAIL' END, 'got ' || r);
  r := pg_temp.fn_try('customer_no_staff_row', format('UPDATE bookings SET status = status WHERE id = %L', bk_none));
  INSERT INTO t_res VALUES ('PRACT', 'customer_no_staff_row', 'patient booking UPDATE not newly blocked by an error', CASE WHEN r IN ('ok:0', 'ok:1', 'denied') THEN 'PASS' ELSE 'FAIL' END, 'got ' || r || ' (same as before: patients have no UPDATE policy)');
END $prac$;

-- ───────────────────────────── 3j. MONEY PART 0 (migration-021, CMD-115) ─────────────────────────────
-- Receipts and bills, numbering, refunds and requests, the day lock by money-event date, blind count and closing, immutability.
-- Seeds what it needs on org A / B (rolled back with the test). Skipped if 021 is absent.
-- BS CALENDAR FIXTURES: the real bs_calendar rows are not in the migration yet (needs-verification, CMD-115). Until they are, this section inserts a
-- few THROWAWAY rows with bs_year 2999 (marked FIXTURE-NOT-CALENDAR-DATA) so the NUMBERING logic can run. They test numbering, never the
-- calendar: no check below claims any AD<->BS mapping is true. They are removed by the final ROLLBACK, and the first check fails if a row with
-- bs_year 2999 is already committed (a leak from another run). The 12 official pairs are separate tests, added with the real data.
CREATE FUNCTION pg_temp.mo_chk(p_label text, p_ok boolean, p_detail text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO t_res VALUES ('MONEY', '-', p_label, CASE WHEN COALESCE(p_ok, false) THEN 'PASS' ELSE 'FAIL' END, p_detail);
  IF NOT COALESCE(p_ok, false) THEN RAISE NOTICE 'FAILED CHECK: % -- %', p_label, left(p_detail, 300); END IF;
END $$;
-- runs one statement as an actor and keeps its effects (the next call builds on it); returns the jsonb of a SELECT, or {raised: sqlstate, msg}
CREATE FUNCTION pg_temp.mo_run(p_actor text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; a record; claims text; dbrole text;
BEGIN
  EXECUTE 'RESET ROLE';
  SELECT * INTO a FROM t_actor WHERE name = p_actor; dbrole := a.db_role;
  claims := CASE WHEN a.uid IS NULL THEN '{"role":"anon"}' ELSE json_build_object('sub', a.uid, 'role', 'authenticated')::text END;
  EXECUTE format('SET LOCAL ROLE %I', dbrole);
  PERFORM set_config('request.jwt.claims', claims, true);
  BEGIN EXECUTE p_sql INTO r; EXCEPTION WHEN OTHERS THEN r := jsonb_build_object('raised', SQLSTATE, 'msg', SQLERRM); END;
  EXECUTE 'RESET ROLE';
  RETURN r;
END $$;
-- same, but as the owner (migration/definer context), keeping effects
CREATE FUNCTION pg_temp.mo_owner(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'RESET ROLE';
  BEGIN EXECUTE p_sql; RETURN 'ok'; EXCEPTION WHEN OTHERS THEN RETURN 'raised:' || SQLERRM; END;
END $$;
CREATE FUNCTION pg_temp.mo_book(p_branch uuid, p_tr uuid, p_cust uuid, p_name text, p_status text, p_amount numeric, p_date date, p_n int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE i uuid := gen_random_uuid(); s timestamptz := ((p_date::timestamp + time '08:00' + (p_n * interval '10 minutes')) AT TIME ZONE 'Asia/Kathmandu');
BEGIN
  INSERT INTO bookings (id, branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, payment_status, dentist_id)
    VALUES (i, p_branch, p_tr, p_cust, p_name, p_date, (s AT TIME ZONE 'Asia/Kathmandu')::time, ((s + interval '5 minutes') AT TIME ZONE 'Asia/Kathmandu')::time, s, s + interval '5 minutes', p_amount, p_amount, p_status::booking_status, 'unpaid', (SELECT id FROM dentists WHERE branch_id = p_branch ORDER BY id LIMIT 1));
  RETURN i;
END $$;
CREATE FUNCTION pg_temp.mo_coll(p_actor text, p_lines text, p_tenders text) RETURNS jsonb LANGUAGE sql AS
$$ SELECT pg_temp.mo_run(p_actor, format('SELECT public.act_money_collect(%L::jsonb, %L::jsonb)', p_lines, p_tenders)) $$;

DO $money$
DECLARE
  oa uuid; ob uuid; a1 uuid; a2 uuid; b1 uuid; tr uuid; trb uuid; cu uuid; cu2 uuid; cua2 uuid; cub uuid; u_staff uuid; u_adm uuid; u_mgr uuid; u_adminb uuid;
  today date := public._money_day(now()); yday date := public._money_day(now()) - 1;
  fx_today boolean := false; fy text; n int; r jsonb; r2 jsonb; s text;
  b1k uuid; b2k uuid; b3k uuid; b4k uuid; bl uuid; bq uuid; bm1 uuid; bm2 uuid; bx uuid; bA2 uuid; bcu2 uuid; bb1 uuid; bb2 uuid; bb3 uuid;
  d1 uuid; d2 uuid; d3 uuid; seq0 int; rid uuid; reqid uuid; k int := 0; cnt int; v_cash numeric; v_exp jsonb;
  u_def uuid;
BEGIN
  IF to_regprocedure('public.act_money_collect(jsonb,jsonb,uuid,text,text,jsonb)') IS NULL THEN
    INSERT INTO t_res VALUES ('MONEY', '-', 'migration-021 checks', 'INFO', 'skipped: migration-021 (money data) not present');
    RETURN;
  END IF;
  SELECT org, uid INTO oa, u_staff FROM t_actor WHERE name = 'staff';
  SELECT uid INTO u_adm FROM t_actor WHERE name = 'admin'; SELECT uid INTO u_mgr FROM t_actor WHERE name = 'manager_2_branches';
  SELECT org, uid INTO ob, u_adminb FROM t_actor WHERE name = 'admin_of_OTHER_org';
  SELECT s2.pk::uuid INTO a1 FROM t_seed s2 JOIN branches b ON b.id = s2.pk::uuid WHERE s2.tbl = 'branches' AND s2.org = oa AND b.name = 'A1';
  SELECT s2.pk::uuid INTO a2 FROM t_seed s2 JOIN branches b ON b.id = s2.pk::uuid WHERE s2.tbl = 'branches' AND s2.org = oa AND b.name = 'A2';
  SELECT s2.pk::uuid INTO b1 FROM t_seed s2 JOIN branches b ON b.id = s2.pk::uuid WHERE s2.tbl = 'branches' AND s2.org = ob;
  SELECT s2.pk::uuid INTO tr FROM t_seed s2 WHERE s2.tbl = 'treatments' AND s2.org = oa LIMIT 1;
  SELECT s2.pk::uuid INTO trb FROM t_seed s2 WHERE s2.tbl = 'treatments' AND s2.org = ob LIMIT 1;
  SELECT s2.pk::uuid INTO cu FROM t_seed s2 JOIN customers c ON c.id = s2.pk::uuid WHERE s2.tbl = 'customers' AND s2.org = oa AND c.branch_id = a1 LIMIT 1;
  SELECT s2.pk::uuid INTO cua2 FROM t_seed s2 JOIN customers c ON c.id = s2.pk::uuid WHERE s2.tbl = 'customers' AND s2.org = oa AND c.branch_id = a2 LIMIT 1;
  INSERT INTO customers (branch_id, full_name, org_id) VALUES (a1, 'Money second patient', oa) RETURNING id INTO cu2;
  INSERT INTO customers (branch_id, full_name, org_id) VALUES (b1, 'Money patient B', ob) RETURNING id INTO cub;

  -- FIXTURE-NOT-CALENDAR-DATA: a leak check first, then throwaway rows (bs_year 2999) for today and for a fake month-3/month-4 pair
  PERFORM pg_temp.mo_chk('fixture hygiene: no committed bs_calendar row has the fake year 2999', NOT EXISTS (SELECT 1 FROM bs_calendar WHERE bs_year = 2999), 'leak from another run');
  IF NOT EXISTS (SELECT 1 FROM bs_calendar WHERE ad_date = today) THEN
    INSERT INTO bs_calendar VALUES (today, 2999, 5, 10); fx_today := true;   -- FIXTURE-NOT-CALENDAR-DATA
  END IF;
  IF NOT EXISTS (SELECT 1 FROM bs_calendar WHERE ad_date = yday) THEN INSERT INTO bs_calendar VALUES (yday, 2999, 5, 9); END IF;   -- FIXTURE-NOT-CALENDAR-DATA
  INSERT INTO bs_calendar VALUES (date '1999-07-15', 2999, 3, 31), (date '1999-07-16', 2999, 4, 1), (date '1999-04-14', 2999, 1, 1);   -- FIXTURE-NOT-CALENDAR-DATA
  fy := fiscal_year(today);

  -- numbering logic on the fixtures (formula only, not the calendar)
  PERFORM pg_temp.mo_chk('fiscal year formula: month 3 day 31 and month 4 day 1 are different years (fixture days)', fiscal_year(date '1999-07-15') = '2998/99' AND fiscal_year(date '1999-07-16') = '2999/00' AND fiscal_year(date '1999-04-14') = '2998/99', fiscal_year(date '1999-07-15') || ' / ' || fiscal_year(date '1999-07-16'));
  PERFORM pg_temp.mo_chk('fiscal year outside the table raises BS_OUT_OF_RANGE (never guesses)', pg_temp.mo_owner('SELECT fiscal_year(date ''1800-01-01'')') LIKE 'raised:BS_OUT_OF_RANGE%', pg_temp.mo_owner('SELECT fiscal_year(date ''1800-01-01'')'));
  PERFORM pg_temp.mo_chk('number formats: receipt, refund note, PAN bill, credit note', money_format_number('receipt', '2083/84', 1189) = '2083/84-1189' AND money_format_number('refund_note', '2083/84', 7) = '2083/84-7'
     AND money_format_number('pan_bill', '2083/84', 1189) = '1189' AND money_format_number('credit_note', '2083/84', 14) = 'CN-14' AND money_format_number('receipt', '2083/84', 1) = '2083/84-1' AND money_format_number('pan_bill', '2084/85', 5) = money_format_number('pan_bill', '2083/84', 5), 'formats (same cases as src/utils/moneyNumber.test.js)');
  PERFORM pg_temp.mo_owner(format('SELECT public._money_next_number(%L, ''receipt'', ''2998/99'')', ob));
  PERFORM pg_temp.mo_chk('counter: first number of a fiscal year is 1 and the next fiscal year restarts at 1',
    public._money_next_number(ob, 'receipt', '2998/99') = 2 AND public._money_next_number(ob, 'receipt', '2999/00') = 1, 'counter');
  DELETE FROM money_counters WHERE org_id = ob;

  -- bookings (org A, branch A1, today): paid-by-split, partial, locked old due, multi-booking, over-pay
  b1k := pg_temp.mo_book(a1, tr, cu, 'Pat One', 'Completed', 1000, today, 1);
  b2k := pg_temp.mo_book(a1, tr, cu, 'Pat One', 'Completed', 500, today, 2);
  b3k := pg_temp.mo_book(a1, tr, cu2, 'Pat Two', 'Confirmed', 800, today, 3);
  bA2 := pg_temp.mo_book(a2, tr, cua2, 'Pat A2', 'Confirmed', 300, today, 4);
  bl  := pg_temp.mo_book(a1, tr, cu2, 'Pat Locked', 'Completed', 700, yday, 5);
  UPDATE bookings SET is_locked = true WHERE id = bl;   -- yesterday's day was closed
  SELECT count(*) INTO cnt FROM money_counters WHERE org_id = oa;
  PERFORM pg_temp.mo_chk('no document or counter exists for org A before the first collect', cnt = 0 AND NOT EXISTS (SELECT 1 FROM money_documents WHERE org_id = oa), 'start state');

  -- ── roles on collect
  r := pg_temp.mo_coll('practitioner', format('[{"booking_id":"%s","amount":100}]', b1k), '[{"mode":"Cash","amount":100}]');
  PERFORM pg_temp.mo_chk('practitioner cannot collect (FORBIDDEN)', pg_temp.act_code(r) = 'FORBIDDEN', coalesce(r::text, 'null'));
  r := pg_temp.mo_coll('admin_viewer', format('[{"booking_id":"%s","amount":100}]', b1k), '[{"mode":"Cash","amount":100}]');
  PERFORM pg_temp.mo_chk('admin_viewer cannot collect (FORBIDDEN)', pg_temp.act_code(r) = 'FORBIDDEN', coalesce(r::text, 'null'));
  r := pg_temp.mo_coll('anon', format('[{"booking_id":"%s","amount":100}]', b1k), '[{"mode":"Cash","amount":100}]');
  PERFORM pg_temp.mo_chk('anonymous cannot call act_money_collect', pg_temp.act_code(r) IN ('raised:42501', 'FORBIDDEN'), coalesce(r::text, 'null'));
  r := pg_temp.mo_coll('admin_of_OTHER_org', format('[{"booking_id":"%s","amount":100}]', b1k), '[{"mode":"Cash","amount":100}]');
  PERFORM pg_temp.mo_chk('another organisation''s admin cannot collect on org A''s booking (BOOKING_NOT_FOUND)', pg_temp.act_code(r) = 'BOOKING_NOT_FOUND', coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('no number was taken by the refused calls', NOT EXISTS (SELECT 1 FROM money_counters WHERE org_id = oa), 'counter');

  -- ── validation (each refusal leaves no number)
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":1500}]', b1k), '[{"mode":"Cash","amount":1500}]');
  PERFORM pg_temp.mo_chk('a line above the booking''s due is refused (OVERPAY)', pg_temp.act_code(r) = 'OVERPAY', coalesce(r::text, 'null'));
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":1000}]', b1k), '[{"mode":"Cash","amount":900}]');
  PERFORM pg_temp.mo_chk('tenders that do not add up to the lines are refused (TENDER_MISMATCH)', pg_temp.act_code(r) = 'TENDER_MISMATCH', coalesce(r::text, 'null'));
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":100}]', b1k), '[{"mode":"Membership","amount":100}]');
  PERFORM pg_temp.mo_chk('a wallet tender is refused (UNSUPPORTED_TENDER)', pg_temp.act_code(r) = 'UNSUPPORTED_TENDER', coalesce(r::text, 'null'));
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":100}]', b1k), '[{"mode":"VoucherWallet","amount":100}]');
  PERFORM pg_temp.mo_chk('a voucher wallet tender is refused (UNSUPPORTED_TENDER)', pg_temp.act_code(r) = 'UNSUPPORTED_TENDER', coalesce(r::text, 'null'));
  r := pg_temp.mo_coll('manager_2_branches', format('[{"booking_id":"%s","amount":100},{"booking_id":"%s","amount":100}]', b1k, bA2), '[{"mode":"Cash","amount":200}]');
  PERFORM pg_temp.mo_chk('bookings of two branches in one call are refused (MIXED_BRANCH)', pg_temp.act_code(r) = 'MIXED_BRANCH', coalesce(r::text, 'null'));
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":100},{"booking_id":"%s","amount":100}]', b1k, b3k), '[{"mode":"Cash","amount":200}]');
  PERFORM pg_temp.mo_chk('bookings of two patients in one call are refused (MIXED_CUSTOMER)', pg_temp.act_code(r) = 'MIXED_CUSTOMER', coalesce(r::text, 'null'));
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":100}]', b1k), '[{"mode":"Cash","amount":-100}]');
  PERFORM pg_temp.mo_chk('a negative tender is refused (INVALID_INPUT)', pg_temp.act_code(r) = 'INVALID_INPUT', coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('none of the refusals took a number or wrote a payment', NOT EXISTS (SELECT 1 FROM money_counters WHERE org_id = oa) AND NOT EXISTS (SELECT 1 FROM payments WHERE booking_id IN (b1k, b2k, b3k)), 'state');

  -- ── a split-tender collect: one receipt, right lines and total
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":1000}]', b1k), '[{"mode":"Cash","amount":600},{"mode":"Esewa","amount":400}]');
  PERFORM pg_temp.mo_chk('staff split-tender collect succeeds', pg_temp.act_code(r) = 'ok', coalesce(r::text, 'null'));
  s := r #>> '{data,number}';
  PERFORM pg_temp.mo_chk('receipt number is fiscal-year-seq (first of the year = 1)', s = money_format_number('receipt', fy, 1), coalesce(s, 'null'));
  SELECT count(*) INTO cnt FROM money_documents WHERE id = (r #>> '{data,document_id}')::uuid AND kind = 'receipt' AND total = 1000 AND jsonb_array_length(lines) = 1 AND (lines #>> '{0,amount}')::numeric = 1000
     AND issued_by = u_staff AND issued_by_name = 'RLS staff A' AND status = 'issued' AND print_count = 0 AND fiscal_year = fy AND seq = 1 AND bs_date IS NOT NULL;
  PERFORM pg_temp.mo_chk('the receipt row: kind, total, one line, issuer, fiscal year, seq, BS date', cnt = 1, 'rows ' || cnt);
  SELECT count(*) INTO cnt FROM payments WHERE booking_id = b1k AND document_id = (r #>> '{data,document_id}')::uuid AND created_at >= now() - interval '1 minute';
  PERFORM pg_temp.mo_chk('two payment rows carry the receipt id and are dated now', cnt = 2, 'rows ' || cnt);
  PERFORM pg_temp.mo_chk('the booking is paid', (SELECT payment_status FROM bookings WHERE id = b1k) = 'paid', (SELECT payment_status FROM bookings WHERE id = b1k));
  PERFORM pg_temp.mo_chk('the audit row carries ids, not amounts', EXISTS (SELECT 1 FROM action_log WHERE action = 'money.collect' AND ok AND target_id = (r #>> '{data,document_id}')::uuid AND NOT (inputs::text ~ '1000|600|400')), 'inputs');

  -- gapless: the next successful collect is 2, and a collect that fails AFTER the number is taken (package redemption of a missing package) leaves no gap
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":500}]', b2k), '[{"mode":"SessionPackage","amount":500,"package_id":"%s"}]'::text);
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":500}]', b2k), format('[{"mode":"SessionPackage","amount":500,"package_id":"%s"}]', gen_random_uuid()));
  PERFORM pg_temp.mo_chk('a collect that fails after the number was taken is refused', pg_temp.act_code(r) IS DISTINCT FROM 'ok', coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('...and used no number and no payment (rolled back with the document)', (SELECT last_seq FROM money_counters WHERE org_id = oa AND series = 'receipt' AND fiscal_year = fy) = 1
     AND NOT EXISTS (SELECT 1 FROM payments WHERE booking_id = b2k) AND (SELECT count(*) FROM money_documents WHERE org_id = oa) = 1, 'counter ' || coalesce((SELECT last_seq::text FROM money_counters WHERE org_id = oa AND series = 'receipt' AND fiscal_year = fy), 'none'));
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":300}]', b2k), '[{"mode":"Cash","amount":300}]');
  PERFORM pg_temp.mo_chk('the next collect gets number 2 (gapless)', r #>> '{data,number}' = money_format_number('receipt', fy, 2), coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('a partial collect leaves the booking partial', (SELECT payment_status FROM bookings WHERE id = b2k) = 'partial', (SELECT payment_status FROM bookings WHERE id = b2k));

  -- several bookings, one patient: one receipt, one line each, a tender split across them
  bm1 := pg_temp.mo_book(a1, tr, cu2, 'Pat Two', 'Confirmed', 200, today, 6); bm2 := pg_temp.mo_book(a1, tr, cu2, 'Pat Two', 'Confirmed', 300, today, 7);
  r := pg_temp.mo_coll('manager_2_branches', format('[{"booking_id":"%s","amount":200},{"booking_id":"%s","amount":150}]', bm1, bm2), '[{"mode":"Cash","amount":250},{"mode":"Card","amount":100}]');
  PERFORM pg_temp.mo_chk('manager collects for two bookings: one receipt number 3', pg_temp.act_code(r) = 'ok' AND r #>> '{data,number}' = money_format_number('receipt', fy, 3), coalesce(r::text, 'null'));
  SELECT count(*) INTO cnt FROM money_documents WHERE id = (r #>> '{data,document_id}')::uuid AND jsonb_array_length(lines) = 2 AND total = 350 AND array_length(booking_ids, 1) = 2;
  PERFORM pg_temp.mo_chk('the receipt has one line per booking and the sum', cnt = 1, 'rows ' || cnt);
  PERFORM pg_temp.mo_chk('each booking got exactly its allocation', (SELECT SUM(amount) FROM payments WHERE booking_id = bm1) = 200 AND (SELECT SUM(amount) FROM payments WHERE booking_id = bm2) = 150
     AND (SELECT payment_status FROM bookings WHERE id = bm1) = 'paid' AND (SELECT payment_status FROM bookings WHERE id = bm2) = 'partial', 'allocation');

  -- ── R1: an old due on a locked booking is collected today, in today's day; the closed day's closing is untouched
  INSERT INTO daily_reports (branch_id, report_date, closed_by) VALUES (a1, yday, u_adm);   -- yesterday was closed the old way
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":700}]', bl), '[{"mode":"Cash","amount":700}]');
  PERFORM pg_temp.mo_chk('an old due on a LOCKED booking is collected today (R1)', pg_temp.act_code(r) = 'ok', coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('...the booking is paid, still locked, and no other column changed', (SELECT payment_status FROM bookings WHERE id = bl) = 'paid' AND (SELECT is_locked FROM bookings WHERE id = bl) AND (SELECT final_amount FROM bookings WHERE id = bl) = 700 AND (SELECT date FROM bookings WHERE id = bl) = yday, 'locked booking');
  PERFORM pg_temp.mo_chk('...the payment is dated today and the closed day''s closing row is unchanged', (SELECT public._money_day(created_at) FROM payments WHERE booking_id = bl) = today
     AND (SELECT count(*) FROM daily_reports WHERE branch_id = a1 AND report_date = yday AND status = 'closed' AND superseded_by IS NULL) = 1, 'dates');

  -- ── §5.3 / §5.4: only money_collect can add a payment to a locked booking, or change payment_status on one
  bq := pg_temp.mo_book(a1, tr, cu2, 'Pat Locked 2', 'Completed', 400, yday, 8); UPDATE bookings SET is_locked = true WHERE id = bq;
  r := pg_temp.mo_run('staff', format('INSERT INTO payments (booking_id, amount, payment_mode, recorded_by) VALUES (%L, 100, ''Cash'', %L) RETURNING to_jsonb(payments)', bq, u_staff));
  PERFORM pg_temp.mo_chk('a client INSERT on a locked booking is still refused (DAY_LOCKED, as today)', r ->> 'msg' LIKE 'DAY_LOCKED%', coalesce(r::text, 'null'));
  r := pg_temp.mo_run('staff', format('INSERT INTO payments (booking_id, amount, payment_mode, recorded_by, document_id) VALUES (%L, 100, ''Cash'', %L, (SELECT id FROM money_documents WHERE org_id = %L LIMIT 1)) RETURNING to_jsonb(payments)', bq, u_staff, oa));
  PERFORM pg_temp.mo_chk('a client cannot set document_id on a payment (DOC_PAYMENT_FORBIDDEN)', r ->> 'msg' LIKE 'DOC_PAYMENT_FORBIDDEN%', coalesce(r::text, 'null'));
  r := pg_temp.mo_run('staff', format('SELECT set_config(''money.doc'', (SELECT id::text FROM money_documents WHERE org_id = %L LIMIT 1), true), (SELECT 1 FROM (INSERT INTO payments (booking_id, amount, payment_mode, recorded_by) VALUES (%L, 100, ''Cash'', %L) RETURNING 1) q)::text', oa, bq, u_staff));
  r := pg_temp.mo_run('staff', format('WITH g AS (SELECT set_config(''money.doc'', (SELECT id::text FROM money_documents WHERE org_id = %L LIMIT 1), true)), i AS (INSERT INTO payments (booking_id, amount, payment_mode, recorded_by, document_id) SELECT %L, 100, ''Cash'', %L, (SELECT id FROM money_documents WHERE org_id = %L LIMIT 1) FROM g RETURNING 1) SELECT to_jsonb(count(*)) FROM i', oa, bq, u_staff, oa));
  PERFORM pg_temp.mo_chk('a client that sets money.doc itself still cannot link a payment (DOC_PAYMENT_FORBIDDEN)', r ->> 'msg' LIKE 'DOC_PAYMENT_FORBIDDEN%', coalesce(r::text, 'null'));
  r := pg_temp.mo_run('staff', format('UPDATE bookings SET payment_status = ''paid'' WHERE id = %L RETURNING to_jsonb(bookings.id)', bq));
  PERFORM pg_temp.mo_chk('a client cannot change payment_status on a locked booking (DAY_LOCKED)', r ->> 'msg' LIKE 'DAY_LOCKED%', coalesce(r::text, 'null'));
  EXECUTE 'CREATE FUNCTION pg_temp.def_status(p uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $f$ BEGIN UPDATE bookings SET payment_status = ''paid'' WHERE id = p; RETURN ''ok''; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $f$';
  PERFORM pg_temp.mo_chk('another definer function cannot change payment_status on a locked booking (no money.doc)', pg_temp.def_status(bq) LIKE 'DAY_LOCKED%', pg_temp.def_status(bq));
  EXECUTE 'CREATE FUNCTION pg_temp.def_pay(p uuid, d uuid, u uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $f$ BEGIN PERFORM set_config(''money.doc'', '''', true); INSERT INTO payments (booking_id, amount, payment_mode, recorded_by, document_id) VALUES (p, 100, ''Cash'', u, d); RETURN ''ok''; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $f$';
  PERFORM pg_temp.mo_chk('a definer insert WITH a document_id but no matching money.doc is refused on a locked booking', pg_temp.def_pay(bq, (SELECT id FROM money_documents WHERE org_id = oa LIMIT 1), u_staff) LIKE 'DAY_LOCKED%', pg_temp.def_pay(bq, (SELECT id FROM money_documents WHERE org_id = oa LIMIT 1), u_staff));
  r := pg_temp.mo_run('staff', format('SELECT to_jsonb(public.record_membership_payment(%L, 10, NULL))', bq));
  PERFORM pg_temp.mo_chk('record_membership_payment on a locked booking cannot change it either', (r ? 'raised') AND (SELECT payment_status FROM bookings WHERE id = bq) = 'unpaid', coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('...and the locked booking stayed unpaid through all of the above', (SELECT payment_status FROM bookings WHERE id = bq) = 'unpaid' AND NOT EXISTS (SELECT 1 FROM payments WHERE booking_id = bq), 'state');

  -- ── immutability of a payment on a receipt (D2): nobody, including the owner and definer code
  SELECT id INTO rid FROM payments WHERE document_id IS NOT NULL AND booking_id = b1k ORDER BY amount LIMIT 1;
  PERFORM pg_temp.mo_chk('owner cannot change the amount of a receipt payment', pg_temp.mo_owner(format('UPDATE payments SET amount = 1 WHERE id = %L', rid)) LIKE 'raised:DOC_PAYMENT_IMMUTABLE%', pg_temp.mo_owner(format('UPDATE payments SET amount = 1 WHERE id = %L', rid)));
  PERFORM pg_temp.mo_chk('...nor its method', pg_temp.mo_owner(format('UPDATE payments SET payment_mode = ''Card'' WHERE id = %L', rid)) LIKE 'raised:DOC_PAYMENT_IMMUTABLE%', 'mode');
  PERFORM pg_temp.mo_chk('...nor its booking', pg_temp.mo_owner(format('UPDATE payments SET booking_id = %L WHERE id = %L', b3k, rid)) LIKE 'raised:DOC_PAYMENT_IMMUTABLE%', 'booking');
  PERFORM pg_temp.mo_chk('...nor its document_id', pg_temp.mo_owner(format('UPDATE payments SET document_id = NULL WHERE id = %L', rid)) LIKE 'raised:DOC_PAYMENT_IMMUTABLE%', 'document');
  PERFORM pg_temp.mo_chk('...nor delete it', pg_temp.mo_owner(format('DELETE FROM payments WHERE id = %L', rid)) LIKE 'raised:DOC_PAYMENT_IMMUTABLE%', 'delete');
  PERFORM pg_temp.mo_chk('...nor its time', pg_temp.mo_owner(format('UPDATE payments SET created_at = created_at + interval ''1 day'' WHERE id = %L', rid)) LIKE 'raised:TIME_IMMUTABLE%', 'time');
  PERFORM pg_temp.mo_chk('deleting a booking that has receipt payments is refused (no way round D2 through the booking or a cascade)', pg_temp.mo_owner(format('DELETE FROM bookings WHERE id = %L', b1k)) LIKE 'raised:%' AND EXISTS (SELECT 1 FROM payments WHERE id = rid), pg_temp.mo_owner(format('DELETE FROM bookings WHERE id = %L', b1k)));
  PERFORM pg_temp.mo_chk('deleting the branch or the organisation is refused too (no ON DELETE CASCADE reaches the payment)', pg_temp.mo_owner(format('DELETE FROM branches WHERE id = %L', a1)) LIKE 'raised:%' AND pg_temp.mo_owner(format('DELETE FROM organizations WHERE id = %L', oa)) LIKE 'raised:%' AND EXISTS (SELECT 1 FROM payments WHERE id = rid), 'cascade');
  -- legacy payments (no document) keep today's behaviour; a client's time is forced to now
  r := pg_temp.mo_run('staff', format('INSERT INTO payments (booking_id, amount, payment_mode, recorded_by, created_at) VALUES (%L, 10, ''Cash'', %L, now() + interval ''40 days'') RETURNING to_jsonb(payments)', b3k, u_staff));
  PERFORM pg_temp.mo_chk('a client payment with a future created_at is stamped now (cannot dodge the lock)', r ->> 'created_at' IS NOT NULL AND (r ->> 'created_at')::timestamptz < now() + interval '1 minute' AND r ->> 'document_id' IS NULL, coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('a legacy payment (no document) can still be corrected, as today', pg_temp.mo_owner(format('UPDATE payments SET amount = 11 WHERE booking_id = %L AND document_id IS NULL', b3k)) = 'ok', 'legacy');

  -- ── documents: immutable except print count, sent and the cancel columns (PAN bill only)
  SELECT id INTO d1 FROM money_documents WHERE org_id = oa ORDER BY seq LIMIT 1;
  PERFORM pg_temp.mo_chk('a document''s total cannot be changed', pg_temp.mo_owner(format('UPDATE money_documents SET total = 1 WHERE id = %L', d1)) LIKE 'raised:DOC_IMMUTABLE%', 'total');
  PERFORM pg_temp.mo_chk('a document cannot be deleted', pg_temp.mo_owner(format('DELETE FROM money_documents WHERE id = %L', d1)) LIKE 'raised:DOC_IMMUTABLE%', 'delete');
  PERFORM pg_temp.mo_chk('a receipt can never be cancelled', pg_temp.mo_owner(format('UPDATE money_documents SET status = ''cancelled'', cancel_reason = ''x'', cancelled_by = %L, cancelled_at = now() WHERE id = %L', u_adm, d1)) LIKE 'raised:DOC_IMMUTABLE%', 'cancel');
  PERFORM pg_temp.mo_chk('a client cannot write money_documents at all', pg_temp.mo_run('staff', format('UPDATE money_documents SET print_count = 5 WHERE id = %L RETURNING to_jsonb(1)', d1)) ->> 'raised' = '42501', 'grant');
  PERFORM pg_temp.mo_chk('the issue time cannot be changed', pg_temp.mo_owner(format('UPDATE money_documents SET issued_at = issued_at + interval ''1 day'' WHERE id = %L', d1)) LIKE 'raised:DOC_IMMUTABLE%', 'time');
  r := pg_temp.mo_run('staff', format('SELECT public.act_document_print(%L)', d1)); r2 := pg_temp.mo_run('staff', format('SELECT public.act_document_print(%L)', d1));
  PERFORM pg_temp.mo_chk('print: first Original, then Copy', r #>> '{data,label}' = 'Original' AND r2 #>> '{data,label}' = 'Copy' AND (SELECT print_count FROM money_documents WHERE id = d1) = 2, coalesce(r::text, '') || coalesce(r2::text, ''));
  PERFORM pg_temp.mo_chk('admin_viewer cannot print (a print is a write)', pg_temp.act_code(pg_temp.mo_run('admin_viewer', format('SELECT public.act_document_print(%L)', d1))) = 'FORBIDDEN', 'viewer');
  PERFORM pg_temp.mo_chk('practitioner cannot print', pg_temp.act_code(pg_temp.mo_run('practitioner', format('SELECT public.act_document_print(%L)', d1))) = 'FORBIDDEN', 'practitioner');
  r := pg_temp.mo_run('staff', format('SELECT public.act_document_send(%L, ''sms'', ''+9779800000000'')', d1));
  PERFORM pg_temp.mo_chk('send is recorded on the document', pg_temp.act_code(r) = 'ok' AND jsonb_array_length((SELECT sent FROM money_documents WHERE id = d1)) = 1, coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('another organisation''s admin cannot print org A''s document (DOCUMENT_NOT_FOUND)', pg_temp.act_code(pg_temp.mo_run('admin_of_OTHER_org', format('SELECT public.act_document_print(%L)', d1))) = 'DOCUMENT_NOT_FOUND', 'org');

  -- ── tenant isolation of the new tables
  PERFORM pg_temp.mo_chk('another organisation sees none of org A''s documents, requests, closings', (pg_temp.mo_run('admin_of_OTHER_org', 'SELECT to_jsonb(count(*)) FROM money_documents')) = '0'::jsonb
     AND (pg_temp.mo_run('admin_of_OTHER_org', 'SELECT to_jsonb(count(*)) FROM money_requests')) = '0'::jsonb AND (pg_temp.mo_run('admin_of_OTHER_org', format('SELECT to_jsonb(count(*)) FROM daily_reports WHERE branch_id = %L', a1))) = '0'::jsonb, 'cross-org');
  PERFORM pg_temp.mo_chk('nobody reads or writes money_counters directly', pg_temp.mo_run('admin', 'SELECT to_jsonb(count(*)) FROM money_counters') ->> 'raised' = '42501', 'counters');
  PERFORM pg_temp.mo_chk('practitioner and anonymous read no documents', (pg_temp.mo_run('practitioner', 'SELECT to_jsonb(count(*)) FROM money_documents')) = '0'::jsonb AND coalesce(pg_temp.mo_run('anon', 'SELECT to_jsonb(count(*)) FROM money_documents') ->> 'raised', '42501') = '42501', 'practitioner');
  PERFORM pg_temp.mo_chk('staff and admin_viewer read org A''s documents (own branch)', (pg_temp.mo_run('staff', 'SELECT to_jsonb(count(*)) FROM money_documents') #>> '{}')::int > 0 AND (pg_temp.mo_run('admin_viewer', 'SELECT to_jsonb(count(*)) FROM money_documents') #>> '{}')::int > 0, 'reads');

  -- ── refunds and requests
  r := pg_temp.mo_run('staff', format('SELECT public.act_money_refund(%L, 100, ''x'', ''cash'')', b1k));
  PERFORM pg_temp.mo_chk('front desk cannot refund (FORBIDDEN)', pg_temp.act_code(r) = 'FORBIDDEN', coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('admin_viewer and practitioner cannot refund', pg_temp.act_code(pg_temp.mo_run('admin_viewer', format('SELECT public.act_money_refund(%L, 100, ''x'', ''cash'')', b1k))) = 'FORBIDDEN' AND pg_temp.act_code(pg_temp.mo_run('practitioner', format('SELECT public.act_money_refund(%L, 100, ''x'', ''cash'')', b1k))) = 'FORBIDDEN', 'roles');
  r := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_money_refund(%L, 100, '''', ''cash'')', b1k));
  PERFORM pg_temp.mo_chk('a refund needs a reason (REASON_REQUIRED)', pg_temp.act_code(r) = 'REASON_REQUIRED', coalesce(r::text, 'null'));
  r := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_money_refund(%L, 1200, ''too much'', ''cash'')', b1k));
  PERFORM pg_temp.mo_chk('never more than paid (OVERREFUND)', pg_temp.act_code(r) = 'OVERREFUND', coalesce(r::text, 'null'));
  r := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_money_refund(%L, 300, ''wrong treatment'', ''cash'')', b1k));
  PERFORM pg_temp.mo_chk('manager refunds 300 of 1000: a refund note in the receipt series, number 5', pg_temp.act_code(r) = 'ok' AND r #>> '{data,kind}' = 'refund_note' AND r #>> '{data,number}' = money_format_number('refund_note', fy, 5), coalesce(r::text, 'null'));
  SELECT count(*) INTO cnt FROM money_documents n JOIN money_documents o ON o.id = n.related_document_id JOIN payment_refunds pr ON pr.document_id = n.id
   WHERE n.id = (r #>> '{data,document_id}')::uuid AND o.kind = 'receipt' AND n.total = 300 AND pr.amount = 300 AND pr.paid_back_by = 'cash' AND pr.reason = 'wrong treatment';
  PERFORM pg_temp.mo_chk('the refund note is linked to its receipt and to the refund row', cnt = 1, 'rows ' || cnt);
  r := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_money_refund(%L, 800, ''again'', ''cash'')', b1k));
  PERFORM pg_temp.mo_chk('earlier refunds count against the limit (700 left)', pg_temp.act_code(r) = 'OVERREFUND', coalesce(r::text, 'null'));
  -- requests
  r := pg_temp.mo_run('staff', format('SELECT public.act_money_request_refund(%L, %L, 100, ''patient asked'')', d1, b1k));
  PERFORM pg_temp.mo_chk('front desk raises a refund request, assigned to a manager, nothing refunded', pg_temp.act_code(r) = 'ok' AND (r #>> '{data,assigned}')::boolean, coalesce(r::text, 'null'));
  reqid := (r #>> '{data,request_id}')::uuid;
  PERFORM pg_temp.mo_chk('...the request is open and the refund total is unchanged', (SELECT status FROM money_requests WHERE id = reqid) = 'open' AND (SELECT SUM(amount) FROM payment_refunds WHERE booking_id = b1k) = 300, 'open');
  PERFORM pg_temp.mo_chk('front desk cannot decline a request', pg_temp.act_code(pg_temp.mo_run('staff', format('SELECT public.act_money_request_decline(%L)', reqid))) = 'FORBIDDEN', 'decline');
  r := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_money_refund(%L, 100, ''approved'', ''cash'', %L)', b1k, reqid));
  PERFORM pg_temp.mo_chk('the manager completes the request with a refund: request becomes done', pg_temp.act_code(r) = 'ok' AND (SELECT status FROM money_requests WHERE id = reqid) = 'done', coalesce(r::text, 'null'));
  r := pg_temp.mo_run('staff', format('SELECT public.act_money_request_refund(%L, %L, 50)', d1, b1k)); reqid := (r #>> '{data,request_id}')::uuid;
  r2 := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_money_request_decline(%L, ''no'')', reqid));
  PERFORM pg_temp.mo_chk('a manager declines a request', pg_temp.act_code(r2) = 'ok' AND (SELECT status FROM money_requests WHERE id = reqid) = 'declined', coalesce(r2::text, 'null') || coalesce((SELECT status FROM money_requests WHERE id = reqid), 'norow') || coalesce(reqid::text, 'noreq') || coalesce(r::text, ''));
  PERFORM pg_temp.mo_chk('a request cannot ask for more than was paid less refunds', pg_temp.act_code(pg_temp.mo_run('staff', format('SELECT public.act_money_request_refund(%L, %L, 5000)', d1, b1k))) = 'OVERREFUND', 'over');
  PERFORM pg_temp.mo_chk('another organisation cannot request on org A''s receipt', pg_temp.act_code(pg_temp.mo_run('admin_of_OTHER_org', format('SELECT public.act_money_request_refund(%L, %L, 10)', d1, b1k))) = 'DOCUMENT_NOT_FOUND', 'org');

  -- ── PAN bill mode (org B has no documents yet): billing mode, bills, cancel -> credit note, sales register
  bb1 := pg_temp.mo_book(b1, trb, cub, 'Pat B', 'Confirmed', 1000, today, 1); bb2 := pg_temp.mo_book(b1, trb, cub, 'Pat B', 'Confirmed', 600, today, 2); bb3 := pg_temp.mo_book(b1, trb, cub, 'Pat B', 'Confirmed', 400, today, 3);
  PERFORM pg_temp.mo_chk('only the owner changes the billing mode (staff and manager are FORBIDDEN)', pg_temp.act_code(pg_temp.mo_run('staff', 'SELECT public.act_billing_set_mode(''123456789'', true)')) = 'FORBIDDEN'
     AND pg_temp.act_code(pg_temp.mo_run('manager_2_branches', 'SELECT public.act_billing_set_mode(''123456789'', true)')) = 'FORBIDDEN', 'roles');
  PERFORM pg_temp.mo_chk('PAN bill mode needs the clinic PAN', pg_temp.act_code(pg_temp.mo_run('admin_of_OTHER_org', 'SELECT public.act_billing_set_mode('''', true)')) = 'PAN_REQUIRED', 'pan');
  r := pg_temp.mo_run('admin_of_OTHER_org', 'SELECT public.act_billing_set_mode(''123456789'', true)');   -- (the call first: a sub-select inside the same expression would be read before it runs)
  PERFORM pg_temp.mo_chk('the owner turns PAN bill mode on (audited)', pg_temp.act_code(r) = 'ok'
     AND (SELECT pan_bill_mode FROM org_billing_settings WHERE org_id = ob) AND (SELECT mode_changed_by FROM org_billing_settings WHERE org_id = ob) = u_adminb
     AND EXISTS (SELECT 1 FROM action_log WHERE action = 'billing.set_mode' AND org_id = ob AND ok), coalesce(r::text, 'null'));
  r := pg_temp.mo_coll('admin_of_OTHER_org', format('[{"booking_id":"%s","amount":1000}]', bb1), '[{"mode":"Cash","amount":1000}]');
  PERFORM pg_temp.mo_chk('in PAN mode a collect issues a PAN bill, numbered 1 (no fiscal-year prefix)', pg_temp.act_code(r) = 'ok' AND r #>> '{data,kind}' = 'pan_bill' AND r #>> '{data,number}' = '1', coalesce(r::text, 'null'));
  d2 := (r #>> '{data,document_id}')::uuid;
  r := pg_temp.mo_coll('admin_of_OTHER_org', format('[{"booking_id":"%s","amount":600}]', bb2), '[{"mode":"Cash","amount":600}]');
  PERFORM pg_temp.mo_chk('the next bill is 2', r #>> '{data,number}' = '2', coalesce(r::text, 'null'));
  d3 := (r #>> '{data,document_id}')::uuid;
  PERFORM pg_temp.mo_chk('the mode cannot change once documents exist this fiscal year (MODE_CHANGE_MID_YEAR)', pg_temp.act_code(pg_temp.mo_run('admin_of_OTHER_org', 'SELECT public.act_billing_set_mode(''123456789'', false)')) = 'MODE_CHANGE_MID_YEAR', 'mid-year');
  PERFORM pg_temp.mo_chk('a receipt cannot be cancelled through bill.cancel (NOT_A_BILL)', pg_temp.act_code(pg_temp.mo_run('manager_2_branches', format('SELECT public.act_bill_cancel(%L, ''x'')', d1))) = 'NOT_A_BILL', 'receipt');
  PERFORM pg_temp.mo_chk('only manager or owner cancels a bill (admin_viewer FORBIDDEN)', pg_temp.act_code(pg_temp.mo_run('admin_viewer', format('SELECT public.act_bill_cancel(%L, ''x'')', d2))) = 'FORBIDDEN', 'roles');
  PERFORM pg_temp.mo_chk('a cancel needs a reason', pg_temp.act_code(pg_temp.mo_run('admin_of_OTHER_org', format('SELECT public.act_bill_cancel(%L, '' '')', d2))) = 'REASON_REQUIRED', 'reason');
  r := pg_temp.mo_run('admin_of_OTHER_org', format('SELECT public.act_bill_cancel(%L, ''issued to the wrong patient'')', d2));
  PERFORM pg_temp.mo_chk('cancelling bill 1 issues credit note CN-1 in the same transaction', pg_temp.act_code(r) = 'ok' AND r #>> '{data,number}' = 'CN-1' AND (SELECT status FROM money_documents WHERE id = d2) = 'cancelled', coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('the credit note points at the bill; the bill''s number and total are untouched', (SELECT related_document_id FROM money_documents WHERE id = (r #>> '{data,credit_note_id}')::uuid) = d2 AND (SELECT number FROM money_documents WHERE id = d2) = '1' AND (SELECT total FROM money_documents WHERE id = d2) = 1000, 'link');
  PERFORM pg_temp.mo_chk('cancelling twice is refused (ALREADY_CANCELLED)', pg_temp.act_code(pg_temp.mo_run('admin_of_OTHER_org', format('SELECT public.act_bill_cancel(%L, ''again'')', d2))) = 'ALREADY_CANCELLED', 'twice');
  PERFORM pg_temp.mo_chk('the sales register lists the cancelled bill and the credit note, and org A sees none of it',
     (SELECT count(*) FROM money_sales_register WHERE org_id = ob AND number = '1' AND status = 'cancelled' AND kind = 'pan_bill') = 1 AND (SELECT count(*) FROM money_sales_register WHERE org_id = ob AND number = 'CN-1' AND kind = 'credit_note') = 1
     AND (pg_temp.mo_run('admin_of_OTHER_org', 'SELECT to_jsonb(count(*)) FROM money_sales_register') #>> '{}')::int = 3 AND (pg_temp.mo_run('admin', 'SELECT to_jsonb(count(*)) FROM money_sales_register') #>> '{}')::int = 0, 'register');
  r := pg_temp.mo_run('admin_of_OTHER_org', format('SELECT public.act_money_refund(%L, 100, ''partial'', ''cash'')', bb3));
  PERFORM pg_temp.mo_chk('a refund on a booking with no document is recorded without a note (legacy payments)', pg_temp.act_code(r) = 'OVERREFUND', coalesce(r::text, 'null'));
  r := pg_temp.mo_run('admin_of_OTHER_org', format('SELECT public.act_money_refund(%L, 100, ''partial'', ''cash'')', bb2));
  PERFORM pg_temp.mo_chk('a refund on a PAN-billed booking gives a credit note CN-2 linked to the bill', pg_temp.act_code(r) = 'ok' AND r #>> '{data,kind}' = 'credit_note' AND r #>> '{data,number}' = 'CN-2', coalesce(r::text, 'null'));

  -- ── daily closing (org A, branch A1, today): blockers, blind count, difference, lock, reopen
  -- open items on today: b3k is Confirmed (fine); make a visit still in the chair and a completed unpaid one with no due holder
  bx := pg_temp.mo_book(a1, tr, cu, 'Pat Chair', 'In-Progress', 100, today, 9); bcu2 := pg_temp.mo_book(a1, tr, cu, 'Pat Unpaid', 'Completed', 100, today, 10);
  r := pg_temp.mo_run('staff', format('SELECT public.act_day_expected(%L, %L)', a1, today));
  PERFORM pg_temp.mo_chk('front desk cannot read expected amounts (FORBIDDEN, a fixed message with no figures)', pg_temp.act_code(r) = 'FORBIDDEN' AND r #>> '{error,message}' = 'Your role cannot do this.' AND NOT ((r #>> '{error,message}') ~ '[0-9]') AND (r -> 'data') = 'null'::jsonb, coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('practitioner cannot read expected amounts', pg_temp.act_code(pg_temp.mo_run('practitioner', format('SELECT public.act_day_expected(%L, %L)', a1, today))) = 'FORBIDDEN', 'practitioner');
  r := pg_temp.mo_run('staff', format('SELECT public.act_day_submit_count(%L, %L, ''{"Cash": 100}''::jsonb)', a1, today));
  PERFORM pg_temp.mo_chk('the blind count returns exactly {"submitted": true} to front desk (no expected, no difference)', pg_temp.act_code(r) = 'ok' AND (r -> 'data') = '{"submitted": true}'::jsonb, coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('...and what the audit row stores has no expected amount either', NOT EXISTS (SELECT 1 FROM action_log WHERE action = 'day.submit_count' AND result::text ~ 'expected'), 'log');
  r := pg_temp.mo_run('staff', format('SELECT public.act_day_submit_count(%L, %L, ''{"cash": 200}''::jsonb)', a1, today));
  PERFORM pg_temp.mo_chk('submitting again replaces the count (one counted row, the new value)', pg_temp.act_code(r) = 'ok' AND (SELECT count(*) FROM daily_reports WHERE branch_id = a1 AND report_date = today AND status = 'counted') = 1
     AND (SELECT (blind_counts ->> 'cash')::numeric FROM daily_reports WHERE branch_id = a1 AND report_date = today AND status = 'counted') = 200, 'one row');
  PERFORM pg_temp.mo_chk('front desk cannot close or reopen', pg_temp.act_code(pg_temp.mo_run('staff', format('SELECT public.act_day_close(%L, %L)', a1, today))) = 'FORBIDDEN' AND pg_temp.act_code(pg_temp.mo_run('staff', format('SELECT public.act_day_reopen(%L, %L, ''x'')', a1, today))) = 'FORBIDDEN', 'roles');
  PERFORM pg_temp.mo_chk('practitioner and admin_viewer cannot submit a count', pg_temp.act_code(pg_temp.mo_run('practitioner', format('SELECT public.act_day_submit_count(%L, %L, ''{"cash": 1}''::jsonb)', a1, today))) = 'FORBIDDEN' AND pg_temp.act_code(pg_temp.mo_run('admin_viewer', format('SELECT public.act_day_submit_count(%L, %L, ''{"cash": 1}''::jsonb)', a1, today))) = 'FORBIDDEN', 'roles');
  PERFORM pg_temp.mo_chk('admin may submit a count too', pg_temp.act_code(pg_temp.mo_run('admin', format('SELECT public.act_day_submit_count(%L, %L, ''{"cash": 200}''::jsonb)', a1, today))) = 'ok', 'admin');
  r := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_day_close(%L, %L)', a1, today));
  PERFORM pg_temp.mo_chk('a visit in the chair and completed visits neither paid nor left as due block the close, listed (BLOCKERS)', pg_temp.act_code(r) = 'BLOCKERS' AND jsonb_array_length(r -> 'data') = 3
     AND (r -> 'data') @> jsonb_build_array(jsonb_build_object('code', 'IN_CHAIR', 'booking_id', bx), jsonb_build_object('code', 'NOT_PAID_OR_DUE', 'booking_id', bcu2), jsonb_build_object('code', 'NOT_PAID_OR_DUE', 'booking_id', b2k)), coalesce(r::text, 'null'));
  UPDATE bookings SET status = 'Completed' WHERE id = bx;   -- the visit ends
  UPDATE bookings SET due_holder_name = 'Family member' WHERE id IN (bx, bcu2);   -- both left as due under a named person
  UPDATE bookings SET status = 'Completed', due_holder_name = 'Family member' WHERE id IN (b2k, bm2, b3k);   -- partial / unpaid visits left as due
  r := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_day_close(%L, %L)', a1, today));
  PERFORM pg_temp.mo_chk('with a count that differs from the system, a manager must give a reason (REASON_REQUIRED)', pg_temp.act_code(r) = 'REASON_REQUIRED', coalesce(r::text, 'null'));
  r := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_day_expected(%L, %L)', a1, today)); v_exp := r #> '{data,expected}';
  SELECT COALESCE(SUM(p.amount) FILTER (WHERE lower(p.payment_mode) = 'cash'), 0) - COALESCE((SELECT SUM(amount) FROM payment_refunds pr JOIN bookings bb ON bb.id = pr.booking_id WHERE bb.branch_id = a1 AND public._money_day(pr.created_at) = today AND lower(COALESCE(pr.paid_back_by, 'cash')) = 'cash'), 0)   -- a refund with no recorded method (legacy rows, the automatic cancellation refund) is treated as cash
    INTO v_cash FROM payments p JOIN bookings b ON b.id = p.booking_id WHERE b.branch_id = a1 AND public._money_day(p.created_at) = today;
  PERFORM pg_temp.mo_chk('the manager sees expected cash = cash taken today less cash refunds today (counted by money-event date)', pg_temp.act_code(r) = 'ok' AND (v_exp ->> 'cash')::numeric = v_cash AND v_cash > 0 AND (r #>> '{data,counted,cash}')::numeric = 200, coalesce(v_exp::text, 'null') || ' vs ' || v_cash );
  PERFORM pg_temp.mo_chk('admin_viewer can read expected (read only)', pg_temp.act_code(pg_temp.mo_run('admin_viewer', format('SELECT public.act_day_expected(%L, %L)', a1, today))) = 'ok', 'viewer');
  PERFORM pg_temp.mo_chk('the old due paid today counts today: expected includes the 700 collected on yesterday''s booking', (v_exp ->> 'cash')::numeric >= 700, v_exp::text);
  r := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_day_close(%L, %L, ''coins short'')', a1, today));
  PERFORM pg_temp.mo_chk('with a reason, the manager closes the day', pg_temp.act_code(r) = 'ok' AND (SELECT status FROM daily_reports WHERE branch_id = a1 AND report_date = today AND superseded_by IS NULL) = 'closed' AND (SELECT difference_reason FROM daily_reports WHERE branch_id = a1 AND report_date = today AND status = 'closed') = 'coins short', coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('closing locks the day''s bookings', NOT EXISTS (SELECT 1 FROM bookings WHERE branch_id = a1 AND date = today AND NOT is_locked), 'bookings');
  -- a closed day refuses each kind of write
  seq0 := (SELECT last_seq FROM money_counters WHERE org_id = oa AND series = 'receipt' AND fiscal_year = fy);
  bm1 := pg_temp.mo_book(a1, tr, cu2, 'Pat Late', 'Confirmed', 100, today, 11);
  r := pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":100}]', bm1), '[{"mode":"Cash","amount":100}]');
  PERFORM pg_temp.mo_chk('a collect on a closed day is refused (DAY_LOCKED) and takes no number', pg_temp.act_code(r) = 'DAY_LOCKED' AND (SELECT last_seq FROM money_counters WHERE org_id = oa AND series = 'receipt' AND fiscal_year = fy) = seq0, coalesce(r::text, 'null'));
  r := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_money_refund(%L, 50, ''late'', ''cash'')', b1k));
  PERFORM pg_temp.mo_chk('a refund on a closed day is refused (DAY_LOCKED)', pg_temp.act_code(r) = 'DAY_LOCKED', coalesce(r::text, 'null'));
  r := pg_temp.mo_run('staff', format('INSERT INTO payments (booking_id, amount, payment_mode, recorded_by, created_at) VALUES (%L, 10, ''Cash'', %L, now() + interval ''2 days'') RETURNING to_jsonb(payments)', bm1, u_staff));
  PERFORM pg_temp.mo_chk('a client payment on a closed day is refused, even with a future created_at', r ->> 'msg' LIKE 'DAY_LOCKED%', coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('a payment_refunds row on a closed day is refused (owner too)', pg_temp.mo_owner(format('INSERT INTO payment_refunds (booking_id, org_id, amount, refunded_by, reason) VALUES (%L, %L, 1, %L, ''x'')', b1k, oa, u_adm)) LIKE 'raised:DAY_LOCKED%', 'refund row');
  PERFORM pg_temp.mo_chk('a document on a closed day is refused (owner too)', pg_temp.mo_owner(format('INSERT INTO money_documents (org_id, branch_id, kind, series, fiscal_year, seq, number, total) VALUES (%L, %L, ''receipt'', ''receipt'', %L, 999, ''x'', 1)', oa, a1, fy)) LIKE 'raised:DAY_LOCKED%', 'document');
  PERFORM pg_temp.mo_chk('a refund can never be deleted or moved in time', pg_temp.mo_owner(format('DELETE FROM payment_refunds WHERE booking_id = %L', b1k)) LIKE 'raised:REFUND_IMMUTABLE%' AND pg_temp.mo_owner(format('UPDATE payment_refunds SET created_at = created_at - interval ''5 days'' WHERE booking_id = %L', b1k)) LIKE 'raised:TIME_IMMUTABLE%', 'refund immutable');
  PERFORM pg_temp.mo_chk('today''s other branch is not closed: a branch-A2 collect still works', pg_temp.act_code(pg_temp.mo_coll('manager_2_branches', format('[{"booking_id":"%s","amount":300}]', bA2), '[{"mode":"Cash","amount":300}]')) = 'ok', 'branch A2');
  PERFORM pg_temp.mo_chk('closing the same day again is refused (ALREADY_CLOSED)', pg_temp.act_code(pg_temp.mo_run('manager_2_branches', format('SELECT public.act_day_close(%L, %L)', a1, today))) = 'ALREADY_CLOSED', 'twice');
  -- reopen: owner only, reason required, audited, history kept
  PERFORM pg_temp.mo_chk('a manager cannot reopen (owner only)', pg_temp.act_code(pg_temp.mo_run('manager_2_branches', format('SELECT public.act_day_reopen(%L, %L, ''x'')', a1, today))) = 'FORBIDDEN', 'manager');
  PERFORM pg_temp.mo_chk('the owner needs a reason to reopen', pg_temp.act_code(pg_temp.mo_run('admin', format('SELECT public.act_day_reopen(%L, %L, '' '')', a1, today))) = 'REASON_REQUIRED', 'reason');
  r := pg_temp.mo_run('admin', format('SELECT public.act_day_reopen(%L, %L, ''a receipt was missed'')', a1, today));
  PERFORM pg_temp.mo_chk('the owner reopens the day: audited, old closing kept as history, bookings unlocked', pg_temp.act_code(r) = 'ok'
     AND EXISTS (SELECT 1 FROM daily_reports WHERE branch_id = a1 AND report_date = today AND status = 'reopened' AND reopened_by = u_adm AND reopen_reason = 'a receipt was missed' AND closed_by = u_mgr)
     AND NOT EXISTS (SELECT 1 FROM bookings WHERE branch_id = a1 AND date = today AND is_locked) AND EXISTS (SELECT 1 FROM action_log WHERE action = 'day.reopen' AND ok AND actor_user_id = u_adm), coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('the day is open again: a collect works', pg_temp.act_code(pg_temp.mo_coll('staff', format('[{"booking_id":"%s","amount":100}]', bm1), '[{"mode":"Cash","amount":100}]')) = 'ok', 'collect');
  PERFORM pg_temp.mo_chk('it must be closed again with a NEW count (NO_COUNT first)', pg_temp.act_code(pg_temp.mo_run('manager_2_branches', format('SELECT public.act_day_close(%L, %L)', a1, today))) = 'NO_COUNT', 'no count');
  PERFORM pg_temp.mo_run('staff', format('SELECT public.act_day_submit_count(%L, %L, ''{"cash": 400}''::jsonb)', a1, today));
  r := pg_temp.mo_run('manager_2_branches', format('SELECT public.act_day_close(%L, %L, ''recounted'')', a1, today));
  PERFORM pg_temp.mo_chk('closing again works; the reopened row is kept as history and marked superseded', pg_temp.act_code(r) = 'ok'
     AND (SELECT count(*) FROM daily_reports WHERE branch_id = a1 AND report_date = today) = 2 AND (SELECT count(*) FROM daily_reports WHERE branch_id = a1 AND report_date = today AND superseded_by IS NOT NULL AND status = 'reopened') = 1
     AND public.day_is_closed(a1, today), coalesce(r::text, 'null'));
  PERFORM pg_temp.mo_chk('no staff-visible failure leaks a figure (checked over every refusal for staff in the audit log)', NOT EXISTS (SELECT 1 FROM action_log WHERE actor_user_id = u_staff AND NOT ok AND (result::text ~ '[0-9]{3}' AND result #>> '{error,message}' ~ '[0-9]')), 'leak');
END $money$;

-- COVERAGE: RLS tables that this test does not seed (static checks above still apply)
INSERT INTO t_res
SELECT 'COVERAGE', '-', c.relname, 'INFO', 'not seeded: dynamic matrix skipped (static policy checks apply)'
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname NOT IN (SELECT tbl FROM t_seed) ORDER BY 3;

-- ───────────────────────────── 4. REPORT ─────────────────────────────
SELECT status || '|' || kind || '|' || caller || '|' || subject || '|' || detail
FROM t_res WHERE kind <> 'OWN' AND NOT (kind = 'COVERAGE') AND NOT (status = 'PASS' AND :'verbose' = 'off') ORDER BY status, kind, caller, subject;
SELECT 'OWN|' || caller || '|' || subject || '|' || detail FROM t_res WHERE kind = 'OWN' ORDER BY caller, subject;
SELECT 'COVERAGE|' || subject || '|' || detail FROM t_res WHERE kind = 'COVERAGE' ORDER BY subject;
SELECT 'SUMMARY|' || status || '|' || count(*) FROM t_res WHERE kind NOT IN ('OWN', 'COVERAGE') GROUP BY status ORDER BY status;

DO $verdict$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM t_res WHERE status = 'FAIL';
  IF n > 0 THEN RAISE EXCEPTION 'tenant isolation: % FAIL(s)', n; END IF;
END $verdict$;

ROLLBACK;
