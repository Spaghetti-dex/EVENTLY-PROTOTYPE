-- Confirmed Resort/Staycation rates, room occupancy, and optional Pool Access.
-- This migration composes with the guarded booking/schedule RPC chain and does
-- not rewrite historical reservation or payment amounts.
begin;

do $$
begin
  if to_regclass('public.packages') is null
     or to_regclass('public.reservations') is null
     or to_regclass('public.orders') is null
     or to_regclass('public.reservation_addons') is null
     or to_regclass('public.admin_activity_logs') is null
     or to_regprocedure('public.create_evently_reservation_before_exact_resource_assignment(jsonb)') is null
     or to_regprocedure('public.create_evently_reservation_before_verified_pool_tour_pricing(jsonb)') is null then
    raise exception 'Staycation pricing stopped: required catalog, booking, or prior pool-pricing wrapper is missing';
  end if;
  if (select count(*) from public.packages where is_active
      and lower(service_type::text)='resort'
      and lower(name) in ('standard room','kubo room'))<>2 then
    raise exception 'Staycation pricing stopped: expected one active Standard Room and one active Kubo Room package';
  end if;
  if (select count(*) from public.packages where is_active
      and lower(service_type::text)='resort'
      and lower(name) in ('non-air-conditioned venue','air-conditioned venue'))<>2 then
    raise exception 'Staycation pricing stopped: expected active Non-Aircon and Aircon Venue Only packages';
  end if;
  if exists(select 1 from public.package_variants variant
      join public.packages package on package.id=variant.package_id
      where variant.is_active and package.is_active and lower(package.service_type::text)='resort'
        and lower(package.name) in ('standard room','kubo room','non-air-conditioned venue','air-conditioned venue')) then
    raise exception 'Staycation pricing stopped: active variants exist for an exact-rate package and need explicit review';
  end if;
end;
$$;

create table if not exists public.evently_resort_service_rates (
  package_id uuid primary key references public.packages(id) on delete restrict,
  rate_key text not null unique check(rate_key in ('standard_room','kubo_room','venue_non_aircon','venue_aircon')),
  expected_price numeric(12,2) not null check(expected_price>0),
  minimum_guests_per_room integer not null check(minimum_guests_per_room>=1),
  maximum_guests_per_room integer,
  duration_minutes integer,
  pool_access_fee numeric(12,2) not null default 5000 check(pool_access_fee=5000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(maximum_guests_per_room is null or maximum_guests_per_room>=minimum_guests_per_room),
  check(duration_minutes is null or duration_minutes>0)
);
alter table public.evently_resort_service_rates enable row level security;
revoke all on public.evently_resort_service_rates from public,anon,authenticated;

create table if not exists public.evently_resort_rate_catalog_backup (
  package_id uuid primary key references public.packages(id) on delete restrict,
  row_data jsonb not null,
  captured_at timestamptz not null default now()
);
alter table public.evently_resort_rate_catalog_backup enable row level security;
revoke all on public.evently_resort_rate_catalog_backup from public,anon,authenticated;

insert into public.evently_resort_rate_catalog_backup(package_id,row_data)
select package.id,to_jsonb(package) from public.packages package
where lower(package.service_type::text)='resort'
  and lower(package.name) in ('standard room','kubo room','non-air-conditioned venue','air-conditioned venue')
on conflict(package_id) do nothing;

alter table public.reservations
  add column if not exists room_count integer,
  add column if not exists stay_nights integer;
alter table public.orders
  add column if not exists room_count integer,
  add column if not exists stay_nights integer;

do $$
begin
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.reservations'::regclass
    and conname='reservations_room_count_positive') then
    alter table public.reservations add constraint reservations_room_count_positive check(room_count is null or room_count>=1) not valid;
  end if;
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.reservations'::regclass
    and conname='reservations_stay_nights_positive') then
    alter table public.reservations add constraint reservations_stay_nights_positive check(stay_nights is null or stay_nights>=1) not valid;
  end if;
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.orders'::regclass
    and conname='orders_room_count_positive') then
    alter table public.orders add constraint orders_room_count_positive check(room_count is null or room_count>=1) not valid;
  end if;
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.orders'::regclass
    and conname='orders_stay_nights_positive') then
    alter table public.orders add constraint orders_stay_nights_positive check(stay_nights is null or stay_nights>=1) not valid;
  end if;
end;
$$;
alter table public.reservations validate constraint reservations_room_count_positive;
alter table public.reservations validate constraint reservations_stay_nights_positive;
alter table public.orders validate constraint orders_room_count_positive;
alter table public.orders validate constraint orders_stay_nights_positive;

-- Configure only rate-sheet facts. Kubo capacity, Venue Only operating hours,
-- schedule mode, resource assignment, and existing inventory are not inferred.
update public.packages
set price=3000,guest_capacity=5,min_guest_count=4,package_category='room',
    pricing_mode='per_night',pool_access_fee=5000,deposit_percentage=30,updated_at=now()
where is_active and lower(service_type::text)='resort' and lower(name)='standard room';

update public.packages
set price=1500,min_guest_count=1,package_category='room',
    pricing_mode='per_night',pool_access_fee=5000,deposit_percentage=30,updated_at=now()
where is_active and lower(service_type::text)='resort' and lower(name)='kubo room';

update public.packages
set price=case lower(name)
      when 'non-air-conditioned venue' then 10000
      when 'air-conditioned venue' then 15000
    end,
    package_category='event_venue',pricing_mode='fixed',min_guest_count=1,
    schedule_mode='customer_select',
    duration_minutes=case lower(name)
      when 'non-air-conditioned venue' then 300
      when 'air-conditioned venue' then 240
    end,
    pool_access_fee=5000,deposit_percentage=30,updated_at=now()
where is_active and lower(service_type::text)='resort'
  and lower(name) in ('non-air-conditioned venue','air-conditioned venue');

insert into public.evently_resort_service_rates(
  package_id,rate_key,expected_price,minimum_guests_per_room,maximum_guests_per_room,duration_minutes,pool_access_fee
)
select package.id,
  case lower(package.name)
    when 'standard room' then 'standard_room'
    when 'kubo room' then 'kubo_room'
    when 'non-air-conditioned venue' then 'venue_non_aircon'
    when 'air-conditioned venue' then 'venue_aircon'
  end,
  case lower(package.name)
    when 'standard room' then 3000
    when 'kubo room' then 1500
    when 'non-air-conditioned venue' then 10000
    when 'air-conditioned venue' then 15000
  end,
  case lower(package.name) when 'standard room' then 4 else 1 end,
  case lower(package.name) when 'standard room' then 5 else null end,
  case lower(package.name)
    when 'non-air-conditioned venue' then 300
    when 'air-conditioned venue' then 240
    else null
  end,
  5000
from public.packages package
where package.is_active and lower(package.service_type::text)='resort'
  and lower(package.name) in ('standard room','kubo room','non-air-conditioned venue','air-conditioned venue')
on conflict(package_id) do update set
  rate_key=excluded.rate_key,
  expected_price=excluded.expected_price,
  minimum_guests_per_room=excluded.minimum_guests_per_room,
  maximum_guests_per_room=excluded.maximum_guests_per_room,
  duration_minutes=excluded.duration_minutes,
  pool_access_fee=excluded.pool_access_fee,
  updated_at=now();

create or replace function public.evently_resort_service_amount(
  p_package_id uuid,p_room_count integer,p_nights integer,p_pool_access_selected boolean
) returns numeric(12,2)
language plpgsql security definer set search_path = '' as $$
declare
  v_package public.packages%rowtype;
  v_rate public.evently_resort_service_rates%rowtype;
  v_base numeric(12,2);
begin
  if p_room_count is null or p_room_count<1 or p_room_count>100
     or p_nights is null or p_nights<1 or p_nights>365 then
    raise exception 'Room count must be 1–100 and nights must be 1–365';
  end if;
  select * into v_package from public.packages where id=p_package_id and is_active for share;
  select * into v_rate from public.evently_resort_service_rates where package_id=p_package_id;
  if not found or v_package.id is null then raise exception 'The selected Resort rate is unavailable'; end if;
  if lower(v_package.service_type::text)<>'resort'
     or v_package.price is distinct from v_rate.expected_price
     or v_package.deposit_percentage is distinct from 30
     or v_package.pool_access_fee is distinct from v_rate.pool_access_fee then
    raise exception 'The selected Resort package no longer matches its locked rate-sheet configuration';
  end if;
  if v_rate.rate_key='standard_room' then
    if v_package.package_category<>'room' or v_package.pricing_mode<>'per_night'
       or v_package.min_guest_count is distinct from 4 or v_package.guest_capacity is distinct from 5 then
      raise exception 'Standard Room occupancy or pricing configuration has changed';
    end if;
    v_base:=v_rate.expected_price*p_room_count*p_nights;
  elsif v_rate.rate_key='kubo_room' then
    if v_package.package_category<>'room' or v_package.pricing_mode<>'per_night'
       or v_package.min_guest_count is distinct from 1 then
      raise exception 'Kubo Room pricing configuration has changed';
    end if;
    v_base:=v_rate.expected_price*p_room_count*p_nights;
  elsif v_rate.rate_key='venue_non_aircon' then
    if v_package.package_category<>'event_venue' or v_package.pricing_mode<>'fixed'
       or v_package.duration_minutes is distinct from 300 then
      raise exception 'Non-Aircon Venue Only must remain ₱10,000 for five hours';
    end if;
    v_base:=v_rate.expected_price;
  elsif v_rate.rate_key='venue_aircon' then
    if v_package.package_category<>'event_venue' or v_package.pricing_mode<>'fixed'
       or v_package.duration_minutes is distinct from 240 then
      raise exception 'Aircon Venue Only must remain ₱15,000 for four hours';
    end if;
    v_base:=v_rate.expected_price;
  else
    raise exception 'The selected Resort rate key is not supported';
  end if;
  return round(v_base+case when p_pool_access_selected then v_rate.pool_access_fee else 0 end,2);
end;
$$;
revoke all on function public.evently_resort_service_amount(uuid,integer,integer,boolean)
  from public,anon,authenticated;

do $$
begin
  if (select count(*) from public.evently_resort_service_rates rates
    join public.packages package on package.id=rates.package_id
    where package.is_active and lower(package.service_type::text)='resort'
      and rates.rate_key in ('standard_room','kubo_room','venue_non_aircon','venue_aircon')
      and package.price=rates.expected_price and package.deposit_percentage=30
      and package.pool_access_fee=5000
      and ((rates.rate_key='standard_room' and package.package_category='room'
          and package.pricing_mode='per_night' and package.min_guest_count=4 and package.guest_capacity=5)
        or (rates.rate_key='kubo_room' and package.package_category='room'
          and package.pricing_mode='per_night' and package.min_guest_count=1)
        or (rates.rate_key='venue_non_aircon' and package.package_category='event_venue'
          and package.pricing_mode='fixed' and package.duration_minutes=300)
        or (rates.rate_key='venue_aircon' and package.package_category='event_venue'
          and package.pricing_mode='fixed' and package.duration_minutes=240)))<>4 then
    raise exception 'Resort package rates/occupancy/durations did not synchronize with the confirmed rate sheet';
  end if;
  if public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='standard_room'),1,1,false)<>3000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='standard_room'),2,3,false)<>18000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='standard_room'),2,3,true)<>23000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='kubo_room'),2,2,false)<>6000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='kubo_room'),2,2,true)<>11000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='venue_non_aircon'),1,1,false)<>10000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='venue_non_aircon'),1,1,true)<>15000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='venue_aircon'),1,1,false)<>15000
     or public.evently_resort_service_amount((select package_id from public.evently_resort_service_rates where rate_key='venue_aircon'),1,1,true)<>20000 then
    raise exception 'Resort room/night, venue, or opt-in Pool Access total verification failed';
  end if;
end;
$$;

-- Keep this wrapper beneath the established schedule-hold RPC. All unrelated
-- services still delegate to the existing pricing/catalog/payment chain.
do $$
begin
  if to_regprocedure('public.create_evently_reservation_before_resort_staycation_pricing(jsonb)') is null then
    alter function public.create_evently_reservation_before_exact_resource_assignment(jsonb)
      rename to create_evently_reservation_before_resort_staycation_pricing;
  end if;
end;
$$;
revoke all on function public.create_evently_reservation_before_resort_staycation_pricing(jsonb)
  from public,anon,authenticated;

create or replace function public.create_evently_reservation_before_exact_resource_assignment(p_booking jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_package public.packages%rowtype;
  v_rate public.evently_resort_service_rates%rowtype;
  v_existing_id uuid;
  v_result jsonb;
  v_payload jsonb:=p_booking;
  v_reservation_id uuid;
  v_order_id uuid;
  v_guest_count integer;
  v_room_count integer:=coalesce(nullif(p_booking->>'rooms','')::integer,1);
  v_nights integer:=coalesce(nullif(p_booking->>'nights','')::integer,1);
  v_safe_guest_count integer;
  v_addon_total numeric(12,2):=0;
  v_pool_fee numeric(12,2):=0;
  v_total numeric(12,2);
  v_deposit numeric(12,2);
  v_amount_paid numeric(12,2):=0;
  v_max_per_room integer;
  v_pool_access_selected boolean:=coalesce(nullif(p_booking->>'pool_access_selected','')::boolean,false);
  v_is_room boolean:=false;
  v_is_venue boolean:=false;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if jsonb_typeof(p_booking) is distinct from 'object'
     or nullif(p_booking->>'idempotency_key','') is null then
    raise exception 'Booking details and an idempotency key are required';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'evently-booking:'||auth.uid()::text||':'||(p_booking->>'idempotency_key'),0));
  select id into v_existing_id from public.reservations where customer_id=auth.uid()
    and client_request_id=(p_booking->>'idempotency_key')::uuid;
  if v_existing_id is not null then
    return public.create_evently_reservation_before_resort_staycation_pricing(p_booking);
  end if;

  if jsonb_typeof(coalesce(p_booking->'addons','[]'::jsonb)) is distinct from 'array' then
    raise exception 'Add-on selection must be an array';
  end if;
  if exists(select 1 from jsonb_array_elements(coalesce(p_booking->'addons','[]'::jsonb)) selected
    join public.addons addon on addon.id=nullif(selected.value->>'id','')::uuid
    where lower(addon.name) like '%pool%access%') then
    raise exception 'Pool Access must be selected through the separately priced room/venue option, not as a generic add-on';
  end if;

  select * into v_package from public.packages
    where id=nullif(p_booking->>'package_id','')::uuid and is_active for share;
  if not found then raise exception 'The selected package is unavailable'; end if;
  select * into v_rate from public.evently_resort_service_rates where package_id=v_package.id;
  if not found then
    if v_pool_access_selected then
      raise exception 'Pool Access is available only as an optional service for eligible Resort Rooms or Venue Only bookings';
    end if;
    return public.create_evently_reservation_before_resort_staycation_pricing(p_booking);
  end if;

  v_is_room:=v_rate.rate_key in ('standard_room','kubo_room');
  v_is_venue:=v_rate.rate_key in ('venue_non_aircon','venue_aircon');
  if lower(v_package.service_type::text)<>'resort'
     or v_package.price is distinct from v_rate.expected_price
     or v_package.deposit_percentage is distinct from 30
     or v_package.pool_access_fee is distinct from 5000 then
    raise exception 'The selected Resort package no longer matches its locked rate-sheet configuration';
  end if;
  if (v_is_room and (v_package.package_category<>'room' or v_package.pricing_mode<>'per_night'))
     or (v_is_venue and (v_package.package_category<>'event_venue' or v_package.pricing_mode<>'fixed'
       or v_package.duration_minutes is distinct from v_rate.duration_minutes)) then
    raise exception 'The selected Resort package category, pricing unit, or duration has changed';
  end if;
  if nullif(p_booking->>'package_variant_id','') is not null then
    raise exception 'This verified Resort rate package has no active variants';
  end if;
  if coalesce(nullif(p_booking->>'cottage_selected','')::boolean,false)
     or nullif(p_booking->>'cottage_addon_id','') is not null then
    raise exception 'Cottage selection is available only for Swimming Tour packages';
  end if;
  if v_room_count<1 or v_room_count>100 or v_nights<1 or v_nights>365 then
    raise exception 'Room count must be 1–100 and nights must be 1–365';
  end if;
  v_guest_count:=nullif(p_booking->>'guest_count','')::integer;
  if v_guest_count is null or v_guest_count<1 then raise exception 'Guest count must be at least one'; end if;
  if v_pool_access_selected then v_pool_fee:=v_rate.pool_access_fee; end if;

  if v_rate.rate_key='standard_room' then
    if v_package.min_guest_count is distinct from 4 or v_package.guest_capacity is distinct from 5 then
      raise exception 'Standard Room occupancy must remain strictly 4–5 guests per room';
    end if;
    if v_guest_count<4*v_room_count or v_guest_count>5*v_room_count then
      raise exception 'Standard Room bookings require 4–5 guests per room';
    end if;
    v_safe_guest_count:=4;
  elsif v_rate.rate_key='kubo_room' then
    if v_package.min_guest_count is distinct from 1 then
      raise exception 'Kubo Room minimum guest configuration has changed';
    end if;
    v_max_per_room:=v_package.guest_capacity;
    if v_max_per_room is not null
       and v_guest_count::numeric>v_max_per_room::numeric*v_room_count::numeric then
      raise exception 'Kubo guest count exceeds the currently configured room capacity';
    end if;
    v_safe_guest_count:=least(v_guest_count,coalesce(v_max_per_room,v_guest_count));
  else
    if v_rate.rate_key='venue_non_aircon' and (v_package.price<>10000 or v_package.duration_minutes<>300) then
      raise exception 'Non-Aircon Venue Only must remain ₱10,000 for five hours';
    elsif v_rate.rate_key='venue_aircon' and (v_package.price<>15000 or v_package.duration_minutes<>240) then
      raise exception 'Aircon Venue Only must remain ₱15,000 for four hours';
    end if;
    if v_guest_count<v_package.min_guest_count
       or (v_package.guest_capacity is not null and v_guest_count>v_package.guest_capacity) then
      raise exception 'Guest count is outside the configured Venue Only package capacity';
    end if;
    v_safe_guest_count:=v_guest_count;
  end if;

  v_payload:=jsonb_set(p_booking,'{guest_count}',to_jsonb(v_safe_guest_count),true);
  v_result:=public.create_evently_reservation_before_resort_staycation_pricing(v_payload);
  v_reservation_id:=nullif(v_result->>'reservation_id','')::uuid;
  if v_reservation_id is null then raise exception 'The established booking RPC did not return a reservation'; end if;
  select id into v_order_id from public.orders where reservation_id=v_reservation_id
    and customer_id=auth.uid() order by created_at limit 1;
  if v_order_id is null then raise exception 'The Resort reservation is not linked to an order'; end if;
  select coalesce(sum(price*coalesce(quantity,1)),0) into v_addon_total
    from public.reservation_addons where reservation_id=v_reservation_id;
  v_total:=round(public.evently_resort_service_amount(
    v_package.id,v_room_count,v_nights,v_pool_access_selected)+v_addon_total,2);
  v_deposit:=round(v_total*0.30,2);

  update public.reservations set
    guest_count=v_guest_count,room_count=case when v_is_room then v_room_count else null end,
    stay_nights=case when v_is_room then v_nights else null end,
    subtotal=v_total,total_amount=v_total,deposit_amount=v_deposit,
    remaining_balance=greatest(v_total-amount_paid,0),pricing_mode=v_package.pricing_mode,
    pool_access_selected=v_pool_access_selected,pool_access_fee=v_pool_fee,updated_at=now()
  where id=v_reservation_id and customer_id=auth.uid();
  update public.orders set
    guest_count=v_guest_count,room_count=case when v_is_room then v_room_count else null end,
    stay_nights=case when v_is_room then v_nights else null end,
    total_amount=v_total,remaining_balance=greatest(v_total-amount_paid,0),
    pool_access_selected=v_pool_access_selected,pool_access_fee=v_pool_fee,updated_at=now()
  where id=v_order_id and customer_id=auth.uid();
  select amount_paid into v_amount_paid from public.reservations where id=v_reservation_id;
  return v_result||jsonb_build_object(
    'reservation_id',v_reservation_id,'order_id',v_order_id,'guest_count',v_guest_count,
    'room_count',case when v_is_room then v_room_count else null end,
    'stay_nights',case when v_is_room then v_nights else null end,
    'subtotal',v_total,'total_amount',v_total,'deposit_amount',v_deposit,
    'remaining_balance',greatest(v_total-coalesce(v_amount_paid,0),0),
    'pool_access_selected',v_pool_access_selected,'pool_access_fee',v_pool_fee);
end;
$$;
revoke all on function public.create_evently_reservation_before_exact_resource_assignment(jsonb)
  from public,anon,authenticated;

notify pgrst,'reload schema';
commit;
