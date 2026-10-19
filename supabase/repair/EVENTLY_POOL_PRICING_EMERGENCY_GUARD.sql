-- Immediate fail-closed mitigation for an already-live database.
-- Run manually in Supabase SQL Editor if the legacy pool RPC is still active.
-- This blocks only creation of the three pool-tour reservations and revokes
-- direct lifecycle writes; existing reservations/payments and other services
-- are unchanged. The capacity-safe migration removes the temporary trigger.
begin;

do $$
begin
  if to_regclass('public.reservations') is null or to_regclass('public.orders') is null
     or to_regclass('public.payments') is null then
    raise exception 'Emergency guard stopped: lifecycle tables are missing';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='public'
    and table_name='reservations' and column_name='package_id') then
    raise exception 'Emergency guard stopped: reservations.package_id is missing';
  end if;
end;
$$;

create or replace function public.evently_pool_pricing_emergency_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.package_id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc'::uuid,
    '5afda244-a615-4bd3-98eb-d360d000100b'::uuid,
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'::uuid
  ) then
    raise exception 'Pool bookings are temporarily paused until per-person pricing and physical capacity are verified';
  end if;
  return new;
end;
$$;
revoke all on function public.evently_pool_pricing_emergency_guard() from public,anon,authenticated;
drop trigger if exists evently_pool_pricing_emergency_guard on public.reservations;
create trigger evently_pool_pricing_emergency_guard
  before insert on public.reservations
  for each row execute function public.evently_pool_pricing_emergency_guard();

-- All current customer/Admin mutations use guarded SECURITY DEFINER RPCs. Remove
-- direct table-level and column-level DML from browser roles, without changing
-- SELECT grants or RLS policies.
do $$
declare v_table text; v_columns text;
begin
  foreach v_table in array array['packages','reservations','orders','payments'] loop
    execute pg_catalog.format('revoke insert,update,delete on table public.%I from public,anon,authenticated',v_table);
    select string_agg(pg_catalog.quote_ident(a.attname),', ' order by a.attnum) into v_columns
    from pg_catalog.pg_attribute a where a.attrelid=to_regclass('public.'||v_table) and a.attnum>0 and not a.attisdropped;
    if v_columns is not null then
      execute pg_catalog.format('revoke insert (%s) on table public.%I from public,anon,authenticated',v_columns,v_table);
      execute pg_catalog.format('revoke update (%s) on table public.%I from public,anon,authenticated',v_columns,v_table);
    end if;
  end loop;
  if exists(select 1 from information_schema.column_privileges
    where table_schema='public' and table_name in ('packages','reservations','orders','payments')
      and grantee in ('PUBLIC','anon','authenticated') and privilege_type in ('INSERT','UPDATE')) then
    raise exception 'Lifecycle column-level write grants remain after revocation';
  end if;
end;
$$;

notify pgrst,'reload schema';
commit;
