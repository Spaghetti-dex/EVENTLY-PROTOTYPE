-- Make role readiness recognize the live profile representation. In addition
-- to enum/check-constraint inspection, an existing authenticated Staff profile
-- is direct evidence that profiles.role can represent the staff role.
create or replace function public.evently_staff_role_ready()
returns boolean language sql stable security definer set search_path = ''
as $$
  select
    (
      not exists (
        select 1 from pg_catalog.pg_type role_type
        join pg_catalog.pg_namespace role_namespace on role_namespace.oid = role_type.typnamespace
        where role_namespace.nspname = 'public' and role_type.typname = 'user_role' and role_type.typtype = 'e'
      )
      or exists (
        select 1 from pg_catalog.pg_type role_type
        join pg_catalog.pg_namespace role_namespace on role_namespace.oid = role_type.typnamespace
        join pg_catalog.pg_enum enum_value on enum_value.enumtypid = role_type.oid
        where role_namespace.nspname = 'public' and role_type.typname = 'user_role'
          and role_type.typtype = 'e' and enum_value.enumlabel = 'staff'
      )
    )
    and exists (
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
          or (role_type.typtype <> 'e' and (
            exists (
              select 1 from pg_catalog.pg_constraint constraint_row
              where constraint_row.conrelid = 'public.profiles'::regclass
                and constraint_row.contype = 'c'
                and pg_catalog.pg_get_constraintdef(constraint_row.oid) ilike '%role%'
                and pg_catalog.pg_get_constraintdef(constraint_row.oid) ilike '%staff%'
            )
            or exists (select 1 from public.profiles profile where profile.role::text = 'staff')
          ))
        )
    );
$$;

revoke all on function public.evently_staff_role_ready() from public;
grant execute on function public.evently_staff_role_ready() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
