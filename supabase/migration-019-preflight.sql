-- migration-019-preflight.sql (CMD-100): READ-ONLY. Run before applying 019 (psql -f). It changes nothing.
-- Print each section and read it. 019 is applied to production only when sections 1 and 2 are clear (or accepted by Sadin).
\echo '== 1. users with role STAFF who wrote clinical content (019 locks front desk out of consultations, notes and consultation files) =='
\echo 'Move each of these to practitioner (Settings > access level, migration 011) BEFORE applying 019, or they lose their own notes.'
SELECT u.id, u.email, u.full_name, u.role, u.branch_id,
       (SELECT count(*) FROM public.consultations c WHERE c.created_by = u.id) AS consultations_created,
       (SELECT count(*) FROM public.consultations c WHERE u.full_name = ANY (c.attended_by_names)) AS consultations_attended,
       (SELECT count(*) FROM public.treatment_notes n WHERE u.dentist_id IS NOT NULL AND n.dentist_id = u.dentist_id) AS notes_written
  FROM public.users u
 WHERE u.role::text = 'staff'
   AND (EXISTS (SELECT 1 FROM public.consultations c WHERE c.created_by = u.id OR u.full_name = ANY (c.attended_by_names))
        OR EXISTS (SELECT 1 FROM public.treatment_notes n WHERE u.dentist_id IS NOT NULL AND n.dentist_id = u.dentist_id))
 ORDER BY u.full_name;

\echo '== 2. staff users with a dentist profile (they probably practise: check them too) =='
SELECT u.id, u.email, u.full_name, u.dentist_id FROM public.users u WHERE u.role::text = 'staff' AND u.dentist_id IS NOT NULL AND u.is_active IS NOT FALSE ORDER BY u.full_name;

\echo '== 3. patients per organization (these get P-numbers in created_at order) =='
SELECT org_id, count(*) AS patients, min(created_at) AS first_created, max(created_at) AS last_created, count(*) FILTER (WHERE created_at IS NULL) AS no_created_at FROM public.customers GROUP BY org_id ORDER BY org_id;

\echo '== 4. phone numbers that would be shared (must be none today: the old index forbids it; this is the rollback check) =='
SELECT org_id, NULLIF(regexp_replace(COALESCE(phone, ''), '\D', '', 'g'), '') AS digits, count(*) FROM public.customers
 WHERE NULLIF(regexp_replace(COALESCE(phone, ''), '\D', '', 'g'), '') IS NOT NULL GROUP BY 1, 2 HAVING count(*) > 1;

\echo '== 5. prerequisites: each must say true =='
SELECT 'migration-011 (practitioner)' AS needs, to_regprocedure('public.get_user_dentist_id()') IS NOT NULL AS present
UNION ALL SELECT 'migration-013 (hub)', to_regprocedure('public.act_consent_record(uuid, text, text, text, text, text, jsonb)') IS NOT NULL
UNION ALL SELECT 'migration-017 (follow-up agent)', to_regclass('public.agent_jobs') IS NOT NULL
UNION ALL SELECT 'consultation buckets', (SELECT count(*) = 2 FROM storage.buckets WHERE id IN ('consultation-audio', 'consultation-images'));
