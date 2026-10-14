-- Admin-configurable booking hours and strict local Philippine mobile validation.
-- Existing historical profile/reservation phone values are not rewritten.

create or replace function public.evently_admin_set_package_schedule(
  p_package_id uuid,
  p_schedule_mode text,
  p_operating_start_time time,
  p_operating_end_time time,
  p_duration_minutes integer
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if p_schedule_mode not in ('untimed', 'fixed', 'customer_select', 'admin_assign') then
    raise exception 'Choose a valid schedule mode';
  end if;
  if p_schedule_mode = 'customer_select' and (
    p_operating_start_time is null or p_operating_end_time is null
    or p_operating_start_time = p_operating_end_time
    or p_duration_minutes is null or p_duration_minutes < 1
  ) then raise exception 'Customer-selected schedules require distinct operating hours and a positive duration'; end if;

  update public.packages
  set schedule_mode = p_schedule_mode,
      operating_start_time = case when p_schedule_mode = 'customer_select' then p_operating_start_time else null end,
      operating_end_time = case when p_schedule_mode = 'customer_select' then p_operating_end_time else null end,
      duration_minutes = case when p_schedule_mode = 'customer_select' then p_duration_minutes else null end,
      updated_at = now()
  where id = p_package_id;
  if not found then raise exception 'Package not found'; end if;

  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'package_schedule_updated', 'package', p_package_id,
    jsonb_build_object('mode', p_schedule_mode, 'opens', p_operating_start_time,
      'closes', p_operating_end_time, 'duration_minutes', p_duration_minutes)::text);
end;
$$;

revoke all on function public.evently_admin_set_package_schedule(uuid,text,time,time,integer) from public, anon;
grant execute on function public.evently_admin_set_package_schedule(uuid,text,time,time,integer) to authenticated;

create or replace function public.evently_validate_philippine_mobile()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.mobile_number is distinct from old.mobile_number then
    if new.mobile_number is not null and new.mobile_number !~ '^09[0-9]{9}$' then
      raise exception 'Mobile number must be exactly 11 digits and start with 09 (example: 09171234567)';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists evently_validate_profile_mobile on public.profiles;
create trigger evently_validate_profile_mobile
before insert or update of mobile_number on public.profiles
for each row execute function public.evently_validate_philippine_mobile();

create or replace function public.evently_validate_reservation_mobile()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.customer_phone is null or new.customer_phone !~ '^09[0-9]{9}$' then
    raise exception 'Customer mobile number must be exactly 11 digits and start with 09 (example: 09171234567)';
  end if;
  return new;
end;
$$;

drop trigger if exists evently_validate_reservation_mobile on public.reservations;
create trigger evently_validate_reservation_mobile
before insert or update of customer_phone on public.reservations
for each row execute function public.evently_validate_reservation_mobile();

update storage.buckets
set file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
where id = 'payment-proofs';

notify pgrst, 'reload schema';
