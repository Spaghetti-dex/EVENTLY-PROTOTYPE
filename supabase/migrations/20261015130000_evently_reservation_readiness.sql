-- Keep reservation readiness and final approval consistent with package-backed
-- physical resources. Existing payment-proof and approval implementation stays
-- in the approval call chain.

create or replace function public.evently_admin_check_reservation_schedule(
  p_reservation_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.reservations%rowtype;
  v_package public.packages%rowtype;
  v_variant public.package_variants%rowtype;
  v_resource_key text;
  v_resource_name text;
  v_mode text;
  v_schedule_mode text;
  v_resource_required boolean;
  v_schedule_complete boolean;
  v_resource_valid boolean;
  v_conflict boolean := false;
  v_start timestamp;
  v_end timestamp;
  v_reason text;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  select * into v_reservation from public.reservations
  where id = p_reservation_id;
  if not found then raise exception 'Reservation not found'; end if;
  select * into v_package from public.packages where id = v_reservation.package_id;
  if not found then raise exception 'The reservation package no longer exists'; end if;
  if v_reservation.package_variant_id is not null then
    select * into v_variant from public.package_variants
    where id = v_reservation.package_variant_id and package_id = v_package.id;
  end if;

  v_mode := coalesce(v_reservation.resource_mode, v_package.resource_mode, 'admin_assign');
  v_schedule_mode := coalesce(v_reservation.schedule_mode, v_package.schedule_mode, 'admin_assign');
  v_resource_key := coalesce(
    nullif(trim(v_reservation.resource_key), ''),
    nullif(trim(v_variant.resource_key), ''),
    nullif(trim(v_package.resource_key), '')
  );
  v_resource_required := lower(coalesce(v_package.package_category, '')) <> 'outside_catering'
    and (
      lower(coalesce(v_package.package_category, '')) in ('event_venue', 'room')
      or v_mode = 'exclusive'
      or (v_resource_key is not null and v_mode <> 'shared_capacity')
    );
  v_schedule_complete := v_reservation.reservation_date is not null
    and (v_schedule_mode = 'untimed'
      or (
      v_reservation.start_time is not null
      and v_reservation.end_time is not null
      and v_reservation.start_time <> v_reservation.end_time
      ));

  if v_resource_key is not null then
    select resource.resource_name into v_resource_name
    from public.evently_resources resource
    where lower(resource.resource_key) = lower(v_resource_key)
      and resource.is_active;
  end if;
  if v_resource_name is null then
    v_resource_name := null;
    v_resource_key := nullif(trim(v_variant.resource_key), '');
    if v_resource_key is not null then
      select resource.resource_name into v_resource_name
      from public.evently_resources resource
      where lower(resource.resource_key) = lower(v_resource_key) and resource.is_active;
    end if;
    if v_resource_name is null then
      v_resource_key := nullif(trim(v_package.resource_key), '');
      if v_resource_key is not null then
        select resource.resource_name into v_resource_name
        from public.evently_resources resource
        where lower(resource.resource_key) = lower(v_resource_key) and resource.is_active;
      end if;
    end if;
  end if;
  v_resource_valid := not v_resource_required or (
    v_resource_key is not null and v_resource_name is not null
  );

  if v_resource_required and v_schedule_complete and v_resource_valid then
    if v_reservation.start_time is not null and v_reservation.end_time is not null then
      v_start := v_reservation.reservation_date + v_reservation.start_time;
      v_end := v_reservation.reservation_date + v_reservation.end_time
        + case when v_reservation.end_time <= v_reservation.start_time then interval '1 day' else interval '0 day' end;
    end if;
    select exists (
      select 1 from public.reservations other
      left join public.packages other_package on other_package.id = other.package_id
      left join public.package_variants other_variant
        on other_variant.id = other.package_variant_id and other_variant.package_id = other_package.id
      where other.id <> v_reservation.id
        and lower(trim(coalesce(nullif(other.resource_key, ''), other_variant.resource_key, other_package.resource_key, ''))) = lower(v_resource_key)
        and lower(other.status::text) not in ('cancelled', 'rejected', 'completed')
        and other.reservation_date is not null
        and (
          (v_start is null and other.reservation_date = v_reservation.reservation_date)
          or (
            v_start is not null and (
              ((other.start_time is null or other.end_time is null)
                and other.reservation_date = v_reservation.reservation_date)
              or (
                other.start_time is not null and other.end_time is not null
                and other.reservation_date + other.start_time < v_end
                and other.reservation_date + other.end_time
                  + case when other.end_time <= other.start_time then interval '1 day' else interval '0 day' end > v_start
              )
            )
          )
        )
    ) into v_conflict;
  end if;

  v_reason := case
    when not v_schedule_complete then 'Reservation date and, when required, distinct start/end times are required.'
    when not v_resource_valid then 'The required package venue/resource is not configured as active.'
    when v_conflict then 'Another active reservation holds this venue during the selected time.'
    else null
  end;
  return jsonb_build_object(
    'schedule_required', v_schedule_mode <> 'untimed',
    'schedule_complete', v_schedule_complete,
    'resource_required', v_resource_required,
    'resource_valid', v_resource_valid,
    'resource_key', v_resource_key,
    'resource_name', v_resource_name,
    'no_conflict', not v_conflict,
    'conflict', v_conflict,
    'reason', v_reason
  );
end;
$$;

revoke all on function public.evently_admin_check_reservation_schedule(uuid) from public, anon;
grant execute on function public.evently_admin_check_reservation_schedule(uuid) to authenticated;

-- The original schedule RPC remains the authoritative schedule validator and
-- writer. This wrapper adds a shared per-resource/date lock and checks every
-- venue-holding state before delegating; cancelled/rejected/completed do not hold.
do $$
begin
  if to_regprocedure('public.evently_admin_set_reservation_schedule_before_active_conflict(uuid,time,time,text)') is null then
    alter function public.evently_admin_set_reservation_schedule(uuid, time, time, text)
      rename to evently_admin_set_reservation_schedule_before_active_conflict;
  end if;
end;
$$;

revoke all on function public.evently_admin_set_reservation_schedule_before_active_conflict(uuid,time,time,text)
  from public, anon, authenticated;

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
  v_package public.packages%rowtype;
  v_variant public.package_variants%rowtype;
  v_resource text := lower(trim(coalesce(p_resource_key, '')));
  v_resource_mode text;
  v_schedule_mode text;
  v_resource_required boolean;
  v_fixed_start time;
  v_fixed_end time;
  v_duration integer;
  v_operating_start time;
  v_operating_end time;
  v_start timestamp;
  v_end timestamp;
  v_window_start timestamp;
  v_window_end timestamp;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  select * into v_reservation from public.reservations
  where id = p_reservation_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.reservation_date is null or p_start_time is null or p_end_time is null or p_start_time = p_end_time then
    raise exception 'A reservation date and distinct start/end times are required';
  end if;
  select * into v_package from public.packages where id = v_reservation.package_id;
  if not found then raise exception 'The reservation package no longer exists'; end if;
  if v_reservation.package_variant_id is not null then
    select * into v_variant from public.package_variants
    where id = v_reservation.package_variant_id and package_id = v_package.id;
  end if;
  v_resource_mode := coalesce(v_reservation.resource_mode, v_package.resource_mode, 'admin_assign');
  v_schedule_mode := coalesce(v_reservation.schedule_mode, v_package.schedule_mode, 'admin_assign');
  v_resource_required := lower(coalesce(v_package.package_category, '')) <> 'outside_catering'
    and (
      lower(coalesce(v_package.package_category, '')) in ('event_venue', 'room')
      or v_resource_mode = 'exclusive'
      or (v_resource <> '' and v_resource_mode <> 'shared_capacity')
    );
  if v_resource = '' and v_resource_required then raise exception 'A verified venue or resource is required'; end if;

  if v_resource = '' then
    if lower(v_reservation.status::text) <> 'pending' then raise exception 'Only pending reservations can have their schedule changed'; end if;
    if v_schedule_mode = 'fixed' then
      v_fixed_start := coalesce(v_variant.fixed_start_time, v_package.fixed_start_time);
      v_fixed_end := coalesce(v_variant.fixed_end_time, v_package.fixed_end_time);
      if v_fixed_start is null or v_fixed_end is null or p_start_time <> v_fixed_start or p_end_time <> v_fixed_end then
        raise exception 'Fixed package times must match the configured package schedule';
      end if;
    elsif v_schedule_mode = 'customer_select' then
      v_duration := coalesce(v_variant.duration_minutes, v_package.duration_minutes);
      v_operating_start := coalesce(v_variant.operating_start_time, v_package.operating_start_time);
      v_operating_end := coalesce(v_variant.operating_end_time, v_package.operating_end_time);
      if v_duration is null or v_operating_start is null or v_operating_end is null or v_operating_start = v_operating_end then
        raise exception 'This package has no configured duration or operating hours';
      end if;
      v_start := v_reservation.reservation_date + p_start_time;
      v_end := v_reservation.reservation_date + p_end_time
        + case when p_end_time <= p_start_time then interval '1 day' else interval '0 day' end;
      if extract(epoch from (v_end - v_start)) / 60 <> v_duration then
        raise exception 'The schedule must match the package''s configured duration';
      end if;
      v_window_start := v_reservation.reservation_date + v_operating_start;
      v_window_end := v_reservation.reservation_date + v_operating_end
        + case when v_operating_end <= v_operating_start then interval '1 day' else interval '0 day' end;
      if v_start < v_window_start or v_end > v_window_end then raise exception 'The schedule is outside configured operating hours'; end if;
    end if;
    update public.reservations
    set start_time = p_start_time,
        end_time = p_end_time,
        updated_at = now()
    where id = p_reservation_id;
    insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), 'reservation_schedule_changed', 'reservation', p_reservation_id,
      concat(v_reservation.reservation_date, ' ', p_start_time, '–', p_end_time, ' (no exclusive venue)'));
    return;
  end if;

  if not exists (
    select 1 from public.evently_resources resource
    where lower(resource.resource_key) = v_resource and resource.is_active
  ) then raise exception 'Select an active configured venue/resource'; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'evently-resource:' || v_resource || ':' || v_reservation.reservation_date::text, 0
  ));
  v_start := v_reservation.reservation_date + p_start_time;
  v_end := v_reservation.reservation_date + p_end_time
    + case when p_end_time <= p_start_time then interval '1 day' else interval '0 day' end;
  if exists (
    select 1 from public.reservations other
    left join public.packages other_package on other_package.id = other.package_id
    left join public.package_variants other_variant
      on other_variant.id = other.package_variant_id and other_variant.package_id = other_package.id
    where other.id <> p_reservation_id
      and lower(trim(coalesce(nullif(other.resource_key, ''), other_variant.resource_key, other_package.resource_key, ''))) = v_resource
      and lower(other.status::text) not in ('cancelled', 'rejected', 'completed')
      and other.reservation_date is not null
       and (
         (other.start_time is null or other.end_time is null)
         and other.reservation_date = v_reservation.reservation_date
         or (
           other.start_time is not null and other.end_time is not null
           and other.reservation_date + other.start_time < v_end
           and other.reservation_date + other.end_time
             + case when other.end_time <= other.start_time then interval '1 day' else interval '0 day' end > v_start
         )
       )
  ) then raise exception 'This venue is held by another active reservation during the selected time'; end if;

  perform public.evently_admin_set_reservation_schedule_before_active_conflict(
    p_reservation_id, p_start_time, p_end_time, v_resource
  );
end;
$$;

revoke all on function public.evently_admin_set_reservation_schedule(uuid,time,time,text) from public, anon;
grant execute on function public.evently_admin_set_reservation_schedule(uuid,time,time,text) to authenticated;

-- Wrap the established payment-proof approval RPC. Resolve a missing venue from
-- the selected variant/package, preserve active admin overrides, lock the
-- resource/date pair, and reject overlaps before the existing atomic approval.
do $$
begin
  if to_regprocedure('public.evently_admin_approve_booking_before_readiness(uuid,boolean)') is null then
    alter function public.evently_admin_approve_booking(uuid, boolean)
      rename to evently_admin_approve_booking_before_readiness;
  end if;
end;
$$;

revoke all on function public.evently_admin_approve_booking_before_readiness(uuid,boolean)
  from public, anon, authenticated;

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
  v_package public.packages%rowtype;
  v_variant public.package_variants%rowtype;
  v_resource_key text;
  v_assigned_resource text;
  v_resource_mode text;
  v_schedule_mode text;
  v_resource_required boolean;
  v_result jsonb;
  v_fixed_start time;
  v_fixed_end time;
  v_duration integer;
  v_operating_start time;
  v_operating_end time;
  v_start timestamp;
  v_end timestamp;
  v_window_start timestamp;
  v_window_end timestamp;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if p_schedule_verified is not true then raise exception 'Schedule verification is required'; end if;
  select * into v_reservation from public.reservations
  where id = p_reservation_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if lower(v_reservation.status::text) <> 'pending' then raise exception 'Only pending reservations can be approved'; end if;
  select * into v_package from public.packages where id = v_reservation.package_id and is_active;
  if not found then raise exception 'The selected package is unavailable'; end if;
  if v_reservation.package_variant_id is not null then
    select * into v_variant from public.package_variants
    where id = v_reservation.package_variant_id and package_id = v_package.id and is_active;
    if not found then raise exception 'The selected package variant is unavailable'; end if;
  end if;

  v_resource_mode := coalesce(v_reservation.resource_mode, v_package.resource_mode, 'admin_assign');
  v_schedule_mode := coalesce(v_reservation.schedule_mode, v_package.schedule_mode, 'admin_assign');
  v_resource_key := coalesce(
    nullif(trim(v_reservation.resource_key), ''),
    nullif(trim(v_variant.resource_key), ''),
    nullif(trim(v_package.resource_key), '')
  );
  v_resource_required := lower(coalesce(v_package.package_category, '')) <> 'outside_catering'
    and (
      lower(coalesce(v_package.package_category, '')) in ('event_venue', 'room')
      or v_resource_mode = 'exclusive'
      or (v_resource_key is not null and v_resource_mode <> 'shared_capacity')
    );
  if v_reservation.reservation_date is null then
    raise exception 'A reservation date is required';
  end if;
  if v_schedule_mode <> 'untimed' and (v_reservation.start_time is null
    or v_reservation.end_time is null or v_reservation.start_time = v_reservation.end_time) then
    raise exception 'Reservation date and distinct start/end times are required';
  end if;
  if v_schedule_mode = 'fixed' then
    v_fixed_start := coalesce(v_variant.fixed_start_time, v_package.fixed_start_time);
    v_fixed_end := coalesce(v_variant.fixed_end_time, v_package.fixed_end_time);
    if v_fixed_start is null or v_fixed_end is null
       or v_reservation.start_time <> v_fixed_start or v_reservation.end_time <> v_fixed_end then
      raise exception 'The reservation does not match the configured fixed package schedule';
    end if;
  elsif v_schedule_mode = 'customer_select' then
    v_duration := coalesce(v_variant.duration_minutes, v_package.duration_minutes);
    v_operating_start := coalesce(v_variant.operating_start_time, v_package.operating_start_time);
    v_operating_end := coalesce(v_variant.operating_end_time, v_package.operating_end_time);
    v_start := v_reservation.reservation_date + v_reservation.start_time;
    v_end := v_reservation.reservation_date + v_reservation.end_time
      + case when v_reservation.end_time <= v_reservation.start_time then interval '1 day' else interval '0 day' end;
    if v_duration is null or extract(epoch from (v_end - v_start)) / 60 <> v_duration then
      raise exception 'The reservation does not match the package''s configured duration';
    end if;
    if v_operating_start is null or v_operating_end is null or v_operating_start = v_operating_end then
      raise exception 'This package has no configured operating hours';
    end if;
    v_window_start := v_reservation.reservation_date + v_operating_start;
    v_window_end := v_reservation.reservation_date + v_operating_end
      + case when v_operating_end <= v_operating_start then interval '1 day' else interval '0 day' end;
    if v_start < v_window_start or v_end > v_window_end then
      raise exception 'The reservation is outside the configured operating hours';
    end if;
  end if;
  v_resource_key := nullif(trim(v_reservation.resource_key), '');
  if v_resource_key is not null then
    select resource.resource_key into v_assigned_resource
    from public.evently_resources resource
    where lower(resource.resource_key) = lower(v_resource_key) and resource.is_active;
  end if;
  if v_assigned_resource is null then
    v_resource_key := nullif(trim(v_variant.resource_key), '');
    if v_resource_key is not null then
      select resource.resource_key into v_assigned_resource
      from public.evently_resources resource
      where lower(resource.resource_key) = lower(v_resource_key) and resource.is_active;
    end if;
    if v_assigned_resource is null then
      v_resource_key := nullif(trim(v_package.resource_key), '');
      if v_resource_key is not null then
        select resource.resource_key into v_assigned_resource
        from public.evently_resources resource
        where lower(resource.resource_key) = lower(v_resource_key) and resource.is_active;
      end if;
    end if;
  end if;
  if v_resource_required and v_assigned_resource is null then
    raise exception 'This package requires a venue, but no active venue is configured for the package or reservation';
  end if;
  if v_resource_required then
    update public.reservations set resource_key = v_assigned_resource
    where id = p_reservation_id and resource_key is distinct from v_assigned_resource;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
      'evently-resource:' || lower(v_assigned_resource) || ':' || v_reservation.reservation_date::text, 0
    ));
    if v_reservation.start_time is not null and v_reservation.end_time is not null then
      v_start := v_reservation.reservation_date + v_reservation.start_time;
      v_end := v_reservation.reservation_date + v_reservation.end_time
        + case when v_reservation.end_time <= v_reservation.start_time then interval '1 day' else interval '0 day' end;
    end if;
    if exists (
      select 1 from public.reservations other
      left join public.packages other_package on other_package.id = other.package_id
      left join public.package_variants other_variant
        on other_variant.id = other.package_variant_id and other_variant.package_id = other_package.id
      where other.id <> p_reservation_id
        and lower(trim(coalesce(nullif(other.resource_key, ''), other_variant.resource_key, other_package.resource_key, ''))) = lower(v_assigned_resource)
        and lower(other.status::text) not in ('cancelled', 'rejected', 'completed')
        and other.reservation_date is not null
        and (
          (v_start is null and other.reservation_date = v_reservation.reservation_date)
          or (
            v_start is not null and (
              ((other.start_time is null or other.end_time is null)
                and other.reservation_date = v_reservation.reservation_date)
              or (
                other.start_time is not null and other.end_time is not null
                and other.reservation_date + other.start_time < v_end
                and other.reservation_date + other.end_time
                  + case when other.end_time <= other.start_time then interval '1 day' else interval '0 day' end > v_start
              )
            )
          )
        )
    ) then raise exception 'This venue is held by another active reservation during the selected time'; end if;
  end if;

  if not v_resource_required and v_schedule_mode <> 'untimed' then
    -- The legacy approval implementation treats every timed package as a
    -- physical venue booking. This wrapper has already validated its schedule;
    -- temporarily suppress only that legacy venue assumption for packages
    -- configured without an exclusive Evently resource.
    update public.reservations set schedule_mode = 'untimed'
    where id = p_reservation_id;
    v_result := public.evently_admin_approve_booking_before_readiness(p_reservation_id, true);
    update public.reservations set schedule_mode = v_schedule_mode, updated_at = now()
    where id = p_reservation_id;
    return v_result;
  end if;

  return public.evently_admin_approve_booking_before_readiness(p_reservation_id, true);
end;
$$;

revoke all on function public.evently_admin_approve_booking(uuid,boolean) from public, anon;
grant execute on function public.evently_admin_approve_booking(uuid,boolean) to authenticated;

notify pgrst, 'reload schema';
