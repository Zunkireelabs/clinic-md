-- Migration 002: fold manual_blocks into the customer-facing availability RPC
--
-- Blocks marked prevent_online_booking should reduce online slot availability. The existing
-- public_check_branch_bookings_range() returns one row per occupied chair-slot, so block
-- occurrences are UNIONed in shaped like booking rows:
--   * chair-scoped block        -> that chair
--   * whole-branch block        -> every active chair of the branch
--   * dentist-only block (no chair) is intentionally excluded: the public capacity model is
--     chair + dentist-gender headcount, with no per-dentist concept (same as Zennly).
-- Recurrence is expanded here (daily/weekly via generate_series, monthly via a clamping helper:
-- Jan 31 + 1 month = Feb 28).
--
-- Signature and return columns are IDENTICAL to schema.sql's version, so the online booking
-- flow keeps working; the first SELECT is that function's original body, untouched.
-- Idempotent. Reversible (manual): re-create the original body from schema.sql (~:2113) and
--   DROP FUNCTION IF EXISTS public.manual_block_occurrence_date(date, text, int, int);

CREATE OR REPLACE FUNCTION public.manual_block_occurrence_date(
  p_anchor date, p_freq text, p_interval int, p_n int
) RETURNS date
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_total_months int;
  v_target_year int;
  v_target_month int;
  v_last_day int;
BEGIN
  IF p_n = 0 THEN RETURN p_anchor; END IF;

  IF p_freq = 'daily' THEN
    RETURN p_anchor + (p_interval * p_n);
  ELSIF p_freq = 'weekly' THEN
    RETURN p_anchor + (p_interval * p_n * 7);
  ELSIF p_freq = 'monthly' THEN
    v_total_months := (EXTRACT(MONTH FROM p_anchor)::int - 1) + p_interval * p_n;
    v_target_year := EXTRACT(YEAR FROM p_anchor)::int + (v_total_months / 12);
    v_target_month := (v_total_months % 12);
    IF v_target_month < 0 THEN
      v_target_month := v_target_month + 12;
      v_target_year := v_target_year - 1;
    END IF;
    v_last_day := EXTRACT(DAY FROM (make_date(v_target_year, v_target_month + 1, 1) + interval '1 month' - interval '1 day'))::int;
    RETURN make_date(v_target_year, v_target_month + 1, LEAST(EXTRACT(DAY FROM p_anchor)::int, v_last_day));
  ELSE
    RAISE EXCEPTION 'Unknown recurrence freq: %', p_freq;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.public_check_branch_bookings_range(p_branch_id uuid, p_start_date date, p_end_date date)
RETURNS TABLE(booking_date date, start_time time without time zone, duration_minutes integer, chair_id uuid, dentist_gender text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT
    b.date AS booking_date,
    b.start_time,
    GREATEST(1, (EXTRACT(EPOCH FROM (b.end_time - b.start_time)) / 60)::int) AS duration_minutes,
    b.chair_id,
    t.gender AS dentist_gender
  FROM public.bookings b
  LEFT JOIN public.dentists t ON t.id = b.dentist_id
  WHERE b.branch_id = p_branch_id
    AND b.date BETWEEN p_start_date AND p_end_date
    AND b.status NOT IN ('Cancelled', 'No Show')

  UNION ALL

  -- Chair-scoped blocks (the branch join + org match means a mismatched row can never affect availability)
  SELECT
    occ.occ_date AS booking_date,
    mb.start_time,
    mb.duration_minutes,
    mb.chair_id,
    NULL::text AS dentist_gender
  FROM public.manual_blocks mb
  JOIN public.branches br ON br.id = mb.branch_id AND br.org_id = mb.org_id
  CROSS JOIN LATERAL (
    SELECT public.manual_block_occurrence_date(mb.block_date, mb.recurrence_freq, mb.recurrence_interval, n) AS occ_date
    FROM generate_series(0, CASE WHEN mb.recurrence_freq IS NULL THEN 0 ELSE LEAST(COALESCE(mb.recurrence_count, 500) - 1, 500) END) AS n
  ) occ
  WHERE mb.branch_id = p_branch_id
    AND mb.chair_id IS NOT NULL
    AND mb.prevent_online_booking = true
    AND mb.is_cancelled = false
    AND occ.occ_date BETWEEN p_start_date AND p_end_date
    AND (mb.recurrence_end_date IS NULL OR occ.occ_date <= mb.recurrence_end_date)
    AND NOT EXISTS (
      SELECT 1 FROM public.manual_block_exceptions mbe
      WHERE mbe.series_id = mb.series_id AND mbe.exception_date = occ.occ_date
    )

  UNION ALL

  -- Whole-branch blocks (no chair, no dentist): every active chair is busy
  SELECT
    occ.occ_date AS booking_date,
    mb.start_time,
    mb.duration_minutes,
    c.id AS chair_id,
    NULL::text AS dentist_gender
  FROM public.manual_blocks mb
  JOIN public.branches br ON br.id = mb.branch_id AND br.org_id = mb.org_id
  JOIN public.chairs c ON c.branch_id = mb.branch_id AND c.is_active = true
  CROSS JOIN LATERAL (
    SELECT public.manual_block_occurrence_date(mb.block_date, mb.recurrence_freq, mb.recurrence_interval, n) AS occ_date
    FROM generate_series(0, CASE WHEN mb.recurrence_freq IS NULL THEN 0 ELSE LEAST(COALESCE(mb.recurrence_count, 500) - 1, 500) END) AS n
  ) occ
  WHERE mb.branch_id = p_branch_id
    AND mb.chair_id IS NULL
    AND mb.dentist_id IS NULL
    AND mb.prevent_online_booking = true
    AND mb.is_cancelled = false
    AND occ.occ_date BETWEEN p_start_date AND p_end_date
    AND (mb.recurrence_end_date IS NULL OR occ.occ_date <= mb.recurrence_end_date)
    AND NOT EXISTS (
      SELECT 1 FROM public.manual_block_exceptions mbe
      WHERE mbe.series_id = mb.series_id AND mbe.exception_date = occ.occ_date
    );
$$;

REVOKE ALL ON FUNCTION public.public_check_branch_bookings_range(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.public_check_branch_bookings_range(uuid, date, date) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.manual_block_occurrence_date(date, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manual_block_occurrence_date(date, text, int, int) TO anon, authenticated;

INSERT INTO public.schema_migrations (version, name)
VALUES ('002', 'manual-blocks-public-availability')
ON CONFLICT DO NOTHING;
