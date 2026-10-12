-- Migration 004: staff (dentist) transfer functions — final-state port of Zennly 039/041/145/146/148/149/150/
-- 153/157/160-167, consolidated. All writes to staff_transfers / dentists.branch_id go through here.
--
-- Security (every function): SECURITY DEFINER with a pinned search_path; EXECUTE revoked from PUBLIC and anon;
-- client functions granted to `authenticated` only, and each validates the caller INSIDE the function:
--   * same org for caller, dentist, and branches (a transfer never crosses orgs, grants or not);
--   * admin, or a manager whose branches (get_user_branch_ids() = primary + user_branches grants) include
--     the relevant branch. staff and admin_viewer can never transfer.
-- The two cron functions are revoked from every client role (the cron/postgres role runs them).
-- All times are Asia/Kathmandu wall-clock; "due" compares date + time, not just the date (Zennly 148).
--
-- Idempotent (CREATE OR REPLACE, REVOKE/GRANT). Reversible (manual): DROP the functions listed below.

-- ── helper: may the caller manage this branch? ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._staff_transfer_can_manage(p_branch_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT CASE public.get_user_role()
    WHEN 'admin'   THEN EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.org_id = public.get_user_org_id())
    WHEN 'manager' THEN p_branch_id = ANY (public.get_user_branch_ids())
    ELSE false
  END;
$$;
REVOKE ALL ON FUNCTION public._staff_transfer_can_manage(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._staff_transfer_can_manage(uuid) FROM anon;
REVOKE ALL ON FUNCTION public._staff_transfer_can_manage(uuid) FROM authenticated;

-- ── transfer_dentist ──────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.transfer_dentist(
  p_dentist_id     uuid,
  p_to_branch_id   uuid,
  p_start_time     time DEFAULT NULL,
  p_duration_value integer DEFAULT NULL,
  p_duration_unit  text DEFAULT NULL,
  p_note           text DEFAULT NULL,
  p_effective_date date DEFAULT NULL,
  p_permanent      boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_caller_org         uuid := public.get_user_org_id();
  v_from_branch        uuid;
  v_from_display_order int;
  v_dentist_org        uuid;
  v_dentist_active     boolean;
  v_to_org             uuid;
  v_to_active          boolean;
  v_new_order          int;
  v_transfer_id        uuid;
  v_now                timestamp := now() AT TIME ZONE 'Asia/Kathmandu';
  v_effective          date;
  v_start_ts           timestamp;
  v_revert_at          timestamptz;
  v_immediate          boolean;
BEGIN
  IF auth.uid() IS NULL OR v_caller_org IS NULL THEN
    RAISE EXCEPTION 'transfer_dentist: not authenticated';
  END IF;

  IF NOT p_permanent THEN
    IF p_duration_value IS NULL OR p_duration_value <= 0 THEN
      RAISE EXCEPTION 'transfer_dentist: duration value must be a positive number';
    END IF;
    IF p_duration_unit IS NULL OR p_duration_unit NOT IN ('minute','hour','day','week','month') THEN
      RAISE EXCEPTION 'transfer_dentist: duration unit must be one of minute, hour, day, week, month';
    END IF;
    IF p_start_time IS NULL THEN
      RAISE EXCEPTION 'transfer_dentist: start time is required';
    END IF;
  END IF;

  v_effective := COALESCE(p_effective_date, v_now::date);
  v_start_ts  := (v_effective::text || ' ' || COALESCE(p_start_time, '00:00:00'::time)::text)::timestamp;

  -- Serialise concurrent transfers for one dentist (Zennly 153). Released at transaction end.
  PERFORM pg_advisory_xact_lock(hashtextextended('staff_transfer:' || p_dentist_id::text, 0));

  SELECT branch_id, org_id, display_order, is_active
    INTO v_from_branch, v_dentist_org, v_from_display_order, v_dentist_active
  FROM public.dentists WHERE id = p_dentist_id;

  IF v_from_branch IS NULL THEN
    RAISE EXCEPTION 'transfer_dentist: dentist % not found', p_dentist_id;
  END IF;
  IF v_dentist_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'transfer_dentist: dentist is not in your organization';
  END IF;
  IF v_dentist_active IS NOT TRUE THEN
    RAISE EXCEPTION 'transfer_dentist: dentist is not active';
  END IF;

  SELECT org_id, is_active INTO v_to_org, v_to_active FROM public.branches WHERE id = p_to_branch_id;
  IF v_to_org IS NULL THEN
    RAISE EXCEPTION 'transfer_dentist: destination branch % not found', p_to_branch_id;
  END IF;
  IF v_to_org IS DISTINCT FROM v_caller_org THEN
    RAISE EXCEPTION 'transfer_dentist: destination branch is not in your organization';
  END IF;
  IF v_to_active IS NOT TRUE THEN
    RAISE EXCEPTION 'transfer_dentist: destination branch is not active';
  END IF;
  IF p_to_branch_id = v_from_branch THEN
    RAISE EXCEPTION 'transfer_dentist: dentist is already at that branch';
  END IF;

  -- Origin-branch manager (primary or grant) or admin — Zennly's final rule; no destination consent.
  IF NOT public._staff_transfer_can_manage(v_from_branch) THEN
    RAISE EXCEPTION 'transfer_dentist: only an admin or the current branch''s manager may transfer this dentist';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.staff_transfers
    WHERE dentist_id = p_dentist_id
      AND (applied = false OR (applied = true AND revert_at IS NOT NULL AND reverted = false))
  ) THEN
    RAISE EXCEPTION 'transfer_dentist: a transfer is already pending or in progress for this dentist; cancel or wait for it first';
  END IF;

  v_immediate := v_start_ts <= v_now;
  v_revert_at := CASE WHEN p_permanent THEN NULL
    ELSE (v_start_ts + (p_duration_value || ' ' || p_duration_unit || 's')::interval) AT TIME ZONE 'Asia/Kathmandu'
  END;

  IF v_immediate THEN
    SELECT COALESCE(max(display_order), -1) + 1 INTO v_new_order FROM public.dentists WHERE branch_id = p_to_branch_id;
    UPDATE public.dentists SET branch_id = p_to_branch_id, display_order = v_new_order WHERE id = p_dentist_id;
  END IF;

  BEGIN
    INSERT INTO public.staff_transfers
      (dentist_id, org_id, from_branch_id, to_branch_id, transferred_by, note, effective_date,
       applied, start_time, duration_value, duration_unit, revert_at, from_display_order, is_permanent)
    VALUES
      (p_dentist_id, v_caller_org, v_from_branch, p_to_branch_id, auth.uid(), p_note, v_effective,
       v_immediate, p_start_time, p_duration_value, p_duration_unit, v_revert_at, v_from_display_order, p_permanent)
    RETURNING id INTO v_transfer_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'transfer_dentist: a transfer is already pending or in progress for this dentist; cancel or wait for it first';
  END;

  RETURN v_transfer_id;
END;
$$;

-- ── cancel_scheduled_transfer (pending only; origin manager or admin) ─────────────────────
CREATE OR REPLACE FUNCTION public.cancel_scheduled_transfer(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_rec record;
BEGIN
  SELECT * INTO v_rec FROM public.staff_transfers WHERE id = p_id;
  IF v_rec.id IS NULL THEN RAISE EXCEPTION 'cancel_scheduled_transfer: transfer not found'; END IF;
  IF v_rec.org_id IS DISTINCT FROM public.get_user_org_id() THEN RAISE EXCEPTION 'cancel_scheduled_transfer: not your organization'; END IF;
  IF v_rec.applied THEN RAISE EXCEPTION 'cancel_scheduled_transfer: transfer already applied'; END IF;
  IF NOT public._staff_transfer_can_manage(v_rec.from_branch_id) THEN
    RAISE EXCEPTION 'cancel_scheduled_transfer: insufficient permissions';
  END IF;
  DELETE FROM public.staff_transfers WHERE id = p_id AND applied = false;
  RETURN true;
END;
$$;

-- ── extend_staff_transfer (active temporary; destination manager or admin) ────────────────
CREATE OR REPLACE FUNCTION public.extend_staff_transfer(p_transfer_id uuid, p_additional_value integer, p_additional_unit text)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_rec record;
  v_new_revert_at timestamptz;
BEGIN
  IF p_additional_value IS NULL OR p_additional_value <= 0 THEN
    RAISE EXCEPTION 'extend_staff_transfer: additional duration must be a positive number';
  END IF;
  IF p_additional_unit IS NULL OR p_additional_unit NOT IN ('minute','hour','day','week','month') THEN
    RAISE EXCEPTION 'extend_staff_transfer: duration unit must be one of minute, hour, day, week, month';
  END IF;

  SELECT * INTO v_rec FROM public.staff_transfers WHERE id = p_transfer_id;
  IF v_rec.id IS NULL THEN RAISE EXCEPTION 'extend_staff_transfer: transfer not found'; END IF;
  IF v_rec.org_id IS DISTINCT FROM public.get_user_org_id() THEN RAISE EXCEPTION 'extend_staff_transfer: not your organization'; END IF;
  IF v_rec.revert_at IS NULL THEN RAISE EXCEPTION 'extend_staff_transfer: this transfer has no scheduled return time'; END IF;
  IF NOT public._staff_transfer_can_manage(v_rec.to_branch_id) THEN
    RAISE EXCEPTION 'extend_staff_transfer: only an admin or the destination branch''s manager may extend this transfer';
  END IF;

  UPDATE public.staff_transfers
     SET revert_at = v_rec.revert_at + (p_additional_value || ' ' || p_additional_unit || 's')::interval,
         note = trim(both ' ' from COALESCE(v_rec.note || ' ', '') ||
           format('[+%s %s%s added %s]', p_additional_value, p_additional_unit,
                  CASE WHEN p_additional_value = 1 THEN '' ELSE 's' END,
                  to_char(now() AT TIME ZONE 'Asia/Kathmandu', 'DD Mon HH24:MI')))
   WHERE id = p_transfer_id AND applied = true AND reverted = false AND revert_at > now()
  RETURNING revert_at INTO v_new_revert_at;

  IF v_new_revert_at IS NULL THEN
    RAISE EXCEPTION 'extend_staff_transfer: this transfer has already ended; start a new transfer instead';
  END IF;
  RETURN v_new_revert_at;
END;
$$;

-- ── revert_staff_transfer_now (either branch's manager or admin; booking guard) ───────────
CREATE OR REPLACE FUNCTION public.revert_staff_transfer_now(p_transfer_id uuid, p_reverted_at timestamptz DEFAULT NULL)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_rec            record;
  v_current_branch uuid;
  v_new_order      int;
  v_now            timestamptz := COALESCE(p_reverted_at, now());
  v_updated        int;
  v_conflicts      int;
  v_last_end       timestamptz;
BEGIN
  SELECT * INTO v_rec FROM public.staff_transfers WHERE id = p_transfer_id;
  IF v_rec.id IS NULL THEN RAISE EXCEPTION 'revert_staff_transfer_now: transfer not found'; END IF;
  IF v_rec.org_id IS DISTINCT FROM public.get_user_org_id() THEN RAISE EXCEPTION 'revert_staff_transfer_now: not your organization'; END IF;
  IF v_rec.revert_at IS NULL THEN RAISE EXCEPTION 'revert_staff_transfer_now: this transfer has no scheduled return time'; END IF;
  IF NOT (v_rec.applied = true AND v_rec.reverted = false) THEN RAISE EXCEPTION 'revert_staff_transfer_now: this transfer has already ended'; END IF;

  IF p_reverted_at IS NOT NULL THEN
    IF p_reverted_at > now() THEN RAISE EXCEPTION 'revert_staff_transfer_now: return time cannot be in the future'; END IF;
    IF p_reverted_at < v_rec.transferred_at THEN RAISE EXCEPTION 'revert_staff_transfer_now: return time cannot be before the transfer started'; END IF;
    IF p_reverted_at >= v_rec.revert_at THEN RAISE EXCEPTION 'revert_staff_transfer_now: return time must be before the scheduled return'; END IF;
  END IF;

  IF NOT (public._staff_transfer_can_manage(v_rec.to_branch_id) OR public._staff_transfer_can_manage(v_rec.from_branch_id)) THEN
    RAISE EXCEPTION 'revert_staff_transfer_now: only an admin, the destination branch''s manager, or the origin branch''s manager may end this transfer';
  END IF;

  SELECT branch_id INTO v_current_branch FROM public.dentists WHERE id = v_rec.dentist_id;
  IF v_current_branch IS NULL THEN RAISE EXCEPTION 'revert_staff_transfer_now: dentist no longer exists'; END IF;
  IF v_current_branch IS DISTINCT FROM v_rec.to_branch_id THEN
    RAISE EXCEPTION 'revert_staff_transfer_now: dentist is no longer at the destination branch for this transfer';
  END IF;

  -- Booking guard (Zennly 162/164): any non-terminal booking (Pending included) at the destination that
  -- ends after the return moment blocks the return; report the LAST end time and the count.
  SELECT count(*), max(b.end_datetime) INTO v_conflicts, v_last_end
  FROM public.bookings b
  WHERE (b.dentist_id = v_rec.dentist_id
         OR EXISTS (SELECT 1 FROM public.booking_dentists bd WHERE bd.booking_id = b.id AND bd.dentist_id = v_rec.dentist_id))
    AND b.branch_id = v_rec.to_branch_id
    AND b.status NOT IN ('Completed', 'Cancelled', 'No Show')
    AND b.end_datetime > v_now;
  IF v_conflicts > 0 THEN
    RAISE EXCEPTION 'revert_staff_transfer_now: still booked at this branch until % (% booking%) — wait until their last scheduled booking finishes, then mark them returned (you can enter that exact time)',
      to_char(v_last_end AT TIME ZONE 'Asia/Kathmandu', 'DD Mon HH24:MI'), v_conflicts, CASE WHEN v_conflicts = 1 THEN '' ELSE 's' END;
  END IF;

  IF v_rec.from_display_order IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.dentists WHERE branch_id = v_rec.from_branch_id AND display_order = v_rec.from_display_order AND id <> v_rec.dentist_id
  ) THEN
    v_new_order := v_rec.from_display_order;
  ELSE
    SELECT COALESCE(max(display_order), -1) + 1 INTO v_new_order FROM public.dentists WHERE branch_id = v_rec.from_branch_id;
  END IF;

  UPDATE public.dentists SET branch_id = v_rec.from_branch_id, display_order = v_new_order WHERE id = v_rec.dentist_id;

  INSERT INTO public.staff_transfers
    (dentist_id, org_id, from_branch_id, to_branch_id, transferred_by, note, effective_date, applied, start_time, is_return_leg)
  VALUES
    (v_rec.dentist_id, v_rec.org_id, v_rec.to_branch_id, v_rec.from_branch_id, auth.uid(),
     'Returned early (marked by manager)', (v_now AT TIME ZONE 'Asia/Kathmandu')::date, true,
     (v_now AT TIME ZONE 'Asia/Kathmandu')::time, true);

  UPDATE public.staff_transfers SET reverted = true, reverted_at = v_now
   WHERE id = p_transfer_id AND applied = true AND reverted = false;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN RAISE EXCEPTION 'revert_staff_transfer_now: this transfer has already ended'; END IF;

  RETURN v_now;
END;
$$;

-- ── reschedule_staff_transfer_return (either branch's manager or admin; strictly future) ──
CREATE OR REPLACE FUNCTION public.reschedule_staff_transfer_return(p_transfer_id uuid, p_new_revert_at timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_rec record;
  v_updated int;
BEGIN
  IF p_new_revert_at IS NULL THEN RAISE EXCEPTION 'reschedule_staff_transfer_return: a new return time is required'; END IF;
  SELECT * INTO v_rec FROM public.staff_transfers WHERE id = p_transfer_id;
  IF v_rec.id IS NULL THEN RAISE EXCEPTION 'reschedule_staff_transfer_return: transfer not found'; END IF;
  IF v_rec.org_id IS DISTINCT FROM public.get_user_org_id() THEN RAISE EXCEPTION 'reschedule_staff_transfer_return: not your organization'; END IF;
  IF v_rec.revert_at IS NULL THEN
    RAISE EXCEPTION 'reschedule_staff_transfer_return: this transfer has no scheduled return time (permanent transfers can''t be rescheduled — start a new transfer instead)';
  END IF;
  IF NOT (v_rec.applied = true AND v_rec.reverted = false) THEN RAISE EXCEPTION 'reschedule_staff_transfer_return: this transfer has already ended'; END IF;
  IF NOT (public._staff_transfer_can_manage(v_rec.to_branch_id) OR public._staff_transfer_can_manage(v_rec.from_branch_id)) THEN
    RAISE EXCEPTION 'reschedule_staff_transfer_return: only an admin, the destination branch''s manager, or the origin branch''s manager may reschedule this transfer''s return';
  END IF;
  IF p_new_revert_at <= now() THEN
    RAISE EXCEPTION 'reschedule_staff_transfer_return: new return time must be in the future — for a return that already happened, use "Mark Returned Early" instead';
  END IF;

  UPDATE public.staff_transfers SET revert_at = p_new_revert_at
   WHERE id = p_transfer_id AND applied = true AND reverted = false;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN RAISE EXCEPTION 'reschedule_staff_transfer_return: this transfer has already ended'; END IF;
  RETURN p_new_revert_at;
END;
$$;

-- ── cron: apply due transfers (date + start_time in Kathmandu; Zennly 148) ───────────────
CREATE OR REPLACE FUNCTION public.apply_due_staff_transfers()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_now            timestamp := now() AT TIME ZONE 'Asia/Kathmandu';
  v_rec            record;
  v_new_order      int;
  v_current_branch uuid;
  v_current_org    uuid;
  v_to_org         uuid;
  v_count          int := 0;
BEGIN
  FOR v_rec IN
    SELECT * FROM public.staff_transfers
    WHERE applied = false
      AND (effective_date::text || ' ' || COALESCE(start_time, '00:00:00'::time)::text)::timestamp <= v_now
    ORDER BY effective_date, start_time, transferred_at
  LOOP
    SELECT branch_id, org_id INTO v_current_branch, v_current_org FROM public.dentists WHERE id = v_rec.dentist_id;
    SELECT org_id INTO v_to_org FROM public.branches WHERE id = v_rec.to_branch_id;

    -- Dentist gone, or (defensively) org mismatch: never move across orgs; just resolve the row.
    IF v_current_branch IS NULL OR v_current_org IS DISTINCT FROM v_rec.org_id OR v_to_org IS DISTINCT FROM v_rec.org_id THEN
      UPDATE public.staff_transfers SET applied = true, reverted = true, reverted_at = now() WHERE id = v_rec.id;
      CONTINUE;
    END IF;

    IF v_current_branch IS DISTINCT FROM v_rec.to_branch_id THEN
      SELECT COALESCE(max(display_order), -1) + 1 INTO v_new_order FROM public.dentists WHERE branch_id = v_rec.to_branch_id;
      UPDATE public.dentists SET branch_id = v_rec.to_branch_id, display_order = v_new_order WHERE id = v_rec.dentist_id;
    END IF;

    UPDATE public.staff_transfers SET applied = true WHERE id = v_rec.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;

-- ── cron: auto-revert transfers whose revert_at has passed (booking-guarded; Zennly 149/167) ──
CREATE OR REPLACE FUNCTION public.apply_due_staff_reverts()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_now            timestamptz := now();
  v_rec            record;
  v_new_order      int;
  v_current_branch uuid;
  v_count          int := 0;
  v_conflicts      int;
BEGIN
  FOR v_rec IN
    SELECT * FROM public.staff_transfers
    WHERE revert_at IS NOT NULL AND applied = true AND reverted = false AND revert_at <= v_now
    ORDER BY revert_at
  LOOP
    SELECT branch_id INTO v_current_branch FROM public.dentists WHERE id = v_rec.dentist_id;

    IF v_current_branch IS NULL THEN
      UPDATE public.staff_transfers SET reverted = true, reverted_at = v_now WHERE id = v_rec.id;
      CONTINUE;
    END IF;

    IF v_current_branch = v_rec.to_branch_id THEN
      -- Don't pull them off a live booking: defer (leave the row) and retry on the next tick.
      SELECT count(*) INTO v_conflicts
      FROM public.bookings b
      WHERE (b.dentist_id = v_rec.dentist_id
             OR EXISTS (SELECT 1 FROM public.booking_dentists bd WHERE bd.booking_id = b.id AND bd.dentist_id = v_rec.dentist_id))
        AND b.branch_id = v_rec.to_branch_id
        AND b.status NOT IN ('Completed', 'Cancelled', 'No Show')
        AND b.end_datetime > v_now;
      IF v_conflicts > 0 THEN
        RAISE NOTICE 'apply_due_staff_reverts: dentist % still has % non-terminal booking(s) at % (transfer %); deferring auto-revert',
          v_rec.dentist_id, v_conflicts, v_rec.to_branch_id, v_rec.id;
        CONTINUE;
      END IF;

      IF v_rec.from_display_order IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.dentists WHERE branch_id = v_rec.from_branch_id AND display_order = v_rec.from_display_order AND id <> v_rec.dentist_id
      ) THEN
        v_new_order := v_rec.from_display_order;
      ELSE
        SELECT COALESCE(max(display_order), -1) + 1 INTO v_new_order FROM public.dentists WHERE branch_id = v_rec.from_branch_id;
      END IF;

      UPDATE public.dentists SET branch_id = v_rec.from_branch_id, display_order = v_new_order WHERE id = v_rec.dentist_id;

      INSERT INTO public.staff_transfers
        (dentist_id, org_id, from_branch_id, to_branch_id, transferred_by, note, effective_date, applied, start_time, is_return_leg)
      VALUES
        (v_rec.dentist_id, v_rec.org_id, v_rec.to_branch_id, v_rec.from_branch_id, NULL,
         'Auto-reverted after scheduled duration', (v_now AT TIME ZONE 'Asia/Kathmandu')::date, true,
         (v_now AT TIME ZONE 'Asia/Kathmandu')::time, true);
    ELSE
      RAISE NOTICE 'apply_due_staff_reverts: dentist % no longer at % (transfer %); marking resolved', v_rec.dentist_id, v_rec.to_branch_id, v_rec.id;
    END IF;

    UPDATE public.staff_transfers SET reverted = true, reverted_at = v_now WHERE id = v_rec.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;

-- ── cron: in-app reminder for bookings left behind at the origin (Zennly 040) ─────────────
-- IN-APP ONLY: inserts rows into public.notifications. No email/SMS/WhatsApp, no pg_net/http.
-- Recipients: users whose primary branch_id is the booking's (origin) branch; once per user per booking.
CREATE OR REPLACE FUNCTION public.notify_left_behind_bookings()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_target_date date := ((now() AT TIME ZONE 'Asia/Kathmandu')::date + 1);
  v_count int := 0;
BEGIN
  WITH left_behind AS (
    SELECT DISTINCT b.id AS booking_id, b.branch_id, b.booking_number, d.name AS staff_name
    FROM public.bookings b
    JOIN LATERAL (
      SELECT b.dentist_id AS dentist_id WHERE b.dentist_id IS NOT NULL
      UNION
      SELECT bd.dentist_id FROM public.booking_dentists bd WHERE bd.booking_id = b.id
    ) a ON true
    JOIN public.dentists d ON d.id = a.dentist_id
    WHERE b.date = v_target_date
      AND b.status NOT IN ('Cancelled', 'Completed', 'No Show')
      AND d.branch_id <> b.branch_id
      AND EXISTS (SELECT 1 FROM public.staff_transfers st WHERE st.dentist_id = d.id AND st.from_branch_id = b.branch_id)
  ),
  recipients AS (
    SELECT lb.booking_id, lb.booking_number, lb.staff_name, u.id AS user_id
    FROM left_behind lb
    JOIN public.users u ON u.branch_id = lb.branch_id AND u.is_active IS NOT FALSE
  )
  INSERT INTO public.notifications (user_id, type, title, body, booking_id)
  SELECT r.user_id, 'transferred_staff_reminder', 'Transferred staff booking tomorrow',
         r.staff_name || ' has transferred to another branch but is still assigned to booking '
           || r.booking_number || ' here tomorrow. Please reassign or follow up.',
         r.booking_id
  FROM recipients r
  WHERE NOT EXISTS (
    SELECT 1 FROM public.notifications n
    WHERE n.user_id = r.user_id AND n.booking_id = r.booking_id AND n.type = 'transferred_staff_reminder'
  );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- ── privileges ────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.transfer_dentist(uuid, uuid, time, integer, text, text, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transfer_dentist(uuid, uuid, time, integer, text, text, date, boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.cancel_scheduled_transfer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_scheduled_transfer(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.extend_staff_transfer(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.extend_staff_transfer(uuid, integer, text) TO authenticated;
REVOKE ALL ON FUNCTION public.revert_staff_transfer_now(uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revert_staff_transfer_now(uuid, timestamptz) TO authenticated;
REVOKE ALL ON FUNCTION public.reschedule_staff_transfer_return(uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reschedule_staff_transfer_return(uuid, timestamptz) TO authenticated;
-- Cron-only: no client role may call these.
REVOKE ALL ON FUNCTION public.apply_due_staff_transfers() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_due_staff_reverts() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.notify_left_behind_bookings() FROM PUBLIC, anon, authenticated;

INSERT INTO public.schema_migrations (version, name)
VALUES ('004', 'staff-transfer-functions')
ON CONFLICT DO NOTHING;
