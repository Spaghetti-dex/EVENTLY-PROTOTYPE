-- Read-only post-migration Resort/Staycation pricing verification.
-- Actual RPC-created reservations are exercised by the disposable behavior test.
do $$
declare
  v_helper text;
  v_booking_wrapper text;
  v_rejected boolean;
begin
  if to_regclass('public.evently_resort_service_rates') is null
     or to_regclass('public.evently_resort_rate_catalog_backup') is null
     or to_regprocedure('public.evently_resort_service_amount(uuid,integer,integer,boolean)') is null
     or to_regprocedure('public.create_evently_reservation_before_exact_resource_assignment(jsonb)') is null then
    raise exception 'FAIL: Resort/Staycation rate mapping or guarded booking wrapper is missing';
  end if;
  if has_function_privilege('anon','public.evently_resort_service_amount(uuid,integer,integer,boolean)','execute')
     or has_function_privilege('authenticated','public.evently_resort_service_amount(uuid,integer,integer,boolean)','execute') then
    raise exception 'FAIL: the internal Resort total calculator is directly executable by browser roles';
  end if;
  if has_table_privilege('anon','public.evently_resort_service_rates','SELECT')
     or has_table_privilege('authenticated','public.evently_resort_service_rates','SELECT')
     or has_table_privilege('anon','public.evently_resort_rate_catalog_backup','SELECT')
     or has_table_privilege('authenticated','public.evently_resort_rate_catalog_backup','SELECT') then
    raise exception 'FAIL: internal Resort rate or rollback tables are exposed to browser roles';
  end if;
  if (select count(*) from public.evently_resort_service_rates rates
    join public.packages package on package.id=rates.package_id
    where package.is_active and lower(package.service_type::text)='resort'
      and package.price=rates.expected_price and package.deposit_percentage=30
      and package.pool_access_fee=5000
      and ((rates.rate_key='standard_room' and package.price=3000
          and package.package_category='room' and package.pricing_mode='per_night'
          and package.min_guest_count=4 and package.guest_capacity=5)
        or (rates.rate_key='kubo_room' and package.price=1500
          and package.package_category='room' and package.pricing_mode='per_night'
          and package.min_guest_count=1)
        or (rates.rate_key='venue_non_aircon' and package.price=10000
          and package.package_category='event_venue' and package.pricing_mode='fixed'
          and package.duration_minutes=300)
        or (rates.rate_key='venue_aircon' and package.price=15000
          and package.package_category='event_venue' and package.pricing_mode='fixed'
          and package.duration_minutes=240)))<>4 then
    raise exception 'FAIL: active room/venue package values differ from the locked rate sheet';
  end if;
  if (select count(*) from public.packages where id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8') and pool_access_fee=0)<>3 then
    raise exception 'FAIL: Pool Access must not be configured as part of a Swimming Tour';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='reservations' and column_name='room_count' and data_type='integer')
     or not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='reservations' and column_name='stay_nights' and data_type='integer')
     or not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='orders' and column_name='room_count' and data_type='integer')
     or not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='orders' and column_name='stay_nights' and data_type='integer') then
    raise exception 'FAIL: room/night quantity snapshots are missing from reservations/orders';
  end if;

  if public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='standard_room'),1,1,false)<>3000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='standard_room'),2,3,false)<>18000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='standard_room'),2,3,true)<>23000
     or round(public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='standard_room'),2,3,true)*0.30,2)<>6900
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='kubo_room'),2,2,false)<>6000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='kubo_room'),2,2,true)<>11000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='venue_non_aircon'),1,1,false)<>10000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='venue_non_aircon'),1,1,true)<>15000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='venue_aircon'),1,1,false)<>15000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='venue_aircon'),1,1,true)<>20000 then
    raise exception 'FAIL: room/night, venue, optional-access, or 30-percent deposit arithmetic differs';
  end if;

  v_rejected:=false;
  begin
    perform public.evently_resort_service_amount(
      (select package_id from public.evently_resort_service_rates where rate_key='standard_room'),0,1,false);
  exception when raise_exception then v_rejected:=sqlerrm ilike '%Room count%';
  end;
  if not coalesce(v_rejected,false) then raise exception 'FAIL: zero-room bookings were not rejected'; end if;
  v_rejected:=false;
  begin
    perform public.evently_resort_service_amount(
      (select package_id from public.evently_resort_service_rates where rate_key='kubo_room'),1,366,false);
  exception when raise_exception then v_rejected:=sqlerrm ilike '%nights%';
  end;
  if not coalesce(v_rejected,false) then raise exception 'FAIL: out-of-range stay length was not rejected'; end if;

  select lower(pg_catalog.pg_get_functiondef('public.create_evently_reservation_before_exact_resource_assignment(jsonb)'::regprocedure))
    into v_booking_wrapper;
  if position('evently_resort_service_amount' in v_booking_wrapper)=0
     or position('pool_access_selected' in v_booking_wrapper)=0
     or position('reservation_addons' in v_booking_wrapper)=0
     or position('idempotency_key' in v_booking_wrapper)=0 then
    raise exception 'FAIL: booking wrapper is missing guarded Resort totals, explicit Pool Access, add-ons, or idempotency';
  end if;
  select lower(pg_catalog.pg_get_functiondef('public.evently_resort_service_amount(uuid,integer,integer,boolean)'::regprocedure))
    into v_helper;
  if position('standard_room' in v_helper)=0 or position('kubo_room' in v_helper)=0
     or position('venue_non_aircon' in v_helper)=0 or position('venue_aircon' in v_helper)=0 then
    raise exception 'FAIL: internal total calculator does not cover all four Resort rates';
  end if;
end;
$$;

select rates.rate_key,rates.package_id,rates.expected_price,
       rates.minimum_guests_per_room,rates.maximum_guests_per_room,
       rates.duration_minutes,rates.pool_access_fee,
       package.price as configured_price,package.deposit_percentage,
       package.pool_access_fee as configured_pool_access_fee,
       package.schedule_mode,package.operating_start_time,package.operating_end_time,
       package.resource_mode,package.resource_key
from public.evently_resort_service_rates rates
join public.packages package on package.id=rates.package_id
order by rates.rate_key;
