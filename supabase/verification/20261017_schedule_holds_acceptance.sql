-- Executable, read-only acceptance checks for the schedule-hold migration.
-- Run against a disposable/test Supabase project after applying migrations:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f this-file.sql

do $$
declare
  v_created timestamptz := '2026-10-17 08:00:00+08';
  v_day_start timestamp := timestamp '2026-10-20 08:00';
  v_day_end timestamp := timestamp '2026-10-20 15:00';
  v_night_start timestamp := timestamp '2026-10-20 16:00';
  v_night_end timestamp := timestamp '2026-10-20 22:00';
  v_overnight_start timestamp := timestamp '2026-10-20 19:00';
  v_overnight_end timestamp := timestamp '2026-10-21 04:00';
  v_next_day_start timestamp := timestamp '2026-10-21 08:00';
  v_next_day_end timestamp := timestamp '2026-10-21 15:00';
  v_due_type text;
  v_pricing_mode_default text;
  v_catalog_pricing_columns integer;
  v_error text;
  v_create_definition text;
  v_delegated_create_definition text;
  v_payment_definition text;
  v_expire_definition text;
  v_pending_proof_definition text;
  v_auto_confirm_definition text;
  v_override_definition text;
  v_wrong_cottage_rejected boolean := false;
  v_capacity record;
  v_capacity_rejected boolean;
begin
  if public.evently_payment_deadline(v_created) <> v_created + interval '24 hours' then
    raise exception 'FAIL: payment deadline must be exactly 24 hours after creation';
  end if;
  if v_day_start < v_night_end and v_day_end > v_night_start then
    raise exception 'FAIL: Day and Night tours must not overlap';
  end if;
  if not (v_night_start < v_overnight_end and v_night_end > v_overnight_start) then
    raise exception 'FAIL: same-date Night and Overnight tours must overlap';
  end if;
  if v_overnight_start < v_next_day_end and v_overnight_end > v_next_day_start then
    raise exception 'FAIL: Overnight and next-day Day tour must not overlap';
  end if;

  select data_type into v_due_type from information_schema.columns
  where table_schema = 'public' and table_name = 'reservations' and column_name = 'payment_due_at';
  if v_due_type is distinct from 'timestamp with time zone' then
    raise exception 'FAIL: reservations.payment_due_at must be timestamptz';
  end if;
  select column_default into v_pricing_mode_default from information_schema.columns
  where table_schema='public' and table_name='packages' and column_name='pricing_mode';
  if position('per_booking' in lower(coalesce(v_pricing_mode_default,'')))=0 then
    raise exception 'FAIL: packages.pricing_mode default must remain per_booking';
  end if;
  select count(*) into v_catalog_pricing_columns from information_schema.columns
  where table_schema = 'public' and table_name = 'packages' and (
    (column_name = 'pricing_mode' and data_type = 'text' and is_nullable = 'NO')
    or (column_name = 'min_guest_count' and data_type = 'integer' and is_nullable = 'NO')
    or (column_name in ('cottage_fee', 'pool_access_fee') and data_type = 'numeric' and is_nullable = 'NO')
     or (column_name = 'cottage_addon_id' and data_type = 'uuid')
     or (column_name = 'max_guest_count' and data_type = 'integer')
     or (column_name = 'pool_capacity_verified' and data_type = 'boolean')
  );
  if v_catalog_pricing_columns <> 7 then
    raise exception 'FAIL: the package pricing, verified-capacity, minimum, and cottage schema columns are incomplete';
  end if;

  if (select count(*) from public.packages where id in (
    '4ae972a8-6503-4776-90c9-899246cbc4dc',
    '5afda244-a615-4bd3-98eb-d360d000100b',
    '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
   ) and resource_key = 'venice-main-pool' and resource_mode = 'exclusive'
     and schedule_mode in ('fixed','timed') and pricing_mode = 'per_guest') <> 3 then
    raise exception 'FAIL: all three tours must share the exclusive venice-main-pool resource';
  end if;
      if public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc', 20, null) <> 2000
     or public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc', 25, null) <> 2500
     or public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc', 50, null) <> 5000
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b', 20, null) <> 3000
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b', 25, null) <> 3750
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b', 50, null) <> 7500
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8', 20, null) <> 4000
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8', 25, null) <> 5000
     or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8', 50, null) <> 10000
     or public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc', 20,
        '1e97b2bf-ca43-492a-8a15-2d20f6abf040') <> 2700
     or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b', 20,
        '1e97b2bf-ca43-492a-8a15-2d20f6abf040') <> 3700
      or public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8', 20,
       '928c269f-c38a-4345-86a5-d1f4c65555f0') <> 5000 then
    raise exception 'FAIL: per-guest tour rates or optional cottage totals are incorrect';
  end if;
    if public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,null)<>2000
       or public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',20,null)<>3000 then
        raise exception 'FAIL: Day/Night per-guest amount examples do not match their rates';
    end if;
    v_error:=null;
    begin perform public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',19,null);
    exception when raise_exception then v_error:=sqlerrm; end;
    if v_error not ilike '%at least 20%' then raise exception 'FAIL: Day Tour minimum 20 was not enforced'; end if;
    v_error:=null;
    begin perform public.evently_pool_tour_amount('5afda244-a615-4bd3-98eb-d360d000100b',19,null);
    exception when raise_exception then v_error:=sqlerrm; end;
    if v_error not ilike '%at least 20%' then raise exception 'FAIL: Night Tour minimum 20 was not enforced'; end if;
    v_error:=null;
    begin perform public.evently_pool_tour_amount('925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8',19,null);
   exception when raise_exception then v_error:=sqlerrm; end;
   if v_error not ilike '%at least 20%' then raise exception 'FAIL: Overnight minimum 20 was not enforced'; end if;
   begin
      perform public.evently_pool_tour_amount('4ae972a8-6503-4776-90c9-899246cbc4dc',20,
       '928c269f-c38a-4345-86a5-d1f4c65555f0');
  exception when raise_exception then v_wrong_cottage_rejected := sqlerrm ilike '%not configured%';
  end;
  if not v_wrong_cottage_rejected then
    raise exception 'FAIL: wrong-tour cottage compatibility was not enforced';
  end if;
  if not exists (select 1 from public.packages where id = '4ae972a8-6503-4776-90c9-899246cbc4dc'
        and price = 100 and pricing_mode = 'per_guest' and min_guest_count = 20
       and max_guest_count is null and not pool_capacity_verified
       and deposit_percentage = 30 and schedule_mode in ('fixed','timed')
      and coalesce(fixed_start_time, operating_start_time) = time '08:00'
      and coalesce(fixed_end_time, operating_end_time) = time '15:00')
      or not exists (select 1 from public.packages where id = '5afda244-a615-4bd3-98eb-d360d000100b'
          and price = 150 and pricing_mode = 'per_guest' and min_guest_count = 20
         and max_guest_count is null and not pool_capacity_verified
        and deposit_percentage = 30 and schedule_mode in ('fixed','timed')
      and coalesce(fixed_start_time, operating_start_time) = time '16:00'
      and coalesce(fixed_end_time, operating_end_time) = time '22:00')
      or not exists (select 1 from public.packages where id = '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
         and price = 200 and pricing_mode = 'per_guest' and min_guest_count = 20
         and max_guest_count is null and not pool_capacity_verified
        and deposit_percentage = 30 and schedule_mode in ('fixed','timed')
      and coalesce(fixed_start_time, operating_start_time) = time '19:00'
      and coalesce(fixed_end_time, operating_end_time) = time '04:00') then
     raise exception 'FAIL: tour rate/minimum/deposit settings or preserved fixed schedules differ from verified values';
  end if;

  for v_capacity in select id,pool_capacity_verified,max_guest_count,min_guest_count
    from public.packages where id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8')
  loop
    if not v_capacity.pool_capacity_verified then
      v_capacity_rejected:=false;
      begin
        perform public.evently_pool_tour_total(v_capacity.id,v_capacity.min_guest_count,null);
      exception when raise_exception then v_capacity_rejected:=sqlerrm ilike '%capacity%';
      end;
      if not v_capacity_rejected then raise exception 'FAIL: unverified physical capacity did not block package %',v_capacity.id; end if;
    elsif v_capacity.max_guest_count is not null then
      v_capacity_rejected:=false;
      begin
        perform public.evently_pool_tour_total(v_capacity.id,v_capacity.max_guest_count+1,null);
      exception when raise_exception then v_capacity_rejected:=sqlerrm ilike '%verified maximum%';
      end;
      if not v_capacity_rejected then raise exception 'FAIL: verified maximum was not enforced for package %',v_capacity.id; end if;
    end if;
  end loop;

  if has_function_privilege('anon', 'public.evently_admin_override_reservation(uuid,text,text,date,time,time,text,timestamptz)', 'EXECUTE')
     or has_function_privilege('anon', 'public.admin_review_payment(uuid,text,text)', 'EXECUTE') then
    raise exception 'FAIL: anonymous users must not execute payment review or override RPCs';
  end if;
  if has_table_privilege('anon','public.reservations','INSERT')
     or has_table_privilege('authenticated','public.reservations','INSERT')
     or has_table_privilege('authenticated','public.reservations','UPDATE')
      or has_table_privilege('authenticated','public.orders','INSERT')
      or has_table_privilege('authenticated','public.orders','UPDATE')
      or has_table_privilege('authenticated','public.payments','INSERT')
      or has_table_privilege('authenticated','public.payments','UPDATE')
      or has_table_privilege('authenticated','public.packages','INSERT')
      or has_table_privilege('authenticated','public.packages','UPDATE')
      or has_table_privilege('authenticated','public.packages','DELETE') then
    raise exception 'FAIL: lifecycle tables must not allow direct authenticated writes that bypass guarded RPCs';
  end if;
  if has_function_privilege('authenticated', 'public.evently_admin_approve_booking(uuid,boolean)', 'EXECUTE') then
    raise exception 'FAIL: manual schedule approval must not remain an authenticated RPC';
  end if;
  if has_function_privilege('authenticated', 'public.evently_admin_set_reservation_schedule(uuid,time,time,text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.evently_admin_override_reservation(uuid,text,text,date,time,time,text,timestamptz)', 'EXECUTE') then
    raise exception 'FAIL: schedule writes must route through the audited Administrator override RPC';
  end if;

  select lower(pg_get_functiondef('public.create_evently_reservation(jsonb)'::regprocedure)) into v_create_definition;
  select lower(pg_get_functiondef('public.create_evently_reservation_before_exact_resource_assignment(jsonb)'::regprocedure)) into v_delegated_create_definition;
  select lower(pg_get_functiondef('public.admin_review_payment(uuid,text,text)'::regprocedure)) into v_payment_definition;
  select lower(pg_get_functiondef('public.evently_expire_unpaid_reservations()'::regprocedure)) into v_expire_definition;
  select lower(pg_get_functiondef('public.evently_has_timely_pending_payment(uuid)'::regprocedure)) into v_pending_proof_definition;
  select lower(pg_get_functiondef('public.evently_auto_confirm_verified_reservation(uuid)'::regprocedure)) into v_auto_confirm_definition;
  select lower(pg_get_functiondef('public.evently_admin_override_reservation(uuid,text,text,date,time,time,text,timestamptz)'::regprocedure)) into v_override_definition;
  if position('evently-resource-schedule-global' in v_create_definition) = 0
     or position('payment_due_at' in v_create_definition) = 0 then
    raise exception 'FAIL: booking RPC must lock exclusive schedules and calculate the hold deadline server-side';
  end if;
  if position('evently_pool_tour_total' in v_delegated_create_definition) = 0
     or position('reservation_addons' in v_delegated_create_definition) = 0
     or position('cottage_addon_id' in v_delegated_create_definition) = 0 then
    raise exception 'FAIL: delegated create RPC must calculate per-person totals and snapshot cottage charges without duplication';
  end if;
  if position('is_evently_admin' in v_payment_definition) = 0
     or position('submitted_at' in v_payment_definition) = 0
     or position('payment_due_at' in v_payment_definition) = 0
     or position('evently_auto_confirm_verified_reservation' in v_payment_definition) = 0
     or position('confirmed' in v_auto_confirm_definition) = 0
     or position('demo_mode is not true' in v_auto_confirm_definition) = 0
     or position('evently_admin_check_reservation_schedule' in v_auto_confirm_definition) = 0
     or position('evently_reservation_holds_schedule' in v_auto_confirm_definition) = 0 then
    raise exception 'FAIL: payment verification must require Admin and timely proof and auto-confirm sufficient payment';
  end if;
  if position('skip locked' in v_expire_definition) = 0
     or position('evently_has_timely_pending_payment' in v_expire_definition) = 0
     or position('payment_due_at is not null' in v_expire_definition) = 0
     or position('submitted_at' in v_pending_proof_definition) = 0
     or position('storage.objects' in v_pending_proof_definition) = 0 then
    raise exception 'FAIL: expiry processing must be concurrency-safe and retain only timely valid proof reviews';
  end if;
  if position('is_evently_admin' in v_override_definition) = 0
     or position('override reason' in v_override_definition) = 0
     or position('evently-resource-schedule-global' in v_override_definition) = 0
     or position('evently_reservation_override_audit' in v_override_definition) = 0 then
    raise exception 'FAIL: overrides must require Administrator role/reason, serialize schedule changes, and audit old/new values';
  end if;
  if not exists (select 1 from cron.job where jobname = 'evently-expire-unpaid-reservations') then
    raise exception 'FAIL: the recurring server-side expiration job is missing';
  end if;
  if exists (select 1 from public.reservations reservation
    where lower(reservation.status::text) = 'pending' and reservation.payment_due_at is null
      and not public.evently_reservation_holds_schedule(reservation.id)) then
    raise exception 'FAIL: legacy pending reservations without an explicitly started deadline must retain their existing hold';
  end if;
  raise notice 'PASS: payment deadline, pool interval arithmetic, exclusive resource, permissions, expiry, and override contracts';
end;
$$;
