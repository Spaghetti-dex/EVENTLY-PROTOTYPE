-- EVENTLY: automatic schedule holds, 24-hour payment deadlines, expiry, and
-- auditable Administrator-only overrides. Apply for review; do not auto-apply.
-- This migration wraps the established booking/payment RPC chain and preserves
-- historical reservations, payment rows, totals, and service-specific pricing.

begin;

alter table public.reservations
  add column if not exists payment_due_at timestamptz,
  add column if not exists expired_at timestamptz,
  add column if not exists cottage_addon_id uuid references public.addons(id);

alter table public.orders
  add column if not exists cottage_addon_id uuid references public.addons(id);

alter table public.packages
  add column if not exists pricing_mode text not null default 'per_booking',
  add column if not exists min_guest_count integer not null default 1,
  add column if not exists max_guest_count integer,
  add column if not exists pool_capacity_verified boolean not null default false,
  add column if not exists pool_capacity_verified_at timestamptz,
  add column if not exists pool_capacity_verified_by uuid references public.profiles(id),
  add column if not exists cottage_fee numeric(12,2) not null default 0,
  add column if not exists cottage_addon_id uuid references public.addons(id),
  add column if not exists pool_access_fee numeric(12,2) not null default 0;

-- Preserve the existing per_booking default and all stored pricing modes.
-- guest_capacity is legacy capacity metadata. Pool max_guest_count is separate;
-- NULL max plus pool_capacity_verified=false means the pool is not bookable
-- until the physical capacity is confirmed. Preserve every guest_capacity value.
alter table public.packages drop constraint if exists packages_pricing_mode_check;
update public.packages set pricing_mode = 'per_booking' where pricing_mode is null;
update public.packages set min_guest_count = 1 where min_guest_count is null;
update public.packages set cottage_fee = 0 where cottage_fee is null;
update public.packages set pool_access_fee = 0 where pool_access_fee is null;
alter table public.packages
  alter column pricing_mode set default 'per_booking',
  alter column pricing_mode set not null,
  alter column min_guest_count set default 1,
  alter column min_guest_count set not null,
  alter column cottage_fee set default 0,
  alter column cottage_fee set not null,
  alter column pool_access_fee set default 0,
  alter column pool_access_fee set not null;

-- Replace the earlier draft constraint so a confirmed maximum can be staged
-- while the separate capacity-verification flag still keeps bookings blocked.
alter table public.packages drop constraint if exists packages_pool_capacity_verification_check;

-- Pool capacity remains unverified by default. The rate/package configuration
-- below must not turn an unknown maximum into an implied unlimited capacity.

do $$
begin
  if exists(select 1 from public.packages
    where pricing_mode not in ('per_booking','fixed','per_guest','per_night')) then
    raise exception 'Unsupported existing package pricing_mode value; preserve and reconcile it before applying schedule holds';
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint
    where conname = 'packages_min_guest_count_check' and conrelid = 'public.packages'::regclass) then
    alter table public.packages add constraint packages_min_guest_count_check
      check (min_guest_count >= 1) not valid;
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint
    where conname = 'packages_max_guest_count_check' and conrelid = 'public.packages'::regclass) then
    alter table public.packages add constraint packages_max_guest_count_check
      check (max_guest_count is null or max_guest_count >= min_guest_count) not valid;
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint
    where conname = 'packages_cottage_fee_nonnegative' and conrelid = 'public.packages'::regclass) then
    alter table public.packages add constraint packages_cottage_fee_nonnegative
      check (cottage_fee >= 0) not valid;
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint
    where conname = 'packages_pool_access_fee_nonnegative' and conrelid = 'public.packages'::regclass) then
    alter table public.packages add constraint packages_pool_access_fee_nonnegative
      check (pool_access_fee >= 0) not valid;
  end if;
end;
$$;

alter table public.packages add constraint packages_pricing_mode_check
  check(pricing_mode in ('per_booking','fixed','per_guest','per_night')) not valid;

alter table public.packages add constraint packages_pool_capacity_verification_check
  check (pool_capacity_verified or (pool_capacity_verified_at is null and pool_capacity_verified_by is null)) not valid;

alter table public.packages validate constraint packages_pricing_mode_check;
alter table public.packages validate constraint packages_min_guest_count_check;
alter table public.packages validate constraint packages_max_guest_count_check;
alter table public.packages validate constraint packages_pool_capacity_verification_check;
alter table public.packages validate constraint packages_cottage_fee_nonnegative;
alter table public.packages validate constraint packages_pool_access_fee_nonnegative;

-- Fail closed unless the audited single-argument booking/payment call chain is
-- present. The migration wraps these signatures; it does not replace them with
-- simplified RPCs or alter an unexpected overload.
do $$
declare
  v_function_name text;
  v_function_count integer;
begin
  foreach v_function_name in array array[
    'create_evently_reservation', 'submit_evently_payment', 'admin_review_payment',
    'evently_admin_approve_booking', 'admin_transition_reservation',
    'evently_admin_set_reservation_schedule', 'evently_check_availability'
  ] loop
    select count(*) into v_function_count from pg_catalog.pg_proc proc
    join pg_catalog.pg_namespace ns on ns.oid = proc.pronamespace
    where ns.nspname = 'public' and proc.proname = v_function_name and proc.prokind = 'f';
    if v_function_count <> 1 then
      raise exception 'Expected exactly one public.% overload before migration; found %', v_function_name, v_function_count;
    end if;
  end loop;
  if (select count(*) from pg_catalog.pg_proc proc
      join pg_catalog.pg_namespace ns on ns.oid = proc.pronamespace
      where ns.nspname = 'public' and proc.proname = 'create_evently_reservation'
        and proc.prokind = 'f') <> 1
     or to_regprocedure('public.create_evently_reservation(jsonb)') is null
     or to_regprocedure('public.create_evently_reservation_before_exact_resource_assignment(jsonb)') is null
     or to_regprocedure('public.create_evently_reservation_before_payment_submission(jsonb)') is null
     or to_regprocedure('public.admin_review_payment(uuid,text,text)') is null
     or to_regprocedure('public.submit_evently_payment(uuid,numeric,text,text,text)') is null
     or to_regprocedure('public.evently_admin_check_reservation_schedule(uuid)') is null
     or to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)') is null
     or to_regprocedure('public.admin_transition_reservation(uuid,text,text)') is null
     or to_regprocedure('public.evently_existing_column(regclass,text[])') is null
     or to_regprocedure('public.evently_status_value(regclass,text,text)') is null then
    raise exception 'The audited booking, payment, Admin schedule, or status RPC chain differs from this migration; stop and reconcile deployed signatures before applying.';
  end if;
  if to_regclass('public.packages') is null
     or to_regclass('public.package_variants') is null
     or to_regclass('public.addons') is null
     or to_regclass('public.reservation_addons') is null
     or to_regclass('public.reservations') is null
     or to_regclass('public.orders') is null
     or to_regclass('public.payments') is null
     or to_regclass('public.profiles') is null
     or to_regclass('public.evently_resources') is null
     or to_regclass('public.admin_activity_logs') is null
     or to_regclass('public.notifications') is null
     or to_regclass('public.evently_business_settings') is null
     or to_regclass('public.evently_booking_recommendations') is null
     or to_regclass('public.evently_schedule_proposals') is null
     or to_regclass('storage.objects') is null
     or to_regclass('storage.buckets') is null then
    raise exception 'A required catalog, booking, Admin/Staff workflow, notification, or private storage object is missing';
  end if;
  if exists (
    select 1 from pg_catalog.pg_proc proc
    join pg_catalog.pg_namespace ns on ns.oid = proc.pronamespace
    where ns.nspname = 'public' and proc.prosecdef and proc.prokind in ('f', 'p')
      and proc.proname <> 'evently_admin_review_booking_recommendation'
      and position('public.evently_admin_approve_booking(' in lower(pg_catalog.pg_get_functiondef(proc.oid))) > 0
  ) then
    raise exception 'An additional SECURITY DEFINER caller of evently_admin_approve_booking exists; audit and migrate that caller before disabling manual approval.';
  end if;
  if exists (
    select 1 from pg_catalog.pg_proc proc
    join pg_catalog.pg_namespace ns on ns.oid = proc.pronamespace
    where ns.nspname = 'public' and proc.prosecdef and proc.prokind in ('f', 'p')
      and proc.proname not in ('evently_admin_approve_booking', 'evently_admin_review_booking_recommendation')
      and position('public.evently_admin_approve_booking_before_' in lower(pg_catalog.pg_get_functiondef(proc.oid))) > 0
  ) then
    raise exception 'An additional SECURITY DEFINER caller of a legacy approval layer exists; audit it before disabling manual approval.';
  end if;
  if exists (
    select 1 from pg_catalog.pg_proc proc
    join pg_catalog.pg_namespace ns on ns.oid = proc.pronamespace
    where ns.nspname = 'public' and proc.prosecdef and proc.prokind in ('f', 'p')
      and proc.proname <> 'evently_admin_decide_schedule_proposal'
      and position('public.evently_admin_set_reservation_schedule(' in lower(pg_catalog.pg_get_functiondef(proc.oid))) > 0
  ) then
    raise exception 'An additional SECURITY DEFINER caller of the legacy schedule RPC exists; migrate it to the audited override before revoking access.';
  end if;
end;
$$;

create index if not exists reservations_payment_due_pending_idx
  on public.reservations (payment_due_at)
  where payment_due_at is not null and expired_at is null;

create table if not exists public.evently_reservation_override_audit (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete restrict,
  admin_id uuid not null references public.profiles(id),
  action text not null,
  reason text not null,
  previous_values jsonb not null,
  new_values jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.evently_reservation_override_audit enable row level security;
drop policy if exists "Administrators read reservation override audit" on public.evently_reservation_override_audit;
create policy "Administrators read reservation override audit"
  on public.evently_reservation_override_audit for select to authenticated
  using (public.is_evently_admin());
revoke all on public.evently_reservation_override_audit from public, anon, authenticated;
grant select on public.evently_reservation_override_audit to authenticated;

-- Keep a private, one-time catalog snapshot so operators can reverse the
-- verified pool catalog mapping without guessing prior values.
create table if not exists public.evently_schedule_hold_catalog_backup (
  entity_type text not null,
  entity_key text not null,
  row_data jsonb not null,
  captured_at timestamptz not null default now(),
  primary key (entity_type, entity_key)
);
revoke all on public.evently_schedule_hold_catalog_backup from public, anon, authenticated;

comment on column public.reservations.payment_due_at is
  'For new bookings, server-calculated reservation.created_at + 24 hours; NULL preserves pre-migration legacy holds.';
comment on column public.reservations.expired_at is
  'Set once when an unpaid schedule hold expires; cancelled status releases the resource.';
comment on column public.packages.guest_capacity is
  'NULL means no configured maximum; pool tour guest minimums are enforced separately by min_guest_count.';

create or replace function public.evently_payment_deadline(p_created_at timestamptz)
returns timestamptz language sql immutable strict
set search_path = ''
as $$ select p_created_at + interval '24 hours'; $$;
revoke all on function public.evently_payment_deadline(timestamptz) from public, anon, authenticated;

-- The physical pool resource and fixed package times are business-verified
-- existing values. The migration may map tour packages to that resource but
-- never creates or changes the resource identity or configured times.
do $$
begin
  if not exists (
    select 1 from public.evently_resources
    where resource_key = 'venice-main-pool' and is_active
      and is_exclusive
      and (lower(resource_type) like '%pool%' or lower(resource_name) like '%pool%')
  ) then
    raise exception 'The verified active exclusive venice-main-pool resource is missing or mismatched; resolve the existing identity before applying.';
  end if;
  if not exists (select 1 from public.addons where id = '1e97b2bf-ca43-492a-8a15-2d20f6abf040' and is_active and price = 700)
     or not exists (select 1 from public.addons where id = '928c269f-c38a-4345-86a5-d1f4c65555f0' and is_active and price = 1000) then
    raise exception 'The verified active cottage add-ons and prices are required before applying.';
  end if;
  if exists (select 1 from public.packages where id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
  ) and nullif(trim(resource_key), '') is not null and lower(trim(resource_key)) <> 'venice-main-pool') then
    raise exception 'A verified pool tour points to another physical resource; reconcile that existing assignment before applying.';
  end if;
  if (select count(*) from public.packages where id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
   ) and is_active and lower(service_type::text) = 'resort'
     and ((resource_mode = 'shared_capacity' and resource_key is null and schedule_mode = 'fixed')
       or (resource_mode = 'exclusive' and resource_key = 'venice-main-pool'
         and schedule_mode in ('fixed','timed')))
     and deposit_percentage = 30) <> 3 then
     raise exception 'Pool packages must match the existing fixed schedule and either the legacy shared catalog or verified exclusive venice-main-pool mapping, with a 30% deposit.';
  end if;
  if exists (select 1 from public.packages where id = '4ae972a8-6503-4776-90c9-899246cbc4dc'
    and (coalesce(fixed_start_time, operating_start_time) is distinct from time '08:00'
      or coalesce(fixed_end_time, operating_end_time) is distinct from time '15:00'))
     or exists (select 1 from public.packages where id = '5afda244-a615-4bd3-98eb-d360d000100b'
    and (coalesce(fixed_start_time, operating_start_time) is distinct from time '16:00'
      or coalesce(fixed_end_time, operating_end_time) is distinct from time '22:00'))
     or exists (select 1 from public.packages where id = '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
    and (coalesce(fixed_start_time, operating_start_time) is distinct from time '19:00'
      or coalesce(fixed_end_time, operating_end_time) is distinct from time '04:00')) then
    raise exception 'The verified tour times differ from the business schedule; do not change schedules as part of this pricing migration.';
  end if;
  if exists (select 1 from public.package_variants where package_id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
  ) and is_active) then
    raise exception 'Pool packages have active variants; review their prices/capacities explicitly before applying the per-person migration.';
  end if;
  if exists (select 1 from public.packages where id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
  ) and guest_capacity is not null and guest_capacity < 1) then
    raise exception 'A legacy pool guest_capacity below one blocks the safe inner-RPC sentinel; reconcile it without interpreting it as a verified maximum.';
  end if;
  if exists (select 1 from public.reservations where package_id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
  ) and lower(status::text) not in ('cancelled', 'canceled', 'rejected', 'completed')
    and (reservation_date is null or start_time is null or end_time is null)) then
    raise exception 'An active pool reservation lacks a complete schedule; resolve it before enabling exclusive conflict enforcement.';
  end if;
  if exists (select 1 from public.reservations where package_id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
  ) and lower(status::text) not in ('cancelled', 'canceled', 'rejected', 'completed')
    and nullif(trim(resource_key), '') is not null and lower(trim(resource_key)) <> 'venice-main-pool') then
    raise exception 'An active pool reservation points to another resource; reconcile it before remapping package rows.';
  end if;
  insert into public.evently_schedule_hold_catalog_backup (entity_type, entity_key, row_data)
  select 'resource', resource_key, to_jsonb(resource)
  from public.evently_resources resource where resource_key = 'venice-main-pool'
  on conflict (entity_type, entity_key) do nothing;
  insert into public.evently_schedule_hold_catalog_backup (entity_type, entity_key, row_data)
  select 'package', package.id::text, to_jsonb(package)
  from public.packages package where package.id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
  )
  on conflict (entity_type, entity_key) do nothing;
end;
$$;

-- Install non-price pool metadata first. Link tours to the existing verified
-- exclusive pool resource, preserve fixed times and every guest_capacity value.
-- Do not stage a maximum: an Administrator must enter the actual physical limit.
update public.packages
set package_category='pool_tour',pricing_mode='per_guest',min_guest_count=1,max_guest_count=null,
    cottage_fee=700,cottage_addon_id='1e97b2bf-ca43-492a-8a15-2d20f6abf040',
    pool_access_fee=0,resource_key='venice-main-pool',resource_mode='exclusive',schedule_mode='fixed',
    pool_capacity_verified=false,pool_capacity_verified_at=null,pool_capacity_verified_by=null,updated_at=now()
where id='4ae972a8-6503-4776-90c9-899246cbc4dc'
  and lower(service_type::text)='resort' and is_active
  and name in ('Day Tour','Day Tour Swimming — Per Person');
update public.packages
set package_category='pool_tour',pricing_mode='per_guest',min_guest_count=1,max_guest_count=null,
    cottage_fee=700,cottage_addon_id='1e97b2bf-ca43-492a-8a15-2d20f6abf040',
    pool_access_fee=0,resource_key='venice-main-pool',resource_mode='exclusive',schedule_mode='fixed',
    pool_capacity_verified=false,pool_capacity_verified_at=null,pool_capacity_verified_by=null,updated_at=now()
where id='5afda244-a615-4bd3-98eb-d360d000100b'
  and lower(service_type::text)='resort' and is_active
  and name in ('Night Tour','Night Tour Swimming — Per Person');
update public.packages
set package_category='pool_tour',pricing_mode='per_guest',min_guest_count=20,max_guest_count=null,
    cottage_fee=1000,cottage_addon_id='928c269f-c38a-4345-86a5-d1f4c65555f0',
    pool_access_fee=0,resource_key='venice-main-pool',resource_mode='exclusive',schedule_mode='fixed',
    pool_capacity_verified=false,pool_capacity_verified_at=null,pool_capacity_verified_by=null,updated_at=now()
where id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
  and lower(service_type::text)='resort' and is_active
  and name in ('Overnight Tour','Overnight Swimming — Minimum 20 Guests');

-- Authoritative unit rates and amount calculator. This amount-only helper does
-- not imply that a booking is capacity-safe; the total RPC below separately
-- requires an Administrator-verified maximum/capacity policy.
create or replace function public.evently_pool_tour_unit_rate(p_package_id uuid)
returns numeric(12,2)
language sql immutable strict set search_path = ''
as $$
  select case p_package_id
    when '4ae972a8-6503-4776-90c9-899246cbc4dc'::uuid then 100::numeric
    when '5afda244-a615-4bd3-98eb-d360d000100b'::uuid then 150::numeric
    when '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'::uuid then 200::numeric
    else null::numeric
  end;
$$;

create or replace function public.evently_pool_tour_amount(
  p_package_id uuid,
  p_guest_count integer,
  p_cottage_addon_id uuid default null
) returns numeric(12,2)
language plpgsql security definer
set search_path = ''
as $$
declare
  v_package public.packages%rowtype;
  v_cottage_price numeric(12,2) := 0;
  v_expected_rate numeric(12,2);
  v_expected_minimum integer;
  v_expected_cottage_id uuid;
  v_expected_cottage_fee numeric(12,2);
begin
  select * into v_package from public.packages
  where id = p_package_id and is_active for share;
  if not found or lower(coalesce(v_package.package_category, '')) <> 'pool_tour'
     or v_package.pricing_mode <> 'per_guest' then
    raise exception 'The selected package is not configured as an active per-person pool tour';
  end if;
  v_expected_rate := public.evently_pool_tour_unit_rate(p_package_id);
  case p_package_id
    when '4ae972a8-6503-4776-90c9-899246cbc4dc'::uuid then
      v_expected_minimum := 1;
      v_expected_cottage_id := '1e97b2bf-ca43-492a-8a15-2d20f6abf040'; v_expected_cottage_fee := 700;
    when '5afda244-a615-4bd3-98eb-d360d000100b'::uuid then
      v_expected_minimum := 1;
      v_expected_cottage_id := '1e97b2bf-ca43-492a-8a15-2d20f6abf040'; v_expected_cottage_fee := 700;
    when '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'::uuid then
      v_expected_minimum := 20;
      v_expected_cottage_id := '928c269f-c38a-4345-86a5-d1f4c65555f0'; v_expected_cottage_fee := 1000;
    else raise exception 'This pool tour package ID is not part of the verified rate schedule';
  end case;
  if v_expected_rate is null
     or v_package.min_guest_count is distinct from v_expected_minimum
     or v_package.cottage_addon_id is distinct from v_expected_cottage_id
     or v_package.cottage_fee is distinct from v_expected_cottage_fee
     or v_package.deposit_percentage is distinct from 30 then
    raise exception 'The pool tour rate mapping, minimum, cottage mapping, or 30-percent deposit is not configured as verified';
  end if;
  if p_guest_count is null or p_guest_count < v_package.min_guest_count then
    raise exception 'This tour requires at least % guests', v_package.min_guest_count;
  end if;
  if p_cottage_addon_id is not null then
    if p_cottage_addon_id is distinct from v_package.cottage_addon_id then
      raise exception 'The selected cottage is not compatible with this tour';
    end if;
    select addon.price into v_cottage_price from public.addons addon
    where addon.id = p_cottage_addon_id and addon.is_active
      and addon.price > 0 and addon.price = v_package.cottage_fee
    for share;
    if not found then raise exception 'The configured cottage rate is unavailable'; end if;
  end if;
  return round(v_expected_rate * p_guest_count + v_cottage_price, 2);
end;
$$;
revoke all on function public.evently_pool_tour_unit_rate(uuid) from public, anon, authenticated;
revoke all on function public.evently_pool_tour_amount(uuid,integer,uuid) from public, anon, authenticated;

create or replace function public.evently_pool_tour_total(
  p_package_id uuid, p_guest_count integer, p_cottage_addon_id uuid default null
) returns numeric(12,2)
language plpgsql security definer set search_path = '' as $$
declare v_package public.packages%rowtype;
begin
  select * into v_package from public.packages where id=p_package_id and is_active for share;
  if not found then raise exception 'The selected pool package is unavailable'; end if;
  if not v_package.pool_capacity_verified then
    raise exception 'Pool bookings are paused until an Administrator verifies the physical capacity policy';
  end if;
  if v_package.max_guest_count is null
     or v_package.max_guest_count < v_package.min_guest_count then
    raise exception 'Pool bookings require an Administrator-verified physical maximum';
  end if;
  if p_guest_count is null or p_guest_count > v_package.max_guest_count then
    raise exception 'Guest count exceeds the verified physical maximum of %', v_package.max_guest_count;
  end if;
  if v_package.price is distinct from public.evently_pool_tour_unit_rate(p_package_id)
     or v_package.deposit_percentage is distinct from 30 then
    raise exception 'The per-person rate/deposit catalog has not been synchronized';
  end if;
  return public.evently_pool_tour_amount(p_package_id,p_guest_count,p_cottage_addon_id);
end;
$$;
revoke all on function public.evently_pool_tour_total(uuid,integer,uuid) from public, anon, authenticated;

-- Wrap, rather than replace, the existing exact-resource RPC. Its catalog/menu,
-- reservation/order, and idempotency behavior remains authoritative. This outer
-- pool-only adjustment guarantees the delegated total is per guest and that a
-- cottage is included once as a separate booking snapshot, never as a duplicate
-- generic reservation_addons entry.
do $$
begin
  if to_regprocedure('public.create_evently_reservation_before_verified_pool_tour_pricing(jsonb)') is null then
    alter function public.create_evently_reservation_before_exact_resource_assignment(jsonb)
      rename to create_evently_reservation_before_verified_pool_tour_pricing;
  end if;
end;
$$;
revoke all on function public.create_evently_reservation_before_verified_pool_tour_pricing(jsonb)
  from public, anon, authenticated;

create or replace function public.create_evently_reservation_before_exact_resource_assignment(p_booking jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_package public.packages%rowtype;
  v_existing_id uuid;
  v_result jsonb;
  v_payload jsonb;
  v_reservation_id uuid;
  v_order_id uuid;
  v_guest_count integer;
  v_cottage_selected boolean := coalesce(nullif(p_booking ->> 'cottage_selected', '')::boolean, false);
  v_requested_cottage uuid := nullif(p_booking ->> 'cottage_addon_id', '')::uuid;
  v_base_and_cottage numeric(12,2);
  v_addon_total numeric(12,2) := 0;
  v_total numeric(12,2);
  v_deposit numeric(12,2);
  v_cottage_fee numeric(12,2) := 0;
  v_amount_paid numeric(12,2) := 0;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if jsonb_typeof(p_booking) is distinct from 'object'
     or nullif(p_booking ->> 'idempotency_key', '') is null then
    raise exception 'Booking details and an idempotency key are required';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'evently-booking:' || auth.uid()::text || ':' || (p_booking ->> 'idempotency_key'), 0
  ));
  select id into v_existing_id from public.reservations
  where customer_id = auth.uid() and client_request_id = (p_booking ->> 'idempotency_key')::uuid;
  if v_existing_id is not null then
    return public.create_evently_reservation_before_verified_pool_tour_pricing(p_booking);
  end if;
  select * into v_package from public.packages
  where id = nullif(p_booking ->> 'package_id', '')::uuid and is_active for share;
  if not found then raise exception 'The selected package is unavailable'; end if;
  if lower(coalesce(v_package.package_category, '')) <> 'pool_tour' then
    return public.create_evently_reservation_before_verified_pool_tour_pricing(p_booking);
  end if;
  if (v_cottage_selected and v_requested_cottage is null)
     or (not v_cottage_selected and v_requested_cottage is not null) then
    raise exception 'Submit a cottage ID only when the compatible cottage is selected';
  end if;
  if nullif(p_booking ->> 'package_variant_id', '') is not null then
    raise exception 'Pool tour variants are not configured; select the verified tour package directly';
  end if;
  v_guest_count := nullif(p_booking ->> 'guest_count', '')::integer;
  v_base_and_cottage := public.evently_pool_tour_total(
    v_package.id, v_guest_count,
    case when v_cottage_selected then v_requested_cottage else null end
  );
  if v_cottage_selected then v_cottage_fee := v_package.cottage_fee; end if;
  if coalesce(nullif(p_booking ->> 'pool_access_selected', '')::boolean, false)
     or v_package.pool_access_fee <> 0 then
    raise exception 'Pool access is part of the selected tour and cannot be charged a second time';
  end if;

  -- The legacy delegated RPC treats guest_capacity as a maximum. For pool
  -- tours only, pass its minimum accepted sentinel (one guest) after this
  -- wrapper has independently checked the verified pool max and per-person
  -- amount. The persisted reservation/order snapshots are restored to the
  -- validated customer guest count below. Other services receive the original
  -- payload unchanged.
  v_payload := p_booking;
  if lower(coalesce(v_package.package_category,''))='pool_tour' then
    v_payload := jsonb_set(p_booking,'{guest_count}',to_jsonb(1),true);
  end if;
  v_result := public.create_evently_reservation_before_verified_pool_tour_pricing(v_payload);
  v_reservation_id := nullif(v_result ->> 'reservation_id', '')::uuid;
  if v_reservation_id is null then raise exception 'The booking RPC did not return a reservation'; end if;
  if v_package.cottage_addon_id is not null and exists (
    select 1 from public.reservation_addons addon
    where addon.reservation_id = v_reservation_id and addon.addon_id = v_package.cottage_addon_id
  ) then raise exception 'A package cottage cannot be submitted as a generic add-on; use the optional cottage selection only'; end if;
  select id into v_order_id from public.orders
  where reservation_id = v_reservation_id and customer_id = auth.uid() limit 1;
  if v_order_id is null then raise exception 'The reservation is not linked to an order'; end if;

  select coalesce(sum(addon.price * coalesce(addon.quantity, 1)), 0)
    into v_addon_total from public.reservation_addons addon
    where addon.reservation_id = v_reservation_id;
  v_total := round(v_base_and_cottage + v_addon_total, 2);
  if v_package.deposit_percentage is distinct from 30 then
    raise exception 'The verified pool package deposit must remain 30 percent';
  end if;
  v_deposit := round(v_total * v_package.deposit_percentage / 100, 2);

  update public.reservations set
    subtotal = v_total, total_amount = v_total, deposit_amount = v_deposit,
    remaining_balance = greatest(v_total - amount_paid, 0),
    guest_count = v_guest_count,
    pricing_mode = 'per_guest', tour_slot = v_package.name,
    cottage_selected = v_cottage_selected, cottage_fee = v_cottage_fee,
    cottage_addon_id = case when v_cottage_selected then v_package.cottage_addon_id else null end,
    pool_access_selected = false, pool_access_fee = 0, updated_at = now()
  where id = v_reservation_id and customer_id = auth.uid();
  update public.orders set
    total_amount = v_total, remaining_balance = greatest(v_total - amount_paid, 0),
    guest_count = v_guest_count,
    tour_slot = v_package.name, cottage_selected = v_cottage_selected,
    cottage_fee = v_cottage_fee,
    cottage_addon_id = case when v_cottage_selected then v_package.cottage_addon_id else null end,
    pool_access_selected = false, pool_access_fee = 0, updated_at = now()
  where reservation_id = v_reservation_id and customer_id = auth.uid();
  select amount_paid into v_amount_paid from public.reservations where id = v_reservation_id;
  return v_result || jsonb_build_object(
    'order_id', v_order_id, 'subtotal', v_total, 'deposit_amount', v_deposit,
    'remaining_balance', greatest(v_total - coalesce(v_amount_paid, 0), 0),
    'tour_slot', v_package.name, 'guest_count',v_guest_count,'cottage_fee', v_cottage_fee,
    'pool_access_fee', 0, 'cottage_addon_id', case when v_cottage_selected then v_package.cottage_addon_id else null end
  );
end;
$$;
revoke all on function public.create_evently_reservation_before_exact_resource_assignment(jsonb)
  from public, anon, authenticated;

create or replace function public.evently_has_timely_pending_payment(p_reservation_id uuid)
returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_status_column text;
  v_found boolean := false;
  v_due timestamptz;
  v_deposit numeric(12,2);
begin
  select payment_due_at, coalesce(deposit_amount, total_amount, 0)
    into v_due, v_deposit from public.reservations where id = p_reservation_id;
  if v_due is null then return false; end if;
  v_status_column := public.evently_existing_column('public.payments', array['verification_status', 'status']);
  if v_status_column is null then return false; end if;
  execute format(
    'select exists (select 1 from public.payments payment where payment.reservation_id = $1 and lower(payment.%I::text) = ''pending'' and payment.submitted_at <= $2 and payment.amount >= $3 and payment.demo_mode is not true and nullif(trim(payment.reference_number), '''') is not null and nullif(trim(payment.proof_url), '''') is not null and exists (select 1 from storage.objects object where object.bucket_id = ''payment-proofs'' and object.name = payment.proof_url))',
    v_status_column
  ) into v_found using p_reservation_id, v_due, v_deposit;
  return coalesce(v_found, false);
end;
$$;

create or replace function public.evently_reservation_holds_schedule(p_reservation_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select reservation.expired_at is null
    and lower(reservation.status::text) not in ('cancelled', 'canceled', 'rejected', 'completed', 'expired')
    and (
      lower(reservation.status::text) = 'confirmed'
      or reservation.payment_due_at is null
      or reservation.payment_due_at > statement_timestamp()
      or coalesce(reservation.amount_paid, 0) >= coalesce(reservation.deposit_amount, reservation.total_amount, 0)
      or public.evently_has_timely_pending_payment(reservation.id)
    )
  from public.reservations reservation
  where reservation.id = p_reservation_id;
$$;

create or replace function public.evently_expire_unpaid_reservations()
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_count integer := 0;
  v_order_status_column text;
  v_order_target text;
  v_pending_payment boolean;
begin
  v_order_status_column := public.evently_existing_column('public.orders'::regclass, array['order_status', 'status']);
  if public.evently_existing_column('public.payments', array['verification_status', 'status']) is null
     or v_order_status_column is null then raise exception 'Payment or order status is not configured'; end if;
  v_order_target := public.evently_status_value('public.orders', v_order_status_column, 'cancelled');
  for v_id in
    select reservation.id from public.reservations reservation
    where reservation.expired_at is null
      and lower(reservation.status::text) = 'pending'
      and reservation.payment_due_at is not null
      and reservation.payment_due_at <= clock_timestamp()
      and coalesce(reservation.amount_paid, 0) < coalesce(reservation.deposit_amount, reservation.total_amount, 0)
    order by reservation.payment_due_at, reservation.id
    for update skip locked
  loop
    v_pending_payment := public.evently_has_timely_pending_payment(v_id);
    if not coalesce(v_pending_payment, false) then
      update public.reservations
      set status = public.evently_status_value('public.reservations', 'status', 'cancelled')::public.booking_status,
          expired_at = clock_timestamp(),
          cancellation_reason = 'Payment was not submitted within the 24-hour hold',
          updated_at = now()
      where id = v_id and expired_at is null and lower(status::text) = 'pending';
      if found then
        execute format(
          'update public.orders set %I = %L, cancellation_reason = %L, updated_at = now() where reservation_id = $1 and lower(%I::text) = ''pending''',
          v_order_status_column, v_order_target, 'Payment was not submitted within the 24-hour hold', v_order_status_column
        ) using v_id;
        v_count := v_count + 1;
      end if;
    end if;
  end loop;
  return v_count;
end;
$$;

-- A verified deposit confirms only after the saved schedule/resource is valid.
-- This also supports rooms/venues that require an Administrator to assign an
-- actual resource, without retaining a separate manual approval step.
create or replace function public.evently_auto_confirm_verified_reservation(p_reservation_id uuid)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_reservation public.reservations%rowtype;
  v_package public.packages%rowtype;
  v_variant public.package_variants%rowtype;
  v_payment_status_column text;
  v_order_status_column text;
  v_order_target text;
  v_verified numeric(12,2) := 0;
  v_schedule jsonb;
  v_resource_key text;
  v_start timestamp;
  v_end timestamp;
begin
  if not public.is_evently_admin() then raise exception 'Administrator access required'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evently-resource-schedule-global', 0));
  perform public.evently_expire_unpaid_reservations();
  select * into v_reservation from public.reservations where id = p_reservation_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if lower(v_reservation.status::text) = 'confirmed' then return true; end if;
  if lower(v_reservation.status::text) <> 'pending' or v_reservation.expired_at is not null then return false; end if;
  select * into v_package from public.packages where id = v_reservation.package_id and is_active;
  if not found then return false; end if;
  if v_reservation.package_variant_id is not null then
    select * into v_variant from public.package_variants
      where id = v_reservation.package_variant_id and package_id = v_package.id and is_active;
  end if;
  if (v_package.schedule_mode = 'fixed'
      or (v_package.schedule_mode = 'timed' and lower(coalesce(v_package.package_category, '')) = 'pool_tour')) and (
    coalesce(v_variant.fixed_start_time, v_package.fixed_start_time, v_variant.operating_start_time, v_package.operating_start_time) is null
    or coalesce(v_variant.fixed_end_time, v_package.fixed_end_time, v_variant.operating_end_time, v_package.operating_end_time) is null
    or v_reservation.start_time is distinct from coalesce(v_variant.fixed_start_time, v_package.fixed_start_time, v_variant.operating_start_time, v_package.operating_start_time)
    or v_reservation.end_time is distinct from coalesce(v_variant.fixed_end_time, v_package.fixed_end_time, v_variant.operating_end_time, v_package.operating_end_time)
  ) then return false; end if;
  v_resource_key := coalesce(nullif(trim(v_reservation.resource_key), ''),
    nullif(trim(v_variant.resource_key), ''), nullif(trim(v_package.resource_key), ''));
  if v_package.resource_mode = 'exclusive' and (
    v_resource_key is null or not exists (select 1 from public.evently_resources resource
      where lower(resource.resource_key) = lower(v_resource_key) and resource.is_active and resource.is_exclusive)
  ) then return false; end if;
  if v_package.resource_mode = 'exclusive' then
    if v_reservation.reservation_date is null or v_reservation.start_time is null or v_reservation.end_time is null then
      return false;
    end if;
    v_start := v_reservation.reservation_date + v_reservation.start_time;
    v_end := v_reservation.reservation_date + v_reservation.end_time
      + case when v_reservation.end_time <= v_reservation.start_time then interval '1 day' else interval '0 day' end;
    if exists (select 1 from public.reservations other
      left join public.package_variants other_variant
        on other_variant.id = other.package_variant_id and other_variant.package_id = other.package_id
      left join public.packages other_package on other_package.id = other.package_id
      where other.id <> p_reservation_id
        and lower(trim(coalesce(nullif(other.resource_key, ''), nullif(other_variant.resource_key, ''), other_package.resource_key, ''))) = lower(v_resource_key)
        and public.evently_reservation_holds_schedule(other.id)
        and other.reservation_date is not null
        and (((other.start_time is null or other.end_time is null) and other.reservation_date = v_reservation.reservation_date)
          or (other.start_time is not null and other.end_time is not null
            and other.reservation_date + other.start_time < v_end
            and other.reservation_date + other.end_time
              + case when other.end_time <= other.start_time then interval '1 day' else interval '0 day' end > v_start))) then
      return false;
    end if;
  end if;
  v_payment_status_column := public.evently_existing_column('public.payments', array['verification_status', 'status']);
  if v_payment_status_column is null then raise exception 'Payment review status is not configured'; end if;
  execute format(
    'select coalesce(sum(payment.amount), 0) from public.payments payment where payment.reservation_id = $1 and lower(payment.%I::text) = ''verified'' and payment.demo_mode is not true and ($2 is null or payment.submitted_at <= $2) and nullif(trim(payment.reference_number), '''') is not null and nullif(trim(payment.proof_url), '''') is not null and exists (select 1 from storage.objects object where object.bucket_id = ''payment-proofs'' and object.name = payment.proof_url)',
    v_payment_status_column
  ) into v_verified using p_reservation_id, v_reservation.payment_due_at;
  if v_verified < round(v_reservation.total_amount * 0.30, 2) then return false; end if;

  v_schedule := public.evently_admin_check_reservation_schedule(p_reservation_id);
  if coalesce((v_schedule ->> 'schedule_complete')::boolean, false) is not true
     or coalesce((v_schedule ->> 'resource_valid')::boolean, false) is not true
     or coalesce((v_schedule ->> 'no_conflict')::boolean, false) is not true then
    return false;
  end if;

  update public.reservations
  set status = public.evently_status_value('public.reservations', 'status', 'confirmed')::public.booking_status,
      updated_at = now()
  where id = p_reservation_id and lower(status::text) = 'pending';
  v_order_status_column := public.evently_existing_column('public.orders'::regclass, array['order_status', 'status']);
  if v_order_status_column is null then raise exception 'Order status is not configured'; end if;
  v_order_target := public.evently_status_value('public.orders', v_order_status_column, 'confirmed');
  execute format('update public.orders set %I = %L, updated_at = now() where reservation_id = $1 and lower(%I::text) = ''pending''',
    v_order_status_column, v_order_target, v_order_status_column) using p_reservation_id;
  insert into public.notifications (user_id, title, message, type, entity_type, entity_id, dedupe_key)
  values (v_reservation.customer_id, 'Booking confirmed', 'Your timely payment has been verified and your schedule is confirmed.',
    'reservation_status', 'reservation', p_reservation_id, 'reservation-auto-confirmed:' || p_reservation_id)
  on conflict (dedupe_key) where dedupe_key is not null do nothing;
  return true;
end;
$$;

revoke all on function public.evently_has_timely_pending_payment(uuid) from public, anon, authenticated;
revoke all on function public.evently_reservation_holds_schedule(uuid) from public, anon, authenticated;
revoke all on function public.evently_expire_unpaid_reservations() from public, anon, authenticated;
revoke all on function public.evently_auto_confirm_verified_reservation(uuid) from public, anon, authenticated;

-- An expired due time is excluded from availability immediately, even when
-- pg_cron is delayed. The scheduled task separately persists cancelled state.
do $$
begin
  if to_regprocedure('public.evently_check_availability_before_payment_hold(uuid,date)') is null then
    alter function public.evently_check_availability(uuid, date)
      rename to evently_check_availability_before_payment_hold;
  end if;
end;
$$;

revoke all on function public.evently_check_availability_before_payment_hold(uuid,date) from public, anon, authenticated;

create or replace function public.evently_check_availability(p_package_id uuid, p_reservation_date date)
returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_package public.packages%rowtype;
  v_start timestamp;
  v_end timestamp;
  v_start_time time;
  v_end_time time;
begin
  select * into v_package from public.packages where id = p_package_id and is_active;
  if not found then return false; end if;
  if v_package.resource_mode <> 'exclusive' or nullif(trim(v_package.resource_key), '') is null
     or v_package.schedule_mode not in ('fixed', 'timed')
     or (v_package.schedule_mode = 'timed'
       and lower(coalesce(v_package.package_category, '')) <> 'pool_tour'
       and lower(v_package.resource_key) <> 'venice-main-pool') then
    return public.evently_check_availability_before_payment_hold(p_package_id, p_reservation_date);
  end if;
  v_start_time := coalesce(v_package.fixed_start_time, v_package.operating_start_time);
  v_end_time := coalesce(v_package.fixed_end_time, v_package.operating_end_time);
  if v_start_time is null or v_end_time is null or v_start_time = v_end_time then return false; end if;
  if not exists (select 1 from public.evently_resources resource
    where lower(resource.resource_key) = lower(v_package.resource_key)
      and resource.is_active and resource.is_exclusive) then return false; end if;
  v_start := p_reservation_date + v_start_time;
  v_end := p_reservation_date + v_end_time
    + case when v_end_time <= v_start_time then interval '1 day' else interval '0 day' end;
  return not exists (
    select 1 from public.reservations other
    left join public.package_variants other_variant
      on other_variant.id = other.package_variant_id and other_variant.package_id = other.package_id
    left join public.packages other_package on other_package.id = other.package_id
    where lower(trim(coalesce(nullif(other.resource_key, ''), nullif(other_variant.resource_key, ''), other_package.resource_key, ''))) = lower(v_package.resource_key)
      and public.evently_reservation_holds_schedule(other.id)
      and other.reservation_date is not null
      and (
        ((other.start_time is null or other.end_time is null) and other.reservation_date = p_reservation_date)
        or (other.start_time is not null and other.end_time is not null
          and other.reservation_date + other.start_time < v_end
          and other.reservation_date + other.end_time
            + case when other.end_time <= other.start_time then interval '1 day' else interval '0 day' end > v_start)
      )
  );
end;
$$;

revoke all on function public.evently_check_availability(uuid,date) from public;
grant execute on function public.evently_check_availability(uuid,date) to anon, authenticated;

-- Lock all exclusive-resource schedule writers through a shared transaction
-- mutex, then retain the original booking validation/pricing/idempotency RPC.
do $$
begin
  if to_regprocedure('public.create_evently_reservation_before_schedule_hold(jsonb)') is null then
    alter function public.create_evently_reservation(jsonb)
      rename to create_evently_reservation_before_schedule_hold;
  end if;
end;
$$;
revoke all on function public.create_evently_reservation_before_schedule_hold(jsonb) from public, anon, authenticated;

create or replace function public.create_evently_reservation(p_booking jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_result jsonb;
  v_payload jsonb := p_booking;
  v_reservation public.reservations%rowtype;
  v_order public.orders%rowtype;
  v_package public.packages%rowtype;
  v_variant public.package_variants%rowtype;
  v_existing_id uuid;
  v_id uuid;
  v_addon_id uuid;
  v_cottage_selected boolean := coalesce(nullif(p_booking ->> 'cottage_selected', '')::boolean, false);
  v_booking_addon_id uuid := nullif(p_booking ->> 'cottage_addon_id', '')::uuid;
  v_due timestamptz;
  v_start timestamp;
  v_end timestamp;
  v_schedule_start time;
  v_schedule_end time;
  v_package_schedule_mode text;
  v_timed_pool boolean := false;
  v_order_status_column text;
  v_order_target text;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if nullif(p_booking ->> 'idempotency_key', '') is null then raise exception 'An idempotency key is required'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'evently-booking:' || auth.uid()::text || ':' || (p_booking ->> 'idempotency_key'), 0
  ));
  select id into v_existing_id from public.reservations
    where customer_id = auth.uid() and client_request_id = (p_booking ->> 'idempotency_key')::uuid;
  if v_existing_id is not null then
    perform public.evently_expire_unpaid_reservations();
    select * into v_reservation from public.reservations where id = v_existing_id for update;
    if v_reservation.expired_at is not null
       or (lower(v_reservation.status::text) = 'pending'
         and v_reservation.payment_due_at <= clock_timestamp()
         and not public.evently_has_timely_pending_payment(v_existing_id)) then
      raise exception 'This idempotent booking has expired; create a new booking';
    end if;
    select * into v_order from public.orders
      where reservation_id = v_existing_id and customer_id = auth.uid()
      order by created_at limit 1;
    if not found then raise exception 'The saved reservation is not linked to an order'; end if;
    v_result := public.create_evently_reservation_before_schedule_hold(p_booking);
    return v_result || jsonb_build_object(
      'reservation_id', v_reservation.id,
      'order_id', v_order.id,
      'subtotal', v_reservation.subtotal,
      'total_amount', v_reservation.total_amount,
      'payment_due_at', v_reservation.payment_due_at,
      'deposit_amount', v_reservation.deposit_amount,
      'remaining_balance', v_reservation.remaining_balance,
      'start_time', v_reservation.start_time,
      'end_time', v_reservation.end_time,
      'schedule_mode', v_reservation.schedule_mode,
      'cottage_selected', v_reservation.cottage_selected,
      'cottage_fee', v_reservation.cottage_fee,
      'cottage_addon_id', v_reservation.cottage_addon_id
    );
  end if;

  select * into v_package from public.packages
    where id = nullif(p_booking ->> 'package_id', '')::uuid and is_active for share;
  if not found then raise exception 'The selected package is unavailable'; end if;
  if v_package.resource_mode = 'exclusive' and nullif(trim(v_package.resource_key), '') is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evently-resource-schedule-global', 0));
  end if;
  perform public.evently_expire_unpaid_reservations();
  if nullif(p_booking ->> 'package_variant_id', '') is not null then
    select * into v_variant from public.package_variants
      where id = (p_booking ->> 'package_variant_id')::uuid and package_id = v_package.id and is_active for share;
    if not found then raise exception 'The selected package variant is unavailable'; end if;
  end if;
  v_package_schedule_mode := coalesce(v_variant.schedule_mode, v_package.schedule_mode, 'admin_assign');
  if lower(coalesce(v_package.package_category, '')) = 'pool_tour' and v_package_schedule_mode = 'timed' then
    v_schedule_start := coalesce(v_variant.fixed_start_time, v_package.fixed_start_time,
      v_variant.operating_start_time, v_package.operating_start_time);
    v_schedule_end := coalesce(v_variant.fixed_end_time, v_package.fixed_end_time,
      v_variant.operating_end_time, v_package.operating_end_time);
    if v_schedule_start is null or v_schedule_end is null or v_schedule_start = v_schedule_end then
      raise exception 'The verified timed pool schedule is missing from the package catalog';
    end if;
    if (nullif(p_booking ->> 'start_time', '') is not null
        and nullif(p_booking ->> 'start_time', '')::time is distinct from v_schedule_start)
       or (nullif(p_booking ->> 'end_time', '') is not null
        and nullif(p_booking ->> 'end_time', '')::time is distinct from v_schedule_end) then
      raise exception 'Submitted pool times do not match the existing verified tour schedule';
    end if;
    -- The older scheduler rejects client times for the legacy `timed` value.
    -- It will still validate package/date/pricing; this wrapper then persists
    -- the authoritative catalog times and performs the full exclusive check.
    v_payload := p_booking - 'start_time' - 'end_time';
    v_timed_pool := true;
  end if;
  v_addon_id := v_package.cottage_addon_id;
  if v_cottage_selected then
    if lower(coalesce(v_package.package_category, '')) <> 'pool_tour'
       or v_addon_id is null or v_booking_addon_id is distinct from v_addon_id then
      raise exception 'The selected cottage is not configured for this tour package';
    end if;
    if not exists (select 1 from public.addons addon where addon.id = v_addon_id
      and addon.is_active and addon.price > 0 and addon.price = v_package.cottage_fee) then
      raise exception 'The configured cottage add-on price is unavailable';
    end if;
  elsif v_booking_addon_id is not null then
    raise exception 'A cottage add-on ID cannot be submitted unless selected';
  end if;

  v_result := public.create_evently_reservation_before_schedule_hold(v_payload);
  v_id := nullif(v_result ->> 'reservation_id', '')::uuid;
  if v_id is null then raise exception 'The booking RPC did not return a reservation'; end if;
  select * into v_reservation from public.reservations where id = v_id and customer_id = auth.uid() for update;
  if not found then raise exception 'The saved reservation is not available to this account'; end if;
  if v_timed_pool then
    update public.reservations set start_time = v_schedule_start, end_time = v_schedule_end,
      schedule_mode = 'timed', updated_at = now()
    where id = v_id and customer_id = auth.uid();
    v_reservation.start_time := v_schedule_start;
    v_reservation.end_time := v_schedule_end;
    v_reservation.schedule_mode := 'timed';
  end if;
  if v_package.resource_mode = 'exclusive'
     and lower(coalesce(v_package.package_category, '')) = 'pool_tour'
     and (v_reservation.reservation_date is null or v_reservation.start_time is null or v_reservation.end_time is null) then
    raise exception 'An exclusive pool tour requires its verified package schedule';
  end if;
  if v_package.resource_mode = 'exclusive' and v_reservation.reservation_date is not null
     and v_reservation.start_time is not null and v_reservation.end_time is not null then
    v_start := v_reservation.reservation_date + v_reservation.start_time;
    v_end := v_reservation.reservation_date + v_reservation.end_time
      + case when v_reservation.end_time <= v_reservation.start_time then interval '1 day' else interval '0 day' end;
    if exists (select 1 from public.reservations other
      left join public.package_variants other_variant
        on other_variant.id = other.package_variant_id and other_variant.package_id = other.package_id
      left join public.packages other_package on other_package.id = other.package_id
      where other.id <> v_id
      and lower(trim(coalesce(nullif(other.resource_key, ''), nullif(other_variant.resource_key, ''), other_package.resource_key, ''))) = lower(v_reservation.resource_key)
      and public.evently_reservation_holds_schedule(other.id)
      and other.reservation_date is not null
      and ((other.start_time is null or other.end_time is null) and other.reservation_date = v_reservation.reservation_date
        or (other.start_time is not null and other.end_time is not null
          and other.reservation_date + other.start_time < v_end
          and other.reservation_date + other.end_time
            + case when other.end_time <= other.start_time then interval '1 day' else interval '0 day' end > v_start)) then
      raise exception 'The selected schedule is no longer available';
    end if;
  end if;

  -- `created_at` is set by the original insert. Never accept a client deadline,
  -- and never change this value on an idempotent retry.
  v_due := public.evently_payment_deadline(v_reservation.created_at);
  update public.reservations
  set status = public.evently_status_value('public.reservations', 'status', 'pending')::public.booking_status,
      deposit_amount = round(total_amount * 0.30, 2),
      remaining_balance = greatest(total_amount - amount_paid, 0),
      payment_due_at = v_due,
      expired_at = null,
      cottage_addon_id = case when v_cottage_selected then v_addon_id else null end,
      updated_at = now()
  where id = v_id and customer_id = auth.uid();
  update public.orders
  set cottage_addon_id = case when v_cottage_selected then v_addon_id else null end,
      remaining_balance = greatest(total_amount - amount_paid, 0),
      updated_at = now()
  where reservation_id = v_id and customer_id = auth.uid();
  v_order_status_column := public.evently_existing_column('public.orders'::regclass, array['order_status', 'status']);
  if v_order_status_column is null then raise exception 'Order status is not configured'; end if;
  v_order_target := public.evently_status_value('public.orders', v_order_status_column, 'pending');
  execute format('update public.orders set %I = %L where reservation_id = $1 and customer_id = $2',
    v_order_status_column, v_order_target) using v_id, auth.uid();
  select * into v_reservation from public.reservations
    where id = v_id and customer_id = auth.uid() for update;
  if not found then raise exception 'The saved reservation is not available to this account'; end if;
  select * into v_order from public.orders
    where reservation_id = v_id and customer_id = auth.uid() order by created_at limit 1 for update;
  if not found then raise exception 'The saved reservation is not linked to an order'; end if;
  return v_result || jsonb_build_object(
    'reservation_id', v_reservation.id,
    'order_id', v_order.id,
    'subtotal', v_reservation.subtotal,
    'total_amount', v_reservation.total_amount,
    'payment_due_at', v_reservation.payment_due_at,
    'deposit_amount', v_reservation.deposit_amount,
    'remaining_balance', v_reservation.remaining_balance,
    'start_time', v_reservation.start_time,
    'end_time', v_reservation.end_time,
    'schedule_mode', v_reservation.schedule_mode,
    'cottage_selected', v_reservation.cottage_selected,
    'cottage_fee', v_reservation.cottage_fee,
    'cottage_addon_id', v_reservation.cottage_addon_id
  );
end;
$$;

revoke all on function public.create_evently_reservation(jsonb) from public, anon;
grant execute on function public.create_evently_reservation(jsonb) to authenticated;

-- Payment creation is still delegated to the trusted exact-amount/payment
-- destination function. This wrapper gates all submissions against the saved
-- 24-hour deadline and records no client-supplied submission timestamp.
do $$
begin
  if to_regprocedure('public.submit_evently_payment_before_payment_hold(uuid,numeric,text,text,text)') is null then
    alter function public.submit_evently_payment(uuid,numeric,text,text,text)
      rename to submit_evently_payment_before_payment_hold;
  end if;
end;
$$;
revoke all on function public.submit_evently_payment_before_payment_hold(uuid,numeric,text,text,text) from public, anon, authenticated;

create or replace function public.submit_evently_payment(
  p_reservation_id uuid, p_amount numeric, p_method text,
  p_reference_number text default null, p_proof_url text default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_reservation public.reservations%rowtype;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  perform public.evently_expire_unpaid_reservations();
  select * into v_reservation from public.reservations
    where id = p_reservation_id and customer_id = auth.uid() for update;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.expired_at is not null or lower(v_reservation.status::text) in ('cancelled', 'canceled', 'expired') then
    raise exception 'The payment deadline has passed; this booking has expired';
  end if;
  if lower(v_reservation.status::text) = 'pending' then
    if v_reservation.payment_due_at is not null and v_reservation.payment_due_at <= clock_timestamp() then
      raise exception 'The payment deadline has passed; this booking has expired';
    end if;
  elsif lower(v_reservation.status::text) <> 'confirmed' then
    raise exception 'This reservation is not eligible for payment submission';
  end if;
  v_id := public.submit_evently_payment_before_payment_hold(
    p_reservation_id, p_amount, p_method, p_reference_number, p_proof_url
  );
  return v_id;
end;
$$;

revoke all on function public.submit_evently_payment(uuid,numeric,text,text,text) from public, anon;
grant execute on function public.submit_evently_payment(uuid,numeric,text,text,text) to authenticated;

-- Browser compatibility name used by the customer flow; same secure checks.
create or replace function public.evently_submit_payment_proof(
  p_reservation_id uuid, p_amount numeric, p_method text,
  p_reference_number text, p_proof_path text
) returns uuid language sql security definer set search_path = '' as $$
  select public.submit_evently_payment(p_reservation_id, p_amount, p_method, p_reference_number, p_proof_path);
$$;
revoke all on function public.evently_submit_payment_proof(uuid,numeric,text,text,text) from public, anon;
grant execute on function public.evently_submit_payment_proof(uuid,numeric,text,text,text) to authenticated;

-- Payment verification is Admin-only in the existing RPC. Serialize it with
-- expiry, preserve the original deadline, and auto-confirm only after a timely
-- verified deposit meets the server-calculated 30% minimum.
do $$
begin
  if to_regprocedure('public.admin_review_payment_before_auto_confirmation(uuid,text,text)') is null then
    alter function public.admin_review_payment(uuid,text,text)
      rename to admin_review_payment_before_auto_confirmation;
  end if;
end;
$$;
revoke all on function public.admin_review_payment_before_auto_confirmation(uuid,text,text) from public, anon, authenticated;

create or replace function public.admin_review_payment(p_payment_id uuid, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_payment record;
  v_reservation public.reservations%rowtype;
  v_status_column text;
  v_payment_status text;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evently-resource-schedule-global', 0));
  perform public.evently_expire_unpaid_reservations();
  v_status_column := public.evently_existing_column('public.payments', array['verification_status', 'status']);
  if v_status_column is null then raise exception 'Payment review status is not configured'; end if;
  execute format('select payment.*, payment.%I::text as _status from public.payments payment where id = $1 for update', v_status_column)
    into v_payment using p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  v_payment_status := lower(v_payment._status);
  select * into v_reservation from public.reservations where id = v_payment.reservation_id for update;
  if not found then raise exception 'Linked reservation not found'; end if;

  if v_payment_status in ('verified', 'rejected') then
    if v_payment_status = lower(p_decision) then return; end if;
    raise exception 'This payment has already been reviewed';
  end if;
  if lower(p_decision) = 'verified' and lower(v_reservation.status::text) = 'pending' and (
    v_reservation.expired_at is not null or v_payment.submitted_at is null
    or (v_reservation.payment_due_at is not null and v_payment.submitted_at > v_reservation.payment_due_at)
  ) then raise exception 'Only eligible payment proof can be verified, and dated holds require submission before the original deadline'; end if;

  perform public.admin_review_payment_before_auto_confirmation(p_payment_id, p_decision, p_reason);
  if lower(p_decision) = 'verified' then
    perform public.evently_auto_confirm_verified_reservation(v_reservation.id);
  else
    perform public.evently_expire_unpaid_reservations();
  end if;
end;
$$;
revoke all on function public.admin_review_payment(uuid,text,text) from public, anon;
grant execute on function public.admin_review_payment(uuid,text,text) to authenticated;

-- Administrator-only audited operations. All schedule mutations share the
-- same mutex as customer creation and always check full timestamp overlaps.
create or replace function public.evently_admin_override_reservation(
  p_reservation_id uuid,
  p_action text,
  p_reason text,
  p_reservation_date date default null,
  p_start_time time default null,
  p_end_time time default null,
  p_resource_key text default null,
  p_payment_due_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_reservation public.reservations%rowtype;
  v_package public.packages%rowtype;
  v_variant public.package_variants%rowtype;
  v_action text := lower(trim(coalesce(p_action, '')));
  v_resource text := nullif(lower(trim(coalesce(p_resource_key, ''))), '');
  v_start timestamp;
  v_end timestamp;
  v_window_start timestamp;
  v_window_end timestamp;
  v_duration integer;
  v_operating_start time;
  v_operating_end time;
  v_previous jsonb;
  v_next jsonb;
  v_order_status_column text;
  v_order_target text;
  v_resource_required boolean;
begin
  if not public.is_evently_admin() then raise exception 'Administrator access required'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'An override reason is required'; end if;
  if v_action not in ('reschedule', 'assign_resource', 'cancel', 'release_schedule', 'extend_payment_deadline', 'reopen_payment') then
    raise exception 'Unsupported Administrator override';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evently-resource-schedule-global', 0));
  select * into v_reservation from public.reservations where id = p_reservation_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  select * into v_package from public.packages where id = v_reservation.package_id;
  if not found then raise exception 'The reservation package no longer exists'; end if;
  if v_reservation.package_variant_id is not null then
    select * into v_variant from public.package_variants where id = v_reservation.package_variant_id and package_id = v_package.id;
  end if;
  v_previous := jsonb_build_object(
    'status', v_reservation.status, 'reservation_date', v_reservation.reservation_date,
    'start_time', v_reservation.start_time, 'end_time', v_reservation.end_time,
    'resource_key', v_reservation.resource_key, 'payment_due_at', v_reservation.payment_due_at,
    'expired_at', v_reservation.expired_at
  );

  if v_action in ('cancel', 'release_schedule') then
    if lower(v_reservation.status::text) = 'completed' then raise exception 'Completed reservations cannot be cancelled or released'; end if;
    update public.reservations set
      status = public.evently_status_value('public.reservations', 'status', 'cancelled')::public.booking_status,
      cancellation_reason = trim(p_reason), updated_at = now()
    where id = p_reservation_id;
    v_order_status_column := public.evently_existing_column('public.orders'::regclass, array['order_status', 'status']);
    if v_order_status_column is null then raise exception 'Order status is not configured'; end if;
    v_order_target := public.evently_status_value('public.orders', v_order_status_column, 'cancelled');
    execute format('update public.orders set %I = %L, cancellation_reason = $1, updated_at = now() where reservation_id = $2 and lower(%I::text) not in (''completed'', ''cancelled'')',
      v_order_status_column, v_order_target, v_order_status_column) using trim(p_reason), p_reservation_id;
  elsif v_action in ('extend_payment_deadline', 'reopen_payment') then
    if p_payment_due_at is null or p_payment_due_at <= clock_timestamp() then
      raise exception 'The replacement payment deadline must be in the future';
    end if;
    if v_action = 'extend_payment_deadline' and (lower(v_reservation.status::text) <> 'pending'
       or (v_reservation.payment_due_at is not null and p_payment_due_at <= v_reservation.payment_due_at)) then
      raise exception 'Only a pending legacy or active hold can receive an Administrator-set future deadline';
    end if;
    if v_action = 'reopen_payment' and v_reservation.expired_at is null then
      raise exception 'Only an expired reservation can be reopened';
    end if;
    if v_reservation.resource_key is not null and v_reservation.reservation_date is not null
       and v_reservation.start_time is not null and v_reservation.end_time is not null then
      v_start := v_reservation.reservation_date + v_reservation.start_time;
      v_end := v_reservation.reservation_date + v_reservation.end_time
        + case when v_reservation.end_time <= v_reservation.start_time then interval '1 day' else interval '0 day' end;
      if exists (select 1 from public.reservations other
        left join public.package_variants other_variant
          on other_variant.id = other.package_variant_id and other_variant.package_id = other.package_id
        left join public.packages other_package on other_package.id = other.package_id
        where other.id <> v_reservation.id
        and lower(trim(coalesce(nullif(other.resource_key, ''), nullif(other_variant.resource_key, ''), other_package.resource_key, ''))) = lower(v_reservation.resource_key)
        and public.evently_reservation_holds_schedule(other.id)
        and other.reservation_date is not null
        and (((other.start_time is null or other.end_time is null) and other.reservation_date = v_reservation.reservation_date)
          or (other.start_time is not null and other.end_time is not null
            and other.reservation_date + other.start_time < v_end
            and other.reservation_date + other.end_time
              + case when other.end_time <= other.start_time then interval '1 day' else interval '0 day' end > v_start))) then
        raise exception 'The original schedule has since been assigned; reopen only after selecting a conflict-free slot';
      end if;
    end if;
    update public.reservations set
      status = public.evently_status_value('public.reservations', 'status', 'pending')::public.booking_status,
      payment_due_at = p_payment_due_at, expired_at = null, cancellation_reason = null, updated_at = now()
    where id = p_reservation_id;
    v_order_status_column := public.evently_existing_column('public.orders'::regclass, array['order_status', 'status']);
    if v_order_status_column is null then raise exception 'Order status is not configured'; end if;
    v_order_target := public.evently_status_value('public.orders', v_order_status_column, 'pending');
    execute format('update public.orders set %I = %L, cancellation_reason = null, updated_at = now() where reservation_id = $1',
      v_order_status_column, v_order_target) using p_reservation_id;
  else
    if v_reservation.expired_at is not null or lower(v_reservation.status::text) not in ('pending', 'confirmed') then
      raise exception 'Only an active pending or confirmed reservation can be rescheduled; reopen an expired hold separately';
    end if;
    if p_reservation_date is null or p_start_time is null or p_end_time is null or p_start_time = p_end_time then
      raise exception 'A date and distinct start/end times are required';
    end if;
    v_resource_required := v_action = 'assign_resource'
      or v_package.resource_mode = 'exclusive'
      or lower(coalesce(v_package.package_category, '')) in ('room', 'event_venue');
    if v_resource_required and v_resource is null then raise exception 'Select an active resource'; end if;
    if v_resource is not null and not exists (select 1 from public.evently_resources resource
      where lower(resource.resource_key) = v_resource and resource.is_active and resource.is_exclusive) then
      raise exception 'Select an active configured exclusive resource';
    end if;
    if (v_package.schedule_mode = 'fixed'
        or (v_package.schedule_mode = 'timed' and lower(coalesce(v_package.package_category, '')) = 'pool_tour')) and (
      coalesce(v_variant.fixed_start_time, v_package.fixed_start_time, v_variant.operating_start_time, v_package.operating_start_time) is null
      or coalesce(v_variant.fixed_end_time, v_package.fixed_end_time, v_variant.operating_end_time, v_package.operating_end_time) is null
      or p_start_time is distinct from coalesce(v_variant.fixed_start_time, v_package.fixed_start_time, v_variant.operating_start_time, v_package.operating_start_time)
      or p_end_time is distinct from coalesce(v_variant.fixed_end_time, v_package.fixed_end_time, v_variant.operating_end_time, v_package.operating_end_time)
    ) then raise exception 'Fixed or timed package schedules cannot be changed'; end if;
    v_start := p_reservation_date + p_start_time;
    v_end := p_reservation_date + p_end_time
      + case when p_end_time <= p_start_time then interval '1 day' else interval '0 day' end;
    if v_package.schedule_mode = 'customer_select' then
      v_duration := coalesce(v_variant.duration_minutes, v_package.duration_minutes);
      v_operating_start := coalesce(v_variant.operating_start_time, v_package.operating_start_time);
      v_operating_end := coalesce(v_variant.operating_end_time, v_package.operating_end_time);
      if v_duration is null or v_operating_start is null or v_operating_end is null or v_operating_start = v_operating_end then
        raise exception 'This package has no configured duration or operating hours';
      end if;
      if extract(epoch from (v_end - v_start)) / 60 <> v_duration then
        raise exception 'The override schedule does not match the package duration';
      end if;
      v_window_start := p_reservation_date + v_operating_start;
      v_window_end := p_reservation_date + v_operating_end
        + case when v_operating_end <= v_operating_start then interval '1 day' else interval '0 day' end;
      if v_start < v_window_start or v_end > v_window_end then
        raise exception 'The override schedule is outside configured operating hours';
      end if;
    end if;
    if v_resource is not null and exists (select 1 from public.reservations other
      left join public.package_variants other_variant
        on other_variant.id = other.package_variant_id and other_variant.package_id = other.package_id
      left join public.packages other_package on other_package.id = other.package_id
      where other.id <> v_reservation.id
      and lower(trim(coalesce(nullif(other.resource_key, ''), nullif(other_variant.resource_key, ''), other_package.resource_key, ''))) = v_resource
      and public.evently_reservation_holds_schedule(other.id)
      and other.reservation_date is not null
      and ((other.start_time is null or other.end_time is null) and other.reservation_date = p_reservation_date
        or (other.start_time is not null and other.end_time is not null
          and other.reservation_date + other.start_time < v_end
          and other.reservation_date + other.end_time
            + case when other.end_time <= other.start_time then interval '1 day' else interval '0 day' end > v_start)) then
      raise exception 'The requested resource schedule conflicts with another active reservation';
    end if;
    update public.reservations set reservation_date = p_reservation_date, start_time = p_start_time,
      end_time = p_end_time,
      resource_key = coalesce(v_resource, resource_key),
      resource_mode = case when v_resource is not null then 'exclusive' else resource_mode end,
      resource_name = case when v_resource is not null then (select resource_name from public.evently_resources where lower(resource_key) = v_resource) else resource_name end,
      status = case when expired_at is not null then public.evently_status_value('public.reservations', 'status', 'pending')::public.booking_status else status end,
      expired_at = null, cancellation_reason = null, updated_at = now()
    where id = p_reservation_id;
  end if;

  if v_action in ('reschedule', 'assign_resource', 'extend_payment_deadline', 'reopen_payment') then
    perform public.evently_auto_confirm_verified_reservation(p_reservation_id);
  end if;

  select jsonb_build_object(
    'status', reservation.status, 'reservation_date', reservation.reservation_date,
    'start_time', reservation.start_time, 'end_time', reservation.end_time,
    'resource_key', reservation.resource_key, 'payment_due_at', reservation.payment_due_at,
    'expired_at', reservation.expired_at
  ) into v_next from public.reservations reservation where reservation.id = p_reservation_id;
  insert into public.evently_reservation_override_audit (
    reservation_id, admin_id, action, reason, previous_values, new_values
  ) values (p_reservation_id, auth.uid(), v_action, trim(p_reason), v_previous, v_next);
  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'reservation_override_' || v_action, 'reservation', p_reservation_id, trim(p_reason));
  return jsonb_build_object('reservation_id', p_reservation_id, 'action', v_action, 'previous', v_previous, 'new', v_next);
end;
$$;

revoke all on function public.evently_admin_override_reservation(uuid,text,text,date,time,time,text,timestamptz) from public, anon;
grant execute on function public.evently_admin_override_reservation(uuid,text,text,date,time,time,text,timestamptz) to authenticated;

-- Keep the Staff proposal workflow, but route acceptance through the reasoned,
-- conflict-checked override rather than the deprecated schedule RPC.
do $$
begin
  if to_regprocedure('public.evently_admin_decide_schedule_proposal_before_audit(uuid,boolean,text)') is null then
    alter function public.evently_admin_decide_schedule_proposal(uuid,boolean,text)
      rename to evently_admin_decide_schedule_proposal_before_audit;
  end if;
end;
$$;
revoke all on function public.evently_admin_decide_schedule_proposal_before_audit(uuid,boolean,text)
  from public, anon, authenticated;

create or replace function public.evently_admin_decide_schedule_proposal(
  p_proposal_id uuid, p_accept boolean, p_reason text default null
) returns void language plpgsql security definer set search_path = '' as $$
declare
  v_proposal public.evently_schedule_proposals%rowtype;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'An Administrator reason is required for schedule proposal decisions';
  end if;
  select * into v_proposal from public.evently_schedule_proposals
  where id = p_proposal_id for update;
  if not found or v_proposal.proposal_state <> 'pending' then
    raise exception 'Schedule proposal is no longer pending';
  end if;
  if p_accept then
    if v_proposal.proposed_date is distinct from (
      select reservation_date from public.reservations where id = v_proposal.reservation_id
    ) then raise exception 'Date changes require the audited Administrator reschedule override'; end if;
    perform public.evently_admin_override_reservation(
      p_reservation_id => v_proposal.reservation_id,
      p_action => 'assign_resource',
      p_reason => p_reason,
      p_reservation_date => v_proposal.proposed_date,
      p_start_time => v_proposal.proposed_start_time,
      p_end_time => v_proposal.proposed_end_time,
      p_resource_key => v_proposal.proposed_resource_key
    );
  end if;
  update public.evently_schedule_proposals set
    proposal_state = case when p_accept then 'accepted' else 'rejected' end,
    decided_by = auth.uid(), decided_at = now(), decision_note = trim(p_reason)
  where id = v_proposal.id;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), case when p_accept then 'staff_schedule_accepted' else 'staff_schedule_rejected' end,
    'reservation', v_proposal.reservation_id, trim(p_reason));
end;
$$;
revoke all on function public.evently_admin_decide_schedule_proposal(uuid,boolean,text) from public, anon;
grant execute on function public.evently_admin_decide_schedule_proposal(uuid,boolean,text) to authenticated;

-- Route legacy status controls through an auditable boundary as well. The
-- existing transition RPC remains authoritative for allowed enum transitions.
do $$
begin
  if to_regprocedure('public.admin_transition_reservation_before_override_audit(uuid,text,text)') is null then
    alter function public.admin_transition_reservation(uuid,text,text)
      rename to admin_transition_reservation_before_override_audit;
  end if;
end;
$$;
revoke all on function public.admin_transition_reservation_before_override_audit(uuid,text,text) from public, anon, authenticated;

create or replace function public.admin_transition_reservation(
  p_reservation_id uuid, p_status text, p_reason text default null
) returns void language plpgsql security definer set search_path = '' as $$
declare
  v_before public.reservations%rowtype;
  v_after public.reservations%rowtype;
begin
  if not public.is_evently_admin() then raise exception 'Administrator access required'; end if;
  select * into v_before from public.reservations where id = p_reservation_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if lower(trim(coalesce(p_status, ''))) in ('confirmed', 'approved') then
    raise exception 'Booking confirmation is payment-driven; verify an eligible deposit instead of changing status directly';
  end if;
  if lower(coalesce(p_status, '')) in ('cancelled', 'canceled', 'rejected')
     and nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required for cancellation or rejection';
  end if;
  perform public.admin_transition_reservation_before_override_audit(p_reservation_id, p_status, p_reason);
  select * into v_after from public.reservations where id = p_reservation_id;
  if v_before.status is distinct from v_after.status then
    insert into public.evently_reservation_override_audit (
      reservation_id, admin_id, action, reason, previous_values, new_values
    ) values (
      p_reservation_id, auth.uid(), 'status_' || lower(p_status),
      coalesce(nullif(trim(p_reason), ''), 'Administrator status transition'),
      jsonb_build_object('status', v_before.status, 'payment_due_at', v_before.payment_due_at,
        'reservation_date', v_before.reservation_date, 'start_time', v_before.start_time,
        'end_time', v_before.end_time, 'resource_key', v_before.resource_key),
      jsonb_build_object('status', v_after.status, 'payment_due_at', v_after.payment_due_at,
        'reservation_date', v_after.reservation_date, 'start_time', v_after.start_time,
        'end_time', v_after.end_time, 'resource_key', v_after.resource_key)
    );
  end if;
end;
$$;
revoke all on function public.admin_transition_reservation(uuid,text,text) from public, anon;
grant execute on function public.admin_transition_reservation(uuid,text,text) to authenticated;

-- Payment verification is now the only path from a pending booking to
-- confirmed. Retain the old approval implementation for rollback but disable
-- its public RPC entry point.
revoke all on function public.evently_admin_approve_booking(uuid,boolean) from public, anon, authenticated;

-- Reviewing a Staff recommendation remains available, but accepting a
-- recommendation no longer manually approves/confirms its reservation.
do $$
begin
  if to_regprocedure('public.evently_admin_review_booking_recommendation_before_auto_confirmation(uuid,text,text,boolean)') is null then
    alter function public.evently_admin_review_booking_recommendation(uuid,text,text,boolean)
      rename to evently_admin_review_booking_recommendation_before_auto_confirmation;
  end if;
end;
$$;
revoke all on function public.evently_admin_review_booking_recommendation_before_auto_confirmation(uuid,text,text,boolean)
  from public, anon, authenticated;

create or replace function public.evently_admin_review_booking_recommendation(
  p_recommendation_id uuid,
  p_decision text,
  p_reason text default null,
  p_schedule_verified boolean default false
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_recommendation public.evently_booking_recommendations%rowtype;
  v_state text;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  select * into v_recommendation from public.evently_booking_recommendations
    where id = p_recommendation_id for update;
  if not found or v_recommendation.review_state <> 'awaiting_admin' then
    raise exception 'Recommendation is no longer awaiting a decision';
  end if;
  if p_decision = 'return' then
    v_state := 'revision_requested';
  elsif p_decision = 'approve' then
    v_state := 'approved';
  elsif p_decision = 'reject' then
    if nullif(trim(p_reason), '') is null then raise exception 'A rejection reason is required'; end if;
    perform public.admin_transition_reservation(
      p_reservation_id => v_recommendation.reservation_id,
      p_status => 'cancelled', p_reason => p_reason
    );
    v_state := 'rejected';
  else
    raise exception 'Invalid admin decision';
  end if;
  update public.evently_booking_recommendations set review_state = v_state,
    decision_by = auth.uid(), decision_at = now(), decision_note = nullif(trim(p_reason), '')
  where id = v_recommendation.id;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'booking_recommendation_' || p_decision, 'reservation', v_recommendation.reservation_id,
    coalesce(nullif(trim(p_reason), ''), 'Staff recommendation reviewed; reservation confirmation remains payment-driven'));
  return jsonb_build_object('review_state', v_state, 'reservation_id', v_recommendation.reservation_id);
end;
$$;
revoke all on function public.evently_admin_review_booking_recommendation(uuid,text,text,boolean) from public, anon;
grant execute on function public.evently_admin_review_booking_recommendation(uuid,text,text,boolean) to authenticated;

-- The rate calculator and final booking wrapper are now installed. Verify
-- server-side arithmetic before changing the stored unit prices. The maximum
-- capacity remains unverified by default, so evently_pool_tour_total blocks
-- bookings until an Administrator confirms a real physical limit/policy.
do $$
declare v_error text;
begin
  if to_regprocedure('public.evently_pool_tour_amount(uuid,integer,uuid)') is null then
    raise exception 'Per-person amount calculator is missing; stored pool prices were not changed';
  end if;
  if to_regprocedure('public.evently_pool_tour_total(uuid,integer,uuid)') is null then
    raise exception 'Capacity-gated pool total calculator is missing; stored pool prices were not changed';
  end if;
  if position('evently_pool_tour_total' in lower(pg_catalog.pg_get_functiondef(
       'public.create_evently_reservation_before_exact_resource_assignment(jsonb)'::regprocedure)))=0 then
    raise exception 'The verified per-person calculator and outer pool booking wrapper must be installed before changing stored pool rates';
  end if;
  if array[
       public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',1,null),
       public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',5,null),
       public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',19,null),
       public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,null),
       public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',25,null),
       public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',50,null),
       public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',1,null),
       public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',5,null),
       public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',19,null),
       public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',20,null),
       public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',25,null),
       public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',50,null),
       public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,null),
       public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',25,null),
       public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',50,null)
     ]::numeric[] is distinct from array[
       100,500,1900,2000,2500,5000,150,750,2850,3000,3750,7500,4000,5000,10000
     ]::numeric[] then
    raise exception 'Per-person or optional cottage calculation verification failed; pool price columns were not changed';
  end if;
  if array[
       public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,'1e97b2bf-ca43-492a-8a15-2d20f6abf040'),
       public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',20,'1e97b2bf-ca43-492a-8a15-2d20f6abf040'),
       public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,'928c269f-c38a-4345-86a5-d1f4c65555f0')
     ]::numeric[] is distinct from array[2700,3700,5000]::numeric[] then
    raise exception 'Optional cottage totals differ; pool price columns were not changed';
  end if;
  v_error:=null;
  begin
    perform public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',19,null);
  exception when raise_exception then get stacked diagnostics v_error=message_text;
  end;
  if coalesce(v_error,'') not like '%at least 20%' then
    raise exception 'Overnight minimum-guest verification failed; pool price columns were not changed';
  end if;
  if array[
       round(public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',25,null)*0.30,2),
       round(public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',20,
         '928c269f-c38a-4345-86a5-d1f4c65555f0')*0.30,2)
     ]::numeric[] is distinct from array[750,1500]::numeric[] then
    raise exception '30-percent pool deposit verification failed; stored pool prices were not changed';
  end if;
  if exists (
    select 1 from public.packages package
    join public.evently_schedule_hold_catalog_backup backup
      on backup.entity_type='package' and backup.entity_key=package.id::text
    where package.id in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
      and package.guest_capacity is distinct from nullif(backup.row_data->>'guest_capacity','')::integer
  ) then raise exception 'guest_capacity changed from its pre-migration value'; end if;
end;
$$;

update public.packages set price=100,updated_at=now()
where id='4ae972a8-6503-4776-90c9-899246cbc4dc' and is_active;
update public.packages set price=150,updated_at=now()
where id='5afda244-a615-4bd3-98eb-d360d000100b' and is_active;
update public.packages set price=200,updated_at=now()
where id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8' and is_active;
do $$
begin
  if (select count(*) from public.packages
      where id in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
        '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
        and price=case id
          when '4ae972a8-6503-4776-90c9-899246cbc4dc'::uuid then 100::numeric
          when '5afda244-a615-4bd3-98eb-d360d000100b'::uuid then 150::numeric
          when '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'::uuid then 200::numeric
        end)<>3 then
    raise exception 'Pool unit rates were not stored after the calculator was verified';
  end if;
end;
$$;

-- Existing direct schedule assignment RPC is retained privately for rollback;
-- customer/admin schedule edits must now use the reasoned override RPC above.
revoke all on function public.evently_admin_set_reservation_schedule(uuid,time,time,text) from public, anon, authenticated;

-- Legacy transition policy: pending reservations that predate this migration
-- retain payment_due_at=NULL and are not selected by the expiry job. They keep
-- their prior hold policy until an Administrator explicitly starts a reasoned
-- deadline through evently_admin_override_reservation.

-- Grant only the scheduler's entry point. Customers never receive expiration,
-- audit-write, or Administrator override privileges.
create extension if not exists pg_cron;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'evently-expire-unpaid-reservations') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'evently-expire-unpaid-reservations';
  end if;
  perform cron.schedule(
    'evently-expire-unpaid-reservations', '* * * * *',
    'select public.evently_expire_unpaid_reservations();'
  );
end;
$$;

-- Lifecycle writes must go through the authenticated SECURITY DEFINER RPC
-- chain. Retain SELECT/RLS policies; remove table and per-column direct write
-- grants that could bypass price/capacity/deadline/conflict validation.
do $$
declare v_table text; v_columns text;
begin
  foreach v_table in array array['packages','reservations','orders','payments'] loop
    execute pg_catalog.format('revoke insert, update, delete on table public.%I from public, anon, authenticated',v_table);
    select string_agg(pg_catalog.quote_ident(a.attname),', ' order by a.attnum) into v_columns
    from pg_catalog.pg_attribute a where a.attrelid=to_regclass('public.'||v_table) and a.attnum>0 and not a.attisdropped;
    if v_columns is not null then
      execute pg_catalog.format('revoke insert (%s) on table public.%I from public, anon, authenticated',v_columns,v_table);
      execute pg_catalog.format('revoke update (%s) on table public.%I from public, anon, authenticated',v_columns,v_table);
    end if;
  end loop;
  if has_table_privilege('anon','public.reservations','INSERT')
    or has_table_privilege('authenticated','public.reservations','INSERT')
    or has_table_privilege('authenticated','public.reservations','UPDATE')
    or has_table_privilege('authenticated','public.packages','INSERT')
    or has_table_privilege('authenticated','public.packages','UPDATE')
    or has_table_privilege('authenticated','public.packages','DELETE')
    or has_table_privilege('authenticated','public.orders','INSERT')
    or has_table_privilege('authenticated','public.orders','UPDATE')
    or has_table_privilege('authenticated','public.payments','UPDATE') then
    raise exception 'Direct lifecycle DML remains granted; booking/payment RPC protections are not active';
  end if;
  if exists(select 1 from information_schema.column_privileges
    where table_schema='public' and table_name in ('packages','reservations','orders','payments')
      and grantee in ('PUBLIC','anon','authenticated') and privilege_type in ('INSERT','UPDATE')) then
    raise exception 'Direct lifecycle column-level write grants remain; booking/payment RPC protections are not active';
  end if;
end;
$$;

notify pgrst, 'reload schema';
commit;

-- Rollback notes (manual review only): unschedule the cron job; drop the new
-- evently_admin_override_reservation/evently_submit_payment_proof functions;
-- drop the wrapper functions and rename their *_before_* functions back to
-- create_evently_reservation, submit_evently_payment, admin_review_payment,
-- and evently_check_availability. Keep payment_due_at, expired_at, audit rows,
-- and existing audit history unless separately reviewed for data retention.
