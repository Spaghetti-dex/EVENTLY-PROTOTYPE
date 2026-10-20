-- Staging-only acceptance checks for 20261020120000_evently_pool_capacity_workflow.
-- Run after migration and after a real Administrator has inspected the pool
-- and verified each tour through the Admin UI/RPC. Read-only: no booking or
-- capacity records are written by this script.
do $$
declare v_error text;
begin
  if to_regprocedure('public.evently_pool_capacity_ready(uuid)') is null
     or to_regprocedure('public.evently_pool_tour_total(uuid,integer,uuid)') is null
     or to_regprocedure('public.evently_pool_capacity_available(date,time,time,integer,uuid)') is null
     or to_regprocedure('public.evently_admin_set_pool_capacity(uuid,boolean,integer,text)') is null then
    raise exception 'FAIL: required pool capacity RPCs are missing';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='packages' and column_name='max_guest_count' and data_type='integer') then
    raise exception 'FAIL: packages.max_guest_count integer column is missing';
  end if;
  if has_function_privilege('anon','public.create_evently_reservation(jsonb)','execute')
     or not has_function_privilege('authenticated','public.create_evently_reservation(jsonb)','execute')
     or has_function_privilege('anon','public.evently_admin_set_pool_capacity(uuid,boolean,integer,text)','execute')
     or not has_function_privilege('authenticated','public.evently_admin_set_pool_capacity(uuid,boolean,integer,text)','execute') then
    raise exception 'FAIL: customer booking/Admin verification RPC grants are too broad or missing';
  end if;
  if exists(select 1 from public.evently_pool_capacity_audit
      where verification_source='prototype_operator_attestation'
        and verified_by='00000000-0000-0000-0000-000000000001') then
    raise notice 'PASS: prototype audit history is preserved but must not be used as capacity proof';
  end if;
  if exists(select 1 from public.packages p join public.evently_pool_capacity_audit a
      on a.id=p.pool_capacity_audit_id
      where p.id in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
        '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
        and p.pool_capacity_verified
        and (a.verification_source<>'authenticated_admin_rpc'
          or a.package_id<>p.id or a.approved_capacity<>p.max_guest_count)) then
    raise exception 'FAIL: a pool package is verified without matching authenticated Administrator audit';
  end if;
  if (select count(*) from public.packages where
        (id='4ae972a8-6503-4776-90c9-899246cbc4dc' and price=100 and min_guest_count=20
         and max_guest_count=50 and public.evently_pool_capacity_ready(id))
        or (id='5afda244-a615-4bd3-98eb-d360d000100b' and price=150 and min_guest_count=20
         and max_guest_count=50 and public.evently_pool_capacity_ready(id))
       or (id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8' and price=200 and min_guest_count=20
         and max_guest_count=50 and public.evently_pool_capacity_ready(id))) <> 3 then
    raise exception 'FAIL: perform genuine physical verification for each of the three tours before booking acceptance';
  end if;
  if public.evently_pool_tour_total('4ae972a8-6503-4776-90c9-899246cbc4dc',20,null)<>2000
     or public.evently_pool_tour_total('4ae972a8-6503-4776-90c9-899246cbc4dc',50,null)<>5000
     or public.evently_pool_tour_total('5afda244-a615-4bd3-98eb-d360d000100b',50,null)<>7500
     or public.evently_pool_tour_total('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,null)<>4000
     or public.evently_pool_tour_total('4ae972a8-6503-4776-90c9-899246cbc4dc',20,'1e97b2bf-ca43-492a-8a15-2d20f6abf040')<>2700
     or public.evently_pool_tour_total('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,'928c269f-c38a-4345-86a5-d1f4c65555f0')<>5000 then
    raise exception 'FAIL: pool tour price or cottage total differs';
  end if;
  v_error:=null;
  begin
    perform public.evently_pool_tour_total('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',19,null);
  exception when raise_exception then get stacked diagnostics v_error=message_text; end;
  if coalesce(v_error,'') not like '%between 20 and 50%' then
    raise exception 'FAIL: Day Tour must reject fewer than 20 guests';
  end if;
  v_error:=null;
  begin
    perform public.evently_pool_tour_total('5afda244-a615-4bd3-98eb-d360d000100b',19,null);
  exception when raise_exception then get stacked diagnostics v_error=message_text; end;
  if coalesce(v_error,'') not like '%between 20 and 50%' then
    raise exception 'FAIL: Night Tour must reject fewer than 20 guests';
  end if;
  v_error:=null;
  begin
    perform public.evently_pool_tour_total('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',19,null);
  exception when raise_exception then get stacked diagnostics v_error=message_text; end;
  if coalesce(v_error,'') not like '%between 20 and 50%' then
    raise exception 'FAIL: Overnight Tour must reject fewer than 20 guests';
  end if;
  v_error:=null;
  begin
    perform public.evently_pool_tour_total('4ae972a8-6503-4776-90c9-899246cbc4dc',51,null);
  exception when raise_exception then get stacked diagnostics v_error=message_text; end;
  if coalesce(v_error,'') not like '%between 1 and 50%' then
    raise exception 'FAIL: Day Tour must reject more than 50 guests';
  end if;
  raise notice 'PASS: authenticated audit, fixed prices/minimums, and 50-person bounds';
end;
$$;

-- Inspect effective grants/policies separately; these must show only authenticated
-- execution for creation/admin verification and anon+authenticated for the
-- boolean availability check. A real customer-account end-to-end test remains
-- required to exercise schedule creation, capacity contention, and confirmation.
select p.proname,has_function_privilege('anon',p.oid,'execute') as anon_execute,
  has_function_privilege('authenticated',p.oid,'execute') as authenticated_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
  'create_evently_reservation','evently_check_availability',
  'evently_admin_set_pool_capacity','evently_pool_capacity_ready');

select c.relname,pol.polname,pol.polcmd,pg_get_expr(pol.polqual,pol.polrelid) as using_expression
from pg_policy pol join pg_class c on c.oid=pol.polrelid
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('packages','reservations','evently_pool_capacity_audit')
order by c.relname,pol.polname;
