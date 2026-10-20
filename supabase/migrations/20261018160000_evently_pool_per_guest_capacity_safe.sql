-- Swimming Tour per-person pricing and capacity-safe RPC repair.
-- This is ordered after the prepared 20261017110000 schedule-hold migration.
-- It never nulls, raises, or reinterprets packages.guest_capacity.
begin;

do $$
begin
  if to_regclass('public.packages') is null or to_regclass('public.reservations') is null
     or to_regclass('public.orders') is null or to_regclass('public.addons') is null
     or to_regclass('public.package_variants') is null
     or to_regclass('public.reservation_addons') is null or to_regclass('public.evently_resources') is null
     or to_regclass('public.admin_activity_logs') is null
     or to_regclass('public.profiles') is null then
    raise exception 'Pool pricing repair stopped: required existing EVENTLY tables are missing';
  end if;
  if to_regprocedure('public.create_evently_reservation(jsonb)') is null
     or to_regprocedure('public.create_evently_reservation_before_exact_resource_assignment(jsonb)') is null
     or to_regprocedure('public.create_evently_reservation_before_verified_pool_tour_pricing(jsonb)') is null
     or to_regprocedure('public.create_evently_reservation_before_payment_submission(jsonb)') is null
     or to_regprocedure('public.submit_evently_payment(uuid,numeric,text,text,text)') is null
     or to_regprocedure('public.admin_review_payment(uuid,text,text)') is null
     or to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)') is null
     or to_regprocedure('public.admin_transition_reservation(uuid,text,text)') is null
     or to_regprocedure('public.evently_admin_check_reservation_schedule(uuid)') is null
     or to_regprocedure('public.evently_expire_unpaid_reservations()') is null
     or to_regprocedure('public.evently_reservation_holds_schedule(uuid)') is null
     or to_regprocedure('public.evently_existing_column(regclass,text[])') is null
     or to_regprocedure('public.evently_status_value(regclass,text,text)') is null
     or to_regprocedure('public.is_evently_admin()') is null
     or to_regprocedure('public.evently_admin_set_package_schedule(uuid,text,time,time,integer)') is null
     or to_regprocedure('public.evently_admin_override_reservation(uuid,text,text,date,time,time,text,timestamptz)') is null
     or to_regprocedure('public.admin_update_evently_catalog(text,uuid,jsonb)') is null then
    raise exception 'Pool pricing repair stopped: the established schedule-hold/booking RPC chain is missing; reconcile 20261017110000 first';
  end if;
  if not has_function_privilege('authenticated','public.admin_update_evently_catalog(text,uuid,jsonb)','execute') then
    raise exception 'Pool pricing repair stopped: the authenticated Admin catalog RPC is not executable; do not revoke direct add-on writes until its replacement is present';
  end if;
  if not has_function_privilege('authenticated','public.evently_admin_set_package_schedule(uuid,text,time,time,integer)','execute') then
    raise exception 'Pool pricing repair stopped: authenticated Administrators cannot use the existing package-schedule RPC';
  end if;
  if not (select prosecdef from pg_catalog.pg_proc
      where oid=to_regprocedure('public.admin_update_evently_catalog(text,uuid,jsonb)'))
     or position('is_evently_admin' in lower(pg_catalog.pg_get_functiondef(
       to_regprocedure('public.admin_update_evently_catalog(text,uuid,jsonb)'))))=0 then
    raise exception 'Pool pricing repair stopped: catalog edits must remain behind the Administrator-only SECURITY DEFINER RPC';
  end if;
  if to_regclass('public.evently_schedule_hold_catalog_backup') is null then
    raise exception 'Pool pricing repair stopped: the schedule-hold catalog snapshot is missing; confirm the migration state before restoring legacy capacity';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='addons' and column_name='compatible_services' and data_type='ARRAY') then
    raise exception 'Pool pricing repair stopped: add-on service compatibility metadata is missing';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='packages' and column_name='cottage_addon_id' and udt_name='uuid')
     or not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='packages' and column_name='cottage_fee' and data_type='numeric') then
    raise exception 'Pool pricing repair stopped: cottage mapping columns are missing; apply prerequisite catalog migration first';
  end if;
  if to_regclass('public.evently_pool_capacity_audit') is not null
     and (select count(*) from information_schema.columns where table_schema='public'
       and table_name='evently_pool_capacity_audit'
       and column_name in ('id','package_id','changed_by','reason','old_capacity_verified',
         'old_max_guest_count','new_capacity_verified','new_max_guest_count','changed_at'))<>9 then
    raise exception 'Pool pricing repair stopped: an existing capacity-audit table has incompatible columns';
  end if;
  if not exists(select 1 from public.evently_resources
    where resource_key='venice-main-pool' and is_active and is_exclusive) then
    raise exception 'Pool pricing repair stopped: the existing exclusive venice-main-pool resource is missing';
  end if;
  if exists(select 1 from public.package_variants where is_active and package_id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
    )) then
    raise exception 'Pool pricing repair stopped: active pool variants need explicit price/capacity review before the package wrapper can safely apply';
  end if;
  if not exists(select 1 from public.addons where id='1e97b2bf-ca43-492a-8a15-2d20f6abf040' and is_active and price=700)
     or not exists(select 1 from public.addons where id='928c269f-c38a-4345-86a5-d1f4c65555f0' and is_active and price=1000) then
    raise exception 'Pool pricing repair stopped: existing cottage add-ons/prices do not match the verified pool catalog';
  end if;
  if (select count(*) from public.packages package
    left join public.evently_schedule_hold_catalog_backup backup
      on backup.entity_type='package' and backup.entity_key=package.id::text
    where package.id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
    ) and package.is_active and lower(package.service_type::text)='resort'
      and package.resource_key='venice-main-pool' and package.resource_mode='exclusive'
      and package.schedule_mode in ('fixed','timed')
      and package.deposit_percentage=30
      and ((package.id='4ae972a8-6503-4776-90c9-899246cbc4dc'
            and coalesce(package.fixed_start_time,package.operating_start_time)=time '08:00'
            and coalesce(package.fixed_end_time,package.operating_end_time)=time '15:00')
        or (package.id='5afda244-a615-4bd3-98eb-d360d000100b'
            and coalesce(package.fixed_start_time,package.operating_start_time)=time '16:00'
            and coalesce(package.fixed_end_time,package.operating_end_time)=time '22:00')
        or (package.id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
            and coalesce(package.fixed_start_time,package.operating_start_time)=time '19:00'
            and coalesce(package.fixed_end_time,package.operating_end_time)=time '04:00'))) <> 3 then
    raise exception 'Pool pricing repair stopped: package IDs, exclusivity, fixed times, or 30%% deposit differ from the verified schedule';
  end if;
end;
$$;

-- A permissive customer INSERT policy is inert without an INSERT grant. Direct
-- lifecycle DML is revoked so the guarded RPC chain remains authoritative.
do $$
declare v_table text; v_columns text;
begin
  foreach v_table in array array['packages','reservations','orders','payments','addons'] loop
    execute pg_catalog.format('revoke insert, update, delete on table public.%I from public, anon, authenticated',v_table);
    select string_agg(pg_catalog.quote_ident(a.attname),', ' order by a.attnum) into v_columns
    from pg_catalog.pg_attribute a where a.attrelid=to_regclass('public.'||v_table) and a.attnum>0 and not a.attisdropped;
    if v_columns is not null then
      execute pg_catalog.format('revoke insert (%s) on table public.%I from public, anon, authenticated',v_columns,v_table);
      execute pg_catalog.format('revoke update (%s) on table public.%I from public, anon, authenticated',v_columns,v_table);
    end if;
  end loop;
  if exists(select 1 from unnest(array['packages','reservations','orders','payments','addons']) as names(table_name)
      where has_table_privilege('anon','public.'||table_name,'INSERT')
         or has_table_privilege('anon','public.'||table_name,'UPDATE')
         or has_table_privilege('anon','public.'||table_name,'DELETE')
         or has_table_privilege('authenticated','public.'||table_name,'INSERT')
         or has_table_privilege('authenticated','public.'||table_name,'UPDATE')
         or has_table_privilege('authenticated','public.'||table_name,'DELETE')) then
    raise exception 'Direct browser-role catalog or lifecycle table writes remain; use the guarded RPCs';
  end if;
  if exists(select 1 from information_schema.column_privileges
    where table_schema='public' and table_name in ('packages','reservations','orders','payments','addons')
      and grantee in ('PUBLIC','anon','authenticated') and privilege_type in ('INSERT','UPDATE')) then
    raise exception 'Direct catalog or lifecycle column-level writes remain granted';
  end if;
end;
$$;

alter table public.packages
  add column if not exists max_guest_count integer,
  add column if not exists pool_capacity_verified boolean not null default false,
  add column if not exists pool_capacity_verified_at timestamptz,
  add column if not exists pool_capacity_verified_by uuid references public.profiles(id);
alter table public.packages drop constraint if exists packages_pool_capacity_verification_check;
do $$
begin
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.packages'::regclass and conname='packages_max_guest_count_check') then
    alter table public.packages add constraint packages_max_guest_count_check
      check(max_guest_count is null or max_guest_count>=min_guest_count) not valid;
  end if;
end;
$$;
alter table public.packages add constraint packages_pool_capacity_verification_check
  check(
    (pool_capacity_verified
      and max_guest_count is not null
      and max_guest_count >= min_guest_count
      and pool_capacity_verified_at is not null
      and pool_capacity_verified_by is not null)
    or (not pool_capacity_verified
      and max_guest_count is null
      and pool_capacity_verified_at is null
      and pool_capacity_verified_by is null)
  ) not valid;
alter table public.packages validate constraint packages_max_guest_count_check;
alter table public.packages validate constraint packages_pool_capacity_verification_check;

-- Create/repair the audit schema before any pricing function or test references it.
create table if not exists public.evently_pool_capacity_audit (
  id uuid primary key default gen_random_uuid(),
  package_id uuid not null references public.packages(id) on delete restrict,
  changed_by uuid not null references public.profiles(id) on delete restrict,
  reason text not null,
  old_capacity_verified boolean not null,
  old_max_guest_count integer,
  new_capacity_verified boolean not null,
  new_max_guest_count integer,
  verification_source text not null default 'authenticated_admin_rpc',
  changed_at timestamptz not null default now()
);
alter table public.evently_pool_capacity_audit
  add column if not exists verification_source text not null default 'authenticated_admin_rpc';
do $$
begin
  if exists(select 1 from public.evently_pool_capacity_audit where changed_by is null) then
    raise exception 'Capacity audit contains rows without an authenticated Administrator; reconcile them before enabling the RPC';
  end if;
  if exists(select 1 from public.evently_pool_capacity_audit where verification_source is null) then
    raise exception 'Capacity audit contains rows without a verification source; reconcile them before enabling the RPC';
  end if;
  alter table public.evently_pool_capacity_audit alter column changed_by set not null;
  alter table public.evently_pool_capacity_audit alter column verification_source set default 'authenticated_admin_rpc';
  alter table public.evently_pool_capacity_audit alter column verification_source set not null;
  if (select count(*) from information_schema.columns where table_schema='public'
      and table_name='evently_pool_capacity_audit'
      and column_name in ('id','package_id','changed_by','reason','old_capacity_verified',
        'old_max_guest_count','new_capacity_verified','new_max_guest_count','verification_source','changed_at'))<>10 then
    raise exception 'Capacity audit schema is incomplete; stop and reconcile before installing pricing functions';
  end if;
end;
$$;
alter table public.packages add column if not exists pool_capacity_audit_id uuid
  references public.evently_pool_capacity_audit(id);
-- Never inherit a legacy boolean as proof of physical capacity. Keep only
-- package flags backed by a matching authenticated Administrator audit row.
update public.packages package
set pool_capacity_verified=false,
    pool_capacity_verified_at=null,
    pool_capacity_verified_by=null,
    pool_capacity_audit_id=null,
    updated_at=now()
where package.id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
  and package.pool_capacity_verified
  and not exists(select 1 from public.evently_pool_capacity_audit audit
    where audit.id=package.pool_capacity_audit_id and audit.package_id=package.id
       and audit.changed_by=package.pool_capacity_verified_by
       and audit.new_capacity_verified
       and audit.new_max_guest_count is not distinct from package.max_guest_count
       and audit.verification_source='authenticated_admin_rpc');
do $$
begin
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.packages'::regclass
    and conname='packages_pool_capacity_audit_state_check') then
    alter table public.packages add constraint packages_pool_capacity_audit_state_check
      check(not pool_capacity_verified or (max_guest_count is not null
        and max_guest_count>=min_guest_count and pool_capacity_verified_at is not null
        and pool_capacity_verified_by is not null and pool_capacity_audit_id is not null)) not valid;
  end if;
end;
$$;
alter table public.packages validate constraint packages_pool_capacity_audit_state_check;
alter table public.evently_pool_capacity_audit enable row level security;
revoke all on public.evently_pool_capacity_audit from public,anon,authenticated;
grant select on public.evently_pool_capacity_audit to authenticated;
drop policy if exists "Administrator reads pool capacity audit" on public.evently_pool_capacity_audit;
create policy "Administrator reads pool capacity audit" on public.evently_pool_capacity_audit
  for select to authenticated using(public.is_evently_admin());

-- Preserve the complete add-on catalog row before adding Resort compatibility.
insert into public.evently_schedule_hold_catalog_backup(entity_type,entity_key,row_data)
select 'addon',addon.id::text,to_jsonb(addon) from public.addons addon
where addon.id in ('1e97b2bf-ca43-492a-8a15-2d20f6abf040','928c269f-c38a-4345-86a5-d1f4c65555f0')
on conflict(entity_type,entity_key) do nothing;

-- These existing cottage IDs are the verified add-ons for Resort Swimming Tours.
-- Add Resort compatibility without removing any other configured service.
update public.addons addon
set compatible_services=(
  select array_agg(normalized.service order by normalized.service)
  from (
    select lower(trim(service)) as service
    from unnest(coalesce(addon.compatible_services,array[]::text[])||array['resort']::text[]) as services(service)
    where nullif(trim(service),'') is not null
    group by lower(trim(service))
  ) normalized
),updated_at=now()
  where (addon.id='1e97b2bf-ca43-492a-8a15-2d20f6abf040' and addon.is_active and addon.price=700)
   or (addon.id='928c269f-c38a-4345-86a5-d1f4c65555f0' and addon.is_active and addon.price=1000);

-- Preserve the per-person rate schedule and guest minimums without staging a
-- maximum. Each package remains unverified until an Administrator records the
-- physical limit. Never infer this value from legacy guest_capacity.
update public.packages set min_guest_count=20,max_guest_count=null,
  cottage_fee=700,cottage_addon_id='1e97b2bf-ca43-492a-8a15-2d20f6abf040',
  pool_access_fee=0,pool_capacity_verified=false,pool_capacity_verified_at=null,
  pool_capacity_verified_by=null,pool_capacity_audit_id=null,updated_at=now()
where id in ('4ae972a8-6503-4776-90c9-899246cbc4dc','5afda244-a615-4bd3-98eb-d360d000100b')
  and is_active and lower(service_type::text)='resort';
update public.packages set min_guest_count=20,max_guest_count=null,
  cottage_fee=1000,cottage_addon_id='928c269f-c38a-4345-86a5-d1f4c65555f0',
  pool_access_fee=0,pool_capacity_verified=false,pool_capacity_verified_at=null,
  pool_capacity_verified_by=null,pool_capacity_audit_id=null,updated_at=now()
where id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
  and is_active and lower(service_type::text)='resort';
do $$
begin
  if (select count(*) from public.packages where
       (id='4ae972a8-6503-4776-90c9-899246cbc4dc' and is_active and min_guest_count=20 and max_guest_count is null and not pool_capacity_verified)
        or (id='5afda244-a615-4bd3-98eb-d360d000100b' and is_active and min_guest_count=20 and max_guest_count is null and not pool_capacity_verified)
        or (id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8' and is_active and min_guest_count=20 and max_guest_count is null and not pool_capacity_verified))<>3 then
    raise exception 'Pool tour minimum guest counts did not synchronize';
  end if;
  if (select count(*) from public.packages where
       (id in ('4ae972a8-6503-4776-90c9-899246cbc4dc','5afda244-a615-4bd3-98eb-d360d000100b')
         and cottage_fee=700 and cottage_addon_id='1e97b2bf-ca43-492a-8a15-2d20f6abf040' and pool_access_fee=0)
       or (id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
         and cottage_fee=1000 and cottage_addon_id='928c269f-c38a-4345-86a5-d1f4c65555f0' and pool_access_fee=0))<>3 then
    raise exception 'Pool cottage IDs/fees or no-Pool-Access rule did not synchronize';
  end if;
  if (select count(*) from public.addons where
       (id='1e97b2bf-ca43-492a-8a15-2d20f6abf040' and is_active and price=700
          and 'resort'=any(compatible_services))
       or (id='928c269f-c38a-4345-86a5-d1f4c65555f0' and is_active and price=1000
          and 'resort'=any(compatible_services))<>2 then
    raise exception 'Verified cottage add-ons must be active, correctly priced, and compatible with Resort';
  end if;
end;
$$;

-- If the earlier draft schedule migration backed up then nulled the legacy
-- guest_capacity value, restore that exact snapshot. This value remains legacy
-- metadata and is not used as a pool maximum by the repaired wrapper.
do $$
begin
  if to_regclass('public.evently_schedule_hold_catalog_backup') is not null then
    update public.packages package
    set guest_capacity=nullif(backup.row_data->>'guest_capacity','')::integer,
        updated_at=now()
    from public.evently_schedule_hold_catalog_backup backup
    where backup.entity_type='package' and backup.entity_key=package.id::text
      and package.id in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
        '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
      and package.guest_capacity is null
      and backup.row_data ? 'guest_capacity'
      and nullif(backup.row_data->>'guest_capacity','') is not null;
  end if;
end;
$$;

-- This helper calculates the established per-guest amount only. Physical
-- capacity is enforced by evently_pool_tour_total after its audit checks.
create or replace function public.evently_pool_tour_unit_rate(p_package_id uuid)
returns numeric(12,2) language sql immutable strict set search_path = '' as $$
  select case p_package_id
    when '4ae972a8-6503-4776-90c9-899246cbc4dc'::uuid then 100::numeric
    when '5afda244-a615-4bd3-98eb-d360d000100b'::uuid then 150::numeric
    when '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'::uuid then 200::numeric
    else null::numeric end;
$$;

create or replace function public.evently_pool_tour_amount(
  p_package_id uuid,p_guest_count integer,p_cottage_addon_id uuid default null
) returns numeric(12,2) language plpgsql security definer set search_path = '' as $$
declare v_package public.packages%rowtype; v_rate numeric(12,2); v_min integer;
  v_cottage_id uuid; v_cottage_fee numeric(12,2); v_addon_price numeric(12,2):=0;
begin
  select * into v_package from public.packages where id=p_package_id and is_active for share;
  if not found or lower(coalesce(v_package.package_category,''))<>'pool_tour'
    or v_package.pricing_mode<>'per_guest' then raise exception 'The selected package is not a configured pool tour'; end if;
  v_rate:=public.evently_pool_tour_unit_rate(p_package_id);
  case p_package_id
    when '4ae972a8-6503-4776-90c9-899246cbc4dc'::uuid then v_min:=20; v_cottage_id:='1e97b2bf-ca43-492a-8a15-2d20f6abf040'; v_cottage_fee:=700;
    when '5afda244-a615-4bd3-98eb-d360d000100b'::uuid then v_min:=20; v_cottage_id:='1e97b2bf-ca43-492a-8a15-2d20f6abf040'; v_cottage_fee:=700;
    when '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'::uuid then v_min:=20; v_cottage_id:='928c269f-c38a-4345-86a5-d1f4c65555f0'; v_cottage_fee:=1000;
    else raise exception 'Pool package ID is not in the verified tour schedule';
  end case;
  if v_rate is null or v_package.min_guest_count<>v_min
    or v_package.cottage_addon_id is distinct from v_cottage_id
    or v_package.cottage_fee is distinct from v_cottage_fee
    or v_package.deposit_percentage is distinct from 30 then
    raise exception 'Per-person rate/minimum/cottage/deposit catalog differs from verified tour configuration';
  end if;
  if p_guest_count is null or p_guest_count<v_min then raise exception 'This tour requires at least % guests',v_min; end if;
  if p_cottage_addon_id is not null then
    if p_cottage_addon_id is distinct from v_cottage_id then raise exception 'Selected cottage is not configured for this tour'; end if;
    select addon.price into v_addon_price from public.addons addon
    where addon.id=p_cottage_addon_id and addon.is_active and addon.price=v_cottage_fee
      and exists(select 1 from unnest(addon.compatible_services) as compatibility(service_name)
        where lower(trim(service_name))=lower(v_package.service_type::text))
    for share;
    if not found then raise exception 'Verified cottage add-on is unavailable'; end if;
  end if;
  return round(v_rate*p_guest_count+v_addon_price,2);
end;
$$;
revoke all on function public.evently_pool_tour_unit_rate(uuid) from public,anon,authenticated;
revoke all on function public.evently_pool_tour_amount(uuid,integer,uuid) from public,anon,authenticated;

create or replace function public.evently_pool_tour_total(
  p_package_id uuid,p_guest_count integer,p_cottage_addon_id uuid default null
) returns numeric(12,2) language plpgsql security definer set search_path = '' as $$
declare v_package public.packages%rowtype;
begin
  select * into v_package from public.packages where id=p_package_id and is_active for share;
  if not found then raise exception 'Pool tour package is unavailable'; end if;
  if not v_package.pool_capacity_verified
      or v_package.pool_capacity_verified_at is null
      or v_package.pool_capacity_audit_id is null
      or v_package.pool_capacity_verified_by is null
      or v_package.max_guest_count is null
      or v_package.max_guest_count < v_package.min_guest_count
      or not exists(select 1 from public.evently_resources resource
        where resource.resource_key=v_package.resource_key
          and resource.resource_key='venice-main-pool'
          and resource.is_active and resource.is_exclusive
          and resource.capacity=v_package.max_guest_count)
      or not exists(select 1 from public.evently_pool_capacity_audit audit
        where audit.id=v_package.pool_capacity_audit_id and audit.package_id=v_package.id
          and audit.changed_by=v_package.pool_capacity_verified_by
          and audit.new_capacity_verified
          and audit.new_max_guest_count is not distinct from v_package.max_guest_count
          and audit.verification_source='authenticated_admin_rpc') then
    raise exception 'Pool bookings are paused until an Administrator verifies physical capacity';
  end if;
  if p_guest_count is null or p_guest_count < v_package.min_guest_count then
    raise exception 'This tour requires at least % guests',v_package.min_guest_count;
  end if;
  if p_guest_count > v_package.max_guest_count then
    raise exception 'Guest count exceeds the verified physical maximum of %',v_package.max_guest_count;
  end if;
  if v_package.price is distinct from public.evently_pool_tour_unit_rate(p_package_id)
    or v_package.deposit_percentage is distinct from 30 then
    raise exception 'Pool unit-price/deposit catalog has not been synchronized';
  end if;
  return public.evently_pool_tour_amount(p_package_id,p_guest_count,p_cottage_addon_id);
end;
$$;
revoke all on function public.evently_pool_tour_total(uuid,integer,uuid) from public,anon,authenticated;

-- No limit is inferred from legacy guest_capacity. An authorized Administrator
-- must explicitly verify and audit the actual physical maximum before booking.
create or replace function public.evently_admin_set_pool_capacity(
  p_package_id uuid,p_capacity_verified boolean,p_max_guest_count integer,p_reason text
) returns void language plpgsql security definer set search_path = '' as $$
declare v_package public.packages%rowtype; v_audit_id uuid;
begin
  if not public.is_evently_admin() then raise exception 'Administrator access required'; end if;
  if auth.uid() is null then raise exception 'Authenticated Administrator identity is required'; end if;
  if nullif(btrim(p_reason),'') is null or length(btrim(p_reason))>2000 then
    raise exception 'A capacity verification note of 1 to 2000 characters is required';
  end if;
  select * into v_package from public.packages where id=p_package_id and is_active for update;
  if not found or lower(coalesce(v_package.package_category,''))<>'pool_tour' then
    raise exception 'Select an active verified pool-tour package';
  end if;
  if v_package.resource_key is distinct from 'venice-main-pool'
     or v_package.resource_mode is distinct from 'exclusive' then
    raise exception 'Pool capacity can be verified only for a package linked to the active exclusive physical pool resource';
  end if;
  perform 1 from public.evently_resources resource
    where resource.resource_key=v_package.resource_key and resource.is_active and resource.is_exclusive
    for update;
  if not found then
    raise exception 'Pool capacity can be verified only for a package linked to the active exclusive physical pool resource';
  end if;
  if p_capacity_verified is distinct from true and p_max_guest_count is not null then
    raise exception 'An unverified capacity must not include a maximum guest count';
  end if;
  if p_capacity_verified
     and (p_max_guest_count is null or p_max_guest_count < v_package.min_guest_count) then
    raise exception 'Enter the actual physical maximum; it must be at least the package minimum of % guests',v_package.min_guest_count;
  end if;
  if p_max_guest_count is not null and p_max_guest_count<v_package.min_guest_count then
    raise exception 'Verified maximum cannot be below the package minimum guest count';
  end if;
  if p_capacity_verified and exists(select 1 from public.packages sibling
      where sibling.id<>p_package_id
        and sibling.package_category='pool_tour'
        and sibling.resource_key=v_package.resource_key
        and sibling.pool_capacity_verified
        and sibling.max_guest_count is distinct from p_max_guest_count) then
    raise exception 'All verified tours sharing the physical pool must use the same maximum; withdraw the other tour verifications before changing it';
  end if;
  insert into public.evently_pool_capacity_audit(
    package_id,changed_by,reason,old_capacity_verified,old_max_guest_count,
    new_capacity_verified,new_max_guest_count,verification_source
  ) values(p_package_id,auth.uid(),btrim(p_reason),v_package.pool_capacity_verified,
    v_package.max_guest_count,coalesce(p_capacity_verified,false),
    case when p_capacity_verified then p_max_guest_count else null end,'authenticated_admin_rpc')
  returning id into v_audit_id;
  update public.packages set
    pool_capacity_verified=coalesce(p_capacity_verified,false),
    max_guest_count=case when p_capacity_verified then p_max_guest_count else null end,
    pool_capacity_verified_at=case when p_capacity_verified then now() else null end,
    pool_capacity_verified_by=case when p_capacity_verified then auth.uid() else null end,
    pool_capacity_audit_id=v_audit_id,
    updated_at=now()
  where id=p_package_id;
  if p_capacity_verified then
    update public.evently_resources set capacity=p_max_guest_count,updated_at=now()
    where resource_key=v_package.resource_key;
  elsif not exists(select 1 from public.packages sibling
      where sibling.package_category='pool_tour'
        and sibling.resource_key=v_package.resource_key
        and sibling.pool_capacity_verified) then
    update public.evently_resources set capacity=null,updated_at=now()
    where resource_key=v_package.resource_key;
  end if;
  insert into public.admin_activity_logs(admin_id,action,entity_type,entity_id,description)
  values(auth.uid(),'pool_capacity_'||case when p_capacity_verified then 'verified' else 'cleared' end,
    'package',p_package_id,btrim(p_reason));
end;
$$;
revoke all on function public.evently_admin_set_pool_capacity(uuid,boolean,integer,text) from public,anon;
grant execute on function public.evently_admin_set_pool_capacity(uuid,boolean,integer,text) to authenticated;

-- Repair only the outer resource-pricing wrapper. The exact-resource, catalog,
-- transaction, idempotency, payment-deadline, availability, and concurrency
-- implementations remain delegated to the already installed audited RPC.
create or replace function public.create_evently_reservation_before_exact_resource_assignment(p_booking jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_package public.packages%rowtype; v_existing_id uuid; v_result jsonb; v_payload jsonb;
  v_reservation_id uuid; v_order_id uuid; v_guest_count integer;
  v_cottage_selected boolean:=coalesce(nullif(p_booking->>'cottage_selected','')::boolean,false);
  v_requested_cottage uuid:=nullif(p_booking->>'cottage_addon_id','')::uuid;
  v_base_cottage numeric(12,2); v_addon_total numeric(12,2):=0; v_total numeric(12,2);
  v_deposit numeric(12,2); v_cottage_fee numeric(12,2):=0; v_amount_paid numeric(12,2):=0;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if jsonb_typeof(p_booking) is distinct from 'object' or nullif(p_booking->>'idempotency_key','') is null then
    raise exception 'Booking details and idempotency key are required';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evently-booking:'||auth.uid()::text||':'||(p_booking->>'idempotency_key'),0));
  select id into v_existing_id from public.reservations where customer_id=auth.uid()
    and client_request_id=(p_booking->>'idempotency_key')::uuid;
  if v_existing_id is not null then
    return public.create_evently_reservation_before_verified_pool_tour_pricing(p_booking);
  end if;
  select * into v_package from public.packages where id=nullif(p_booking->>'package_id','')::uuid and is_active for share;
  if not found then raise exception 'The selected package is unavailable'; end if;
  if lower(coalesce(v_package.package_category,''))<>'pool_tour' then
    return public.create_evently_reservation_before_verified_pool_tour_pricing(p_booking);
  end if;
  if nullif(p_booking->>'package_variant_id','') is not null then raise exception 'Pool tour variants are not configured'; end if;
  v_guest_count:=nullif(p_booking->>'guest_count','')::integer;
  if (v_cottage_selected and v_requested_cottage is null) or (not v_cottage_selected and v_requested_cottage is not null) then
    raise exception 'Cottage ID is required only when the compatible cottage is selected';
  end if;
  if coalesce(nullif(p_booking->>'pool_access_selected','')::boolean,false) or v_package.pool_access_fee<>0 then
    raise exception 'Pool access cannot be charged a second time';
  end if;
  v_base_cottage:=public.evently_pool_tour_total(v_package.id,v_guest_count,
    case when v_cottage_selected then v_requested_cottage else null end);
  if v_cottage_selected then v_cottage_fee:=v_package.cottage_fee; end if;
  if jsonb_typeof(coalesce(p_booking->'addons','[]'::jsonb)) is distinct from 'array' then
    raise exception 'Add-on selection must be an array';
  end if;
  if exists(select 1 from jsonb_array_elements(coalesce(p_booking->'addons','[]'::jsonb)) as selected(value)
    join public.addons catalog_addon on catalog_addon.id=nullif(selected.value->>'id','')::uuid
    where lower(catalog_addon.name) like '%pool%access%') then
    raise exception 'Pool Access is not available for Swimming Tour bookings';
  end if;
  if v_package.cottage_addon_id is not null and exists(
    select 1 from jsonb_array_elements(coalesce(p_booking->'addons','[]'::jsonb)) as selected(value)
    join public.addons catalog_addon on catalog_addon.id=nullif(selected.value->>'id','')::uuid
    where catalog_addon.id=v_package.cottage_addon_id or lower(catalog_addon.name) like '%cottage%'
  ) then raise exception 'Cottage can only be selected through the package cottage option, not as a generic add-on'; end if;

  -- Legacy RPCs still enforce guest_capacity. Pass the minimum safe sentinel
  -- to that internal calculator only; the capacity-safe total above validates
  -- the real count, which is written to reservation/order snapshots below.
  v_payload:=jsonb_set(p_booking,'{guest_count}',to_jsonb(1),true);
  v_result:=public.create_evently_reservation_before_verified_pool_tour_pricing(v_payload);
  v_reservation_id:=nullif(v_result->>'reservation_id','')::uuid;
  if v_reservation_id is null then raise exception 'The existing booking RPC did not return a reservation'; end if;
  if exists(select 1 from public.reservation_addons addon where addon.reservation_id=v_reservation_id
    and addon.addon_id=v_package.cottage_addon_id) then raise exception 'Cottage was duplicated in generic add-ons'; end if;
  select id into v_order_id from public.orders where reservation_id=v_reservation_id and customer_id=auth.uid() limit 1;
  if v_order_id is null then raise exception 'Reservation is not linked to an order'; end if;
  select coalesce(sum(addon.price*coalesce(addon.quantity,1)),0) into v_addon_total
    from public.reservation_addons addon where addon.reservation_id=v_reservation_id;
  v_total:=round(v_base_cottage+v_addon_total,2);
  v_deposit:=round(v_total*0.30,2);
  update public.reservations set guest_count=v_guest_count,pricing_mode='per_guest',
    subtotal=v_total,total_amount=v_total,deposit_amount=v_deposit,
    remaining_balance=greatest(v_total-amount_paid,0),tour_slot=v_package.name,
    cottage_selected=v_cottage_selected,cottage_fee=v_cottage_fee,
    cottage_addon_id=case when v_cottage_selected then v_package.cottage_addon_id else null end,
    pool_access_selected=false,pool_access_fee=0,updated_at=now()
  where id=v_reservation_id and customer_id=auth.uid();
  update public.orders set guest_count=v_guest_count,total_amount=v_total,
    remaining_balance=greatest(v_total-amount_paid,0),tour_slot=v_package.name,
    cottage_selected=v_cottage_selected,cottage_fee=v_cottage_fee,
    cottage_addon_id=case when v_cottage_selected then v_package.cottage_addon_id else null end,
    pool_access_selected=false,pool_access_fee=0,updated_at=now()
  where reservation_id=v_reservation_id and customer_id=auth.uid();
  select amount_paid into v_amount_paid from public.reservations where id=v_reservation_id;
  return v_result||jsonb_build_object('reservation_id',v_reservation_id,'order_id',v_order_id,
    'guest_count',v_guest_count,'subtotal',v_total,'total_amount',v_total,'deposit_amount',v_deposit,
    'remaining_balance',greatest(v_total-coalesce(v_amount_paid,0),0),'tour_slot',v_package.name,
    'cottage_fee',v_cottage_fee,'pool_access_fee',0,
    'cottage_addon_id',case when v_cottage_selected then v_package.cottage_addon_id else null end);
end;
$$;
revoke all on function public.create_evently_reservation_before_exact_resource_assignment(jsonb) from public,anon,authenticated;
-- Remove the short-lived emergency guard only after the authoritative wrapper
-- has been installed inside this transaction.
drop trigger if exists evently_pool_pricing_emergency_guard on public.reservations;

-- Verify server-side formulas while the legacy stored price is unchanged.
do $$
declare v_error text;
begin
  if public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,null)<>2000
     or public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',25,null)<>2500
     or public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',50,null)<>5000
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',20,null)<>3000
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',25,null)<>3750
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',50,null)<>7500
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,null)<>4000
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',25,null)<>5000
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',50,null)<>10000
      or public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,'1e97b2bf-ca43-492a-8a15-2d20f6abf040')<>2700
      or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',20,'1e97b2bf-ca43-492a-8a15-2d20f6abf040')<>3700
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,'928c269f-c38a-4345-86a5-d1f4c65555f0')<>5000 then
    raise exception 'Per-person pricing calculator verification failed; stored package rates remain unchanged';
  end if;
  v_error:=null;
  begin perform public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',19,null);
  exception when raise_exception then get stacked diagnostics v_error=message_text; end;
  if coalesce(v_error,'') not like '%at least 20%' then raise exception 'Overnight minimum guest verification failed'; end if;
  v_error:=null;
  begin perform public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',19,null);
  exception when raise_exception then get stacked diagnostics v_error=message_text; end;
  if coalesce(v_error,'') not like '%at least 20%' then raise exception 'Day Tour minimum guest verification failed'; end if;
  v_error:=null;
  begin perform public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',19,null);
  exception when raise_exception then get stacked diagnostics v_error=message_text; end;
  if coalesce(v_error,'') not like '%at least 20%' then raise exception 'Night Tour minimum guest verification failed'; end if;
  if round(public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,null)*0.30,2)<>600
     or round(public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',20,null)*0.30,2)<>900
     or round(public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,null)*0.30,2)<>1200 then
    raise exception '30-percent pool deposit verification failed';
  end if;
end;
$$;

-- Only after the server pricing functions and outer wrapper are installed and
-- the formula assertions pass, store the verified unit rates. guest_capacity
-- and max_guest_count are not modified here.
update public.packages set price=100,updated_at=now() where id='4ae972a8-6503-4776-90c9-899246cbc4dc' and is_active;
update public.packages set price=150,updated_at=now() where id='5afda244-a615-4bd3-98eb-d360d000100b' and is_active;
update public.packages set price=200,updated_at=now() where id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8' and is_active;
do $$
begin
  if (select count(*) from public.packages where
      (id='4ae972a8-6503-4776-90c9-899246cbc4dc' and price=100)
      or (id='5afda244-a615-4bd3-98eb-d360d000100b' and price=150)
      or (id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8' and price=200))<>3 then
    raise exception 'Unit prices did not synchronize after calculator verification';
  end if;
end;
$$;

-- Physical capacity remains blocked until an authenticated Administrator records
-- an Administrator records each actual physical maximum through the audited RPC.

do $$
declare v_error text; v_capacity record;
begin
   if public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,null)<>2000
     or public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',50,null)<>5000
      or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',20,null)<>3000
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',50,null)<>7500 then
     raise exception 'Day/Night per-guest price calculations differ';
  end if;
   v_error:=null;
   begin perform public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',19,null);
   exception when raise_exception then get stacked diagnostics v_error=message_text; end;
   if coalesce(v_error,'') not like '%at least 20%' then raise exception 'Day Tour below-minimum test failed'; end if;
   v_error:=null;
   begin perform public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',19,null);
   exception when raise_exception then get stacked diagnostics v_error=message_text; end;
   if coalesce(v_error,'') not like '%at least 20%' then raise exception 'Night Tour below-minimum test failed'; end if;
   v_error:=null;
   begin perform public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',19,null);
   exception when raise_exception then get stacked diagnostics v_error=message_text; end;
   if coalesce(v_error,'') not like '%at least 20%' then raise exception 'Overnight below-minimum test failed'; end if;
  if public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,null)<>2000
     or public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',50,null)<>5000
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',20,null)<>3000
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',50,null)<>7500
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,null)<>4000
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',50,null)<>10000 then
     raise exception 'Pool per-guest price calculations for 20 and 50 guests differ';
  end if;
  if public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',51,null)<>5100
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',51,null)<>7650
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',51,null)<>10200 then
    raise exception 'Per-guest amount calculation must remain independent from physical capacity verification';
  end if;
  for v_capacity in select id,min_guest_count from public.packages where id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8') and not pool_capacity_verified
  loop
    v_error:=null;
    begin perform public.evently_pool_tour_total(v_capacity.id,v_capacity.min_guest_count,null);
    exception when raise_exception then get stacked diagnostics v_error=message_text; end;
    if coalesce(v_error,'') not like '%capacity%' then
      raise exception 'Pool package % did not fail closed while its physical capacity remains unverified',v_capacity.id;
    end if;
  end loop;
end;
$$;
notify pgrst,'reload schema';
commit;
