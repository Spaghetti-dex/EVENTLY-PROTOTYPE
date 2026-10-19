-- Run after the two-session concurrency check on the disposable database.
\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claim.sub', :'admin_id', true);
select set_config('evently.test.request_key_a', :'request_key_a', true);
select set_config('evently.test.request_key_b', :'request_key_b', true);
do $$
declare
  v_reservation_id uuid;
begin
  for v_reservation_id in
    select id from public.reservations
    where client_request_id in (
      current_setting('evently.test.request_key_a')::uuid,
      current_setting('evently.test.request_key_b')::uuid
    )
      and lower(status::text) not in ('cancelled', 'canceled', 'rejected', 'completed')
  loop
    perform public.evently_admin_override_reservation(
      p_reservation_id => v_reservation_id,
      p_action => 'release_schedule',
      p_reason => 'Disposable concurrent booking test cleanup'
    );
  end loop;
end;
$$;
commit;
