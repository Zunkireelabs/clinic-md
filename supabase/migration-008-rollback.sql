-- migration-008-rollback.sql: restores the exact policy expressions that were in place before migration-008.
-- (branch_in_my_org() is left in place; nothing references it after this runs, and dropping it is harmless: DROP FUNCTION public.branch_in_my_org(uuid);)
BEGIN;

ALTER POLICY "Staff can read branch bookings" ON public.bookings
    USING (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)));

ALTER POLICY "Staff can create branch bookings" ON public.bookings
    WITH CHECK (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)));

ALTER POLICY "Staff can update branch bookings" ON public.bookings
    USING (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)))
    WITH CHECK (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)));

ALTER POLICY "Staff can read branch customers" ON public.customers
    USING (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)));

ALTER POLICY "Staff can create customers" ON public.customers
    WITH CHECK (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)));

ALTER POLICY "Staff can update branch customers" ON public.customers
    USING (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)))
    WITH CHECK (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)));

ALTER POLICY "Manager can read branch daily reports" ON public.daily_reports
    USING (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)));

ALTER POLICY "Manager can close day" ON public.daily_reports
    WITH CHECK (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Staff can read branch dentist attendance" ON public.dentist_attendance
    USING (((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role)));

ALTER POLICY "Manager can manage dentist attendance" ON public.dentist_attendance
    WITH CHECK (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Manager can update dentist attendance" ON public.dentist_attendance
    USING (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))))
    WITH CHECK (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Manager can read branch audit logs" ON public.audit_logs
    USING (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Staff can read branch payments" ON public.payments
    USING ((EXISTS ( SELECT 1 FROM bookings b WHERE ((b.id = payments.booking_id) AND ((b.branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))))));

ALTER POLICY "Staff can record payments" ON public.payments
    WITH CHECK ((EXISTS ( SELECT 1 FROM bookings b WHERE ((b.id = payments.booking_id) AND ((b.branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))))));

ALTER POLICY "Managers can read branch users" ON public.users
    USING (((get_user_role() = ANY (ARRAY['manager'::user_role, 'admin'::user_role])) AND ((branch_id = ANY (get_user_branch_ids())) OR (get_user_role() = 'admin'::user_role))));

ALTER POLICY "Admin manage payroll runs" ON public.payroll_runs
    USING ((get_user_role() = 'admin'::user_role))
    WITH CHECK ((get_user_role() = 'admin'::user_role));

ALTER POLICY "Admin viewer can read payroll runs" ON public.payroll_runs
    USING ((get_user_role() = 'admin_viewer'::user_role));

ALTER POLICY "Admin manage payroll items" ON public.payroll_items
    USING ((get_user_role() = 'admin'::user_role))
    WITH CHECK ((get_user_role() = 'admin'::user_role));

ALTER POLICY "Admin viewer can read payroll items" ON public.payroll_items
    USING ((get_user_role() = 'admin_viewer'::user_role));

ALTER POLICY "Admin manage staff compensation" ON public.staff_compensation
    USING ((get_user_role() = 'admin'::user_role))
    WITH CHECK ((get_user_role() = 'admin'::user_role));

ALTER POLICY "Admin viewer can read staff compensation" ON public.staff_compensation
    USING ((get_user_role() = 'admin_viewer'::user_role));

ALTER POLICY booking_dentists_select ON public.booking_dentists USING (true);
ALTER POLICY booking_dentists_insert ON public.booking_dentists WITH CHECK (true);
ALTER POLICY booking_dentists_update ON public.booking_dentists USING (true) WITH CHECK (true);
ALTER POLICY booking_dentists_delete ON public.booking_dentists USING (true);
ALTER POLICY treatment_categories_insert ON public.treatment_categories WITH CHECK (true);
ALTER POLICY treatment_categories_update ON public.treatment_categories USING (true) WITH CHECK (true);
ALTER POLICY treatment_categories_delete ON public.treatment_categories USING (true);

DROP FUNCTION IF EXISTS public.branch_in_my_org(uuid);

COMMIT;
