-- Keep package-specific deposit configuration additive and visible to PostgREST.
-- No reservation totals or payment records are modified by this migration.

alter table public.packages
  add column if not exists deposit_percentage numeric(5,2);

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conname = 'packages_deposit_percentage_range'
      and conrelid = 'public.packages'::regclass
  ) then
    alter table public.packages
      add constraint packages_deposit_percentage_range
      check (deposit_percentage is null or deposit_percentage between 0 and 100)
      not valid;
  end if;
end;
$$;

grant update (deposit_percentage) on public.packages to authenticated;

drop policy if exists "Admins configure package deposits" on public.packages;
create policy "Admins configure package deposits"
  on public.packages for update
  to authenticated
  using (public.is_evently_admin())
  with check (public.is_evently_admin());

notify pgrst, 'reload schema';
