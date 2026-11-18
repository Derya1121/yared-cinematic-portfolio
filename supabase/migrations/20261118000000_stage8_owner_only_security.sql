-- Stage 8 security follow-up: enforce owner-only access consistently.
-- This is a migration for the Stage 8 branch; do not apply to production before review.
--
-- The dashboard rejects editor accounts, but several RLS policies and two
-- SECURITY DEFINER RPCs used private.is_admin('editor'). Make the shared helper
-- owner-only so those paths cannot grant an editor more access than the UI.
-- Keep the argument for backwards compatibility with existing policies/RPCs.
create or replace function private.is_admin(min_role text default 'owner')
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.admin_users a
    where a.user_id = (select auth.uid())
      and a.active
      and a.role = 'owner'
      and (
        coalesce(
          (select c.value from private.app_config c where c.key = 'admin_require_mfa'),
          'false'
        ) <> 'true'
        or (select auth.jwt() ->> 'aal') = 'aal2'
      )
  );
$$;

-- app_config is intentionally inaccessible to anon/authenticated via grants.
-- RLS adds defense in depth; the SECURITY DEFINER helper above is owned by
-- postgres (the table owner) and can still read this row for the MFA check.
alter table private.app_config enable row level security;
