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
  b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid; bR1 uuid; bR2 uuid; bR3 uuid; bD uuid; bPaid uuid; bX uuid;
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
  UPDATE bookings SET status = 'Pending' WHERE id = bX;
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
  SELECT jsonb_build_object('action_id', id) INTO r2 FROM action_log WHERE target_id = bX AND action = 'booking.set_status' AND ok ORDER BY created_at DESC LIMIT 1;
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
    (oa, pat2, 'sms', '+9779801000002', 'service', 'agreed', 'booking', 'Phone given when booking');

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
  INSERT INTO patient_channels (org_id, customer_id, channel, address, purpose, status, source, evidence) VALUES (oa, pat4, 'sms', '+9779801000042', 'service', 'stopped', 'patient_reply', 'STOP');
  INSERT INTO customers (branch_id, full_name, org_id, phone) VALUES (a1, 'Hub Backfill NoBooking', oa, '+9779801000043');
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
