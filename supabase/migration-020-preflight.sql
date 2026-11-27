-- migration-020-preflight (CMD-54): READ-ONLY. Run by a human on production BEFORE migration-020 and the matching edge-function deploy.
--
-- 020 and the new edge functions refuse role 'staff' (front desk) for consultation work: recording consent, signing, transcribing, drafting and
-- image analysis. A dentist who logs in with role 'staff' would lose the Scribe. Every user listed here must be moved to 'practitioner'
-- (and linked to their dentist profile) before 020 reaches production, or confirmed by Sadin as front desk who should lose access.
-- All time, not a window (same rule as CMD-100's preflight). Writes nothing.

SELECT u.id, u.full_name, u.email, u.role::text AS role, u.dentist_id IS NOT NULL AS linked_to_dentist, o.name AS organization,
       count(DISTINCT c.id) FILTER (WHERE c.created_by = u.id)                 AS consultations_created,
       count(DISTINCT c.id) FILTER (WHERE u.full_name = ANY (c.attended_by_names)) AS consultations_attended,
       max(c.created_at)                                                        AS last_consultation_at
  FROM public.users u
  JOIN public.organizations o ON o.id = u.org_id
  JOIN public.consultations c ON c.org_id = u.org_id AND (c.created_by = u.id OR u.full_name = ANY (c.attended_by_names))
 WHERE u.role::text = 'staff'
 GROUP BY u.id, u.full_name, u.email, u.role, u.dentist_id, o.name
 ORDER BY last_consultation_at DESC;

-- Expected before 020 goes to production: zero rows (or each remaining row signed off by Sadin).
