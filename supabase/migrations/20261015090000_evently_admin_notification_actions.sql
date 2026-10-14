-- Allow Owner/Admin users to mark notifications in their administrative inbox
-- read without widening direct UPDATE access on the notifications table.
create or replace function public.evently_admin_mark_notifications_read(p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated integer;
begin
  if not public.is_evently_admin() then
    raise exception 'Administrative access required';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 then return 0; end if;

  update public.notifications
  set is_read = true
  where id = any(p_ids) and is_read is distinct from true;
  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

revoke all on function public.evently_admin_mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.evently_admin_mark_notifications_read(uuid[]) to authenticated;

notify pgrst, 'reload schema';
