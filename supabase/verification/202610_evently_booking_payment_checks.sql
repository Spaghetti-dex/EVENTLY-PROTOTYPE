-- Read-only post-migration checks for the EVENTLY booking payment workflow.
-- Run in the intended Supabase project's SQL editor after applying
-- 20261014120000_evently_booking_payment_verification.sql.

with checks as (
  select
    'payment proof metadata columns'::text as check_name,
    exists (
      select 1 from pg_catalog.pg_attribute
      where attrelid = 'public.payments'::regclass
        and attname = 'demo_mode' and not attisdropped
    ) and exists (
      select 1 from pg_catalog.pg_attribute
      where attrelid = 'public.payments'::regclass
        and attname = 'submitted_at' and not attisdropped
    ) and exists (
      select 1 from pg_catalog.pg_attribute
      where attrelid = 'public.payments'::regclass
        and attname = 'reviewed_by' and not attisdropped
    ) as passed,
    'payments.demo_mode, submitted_at, and reviewed_by exist'::text as detail

  union all

  select
    'private receipt bucket',
    exists (
      select 1 from storage.buckets
      where id = 'payment-proofs'
        and public = false
        and file_size_limit = 10485760
        and allowed_mime_types @> array['image/jpeg', 'image/png', 'image/webp']::text[]
    ),
    'payment-proofs is private and limited to the supported image types and 10 MiB'

  union all

  select
    'customer receipt upload policy',
    exists (
      select 1 from pg_catalog.pg_policies
      where schemaname = 'storage'
        and tablename = 'objects'
        and policyname = 'Customers upload their payment proofs'
        and with_check ilike '%auth.uid()%'
        and with_check ilike '%mimetype%'
    ),
    'uploads are scoped to the caller and image MIME types'

  union all

  select
    'core RPCs exist and are security definer',
    coalesce((
      select count(*) = 4 and bool_and(prosecdef)
      from pg_catalog.pg_proc
      where oid in (
        to_regprocedure('public.create_evently_reservation(jsonb)')::oid,
        to_regprocedure('public.submit_evently_payment(uuid,numeric,text,text,text)')::oid,
        to_regprocedure('public.admin_review_payment(uuid,text,text)')::oid,
        to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)')::oid
      )
    ), false),
    'booking, payment submission, review, and approval RPCs are present and SECURITY DEFINER'

  union all

  select
    'customer RPC privileges',
    coalesce(
      has_function_privilege('authenticated', to_regprocedure('public.create_evently_reservation(jsonb)'), 'EXECUTE')
      and has_function_privilege('authenticated', to_regprocedure('public.submit_evently_payment(uuid,numeric,text,text,text)'), 'EXECUTE')
      and not has_function_privilege('anon', to_regprocedure('public.create_evently_reservation(jsonb)'), 'EXECUTE')
      and not has_function_privilege('anon', to_regprocedure('public.submit_evently_payment(uuid,numeric,text,text,text)'), 'EXECUTE'),
      false
    ),
    'authenticated customers can submit; anonymous callers cannot'

  union all

  select
    'Admin-only review and approval privileges',
    coalesce(
      has_function_privilege('authenticated', to_regprocedure('public.admin_review_payment(uuid,text,text)'), 'EXECUTE')
      and has_function_privilege('authenticated', to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)'), 'EXECUTE')
      and not has_function_privilege('anon', to_regprocedure('public.admin_review_payment(uuid,text,text)'), 'EXECUTE')
      and not has_function_privilege('anon', to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)'), 'EXECUTE'),
      false
    ),
    'authenticated RPC calls are guarded by Owner/Admin checks in their function bodies'

  union all

  select
    'approval requires verified proof and schedule checks',
    coalesce(
      pg_get_functiondef(to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)')) ilike '%payment proof%'
      and pg_get_functiondef(to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)')) ilike '%is_evently_admin%'
      and pg_get_functiondef(to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)')) ilike '%evently_admin_approve_booking_before_payment_verification%',
      false
    ),
    'the wrapper checks verified payment proof, then delegates to the schedule/resource approval workflow'

  union all

  select
    'generic confirmation bypass is blocked',
    coalesce(
      pg_get_functiondef(to_regprocedure('public.admin_transition_reservation(uuid,text,text)')) ilike '%evently_admin_approve_booking%'
      and pg_get_functiondef(to_regprocedure('public.admin_transition_reservation(uuid,text,text)')) ilike '%use evently_admin_approve_booking%',
      false
    ),
    'confirmed/approved transitions must use the guarded approval RPC'

  union all

  select
    'demo payments excluded from financial totals',
    coalesce(
      pg_get_functiondef(to_regprocedure('public.admin_review_payment(uuid,text,text)')) ilike '%demo_mode is not true%',
      false
    ),
    'accepted demo proof does not update amount_paid or collected payment totals'
)
select check_name, passed, detail
from checks
order by check_name;
