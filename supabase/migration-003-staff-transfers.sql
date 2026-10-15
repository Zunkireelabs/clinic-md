-- Migration 003: staff (dentist) transfers between branches — table, indexes, RLS
--
-- Final-state port of Zennly's transfer model (migrations 038/041/145/149/150/153/163), consolidated.
-- dentists.branch_id remains the dentist's single CURRENT branch; a transfer moves it (migration-004
-- functions). This table is the audit + schedule record, one row per leg.
--
-- Writes happen ONLY through the SECURITY DEFINER functions in migration-004 — there is deliberately
-- no client INSERT/UPDATE/DELETE policy, so the audit trail cannot be forged.
--
-- Idempotent. Reversible (manual):
--   DROP TABLE IF EXISTS public.staff_transfers;
--   -- and re-create manual_block_scope_ok from migration-001.

CREATE TABLE IF NOT EXISTS public.staff_transfers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dentist_id         uuid NOT NULL REFERENCES public.dentists(id) ON DELETE CASCADE,
  org_id             uuid NOT NULL REFERENCES public.organizations(id),
  from_branch_id     uuid NOT NULL REFERENCES public.branches(id),
  to_branch_id       uuid NOT NULL REFERENCES public.branches(id),
  transferred_by     uuid REFERENCES public.users(id),
  transferred_at     timestamptz NOT NULL DEFAULT now(),
  note               text,
  -- When the move takes effect (Asia/Kathmandu wall clock) and whether it has happened yet.
  effective_date     date    NOT NULL DEFAULT CURRENT_DATE,
  start_time         time,
  applied            boolean NOT NULL DEFAULT true,
  -- Temporary transfers: duration + computed return instant. Permanent: all NULL.
  duration_value     integer CHECK (duration_value IS NULL OR duration_value > 0),
  duration_unit      text    CHECK (duration_unit IN ('minute','hour','day','week','month')),
  revert_at          timestamptz,
  reverted           boolean NOT NULL DEFAULT false,
  reverted_at        timestamptz,
  is_permanent       boolean NOT NULL DEFAULT false,
  -- Origin column position captured before the move overwrites dentists.display_order.
  from_display_order integer,
  -- Synthesised destination -> origin row that records a return (auto or early).
  is_return_leg      boolean NOT NULL DEFAULT false,
  CONSTRAINT staff_transfers_distinct_branches CHECK (from_branch_id <> to_branch_id)
);

CREATE INDEX IF NOT EXISTS idx_staff_transfers_dentist ON public.staff_transfers(dentist_id);
CREATE INDEX IF NOT EXISTS idx_staff_transfers_org ON public.staff_transfers(org_id);
CREATE INDEX IF NOT EXISTS idx_staff_transfers_from_branch ON public.staff_transfers(from_branch_id);
CREATE INDEX IF NOT EXISTS idx_staff_transfers_to_branch ON public.staff_transfers(to_branch_id);
-- Cheap scans for the cron jobs.
CREATE INDEX IF NOT EXISTS idx_staff_transfers_pending
  ON public.staff_transfers (effective_date) WHERE applied = false;
CREATE INDEX IF NOT EXISTS idx_staff_transfers_pending_revert
  ON public.staff_transfers (revert_at) WHERE revert_at IS NOT NULL AND applied = true AND reverted = false;
-- At most one pending-or-in-progress transfer per dentist, enforced by the database
-- (defence in depth behind the advisory lock in transfer_dentist; Zennly 153).
CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_transfers_one_active_per_dentist
  ON public.staff_transfers (dentist_id)
  WHERE applied = false OR (applied = true AND revert_at IS NOT NULL AND reverted = false);

-- ── RLS: read-only for org members; no client writes ───────────────────────────────────
ALTER TABLE public.staff_transfers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own org transfers" ON public.staff_transfers;
DROP POLICY IF EXISTS "Staff can read own org transfers" ON public.staff_transfers;
CREATE POLICY "Staff can read own org transfers"
  ON public.staff_transfers FOR SELECT
  TO authenticated
  USING (org_id = public.get_user_org_id());

REVOKE ALL ON public.staff_transfers FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.staff_transfers FROM authenticated;
GRANT SELECT ON public.staff_transfers TO authenticated;

-- ── Blocks interaction (3b) ────────────────────────────────────────────────────────────
-- manual_block_scope_ok required dentist.branch_id = the block's branch, which would make an
-- origin-branch block for a transferred dentist impossible to edit or cancel. A dentist may now be
-- scoped by a block at a branch they belong to NOW or have a transfer record with (from/to), always
-- within the same org. Existing blocks are never moved or deleted by a transfer.
CREATE OR REPLACE FUNCTION public.manual_block_scope_ok(p_org_id uuid, p_branch_id uuid, p_dentist_id uuid, p_chair_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT p_org_id = public.get_user_org_id()
    AND EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.org_id = p_org_id)
    AND (
      p_dentist_id IS NULL
      OR EXISTS (
        SELECT 1 FROM public.dentists d
        WHERE d.id = p_dentist_id AND d.org_id = p_org_id
          AND (
            d.branch_id = p_branch_id
            OR EXISTS (
              SELECT 1 FROM public.staff_transfers t
              WHERE t.dentist_id = d.id AND t.org_id = p_org_id
                AND (t.from_branch_id = p_branch_id OR t.to_branch_id = p_branch_id)
            )
          )
      )
    )
    AND (p_chair_id IS NULL OR EXISTS (SELECT 1 FROM public.chairs c WHERE c.id = p_chair_id AND c.branch_id = p_branch_id));
$$;
REVOKE ALL ON FUNCTION public.manual_block_scope_ok(uuid, uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manual_block_scope_ok(uuid, uuid, uuid, uuid) TO authenticated;

INSERT INTO public.schema_migrations (version, name)
VALUES ('003', 'staff-transfers')
ON CONFLICT DO NOTHING;
