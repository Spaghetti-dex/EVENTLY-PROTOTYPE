-- Additive compatibility for the existing Supabase catalog/resource schema.
-- Physical locations below are selected only from the exact address text stored
-- on the live package records; no capacity or air-conditioning inference is used.

alter table public.evently_resources
  add column if not exists is_exclusive boolean not null default true,
  add column if not exists capacity integer,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

alter table public.packages
  add column if not exists package_category text,
  add column if not exists resource_mode text not null default 'admin_assign',
  add column if not exists fixed_start_time time,
  add column if not exists fixed_end_time time;

alter table public.package_variants
  add column if not exists schedule_mode text,
  add column if not exists fixed_start_time time,
  add column if not exists fixed_end_time time,
  add column if not exists duration_minutes integer,
  add column if not exists operating_start_time time,
  add column if not exists operating_end_time time;

alter table public.reservations
  add column if not exists schedule_mode text not null default 'admin_assign',
  add column if not exists resource_mode text not null default 'admin_assign',
  add column if not exists resource_name text;

-- Seed only venues whose real physical location is explicitly recorded in the
-- selected package descriptions. Keep existing resource rows and admin edits.
insert into public.evently_resources (
  resource_key, resource_name, resource_type, location_description,
  is_active, is_exclusive
) values
  (
    'catering-alfamart-daffodil-2f',
    'Daffodil Events Place',
    'event_venue',
    '2nd Floor Alfamart, Daffodil St., Brgy. Rizal',
    true,
    true
  ),
  (
    'catering-alfamart-amarillo-4f',
    'Alfamart Amarillo — 4th Floor',
    'event_venue',
    '4th Floor Alfamart, Amarillo St., Brgy. Rizal',
    true,
    true
  ),
  (
    'catering-alfamart-amarillo-3f',
    'Alfamart Amarillo — 3rd Floor',
    'event_venue',
    '3rd Floor Alfamart, Amarillo St., Brgy. Rizal',
    true,
    true
  )
on conflict (resource_key) do nothing;

-- Package 1: the package's stored address is the Daffodil Events Place venue.
update public.packages package
set resource_key = coalesce(nullif(trim(package.resource_key), ''), 'catering-alfamart-daffodil-2f'),
    resource_mode = 'exclusive',
    package_category = 'event_venue',
    schedule_mode = case
      when lower(package.schedule_mode) in ('fixed', 'customer_select', 'admin_assign') then package.schedule_mode
      else 'customer_select'
    end,
    updated_at = now()
where lower(package.description) like '%2nd floor alfamart, daffodil st.%';

-- Package 2 products share the single 4th-floor resource because their stored
-- descriptions specify that same physical location. Do not derive this from pax.
update public.packages package
set resource_key = coalesce(nullif(trim(package.resource_key), ''), 'catering-alfamart-amarillo-4f'),
    resource_mode = 'exclusive',
    package_category = 'event_venue',
    schedule_mode = case
      when lower(package.schedule_mode) in ('fixed', 'customer_select', 'admin_assign') then package.schedule_mode
      else 'admin_assign'
    end,
    updated_at = now()
where lower(package.description) like '%4th floor alfamart, amarillo st.%';

-- Package 3 products share the single 3rd-floor resource because their stored
-- descriptions specify that same physical location. Do not derive this from AC.
update public.packages package
set resource_key = coalesce(nullif(trim(package.resource_key), ''), 'catering-alfamart-amarillo-3f'),
    resource_mode = 'exclusive',
    package_category = 'event_venue',
    schedule_mode = case
      when lower(package.schedule_mode) in ('fixed', 'customer_select', 'admin_assign') then package.schedule_mode
      else 'admin_assign'
    end,
    updated_at = now()
where lower(package.description) like '%3rd floor alfamart, amarillo st.%';

-- A saved variant venue remains authoritative. Only fill missing variant links
-- from its parent package, so same-place variants share the same resource key.
update public.package_variants variant
set resource_key = package.resource_key
from public.packages package
where variant.package_id = package.id
  and package.resource_key is not null
  and nullif(trim(variant.resource_key), '') is null;

-- Outside-venue catering expressly uses the customer's venue, not an
-- Evently-owned facility, and therefore does not consume an Evently resource.
update public.packages package
set package_category = 'outside_catering',
    resource_mode = 'shared_capacity',
    updated_at = now()
where lower(package.name) like '%outside venue catering%'
   or lower(package.description) like '%customer-provided venue%';

-- Resort rooms and resort venue rentals have no package-to-inventory mapping in
-- the catalog. Require an Admin to choose a registered room/facility instead of
-- fabricating inventory or changing package prices/details.
update public.packages package
set package_category = case
      when lower(package.name) like '%room%' then 'room'
      when lower(package.name) like '%venue only%' then 'event_venue'
      else package.package_category
    end,
    resource_mode = 'exclusive',
    schedule_mode = case
      when lower(package.schedule_mode) in ('fixed', 'customer_select', 'admin_assign') then package.schedule_mode
      else 'admin_assign'
    end,
    updated_at = now()
where lower(package.service_type::text) = 'resort'
  and (lower(package.name) like '%room%' or lower(package.name) like '%venue only%');

-- Preserve all saved resource choices. Backfill only reservations with no
-- assignment from their selected variant/package relationship.
update public.reservations reservation
set resource_key = coalesce(
      nullif(trim(reservation.resource_key), ''),
      nullif(trim((select variant.resource_key
        from public.package_variants variant
        where variant.id = reservation.package_variant_id
          and variant.package_id = package.id)), ''),
      nullif(trim(package.resource_key), '')
    ),
    resource_mode = coalesce(package.resource_mode, reservation.resource_mode),
    schedule_mode = case
      when lower(coalesce(package.schedule_mode, '')) in ('timed', 'fixed', 'customer_select', 'admin_assign')
        then package.schedule_mode
      when lower(coalesce(package.schedule_mode, '')) = 'untimed' then 'untimed'
      else reservation.schedule_mode
    end,
    updated_at = now()
from public.packages package
where package.id = reservation.package_id
  and (
    (nullif(trim(reservation.resource_key), '') is null and nullif(trim(package.resource_key), '') is not null)
    or reservation.resource_mode is distinct from package.resource_mode
    or reservation.schedule_mode is distinct from package.schedule_mode
  );

-- Normalize legacy `timed` values from the live catalog to modes understood by
-- the established schedule RPC. Package 1 has stored duration/operating hours;
-- Package 2/3 have venue duration but no customer time selection configured.
update public.packages
set schedule_mode = case
      when lower(description) like '%2nd floor alfamart, daffodil st.%' then 'customer_select'
      when lower(description) like '%4th floor alfamart, amarillo st.%'
        or lower(description) like '%3rd floor alfamart, amarillo st.%' then 'admin_assign'
      else schedule_mode
    end,
    updated_at = now()
where lower(schedule_mode) in ('timed', 'untimed');

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
  and resource.is_active
  and reservation.resource_name is distinct from resource.resource_name;

-- Keep the established customer booking/payment RPC intact, then snapshot the
-- active saved/package/variant resource onto the reservation. This is a wrapper
-- around the existing authorized booking function, not a replacement workflow.
do $$
begin
  if to_regprocedure('public.create_evently_reservation_before_exact_resource_assignment(jsonb)') is null then
    alter function public.create_evently_reservation(jsonb)
      rename to create_evently_reservation_before_exact_resource_assignment;
  end if;
end;
$$;

revoke all on function public.create_evently_reservation_before_exact_resource_assignment(jsonb)
  from public, anon, authenticated;

create or replace function public.create_evently_reservation(p_booking jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_reservation public.reservations%rowtype;
  v_package public.packages%rowtype;
  v_variant public.package_variants%rowtype;
  v_reservation_id uuid;
  v_existing_id uuid;
  v_resource_key text;
  v_active_resource_key text;
  v_resource_mode text;
  v_schedule_mode text;
  v_start timestamp;
  v_end timestamp;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if jsonb_typeof(p_booking) is distinct from 'object' then raise exception 'Booking details are required'; end if;

  if nullif(p_booking ->> 'idempotency_key', '') is not null then
    select reservation.id into v_existing_id
    from public.reservations reservation
    where reservation.customer_id = auth.uid()
      and reservation.client_request_id = (p_booking ->> 'idempotency_key')::uuid;
  end if;
  v_result := public.create_evently_reservation_before_exact_resource_assignment(p_booking);
  v_reservation_id := nullif(v_result ->> 'reservation_id', '')::uuid;
  if v_reservation_id is null then raise exception 'The booking RPC did not return a reservation'; end if;

  select * into v_reservation from public.reservations
  where id = v_reservation_id and customer_id = auth.uid() for update;
  if not found then raise exception 'The saved reservation is not available to this account'; end if;
  select * into v_package from public.packages where id = v_reservation.package_id;
  if not found then raise exception 'The selected package no longer exists'; end if;
  if v_reservation.package_variant_id is not null then
    select * into v_variant from public.package_variants
    where id = v_reservation.package_variant_id and package_id = v_package.id;
  end if;

  if nullif(trim(v_reservation.resource_key), '') is not null then
    select resource.resource_key into v_active_resource_key
    from public.evently_resources resource
    where lower(resource.resource_key) = lower(v_reservation.resource_key)
      and resource.is_active;
  end if;
  if v_active_resource_key is null and nullif(trim(v_variant.resource_key), '') is not null then
    select resource.resource_key into v_active_resource_key
    from public.evently_resources resource
    where lower(resource.resource_key) = lower(v_variant.resource_key)
      and resource.is_active;
  end if;
  if v_active_resource_key is null and nullif(trim(v_package.resource_key), '') is not null then
    select resource.resource_key into v_active_resource_key
    from public.evently_resources resource
    where lower(resource.resource_key) = lower(v_package.resource_key)
      and resource.is_active;
  end if;
  v_resource_key := coalesce(
    v_active_resource_key,
    nullif(trim(v_variant.resource_key), ''),
    nullif(trim(v_package.resource_key), ''),
    nullif(trim(v_reservation.resource_key), '')
  );
  v_resource_mode := case
    when v_reservation.resource_mode is null
      or (v_reservation.resource_mode = 'admin_assign' and v_package.resource_mode <> 'admin_assign')
      then coalesce(v_package.resource_mode, v_reservation.resource_mode, 'admin_assign')
    else v_reservation.resource_mode
  end;
  v_schedule_mode := case
    when v_reservation.schedule_mode is null
      or (v_reservation.schedule_mode = 'admin_assign' and v_package.schedule_mode <> 'admin_assign'
        and v_reservation.start_time is null and v_reservation.end_time is null)
      then coalesce(v_package.schedule_mode, v_reservation.schedule_mode, 'admin_assign')
    else v_reservation.schedule_mode
  end;

  update public.reservations
  set resource_key = coalesce(v_resource_key, resource_key),
      resource_mode = v_resource_mode,
      schedule_mode = v_schedule_mode,
      updated_at = now()
  where id = v_reservation_id;

  -- Validate the selected time against active bookings at submit time when the
  -- package already resolves to an exclusive resource. Admin-assigned schedules
  -- are checked when saved and again by the approval RPC.
  if v_existing_id is null
     and v_resource_mode = 'exclusive'
     and v_resource_key is not null
     and v_reservation.reservation_date is not null
     and v_reservation.start_time is not null
     and v_reservation.end_time is not null then
    if not exists (
      select 1 from public.evently_resources resource
      where lower(resource.resource_key) = lower(v_resource_key) and resource.is_active
    ) then raise exception 'The selected package venue is not active'; end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
      'evently-resource:' || lower(v_resource_key) || ':' || v_reservation.reservation_date::text, 0
    ));
    v_start := v_reservation.reservation_date + v_reservation.start_time;
    v_end := v_reservation.reservation_date + v_reservation.end_time
      + case when v_reservation.end_time <= v_reservation.start_time then interval '1 day' else interval '0 day' end;
    if exists (
      select 1 from public.reservations other
      left join public.packages other_package on other_package.id = other.package_id
      left join public.package_variants other_variant
        on other_variant.id = other.package_variant_id and other_variant.package_id = other_package.id
      where other.id <> v_reservation_id
        and lower(trim(coalesce(nullif(other.resource_key, ''), other_variant.resource_key, other_package.resource_key, ''))) = lower(v_resource_key)
        and lower(other.status::text) not in ('cancelled', 'rejected', 'completed')
        and other.reservation_date is not null
        and (
          ((other.start_time is null or other.end_time is null)
            and other.reservation_date = v_reservation.reservation_date)
          or (
            other.start_time is not null and other.end_time is not null
            and other.reservation_date + other.start_time < v_end
            and other.reservation_date + other.end_time
              + case when other.end_time <= other.start_time then interval '1 day' else interval '0 day' end > v_start
          )
        )
    ) then raise exception 'This venue is held by another active reservation during the selected time'; end if;
  end if;

  return v_result || jsonb_build_object('resource_key', v_resource_key);
end;
$$;

revoke all on function public.create_evently_reservation(jsonb) from public, anon;
grant execute on function public.create_evently_reservation(jsonb) to authenticated;

notify pgrst, 'reload schema';
