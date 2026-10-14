-- Report whether the existing public.profiles.role representation accepts staff.
-- Supports the repository's text/check role column and compatible enum deployments.
create or replace function public.evently_staff_role_ready()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from pg_catalog.pg_attribute attribute
    join pg_catalog.pg_type role_type on role_type.oid = attribute.atttypid
    where attribute.attrelid = 'public.profiles'::regclass
      and attribute.attname = 'role'
      and not attribute.attisdropped
      and (
        (role_type.typtype = 'e' and exists (
          select 1 from pg_catalog.pg_enum enum_value
          where enum_value.enumtypid = role_type.oid and enum_value.enumlabel = 'staff'
        ))
        or (role_type.typtype <> 'e' and exists (
          select 1 from pg_catalog.pg_constraint constraint_row
          where constraint_row.conrelid = 'public.profiles'::regclass
            and constraint_row.contype = 'c'
            and pg_catalog.pg_get_constraintdef(constraint_row.oid) ilike '%role%'
            and pg_catalog.pg_get_constraintdef(constraint_row.oid) ilike '%staff%'
        ))
      )
  );
$$;

create or replace function public.evently_staff_permissions_ready()
returns boolean language sql stable security definer set search_path = ''
as $$
  select public.evently_staff_role_ready()
    and to_regclass('public.evently_staff_permissions') is not null
    and to_regprocedure('public.evently_staff_has_permission(text)') is not null
    and to_regprocedure('public.evently_staff_list_reservations()') is not null
    and to_regprocedure('public.evently_staff_submit_booking_recommendation(uuid,text,text,text)') is not null
    and to_regprocedure('public.evently_admin_review_booking_recommendation(uuid,text,text,boolean)') is not null;
$$;

-- Lets a signed-in user distinguish a missing profile from a profile SELECT/RLS
-- problem without accepting an arbitrary user id from the client.
create or replace function public.evently_current_profile_role()
returns text language plpgsql stable security definer set search_path = ''
as $$
declare v_role text;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  select role::text into v_role from public.profiles where id = auth.uid();
  return v_role;
end;
$$;

revoke all on function public.evently_staff_role_ready() from public;
revoke all on function public.evently_staff_permissions_ready() from public;
revoke all on function public.evently_current_profile_role() from public;
grant execute on function public.evently_staff_role_ready() to anon, authenticated, service_role;
grant execute on function public.evently_staff_permissions_ready() to authenticated, service_role;
grant execute on function public.evently_current_profile_role() to authenticated;

notify pgrst, 'reload schema';
