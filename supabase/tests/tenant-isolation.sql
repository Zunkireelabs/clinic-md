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
  u_cust uuid := gen_random_uuid(); u_adminb uuid := gen_random_uuid();
  tr_a uuid; tr_b uuid; d_a1 uuid; d_a2 uuid; d_b uuid; c_a1 uuid; c_a2 uuid; c_b uuid; bk_a1 uuid; bk_a2 uuid; bk_b uuid;
  run_a1 uuid; run_a2 uuid; run_b uuid; x uuid; sfx text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  seq int := 0;
BEGIN
  INSERT INTO organizations (id, name, code, slug) VALUES (oa, 'RLS Test A', 'rlsa' || sfx, 'rls-a-' || sfx), (ob, 'RLS Test B', 'rlsb' || sfx, 'rls-b-' || sfx);
  PERFORM pg_temp.sd('organizations', 'id', oa::text, oa); PERFORM pg_temp.sd('organizations', 'id', ob::text, ob);
  INSERT INTO branches (id, name, org_id) VALUES (a1, 'A1', oa), (a2, 'A2', oa), (b1, 'B1', ob);
  PERFORM pg_temp.sd('branches', 'id', a1::text, oa); PERFORM pg_temp.sd('branches', 'id', a2::text, oa); PERFORM pg_temp.sd('branches', 'id', b1::text, ob);

  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at) VALUES
    (u_admin,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-admin-' || sfx || '@test.invalid', now(), now()),
    (u_viewer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-viewer-' || sfx || '@test.invalid', now(), now()),
    (u_mgr,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-mgr-' || sfx || '@test.invalid', now(), now()),
    (u_staff,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-staff-' || sfx || '@test.invalid', now(), now()),
    (u_cust,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-cust-' || sfx || '@test.invalid', now(), now()),
    (u_adminb, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rls-adminb-' || sfx || '@test.invalid', now(), now());
  INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active) VALUES
    (u_admin,  'rls-admin-' || sfx || '@test.invalid',  'RLS admin A',  'admin',        a1, oa, true),
    (u_viewer, 'rls-viewer-' || sfx || '@test.invalid', 'RLS viewer A', 'admin_viewer', a1, oa, true),
    (u_mgr,    'rls-mgr-' || sfx || '@test.invalid',    'RLS mgr A',    'manager',      a1, oa, true),
    (u_staff,  'rls-staff-' || sfx || '@test.invalid',  'RLS staff A',  'staff',        a1, oa, true),
    (u_adminb, 'rls-adminb-' || sfx || '@test.invalid', 'RLS admin B',  'admin',        b1, ob, true);
  INSERT INTO user_branches (user_id, branch_id) VALUES (u_mgr, a2); -- the manager works in TWO branches
  PERFORM pg_temp.sd('users', 'id', u_admin::text, oa); PERFORM pg_temp.sd('users', 'id', u_viewer::text, oa); PERFORM pg_temp.sd('users', 'id', u_mgr::text, oa);
  PERFORM pg_temp.sd('users', 'id', u_staff::text, oa); PERFORM pg_temp.sd('users', 'id', u_adminb::text, ob);
  PERFORM pg_temp.sd('user_branches', 'user_id', u_mgr::text, oa);

  INSERT INTO t_actor VALUES ('admin', u_admin, oa, 'authenticated'), ('admin_viewer', u_viewer, oa, 'authenticated'),
    ('manager_2_branches', u_mgr, oa, 'authenticated'), ('staff', u_staff, oa, 'authenticated'),
    ('customer_no_staff_row', u_cust, oa, 'authenticated'), ('anon', NULL, oa, 'anon'), ('admin_of_OTHER_org', u_adminb, ob, 'authenticated');

  -- treatments, dentists, customers
  INSERT INTO treatments (name, duration_minutes, price_npr, org_id) VALUES ('T A', 30, 1000, oa) RETURNING id INTO tr_a;
  INSERT INTO treatments (name, duration_minutes, price_npr, org_id) VALUES ('T B', 30, 1000, ob) RETURNING id INTO tr_b;
  PERFORM pg_temp.sd('treatments', 'id', tr_a::text, oa); PERFORM pg_temp.sd('treatments', 'id', tr_b::text, ob);
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (a1, 'Dr A1', 'Male', oa) RETURNING id INTO d_a1;
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (a2, 'Dr A2', 'Male', oa) RETURNING id INTO d_a2;
  INSERT INTO dentists (branch_id, name, gender, org_id) VALUES (b1, 'Dr B', 'Male', ob) RETURNING id INTO d_b;
  PERFORM pg_temp.sd('dentists', 'id', d_a1::text, oa); PERFORM pg_temp.sd('dentists', 'id', d_a2::text, oa); PERFORM pg_temp.sd('dentists', 'id', d_b::text, ob);
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
