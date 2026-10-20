-- EVENTLY pool-capacity backend repair.
-- Additive and fail-closed: never adopts prototype_operator_attestation as a
-- physical inspection. Apply and validate in staging before production approval.
begin;

do $$
begin
  if to_regclass('public.packages') is null
     or to_regclass('public.reservations') is null
     or to_regclass('public.evently_resources') is null
     or to_regclass('public.evently_pool_capacity_audit') is null
     or to_regclass('public.profiles') is null
     or to_regclass('public.package_variants') is null
     or to_regclass('public.reservation_addons') is null
     or to_regclass('public.admin_activity_logs') is null
     or to_regprocedure('public.is_evently_admin()') is null
     or to_regprocedure('public.create_evently_reservation(jsonb)') is null
     or to_regprocedure('public.create_evently_reservation_before_exact_resource_assignment(jsonb)') is null
     or to_regprocedure('public.evently_check_availability(uuid,date)') is null
     or to_regprocedure('public.evently_admin_set_reservation_schedule(time,uuid,text,time)') is null then
    raise exception 'Pool workflow migration stopped: expected existing EVENTLY schema/RPC chain is incomplete';
  end if;
  if (select count(*) from public.packages where id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
      and is_active and lower(service_type)='resort' and pricing_mode='per_guest'
      and resource_key='venice-main-pool') <> 3 then
    raise exception 'Pool workflow migration stopped: expected active pool package rows or physical resource mappings differ';
  end if;
  if exists(select 1 from public.packages where id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
      and package_category is not null and package_category<>'pool_tour') then
    raise exception 'Pool workflow migration stopped: pool package category has an unexpected non-null value';
  end if;
  if not exists(select 1 from public.evently_resources
      where resource_key='venice-main-pool' and is_active and is_exclusive) then
    raise exception 'Pool workflow migration stopped: active exclusive physical pool resource missing';
  end if;
  if (select count(*) from public.packages where
      (id='4ae972a8-6503-4776-90c9-899246cbc4dc' and price=100 and min_guest_count in (1,20)
        and deposit_percentage=30
        and coalesce(fixed_start_time,operating_start_time)=time '08:00'
        and coalesce(fixed_end_time,operating_end_time)=time '15:00'
        and cottage_fee=700 and cottage_addon_id='1e97b2bf-ca43-492a-8a15-2d20f6abf040')
      or (id='5afda244-a615-4bd3-98eb-d360d000100b' and price=150 and min_guest_count in (1,20)
        and deposit_percentage=30
        and coalesce(fixed_start_time,operating_start_time)=time '16:00'
        and coalesce(fixed_end_time,operating_end_time)=time '22:00'
        and cottage_fee=700 and cottage_addon_id='1e97b2bf-ca43-492a-8a15-2d20f6abf040')
      or (id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8' and price=200 and min_guest_count=20
        and deposit_percentage=30
        and coalesce(fixed_start_time,operating_start_time)=time '19:00'
        and coalesce(fixed_end_time,operating_end_time)=time '04:00'
        and cottage_fee=1000 and cottage_addon_id='928c269f-c38a-4345-86a5-d1f4c65555f0')
  ) <> 3 then
    raise exception 'Pool workflow migration stopped: tour rate, schedule, minimum, or cottage catalog differs from the approved configuration';
  end if;
  if exists(select 1 from public.package_variants where is_active and package_id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')) then
    raise exception 'Pool workflow migration stopped: active pool variants must be reviewed before capacity-safe booking';
  end if;
  if (select count(*) from information_schema.columns where table_schema='public'
      and table_name='evently_pool_capacity_audit'
      and column_name in ('id','resource_key','approved_capacity','verification_source',
        'verification_note','verified_by','verified_at')) <> 7 then
    raise exception 'Pool workflow migration stopped: unrecognized capacity audit shape; preserve and reconcile it first';
  end if;
  if exists(
    select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prokind='f'
      and p.oid <> to_regprocedure('public.create_evently_reservation(jsonb)')
      and position('public.create_evently_reservation(' in lower(pg_catalog.pg_get_functiondef(p.oid))) > 0
  ) then
    raise exception 'Pool workflow migration stopped: another RPC calls create_evently_reservation directly';
  end if;
  if to_regprocedure('public.create_evently_reservation_before_exact_resource_assignment(jsonb)') is null
     or not (select prosecdef from pg_catalog.pg_proc
       where oid=to_regprocedure('public.create_evently_reservation_before_exact_resource_assignment(jsonb)')) then
    raise exception 'Pool workflow migration stopped: expected SECURITY DEFINER booking core is unavailable';
  end if;
end;
$$;

alter table public.packages
  add column if not exists max_guest_count integer,
  add column if not exists pool_capacity_audit_id uuid;
alter table public.reservations
  add column if not exists cottage_selected boolean not null default false,
  add column if not exists cottage_fee numeric(12,2) not null default 0,
  add column if not exists cottage_addon_id uuid references public.addons(id);

-- Keep the established audit table and all historic rows. Add a nullable link
-- for the package-specific authenticated verification entries created below.
alter table public.evently_pool_capacity_audit
  add column if not exists package_id uuid references public.packages(id) on delete restrict;
do $$
  if not exists(select 1 from pg_catalog.pg_constraint
      where conrelid='public.packages'::regclass and conname='packages_pool_capacity_audit_id_fkey') then
    alter table public.packages add constraint packages_pool_capacity_audit_id_fkey
      foreign key(pool_capacity_audit_id) references public.evently_pool_capacity_audit(id) on delete restrict;
  end if;
end;
$$;

-- A historical prototype record is retained exactly as recorded, but is not
-- treated as an authenticated physical inspection. Withdraw only the live
-- package flags backed by such a record; never rewrite the audit history.
update public.packages p
set pool_capacity_verified=false,
    pool_capacity_verified_at=null,
    pool_capacity_verified_by=null,
    pool_capacity_audit_id=null,
    max_guest_count=null,
    updated_at=now()
where p.id in (
  '4ae972a8-6503-4776-90c9-899246cbc4dc',
  '5afda244-a615-4bd3-98eb-d360d000100b',
  '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
) and p.pool_capacity_verified
  and not exists(
    select 1 from public.evently_pool_capacity_audit a
    where a.id=p.pool_capacity_audit_id and a.package_id=p.id
      and a.resource_key='venice-main-pool'
      and a.approved_capacity between p.min_guest_count and 50
      and a.verified_by=p.pool_capacity_verified_by
      and a.verification_source='authenticated_admin_rpc'
  );

update public.packages set package_category='pool_tour',updated_at=now()
where id in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
  '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
  and package_category is null;
update public.packages set min_guest_count=20,updated_at=now()
where id in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
  '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
  and is_active and lower(service_type)='resort' and resource_key='venice-main-pool';
update public.evently_resources r set capacity=null,updated_at=now()
where r.resource_key='venice-main-pool' and not exists(
  select 1 from public.packages p where p.id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
    and p.pool_capacity_verified and p.max_guest_count is not null
    and exists(select 1 from public.evently_pool_capacity_audit a
      where a.id=p.pool_capacity_audit_id and a.package_id=p.id
        and a.verification_source='authenticated_admin_rpc')
);

do $$
begin
  if not exists(select 1 from pg_catalog.pg_constraint
      where conrelid='public.packages'::regclass and conname='packages_pool_max_guest_count_check') then
    alter table public.packages add constraint packages_pool_max_guest_count_check
      check(max_guest_count is null or (package_category='pool_tour'
        and max_guest_count between min_guest_count and 50)) not valid;
  end if;
  if not exists(select 1 from pg_catalog.pg_constraint
      where conrelid='public.packages'::regclass and conname='packages_pool_capacity_audit_state_check') then
    alter table public.packages add constraint packages_pool_capacity_audit_state_check
      check(not pool_capacity_verified or (
        max_guest_count is not null and pool_capacity_verified_at is not null
        and pool_capacity_verified_by is not null and pool_capacity_audit_id is not null
      )) not valid;
  end if;
end;
$$;
alter table public.packages validate constraint packages_pool_max_guest_count_check;
alter table public.packages validate constraint packages_pool_capacity_audit_state_check;
do $$
begin
  if not exists(select 1 from pg_catalog.pg_constraint
      where conrelid='public.reservations'::regclass and conname='reservations_cottage_fee_nonnegative') then
    alter table public.reservations add constraint reservations_cottage_fee_nonnegative
      check(cottage_fee>=0) not valid;
  end if;
end;
$$;
alter table public.reservations validate constraint reservations_cottage_fee_nonnegative;

-- The established browser contract is RPC-only for catalog and reservation
-- writes. Existing permissive INSERT RLS policy remains inert after revoking
-- table/column DML; SECURITY DEFINER RPCs retain their owner privileges.
do $$
declare v_table text; v_columns text;
begin
  foreach v_table in array array['packages','reservations'] loop
    execute pg_catalog.format(
      'revoke insert,update,delete on table public.%I from public,anon,authenticated',v_table);
    select string_agg(pg_catalog.quote_ident(a.attname),', ' order by a.attnum)
      into v_columns from pg_catalog.pg_attribute a
      where a.attrelid=to_regclass('public.'||v_table) and a.attnum>0 and not a.attisdropped;
    if v_columns is not null then
      execute pg_catalog.format(
        'revoke insert (%s),update (%s) on table public.%I from public,anon,authenticated',
        v_columns,v_columns,v_table);
    end if;
  end loop;
  if has_table_privilege('anon','public.reservations','INSERT')
     or has_table_privilege('authenticated','public.reservations','INSERT')
     or has_table_privilege('anon','public.reservations','UPDATE')
     or has_table_privilege('authenticated','public.reservations','UPDATE')
     or has_table_privilege('anon','public.reservations','DELETE')
     or has_table_privilege('authenticated','public.reservations','DELETE')
     or has_table_privilege('anon','public.packages','UPDATE')
     or has_table_privilege('authenticated','public.packages','UPDATE')
     or has_table_privilege('anon','public.packages','INSERT')
     or has_table_privilege('authenticated','public.packages','INSERT')
     or has_table_privilege('anon','public.packages','DELETE')
     or has_table_privilege('authenticated','public.packages','DELETE') then
    raise exception 'Pool workflow migration stopped: direct browser-role booking/catalog writes remain granted';
  end if;
end;
$$;

create index if not exists reservations_pool_date_idx
  on public.reservations(reservation_date, start_time, end_time)
  where package_id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
  );

create or replace function public.evently_pool_capacity_ready(p_package_id uuid)
returns boolean
language sql stable security definer set search_path=''
as $$
  select exists(
    select 1
    from public.packages p
    join public.evently_resources r on r.resource_key=p.resource_key
    join public.evently_pool_capacity_audit a on a.id=p.pool_capacity_audit_id
    where p.id=p_package_id and p.is_active
      and p.id in (
        '4ae972a8-6503-4776-90c9-899246cbc4dc',
        '5afda244-a615-4bd3-98eb-d360d000100b',
        '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
      )
      and p.pool_capacity_verified and p.pool_capacity_verified_at is not null
      and p.pool_capacity_verified_by is not null
      and p.max_guest_count between p.min_guest_count and 50
      and p.package_category in ('pool_tour')
      and p.pricing_mode='per_guest'
      and p.resource_key='venice-main-pool' and p.resource_mode='exclusive'
      and p.schedule_mode in ('fixed','timed')
      and r.is_active and r.is_exclusive and r.capacity=p.max_guest_count
      and a.package_id=p.id and a.resource_key=p.resource_key
      and a.approved_capacity=p.max_guest_count
      and a.verified_by=p.pool_capacity_verified_by
      and a.verified_at=p.pool_capacity_verified_at
      and a.verification_source='authenticated_admin_rpc'
  );
$$;

create or replace function public.evently_pool_tour_total(
  p_package_id uuid,p_guest_count integer,p_cottage_addon_id uuid default null
) returns numeric(12,2)
language plpgsql security definer set search_path=''
as $$
declare v_package public.packages%rowtype; v_rate numeric(12,2); v_min integer;
  v_cottage uuid; v_cottage_price numeric(12,2);
begin
  select * into v_package from public.packages where id=p_package_id and is_active for share;
  if not found or not public.evently_pool_capacity_ready(p_package_id) then
    raise exception 'Pool bookings are paused until an Administrator verifies and audits physical capacity';
  end if;
  case p_package_id
    when '4ae972a8-6503-4776-90c9-899246cbc4dc'::uuid then
      v_rate:=100; v_min:=20; v_cottage:='1e97b2bf-ca43-492a-8a15-2d20f6abf040'; v_cottage_price:=700;
    when '5afda244-a615-4bd3-98eb-d360d000100b'::uuid then
      v_rate:=150; v_min:=20; v_cottage:='1e97b2bf-ca43-492a-8a15-2d20f6abf040'; v_cottage_price:=700;
    when '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'::uuid then
      v_rate:=200; v_min:=20; v_cottage:='928c269f-c38a-4345-86a5-d1f4c65555f0'; v_cottage_price:=1000;
    else raise exception 'Selected package is not a configured pool tour';
  end case;
  if p_guest_count is null or p_guest_count<v_min or p_guest_count>v_package.max_guest_count then
    raise exception 'Guest count must be between % and % for this pool tour',v_min,v_package.max_guest_count;
  end if;
  if v_package.price is distinct from v_rate or v_package.min_guest_count is distinct from v_min
     or v_package.cottage_addon_id is distinct from v_cottage
     or v_package.cottage_fee is distinct from v_cottage_price
     or v_package.deposit_percentage is distinct from 30 then
    raise exception 'Pool tour price, minimum, cottage, or deposit configuration differs from the approved schedule';
  end if;
  if p_cottage_addon_id is not null and p_cottage_addon_id is distinct from v_cottage then
    raise exception 'Selected cottage is not configured for this tour';
  end if;
  if p_cottage_addon_id is not null and not exists(
    select 1 from public.addons a where a.id=v_cottage and a.is_active
      and a.price=v_cottage_price and 'resort'=any(a.compatible_services)
  ) then raise exception 'Configured cottage add-on is unavailable'; end if;
  return round(v_rate*p_guest_count+case when p_cottage_addon_id is null then 0 else v_cottage_price end,2);
end;
$$;

-- Advisory transaction lock + overlap sum is the single capacity gate for
-- both availability and reservation writes. Pending rows are conservatively
-- counted until cancelled/rejected/completed/expired.
create or replace function public.evently_pool_capacity_available(
  p_date date,p_start time,p_end time,p_guest_count integer,p_exclude_reservation uuid default null
) returns boolean
language plpgsql volatile security definer set search_path=''
as $$
declare v_used integer; v_max integer;
  v_start timestamp; v_end timestamp;
begin
  if p_date is null or p_start is null or p_end is null or p_start=p_end
     or p_guest_count is null or p_guest_count<1 then return false; end if;
  select max(r.capacity) into v_max from public.evently_resources r
    where r.resource_key='venice-main-pool' and r.is_active and r.is_exclusive;
  if v_max is null or v_max>50 then return false; end if;
  v_start:=p_date+p_start;
  v_end:=p_date+p_end+case when p_end<=p_start then interval '1 day' else interval '0 day' end;
  select coalesce(sum(res.guest_count),0)::integer into v_used
  from public.reservations res
  left join public.packages pkg on pkg.id=res.package_id
  left join public.package_variants variant
    on variant.id=res.package_variant_id and variant.package_id=res.package_id
  where res.id is distinct from p_exclude_reservation
    and lower(trim(coalesce(nullif(res.resource_key,''),nullif(variant.resource_key,''),nullif(pkg.resource_key,''),'')))='venice-main-pool'
    and res.expired_at is null
    and lower(res.status::text) not in ('cancelled','canceled','rejected','completed','expired')
    and res.reservation_date is not null and res.start_time is not null and res.end_time is not null
    and res.reservation_date+res.start_time<v_end
    and res.reservation_date+res.end_time
      +case when res.end_time<=res.start_time then interval '1 day' else interval '0 day' end>v_start;
  return v_used+p_guest_count<=v_max;
end;
$$;

create or replace function public.evently_admin_set_pool_capacity(
  p_package_id uuid,p_capacity_verified boolean,p_max_guest_count integer,p_reason text
) returns void
language plpgsql security definer set search_path=''
as $$
declare v_package public.packages%rowtype; v_resource public.evently_resources%rowtype; v_audit uuid;
  v_max integer;
begin
  if auth.uid() is null or not public.is_evently_admin() then
    raise exception 'Authenticated Administrator access is required' using errcode='42501';
  end if;
  if nullif(btrim(p_reason),'') is null or length(btrim(p_reason))<10 or length(p_reason)>2000 then
    raise exception 'Record a 10–2000 character note describing the capacity change';
  end if;
  if p_capacity_verified and btrim(p_reason) !~* '(physical|on[- ]site)' then
    raise exception 'The verification note must explicitly describe the on-site physical capacity inspection';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evently-resource-schedule-global',0));
  select * into v_package from public.packages where id=p_package_id and is_active for update;
  if not found or p_package_id not in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
  ) then raise exception 'Select an active configured pool tour'; end if;
  select * into v_resource from public.evently_resources
    where resource_key='venice-main-pool' and is_active and is_exclusive for update;
  if not found then raise exception 'The exclusive physical pool resource is not active'; end if;
  if p_capacity_verified then
    if p_max_guest_count is null or p_max_guest_count<v_package.min_guest_count or p_max_guest_count>50 then
      raise exception 'Verified maximum must be between % and 50 guests',v_package.min_guest_count;
    end if;
    if exists(select 1 from public.packages sibling where sibling.id<>p_package_id
      and sibling.id in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
        '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
      and sibling.pool_capacity_verified and sibling.max_guest_count is distinct from p_max_guest_count) then
      raise exception 'All verified tours sharing this pool must use the same physical maximum';
    end if;
    if exists(
      with pool_holds as (
        select res.reservation_date+res.start_time as slot_start,
          res.reservation_date+res.end_time
            +case when res.end_time<=res.start_time then interval '1 day' else interval '0 day' end as slot_end,
          res.guest_count
        from public.reservations res
        left join public.packages pkg on pkg.id=res.package_id
        left join public.package_variants variant
          on variant.id=res.package_variant_id and variant.package_id=res.package_id
        where lower(trim(coalesce(nullif(res.resource_key,''),nullif(variant.resource_key,''),nullif(pkg.resource_key,''),'')))='venice-main-pool'
          and res.expired_at is null
          and lower(res.status::text) not in ('cancelled','canceled','rejected','completed','expired')
          and res.reservation_date is not null and res.start_time is not null and res.end_time is not null
      )
      select 1 from pool_holds point
      where (select coalesce(sum(held.guest_count),0) from pool_holds held
        where held.slot_start<=point.slot_start and held.slot_end>point.slot_start)>p_max_guest_count
    ) then
      raise exception 'Cannot verify a lower capacity while existing overlapping reservations exceed it';
    end if;
    insert into public.evently_pool_capacity_audit(package_id,resource_key,approved_capacity,
      verification_source,verification_note,verified_by,verified_at)
    values(p_package_id,'venice-main-pool',p_max_guest_count,'authenticated_admin_rpc',
      btrim(p_reason),auth.uid(),clock_timestamp()) returning id into v_audit;
    update public.packages set pool_capacity_verified=true,max_guest_count=p_max_guest_count,
      pool_capacity_verified_at=(select verified_at from public.evently_pool_capacity_audit where id=v_audit),
      pool_capacity_verified_by=auth.uid(),pool_capacity_audit_id=v_audit,updated_at=now()
      where id=p_package_id;
    update public.evently_resources set capacity=p_max_guest_count,updated_at=now()
      where resource_key='venice-main-pool';
  else
    insert into public.evently_pool_capacity_audit(package_id,resource_key,approved_capacity,
      verification_source,verification_note,verified_by,verified_at)
    values(p_package_id,'venice-main-pool',coalesce(v_package.max_guest_count,v_resource.capacity,50),
      'authenticated_admin_withdrawal',btrim(p_reason),auth.uid(),clock_timestamp()) returning id into v_audit;
    update public.packages set pool_capacity_verified=false,max_guest_count=null,
      pool_capacity_verified_at=null,pool_capacity_verified_by=null,
      pool_capacity_audit_id=v_audit,updated_at=now() where id=p_package_id;
    select max(max_guest_count) into v_max from public.packages
      where id in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
        '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
        and pool_capacity_verified;
    update public.evently_resources set capacity=v_max,updated_at=now()
      where resource_key='venice-main-pool';
  end if;
  insert into public.admin_activity_logs(admin_id,action,entity_type,entity_id,description)
  values(auth.uid(),case when p_capacity_verified then 'pool_capacity_verified' else 'pool_capacity_withdrawn' end,
    'package',p_package_id,btrim(p_reason));
end;
$$;

-- Preserve the existing general-resource implementations behind private names.
do $$
begin
  if to_regprocedure('public.create_evently_reservation_before_pool_capacity(jsonb)') is null then
    alter function public.create_evently_reservation(jsonb)
      rename to create_evently_reservation_before_pool_capacity;
  end if;
  if to_regprocedure('public.evently_check_availability_before_pool_capacity(uuid,date)') is null then
    alter function public.evently_check_availability(uuid,date)
      rename to evently_check_availability_before_pool_capacity;
  end if;
  if to_regprocedure('public.evently_admin_set_reservation_schedule_before_pool_capacity(time,uuid,text,time)') is null then
    alter function public.evently_admin_set_reservation_schedule(time,uuid,text,time)
      rename to evently_admin_set_reservation_schedule_before_pool_capacity;
  end if;
end;
$$;

create or replace function public.evently_check_availability(
  p_package_id uuid,p_reservation_date date,p_guest_count integer
)
returns boolean language plpgsql volatile security definer set search_path=''
as $$
declare v_package public.packages%rowtype; v_required integer;
begin
  select * into v_package from public.packages where id=p_package_id and is_active;
  if not found then return false; end if;
  if p_package_id not in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8') then
    return public.evently_check_availability_before_pool_capacity(p_package_id,p_reservation_date);
  end if;
  if not public.evently_pool_capacity_ready(p_package_id) then return false; end if;
  if p_reservation_date<(now() at time zone 'Asia/Manila')::date then return false; end if;
  v_required:=coalesce(p_guest_count,v_package.min_guest_count);
  if v_required<v_package.min_guest_count or v_required>v_package.max_guest_count then return false; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evently-resource-schedule-global',0));
  return public.evently_pool_capacity_available(p_reservation_date,
    coalesce(v_package.fixed_start_time,v_package.operating_start_time),
    coalesce(v_package.fixed_end_time,v_package.operating_end_time),v_required,null);
end;
$$;

-- Keep the existing 2-argument contract for older clients; it checks the
-- package's minimum party size. New clients pass their actual selected count.
create or replace function public.evently_check_availability(p_package_id uuid,p_reservation_date date)
returns boolean language sql volatile security definer set search_path=''
as $$
  select public.evently_check_availability(p_package_id,p_reservation_date,null::integer);
$$;

create or replace function public.create_evently_reservation(p_booking jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_package public.packages%rowtype; v_requested integer; v_start time; v_end time;
  v_date date; v_cottage uuid; v_total numeric(12,2); v_addon_total numeric(12,2);
  v_result jsonb; v_id uuid; v_booking jsonb; v_used integer;
begin
  if jsonb_typeof(p_booking) is distinct from 'object' or jsonb_typeof(p_booking->'p_booking')='array' then
    raise exception 'Booking details are required';
  end if;
  -- The public app sends the booking fields directly; accept the established
  -- RPC wrapper shape as well for older clients.
  v_booking:=case when jsonb_typeof(p_booking->'p_booking')='object' then p_booking->'p_booking' else p_booking end;
  if auth.uid() is null then raise exception 'Authentication is required' using errcode='28000'; end if;
  select * into v_package from public.packages
    where id=nullif(v_booking->>'package_id','')::uuid and is_active;
  if not found then raise exception 'The selected package is unavailable'; end if;
  if v_package.id not in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8') then
    return public.create_evently_reservation_before_pool_capacity(p_booking);
  end if;
  begin
    v_requested:=nullif(v_booking->>'guest_count','')::integer;
    v_date:=nullif(v_booking->>'reservation_date','')::date;
    v_start:=nullif(v_booking->>'start_time','')::time;
    v_end:=nullif(v_booking->>'end_time','')::time;
    v_cottage:=case when coalesce((v_booking->>'cottage_selected')::boolean,false)
      then nullif(v_booking->>'cottage_addon_id','')::uuid else null end;
  exception when others then raise exception 'Invalid pool date, schedule, guest count, or cottage selection'; end;
  if not public.evently_pool_capacity_ready(v_package.id) then
    raise exception 'Pool bookings are paused until an Administrator verifies and audits physical capacity';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evently-resource-schedule-global',0));
  v_total:=public.evently_pool_tour_total(v_package.id,v_requested,v_cottage);
  if v_date is null or v_date<(now() at time zone 'Asia/Manila')::date then
    raise exception 'Select a valid current or future reservation date';
  end if;
  if v_start is distinct from coalesce(v_package.fixed_start_time,v_package.operating_start_time)
     or v_end is distinct from coalesce(v_package.fixed_end_time,v_package.operating_end_time) then
    raise exception 'Selected time does not match the verified fixed pool tour schedule';
  end if;
  if v_package.schedule_mode not in ('fixed','timed')
     or v_package.resource_mode<>'exclusive' or v_package.resource_key<>'venice-main-pool' then
    raise exception 'Pool tour resource or schedule configuration is invalid';
  end if;
  if v_cottage is not null and exists(
    select 1 from jsonb_array_elements(coalesce(v_booking->'addons','[]'::jsonb)) a
      where a->>'id'=v_cottage::text
  ) then raise exception 'Cottage must be selected only through its optional tour cottage field'; end if;
  if exists(
    select 1 from jsonb_array_elements(coalesce(v_booking->'addons','[]'::jsonb)) chosen
    join public.addons a on a.id=nullif(chosen->>'id','')::uuid
    where a.id=v_package.cottage_addon_id or lower(a.name) like '%cottage%'
      or lower(a.name) like '%pool access%'
  ) then
    raise exception 'Cottage and Pool Access must use their package-specific selections, not generic add-ons';
  end if;
  if coalesce((v_booking->>'pool_access_selected')::boolean,false) then
    raise exception 'Pool access is included in the tour and cannot be charged separately';
  end if;
  if not public.evently_pool_capacity_available(v_date,v_start,v_end,v_requested,null) then
    select coalesce(sum(r.guest_count),0)::integer into v_used from public.reservations r
    left join public.packages pkg on pkg.id=r.package_id
    left join public.package_variants variant
      on variant.id=r.package_variant_id and variant.package_id=r.package_id
    where lower(trim(coalesce(nullif(r.resource_key,''),nullif(variant.resource_key,''),nullif(pkg.resource_key,''),'')))='venice-main-pool'
      and r.expired_at is null and lower(r.status::text) not in ('cancelled','canceled','rejected','completed','expired')
      and r.reservation_date+r.start_time<(v_date+v_end+case when v_end<=v_start then interval '1 day' else interval '0 day' end)
      and r.reservation_date+r.end_time+case when r.end_time<=r.start_time then interval '1 day' else interval '0 day' end>(v_date+v_start);
    raise exception 'Pool capacity conflict: % guests are already held; this tour would exceed the verified maximum of %',v_used,v_package.max_guest_count;
  end if;
  -- The existing booking core treats guest_capacity as a hard maximum and
  -- stores a single package price. Use its minimum valid sentinel internally,
  -- then atomically save the validated per-person amount and actual guest count.
  v_booking:=jsonb_set(v_booking,'{_evently_pool_guest_count}',to_jsonb(v_requested),true);
  v_booking:=jsonb_set(v_booking,'{guest_count}',to_jsonb(1),true);
  v_result:=public.create_evently_reservation_before_exact_resource_assignment(v_booking);
  v_id:=nullif(v_result->>'reservation_id','')::uuid;
  if v_id is null then raise exception 'Existing booking core did not return a reservation'; end if;
  select coalesce(sum(a.price*coalesce(a.quantity,1)),0) into v_addon_total
    from public.reservation_addons a where a.reservation_id=v_id;
  v_total:=v_total+v_addon_total;
  update public.reservations set
    guest_count=v_requested,resource_key='venice-main-pool',resource_mode='exclusive',
    schedule_mode=v_package.schedule_mode,
    cottage_selected=(v_cottage is not null),
    cottage_fee=case when v_cottage is null then 0 else v_package.cottage_fee end,
    cottage_addon_id=v_cottage,
    subtotal=v_total,total_amount=v_total,deposit_amount=round(v_total*0.30,2),
    remaining_balance=greatest(v_total-coalesce(amount_paid,0),0),
    booking_snapshot=coalesce(booking_snapshot,'{}'::jsonb)||jsonb_build_object(
      'pool_unit_rate',v_package.price,'pool_guest_count',v_requested,
      'pool_max_guest_count',v_package.max_guest_count,
      'cottage_addon_id',v_cottage,'cottage_fee',case when v_cottage is null then 0 else v_package.cottage_fee end
    ),updated_at=now()
  where id=v_id and customer_id=auth.uid();
  if not found then raise exception 'Created reservation could not be safely updated'; end if;
  return v_result||jsonb_build_object('guest_count',v_requested,'total_amount',v_total,
    'deposit_amount',round(v_total*0.30,2),'resource_key','venice-main-pool');
end;
$$;

create or replace function public.evently_admin_set_reservation_schedule(
  p_end_time time,p_reservation_id uuid,p_resource_key text,p_start_time time
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_res public.reservations%rowtype; v_package public.packages%rowtype;
begin
  if auth.uid() is null or not public.is_evently_admin() then
    raise exception 'Administrator access required' using errcode='42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evently-resource-schedule-global',0));
  select * into v_res from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  select * into v_package from public.packages where id=v_res.package_id;
  if not found then raise exception 'Selected package not found'; end if;
  if v_package.id not in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8') then
    return public.evently_admin_set_reservation_schedule_before_pool_capacity(
      p_end_time,p_reservation_id,p_resource_key,p_start_time);
  end if;
  if lower(v_res.status::text)<>'pending' then
    raise exception 'Only pending pool reservations may have schedule fields updated';
  end if;
  if p_resource_key is distinct from 'venice-main-pool'
     or p_start_time is distinct from coalesce(v_package.fixed_start_time,v_package.operating_start_time)
     or p_end_time is distinct from coalesce(v_package.fixed_end_time,v_package.operating_end_time) then
    raise exception 'Pool tour schedules and physical resource are fixed by the verified tour catalog';
  end if;
  if not public.evently_pool_capacity_ready(v_package.id)
     or not public.evently_pool_capacity_available(v_res.reservation_date,p_start_time,p_end_time,
        v_res.guest_count,v_res.id) then
    raise exception 'Pool capacity conflict: this schedule would exceed the currently verified simultaneous limit';
  end if;
  update public.reservations set start_time=p_start_time,end_time=p_end_time,
    resource_key='venice-main-pool',resource_mode='exclusive',schedule_mode=v_package.schedule_mode,
    updated_at=now() where id=p_reservation_id;
  return pg_catalog.jsonb_build_object('reservation_id',p_reservation_id,
    'reservation_date',v_res.reservation_date,'start_time',p_start_time,'end_time',p_end_time,
    'resource_key','venice-main-pool','status','pending');
end;
$$;

-- Preserve restricted execution of the old general booking path and expose
-- only the guarded customer/admin endpoints.
revoke all on function public.create_evently_reservation_before_pool_capacity(jsonb) from public,anon,authenticated;
revoke all on function public.evently_check_availability_before_pool_capacity(uuid,date) from public,anon,authenticated;
revoke all on function public.evently_admin_set_reservation_schedule_before_pool_capacity(time,uuid,text,time) from public,anon,authenticated;
revoke all on function public.evently_pool_capacity_ready(uuid) from public,anon,authenticated;
revoke all on function public.evently_pool_capacity_available(date,time,time,integer,uuid) from public,anon,authenticated;
revoke all on function public.evently_pool_tour_total(uuid,integer,uuid) from public,anon,authenticated;
revoke all on function public.evently_admin_set_pool_capacity(uuid,boolean,integer,text) from public,anon;
grant execute on function public.evently_admin_set_pool_capacity(uuid,boolean,integer,text) to authenticated;
revoke all on function public.evently_check_availability(uuid,date) from public,anon,authenticated;
revoke all on function public.evently_check_availability(uuid,date,integer) from public,anon,authenticated;
grant execute on function public.evently_check_availability(uuid,date) to anon,authenticated;
grant execute on function public.evently_check_availability(uuid,date,integer) to anon,authenticated;
revoke all on function public.create_evently_reservation(jsonb) from public,anon,authenticated;
grant execute on function public.create_evently_reservation(jsonb) to authenticated;
revoke all on function public.evently_admin_set_reservation_schedule(time,uuid,text,time) from public,anon,authenticated;
grant execute on function public.evently_admin_set_reservation_schedule(time,uuid,text,time) to authenticated;

alter table public.evently_pool_capacity_audit enable row level security;
revoke all on public.evently_pool_capacity_audit from public,anon,authenticated;
grant select on public.evently_pool_capacity_audit to authenticated;
drop policy if exists "EVENTLY administrators read pool verification audit" on public.evently_pool_capacity_audit;
create policy "EVENTLY administrators read pool verification audit"
  on public.evently_pool_capacity_audit for select to authenticated
  using(public.is_evently_admin());

notify pgrst,'reload schema';
commit;
