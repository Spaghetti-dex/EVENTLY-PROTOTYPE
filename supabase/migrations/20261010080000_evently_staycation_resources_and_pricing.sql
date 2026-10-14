-- Complete EVENTLY staycation pricing and physical-resource configuration.
-- This migration intentionally does not invent room/cottage rows, venue hours,
-- shared-pool capacity, or package-to-catering-location assignments.

create table if not exists public.evently_resources (
  resource_key text primary key,
  resource_name text not null,
  resource_type text not null,
  location_description text,
  is_active boolean not null default true,
  is_exclusive boolean not null default true,
  capacity integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.evently_resources
  add column if not exists is_exclusive boolean not null default true,
  add column if not exists capacity integer,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

alter table public.evently_resources enable row level security;

drop policy if exists "Authenticated users read active evently resources" on public.evently_resources;
create policy "Authenticated users read active evently resources"
  on public.evently_resources for select to authenticated
  using (is_active or public.is_evently_admin());

drop policy if exists "Admins manage evently resources" on public.evently_resources;
create policy "Admins manage evently resources"
  on public.evently_resources for all to authenticated
  using (public.is_evently_admin()) with check (public.is_evently_admin());

grant select on public.evently_resources to authenticated;
grant insert, update, delete on public.evently_resources to authenticated;

-- These are the three physical catering locations supplied by the business.
insert into public.evently_resources (
  resource_key, resource_name, resource_type, location_description, is_active, is_exclusive
) values
  ('catering-alfamart-daffodil-2f', 'Alfamart Daffodil — 2nd Floor', 'catering_venue', '2nd Floor Alfamart, Daffodil St., Brgy. Rizal', true, true),
  ('catering-alfamart-amarillo-4f', 'Alfamart Amarillo — 4th Floor', 'catering_venue', '4th Floor Alfamart, Amarillo St., Brgy. Rizal', true, true),
  ('catering-alfamart-amarillo-3f', 'Alfamart Amarillo — 3rd Floor', 'catering_venue', '3rd Floor Alfamart, Amarillo St., Brgy. Rizal', true, true)
on conflict (resource_key) do update set
  resource_name = excluded.resource_name,
  resource_type = excluded.resource_type,
  location_description = excluded.location_description,
  is_exclusive = excluded.is_exclusive,
  updated_at = now();

alter table public.packages
  add column if not exists package_category text,
  add column if not exists pricing_mode text not null default 'fixed',
  add column if not exists min_guest_count integer not null default 1,
  add column if not exists cottage_fee numeric(12,2) not null default 0,
  add column if not exists pool_access_fee numeric(12,2) not null default 0,
  add column if not exists resource_mode text not null default 'admin_assign';

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'packages_pricing_mode_check'
      and conrelid = 'public.packages'::regclass
  ) then
    alter table public.packages add constraint packages_pricing_mode_check
      check (pricing_mode in ('fixed', 'per_guest', 'per_night'));
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'packages_resource_mode_check'
      and conrelid = 'public.packages'::regclass
  ) then
    alter table public.packages add constraint packages_resource_mode_check
      check (resource_mode in ('exclusive', 'shared_capacity', 'admin_assign'));
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'packages_min_guest_count_check'
      and conrelid = 'public.packages'::regclass
  ) then
    alter table public.packages add constraint packages_min_guest_count_check
      check (min_guest_count >= 1);
  end if;
end;
$$;

alter table public.reservations
  add column if not exists tour_slot text,
  add column if not exists cottage_selected boolean not null default false,
  add column if not exists cottage_fee numeric(12,2) not null default 0,
  add column if not exists pool_access_selected boolean not null default false,
  add column if not exists pool_access_fee numeric(12,2) not null default 0,
  add column if not exists pricing_mode text not null default 'fixed',
  add column if not exists resource_mode text not null default 'admin_assign',
  add column if not exists resource_name text;

alter table public.orders
  add column if not exists tour_slot text,
  add column if not exists cottage_selected boolean not null default false,
  add column if not exists cottage_fee numeric(12,2) not null default 0,
  add column if not exists pool_access_selected boolean not null default false,
  add column if not exists pool_access_fee numeric(12,2) not null default 0;

-- Confirmed package facts. Prices on per_guest packages are unit prices.
update public.packages
set price = 3000,
    guest_capacity = 5,
    min_guest_count = 4,
    package_category = 'room',
    pricing_mode = 'fixed',
    resource_mode = 'admin_assign',
    updated_at = now()
where lower(name) = 'standard room';

insert into public.packages (
  name, description, service_type, price, guest_capacity, menu_items, add_ons,
  is_active, package_category, pricing_mode, min_guest_count, resource_mode,
  schedule_mode
)
select
  'Kubo Room', 'VENICE Resort Kubo room. Capacity and schedule require business configuration.',
  source.service_type, 1500, null, array[]::text[], array[]::text[],
  true, 'room', 'fixed', 1, 'admin_assign', 'admin_assign'
from public.packages source
where lower(source.service_type::text) = 'resort'
  and not exists (select 1 from public.packages where lower(name) = 'kubo room')
limit 1;

insert into public.packages (
  name, description, service_type, price, guest_capacity, menu_items, add_ons,
  is_active, package_category, pricing_mode, min_guest_count, cottage_fee,
  resource_mode, schedule_mode, fixed_start_time, fixed_end_time
)
select values_to_add.name, values_to_add.description, source.service_type,
  values_to_add.price, null, array[]::text[], array[]::text[], true,
  'pool_tour', 'per_guest', values_to_add.minimum_guests,
  values_to_add.cottage_fee, 'shared_capacity', 'fixed',
  values_to_add.start_time, values_to_add.end_time
from (
  values
    ('Day Tour', 'Swimming pool day tour from 8:00 AM to 3:00 PM.', 100::numeric, 1, 700::numeric, '08:00'::time, '15:00'::time),
    ('Night Tour', 'Swimming pool night tour from 4:00 PM to 10:00 PM.', 150::numeric, 1, 700::numeric, '16:00'::time, '22:00'::time),
    ('Overnight Tour', 'Overnight swimming pool tour ending at 4:00 AM the following day.', 200::numeric, 20, 1000::numeric, '19:00'::time, '04:00'::time)
) as values_to_add(name, description, price, minimum_guests, cottage_fee, start_time, end_time)
cross join lateral (
  select service_type from public.packages
  where lower(service_type::text) = 'resort'
  limit 1
) source
where not exists (
  select 1 from public.packages existing
  where lower(existing.name) = lower(values_to_add.name)
);

update public.packages
set price = configured.price,
    package_category = 'pool_tour',
    pricing_mode = 'per_guest',
    min_guest_count = configured.minimum_guests,
    cottage_fee = configured.cottage_fee,
    resource_mode = 'shared_capacity',
    schedule_mode = 'fixed',
    fixed_start_time = configured.start_time,
    fixed_end_time = configured.end_time,
    resource_key = null,
    updated_at = now()
from (
  values
    ('day tour', 100::numeric, 1, 700::numeric, '08:00'::time, '15:00'::time),
    ('night tour', 150::numeric, 1, 700::numeric, '16:00'::time, '22:00'::time),
    ('overnight tour', 200::numeric, 20, 1000::numeric, '19:00'::time, '04:00'::time)
) configured(name, price, minimum_guests, cottage_fee, start_time, end_time)
where lower(public.packages.name) = configured.name;

-- Venue offerings are catalogued, but remain unbookable until operating hours
-- and a real venue resource are configured by the business.
insert into public.packages (
  name, description, service_type, price, guest_capacity, menu_items, add_ons,
  is_active, package_category, pricing_mode, min_guest_count, pool_access_fee,
  resource_mode, schedule_mode, duration_minutes
)
select values_to_add.name, values_to_add.description, source.service_type,
  values_to_add.price, null, array[]::text[], array[]::text[], true,
  'event_venue', 'fixed', 1, 5000, 'exclusive', 'customer_select',
  values_to_add.duration_minutes
from (
  values
    ('Non-Air-Conditioned Venue', 'Venue-only reservation for five hours.', 10000::numeric, 300),
    ('Air-Conditioned Venue', 'Air-conditioned venue-only reservation for four hours.', 15000::numeric, 240)
) as values_to_add(name, description, price, duration_minutes)
cross join lateral (
  select service_type from public.packages
  where lower(service_type::text) = 'resort'
  limit 1
) source
where not exists (
  select 1 from public.packages existing
  where lower(existing.name) = lower(values_to_add.name)
);

create or replace function public.evently_set_reservation_resource_name()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if nullif(trim(new.resource_key), '') is null then
    new.resource_name := null;
  else
    select resource.resource_name into new.resource_name
    from public.evently_resources resource
    where lower(resource.resource_key) = lower(new.resource_key)
      and resource.is_active;
  end if;
  return new;
end;
$$;

drop trigger if exists evently_set_reservation_resource_name on public.reservations;
create trigger evently_set_reservation_resource_name
before insert or update of resource_key on public.reservations
for each row execute function public.evently_set_reservation_resource_name();

update public.reservations reservation
set resource_name = resource.resource_name
from public.evently_resources resource
where lower(resource.resource_key) = lower(reservation.resource_key)
  and reservation.resource_name is distinct from resource.resource_name;

-- A shared pool tour is not made unavailable by another guest's reservation.
-- Exclusive fixed resources remain protected from confirmed overlaps.
create or replace function public.evently_check_availability(
  p_package_id uuid,
  p_reservation_date date
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when package.resource_mode <> 'exclusive'
      or package.resource_key is null
      or package.schedule_mode <> 'fixed'
      then true
    else not exists (
      select 1
      from public.reservations reservation
      where reservation.reservation_date = p_reservation_date
        and lower(reservation.resource_key) = lower(package.resource_key)
        and lower(reservation.status::text) = 'confirmed'
        and reservation.start_time is not null
        and reservation.end_time is not null
        and p_reservation_date + package.fixed_start_time
          < reservation.reservation_date + reservation.end_time
            + case when reservation.end_time <= reservation.start_time then interval '1 day' else interval '0 day' end
        and p_reservation_date + package.fixed_end_time
            + case when package.fixed_end_time <= package.fixed_start_time then interval '1 day' else interval '0 day' end
          > reservation.reservation_date + reservation.start_time
    )
  end
  from public.packages package
  where package.id = p_package_id and package.is_active;
$$;

-- Preserve all validation in the existing schedule-aware RPC and layer the
-- new server-authoritative pricing rules around it.
do $$
begin
  if to_regprocedure('public.create_evently_reservation_before_staycation(jsonb)') is null then
    alter function public.create_evently_reservation(jsonb)
      rename to create_evently_reservation_before_staycation;
  end if;
end;
$$;

revoke all on function public.create_evently_reservation_before_staycation(jsonb) from public, anon;

create or replace function public.create_evently_reservation(p_booking jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_package public.packages%rowtype;
  v_variant public.package_variants%rowtype;
  v_existing public.reservations%rowtype;
  v_result jsonb;
  v_reservation_id uuid;
  v_order_id uuid;
  v_guest_count integer;
  v_nights integer := greatest(1, coalesce(nullif(p_booking ->> 'nights', '')::integer, 1));
  v_base_price numeric(12,2);
  v_addon_total numeric(12,2);
  v_cottage_selected boolean := coalesce(nullif(p_booking ->> 'cottage_selected', '')::boolean, false);
  v_pool_selected boolean := coalesce(nullif(p_booking ->> 'pool_access_selected', '')::boolean, false);
  v_cottage_fee numeric(12,2);
  v_pool_fee numeric(12,2);
  v_subtotal numeric(12,2);
  v_deposit numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;

  select * into v_existing
  from public.reservations
  where customer_id = auth.uid()
    and client_request_id = (p_booking ->> 'idempotency_key')::uuid;
  if found then
    return jsonb_build_object(
      'reservation_id', v_existing.id,
      'reservation_code', v_existing.reservation_code,
      'subtotal', v_existing.total_amount,
      'deposit_amount', v_existing.deposit_amount,
      'remaining_balance', v_existing.remaining_balance,
      'start_time', v_existing.start_time,
      'end_time', v_existing.end_time,
      'schedule_mode', v_existing.schedule_mode
    );
  end if;

  select * into v_package
  from public.packages
  where id = (p_booking ->> 'package_id')::uuid and is_active
  for share;
  if not found then raise exception 'The selected package is unavailable'; end if;

  if nullif(p_booking ->> 'package_variant_id', '') is not null then
    select * into v_variant
    from public.package_variants
    where id = (p_booking ->> 'package_variant_id')::uuid
      and package_id = v_package.id and is_active
    for share;
    if not found then raise exception 'The selected package variant is unavailable'; end if;
  end if;

  v_guest_count := (p_booking ->> 'guest_count')::integer;
  if v_guest_count < v_package.min_guest_count then
    raise exception 'This package requires at least % guests', v_package.min_guest_count;
  end if;
  if v_cottage_selected and v_package.cottage_fee <= 0 then
    raise exception 'A cottage is not available for this package';
  end if;
  if v_pool_selected and v_package.pool_access_fee <= 0 then
    raise exception 'Optional pool access is not available for this package';
  end if;

  v_result := public.create_evently_reservation_before_staycation(p_booking);
  v_reservation_id := (v_result ->> 'reservation_id')::uuid;
  v_order_id := nullif(v_result ->> 'order_id', '')::uuid;

  select coalesce(sum(price * quantity), 0) into v_addon_total
  from public.reservation_addons
  where reservation_id = v_reservation_id;

  v_base_price := case v_package.pricing_mode
    when 'per_guest' then coalesce(v_variant.price, v_package.price) * v_guest_count
    when 'per_night' then coalesce(v_variant.price, v_package.price) * v_nights
    else coalesce(v_variant.price, v_package.price)
  end;
  v_cottage_fee := case when v_cottage_selected then v_package.cottage_fee else 0 end;
  v_pool_fee := case when v_pool_selected then v_package.pool_access_fee else 0 end;
  v_subtotal := v_base_price + v_addon_total + v_cottage_fee + v_pool_fee;
  v_deposit := round(
    v_subtotal * least(100, greatest(0, coalesce(v_package.deposit_percentage, 0))) / 100,
    2
  );

  update public.reservations
  set subtotal = v_subtotal,
      total_amount = v_subtotal,
      deposit_amount = v_deposit,
      remaining_balance = greatest(v_subtotal - amount_paid, 0),
      tour_slot = case when v_package.package_category = 'pool_tour' then v_package.name else null end,
      cottage_selected = v_cottage_selected,
      cottage_fee = v_cottage_fee,
      pool_access_selected = v_pool_selected,
      pool_access_fee = v_pool_fee,
      pricing_mode = v_package.pricing_mode,
      resource_mode = v_package.resource_mode,
      updated_at = now()
  where id = v_reservation_id and customer_id = auth.uid();

  update public.orders
  set total_amount = v_subtotal,
      remaining_balance = greatest(v_subtotal - amount_paid, 0),
      tour_slot = case when v_package.package_category = 'pool_tour' then v_package.name else null end,
      cottage_selected = v_cottage_selected,
      cottage_fee = v_cottage_fee,
      pool_access_selected = v_pool_selected,
      pool_access_fee = v_pool_fee,
      updated_at = now()
  where id = v_order_id and customer_id = auth.uid();

  return v_result || jsonb_build_object(
    'subtotal', v_subtotal,
    'deposit_amount', v_deposit,
    'remaining_balance', v_subtotal,
    'tour_slot', case when v_package.package_category = 'pool_tour' then v_package.name else null end,
    'cottage_fee', v_cottage_fee,
    'pool_access_fee', v_pool_fee
  );
end;
$$;

revoke all on function public.create_evently_reservation(jsonb) from public, anon;
grant execute on function public.create_evently_reservation(jsonb) to authenticated;

-- Reuse the existing approval implementation for exclusive/admin-assigned
-- resources. Shared pool tours are validated against their fixed package
-- schedule, then approved without assigning the shared pool as an exclusive
-- resource.
do $$
begin
  if to_regprocedure('public.evently_admin_approve_booking_before_shared_pool(uuid,boolean)') is null then
    alter function public.evently_admin_approve_booking(uuid, boolean)
      rename to evently_admin_approve_booking_before_shared_pool;
  end if;
end;
$$;

revoke all on function public.evently_admin_approve_booking_before_shared_pool(uuid, boolean) from public, anon;

create or replace function public.evently_admin_approve_booking(
  p_reservation_id uuid,
  p_schedule_verified boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.reservations%rowtype;
  v_fixed_start time;
  v_fixed_end time;
  v_original_mode text;
  v_result jsonb;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;

  select * into v_reservation
  from public.reservations
  where id = p_reservation_id
  for update;
  if not found then raise exception 'Reservation not found'; end if;

  if v_reservation.resource_mode <> 'shared_capacity' then
    return public.evently_admin_approve_booking_before_shared_pool(
      p_reservation_id, p_schedule_verified
    );
  end if;

  if p_schedule_verified is not true then raise exception 'Schedule verification is required'; end if;
  if lower(v_reservation.status::text) <> 'pending' then
    raise exception 'Only pending reservations can be approved';
  end if;

  select coalesce(variant.fixed_start_time, package.fixed_start_time),
         coalesce(variant.fixed_end_time, package.fixed_end_time)
  into v_fixed_start, v_fixed_end
  from public.packages package
  left join public.package_variants variant
    on variant.id = v_reservation.package_variant_id
  where package.id = v_reservation.package_id;

  if v_fixed_start is null or v_fixed_end is null
     or v_reservation.start_time <> v_fixed_start
     or v_reservation.end_time <> v_fixed_end then
    raise exception 'The shared tour reservation does not match its fixed schedule';
  end if;

  v_original_mode := v_reservation.schedule_mode;
  update public.reservations set schedule_mode = 'untimed'
  where id = p_reservation_id;

  v_result := public.evently_admin_approve_booking_before_shared_pool(
    p_reservation_id, true
  );

  update public.reservations
  set schedule_mode = v_original_mode, updated_at = now()
  where id = p_reservation_id;

  return v_result || jsonb_build_object(
    'start_time', v_fixed_start,
    'end_time', v_fixed_end,
    'resource_key', null
  );
end;
$$;

revoke all on function public.evently_admin_approve_booking(uuid, boolean) from public, anon;
grant execute on function public.evently_admin_approve_booking(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
