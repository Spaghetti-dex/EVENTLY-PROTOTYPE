-- READ-ONLY verification for the Phase 1 additive foundation candidate.
-- Compare row counts with EVENTLY_SAFE_ROLLOUT_PREFLIGHT.sql. This performs no writes.
do $$
declare
  v_missing integer;
begin
  select count(*) into v_missing
  from (values
    ('reservations','payment_due_at','timestamptz'),
    ('reservations','expired_at','timestamptz')
  ) required(table_name,column_name,expected_udt)
  where not exists(select 1 from information_schema.columns column_info
    where column_info.table_schema='public'
      and column_info.table_name=required.table_name
      and column_info.column_name=required.column_name
      and column_info.udt_name=required.expected_udt
      and column_info.is_nullable='YES');
  if v_missing<>0 then raise exception 'FAIL: Phase 1 deadline/expiration columns are missing, mistyped, or not nullable'; end if;

  if to_regclass('public.evently_reservation_override_audit') is null
     or not exists(select 1 from pg_catalog.pg_class relation
       where relation.oid='public.evently_reservation_override_audit'::regclass
         and relation.relrowsecurity) then
    raise exception 'FAIL: private override audit table or RLS is missing';
  end if;
  if not exists(select 1 from pg_catalog.pg_policies policy
    where policy.schemaname='public'
      and policy.tablename='evently_reservation_override_audit'
      and policy.policyname='Administrators read reservation override audit'
      and policy.cmd='SELECT'
      and position('is_evently_admin' in lower(policy.qual))>0) then
    raise exception 'FAIL: Admin-only override-audit read policy is missing';
  end if;
  if has_table_privilege('anon','public.evently_reservation_override_audit','INSERT')
     or has_table_privilege('anon','public.evently_reservation_override_audit','UPDATE')
     or has_table_privilege('anon','public.evently_reservation_override_audit','DELETE')
     or has_table_privilege('authenticated','public.evently_reservation_override_audit','INSERT')
     or has_table_privilege('authenticated','public.evently_reservation_override_audit','UPDATE')
     or has_table_privilege('authenticated','public.evently_reservation_override_audit','DELETE') then
    raise exception 'FAIL: browser roles can write the private override audit directly';
  end if;
end;
$$;

-- Report, but do not assert zero: pre-existing deployments may already contain
-- deadline metadata that Phase 1 must leave untouched.
select count(*) as reservation_count,
       count(*) filter(where payment_due_at is not null) as rows_with_deadline,
       count(*) filter(where expired_at is not null) as expired_rows
from public.reservations;

select count(*) as payment_count from public.payments;
select count(*) as override_audit_rows from public.evently_reservation_override_audit;
