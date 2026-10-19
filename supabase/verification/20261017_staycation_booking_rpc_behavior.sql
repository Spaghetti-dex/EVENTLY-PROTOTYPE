-- Behavioral pool/room booking regression test for a disposable Supabase database.
-- This creates real reservations/orders through the public RPC and rolls them
-- back at the end. A customer profile must exist in the test database.
-- Run with psql -v ON_ERROR_STOP=1 after applying the migration under test.

begin;

create or replace function pg_temp.evently_test_create_existing_service_booking(
  p_package_id uuid, p_booking_service text, p_guest_count integer,
  p_reservation_date date, p_menu jsonb default '{}'::jsonb,
  p_room_count integer default 1, p_nights integer default 1,
  p_pool_access_selected boolean default false
) returns jsonb language plpgsql set search_path = '' as $$
declare
  v_package public.packages%rowtype;
  v_start time;
  v_end time;
  v_payload jsonb;
begin
  select * into v_package from public.packages where id = p_package_id and is_active;
  if not found then raise exception 'Regression-test package is unavailable'; end if;
  v_payload := jsonb_build_object(
    'idempotency_key', gen_random_uuid(), 'package_id', v_package.id,
    'package_variant_id', null, 'booking_service', p_booking_service,
    'reservation_date', p_reservation_date, 'guest_count', p_guest_count,
    'customer_name', 'EVENTLY Service Regression Test',
    'customer_email', 'service-test@example.com', 'customer_phone', '09123456789',
    'addons', '[]'::jsonb, 'menu', coalesce(p_menu, '{}'::jsonb),
    'cottage_selected', false, 'pool_access_selected', p_pool_access_selected,
    'item_quantity', 1, 'rooms', p_room_count, 'nights', p_nights,
    'special_requests', 'Disposable service regression test location'
  );
  if v_package.schedule_mode = 'customer_select' then
    v_start := coalesce(v_package.operating_start_time, time '09:00');
    if v_package.duration_minutes is null or v_package.duration_minutes < 1 then
      raise exception 'Regression-test customer-select package has no duration';
    end if;
    v_end := (p_reservation_date + v_start + make_interval(mins => v_package.duration_minutes))::time;
    v_payload := jsonb_set(jsonb_set(v_payload, '{start_time}', to_jsonb(v_start::text)), '{end_time}', to_jsonb(v_end::text));
  end if;
  return public.create_evently_reservation(jsonb_build_object('p_booking', v_payload));
end;
$$;

do $$
declare
  v_customer uuid;
  v_admin uuid;
  v_catering_package public.packages%rowtype;
  v_event_package public.packages%rowtype;
  v_standard_room public.packages%rowtype;
  v_kubo_room public.packages%rowtype;
  v_day uuid := '4ae972a8-6503-4776-90c9-899246cbc4dc';
  v_night uuid := '5afda244-a615-4bd3-98eb-d360d000100b';
  v_overnight uuid := '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8';
  v_day_cottage uuid := '1e97b2bf-ca43-492a-8a15-2d20f6abf040';
  v_overnight_cottage uuid := '928c269f-c38a-4345-86a5-d1f4c65555f0';
  v_pool_access_addon uuid;
  v_date date;
  v_later_date date;
  v_day_key uuid := gen_random_uuid();
  v_result jsonb;
  v_reservation_id uuid;
  v_order_id uuid;
  v_deadline timestamptz;
  v_message text;
  v_conflict_rejected boolean := false;
  v_manual_confirmation_rejected boolean := false;
  v_minimum_rejected boolean := false;
  v_wrong_cottage_rejected boolean := false;
  v_duplicate_cottage_rejected boolean := false;
  v_room_occupancy_rejected boolean := false;
  v_tour_pool_access_rejected boolean := false;
  v_generic_pool_access_rejected boolean := false;
  v_service_result jsonb;
  v_service_guest_count integer;
  v_day_guest_count integer;
  v_night_guest_count integer;
  v_overnight_guest_count integer;
  v_day_max integer;
  v_night_max integer;
  v_overnight_max integer;
  v_day_total numeric(12,2);
  v_day_deposit numeric(12,2);
  v_night_total numeric(12,2);
  v_overnight_total numeric(12,2);
begin
  select id into v_customer from public.profiles where role = 'customer' limit 1;
  if v_customer is null then raise exception 'Test database requires one customer profile'; end if;
  select id into v_admin from public.profiles where role in ('admin', 'owner') limit 1;
  if v_admin is null then raise exception 'Test database requires one Administrator/Owner profile'; end if;
  if exists(select 1 from public.packages package where package.id in (v_day,v_night,v_overnight)
    and (not package.pool_capacity_verified
      or package.pool_capacity_verified_at is null
      or package.pool_capacity_verified_by is null
      or package.pool_capacity_audit_id is null
      or package.max_guest_count is null
      or package.max_guest_count < package.min_guest_count
      or not exists(select 1 from public.evently_resources resource
        where resource.resource_key=package.resource_key
          and resource.is_active and resource.is_exclusive
          and resource.capacity=package.max_guest_count)
      or not exists(select 1 from public.evently_pool_capacity_audit audit
        where audit.id=package.pool_capacity_audit_id
          and audit.package_id=package.id
          and audit.changed_by=package.pool_capacity_verified_by
          and audit.new_capacity_verified
          and audit.new_max_guest_count is not distinct from package.max_guest_count
          and audit.verification_source='authenticated_admin_rpc'))) then
    raise exception 'BLOCKED: booking behavior tests require a matching Administrator audit with a real maximum for all three packages. No maximum is inferred by this test.';
  end if;
  select max_guest_count into v_day_max from public.packages where id=v_day;
  select max_guest_count into v_night_max from public.packages where id=v_night;
  select max_guest_count into v_overnight_max from public.packages where id=v_overnight;
  if (select count(*) from public.packages where
       (id=v_day and min_guest_count=1 and max_guest_count>=min_guest_count and price=100)
    or (id=v_night and min_guest_count=1 and max_guest_count>=min_guest_count and price=150)
    or (id=v_overnight and min_guest_count=20 and max_guest_count>=min_guest_count and price=200))<>3 then
    raise exception 'BLOCKED: pool packages do not match the Administrator-confirmed minimum/rate configuration';
  end if;
  v_day_guest_count := case when v_day_max is null then 25 else least(25,v_day_max) end;
  v_night_guest_count := case when v_night_max is null then 25 else least(25,v_night_max) end;
  v_overnight_guest_count := case when v_overnight_max is null or v_overnight_max >= 25 then 25 else 20 end;
  if v_day_guest_count<1 or v_night_guest_count<1 or v_overnight_guest_count<20 then
    raise exception 'BLOCKED: verified test capacity is below the configured minimum';
  end if;
  v_day_total:=100*v_day_guest_count+700;
  v_day_deposit:=round(v_day_total*0.30,2);
  v_night_total:=150*v_night_guest_count;
  v_overnight_total:=200*v_overnight_guest_count+1000;
  perform set_config('request.jwt.claim.sub', v_customer::text, true);

  -- Match the existing calendar policy: future dates only, Sundays unavailable.
  -- Find free, realistic test dates rather than using a date outside a possible
  -- booking horizon or colliding with disposable-database fixtures.
  select candidate.day::date into v_date
  from generate_series(current_date + 30, current_date + 365, interval '1 day') as candidate(day)
  where extract(dow from candidate.day) <> 0
    and public.evently_check_availability(v_day, candidate.day::date)
    and public.evently_check_availability(v_night, candidate.day::date)
    and public.evently_check_availability(v_overnight, candidate.day::date)
    and extract(dow from candidate.day + interval '1 day') <> 0
    and public.evently_check_availability(v_day, (candidate.day + interval '1 day')::date)
  order by candidate.day limit 1;
  if v_date is null then raise exception 'No free test date found within the supported future calendar window'; end if;

  select candidate.day::date into v_later_date
  from generate_series(v_date + 2, v_date + 365, interval '1 day') as candidate(day)
  where extract(dow from candidate.day) <> 0
    and extract(dow from candidate.day + interval '1 day') <> 0
    and public.evently_check_availability(v_overnight, candidate.day::date)
    and public.evently_check_availability(v_day, (candidate.day + interval '1 day')::date)
  order by candidate.day limit 1;
  if v_later_date is null then raise exception 'No free overnight/next-day test dates found in the supported calendar window'; end if;

  begin
    perform public.create_evently_reservation(jsonb_build_object('p_booking', jsonb_build_object(
      'idempotency_key', gen_random_uuid(), 'package_id', v_overnight,
      'booking_service', 'Swimming Pool', 'guest_count', 19,
      'reservation_date', v_later_date + 5, 'start_time', '19:00:00', 'end_time', '04:00:00',
      'customer_name', 'EVENTLY SQL Test', 'customer_email', 'pool-test@example.com',
      'customer_phone', '09123456789', 'addons', '[]'::jsonb, 'menu', '{}'::jsonb,
      'cottage_selected', false, 'pool_access_selected', false, 'rooms', 1, 'nights', 1
    )));
  exception when raise_exception then
    get stacked diagnostics v_message = message_text;
    v_minimum_rejected := v_message ilike '%at least 20%';
  end;
  if not v_minimum_rejected then raise exception 'FAIL: booking RPC did not enforce the Overnight 20-guest minimum'; end if;

  begin
    perform public.create_evently_reservation(jsonb_build_object('p_booking', jsonb_build_object(
      'idempotency_key', gen_random_uuid(), 'package_id', v_day,
       'booking_service', 'Swimming Pool', 'guest_count', v_day_guest_count,
      'reservation_date', v_later_date + 6, 'start_time', '08:00:00', 'end_time', '15:00:00',
      'customer_name', 'EVENTLY SQL Test', 'customer_email', 'pool-test@example.com',
      'customer_phone', '09123456789', 'addons', '[]'::jsonb, 'menu', '{}'::jsonb,
      'cottage_selected', true, 'cottage_addon_id', v_overnight_cottage,
      'pool_access_selected', false, 'rooms', 1, 'nights', 1
    )));
  exception when raise_exception then
    get stacked diagnostics v_message = message_text;
    v_wrong_cottage_rejected := v_message ilike '%cottage%';
  end;
  if not v_wrong_cottage_rejected then raise exception 'FAIL: booking RPC accepted the wrong-tour cottage add-on'; end if;

  v_day_key:=gen_random_uuid();
  begin
    perform public.create_evently_reservation(jsonb_build_object('p_booking',jsonb_build_object(
      'idempotency_key',v_day_key,'package_id',v_day,'booking_service','Swimming Pool',
      'guest_count',v_day_guest_count,'reservation_date',v_later_date+6,
      'start_time','08:00:00','end_time','15:00:00',
      'customer_name','EVENTLY SQL Test','customer_email','pool-test@example.com',
      'customer_phone','09123456789','addons',jsonb_build_array(jsonb_build_object('id',v_day_cottage)),
      'menu','{}'::jsonb,'cottage_selected',true,'cottage_addon_id',v_day_cottage,
      'pool_access_selected',false,'rooms',1,'nights',1
    )));
  exception when raise_exception then
    get stacked diagnostics v_message=message_text;
    v_duplicate_cottage_rejected:=v_message ilike '%generic add-on%';
  end;
  if not v_duplicate_cottage_rejected then
    raise exception 'FAIL: booking RPC did not reject a cottage duplicated as a generic add-on';
  end if;
  if exists(select 1 from public.reservations where customer_id=v_customer and client_request_id=v_day_key) then
    raise exception 'FAIL: rejected duplicate cottage booking left a reservation row';
  end if;

   -- Day Tour uses a test count within its separately verified physical limit.
   -- Cottage adds once to total/order/snapshot, and deposit remains 30%.
  v_result := public.create_evently_reservation(jsonb_build_object('p_booking', jsonb_build_object(
    'idempotency_key', v_day_key, 'package_id', v_day,
    'booking_service', 'Swimming Pool', 'guest_count', v_day_guest_count,
    'reservation_date', v_date, 'start_time', '08:00:00', 'end_time', '15:00:00',
    'customer_name', 'EVENTLY SQL Test', 'customer_email', 'pool-test@example.com',
    'customer_phone', '09123456789', 'addons', '[]'::jsonb, 'menu', '{}'::jsonb,
    'cottage_selected', true, 'cottage_addon_id', v_day_cottage,
    'pool_access_selected', false, 'rooms', 1, 'nights', 1
  )));
  v_reservation_id := (v_result ->> 'reservation_id')::uuid;
  v_order_id := (v_result ->> 'order_id')::uuid;
  if v_result ->> 'order_id' is distinct from v_order_id::text
      or (v_result ->> 'subtotal')::numeric <> v_day_total
      or (v_result ->> 'total_amount')::numeric <> v_day_total
      or (v_result ->> 'deposit_amount')::numeric <> v_day_deposit
      or (v_result ->> 'remaining_balance')::numeric <> v_day_total
     or (v_result ->> 'cottage_addon_id')::uuid <> v_day_cottage
     or (v_result ->> 'cottage_fee')::numeric <> 700
     or (v_result ->> 'cottage_selected')::boolean is not true
      or (select total_amount from public.reservations where id = v_reservation_id) <> v_day_total
      or (select deposit_amount from public.reservations where id = v_reservation_id) <> v_day_deposit
      or (select total_amount from public.orders where id = v_order_id) <> v_day_total
     or (select cottage_addon_id from public.reservations where id = v_reservation_id) <> v_day_cottage
     or (select cottage_addon_id from public.orders where id = v_order_id) <> v_day_cottage
     or exists (select 1 from public.reservation_addons where reservation_id = v_reservation_id and addon_id = v_day_cottage) then
    raise exception 'FAIL: Day Tour per-person/cottage/order snapshot total or 30% deposit is incorrect';
  end if;
  v_deadline := (v_result ->> 'payment_due_at')::timestamptz;
  if v_deadline <> (select created_at + interval '24 hours' from public.reservations where id = v_reservation_id) then
    raise exception 'FAIL: Day Tour payment deadline is not created_at plus 24 hours';
  end if;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  begin
    perform public.admin_transition_reservation(v_reservation_id, 'confirmed', 'test direct confirmation bypass');
  exception when raise_exception then
    v_manual_confirmation_rejected := sqlerrm ilike '%payment-driven%';
  end;
  perform set_config('request.jwt.claim.sub', v_customer::text, true);
  if not v_manual_confirmation_rejected
     or (select lower(status::text) from public.reservations where id = v_reservation_id) <> 'pending' then
    raise exception 'FAIL: Admin status transition bypassed payment-driven confirmation';
  end if;

  -- Idempotent retry returns the original deadline and does not add a second
  -- cottage or booking charge.
  v_result := public.create_evently_reservation(jsonb_build_object('p_booking', jsonb_build_object(
    'idempotency_key', v_day_key,
    'package_id', v_day, 'booking_service', 'Swimming Pool', 'guest_count', v_day_guest_count,
    'reservation_date', v_date, 'start_time', '08:00:00', 'end_time', '15:00:00',
    'customer_name', 'EVENTLY SQL Test', 'customer_email', 'pool-test@example.com',
    'customer_phone', '09123456789', 'addons', '[]'::jsonb, 'menu', '{}'::jsonb,
    'cottage_selected', true, 'cottage_addon_id', v_day_cottage,
    'pool_access_selected', false, 'rooms', 1, 'nights', 1
  )));
  if (v_result ->> 'payment_due_at')::timestamptz <> v_deadline
     or (select count(*) from public.reservations where customer_id = v_customer and client_request_id = v_day_key) <> 1
     or (v_result ->> 'order_id')::uuid <> v_order_id
      or (v_result ->> 'total_amount')::numeric <> v_day_total
      or (v_result ->> 'deposit_amount')::numeric <> v_day_deposit
      or (v_result ->> 'remaining_balance')::numeric <> v_day_total
     or (v_result ->> 'cottage_addon_id')::uuid <> v_day_cottage
     or (select total_amount from public.reservations where id = v_reservation_id) <> 10700 then
    raise exception 'FAIL: idempotent retry changed deadline, totals, or duplicated the booking';
  end if;

  -- Day and Night may share a date. Night and Overnight on that date must
  -- conflict at the same exclusive pool.
  v_result := public.create_evently_reservation(jsonb_build_object('p_booking', jsonb_build_object(
    'idempotency_key', gen_random_uuid(), 'package_id', v_night,
    'booking_service', 'Swimming Pool', 'guest_count', v_night_guest_count,
    'reservation_date', v_date, 'start_time', '16:00:00', 'end_time', '22:00:00',
    'customer_name', 'EVENTLY SQL Test', 'customer_email', 'pool-test@example.com',
    'customer_phone', '09123456789', 'addons', '[]'::jsonb, 'menu', '{}'::jsonb,
    'cottage_selected', false, 'pool_access_selected', false, 'rooms', 1, 'nights', 1
  )));
  if (v_result ->> 'subtotal')::numeric <> v_night_total then raise exception 'FAIL: Night Tour was not billed per guest'; end if;
  begin
    perform public.create_evently_reservation(jsonb_build_object('p_booking', jsonb_build_object(
      'idempotency_key', gen_random_uuid(), 'package_id', v_overnight,
      'booking_service', 'Swimming Pool', 'guest_count', 20,
      'reservation_date', v_date, 'start_time', '19:00:00', 'end_time', '04:00:00',
      'customer_name', 'EVENTLY SQL Test', 'customer_email', 'pool-test@example.com',
      'customer_phone', '09123456789', 'addons', '[]'::jsonb, 'menu', '{}'::jsonb,
      'cottage_selected', false, 'pool_access_selected', false, 'rooms', 1, 'nights', 1
    )));
  exception when raise_exception then
    get stacked diagnostics v_message = message_text;
    v_conflict_rejected := v_message ilike '%available%' or v_message ilike '%conflict%' or v_message ilike '%held%';
  end;
  if not v_conflict_rejected then raise exception 'FAIL: same-date Night/Overnight conflict was not rejected'; end if;

   -- Overnight's 19:00–04:00 interval does not conflict with next-day Day Tour
   -- at 08:00. The guest count respects the explicitly verified test capacity.
  v_result := public.create_evently_reservation(jsonb_build_object('p_booking', jsonb_build_object(
    'idempotency_key', gen_random_uuid(), 'package_id', v_overnight,
    'booking_service', 'Swimming Pool', 'guest_count', v_overnight_guest_count,
    'reservation_date', v_later_date, 'start_time', '19:00:00', 'end_time', '04:00:00',
    'customer_name', 'EVENTLY SQL Test', 'customer_email', 'pool-test@example.com',
    'customer_phone', '09123456789', 'addons', '[]'::jsonb, 'menu', '{}'::jsonb,
    'cottage_selected', true, 'cottage_addon_id', v_overnight_cottage,
    'pool_access_selected', false, 'rooms', 1, 'nights', 1
  )));
  v_reservation_id := (v_result ->> 'reservation_id')::uuid;
  if (v_result ->> 'subtotal')::numeric <> v_overnight_total
     or (select deposit_amount from public.reservations where id = v_reservation_id) <> round(v_overnight_total*0.30,2) then
    raise exception 'FAIL: Overnight 21-guest rate, cottage, or deposit is incorrect';
  end if;
  v_result := public.create_evently_reservation(jsonb_build_object('p_booking', jsonb_build_object(
    'idempotency_key', gen_random_uuid(), 'package_id', v_day,
    'booking_service', 'Swimming Pool', 'guest_count', v_day_guest_count,
    'reservation_date', v_later_date + 1, 'start_time', '08:00:00', 'end_time', '15:00:00',
    'customer_name', 'EVENTLY SQL Test', 'customer_email', 'pool-test@example.com',
    'customer_phone', '09123456789', 'addons', '[]'::jsonb, 'menu', '{}'::jsonb,
    'cottage_selected', false, 'pool_access_selected', false, 'rooms', 1, 'nights', 1
  )));
  if (v_result is null) then raise exception 'FAIL: next-day Day Tour should be available after Overnight ends at 04:00'; end if;

  -- Existing non-pool services still use their established delegated calculator.
  select * into v_catering_package from public.packages
  where is_active and lower(service_type::text) = 'catering' order by name limit 1;
  if not found then raise exception 'Disposable database requires an active Catering package'; end if;
  v_service_guest_count := greatest(coalesce(v_catering_package.min_guest_count, 1), 1);
  if v_catering_package.guest_capacity is not null then
    v_service_guest_count := least(v_service_guest_count, v_catering_package.guest_capacity);
  end if;
  v_service_result := pg_temp.evently_test_create_existing_service_booking(
    v_catering_package.id, 'Catering', v_service_guest_count, v_later_date + 2,
    jsonb_build_object('Integration Test Menu', 'Test Selection')
  );
  if (v_service_result ->> 'total_amount')::numeric <> v_catering_package.price then
    raise exception 'FAIL: Catering flat package pricing changed in the pool per-person wrapper';
  end if;

  select * into v_event_package from public.packages
  where is_active and package_category = 'event_venue' and schedule_mode = 'admin_assign'
  order by name limit 1;
  if not found then raise exception 'Disposable database requires an active Admin-assigned Events Place package'; end if;
  v_service_result := pg_temp.evently_test_create_existing_service_booking(
    v_event_package.id, 'Event', 1, v_later_date + 3, '{}'::jsonb
  );
  if (v_service_result ->> 'total_amount')::numeric <> v_event_package.price then
    raise exception 'FAIL: Events Place package pricing changed in the pool per-person wrapper';
  end if;

  select * into v_standard_room from public.packages
  where is_active and lower(name) = 'standard room' limit 1;
  select * into v_kubo_room from public.packages
  where is_active and lower(name) = 'kubo room' limit 1;
  if v_standard_room.id is null or v_kubo_room.id is null then
    raise exception 'Disposable database requires active Standard Room and Kubo Room packages';
  end if;
  if v_standard_room.price<>3000 or v_standard_room.min_guest_count<>4 or v_standard_room.guest_capacity<>5
     or v_standard_room.pricing_mode<>'per_night' or v_standard_room.pool_access_fee<>5000
     or v_standard_room.deposit_percentage<>30 then
    raise exception 'BLOCKED: Standard Room does not match the confirmed 4–5 guest/₱3,000 rate';
  end if;
  v_service_guest_count:=8;
  v_service_result := pg_temp.evently_test_create_existing_service_booking(
    v_standard_room.id, 'Room Accommodation', v_service_guest_count, v_later_date + 4,
    '{}'::jsonb,2,3,false
  );
  if (v_service_result ->> 'total_amount')::numeric <> 18000
     or (v_service_result ->> 'deposit_amount')::numeric<>5400
     or (v_service_result ->> 'room_count')::integer<>2
     or (v_service_result ->> 'stay_nights')::integer<>3
     or coalesce((v_service_result->>'pool_access_fee')::numeric,0)<>0 then
    raise exception 'FAIL: Standard Room 2-room/3-night total, 30%% deposit, or no-access snapshot is incorrect';
  end if;
  v_service_result := pg_temp.evently_test_create_existing_service_booking(
    v_standard_room.id, 'Room Accommodation', v_service_guest_count, v_later_date + 7,
    '{}'::jsonb,2,3,true
  );
  if (v_service_result ->> 'total_amount')::numeric <> 23000
     or (v_service_result ->> 'deposit_amount')::numeric<>6900
     or coalesce((v_service_result->>'pool_access_fee')::numeric,0)<>5000
     or v_service_result->>'pool_access_selected'<>'true' then
    raise exception 'FAIL: optional Standard Room Pool Access was not charged exactly once';
  end if;
  begin
    perform pg_temp.evently_test_create_existing_service_booking(
      v_standard_room.id,'Room Accommodation',3,v_later_date+11,'{}'::jsonb,1,1,false);
  exception when raise_exception then v_room_occupancy_rejected:=true;
  end;
  if not v_room_occupancy_rejected then raise exception 'FAIL: Standard Room allowed fewer than four guests'; end if;
  v_room_occupancy_rejected:=false;
  begin
    perform pg_temp.evently_test_create_existing_service_booking(
      v_standard_room.id,'Room Accommodation',11,v_later_date+12,'{}'::jsonb,2,1,false);
  exception when raise_exception then v_room_occupancy_rejected:=true;
  end;
  if not v_room_occupancy_rejected then raise exception 'FAIL: Standard Room allowed more than five guests per room'; end if;

  begin
    perform pg_temp.evently_test_create_existing_service_booking(
      v_day,'Swimming Pool',1,v_later_date+2,'{}'::jsonb,1,1,true);
  exception when raise_exception then v_tour_pool_access_rejected:=true;
  end;
  if not v_tour_pool_access_rejected then raise exception 'FAIL: optional Pool Access was accepted on a Swimming Tour'; end if;
  select id into v_pool_access_addon from public.addons
    where is_active and lower(name) like '%pool%access%' order by id limit 1;
  if v_pool_access_addon is not null then
    v_day_key:=gen_random_uuid();
    begin
      perform public.create_evently_reservation(jsonb_build_object('p_booking',jsonb_build_object(
        'idempotency_key',v_day_key,'package_id',v_day,'booking_service','Swimming Pool',
        'guest_count',v_day_guest_count,'reservation_date',v_later_date+3,
        'start_time','08:00:00','end_time','15:00:00',
        'customer_name','EVENTLY SQL Test','customer_email','pool-test@example.com',
        'customer_phone','09123456789','addons',jsonb_build_array(jsonb_build_object('id',v_pool_access_addon)),
        'menu','{}'::jsonb,'cottage_selected',false,'pool_access_selected',false,'rooms',1,'nights',1
      )));
    exception when raise_exception then
      get stacked diagnostics v_message=message_text;
      v_generic_pool_access_rejected:=v_message ilike '%Pool Access is not available%';
    end;
    if not v_generic_pool_access_rejected then
      raise exception 'FAIL: Pool Access was accepted as a generic Swimming Tour add-on';
    end if;
    if exists(select 1 from public.reservations where customer_id=v_customer and client_request_id=v_day_key) then
      raise exception 'FAIL: rejected generic Pool Access left a Swimming Tour reservation';
    end if;
  end if;
  if v_kubo_room.price<>1500 or v_kubo_room.min_guest_count<>1
     or v_kubo_room.pricing_mode<>'per_night' or v_kubo_room.pool_access_fee<>5000
     or v_kubo_room.deposit_percentage<>30 then
    raise exception 'BLOCKED: Kubo Room does not match the confirmed ₱1,500 rate/no-invented-cap configuration';
  end if;
  v_service_guest_count := greatest(coalesce(v_kubo_room.min_guest_count, 1), 1);
  v_service_result := pg_temp.evently_test_create_existing_service_booking(
    v_kubo_room.id, 'Room Accommodation', v_service_guest_count, v_later_date + 10,
    '{}'::jsonb,2,2,true
  );
  if (v_service_result ->> 'total_amount')::numeric <> 11000
     or (v_service_result ->> 'deposit_amount')::numeric<>3300
     or coalesce((v_service_result->>'pool_access_fee')::numeric,0)<>5000 then
    raise exception 'FAIL: Kubo Room multi-night total or optional Pool Access total is incorrect';
  end if;
end;
$$;

rollback;
