-- book-dental row-level security policies
-- ALTER TABLE ... ENABLE ROW LEVEL SECURITY and CREATE POLICY statements.
-- Companion file to schema.sql.

CREATE POLICY "Admin can manage membership tiers" ON public.membership_tiers TO authenticated USING (((public.get_user_role() = 'admin'::public.user_role) AND (org_id = public.get_user_org_id()))) WITH CHECK (((public.get_user_role() = 'admin'::public.user_role) AND (org_id = public.get_user_org_id())));

CREATE POLICY "Admin can manage package types" ON public.package_types TO authenticated USING (((public.get_user_role() = 'admin'::public.user_role) AND (org_id = public.get_user_org_id()))) WITH CHECK (((public.get_user_role() = 'admin'::public.user_role) AND (org_id = public.get_user_org_id())));

CREATE POLICY "Admin can manage voucher types" ON public.voucher_types TO authenticated USING (((public.get_user_role() = 'admin'::public.user_role) AND (org_id = public.get_user_org_id()))) WITH CHECK (((public.get_user_role() = 'admin'::public.user_role) AND (org_id = public.get_user_org_id())));

CREATE POLICY "Admin manage payroll items" ON public.payroll_items TO authenticated USING ((public.get_user_role() = 'admin'::public.user_role)) WITH CHECK ((public.get_user_role() = 'admin'::public.user_role));

CREATE POLICY "Admin manage payroll runs" ON public.payroll_runs TO authenticated USING ((public.get_user_role() = 'admin'::public.user_role)) WITH CHECK ((public.get_user_role() = 'admin'::public.user_role));

CREATE POLICY "Admin manage staff compensation" ON public.staff_compensation TO authenticated USING ((public.get_user_role() = 'admin'::public.user_role)) WITH CHECK ((public.get_user_role() = 'admin'::public.user_role));

CREATE POLICY "Admin viewer can read org attendance" ON public.attendance FOR SELECT TO authenticated USING (((public.get_user_role() = 'admin_viewer'::public.user_role) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = attendance.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Admin viewer can read org audit logs" ON public.audit_logs FOR SELECT TO authenticated USING (((public.get_user_role() = 'admin_viewer'::public.user_role) AND ((branch_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = audit_logs.branch_id) AND (b.org_id = public.get_user_org_id())))))));

CREATE POLICY "Admin viewer can read org bookings" ON public.bookings FOR SELECT TO authenticated USING (((public.get_user_role() = 'admin_viewer'::public.user_role) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = bookings.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Admin viewer can read org daily reports" ON public.daily_reports FOR SELECT TO authenticated USING (((public.get_user_role() = 'admin_viewer'::public.user_role) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = daily_reports.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Admin viewer can read org payments" ON public.payments FOR SELECT TO authenticated USING (((public.get_user_role() = 'admin_viewer'::public.user_role) AND (EXISTS ( SELECT 1
   FROM (public.bookings bk
     JOIN public.branches b ON ((b.id = bk.branch_id)))
  WHERE ((bk.id = payments.booking_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Admin viewer can read org dentist attendance" ON public.dentist_attendance FOR SELECT TO authenticated USING (((public.get_user_role() = 'admin_viewer'::public.user_role) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = dentist_attendance.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Admin viewer can read org users" ON public.users FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = 'admin_viewer'::public.user_role)));

CREATE POLICY "Admin viewer can read payroll items" ON public.payroll_items FOR SELECT TO authenticated USING ((public.get_user_role() = 'admin_viewer'::public.user_role));

CREATE POLICY "Admin viewer can read payroll runs" ON public.payroll_runs FOR SELECT TO authenticated USING ((public.get_user_role() = 'admin_viewer'::public.user_role));

CREATE POLICY "Admin viewer can read staff compensation" ON public.staff_compensation FOR SELECT TO authenticated USING ((public.get_user_role() = 'admin_viewer'::public.user_role));

CREATE POLICY "Admins can grant org branch access" ON public.user_branches FOR INSERT TO authenticated WITH CHECK (((public.get_user_role() = 'admin'::public.user_role) AND (EXISTS ( SELECT 1
   FROM public.users u
  WHERE ((u.id = user_branches.user_id) AND (u.org_id = public.get_user_org_id())))) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = user_branches.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Admins can read org branch grants" ON public.user_branches FOR SELECT TO authenticated USING (((public.get_user_role() = 'admin'::public.user_role) AND (EXISTS ( SELECT 1
   FROM public.users u
  WHERE ((u.id = user_branches.user_id) AND (u.org_id = public.get_user_org_id()))))));

CREATE POLICY "Admins can revoke org branch access" ON public.user_branches FOR DELETE TO authenticated USING (((public.get_user_role() = 'admin'::public.user_role) AND (EXISTS ( SELECT 1
   FROM public.users u
  WHERE ((u.id = user_branches.user_id) AND (u.org_id = public.get_user_org_id()))))));

CREATE POLICY "Anon can read active organizations" ON public.organizations FOR SELECT TO anon USING ((is_active = true));

CREATE POLICY "Anonymous can read active branches" ON public.branches FOR SELECT TO anon USING ((is_active = true));

CREATE POLICY "Anonymous can read active organizations" ON public.organizations FOR SELECT TO anon USING ((is_active = true));

CREATE POLICY "Anonymous can read active chairs" ON public.chairs FOR SELECT TO anon USING ((is_active = true));

CREATE POLICY "Anonymous can read active treatments" ON public.treatments FOR SELECT TO anon USING ((is_active = true));

CREATE POLICY "Anonymous can read active dentists" ON public.dentists FOR SELECT TO anon USING ((is_active = true));

CREATE POLICY "Anonymous users can create bookings" ON public.bookings FOR INSERT TO anon WITH CHECK ((EXISTS ( SELECT 1
   FROM public.branches
  WHERE ((branches.id = bookings.branch_id) AND (branches.is_active = true)))));

CREATE POLICY "Anyone can read membership tiers" ON public.membership_tiers FOR SELECT TO anon USING ((is_active = true));

CREATE POLICY "Manager and admin can create org reward catalog" ON public.reward_catalog FOR INSERT TO authenticated WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (org_id = public.get_user_org_id())));

CREATE POLICY "Manager and admin can create org treatments" ON public.treatments FOR INSERT TO authenticated WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (org_id = public.get_user_org_id())));

CREATE POLICY "Manager and admin can delete org reward catalog" ON public.reward_catalog FOR DELETE TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (org_id = public.get_user_org_id())));

CREATE POLICY "Manager and admin can delete org treatments" ON public.treatments FOR DELETE TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (org_id = public.get_user_org_id())));

CREATE POLICY "Manager and admin can update org reward catalog" ON public.reward_catalog FOR UPDATE TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (org_id = public.get_user_org_id()))) WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (org_id = public.get_user_org_id())));

CREATE POLICY "Manager and admin can update org treatments" ON public.treatments FOR UPDATE TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (org_id = public.get_user_org_id()))) WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (org_id = public.get_user_org_id())));

CREATE POLICY "Manager can close day" ON public.daily_reports FOR INSERT TO authenticated WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND ((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Manager can close own org day" ON public.daily_reports FOR INSERT TO authenticated WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = daily_reports.branch_id) AND (b.org_id = public.get_user_org_id())))) AND ((branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Manager can create org chairs" ON public.chairs FOR INSERT TO authenticated WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = chairs.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Manager can create org dentists" ON public.dentists FOR INSERT TO authenticated WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = dentists.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Manager can create own org dentist attendance" ON public.dentist_attendance FOR INSERT TO authenticated WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = dentist_attendance.branch_id) AND (b.org_id = public.get_user_org_id())))) AND ((branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Manager can delete org chairs" ON public.chairs FOR DELETE TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = chairs.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Manager can delete org dentists" ON public.dentists FOR DELETE TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = dentists.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Manager can manage dentist attendance" ON public.dentist_attendance FOR INSERT TO authenticated WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND ((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Manager can read branch audit logs" ON public.audit_logs FOR SELECT TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND ((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Manager can read branch daily reports" ON public.daily_reports FOR SELECT TO authenticated USING (((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role)));

CREATE POLICY "Manager can read own org attendance" ON public.attendance FOR SELECT TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = attendance.branch_id) AND (b.org_id = public.get_user_org_id())))) AND ((branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Manager can read own org audit logs" ON public.audit_logs FOR SELECT TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND ((branch_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = audit_logs.branch_id) AND (b.org_id = public.get_user_org_id()))))) AND ((branch_id IS NULL) OR (branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Manager can read own org daily reports" ON public.daily_reports FOR SELECT TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = daily_reports.branch_id) AND (b.org_id = public.get_user_org_id())))) AND ((branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Manager can read own org users" ON public.users FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager can update org chairs" ON public.chairs FOR UPDATE TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = chairs.branch_id) AND (b.org_id = public.get_user_org_id())))))) WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = chairs.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Manager can update org dentists" ON public.dentists FOR UPDATE TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = dentists.branch_id) AND (b.org_id = public.get_user_org_id())))))) WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = dentists.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Manager can update own org dentist attendance" ON public.dentist_attendance FOR UPDATE TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = dentist_attendance.branch_id) AND (b.org_id = public.get_user_org_id())))) AND ((branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role)))) WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = dentist_attendance.branch_id) AND (b.org_id = public.get_user_org_id())))) AND ((branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Manager can update dentist attendance" ON public.dentist_attendance FOR UPDATE TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND ((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role)))) WITH CHECK (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND ((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Manager/admin can dismiss within own org" ON public.customer_duplicate_dismissals FOR INSERT TO authenticated WITH CHECK (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin can read own org dismissals" ON public.customer_duplicate_dismissals FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin can read own org membership transactions" ON public.membership_transactions FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role, 'admin_viewer'::public.user_role]))));

CREATE POLICY "Manager/admin can read own org voucher claims" ON public.voucher_claims FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role, 'admin_viewer'::public.user_role]))));

CREATE POLICY "Manager/admin can read own org voucher payments" ON public.voucher_payments FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role, 'admin_viewer'::public.user_role]))));

CREATE POLICY "Manager/admin can read own org vouchers" ON public.vouchers FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role, 'admin_viewer'::public.user_role]))));

CREATE POLICY "Manager/admin delete outreach ai config" ON public.outreach_ai_config FOR DELETE TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin delete outreach provider config" ON public.outreach_provider_config FOR DELETE TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin delete outreach rules" ON public.outreach_rules FOR DELETE TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin delete outreach templates" ON public.outreach_templates FOR DELETE TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin insert outreach ai config" ON public.outreach_ai_config FOR INSERT TO authenticated WITH CHECK (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin insert outreach provider config" ON public.outreach_provider_config FOR INSERT TO authenticated WITH CHECK (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin read outreach ai config" ON public.outreach_ai_config FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin read outreach drafts" ON public.outreach_drafts FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin read outreach messages" ON public.outreach_messages FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin read outreach provider config" ON public.outreach_provider_config FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin update outreach ai config" ON public.outreach_ai_config FOR UPDATE TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])))) WITH CHECK (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin update outreach provider config" ON public.outreach_provider_config FOR UPDATE TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])))) WITH CHECK (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin update outreach rules" ON public.outreach_rules FOR UPDATE TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])))) WITH CHECK (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin update outreach templates" ON public.outreach_templates FOR UPDATE TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])))) WITH CHECK (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin write outreach rules" ON public.outreach_rules FOR INSERT TO authenticated WITH CHECK (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin write outreach templates" ON public.outreach_templates FOR INSERT TO authenticated WITH CHECK (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role]))));

CREATE POLICY "Manager/admin/staff can read own org memberships" ON public.memberships FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role, 'admin_viewer'::public.user_role, 'staff'::public.user_role]))));

CREATE POLICY "Managers can read branch users" ON public.users FOR SELECT TO authenticated USING (((public.get_user_role() = ANY (ARRAY['manager'::public.user_role, 'admin'::public.user_role])) AND ((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Org members read outreach rules" ON public.outreach_rules FOR SELECT TO authenticated USING ((org_id = public.get_user_org_id()));

CREATE POLICY "Org members read outreach templates" ON public.outreach_templates FOR SELECT TO authenticated USING ((org_id = public.get_user_org_id()));

CREATE POLICY "Staff can create branch bookings" ON public.bookings FOR INSERT TO authenticated WITH CHECK (((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role)));

CREATE POLICY "Staff can create customers" ON public.customers FOR INSERT TO authenticated WITH CHECK (((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role)));

CREATE POLICY "Staff can create own org bookings" ON public.bookings FOR INSERT TO authenticated WITH CHECK (((EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = bookings.branch_id) AND (b.org_id = public.get_user_org_id())))) AND ((branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Staff can create own org customers" ON public.customers FOR INSERT TO authenticated WITH CHECK ((org_id = public.get_user_org_id()));

CREATE POLICY "Staff can read branch bookings" ON public.bookings FOR SELECT TO authenticated USING (((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role)));

CREATE POLICY "Staff can read branch customers" ON public.customers FOR SELECT TO authenticated USING (((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role)));

CREATE POLICY "Staff can read branch payments" ON public.payments FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.bookings b
  WHERE ((b.id = payments.booking_id) AND ((b.branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role))))));

CREATE POLICY "Staff can read branch dentist attendance" ON public.dentist_attendance FOR SELECT TO authenticated USING (((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role)));

CREATE POLICY "Staff can read own org bookings" ON public.bookings FOR SELECT TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = bookings.branch_id) AND (b.org_id = public.get_user_org_id())))) AND ((branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Staff can read own org customers" ON public.customers FOR SELECT TO authenticated USING ((org_id = public.get_user_org_id()));

CREATE POLICY "Staff can read own org package redemptions" ON public.package_redemptions FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['staff'::public.user_role, 'manager'::public.user_role, 'admin'::public.user_role, 'admin_viewer'::public.user_role]))));

CREATE POLICY "Staff can read own org packages" ON public.packages FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['staff'::public.user_role, 'manager'::public.user_role, 'admin'::public.user_role, 'admin_viewer'::public.user_role]))));

CREATE POLICY "Staff can read own org payment refunds" ON public.payment_refunds FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (EXISTS ( SELECT 1
   FROM public.bookings bk
  WHERE ((bk.id = payment_refunds.booking_id) AND ((bk.branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role)))))));

CREATE POLICY "Staff can read own org payments" ON public.payments FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM (public.bookings bk
     JOIN public.branches b ON ((b.id = bk.branch_id)))
  WHERE ((bk.id = payments.booking_id) AND (b.org_id = public.get_user_org_id()) AND ((bk.branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))))));

CREATE POLICY "Staff can read own org dentist attendance" ON public.dentist_attendance FOR SELECT TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = dentist_attendance.branch_id) AND (b.org_id = public.get_user_org_id())))) AND ((branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Staff can read package types" ON public.package_types FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['staff'::public.user_role, 'manager'::public.user_role, 'admin'::public.user_role, 'admin_viewer'::public.user_role]))));

CREATE POLICY "Staff can record own org payment refunds" ON public.payment_refunds FOR INSERT TO authenticated WITH CHECK (((org_id = public.get_user_org_id()) AND (EXISTS ( SELECT 1
   FROM public.bookings bk
  WHERE ((bk.id = payment_refunds.booking_id) AND ((bk.branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role)))))));

CREATE POLICY "Staff can record own org payments" ON public.payments FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM (public.bookings bk
     JOIN public.branches b ON ((b.id = bk.branch_id)))
  WHERE ((bk.id = payments.booking_id) AND (b.org_id = public.get_user_org_id()) AND ((bk.branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))))));

CREATE POLICY "Staff can record payments" ON public.payments FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM public.bookings b
  WHERE ((b.id = payments.booking_id) AND ((b.branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role))))));

CREATE POLICY "Staff can reorder branch chairs" ON public.chairs FOR UPDATE TO authenticated USING (((public.get_user_role() = 'staff'::public.user_role) AND (branch_id = public.get_user_branch_id()))) WITH CHECK (((public.get_user_role() = 'staff'::public.user_role) AND (branch_id = public.get_user_branch_id())));

CREATE POLICY "Staff can reorder branch dentists" ON public.dentists FOR UPDATE TO authenticated USING (((public.get_user_role() = 'staff'::public.user_role) AND (branch_id = public.get_user_branch_id()))) WITH CHECK (((public.get_user_role() = 'staff'::public.user_role) AND (branch_id = public.get_user_branch_id())));

CREATE POLICY "Staff can update branch bookings" ON public.bookings FOR UPDATE TO authenticated USING (((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role))) WITH CHECK (((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role)));

CREATE POLICY "Staff can update branch customers" ON public.customers FOR UPDATE TO authenticated USING (((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role))) WITH CHECK (((branch_id = ANY (public.get_user_branch_ids())) OR (public.get_user_role() = 'admin'::public.user_role)));

CREATE POLICY "Staff can update own org bookings" ON public.bookings FOR UPDATE TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = bookings.branch_id) AND (b.org_id = public.get_user_org_id())))) AND ((branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role)))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = bookings.branch_id) AND (b.org_id = public.get_user_org_id())))) AND ((branch_id = public.get_user_branch_id()) OR (public.get_user_role() = 'admin'::public.user_role))));

CREATE POLICY "Staff can update own org customers" ON public.customers FOR UPDATE TO authenticated USING ((org_id = public.get_user_org_id())) WITH CHECK ((org_id = public.get_user_org_id()));

CREATE POLICY "Staff/manager/admin can read voucher types" ON public.voucher_types FOR SELECT TO authenticated USING (((org_id = public.get_user_org_id()) AND (public.get_user_role() = ANY (ARRAY['staff'::public.user_role, 'manager'::public.user_role, 'admin'::public.user_role, 'admin_viewer'::public.user_role]))));

CREATE POLICY "Users can check in own org" ON public.attendance FOR INSERT TO authenticated WITH CHECK (((user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = attendance.branch_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Users can check out" ON public.attendance FOR UPDATE TO authenticated USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));

CREATE POLICY "Users can read own attendance" ON public.attendance FOR SELECT TO authenticated USING ((user_id = auth.uid()));

CREATE POLICY "Users can read own branch grants" ON public.user_branches FOR SELECT TO authenticated USING ((user_id = auth.uid()));

CREATE POLICY "Users can read own org branches" ON public.branches FOR SELECT TO authenticated USING ((org_id = public.get_user_org_id()));

CREATE POLICY "Users can read own org customer referral credits" ON public.customer_referral_credits FOR SELECT TO authenticated USING ((org_id = public.get_user_org_id()));

CREATE POLICY "Users can read own org customer referral debits" ON public.customer_referral_debits FOR SELECT TO authenticated USING ((org_id = public.get_user_org_id()));

CREATE POLICY "Users can read own org customer referrals" ON public.customer_referrals FOR SELECT TO authenticated USING ((org_id = public.get_user_org_id()));

CREATE POLICY "Users can read own org membership tiers" ON public.membership_tiers FOR SELECT TO authenticated USING ((org_id = public.get_user_org_id()));

CREATE POLICY "Users can read own org reward catalog" ON public.reward_catalog FOR SELECT TO authenticated USING ((org_id = public.get_user_org_id()));

CREATE POLICY "Users can read own org chairs" ON public.chairs FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = chairs.branch_id) AND (b.org_id = public.get_user_org_id())))));

CREATE POLICY "Users can read own org treatments" ON public.treatments FOR SELECT TO authenticated USING ((org_id = public.get_user_org_id()));

CREATE POLICY "Users can read own org dentists" ON public.dentists FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.branches b
  WHERE ((b.id = dentists.branch_id) AND (b.org_id = public.get_user_org_id())))));

CREATE POLICY "Users can read own organization" ON public.organizations FOR SELECT TO authenticated USING ((id = public.get_user_org_id()));

CREATE POLICY "Users can read own profile" ON public.users FOR SELECT TO authenticated USING ((id = auth.uid()));

CREATE POLICY "Users read own notifications" ON public.notifications FOR SELECT TO authenticated USING ((user_id = auth.uid()));

CREATE POLICY "Users update own notifications" ON public.notifications FOR UPDATE TO authenticated USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));

CREATE POLICY anon_insert_bookings ON public.bookings FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY anon_insert_customers ON public.customers FOR INSERT TO anon WITH CHECK (true);

ALTER TABLE public.attendance ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.booking_dentists ENABLE ROW LEVEL SECURITY;

CREATE POLICY booking_dentists_delete ON public.booking_dentists FOR DELETE TO authenticated USING (true);

CREATE POLICY booking_dentists_insert ON public.booking_dentists FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY booking_dentists_select ON public.booking_dentists FOR SELECT TO authenticated USING (true);

CREATE POLICY booking_dentists_update ON public.booking_dentists FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customer reads own account" ON public.customer_accounts FOR SELECT USING ((auth_user_id = auth.uid()));

CREATE POLICY "customer reads own bookings" ON public.bookings FOR SELECT USING ((customer_account_id IN ( SELECT customer_accounts.id
   FROM public.customer_accounts
  WHERE (customer_accounts.auth_user_id = auth.uid()))));

CREATE POLICY "customer reads own membership" ON public.memberships FOR SELECT USING ((customer_id IN ( SELECT customer_accounts.customer_id
   FROM public.customer_accounts
  WHERE ((customer_accounts.auth_user_id = auth.uid()) AND (customer_accounts.customer_id IS NOT NULL)))));

CREATE POLICY "customer reads own membership transactions" ON public.membership_transactions FOR SELECT USING ((membership_id IN ( SELECT m.id
   FROM public.memberships m
  WHERE (m.customer_id IN ( SELECT customer_accounts.customer_id
           FROM public.customer_accounts
          WHERE ((customer_accounts.auth_user_id = auth.uid()) AND (customer_accounts.customer_id IS NOT NULL)))))));

CREATE POLICY "customer reads own org chairs" ON public.chairs FOR SELECT TO authenticated USING (((is_active = true) AND (branch_id IN ( SELECT b.id
   FROM public.branches b
  WHERE (b.org_id IN ( SELECT customer_accounts.org_id
           FROM public.customer_accounts
          WHERE (customer_accounts.auth_user_id = auth.uid())))))));

CREATE POLICY "customer reads own org treatments" ON public.treatments FOR SELECT TO authenticated USING (((is_active = true) AND (org_id IN ( SELECT customer_accounts.org_id
   FROM public.customer_accounts
  WHERE (customer_accounts.auth_user_id = auth.uid())))));

CREATE POLICY "customer reads own org dentists" ON public.dentists FOR SELECT TO authenticated USING (((is_active = true) AND (org_id IN ( SELECT customer_accounts.org_id
   FROM public.customer_accounts
  WHERE (customer_accounts.auth_user_id = auth.uid())))));

CREATE POLICY "customer reads own org voucher types" ON public.voucher_types FOR SELECT USING ((org_id IN ( SELECT customer_accounts.org_id
   FROM public.customer_accounts
  WHERE (customer_accounts.auth_user_id = auth.uid()))));

CREATE POLICY "customer reads own referrals" ON public.customer_referrals FOR SELECT USING (((referring_customer_id IN ( SELECT customer_accounts.customer_id
   FROM public.customer_accounts
  WHERE ((customer_accounts.auth_user_id = auth.uid()) AND (customer_accounts.customer_id IS NOT NULL)))) OR (referred_customer_id IN ( SELECT customer_accounts.customer_id
   FROM public.customer_accounts
  WHERE ((customer_accounts.auth_user_id = auth.uid()) AND (customer_accounts.customer_id IS NOT NULL))))));

CREATE POLICY "customer reads own voucher claims" ON public.voucher_claims FOR SELECT USING ((voucher_id IN ( SELECT v.id
   FROM public.vouchers v
  WHERE (v.customer_id IN ( SELECT customer_accounts.customer_id
           FROM public.customer_accounts
          WHERE ((customer_accounts.auth_user_id = auth.uid()) AND (customer_accounts.customer_id IS NOT NULL)))))));

CREATE POLICY "customer reads own vouchers" ON public.vouchers FOR SELECT USING ((customer_id IN ( SELECT customer_accounts.customer_id
   FROM public.customer_accounts
  WHERE ((customer_accounts.auth_user_id = auth.uid()) AND (customer_accounts.customer_id IS NOT NULL)))));

CREATE POLICY "customer updates own account" ON public.customer_accounts FOR UPDATE USING ((auth_user_id = auth.uid()));

ALTER TABLE public.customer_accounts ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.customer_duplicate_dismissals ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.customer_merge_log ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.customer_referral_credits ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.customer_referral_debits ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.customer_referrals ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.daily_reports ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.membership_tiers ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.membership_transactions ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.org_commission_collections ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.org_commission_rates ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.outreach_ai_config ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.outreach_drafts ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.outreach_messages ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.outreach_provider_config ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.outreach_rules ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.outreach_templates ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.package_redemptions ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.package_types ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.packages ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.payment_refunds ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.payroll_items ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.payroll_runs ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.reward_catalog ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.chairs ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.schema_migrations ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.treatment_categories ENABLE ROW LEVEL SECURITY;

CREATE POLICY treatment_categories_delete ON public.treatment_categories FOR DELETE TO authenticated USING (true);

CREATE POLICY treatment_categories_insert ON public.treatment_categories FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY treatment_categories_select ON public.treatment_categories FOR SELECT TO authenticated USING (true);

CREATE POLICY treatment_categories_update ON public.treatment_categories FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

ALTER TABLE public.treatments ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.staff_compensation ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.dentist_attendance ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.dentists ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.user_branches ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.voucher_claims ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.voucher_code_counters ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.voucher_payments ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.voucher_types ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.vouchers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Staff can read own org treatment notes" ON public.treatment_notes FOR SELECT TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.dentists d
  WHERE ((d.id = treatment_notes.dentist_id) AND (d.org_id = public.get_user_org_id())))) OR (EXISTS ( SELECT 1
   FROM (public.bookings bk
     JOIN public.branches b ON ((b.id = bk.branch_id)))
  WHERE ((bk.id = treatment_notes.booking_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Staff can create own org treatment notes" ON public.treatment_notes FOR INSERT TO authenticated WITH CHECK (((EXISTS ( SELECT 1
   FROM public.dentists d
  WHERE ((d.id = treatment_notes.dentist_id) AND (d.org_id = public.get_user_org_id())))) OR (EXISTS ( SELECT 1
   FROM (public.bookings bk
     JOIN public.branches b ON ((b.id = bk.branch_id)))
  WHERE ((bk.id = treatment_notes.booking_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "Staff can update own org treatment notes" ON public.treatment_notes FOR UPDATE TO authenticated USING (((EXISTS ( SELECT 1
   FROM public.dentists d
  WHERE ((d.id = treatment_notes.dentist_id) AND (d.org_id = public.get_user_org_id())))) OR (EXISTS ( SELECT 1
   FROM (public.bookings bk
     JOIN public.branches b ON ((b.id = bk.branch_id)))
  WHERE ((bk.id = treatment_notes.booking_id) AND (b.org_id = public.get_user_org_id())))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.dentists d
  WHERE ((d.id = treatment_notes.dentist_id) AND (d.org_id = public.get_user_org_id())))) OR (EXISTS ( SELECT 1
   FROM (public.bookings bk
     JOIN public.branches b ON ((b.id = bk.branch_id)))
  WHERE ((bk.id = treatment_notes.booking_id) AND (b.org_id = public.get_user_org_id()))))));

CREATE POLICY "customer reads own treatment notes" ON public.treatment_notes FOR SELECT USING ((customer_id IN ( SELECT customer_accounts.customer_id
   FROM public.customer_accounts
  WHERE ((customer_accounts.auth_user_id = auth.uid()) AND (customer_accounts.customer_id IS NOT NULL)))));

ALTER TABLE public.treatment_notes ENABLE ROW LEVEL SECURITY;
