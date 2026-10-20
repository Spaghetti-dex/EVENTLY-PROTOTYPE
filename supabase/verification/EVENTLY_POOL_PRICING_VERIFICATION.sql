-- Read-only post-migration verification for 20261018160000.
-- No reservation, order, payment, or package rows are modified by this script.
do $$
declare
  v_def text;
  v_rejected boolean;
  v_capacity_row record;
begin
  if to_regprocedure('public.evently_pool_tour_amount(uuid,integer,uuid)') is null
     or to_regprocedure('public.evently_pool_tour_total(uuid,integer,uuid)') is null
     or to_regprocedure('public.evently_admin_set_pool_capacity(uuid,boolean,integer,text)') is null then
    raise exception 'FAIL: pool amount/total functions are missing';
  end if;
  if has_function_privilege('anon','public.evently_admin_set_pool_capacity(uuid,boolean,integer,text)','execute')
     or not has_function_privilege('authenticated','public.evently_admin_set_pool_capacity(uuid,boolean,integer,text)','execute') then
    raise exception 'FAIL: pool capacity verification RPC grants are unsafe';
  end if;
  if not exists(select 1 from pg_catalog.pg_class where oid='public.evently_pool_capacity_audit'::regclass and relrowsecurity) then
    raise exception 'FAIL: pool capacity audit is missing RLS';
  end if;
  if has_function_privilege('anon','public.evently_admin_set_pool_capacity(uuid,boolean,integer,text)','execute') then
    raise exception 'FAIL: anonymous users can configure pool capacity';
  end if;
  if (select count(*) from public.packages package where
        ((package.id='4ae972a8-6503-4776-90c9-899246cbc4dc' and package.min_guest_count=20)
        or (package.id='5afda244-a615-4bd3-98eb-d360d000100b' and package.min_guest_count=20)
       or (package.id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8' and package.min_guest_count=20))
      and package.max_guest_count is not null
      and package.max_guest_count>=package.min_guest_count
      and package.pool_capacity_verified
      and package.pool_capacity_verified_at is not null and package.pool_capacity_verified_by is not null
      and package.pool_capacity_audit_id is not null
      and exists(select 1 from public.evently_resources resource
        where resource.resource_key=package.resource_key and resource.is_active and resource.is_exclusive
          and resource.capacity=package.max_guest_count)
      and exists(select 1 from public.evently_pool_capacity_audit audit
       where audit.id=package.pool_capacity_audit_id and audit.package_id=package.id
          and audit.changed_by=package.pool_capacity_verified_by and audit.new_capacity_verified
          and audit.new_max_guest_count is not distinct from package.max_guest_count
          and audit.verification_source='authenticated_admin_rpc'))<>3 then
    raise exception 'FAIL: the three authenticated Administrator capacity audit records are missing or inconsistent';
  end if;
  if (select count(*) from public.packages where
       (id in ('4ae972a8-6503-4776-90c9-899246cbc4dc','5afda244-a615-4bd3-98eb-d360d000100b')
         and cottage_fee=700 and cottage_addon_id='1e97b2bf-ca43-492a-8a15-2d20f6abf040' and pool_access_fee=0)
       or (id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
         and cottage_fee=1000 and cottage_addon_id='928c269f-c38a-4345-86a5-d1f4c65555f0' and pool_access_fee=0))<>3 then
    raise exception 'FAIL: package cottage mappings/fees or no-Pool-Access tour rule differ';
  end if;
  if (select count(*) from public.addons where
       (id='1e97b2bf-ca43-492a-8a15-2d20f6abf040' and is_active and price=700
          and 'resort'=any(compatible_services))
       or (id='928c269f-c38a-4345-86a5-d1f4c65555f0' and is_active and price=1000
          and 'resort'=any(compatible_services))<>2 then
    raise exception 'FAIL: cottage add-ons must be active, correctly priced, and Resort-compatible';
  end if;
   if public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,null)<>2000
     or public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',25,null)<>2500
     or public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',50,null)<>5000
      or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',20,null)<>3000
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',25,null)<>3750
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',50,null)<>7500
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,null)<>4000
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',25,null)<>5000
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',50,null)<>10000 then
    raise exception 'FAIL: 20/25/50 guest per-person pricing calculations differ';
  end if;
   if public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,
         '1e97b2bf-ca43-492a-8a15-2d20f6abf040')<>2700
       or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',20,
         '1e97b2bf-ca43-492a-8a15-2d20f6abf040')<>3700
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,
       '928c269f-c38a-4345-86a5-d1f4c65555f0')<>5000 then
    raise exception 'FAIL: optional cottage pricing is not added once';
  end if;
  if round(public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',25,null)*0.30,2)<>750
     or round(public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,null)*0.30,2)<>1200
     or round(public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,
       '928c269f-c38a-4345-86a5-d1f4c65555f0')*0.30,2)<>1500 then
    raise exception 'FAIL: 30-percent deposit is not based on validated guest/cottage totals';
  end if;
    if public.evently_pool_tour_total('4ae972a8-6503-4776-90c9-899246cbc4dc',20,null)<>2000
       or public.evently_pool_tour_total('5afda244-a615-4bd3-98eb-d360d000100b',20,null)<>3000
      or public.evently_pool_tour_total('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,null)<>4000 then
     raise exception 'FAIL: verified Day/Night/Overnight minimum pricing differs';
  end if;
  v_rejected:=false;
   begin perform public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',19,null);
   exception when raise_exception then v_rejected:=sqlerrm ilike '%at least 20%'; end;
   if not coalesce(v_rejected,false) then raise exception 'FAIL: Day Tour minimum of 20 guests was not enforced'; end if;
   v_rejected:=false;
   begin perform public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',19,null);
   exception when raise_exception then v_rejected:=sqlerrm ilike '%at least 20%'; end;
   if not coalesce(v_rejected,false) then raise exception 'FAIL: Night Tour minimum of 20 guests was not enforced'; end if;
   v_rejected:=false;
   begin perform public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',19,null);
   exception when raise_exception then v_rejected:=sqlerrm ilike '%at least 20%'; end;
   if not coalesce(v_rejected,false) then raise exception 'FAIL: Overnight minimum of 20 guests was not enforced'; end if;

    if to_regprocedure('public.create_evently_reservation_before_exact_resource_assignment(jsonb)') is null
       or to_regprocedure('public.evently_check_availability(uuid,date)') is null
     or to_regprocedure('public.evently_reservation_holds_schedule(uuid)') is null
     or to_regprocedure('public.evently_expire_unpaid_reservations()') is null
     or to_regprocedure('public.evently_auto_confirm_verified_reservation(uuid)') is null then
    raise exception 'FAIL: existing booking, availability, schedule-hold, expiry, or confirmation RPC is missing';
  end if;
   select lower(pg_catalog.pg_get_functiondef('public.create_evently_reservation_before_exact_resource_assignment(jsonb)'::regprocedure))
      into v_def;
   if to_regprocedure('public.create_evently_reservation_before_resort_staycation_pricing(jsonb)') is not null then
     v_def:=v_def||lower(pg_catalog.pg_get_functiondef(
       'public.create_evently_reservation_before_resort_staycation_pricing(jsonb)'::regprocedure));
   end if;
  if position('evently_pool_tour_total' in v_def)=0
      or position('guest_count' in v_def)=0
      or position('reservation_addons' in v_def)=0
      or position('pool access is not available for swimming tour bookings' in v_def)=0 then
    raise exception 'FAIL: booking wrapper does not delegate the validated total/guest snapshot/add-on check';
  end if;
  if has_function_privilege('authenticated','public.evently_admin_approve_booking(uuid,boolean)','execute') then
    raise exception 'FAIL: manual booking approval is still executable';
  end if;
  if has_table_privilege('anon','public.reservations','INSERT')
      or has_table_privilege('authenticated','public.reservations','INSERT')
      or has_table_privilege('authenticated','public.reservations','UPDATE')
      or has_table_privilege('anon','public.reservations','UPDATE')
      or has_table_privilege('anon','public.reservations','DELETE')
      or has_table_privilege('authenticated','public.reservations','DELETE')
      or has_table_privilege('anon','public.addons','INSERT')
      or has_table_privilege('anon','public.addons','UPDATE')
      or has_table_privilege('anon','public.addons','DELETE')
      or has_table_privilege('authenticated','public.addons','INSERT')
      or has_table_privilege('authenticated','public.addons','UPDATE')
      or has_table_privilege('authenticated','public.addons','DELETE')
      or has_table_privilege('anon','public.orders','INSERT')
      or has_table_privilege('anon','public.orders','UPDATE')
      or has_table_privilege('anon','public.orders','DELETE')
      or has_table_privilege('authenticated','public.orders','INSERT')
      or has_table_privilege('authenticated','public.orders','UPDATE')
      or has_table_privilege('authenticated','public.orders','DELETE')
      or has_table_privilege('anon','public.payments','INSERT')
      or has_table_privilege('anon','public.payments','UPDATE')
      or has_table_privilege('anon','public.payments','DELETE')
      or has_table_privilege('authenticated','public.payments','UPDATE')
      or has_table_privilege('authenticated','public.payments','INSERT')
      or has_table_privilege('authenticated','public.payments','DELETE')
      or has_table_privilege('anon','public.packages','INSERT')
      or has_table_privilege('anon','public.packages','UPDATE')
      or has_table_privilege('anon','public.packages','DELETE')
      or has_table_privilege('authenticated','public.packages','INSERT')
      or has_table_privilege('authenticated','public.packages','UPDATE')
      or has_table_privilege('authenticated','public.packages','DELETE') then
    raise exception 'FAIL: direct lifecycle DML remains granted instead of using guarded RPCs';
  end if;
  if not has_function_privilege('authenticated','public.admin_update_evently_catalog(text,uuid,jsonb)','execute') then
    raise exception 'FAIL: authenticated Administrators no longer have the guarded catalog RPC';
  end if;
  if exists(select 1 from information_schema.column_privileges
      where table_schema='public' and table_name in ('packages','reservations','orders','payments','addons')
        and grantee in ('PUBLIC','anon','authenticated') and privilege_type in ('INSERT','UPDATE')) then
    raise exception 'FAIL: direct column-level catalog or lifecycle DML remains granted';
  end if;

  -- This verification runs only after each tour has been approved through the
  -- authenticated Admin RPC; unverified capacity must remain blocked.
   for v_capacity_row in select id,min_guest_count,max_guest_count from public.packages package where package.id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc','5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
      and package.pool_capacity_verified and package.pool_capacity_verified_at is not null
      and package.pool_capacity_audit_id is not null
      and package.max_guest_count is not null
      and exists(select 1 from public.evently_pool_capacity_audit audit
          where audit.id=package.pool_capacity_audit_id and audit.package_id=package.id
            and audit.changed_by=package.pool_capacity_verified_by
            and audit.new_capacity_verified and audit.new_max_guest_count=package.max_guest_count
            and audit.verification_source='authenticated_admin_rpc')
   loop
     if public.evently_pool_tour_total(v_capacity_row.id,v_capacity_row.max_guest_count,null)
          is distinct from public.evently_pool_tour_amount(v_capacity_row.id,v_capacity_row.max_guest_count,null) then
       raise exception 'FAIL: the Administrator-verified maximum was not accepted for %',v_capacity_row.id;
     end if;
     v_rejected:=false;
     begin
       perform public.evently_pool_tour_total(v_capacity_row.id,v_capacity_row.max_guest_count+1,null);
     exception when raise_exception then v_rejected:=sqlerrm like '%verified physical maximum%';
    end;
    if not coalesce(v_rejected,false) then raise exception 'FAIL: count above verified maximum was not rejected for %',v_capacity_row.id; end if;
  end loop;
end;
$$;

select package.id,package.name,package.price as unit_rate,package.min_guest_count,
       package.guest_capacity as preserved_legacy_capacity,
       package.max_guest_count,package.pool_capacity_verified,package.cottage_fee,
       package.pool_capacity_verified_at,package.pool_capacity_verified_by,package.pool_capacity_audit_id,
       package.cottage_addon_id,package.deposit_percentage,package.resource_key,
       package.resource_mode,package.schedule_mode,package.fixed_start_time,
       package.fixed_end_time,package.operating_start_time,package.operating_end_time
from public.packages package where package.id in (
  '4ae972a8-6503-4776-90c9-899246cbc4dc',
  '5afda244-a615-4bd3-98eb-d360d000100b',
  '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
 ) order by package.id;

select resource_key,resource_name,capacity,is_active,is_exclusive
from public.evently_resources where resource_key='venice-main-pool';

select public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,null) as day_20_guests,
       public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',25,null) as day_25_guests,
       public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',20,null) as night_20_guests,
       public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,null) as overnight_20_guests,
       public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',25,null) as overnight_25_guests,
       round(public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,null)*0.30,2) as day_20_guest_deposit;

-- Confirm the existing per_booking default and show that both legacy modes remain.
select column_default as packages_pricing_mode_default
from information_schema.columns
where table_schema='public' and table_name='packages' and column_name='pricing_mode';

select pricing_mode,count(*) as package_count
from public.packages
order by pricing_mode;
