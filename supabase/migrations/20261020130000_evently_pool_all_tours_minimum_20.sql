-- Raise the minimum party size for every swimming tour while preserving
-- audited capacity, existing prices, schedules, cottages, and reservation data.
-- Depends on 20261020120000_evently_pool_capacity_workflow.
begin;

do $$
begin
  if to_regprocedure('public.evently_pool_capacity_ready(uuid)') is null
     or to_regprocedure('public.evently_pool_tour_total(uuid,integer,uuid)') is null
     or to_regprocedure('public.evently_admin_set_pool_capacity(uuid,boolean,integer,text)') is null then
    raise exception 'Pool minimum migration stopped: apply/reconcile 20261020120000 before this migration';
  end if;
  if (select count(*) from public.packages where id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
      and is_active and package_category='pool_tour' and resource_key='venice-main-pool'
      and pricing_mode='per_guest'
      and ((id='4ae972a8-6503-4776-90c9-899246cbc4dc' and price=100)
        or (id='5afda244-a615-4bd3-98eb-d360d000100b' and price=150)
        or (id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8' and price=200))) <> 3 then
    raise exception 'Pool minimum migration stopped: expected three active tour packages and approved per-person rates';
  end if;
  if exists(select 1 from public.packages where id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
      and max_guest_count is not null and max_guest_count<20) then
    raise exception 'Pool minimum migration stopped: a verified pool maximum is below 20; reconcile that verification first';
  end if;
end;
$$;

-- Catalog-only change. Existing physical verification fields and audit links
-- are retained; max_guest_count remains the independently verified maximum.
update public.packages set min_guest_count=20,updated_at=now()
where id in ('4ae972a8-6503-4776-90c9-899246cbc4dc',
  '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
  and min_guest_count is distinct from 20;

-- Keep the authoritative RPC defensive even if catalog values are changed by
-- a future privileged maintenance operation.
create or replace function public.evently_pool_tour_total(
  p_package_id uuid,p_guest_count integer,p_cottage_addon_id uuid default null
) returns numeric(12,2)
language plpgsql security definer set search_path=''
as $$
declare v_package public.packages%rowtype; v_rate numeric(12,2); v_min integer;
  v_cottage uuid; v_cottage_price numeric(12,2);
begin
  select * into v_package from public.packages where id=p_package_id and is_active for share;
  if not found or not public.evently_pool_capacity_ready(p_package_id) then
    raise exception 'Pool bookings are paused until an Administrator verifies and audits physical capacity';
  end if;
  case p_package_id
    when '4ae972a8-6503-4776-90c9-899246cbc4dc'::uuid then
      v_rate:=100; v_min:=20; v_cottage:='1e97b2bf-ca43-492a-8a15-2d20f6abf040'; v_cottage_price:=700;
    when '5afda244-a615-4bd3-98eb-d360d000100b'::uuid then
      v_rate:=150; v_min:=20; v_cottage:='1e97b2bf-ca43-492a-8a15-2d20f6abf040'; v_cottage_price:=700;
    when '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'::uuid then
      v_rate:=200; v_min:=20; v_cottage:='928c269f-c38a-4345-86a5-d1f4c65555f0'; v_cottage_price:=1000;
    else raise exception 'Selected package is not a configured pool tour';
  end case;
  if p_guest_count is null or p_guest_count<v_min or p_guest_count>v_package.max_guest_count then
    raise exception 'Guest count must be between % and % for this pool tour',v_min,v_package.max_guest_count;
  end if;
  if v_package.price is distinct from v_rate or v_package.min_guest_count is distinct from v_min
     or v_package.cottage_addon_id is distinct from v_cottage
     or v_package.cottage_fee is distinct from v_cottage_price
     or v_package.deposit_percentage is distinct from 30 then
    raise exception 'Pool tour price, minimum, cottage, or deposit configuration differs from the approved schedule';
  end if;
  if p_cottage_addon_id is not null and p_cottage_addon_id is distinct from v_cottage then
    raise exception 'Selected cottage is not configured for this tour';
  end if;
  if p_cottage_addon_id is not null and not exists(
    select 1 from public.addons a where a.id=v_cottage and a.is_active
      and a.price=v_cottage_price and 'resort'=any(a.compatible_services)
  ) then raise exception 'Configured cottage add-on is unavailable'; end if;
  return round(v_rate*p_guest_count+case when p_cottage_addon_id is null then 0 else v_cottage_price end,2);
end;
$$;
revoke all on function public.evently_pool_tour_total(uuid,integer,uuid) from public,anon,authenticated;

do $$
begin
  if (select count(*) from public.packages where id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
      and min_guest_count=20
      and ((id='4ae972a8-6503-4776-90c9-899246cbc4dc' and price=100 and cottage_fee=700)
        or (id='5afda244-a615-4bd3-98eb-d360d000100b' and price=150 and cottage_fee=700)
        or (id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8' and price=200 and cottage_fee=1000)))<>3 then
    raise exception 'Pool minimum migration failed to synchronize the minimum or changed the approved rates';
  end if;
end;
$$;

notify pgrst,'reload schema';
commit;
