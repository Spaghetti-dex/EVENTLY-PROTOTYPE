-- Expose the existing catalog objects and the existing package/date eligibility RPC.
-- This migration does not create or duplicate add-on storage.

alter table public.addons enable row level security;

drop policy if exists "Active addons are readable" on public.addons;
create policy "Active addons are readable"
  on public.addons for select
  using (is_active or public.is_evently_admin());

grant select on public.addons to anon, authenticated;
grant execute on function public.evently_check_availability(uuid, date) to anon, authenticated;

-- Remove the obsolete reversed overload if an earlier workflow migration installed it.
drop function if exists public.evently_check_availability(date, uuid);

notify pgrst, 'reload schema';
