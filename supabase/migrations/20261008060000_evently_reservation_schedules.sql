-- Add explicit schedule metadata without inferring hours from service or package names.

alter table public.packages
  add column if not exists schedule_mode text not null default 'admin_assign',
  add column if not exists fixed_start_time time,
  add column if not exists fixed_end_time time,
  add column if not exists duration_minutes integer,
  add column if not exists operating_start_time time,
  add column if not exists operating_end_time time,
  add column if not exists resource_key text;

alter table public.package_variants
  add column if not exists schedule_mode text,
  add column if not exists fixed_start_time time,
  add column if not exists fixed_end_time time,
  add column if not exists duration_minutes integer,
  add column if not exists operating_start_time time,
  add column if not exists operating_end_time time,
  add column if not exists resource_key text;

alter table public.reservations
  add column if not exists schedule_mode text not null default 'admin_assign';

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'packages_schedule_mode_check'
      and conrelid = 'public.packages'::regclass
  ) then
    alter table public.packages add constraint packages_schedule_mode_check
      check (schedule_mode in ('untimed', 'fixed', 'customer_select', 'admin_assign'));
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'package_variants_schedule_mode_check'
      and conrelid = 'public.package_variants'::regclass
  ) then
    alter table public.package_variants add constraint package_variants_schedule_mode_check
      check (schedule_mode is null or schedule_mode in ('untimed', 'fixed', 'customer_select', 'admin_assign'));
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'reservations_schedule_mode_check'
      and conrelid = 'public.reservations'::regclass
  ) then
    alter table public.reservations add constraint reservations_schedule_mode_check
      check (schedule_mode in ('untimed', 'fixed', 'customer_select', 'admin_assign'));
  end if;
end;
$$;

update public.packages
set schedule_mode = 'fixed', fixed_start_time = '08:00:00', fixed_end_time = '15:00:00'
where lower(name) in ('resort day tour', 'day tour admission');

update public.packages
set schedule_mode = 'fixed', fixed_start_time = '16:00:00', fixed_end_time = '22:00:00'
where lower(name) in ('resort night tour', 'night tour admission');

update public.packages
set schedule_mode = 'fixed', fixed_start_time = '19:00:00', fixed_end_time = '04:00:00'
where lower(name) in ('resort overnight tour', 'overnight resort stay');

update public.packages
set schedule_mode = 'customer_select', duration_minutes = 240
where lower(service_type::text) = 'catering';

update public.reservations reservation
set schedule_mode = package.schedule_mode,
    resource_key = coalesce(reservation.resource_key, package.resource_key),
    start_time = case when package.schedule_mode = 'fixed' then package.fixed_start_time else reservation.start_time end,
    end_time = case when package.schedule_mode = 'fixed' then package.fixed_end_time else reservation.end_time end
from public.packages package
where package.id = reservation.package_id;

create index if not exists reservations_confirmed_schedule_idx
  on public.reservations (reservation_date, resource_key, start_time, end_time)
  where status = 'confirmed';

do $$
begin
  if to_regprocedure('public.create_evently_reservation_legacy(jsonb)') is null then
    alter function public.create_evently_reservation(jsonb)
      rename to create_evently_reservation_legacy;
  end if;
end;
$$;

revoke all on function public.create_evently_reservation_legacy(jsonb) from public, anon, authenticated;

create or replace function public.create_evently_reservation(p_booking jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_package public.packages%rowtype;
  v_variant public.package_variants%rowtype;
  v_variant_id uuid;
  v_existing public.reservations%rowtype;
  v_mode text;
  v_start time;
  v_end time;
  v_resource text;
  v_duration_minutes integer;
  v_operating_start time;
  v_operating_end time;
  v_selected_start timestamp;
  v_selected_end timestamp;
  v_operating_window_start timestamp;
  v_operating_window_end timestamp;
  v_payload jsonb := p_booking;
  v_result jsonb;
  v_reservation_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if coalesce(p_booking ->> 'idempotency_key', '') = '' then raise exception 'An idempotency key is required'; end if;

  select * into v_existing
  from public.reservations
  where customer_id = auth.uid()
    and client_request_id = (p_booking ->> 'idempotency_key')::uuid;
  if found then
    return public.create_evently_reservation_legacy(p_booking);
  end if;

  select * into v_package
  from public.packages
  where id = (p_booking ->> 'package_id')::uuid
    and is_active
  for share;
  if not found then raise exception 'The selected package is unavailable'; end if;

  v_variant_id := nullif(p_booking ->> 'package_variant_id', '')::uuid;
  if v_variant_id is not null then
    select * into v_variant
    from public.package_variants
    where id = v_variant_id
      and package_id = v_package.id
      and is_active
    for share;
    if not found then raise exception 'The selected package variant is unavailable'; end if;
  end if;

  v_mode := coalesce(v_variant.schedule_mode, v_package.schedule_mode, 'admin_assign');
  v_resource := nullif(trim(coalesce(v_variant.resource_key, v_package.resource_key, '')), '');

  if v_mode = 'fixed' then
    v_start := coalesce(v_variant.fixed_start_time, v_package.fixed_start_time);
    v_end := coalesce(v_variant.fixed_end_time, v_package.fixed_end_time);
    if v_start is null or v_end is null or v_end = v_start then
      raise exception 'This fixed-schedule package has an invalid configured start or end time';
    end if;
    v_payload := jsonb_set(jsonb_set(v_payload, '{start_time}', to_jsonb(v_start::text)), '{end_time}', to_jsonb(v_end::text));
  elsif v_mode = 'customer_select' then
    v_start := nullif(trim(p_booking ->> 'start_time'), '')::time;
    v_end := nullif(trim(p_booking ->> 'end_time'), '')::time;
    if v_start is null or v_end is null then
      raise exception 'Start and end times are required for this package';
    end if;
    if v_end = v_start then raise exception 'Start and end times must be different'; end if;
    v_duration_minutes := coalesce(v_variant.duration_minutes, v_package.duration_minutes);
    v_operating_start := coalesce(v_variant.operating_start_time, v_package.operating_start_time);
    v_operating_end := coalesce(v_variant.operating_end_time, v_package.operating_end_time);
    if v_duration_minutes is null or v_duration_minutes < 1 then
      raise exception 'This package has no configured booking duration';
    end if;
    if v_operating_start is null or v_operating_end is null or v_operating_start = v_operating_end then
      raise exception 'This package has no configured operating hours';
    end if;
    v_selected_start := date '2000-01-01' + v_start;
    v_selected_end := date '2000-01-01' + v_end
      + case when v_end <= v_start then interval '1 day' else interval '0 day' end;
    if extract(epoch from (v_selected_end - v_selected_start)) / 60 <> v_duration_minutes then
      raise exception 'The selected time does not match this package''s configured duration';
    end if;
    v_operating_window_start := date '2000-01-01' + v_operating_start;
    v_operating_window_end := date '2000-01-01' + v_operating_end
      + case when v_operating_end <= v_operating_start then interval '1 day' else interval '0 day' end;
    if v_selected_start < v_operating_window_start or v_selected_end > v_operating_window_end then
      raise exception 'The selected time is outside the configured operating hours';
    end if;
  else
    if nullif(trim(p_booking ->> 'start_time'), '') is not null
       or nullif(trim(p_booking ->> 'end_time'), '') is not null then
      raise exception 'Times cannot be submitted for a package that is not configured for customer scheduling';
    end if;
    v_start := null;
    v_end := null;
  end if;

  v_result := public.create_evently_reservation_legacy(v_payload);
  v_reservation_id := (v_result ->> 'reservation_id')::uuid;

  update public.reservations
  set start_time = v_start,
      end_time = v_end,
      schedule_mode = v_mode,
      resource_key = v_resource,
      updated_at = now()
  where id = v_reservation_id
    and customer_id = auth.uid();

  return v_result || jsonb_build_object(
    'start_time', v_start,
    'end_time', v_end,
    'schedule_mode', v_mode
  );
end;
$$;

revoke all on function public.create_evently_reservation(jsonb) from public, anon;
grant execute on function public.create_evently_reservation(jsonb) to authenticated;

create or replace function public.evently_admin_set_reservation_schedule(
  p_reservation_id uuid,
  p_start_time time,
  p_end_time time,
  p_resource_key text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.reservations%rowtype;
  v_resource text := nullif(lower(trim(p_resource_key)), '');
  v_fixed_start time;
  v_fixed_end time;
  v_fixed_resource text;
  v_new_start timestamp;
  v_new_end timestamp;
  v_duration_minutes integer;
  v_operating_start time;
  v_operating_end time;
  v_operating_window_start timestamp;
  v_operating_window_end timestamp;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    raise exception 'Distinct start and end times are required';
  end if;
  if v_resource is null then raise exception 'A verified venue or resource is required'; end if;

  select * into v_reservation
  from public.reservations
  where id = p_reservation_id
  for update;
  if not found then raise exception 'Reservation not found'; end if;
  if lower(v_reservation.status::text) <> 'pending' then
    raise exception 'Only pending reservations can have their schedule changed';
  end if;

  if v_reservation.schedule_mode = 'fixed' then
    select
      coalesce(variant.fixed_start_time, package.fixed_start_time),
      coalesce(variant.fixed_end_time, package.fixed_end_time),
      nullif(lower(trim(coalesce(variant.resource_key, package.resource_key, ''))), '')
    into v_fixed_start, v_fixed_end, v_fixed_resource
    from public.packages package
    left join public.package_variants variant
      on variant.id = v_reservation.package_variant_id
     and variant.package_id = package.id
    where package.id = v_reservation.package_id;
    if v_fixed_start is null or v_fixed_end is null or v_fixed_end = v_fixed_start then
      raise exception 'The fixed package schedule is not configured correctly';
    end if;
    if p_start_time <> v_fixed_start or p_end_time <> v_fixed_end then
      raise exception 'Fixed package times must match the configured package schedule';
    end if;
    if v_fixed_resource is not null and v_resource <> v_fixed_resource then
      raise exception 'Fixed package reservations must use the configured venue or resource';
    end if;
  end if;

  v_new_start := v_reservation.reservation_date + p_start_time;
  v_new_end := v_reservation.reservation_date + p_end_time
    + case when p_end_time <= p_start_time then interval '1 day' else interval '0 day' end;
  if v_reservation.schedule_mode = 'customer_select' then
    select
      coalesce(variant.duration_minutes, package.duration_minutes),
      coalesce(variant.operating_start_time, package.operating_start_time),
      coalesce(variant.operating_end_time, package.operating_end_time)
    into v_duration_minutes, v_operating_start, v_operating_end
    from public.packages package
    left join public.package_variants variant
      on variant.id = v_reservation.package_variant_id
     and variant.package_id = package.id
    where package.id = v_reservation.package_id;
    if v_duration_minutes is null
       or extract(epoch from (v_new_end - v_new_start)) / 60 <> v_duration_minutes then
      raise exception 'The schedule must match the package''s configured duration';
    end if;
    if v_operating_start is null or v_operating_end is null or v_operating_start = v_operating_end then
      raise exception 'This package has no configured operating hours';
    end if;
    v_operating_window_start := v_reservation.reservation_date + v_operating_start;
    v_operating_window_end := v_reservation.reservation_date + v_operating_end
      + case when v_operating_end <= v_operating_start then interval '1 day' else interval '0 day' end;
    if v_new_start < v_operating_window_start or v_new_end > v_operating_window_end then
      raise exception 'The schedule is outside the configured operating hours';
    end if;
  end if;
  if exists (
    select 1
    from public.reservations conflict
    where conflict.id <> p_reservation_id
      and lower(conflict.resource_key) = v_resource
      and lower(conflict.status::text) = 'confirmed'
      and conflict.start_time is not null
      and conflict.end_time is not null
      and conflict.reservation_date + conflict.start_time < v_new_end
      and conflict.reservation_date + conflict.end_time
        + case when conflict.end_time <= conflict.start_time then interval '1 day' else interval '0 day' end > v_new_start
  ) then
    raise exception 'This venue or resource already has a confirmed reservation during the selected time';
  end if;

  update public.reservations
  set start_time = p_start_time,
      end_time = p_end_time,
      resource_key = v_resource,
      schedule_mode = case when schedule_mode = 'untimed' then 'admin_assign' else schedule_mode end,
      updated_at = now()
  where id = p_reservation_id;

  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (
    auth.uid(),
    'reservation_schedule_changed',
    'reservation',
    p_reservation_id,
    concat(v_reservation.reservation_date, ' ', p_start_time, '–', p_end_time, ' @ ', v_resource)
  );
end;
$$;

revoke all on function public.evently_admin_set_reservation_schedule(uuid, time, time, text) from public, anon;
grant execute on function public.evently_admin_set_reservation_schedule(uuid, time, time, text) to authenticated;

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
  v_confirmed text;
  v_order_status_column text;
  v_order_confirmed text;
  v_fixed_start time;
  v_fixed_end time;
  v_fixed_resource text;
  v_duration_minutes integer;
  v_operating_start time;
  v_operating_end time;
  v_schedule_start timestamp;
  v_schedule_end timestamp;
  v_operating_window_start timestamp;
  v_operating_window_end timestamp;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if p_schedule_verified is not true then raise exception 'Schedule verification is required'; end if;

  select * into v_reservation
  from public.reservations
  where id = p_reservation_id
  for update;
  if not found then raise exception 'Reservation not found'; end if;
  if lower(v_reservation.status::text) <> 'pending' then
    raise exception 'Only pending reservations can be approved';
  end if;

  if v_reservation.schedule_mode <> 'untimed' then
    if v_reservation.start_time is null or v_reservation.end_time is null
       or v_reservation.end_time = v_reservation.start_time then
      raise exception 'Start and end times are required to approve a timed package reservation';
    end if;
    if nullif(trim(v_reservation.resource_key), '') is null then
      raise exception 'A verified venue or resource is required to approve this reservation';
    end if;
  end if;

  if v_reservation.schedule_mode = 'fixed' then
    select
      coalesce(variant.fixed_start_time, package.fixed_start_time),
      coalesce(variant.fixed_end_time, package.fixed_end_time),
      nullif(lower(trim(coalesce(variant.resource_key, package.resource_key, ''))), '')
    into v_fixed_start, v_fixed_end, v_fixed_resource
    from public.packages package
    left join public.package_variants variant
      on variant.id = v_reservation.package_variant_id
     and variant.package_id = package.id
    where package.id = v_reservation.package_id;
    if v_fixed_start is null or v_fixed_end is null
       or v_reservation.start_time <> v_fixed_start
       or v_reservation.end_time <> v_fixed_end
       or (v_fixed_resource is not null and lower(v_reservation.resource_key) <> v_fixed_resource) then
      raise exception 'The reservation does not match the configured fixed package schedule';
    end if;
  end if;

  if v_reservation.schedule_mode = 'customer_select' then
    select
      coalesce(variant.duration_minutes, package.duration_minutes),
      coalesce(variant.operating_start_time, package.operating_start_time),
      coalesce(variant.operating_end_time, package.operating_end_time)
    into v_duration_minutes, v_operating_start, v_operating_end
    from public.packages package
    left join public.package_variants variant
      on variant.id = v_reservation.package_variant_id
     and variant.package_id = package.id
    where package.id = v_reservation.package_id;
    v_schedule_start := v_reservation.reservation_date + v_reservation.start_time;
    v_schedule_end := v_reservation.reservation_date + v_reservation.end_time
      + case when v_reservation.end_time <= v_reservation.start_time then interval '1 day' else interval '0 day' end;
    if v_duration_minutes is null
       or extract(epoch from (v_schedule_end - v_schedule_start)) / 60 <> v_duration_minutes then
      raise exception 'The reservation does not match the package''s configured duration';
    end if;
    if v_operating_start is null or v_operating_end is null or v_operating_start = v_operating_end then
      raise exception 'This package has no configured operating hours';
    end if;
    v_operating_window_start := v_reservation.reservation_date + v_operating_start;
    v_operating_window_end := v_reservation.reservation_date + v_operating_end
      + case when v_operating_end <= v_operating_start then interval '1 day' else interval '0 day' end;
    if v_schedule_start < v_operating_window_start or v_schedule_end > v_operating_window_end then
      raise exception 'The reservation is outside the configured operating hours';
    end if;
  end if;

  if v_reservation.start_time is not null and exists (
    select 1
    from public.reservations conflict
    where conflict.id <> p_reservation_id
      and lower(conflict.resource_key) = lower(v_reservation.resource_key)
      and lower(conflict.status::text) = 'confirmed'
      and conflict.start_time is not null
      and conflict.end_time is not null
      and conflict.reservation_date + conflict.start_time < (
        v_reservation.reservation_date + v_reservation.end_time
        + case when v_reservation.end_time <= v_reservation.start_time then interval '1 day' else interval '0 day' end
      )
      and conflict.reservation_date + conflict.end_time
        + case when conflict.end_time <= conflict.start_time then interval '1 day' else interval '0 day' end
        > v_reservation.reservation_date + v_reservation.start_time
  ) then
    raise exception 'This venue or resource already has a confirmed reservation during the selected time';
  end if;

  v_confirmed := public.evently_status_value('public.reservations', 'status', 'confirmed');
  update public.reservations
  set status = v_confirmed::public.booking_status,
      updated_at = now()
  where id = p_reservation_id;

  v_order_status_column := public.evently_existing_column('public.orders', array['order_status', 'status']);
  if v_order_status_column is not null then
    v_order_confirmed := public.evently_status_value('public.orders', v_order_status_column, 'confirmed');
    execute format(
      'update public.orders set %I = %L, updated_at = now()
       where reservation_id = $1 and lower(%I::text) = ''pending''',
      v_order_status_column,
      v_order_confirmed,
      v_order_status_column
    ) using p_reservation_id;
  end if;

  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'reservation_approved', 'reservation', p_reservation_id, 'Schedule verified and reservation confirmed');

  insert into public.notifications (user_id, title, message, type, entity_type, entity_id, dedupe_key)
  values (
    v_reservation.customer_id,
    'Reservation confirmed',
    'Your reservation ' || v_reservation.reservation_code || ' has been confirmed.',
    'reservation_status',
    'reservation',
    p_reservation_id,
    'reservation-status:' || p_reservation_id || ':confirmed'
  )
  on conflict (dedupe_key) where dedupe_key is not null do nothing;

  return jsonb_build_object(
    'reservation_id', p_reservation_id,
    'status', v_confirmed,
    'start_time', v_reservation.start_time,
    'end_time', v_reservation.end_time,
    'resource_key', v_reservation.resource_key
  );
end;
$$;

revoke all on function public.evently_admin_approve_booking(uuid, boolean) from public, anon;
grant execute on function public.evently_admin_approve_booking(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
