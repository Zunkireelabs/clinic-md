-- Migration 001: manual_blocks — front-desk "block time off" with optional recurrence
-- (dentist lunch, chair sterilisation, meeting, whole-clinic closure).
--
-- Ported from Zennly migration-212, adapted to ClinicMD naming (dentists / chairs) and to
-- ClinicMD's RLS helpers. Recurrence is expanded at read time (client + the availability RPC in
-- migration-002); manual_block_exceptions records "this occurrence only" cancellations, and a
-- split series row (same series_id, prior row's recurrence_end_date capped) implements
-- "this and following" edits.
--
-- Idempotent: safe to re-run. Reversible (manual):
--   DROP TABLE IF EXISTS public.manual_block_exceptions;
--   DROP TABLE IF EXISTS public.manual_blocks;

CREATE TABLE IF NOT EXISTS public.manual_blocks (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                 uuid NOT NULL REFERENCES public.organizations(id),
  branch_id              uuid NOT NULL REFERENCES public.branches(id),
  dentist_id             uuid REFERENCES public.dentists(id) ON DELETE CASCADE, -- NULL = whole branch
  chair_id               uuid REFERENCES public.chairs(id) ON DELETE CASCADE,   -- optional
  block_date             date NOT NULL,        -- anchor/original date
  start_time             time NOT NULL,
  duration_minutes       integer NOT NULL CHECK (duration_minutes > 0),
  description            text,
  prevent_online_booking boolean NOT NULL DEFAULT true,
  created_by             uuid REFERENCES public.users(id),
  created_at             timestamptz NOT NULL DEFAULT now(),

  recurrence_freq        text CHECK (recurrence_freq IN ('daily','weekly','monthly')), -- NULL = one-off
  recurrence_interval    integer NOT NULL DEFAULT 1 CHECK (recurrence_interval > 0),
  recurrence_end_date    date,
  recurrence_count       integer CHECK (recurrence_count IS NULL OR recurrence_count > 0),

  series_id              uuid,     -- shared across a recurring series' split rows; NULL for one-off
  is_cancelled           boolean NOT NULL DEFAULT false,
  cancelled_at           timestamptz
);

CREATE INDEX IF NOT EXISTS idx_manual_blocks_branch_date ON public.manual_blocks(branch_id, block_date);
CREATE INDEX IF NOT EXISTS idx_manual_blocks_org ON public.manual_blocks(org_id);
CREATE INDEX IF NOT EXISTS idx_manual_blocks_dentist ON public.manual_blocks(dentist_id) WHERE dentist_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_manual_blocks_series ON public.manual_blocks(series_id) WHERE series_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.manual_block_exceptions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id      uuid NOT NULL,
  exception_date date NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE(series_id, exception_date)
);

-- ── Scope check (tenant integrity) ─────────────────────────────────────────────────────
-- A block's org_id, branch and optional dentist/chair must all agree: the branch must belong to the
-- caller's org, and the dentist/chair (if set) must belong to that same branch (dentists and chairs
-- each have a single branch_id in this schema). SECURITY DEFINER so the check doesn't depend on the
-- caller's read access to those tables. Used by every write policy, for every role (admin included).
CREATE OR REPLACE FUNCTION public.manual_block_scope_ok(p_org_id uuid, p_branch_id uuid, p_dentist_id uuid, p_chair_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT p_org_id = public.get_user_org_id()
    AND EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.org_id = p_org_id)
    AND (p_dentist_id IS NULL OR EXISTS (SELECT 1 FROM public.dentists d WHERE d.id = p_dentist_id AND d.branch_id = p_branch_id))
    AND (p_chair_id IS NULL OR EXISTS (SELECT 1 FROM public.chairs c WHERE c.id = p_chair_id AND c.branch_id = p_branch_id));
$$;
REVOKE ALL ON FUNCTION public.manual_block_scope_ok(uuid, uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manual_block_scope_ok(uuid, uuid, uuid, uuid) TO authenticated;

-- ── RLS ─────────────────────────────────────────────────────────────────────────────────
-- Read: same org, and either org-wide role (admin / admin_viewer) or a branch the user belongs to.
-- Write: same org, and admin, or staff/manager of the block's branch (anyone who can create
-- bookings there). The org check is on every policy so another org's rows are never visible
-- or editable even if a branch id leaks.
ALTER TABLE public.manual_blocks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own org blocks" ON public.manual_blocks;
DROP POLICY IF EXISTS "Staff can read branch blocks" ON public.manual_blocks;
CREATE POLICY "Staff can read branch blocks"
  ON public.manual_blocks FOR SELECT
  TO authenticated
  USING (
    org_id = public.get_user_org_id()
    AND EXISTS (SELECT 1 FROM public.branches b WHERE b.id = manual_blocks.branch_id AND b.org_id = manual_blocks.org_id)
    AND (
      public.get_user_role() IN ('admin', 'admin_viewer')
      OR branch_id = ANY (public.get_user_branch_ids())
    )
  );

DROP POLICY IF EXISTS "Managers can write own branch blocks" ON public.manual_blocks;
DROP POLICY IF EXISTS "Staff can write branch blocks" ON public.manual_blocks;
CREATE POLICY "Staff can write branch blocks"
  ON public.manual_blocks FOR ALL
  TO authenticated
  USING (
    public.manual_block_scope_ok(org_id, branch_id, dentist_id, chair_id)
    AND (
      public.get_user_role() = 'admin'
      OR (public.get_user_role() IN ('manager', 'staff') AND branch_id = ANY (public.get_user_branch_ids()))
    )
  )
  WITH CHECK (
    public.manual_block_scope_ok(org_id, branch_id, dentist_id, chair_id)
    AND (
      public.get_user_role() = 'admin'
      OR (public.get_user_role() IN ('manager', 'staff') AND branch_id = ANY (public.get_user_branch_ids()))
    )
  );

ALTER TABLE public.manual_block_exceptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own org block exceptions" ON public.manual_block_exceptions;
CREATE POLICY "Users can read own org block exceptions"
  ON public.manual_block_exceptions FOR SELECT
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.manual_blocks mb
    WHERE mb.series_id = manual_block_exceptions.series_id
      AND mb.org_id = public.get_user_org_id()
      AND (
        public.get_user_role() IN ('admin', 'admin_viewer')
        OR mb.branch_id = ANY (public.get_user_branch_ids())
      )
  ));

DROP POLICY IF EXISTS "Managers can write own branch block exceptions" ON public.manual_block_exceptions;
DROP POLICY IF EXISTS "Staff can write branch block exceptions" ON public.manual_block_exceptions;
CREATE POLICY "Staff can write branch block exceptions"
  ON public.manual_block_exceptions FOR ALL
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.manual_blocks mb
    WHERE mb.series_id = manual_block_exceptions.series_id
      AND public.manual_block_scope_ok(mb.org_id, mb.branch_id, mb.dentist_id, mb.chair_id)
      AND (
        public.get_user_role() = 'admin'
        OR (public.get_user_role() IN ('manager', 'staff') AND mb.branch_id = ANY (public.get_user_branch_ids()))
      )
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.manual_blocks mb
    WHERE mb.series_id = manual_block_exceptions.series_id
      AND public.manual_block_scope_ok(mb.org_id, mb.branch_id, mb.dentist_id, mb.chair_id)
      AND (
        public.get_user_role() = 'admin'
        OR (public.get_user_role() IN ('manager', 'staff') AND mb.branch_id = ANY (public.get_user_branch_ids()))
      )
  ));

-- Table-level grants (RLS above does the row filtering). No access for anon.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.manual_blocks TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.manual_block_exceptions TO authenticated;

INSERT INTO public.schema_migrations (version, name)
VALUES ('001', 'manual-blocks')
ON CONFLICT DO NOTHING;
