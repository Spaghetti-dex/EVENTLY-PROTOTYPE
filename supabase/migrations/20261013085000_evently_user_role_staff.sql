-- Add Staff to the existing public.user_role enum when that enum exists.
-- The checked-in profiles migration uses text with a check constraint, which is
-- separately expanded by 20261013090000_evently_staff_and_reviews.sql.
do $$
declare
  v_role_type oid := to_regtype('public.user_role');
begin
  if v_role_type is not null
     and exists (select 1 from pg_catalog.pg_type where oid = v_role_type and typtype = 'e') then
    execute 'alter type public.user_role add value if not exists ''staff''';
  end if;
end;
$$;

notify pgrst, 'reload schema';
