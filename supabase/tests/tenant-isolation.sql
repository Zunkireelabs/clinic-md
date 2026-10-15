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
