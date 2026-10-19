-- Behavioral payment/hold regression test for a disposable Supabase database.
-- Requires one customer, one admin/owner, one staff profile, and the normal
-- private payment-proofs bucket. All fixture rows are rolled back.
-- Run with psql -v ON_ERROR_STOP=1 after applying the migration under test.

begin;

create or replace function pg_temp.evently_test_create_day_booking(p_date date)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_start time;
  v_end time;
begin
  select coalesce(fixed_start_time, operating_start_time),
         coalesce(fixed_end_time, operating_end_time)
    into v_start, v_end
  from public.packages where id = '4ae972a8-6503-4776-90c9-899246cbc4dc' and is_active;
  if v_start is null or v_end is null then raise exception 'Test pool tour schedule is not configured'; end if;
  return public.create_evently_reservation(jsonb_build_object('p_booking', jsonb_build_object(
    'idempotency_key', gen_random_uuid(),
    'package_id', '4ae972a8-6503-4776-90c9-899246cbc4dc',
    'booking_service', 'Swimming Pool', 'guest_count', 2,
    'reservation_date', p_date, 'start_time', v_start::text, 'end_time', v_end::text,
    'customer_name', 'EVENTLY Hold Test', 'customer_email', 'hold-test@example.com',
    'customer_phone', '09123456789', 'addons', '[]'::jsonb, 'menu', '{}'::jsonb,
    'cottage_selected', false, 'pool_access_selected', false, 'rooms', 1, 'nights', 1
  )));
end;
$$;

create or replace function pg_temp.evently_test_insert_pending_proof(
  p_customer_id uuid, p_reservation_id uuid, p_amount numeric,
  p_submitted_at timestamptz, p_suffix text
) returns uuid language plpgsql set search_path = '' as $$
declare
  v_order_id uuid;
  v_payment_id uuid;
  v_status_column text;
  v_method_column text;
  v_pending text;
  v_method text;
  v_path text := p_customer_id::text || '/' || gen_random_uuid()::text || '.png';
begin
  select id into v_order_id from public.orders
  where reservation_id = p_reservation_id and customer_id = p_customer_id limit 1;
  if v_order_id is null then raise exception 'Test reservation is not linked to an order'; end if;
  insert into storage.objects(bucket_id, name, metadata)
  values ('payment-proofs', v_path, jsonb_build_object('mimetype', 'image/png'));
  v_status_column := public.evently_existing_column('public.payments', array['verification_status', 'status']);
  v_method_column := public.evently_existing_column('public.payments', array['method', 'payment_method']);
  if v_status_column is null or v_method_column is null then raise exception 'Payment columns are not configured'; end if;
  v_pending := public.evently_status_value('public.payments', v_status_column, 'pending');
  v_method := public.evently_status_value('public.payments', v_method_column, 'gcash');
  execute format(
    'insert into public.payments (customer_id,reservation_id,order_id,amount,%I,%I,reference_number,proof_url,demo_mode,submitted_at) values ($1,$2,$3,$4,%L,%L,$5,$6,false,$7) returning id',
    v_status_column, v_method_column, v_pending, v_method
  ) into v_payment_id using p_customer_id, p_reservation_id, v_order_id, p_amount,
    'EVENTLY-HOLD-' || p_suffix, v_path, p_submitted_at;
  return v_payment_id;
end;
$$;

do $$
declare
  v_customer uuid;
  v_admin uuid;
  v_staff uuid;
  v_expiry_date date;
  v_timely_date date;
  v_reject_date date;
  v_staff_date date;
  v_legacy_date date;
  v_booking jsonb;
  v_reservation_id uuid;
  v_legacy_reservation_id uuid;
  v_payment_id uuid;
  v_amount numeric(12,2);
  v_due timestamptz;
  v_status_column text;
  v_payment_status text;
  v_error text;
  v_rejected boolean;
  v_new_deadline timestamptz;
begin
  select id into v_customer from public.profiles where role = 'customer' limit 1;
  select id into v_admin from public.profiles where role in ('admin', 'owner') limit 1;
  select id into v_staff from public.profiles where role = 'staff' and coalesce(staff_active, true) limit 1;
  if v_customer is null or v_admin is null or v_staff is null then
    raise exception 'Test database requires customer, Admin/Owner, and active Staff profiles';
  end if;
  perform set_config('request.jwt.claim.sub', v_customer::text, true);

  -- Choose four future non-Sunday dates with free pool intervals, matching the
  -- customer calendar rule and avoiding collisions with disposable fixtures.
  select candidate.day::date into v_expiry_date
  from generate_series(current_date + 30, current_date + 400, interval '1 day') candidate(day)
  where extract(dow from candidate.day) <> 0
    and public.evently_check_availability('4ae972a8-6503-4776-90c9-899246cbc4dc', candidate.day::date)
  order by candidate.day limit 1;
  select candidate.day::date into v_timely_date
  from generate_series(current_date + 30, current_date + 400, interval '1 day') candidate(day)
  where extract(dow from candidate.day) <> 0 and candidate.day::date <> v_expiry_date
    and public.evently_check_availability('4ae972a8-6503-4776-90c9-899246cbc4dc', candidate.day::date)
  order by candidate.day limit 1;
  select candidate.day::date into v_reject_date
  from generate_series(current_date + 30, current_date + 400, interval '1 day') candidate(day)
  where extract(dow from candidate.day) <> 0 and candidate.day::date not in (v_expiry_date, v_timely_date)
    and public.evently_check_availability('4ae972a8-6503-4776-90c9-899246cbc4dc', candidate.day::date)
  order by candidate.day limit 1;
  select candidate.day::date into v_staff_date
  from generate_series(current_date + 30, current_date + 400, interval '1 day') candidate(day)
  where extract(dow from candidate.day) <> 0 and candidate.day::date not in (v_expiry_date, v_timely_date, v_reject_date)
    and public.evently_check_availability('4ae972a8-6503-4776-90c9-899246cbc4dc', candidate.day::date)
  order by candidate.day limit 1;
  if v_expiry_date is null or v_timely_date is null or v_reject_date is null or v_staff_date is null then
    raise exception 'Could not find four free test dates within the existing calendar window';
  end if;
  select candidate.day::date into v_legacy_date
  from generate_series(current_date + 30, current_date + 400, interval '1 day') candidate(day)
  where extract(dow from candidate.day) <> 0
    and candidate.day::date not in (v_expiry_date, v_timely_date, v_reject_date, v_staff_date)
    and public.evently_check_availability('4ae972a8-6503-4776-90c9-899246cbc4dc', candidate.day::date)
  order by candidate.day limit 1;
  if v_legacy_date is null then raise exception 'No free date found for the legacy deadline transition test'; end if;

  -- Expiration at/after the saved 24-hour deadline releases availability and
  -- rejects later payment submission.
  v_booking := pg_temp.evently_test_create_day_booking(v_expiry_date);
  v_reservation_id := (v_booking ->> 'reservation_id')::uuid;
  update public.reservations set created_at = now() - interval '25 hours',
    payment_due_at = public.evently_payment_deadline(now() - interval '25 hours')
  where id = v_reservation_id;
  perform public.evently_expire_unpaid_reservations();
  if (select expired_at is null or lower(status::text) <> 'cancelled'
      from public.reservations where id = v_reservation_id) then
    raise exception 'FAIL: overdue unpaid reservation did not expire';
  end if;
  if not public.evently_check_availability('4ae972a8-6503-4776-90c9-899246cbc4dc', v_expiry_date) then
    raise exception 'FAIL: expired booking continued to block its schedule';
  end if;
  v_rejected := false;
  begin
    perform public.evently_submit_payment_proof(
      v_reservation_id, 60, 'gcash', 'EVENTLY-LATE-PROOF', v_customer::text || '/late.png'
    );
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    v_rejected := v_error ilike '%expired%' or v_error ilike '%deadline%';
  end;
  if not v_rejected then raise exception 'FAIL: payment proof after expiration was not rejected'; end if;

  -- A valid timely pending proof protects a past-deadline hold until review;
  -- verification of the 30% deposit then confirms it automatically.
  v_booking := pg_temp.evently_test_create_day_booking(v_timely_date);
  v_reservation_id := (v_booking ->> 'reservation_id')::uuid;
  v_due := (select public.evently_payment_deadline(created_at - interval '25 hours')
    from public.reservations where id = v_reservation_id);
  update public.reservations set created_at = now() - interval '25 hours', payment_due_at = v_due
  where id = v_reservation_id;
  v_amount := (select deposit_amount from public.reservations where id = v_reservation_id);
  v_payment_id := pg_temp.evently_test_insert_pending_proof(v_customer, v_reservation_id, v_amount, v_due - interval '5 minutes', 'TIMELY');
  perform public.evently_expire_unpaid_reservations();
  if (select expired_at is not null or lower(status::text) <> 'pending'
      from public.reservations where id = v_reservation_id)
     or not public.evently_reservation_holds_schedule(v_reservation_id) then
    raise exception 'FAIL: timely valid proof under review did not preserve its hold';
  end if;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform public.admin_review_payment(v_payment_id, 'verified', null);
  if (select lower(status::text) <> 'confirmed' from public.reservations where id = v_reservation_id) then
    raise exception 'FAIL: verified timely 30% deposit did not automatically confirm the booking';
  end if;
  perform set_config('request.jwt.claim.sub', v_customer::text, true);

  -- Rejection preserves the original deadline and expires an unpaid booking
  -- immediately once that original deadline has passed.
  v_booking := pg_temp.evently_test_create_day_booking(v_reject_date);
  v_reservation_id := (v_booking ->> 'reservation_id')::uuid;
  v_due := (select public.evently_payment_deadline(created_at - interval '25 hours')
    from public.reservations where id = v_reservation_id);
  update public.reservations set created_at = now() - interval '25 hours', payment_due_at = v_due
  where id = v_reservation_id;
  v_amount := (select deposit_amount from public.reservations where id = v_reservation_id);
  v_payment_id := pg_temp.evently_test_insert_pending_proof(v_customer, v_reservation_id, v_amount, v_due - interval '5 minutes', 'REJECTED');
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform public.admin_review_payment(v_payment_id, 'rejected', 'Disposable test rejection');
  if (select payment_due_at is distinct from v_due or expired_at is null
      or lower(status::text) <> 'cancelled' from public.reservations where id = v_reservation_id) then
    raise exception 'FAIL: rejected proof reset its deadline or failed to expire after the original deadline';
  end if;
  perform set_config('request.jwt.claim.sub', v_customer::text, true);

  -- Staff must not be able to verify a pending payment.
  v_booking := pg_temp.evently_test_create_day_booking(v_staff_date);
  v_reservation_id := (v_booking ->> 'reservation_id')::uuid;
  v_amount := (select deposit_amount from public.reservations where id = v_reservation_id);
  v_payment_id := pg_temp.evently_test_insert_pending_proof(v_customer, v_reservation_id, v_amount, now(), 'STAFF');
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_rejected := false;
  begin
    perform public.admin_review_payment(v_payment_id, 'verified', null);
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    v_rejected := v_error ilike '%administrative access required%';
  end;
  if not v_rejected then raise exception 'FAIL: Staff was able to verify payment'; end if;
  v_status_column := public.evently_existing_column('public.payments', array['verification_status', 'status']);
  execute format('select %I::text from public.payments where id = $1', v_status_column)
    into v_payment_status using v_payment_id;
  if lower(v_payment_status) <> 'pending' then raise exception 'FAIL: failed Staff verification mutated payment state'; end if;

  -- Legacy NULL-deadline holds are not expired automatically. Starting their
  -- deadline is an audited Admin override, and Staff cannot perform it.
  perform set_config('request.jwt.claim.sub', v_customer::text, true);
  v_booking := pg_temp.evently_test_create_day_booking(v_legacy_date);
  v_legacy_reservation_id := (v_booking ->> 'reservation_id')::uuid;
  update public.reservations set payment_due_at = null where id = v_legacy_reservation_id;
  perform public.evently_expire_unpaid_reservations();
  if not public.evently_reservation_holds_schedule(v_legacy_reservation_id) then
    raise exception 'FAIL: legacy NULL-deadline booking did not retain its schedule hold';
  end if;
  if (select expired_at is not null or lower(status::text) <> 'pending'
      from public.reservations where id = v_legacy_reservation_id) then
    raise exception 'FAIL: migration expiry processed a grandfathered legacy booking';
  end if;
  v_new_deadline := clock_timestamp() + interval '48 hours';
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform public.evently_admin_override_reservation(
    p_reservation_id => v_legacy_reservation_id,
    p_action => 'extend_payment_deadline',
    p_reason => 'Disposable legacy-hold transition test',
    p_payment_due_at => v_new_deadline
  );
  if (select payment_due_at from public.reservations where id = v_legacy_reservation_id) is distinct from v_new_deadline
     or not exists (select 1 from public.evently_reservation_override_audit
       where reservation_id = v_legacy_reservation_id and admin_id = v_admin
         and action = 'extend_payment_deadline'
         and previous_values ->> 'payment_due_at' is null
         and (new_values ->> 'payment_due_at')::timestamptz = v_new_deadline) then
    raise exception 'FAIL: Admin did not start and audit the legacy payment deadline';
  end if;
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_rejected := false;
  begin
    perform public.evently_admin_override_reservation(
      p_reservation_id => v_legacy_reservation_id,
      p_action => 'extend_payment_deadline',
      p_reason => 'Staff must not override deadlines',
      p_payment_due_at => v_new_deadline + interval '1 hour'
    );
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    v_rejected := v_error ilike '%administrator access required%';
  end;
  if not v_rejected or (select payment_due_at from public.reservations where id = v_legacy_reservation_id) is distinct from v_new_deadline then
    raise exception 'FAIL: Staff changed an Administrator-only payment deadline';
  end if;
end;
$$;

rollback;
