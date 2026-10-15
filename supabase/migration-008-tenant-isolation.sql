-- migration-008-tenant-isolation.sql
-- SECURITY: close cross-clinic access through the legacy "branch" RLS policies.
--
-- Production carries two generations of permissive policies. Postgres grants a row when ANY permissive policy passes, so the older
-- generation (no org check: `branch_id = ANY(get_user_branch_ids()) OR get_user_role() = 'admin'`, and role-only payroll policies)
-- let an admin / admin_viewer of ONE clinic read and write every other clinic's bookings, customers, payments, payroll, ...
--
-- The legacy policies are NOT dropped: they are the only ones using get_user_branch_ids() (managers/staff with several branches via
-- user_branches). Each keeps its name and original logic and gains an org guard in front (ALTER POLICY, so this is idempotent: the
-- statements state the full final expression, they do not wrap the current one).
--   branch tables ........ public.branch_in_my_org(branch_id) AND (<original>)
--   payments ............. the booking must be in a branch of my org
--   users ................ org_id = get_user_org_id() AND (<original>)
--   payroll_runs ......... branch_in_my_org(branch_id) AND <role check>
--   payroll_items ........ through payroll_runs
--   staff_compensation ... through dentists (org)
-- INSERT/UPDATE get the same guard in WITH CHECK, so nobody can write a row into another org.
-- Also two tables whose policies were literally `true` for every signed-in user (patients and other clinics included):
--   booking_dentists ..... read: the booking must be readable by the caller (its own RLS); writes: booking in a branch of my org
--   treatment_categories . writes: org_id = my org (SELECT stays open: a names-only catalog patients see while booking)
-- Rollback: migration-008-rollback.sql (restores the exact previous expressions).

BEGIN;

CREATE OR REPLACE FUNCTION public.branch_in_my_org(p_branch uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch AND org_id = public.get_user_org_id());
$$;
REVOKE ALL ON FUNCTION public.branch_in_my_org(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.branch_in_my_org(uuid) TO authenticated;

ALTER POLICY "Staff can read branch bookings" ON public.bookings
    USING (public.branch_in_my_org(branch_id) AND (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Staff can create branch bookings" ON public.bookings
    WITH CHECK (public.branch_in_my_org(branch_id) AND (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Staff can update branch bookings" ON public.bookings
    USING (public.branch_in_my_org(branch_id) AND (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))))
    WITH CHECK (public.branch_in_my_org(branch_id) AND (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Staff can read branch customers" ON public.customers
    USING (public.branch_in_my_org(branch_id) AND (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Staff can create customers" ON public.customers
    WITH CHECK (public.branch_in_my_org(branch_id) AND (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Staff can update branch customers" ON public.customers
    USING (public.branch_in_my_org(branch_id) AND (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))))
    WITH CHECK (public.branch_in_my_org(branch_id) AND (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Manager can read branch daily reports" ON public.daily_reports
    USING (public.branch_in_my_org(branch_id) AND (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Manager can close day" ON public.daily_reports
    WITH CHECK (public.branch_in_my_org(branch_id) AND (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)))));

ALTER POLICY "Staff can read branch dentist attendance" ON public.dentist_attendance
    USING (public.branch_in_my_org(branch_id) AND (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Manager can manage dentist attendance" ON public.dentist_attendance
    WITH CHECK (public.branch_in_my_org(branch_id) AND (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)))));

ALTER POLICY "Manager can update dentist attendance" ON public.dentist_attendance
    USING (public.branch_in_my_org(branch_id) AND (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)))))
    WITH CHECK (public.branch_in_my_org(branch_id) AND (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)))));

ALTER POLICY "Manager can read branch audit logs" ON public.audit_logs
    USING (public.branch_in_my_org(branch_id) AND (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)))));

ALTER POLICY "Staff can read branch payments" ON public.payments
    USING (EXISTS (SELECT 1 FROM public.bookings gb WHERE gb.id = payments.booking_id AND public.branch_in_my_org(gb.branch_id)) AND ((EXISTS ( SELECT 1 FROM bookings b WHERE ((b.id = payments.booking_id) AND ((b.branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)))))));

ALTER POLICY "Staff can record payments" ON public.payments
    WITH CHECK (EXISTS (SELECT 1 FROM public.bookings gb WHERE gb.id = payments.booking_id AND public.branch_in_my_org(gb.branch_id)) AND ((EXISTS ( SELECT 1 FROM bookings b WHERE ((b.id = payments.booking_id) AND ((b.branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)))))));

ALTER POLICY "Managers can read branch users" ON public.users
    USING (org_id = public.get_user_org_id() AND (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)))));

ALTER POLICY "Admin manage payroll runs" ON public.payroll_runs
    USING (public.branch_in_my_org(branch_id) AND ((get_user_role() = 'admin'::user_role)))
    WITH CHECK (public.branch_in_my_org(branch_id) AND ((get_user_role() = 'admin'::user_role)));

ALTER POLICY "Admin viewer can read payroll runs" ON public.payroll_runs
    USING (public.branch_in_my_org(branch_id) AND ((get_user_role() = 'admin_viewer'::user_role)));

ALTER POLICY "Admin manage payroll items" ON public.payroll_items
    USING (EXISTS (SELECT 1 FROM public.payroll_runs gr WHERE gr.id = payroll_items.payroll_run_id AND public.branch_in_my_org(gr.branch_id)) AND ((get_user_role() = 'admin'::user_role)))
    WITH CHECK (EXISTS (SELECT 1 FROM public.payroll_runs gr WHERE gr.id = payroll_items.payroll_run_id AND public.branch_in_my_org(gr.branch_id)) AND ((get_user_role() = 'admin'::user_role)));

ALTER POLICY "Admin viewer can read payroll items" ON public.payroll_items
    USING (EXISTS (SELECT 1 FROM public.payroll_runs gr WHERE gr.id = payroll_items.payroll_run_id AND public.branch_in_my_org(gr.branch_id)) AND ((get_user_role() = 'admin_viewer'::user_role)));

ALTER POLICY "Admin manage staff compensation" ON public.staff_compensation
    USING (EXISTS (SELECT 1 FROM public.dentists gd WHERE gd.id = staff_compensation.dentist_id AND gd.org_id = public.get_user_org_id()) AND ((get_user_role() = 'admin'::user_role)))
    WITH CHECK (EXISTS (SELECT 1 FROM public.dentists gd WHERE gd.id = staff_compensation.dentist_id AND gd.org_id = public.get_user_org_id()) AND ((get_user_role() = 'admin'::user_role)));

ALTER POLICY "Admin viewer can read staff compensation" ON public.staff_compensation
    USING (EXISTS (SELECT 1 FROM public.dentists gd WHERE gd.id = staff_compensation.dentist_id AND gd.org_id = public.get_user_org_id()) AND ((get_user_role() = 'admin_viewer'::user_role)));

-- ── Policies that were open to every signed-in user ──
ALTER POLICY booking_dentists_select ON public.booking_dentists
    USING (EXISTS (SELECT 1 FROM public.bookings b WHERE b.id = booking_dentists.booking_id));
ALTER POLICY booking_dentists_insert ON public.booking_dentists
    WITH CHECK (EXISTS (SELECT 1 FROM public.bookings b WHERE b.id = booking_dentists.booking_id AND public.branch_in_my_org(b.branch_id)));
ALTER POLICY booking_dentists_update ON public.booking_dentists
    USING (EXISTS (SELECT 1 FROM public.bookings b WHERE b.id = booking_dentists.booking_id AND public.branch_in_my_org(b.branch_id)))
    WITH CHECK (EXISTS (SELECT 1 FROM public.bookings b WHERE b.id = booking_dentists.booking_id AND public.branch_in_my_org(b.branch_id)));
ALTER POLICY booking_dentists_delete ON public.booking_dentists
    USING (EXISTS (SELECT 1 FROM public.bookings b WHERE b.id = booking_dentists.booking_id AND public.branch_in_my_org(b.branch_id)));

ALTER POLICY treatment_categories_insert ON public.treatment_categories WITH CHECK (org_id = public.get_user_org_id());
ALTER POLICY treatment_categories_update ON public.treatment_categories
    USING (org_id = public.get_user_org_id()) WITH CHECK (org_id = public.get_user_org_id());
ALTER POLICY treatment_categories_delete ON public.treatment_categories USING (org_id = public.get_user_org_id());

COMMIT;
