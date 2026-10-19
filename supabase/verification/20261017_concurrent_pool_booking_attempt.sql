-- One concurrent pool-booking attempt. Run two psql processes at the same time
-- with the same customer/date and different request_key values. Exactly one
-- process must succeed; the other must receive an availability/conflict error.
\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claim.sub', :'customer_id', true);
do $$
begin
  if not exists(select 1 from public.packages where id='4ae972a8-6503-4776-90c9-899246cbc4dc'
    and pool_capacity_verified and (max_guest_count is null or max_guest_count>=2)) then
    raise exception 'Test requires a physically verified Day Tour capacity of at least two guests';
  end if;
end;
$$;
select public.create_evently_reservation(jsonb_build_object('p_booking', jsonb_build_object(
  'idempotency_key', :'request_key'::uuid,
  'package_id', '4ae972a8-6503-4776-90c9-899246cbc4dc',
  'booking_service', 'Swimming Pool', 'guest_count', 20,
  'reservation_date', :'reservation_date'::date,
  'start_time', '08:00:00', 'end_time', '15:00:00',
  'customer_name', 'EVENTLY Concurrency Test',
  'customer_email', 'pool-concurrency@example.com',
  'customer_phone', '09123456789', 'addons', '[]'::jsonb,
  'menu', '{}'::jsonb, 'cottage_selected', false,
  'pool_access_selected', false, 'rooms', 1, 'nights', 1
)));
commit;
