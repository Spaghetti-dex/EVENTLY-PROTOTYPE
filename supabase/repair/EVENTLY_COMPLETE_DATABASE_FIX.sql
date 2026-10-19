-- EVENTLY complete, forward-only repair/synchronization script.
-- Execute manually in Supabase SQL Editor only after the read-only preflight.
-- This script preserves operational records and does not reset auth, recreate
-- catalogs/resources, or replace the established booking/payment RPC chain.
begin;

-- ---------------------------------------------------------------------------
-- 0. Fail-closed compatibility checks. Nothing is mutated before these pass.
-- ---------------------------------------------------------------------------
do $$
declare
  v_missing text[] := array[]::text[];
  v_hold_migration_recorded boolean := false;
  v_hold_chain_ready boolean := false;
  v_review_duplicates integer := 0;
begin
  if to_regclass('public.profiles') is null then v_missing := array_append(v_missing, 'public.profiles'); end if;
  if to_regclass('public.packages') is null then v_missing := array_append(v_missing, 'public.packages'); end if;
  if to_regclass('public.reservations') is null then v_missing := array_append(v_missing, 'public.reservations'); end if;
  if to_regclass('public.reviews') is null then v_missing := array_append(v_missing, 'public.reviews'); end if;
  if to_regclass('public.payments') is null then v_missing := array_append(v_missing, 'public.payments'); end if;
  if to_regclass('public.orders') is null then v_missing := array_append(v_missing, 'public.orders'); end if;
  if to_regclass('public.addons') is null then v_missing := array_append(v_missing, 'public.addons'); end if;
  if to_regclass('public.evently_resources') is null then v_missing := array_append(v_missing, 'public.evently_resources'); end if;
  if to_regclass('public.admin_activity_logs') is null then v_missing := array_append(v_missing, 'public.admin_activity_logs'); end if;
  if to_regclass('public.evently_review_analysis_rate_limits') is null then
    -- The review repair creates this table transactionally below.
    null;
  end if;
  if cardinality(v_missing) > 0 then
    raise exception 'EVENTLY repair stopped before changes. Required existing tables are missing: %', array_to_string(v_missing, ', ');
  end if;

  if to_regclass('storage.objects') is null or to_regclass('storage.buckets') is null then
    raise exception 'EVENTLY repair requires Supabase Storage objects and buckets; no changes were made';
  end if;
  if to_regclass('public.evently_staff_permissions') is null
     or to_regclass('public.evently_staff_permission_policy') is null then
    raise exception 'EVENTLY Staff permission tables are missing; apply/reconcile the existing Staff migrations first';
  end if;

  if exists (
    select required.table_name, required.column_name
    from (values
      ('reviews','id'),('reviews','customer_id'),('reviews','reservation_id'),('reviews','rating'),
      ('reviews','review_text'),('reviews','created_at'),
      ('reservations','id'),('reservations','customer_id'),('reservations','package_id'),('reservations','status'),
      ('reservations','customer_name'),('reservations','customer_email'),('reservations','customer_phone'),
      ('reservations','reservation_code'),('reservations','package_name'),('reservations','package_variant'),
      ('reservations','reservation_date'),('reservations','start_time'),('reservations','end_time'),
      ('reservations','resource_name'),('reservations','special_requests'),
      ('profiles','id'),('profiles','role'),('profiles','full_name'),('profiles','username'),
      ('profiles','email'),('profiles','mobile_number'),
      ('packages','id'),('packages','service_type'),
      ('packages','price'),('packages','min_guest_count'),('packages','guest_capacity'),
      ('packages','deposit_percentage'),('packages','cottage_fee'),('packages','cottage_addon_id'),
      ('packages','resource_key'),('packages','resource_mode'),('packages','schedule_mode'),
      ('packages','fixed_start_time'),('packages','operating_start_time'),
      ('packages','fixed_end_time'),('packages','operating_end_time'),
      ('payments','id'),('orders','id'),('addons','id')
    ) required(table_name,column_name)
    left join information_schema.columns actual
      on actual.table_schema='public' and actual.table_name=required.table_name
      and actual.column_name=required.column_name
    where actual.column_name is null
  ) then
    raise exception 'EVENTLY repair stopped: required live schema columns for reviews/privacy projection are missing; run the preflight and reconcile schema first';
  end if;

  -- Require the canonical 24-hour schedule-hold chain, if the project tracks
  -- migration versions. If the ledger is absent, verify its actual signatures
  -- below rather than assuming a file on disk was deployed.
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute 'select exists (select 1 from supabase_migrations.schema_migrations where version::text = $1)'
      into v_hold_migration_recorded using '20261017110000';
  end if;

  v_hold_chain_ready :=
    to_regprocedure('public.evently_payment_deadline(timestamptz)') is not null
    and to_regprocedure('public.evently_expire_unpaid_reservations()') is not null
    and to_regprocedure('public.evently_reservation_holds_schedule(uuid)') is not null
    and to_regprocedure('public.evently_has_timely_pending_payment(uuid)') is not null
    and to_regprocedure('public.evently_auto_confirm_verified_reservation(uuid)') is not null
    and to_regprocedure('public.evently_admin_override_reservation(uuid,text,text,date,time,time,text,timestamptz)') is not null
    and to_regprocedure('public.evently_submit_payment_proof(uuid,numeric,text,text,text)') is not null
    and to_regprocedure('public.evently_check_availability(uuid,date)') is not null
    and to_regprocedure('public.create_evently_reservation(jsonb)') is not null
    and to_regprocedure('public.admin_review_payment(uuid,text,text)') is not null
    and to_regprocedure('public.admin_transition_reservation(uuid,text,text)') is not null;
  if not v_hold_chain_ready then
    raise exception 'EVENTLY repair stopped: the prepared schedule-hold/payment workflow is absent or incomplete. Review the preflight and apply/reconcile the existing schedule-hold migration before this script.';
  end if;
  if v_hold_migration_recorded is false and to_regclass('supabase_migrations.schema_migrations') is not null then
    raise exception 'EVENTLY repair stopped: migration 20261017110000 is not recorded. Verify that the live RPC chain matches the prepared schedule-hold migration before applying this repair.';
  end if;

  if to_regprocedure('public.evently_staff_role_ready()') is null
     or to_regprocedure('public.evently_staff_permissions_ready()') is null
     or to_regprocedure('public.evently_current_profile_role()') is null
     or to_regprocedure('public.evently_staff_list_reservations()') is null
     or to_regprocedure('public.evently_staff_list_orders()') is null
     or to_regprocedure('public.evently_staff_dashboard_stats()') is null then
    raise exception 'EVENTLY repair stopped: required existing Staff/Admin role or dashboard RPCs are missing';
  end if;
  if public.evently_staff_role_ready() is distinct from true
     or public.evently_staff_permissions_ready() is distinct from true then
    raise exception 'EVENTLY repair stopped: Staff role/permission readiness checks are false';
  end if;

  if not exists (select 1 from public.evently_resources
    where resource_key = 'venice-main-pool' and is_active and is_exclusive) then
    raise exception 'EVENTLY repair stopped: the existing active exclusive venice-main-pool resource is missing';
  end if;
  if (select count(*) from public.packages where id in (
      '4ae972a8-6503-4776-90c9-899246cbc4dc',
      '5afda244-a615-4bd3-98eb-d360d000100b',
      '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
    ) and is_active and resource_key = 'venice-main-pool' and resource_mode = 'exclusive'
       and schedule_mode in ('fixed','timed') and pricing_mode = 'per_guest' and deposit_percentage = 30
      and ((id='4ae972a8-6503-4776-90c9-899246cbc4dc' and price=100 and min_guest_count=1
            and cottage_fee=700 and cottage_addon_id='1e97b2bf-ca43-492a-8a15-2d20f6abf040'
            and coalesce(fixed_start_time,operating_start_time)=time '08:00'
            and coalesce(fixed_end_time,operating_end_time)=time '15:00')
        or (id='5afda244-a615-4bd3-98eb-d360d000100b' and price=150 and min_guest_count=1
            and cottage_fee=700 and cottage_addon_id='1e97b2bf-ca43-492a-8a15-2d20f6abf040'
            and coalesce(fixed_start_time,operating_start_time)=time '16:00'
            and coalesce(fixed_end_time,operating_end_time)=time '22:00')
        or (id='925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8' and price=200 and min_guest_count=20
            and cottage_fee=1000 and cottage_addon_id='928c269f-c38a-4345-86a5-d1f4c65555f0'
            and coalesce(fixed_start_time,operating_start_time)=time '19:00'
            and coalesce(fixed_end_time,operating_end_time)=time '04:00'))) <> 3 then
    raise exception 'EVENTLY repair stopped: the existing three pool packages do not match their verified resource, fixed schedule, per-person, and 30%% deposit settings';
  end if;
  if not exists (select 1 from public.packages where id = '4ae972a8-6503-4776-90c9-899246cbc4dc'
      and price = 100 and min_guest_count = 1 and cottage_fee = 700)
    or not exists (select 1 from public.packages where id = '5afda244-a615-4bd3-98eb-d360d000100b'
      and price = 150 and min_guest_count = 1 and cottage_fee = 700)
    or not exists (select 1 from public.packages where id = '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
      and price = 200 and min_guest_count = 20 and cottage_fee = 1000) then
    raise exception 'EVENTLY repair stopped: verified Day/Night/Overnight rates, minimums, or cottage prices differ; no catalog rows were changed';
  end if;
  if not exists (select 1 from public.addons where id = '1e97b2bf-ca43-492a-8a15-2d20f6abf040' and is_active and price = 700)
    or not exists (select 1 from public.addons where id = '928c269f-c38a-4345-86a5-d1f4c65555f0' and is_active and price = 1000) then
    raise exception 'EVENTLY repair stopped: existing cottage add-ons do not match the verified catalog';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema = 'public'
       and table_name = 'reservations' and column_name = 'payment_due_at' and data_type = 'timestamp with time zone')
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
       and table_name = 'reservations' and column_name = 'expired_at') then
    raise exception 'EVENTLY repair stopped: payment_due_at/expired_at is missing; apply/reconcile the prepared schedule-hold migration first';
  end if;
  if not exists (select 1 from pg_catalog.pg_class where oid = 'public.reservations'::regclass and relrowsecurity)
     or not exists (select 1 from pg_catalog.pg_class where oid = 'public.payments'::regclass and relrowsecurity)
     or not exists (select 1 from pg_catalog.pg_class where oid = 'public.reviews'::regclass and relrowsecurity) then
    raise exception 'EVENTLY repair stopped: RLS is not enabled on a core customer-data table';
  end if;
  if has_table_privilege('anon','public.reservations','select')
     or has_table_privilege('anon','public.payments','select')
     or has_table_privilege('anon','public.profiles','select')
     or has_column_privilege('anon','public.reservations','customer_id','select')
     or has_column_privilege('anon','public.payments','customer_id','select')
     or has_column_privilege('anon','public.profiles','email','select') then
    raise exception 'EVENTLY repair stopped: anonymous access to private reservation/payment/profile data must be reviewed before repair';
  end if;
  if has_function_privilege('authenticated','public.evently_admin_approve_booking(uuid,boolean)','EXECUTE') then
    raise exception 'EVENTLY repair stopped: legacy direct booking approval remains executable; reconcile schedule-hold permissions first';
  end if;

  select count(*) into v_review_duplicates
  from (select reservation_id from public.reviews group by reservation_id having count(*) > 1) duplicates;
  if v_review_duplicates > 0 then
    raise exception 'EVENTLY repair stopped: % reservation(s) already have duplicate reviews. Existing rows were preserved; reconcile those records explicitly before adding the one-review unique constraint.', v_review_duplicates;
  end if;
end;
$$;

-- Catalog/lifecycle writes must use existing SECURITY DEFINER/RLS-checked RPCs.
-- Keep SELECT/RLS policies, but remove browser-role direct write grants so
-- customer/admin direct DML cannot bypass catalog, price, deadline, or audit paths.
do $$
declare v_table text; v_columns text;
begin
  foreach v_table in array array['packages','reservations','orders','payments'] loop
    if to_regclass('public.'||v_table) is null then raise exception 'Required lifecycle table public.% is missing',v_table; end if;
    execute pg_catalog.format('revoke insert, update, delete on table public.%I from public, anon, authenticated',v_table);
    select string_agg(pg_catalog.quote_ident(a.attname),', ' order by a.attnum) into v_columns
    from pg_catalog.pg_attribute a where a.attrelid=to_regclass('public.'||v_table) and a.attnum>0 and not a.attisdropped;
    if v_columns is not null then
      execute pg_catalog.format('revoke insert (%s) on table public.%I from public, anon, authenticated',v_columns,v_table);
      execute pg_catalog.format('revoke update (%s) on table public.%I from public, anon, authenticated',v_columns,v_table);
    end if;
  end loop;
  if has_table_privilege('anon','public.reservations','INSERT')
    or has_table_privilege('authenticated','public.reservations','INSERT')
    or has_table_privilege('anon','public.orders','INSERT')
    or has_table_privilege('authenticated','public.orders','INSERT')
    or has_table_privilege('anon','public.payments','UPDATE')
     or has_table_privilege('authenticated','public.payments','UPDATE')
     or has_table_privilege('authenticated','public.packages','INSERT')
     or has_table_privilege('authenticated','public.packages','UPDATE')
     or has_table_privilege('authenticated','public.packages','DELETE') then
    raise exception 'Direct lifecycle write grants remain after revocation';
  end if;
  if exists(select 1 from information_schema.column_privileges
    where table_schema='public' and table_name in ('packages','reservations','orders','payments')
      and grantee in ('PUBLIC','anon','authenticated') and privilege_type in ('INSERT','UPDATE')) then
    raise exception 'Direct lifecycle column-level write grants remain after revocation';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. Add review-specific schema only; do not alter existing review content,
--    rating, reservation identity, pool catalog, or booking/payment RPC logic.
-- ---------------------------------------------------------------------------
alter table public.reviews
  add column if not exists sentiment_model_version text,
  add column if not exists sentiment_status text not null default 'pending',
  add column if not exists public_review_text text,
  add column if not exists service_category text,
  add column if not exists sentiment_confidence numeric(6,5),
  add column if not exists sentiment_analyzed_at timestamptz,
  add column if not exists sentiment_label text,
  add column if not exists moderation_status text not null default 'pending',
  add column if not exists moderation_reason text,
  add column if not exists is_published boolean not null default false,
  add column if not exists updated_at timestamptz not null default now();
alter table public.reviews alter column review_text drop not null;

create table if not exists public.evently_review_analysis_rate_limits (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  request_count integer not null default 0
);
alter table public.evently_review_analysis_rate_limits enable row level security;
revoke all on public.evently_review_analysis_rate_limits from public, anon, authenticated;

-- Customer Catering change requests are separate from reservation state. The
-- reviewed reservation RPC remains the only code path that applies a request.
create table if not exists public.evently_catering_change_requests (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete restrict,
  customer_id uuid not null references public.profiles(id) on delete restrict,
  request_action text not null check (request_action in ('cancel','reschedule')),
  reason text not null,
  original_reservation_date date not null,
  original_start_time time not null,
  original_end_time time not null,
  proposed_reservation_date date,
  proposed_start_time time,
  proposed_end_time time,
  request_status text not null default 'pending'
    check (request_status in ('pending','approved','rejected')),
  decision_note text,
  requested_at timestamptz not null default now(),
  decided_by uuid references public.profiles(id),
  decided_at timestamptz,
  applied_at timestamptz
);
create unique index if not exists evently_one_pending_catering_request_per_reservation
  on public.evently_catering_change_requests(reservation_id) where request_status='pending';
create index if not exists evently_catering_requests_reservation_created_idx
  on public.evently_catering_change_requests(reservation_id,requested_at desc);
alter table public.evently_catering_change_requests enable row level security;
revoke all on public.evently_catering_change_requests from public,anon,authenticated;
grant select on public.evently_catering_change_requests to authenticated;
drop policy if exists "Customer or Administrator reads Catering change requests" on public.evently_catering_change_requests;
create policy "Customer or Administrator reads Catering change requests"
  on public.evently_catering_change_requests for select to authenticated
  using (customer_id=auth.uid() or public.is_evently_admin());

create or replace function public.evently_customer_request_catering_change(
  p_reservation_id uuid,p_action text,p_reason text,
  p_proposed_reservation_date date default null,
  p_proposed_start_time time default null,
  p_proposed_end_time time default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_customer_id uuid:=auth.uid(); v_reservation public.reservations%rowtype;
  v_service_type text; v_event_start timestamptz; v_request_id uuid;
  v_action text:=lower(btrim(coalesce(p_action,'')));
begin
  if v_customer_id is null or not exists(select 1 from public.profiles where id=v_customer_id and role='customer') then
    raise exception 'Only the signed-in customer who owns this booking may request a change';
  end if;
  if v_action not in ('cancel','reschedule') then raise exception 'Choose cancellation or rescheduling'; end if;
  if nullif(btrim(p_reason),'') is null or length(btrim(p_reason))>2000 then
    raise exception 'A reason of 1 to 2000 characters is required';
  end if;
  select * into v_reservation from public.reservations
    where id=p_reservation_id and customer_id=v_customer_id for share;
  if not found then raise exception 'Reservation not found for this customer'; end if;
  select lower(coalesce(package.service_type::text,'')) into v_service_type
  from public.packages package where package.id=v_reservation.package_id;
  if coalesce(v_service_type,'') not like '%cater%' then
    raise exception 'This cancellation/rescheduling request path is only for Catering bookings';
  end if;
  if lower(v_reservation.status::text) not in ('pending','confirmed') or v_reservation.expired_at is not null then
    raise exception 'Only active Catering reservations may be changed';
  end if;
  if v_reservation.reservation_date is null or v_reservation.start_time is null or v_reservation.end_time is null then
    raise exception 'The scheduled Catering event date and time must be assigned before a change request';
  end if;
  v_event_start := (v_reservation.reservation_date + v_reservation.start_time) at time zone 'Asia/Manila';
  -- Strictly later than the boundary is rejected; equality at exactly 72 hours
  -- remains eligible.
  if clock_timestamp() > v_event_start - interval '72 hours' then
    raise exception 'Catering cancellation or rescheduling must be requested at least 72 hours before the event';
  end if;
  if v_action='reschedule' then
    if p_proposed_reservation_date is null or p_proposed_start_time is null or p_proposed_end_time is null
       or p_proposed_start_time=p_proposed_end_time then
      raise exception 'A proposed date and distinct start/end times are required';
    end if;
    if ((p_proposed_reservation_date+p_proposed_start_time) at time zone 'Asia/Manila') <= clock_timestamp() then
      raise exception 'The proposed event time must be in the future';
    end if;
  elsif p_proposed_reservation_date is not null or p_proposed_start_time is not null or p_proposed_end_time is not null then
    raise exception 'Do not include a proposed schedule with a cancellation request';
  end if;
  insert into public.evently_catering_change_requests(
    reservation_id,customer_id,request_action,reason,original_reservation_date,
    original_start_time,original_end_time,proposed_reservation_date,
    proposed_start_time,proposed_end_time
  ) values (
    p_reservation_id,v_customer_id,v_action,btrim(p_reason),v_reservation.reservation_date,
    v_reservation.start_time,v_reservation.end_time,p_proposed_reservation_date,
    p_proposed_start_time,p_proposed_end_time
  ) returning id into v_request_id;
  return v_request_id;
exception when unique_violation then
  raise exception 'A Catering change request is already awaiting Administrator review';
end;
$$;

create or replace function public.evently_guard_catering_change_request()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_service_type text; v_request public.evently_catering_change_requests%rowtype;
  v_is_cancellation boolean; v_is_schedule_change boolean;
begin
  v_is_cancellation := lower(new.status::text) in ('cancelled','canceled')
    and lower(old.status::text) not in ('cancelled','canceled');
  v_is_schedule_change := new.reservation_date is distinct from old.reservation_date
    or new.start_time is distinct from old.start_time or new.end_time is distinct from old.end_time;
  if not v_is_cancellation and not v_is_schedule_change then return new; end if;
  -- Keep the existing automatic 24-hour expiry workflow independent of a
  -- customer-requested cancellation policy.
  if new.expired_at is not null and old.expired_at is null then return new; end if;
  -- Administrator booking rejection is not a customer-initiated cancellation.
  -- Customers cannot write reservation status directly, and confirmed-booking
  -- cancellations still require a matching approved request below.
  if v_is_cancellation and lower(old.status::text)='pending' then return new; end if;
  select lower(coalesce(package.service_type::text,'')) into v_service_type
  from public.packages package where package.id=old.package_id;
  if coalesce(v_service_type,'') not like '%cater%' then return new; end if;
  select * into v_request from public.evently_catering_change_requests request_row
  where request_row.reservation_id=old.id and request_row.request_status='approved'
    and request_row.applied_at is null
    and request_row.original_reservation_date=old.reservation_date
    and request_row.original_start_time=old.start_time
    and request_row.original_end_time=old.end_time
    and request_row.requested_at <= ((old.reservation_date+old.start_time) at time zone 'Asia/Manila') - interval '72 hours'
    and ((v_is_cancellation and request_row.request_action='cancel')
      or (v_is_schedule_change and request_row.request_action='reschedule'))
  order by request_row.requested_at desc limit 1 for update;
  if not found then
    raise exception 'Catering cancellation or schedule changes require a timely customer request and Administrator approval';
  end if;
  update public.evently_catering_change_requests set applied_at=now() where id=v_request.id;
  return new;
end;
$$;
drop trigger if exists evently_guard_catering_change_request on public.reservations;
create trigger evently_guard_catering_change_request
  before update of status,reservation_date,start_time,end_time on public.reservations
  for each row execute function public.evently_guard_catering_change_request();

create or replace function public.evently_admin_decide_catering_change(
  p_request_id uuid,p_decision text,p_decision_note text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_request public.evently_catering_change_requests%rowtype; v_result jsonb; v_resource_key text;
begin
  if not public.is_evently_admin() then raise exception 'Administrator access required'; end if;
  if lower(coalesce(p_decision,'')) not in ('approved','rejected') then raise exception 'Choose approve or reject'; end if;
  if nullif(btrim(p_decision_note),'') is null then raise exception 'An Administrator decision note is required'; end if;
  select * into v_request from public.evently_catering_change_requests where id=p_request_id for update;
  if not found or v_request.request_status<>'pending' then raise exception 'Request is no longer pending'; end if;
  select resource_key into v_resource_key from public.reservations where id=v_request.reservation_id;
  if p_decision='rejected' then
    update public.evently_catering_change_requests set request_status='rejected',
      decision_note=btrim(p_decision_note),decided_by=auth.uid(),decided_at=now() where id=v_request.id;
  else
    if v_request.request_action='reschedule'
       and ((v_request.proposed_reservation_date+v_request.proposed_start_time) at time zone 'Asia/Manila')<=clock_timestamp() then
      raise exception 'The proposed Catering schedule has passed; ask the customer for a new future schedule';
    end if;
    update public.evently_catering_change_requests set request_status='approved',
      decision_note=btrim(p_decision_note),decided_by=auth.uid(),decided_at=now() where id=v_request.id;
    if v_request.request_action='cancel' then
      v_result:=public.evently_admin_override_reservation(v_request.reservation_id,'cancel',btrim(p_decision_note));
    else
      v_result:=public.evently_admin_override_reservation(
        p_reservation_id=>v_request.reservation_id,
        p_action=>'reschedule',p_reason=>btrim(p_decision_note),
        p_reservation_date=>v_request.proposed_reservation_date,
        p_start_time=>v_request.proposed_start_time,p_end_time=>v_request.proposed_end_time,
        p_resource_key=>v_resource_key,p_payment_due_at=>null
      );
    end if;
    update public.evently_catering_change_requests set applied_at=coalesce(applied_at,now()) where id=v_request.id;
  end if;
  insert into public.admin_activity_logs(admin_id,action,entity_type,entity_id,description)
  values(auth.uid(),'catering_change_request_'||p_decision,'reservation',v_request.reservation_id,
    btrim(p_decision_note));
  insert into public.notifications(user_id,title,message,type,entity_type,entity_id,dedupe_key)
  values(v_request.customer_id,
    case when p_decision='approved' then 'Catering change request approved' else 'Catering change request declined' end,
    case when p_decision='approved' then 'An Administrator approved your timely Catering request.'
      else 'An Administrator declined your Catering request. '||btrim(p_decision_note) end,
    'reservation_status','reservation',v_request.reservation_id,
    'catering-change-request:'||v_request.id||':'||p_decision)
  on conflict(dedupe_key) where dedupe_key is not null do nothing;
  return jsonb_build_object('request_id',v_request.id,'decision',p_decision,'reservation_result',v_result);
end;
$$;

revoke all on function public.evently_customer_request_catering_change(uuid,text,text,date,time,time) from public,anon;
grant execute on function public.evently_customer_request_catering_change(uuid,text,text,date,time,time) to authenticated;
revoke all on function public.evently_admin_decide_catering_change(uuid,text,text) from public,anon;
grant execute on function public.evently_admin_decide_catering_change(uuid,text,text) to authenticated;
revoke all on function public.evently_guard_catering_change_request() from public,anon,authenticated;

update public.reviews
set sentiment_status = case
      when nullif(btrim(review_text),'') is null then 'unavailable'
      when sentiment_label in ('positive','neutral','negative') then 'complete'
      when sentiment_status = 'failed' then 'failed'
      else 'pending'
    end;
do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint
    where conrelid='public.reviews'::regclass and conname='evently_reviews_sentiment_status_check') then
    alter table public.reviews add constraint evently_reviews_sentiment_status_check
      check (sentiment_status in ('pending','complete','unavailable','failed')) not valid;
  end if;
end;
$$;
alter table public.reviews validate constraint evently_reviews_sentiment_status_check;
do $$
begin
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.reviews'::regclass and conname='evently_reviews_rating_check') then
    alter table public.reviews add constraint evently_reviews_rating_check check(rating between 1 and 5) not valid;
  end if;
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.reviews'::regclass and conname='evently_reviews_moderation_check') then
    alter table public.reviews add constraint evently_reviews_moderation_check
      check(moderation_status in ('pending','approved','rejected','flagged')) not valid;
  end if;
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.reviews'::regclass and conname='evently_reviews_sentiment_check') then
    alter table public.reviews add constraint evently_reviews_sentiment_check
      check(sentiment_label is null or sentiment_label in ('positive','neutral','negative')) not valid;
  end if;
end;
$$;
alter table public.reviews validate constraint evently_reviews_rating_check;
alter table public.reviews validate constraint evently_reviews_moderation_check;
alter table public.reviews validate constraint evently_reviews_sentiment_check;

-- Resolve and snapshot service category using the valid reservation->package
-- relationship. No reviews.package_id column is added, read, or required.
update public.reviews review
set service_category = case
  when lower(coalesce(package.service_type::text,'')) like '%cater%' then 'Catering'
  when lower(coalesce(package.service_type::text,'')) like '%pool%'
    or lower(coalesce(package.service_type::text,'')) like '%resort%'
    or lower(coalesce(package.service_type::text,'')) like '%room%'
    or lower(coalesce(package.service_type::text,'')) like '%stay%'
    or lower(coalesce(package.service_type::text,'')) like '%accommodation%' then 'Staycation'
  when lower(coalesce(package.service_type::text,'')) like '%event%'
    or lower(coalesce(package.service_type::text,'')) like '%venue%' then 'Events Place'
  else 'Venice experience'
end
from public.reservations reservation
left join public.packages package on package.id = reservation.package_id
where reservation.id = review.reservation_id
  and (review.service_category is null or btrim(review.service_category)='');
update public.reviews set service_category='Venice experience'
where service_category is null or btrim(service_category)='';

-- ---------------------------------------------------------------------------
-- 2. Moderation, privacy projection, ownership, and one-review enforcement.
-- ---------------------------------------------------------------------------
create or replace function public.evently_review_text_has_profanity(p_text text)
returns boolean language sql immutable set search_path = '' as $$
  with normalized as (
    select regexp_replace(translate(lower(coalesce(p_text,'')), '013457@!$', 'oieastais'), '[^a-z]+', ' ', 'g') as body
  )
  select body ~ '(^| )(fuck|fucking|shit|bullshit|bitch|bastard|asshole|cunt|putangina|putang ina|gago|tanga|bobo|pakyu|puki)( |$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])f[^[:alpha:]]*u[^[:alpha:]]*c[^[:alpha:]]*k([^[:alpha:]]|$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])s[^[:alpha:]]*h[^[:alpha:]]*i[^[:alpha:]]*t([^[:alpha:]]|$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])g[^[:alpha:]]*a[^[:alpha:]]*g[^[:alpha:]]*o([^[:alpha:]]|$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])t[^[:alpha:]]*a[^[:alpha:]]*n[^[:alpha:]]*g[^[:alpha:]]*a([^[:alpha:]]|$)'
  from normalized;
$$;

create or replace function public.evently_review_text_needs_moderation(p_text text)
returns boolean language sql immutable set search_path = '' as $$
  select lower(coalesce(p_text,'')) ~* '(kill[[:space:]]+you|you[[:space:]]+should[[:space:]]+die|go[[:space:]]+die|threaten(ed|ing)?|racial[[:space:]]+slur|homophobic[[:space:]]+slur)'
    or coalesce(p_text,'') ~* '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'
    or coalesce(p_text,'') ~* '\+?[[:digit:]][[:digit:] ()-]{7,}[[:digit:]]'
    or coalesce(p_text,'') ~* '(https?://|www\.)'
    or lower(coalesce(p_text,'')) ~* '(^|[[:space:]])(buy now|click here|limited offer|earn money fast)([[:space:]]|$)'
    or lower(coalesce(p_text,'')) ~* '(^|[[:space:]])([[:alnum:]_]+)([[:space:]]+\2){3,}([[:space:]]|$)';
$$;

create or replace function public.evently_safe_public_review_text(
  p_customer_id uuid, p_reservation_id uuid, p_review_text text
) returns text language plpgsql stable security definer set search_path = '' as $$
declare v_private record; v_text text := nullif(btrim(coalesce(p_review_text,'')), '');
begin
  if v_text is null then return null; end if;
  select profile.full_name, profile.username, profile.email, profile.mobile_number,
         reservation.customer_name, reservation.customer_email, reservation.customer_phone,
         reservation.reservation_code, reservation.package_name, reservation.package_variant,
         reservation.reservation_date, reservation.start_time, reservation.end_time,
         reservation.resource_name, reservation.special_requests
    into v_private
  from public.reservations reservation
  left join public.profiles profile on profile.id = p_customer_id
  where reservation.id = p_reservation_id and reservation.customer_id = p_customer_id;
  if not found then return '[Customer feedback withheld to protect private booking details]'; end if;
  if (nullif(v_private.full_name,'') is not null and position(lower(v_private.full_name) in lower(v_text)) > 0)
    or (nullif(v_private.username,'') is not null and position(lower(v_private.username) in lower(v_text)) > 0)
    or (nullif(v_private.email,'') is not null and position(lower(v_private.email) in lower(v_text)) > 0)
    or (nullif(v_private.mobile_number,'') is not null and position(lower(v_private.mobile_number) in lower(v_text)) > 0)
    or (nullif(v_private.customer_name,'') is not null and position(lower(v_private.customer_name) in lower(v_text)) > 0)
    or (nullif(v_private.customer_email,'') is not null and position(lower(v_private.customer_email) in lower(v_text)) > 0)
    or (nullif(v_private.customer_phone,'') is not null and position(lower(v_private.customer_phone) in lower(v_text)) > 0)
    or (nullif(v_private.reservation_code,'') is not null and position(lower(v_private.reservation_code) in lower(v_text)) > 0)
    or (nullif(v_private.package_name,'') is not null and position(lower(v_private.package_name) in lower(v_text)) > 0)
    or (nullif(v_private.package_variant,'') is not null and position(lower(v_private.package_variant) in lower(v_text)) > 0)
    or (nullif(v_private.reservation_date::text,'') is not null and position(lower(v_private.reservation_date::text) in lower(v_text)) > 0)
    or (nullif(v_private.start_time::text,'') is not null and position(lower(v_private.start_time::text) in lower(v_text)) > 0)
    or (nullif(v_private.end_time::text,'') is not null and position(lower(v_private.end_time::text) in lower(v_text)) > 0)
    or (nullif(v_private.resource_name,'') is not null and position(lower(v_private.resource_name) in lower(v_text)) > 0)
    or (nullif(v_private.special_requests,'') is not null and position(lower(v_private.special_requests) in lower(v_text)) > 0)
  then return '[Customer feedback withheld to protect private booking details]'; end if;
  v_text := regexp_replace(v_text, '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}', '[redacted email]', 'gi');
  v_text := regexp_replace(v_text, '\+?[[:digit:]][[:digit:] ()-]{7,}[[:digit:]]', '[redacted phone]', 'g');
  v_text := regexp_replace(v_text, '(https?://|www\.)[^[:space:]]+', '[redacted link]', 'gi');
  v_text := regexp_replace(v_text, '[[:xdigit:]]{8}-[[:xdigit:]]{4}-[1-5][[:xdigit:]]{3}-[89abAB][[:xdigit:]]{3}-[[:xdigit:]]{12}', '[redacted ID]', 'g');
  return v_text;
end;
$$;

create or replace function public.evently_guard_one_review_per_reservation()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.reservation_id::text, 0));
  if exists (select 1 from public.reviews existing
    where existing.reservation_id=new.reservation_id and existing.id<>new.id) then
    raise exception 'A review already exists for this booking';
  end if;
  return new;
end;
$$;
create unique index if not exists evently_reviews_one_per_reservation_uidx on public.reviews(reservation_id);
drop trigger if exists evently_one_review_per_reservation on public.reviews;
create trigger evently_one_review_per_reservation
  before insert or update of reservation_id on public.reviews
  for each row execute function public.evently_guard_one_review_per_reservation();

create or replace function public.evently_submit_customer_review(
  p_reservation_id uuid,p_rating integer,p_review_text text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_customer_id uuid:=auth.uid(); v_review_id uuid; v_category text;
  v_text text:=nullif(btrim(coalesce(p_review_text,'')), '');
  v_public_text text; v_flagged boolean;
begin
  if v_customer_id is null then raise exception 'Sign in to submit a review'; end if;
  if not exists(select 1 from public.profiles where id=v_customer_id and role='customer') then
    raise exception 'Only customer accounts may submit a review';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Choose a rating from 1 to 5 stars'; end if;
  if length(coalesce(v_text,''))>3000 then raise exception 'Review must be 3000 characters or fewer'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_reservation_id::text,0));
  select case
    when lower(coalesce(package.service_type::text,'')) like '%cater%' then 'Catering'
    when lower(coalesce(package.service_type::text,'')) like '%pool%' or lower(coalesce(package.service_type::text,'')) like '%resort%'
      or lower(coalesce(package.service_type::text,'')) like '%room%' or lower(coalesce(package.service_type::text,'')) like '%stay%'
      or lower(coalesce(package.service_type::text,'')) like '%accommodation%' then 'Staycation'
    when lower(coalesce(package.service_type::text,'')) like '%event%' or lower(coalesce(package.service_type::text,'')) like '%venue%' then 'Events Place'
    else 'Venice experience' end into v_category
  from public.reservations reservation
  left join public.packages package on package.id=reservation.package_id
  where reservation.id=p_reservation_id and reservation.customer_id=v_customer_id
    and lower(reservation.status::text)='completed'
  for share of reservation;
  if not found then raise exception 'Only the customer who completed this booking may review it'; end if;
  if v_text is not null and public.evently_review_text_has_profanity(v_text) then
    raise exception 'Please edit profanity or abusive wording before submitting'; end if;
  v_public_text:=public.evently_safe_public_review_text(v_customer_id,p_reservation_id,v_text);
  v_flagged:=v_text is not null and (public.evently_review_text_needs_moderation(v_text)
    or v_public_text like '[Customer feedback withheld%');
  insert into public.reviews(
    customer_id,reservation_id,rating,review_text,public_review_text,service_category,
    is_published,moderation_status,moderation_reason,sentiment_label,sentiment_confidence,
    sentiment_analyzed_at,sentiment_model_version,sentiment_status,created_at,updated_at
  ) values (
    v_customer_id,p_reservation_id,p_rating,v_text,v_public_text,v_category,not v_flagged,
    case when v_flagged then 'flagged' else 'approved' end,
    case when v_flagged then 'Automated review screen flagged content for Administrator review' else null end,
    null,null,null,null,case when v_text is null then 'unavailable' else 'pending' end,now(),now()
  ) returning id into v_review_id;
  return v_review_id;
exception when unique_violation then raise exception 'A review already exists for this booking';
end;
$$;

create or replace function public.evently_update_customer_review(
  p_review_id uuid,p_rating integer,p_review_text text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_customer_id uuid:=auth.uid(); v_reservation_id uuid; v_category text;
  v_text text:=nullif(btrim(coalesce(p_review_text,'')), '');
  v_public_text text; v_flagged boolean;
begin
  if v_customer_id is null or not exists(select 1 from public.profiles where id=v_customer_id and role='customer') then
    raise exception 'Only signed-in customers may update a review';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Choose a rating from 1 to 5 stars'; end if;
  if length(coalesce(v_text,''))>3000 then raise exception 'Review must be 3000 characters or fewer'; end if;
  select reservation_id into v_reservation_id from public.reviews
    where id=p_review_id and customer_id=v_customer_id for update;
  if not found then raise exception 'Review not found for this customer'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_reservation_id::text,0));
  select case
    when lower(coalesce(package.service_type::text,'')) like '%cater%' then 'Catering'
    when lower(coalesce(package.service_type::text,'')) like '%pool%' or lower(coalesce(package.service_type::text,'')) like '%resort%'
      or lower(coalesce(package.service_type::text,'')) like '%room%' or lower(coalesce(package.service_type::text,'')) like '%stay%'
      or lower(coalesce(package.service_type::text,'')) like '%accommodation%' then 'Staycation'
    when lower(coalesce(package.service_type::text,'')) like '%event%' or lower(coalesce(package.service_type::text,'')) like '%venue%' then 'Events Place'
    else 'Venice experience' end into v_category
  from public.reservations reservation
  left join public.packages package on package.id=reservation.package_id
  where reservation.id=v_reservation_id and reservation.customer_id=v_customer_id
    and lower(reservation.status::text)='completed'
  for share of reservation;
  if not found then raise exception 'Only the customer who completed this booking may update its review'; end if;
  if v_text is not null and public.evently_review_text_has_profanity(v_text) then
    raise exception 'Please edit profanity or abusive wording before submitting'; end if;
  v_public_text:=public.evently_safe_public_review_text(v_customer_id,v_reservation_id,v_text);
  v_flagged:=v_text is not null and (public.evently_review_text_needs_moderation(v_text)
    or v_public_text like '[Customer feedback withheld%');
  update public.reviews set rating=p_rating,review_text=v_text,public_review_text=v_public_text,
    service_category=v_category,is_published=not v_flagged,
    moderation_status=case when v_flagged then 'flagged' else 'approved' end,
    moderation_reason=case when v_flagged then 'Automated review screen flagged edited content for Administrator review' else null end,
    sentiment_label=null,sentiment_confidence=null,sentiment_analyzed_at=null,sentiment_model_version=null,
    sentiment_status=case when v_text is null then 'unavailable' else 'pending' end,updated_at=now()
  where id=p_review_id and customer_id=v_customer_id;
  return p_review_id;
end;
$$;

create or replace function public.evently_admin_moderate_review(
  p_review_id uuid,p_decision text,p_reason text default null
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_evently_admin()
    and not (p_decision='flagged' and public.evently_staff_has_permission('moderate_reviews')) then
    raise exception 'Review moderation access required';
  end if;
  if not public.is_evently_admin() and p_decision<>'flagged' then
    raise exception 'Staff may only flag reviews for Administrator oversight';
  end if;
  if p_decision not in ('approved','rejected','flagged') then raise exception 'Invalid moderation decision'; end if;
  if p_decision<>'approved' and nullif(btrim(p_reason),'') is null then raise exception 'A moderation reason is required'; end if;
  update public.reviews set moderation_status=p_decision,
    is_published=case when public.is_evently_admin() then p_decision='approved' else is_published end,
    moderation_reason=nullif(btrim(p_reason),''),updated_at=now()
  where id=p_review_id;
  if not found then raise exception 'Review not found'; end if;
  insert into public.admin_activity_logs(admin_id,action,entity_type,entity_id,description)
  values(auth.uid(),'review_'||p_decision,'review',p_review_id,coalesce(nullif(btrim(p_reason),''),'Review moderated'));
end;
$$;

create or replace function public.evently_record_review_sentiment(
  p_review_id uuid,p_sentiment text,p_confidence numeric,p_model_version text,p_analyzed_text text
) returns void language plpgsql security definer set search_path = '' as $$
declare v_current_text text;
begin
  if coalesce(current_setting('request.jwt.claim.role',true),'')<>'service_role' then raise exception 'Trusted analysis service required'; end if;
  if p_sentiment not in ('positive','neutral','negative') then raise exception 'Invalid sentiment label'; end if;
  if nullif(btrim(p_model_version),'') is null then raise exception 'A model version is required'; end if;
  select review_text into v_current_text from public.reviews where id=p_review_id for update;
  if not found then raise exception 'Review not found'; end if;
  if nullif(btrim(v_current_text),'') is null then raise exception 'Star-only reviews do not have a sentiment result'; end if;
  if v_current_text is distinct from p_analyzed_text then raise exception 'Review text changed during analysis'; end if;
  update public.reviews set sentiment_label=p_sentiment,
    sentiment_confidence=case when p_confidence between 0 and 1 then p_confidence else null end,
    sentiment_model_version=p_model_version,sentiment_analyzed_at=now(),sentiment_status='complete',updated_at=now()
  where id=p_review_id;
end;
$$;

create or replace function public.evently_consume_review_analysis_quota(p_user_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  if coalesce(current_setting('request.jwt.claim.role',true),'')<>'service_role' then raise exception 'Trusted analysis service required'; end if;
  if p_user_id is null then raise exception 'Analysis owner is required'; end if;
  insert into public.evently_review_analysis_rate_limits(user_id,window_started_at,request_count) values(p_user_id,now(),1)
  on conflict(user_id) do update set
    request_count=case when public.evently_review_analysis_rate_limits.window_started_at<now()-interval '1 minute'
      then 1 else public.evently_review_analysis_rate_limits.request_count+1 end,
    window_started_at=case when public.evently_review_analysis_rate_limits.window_started_at<now()-interval '1 minute'
      then now() else public.evently_review_analysis_rate_limits.window_started_at end
  returning request_count into v_count;
  return v_count<=8;
end;
$$;

create or replace function public.evently_review_features_ready()
returns boolean language sql stable security definer set search_path = '' as $$
  select to_regclass('public.reviews') is not null
   and (select count(*)=17 from pg_catalog.pg_attribute
     where attrelid='public.reviews'::regclass and not attisdropped and attname=any(array[
       'id','customer_id','reservation_id','rating','review_text','public_review_text','service_category',
       'is_published','moderation_status','moderation_reason','sentiment_label','sentiment_confidence',
       'sentiment_analyzed_at','sentiment_model_version','sentiment_status','created_at','updated_at']))
   and to_regprocedure('public.evently_submit_customer_review(uuid,integer,text)') is not null
   and to_regprocedure('public.evently_update_customer_review(uuid,integer,text)') is not null
   and to_regprocedure('public.evently_review_text_has_profanity(text)') is not null
   and to_regprocedure('public.evently_review_text_needs_moderation(text)') is not null
   and to_regprocedure('public.evently_admin_moderate_review(uuid,text,text)') is not null
   and to_regprocedure('public.evently_record_review_sentiment(uuid,text,numeric,text,text)') is not null
   and to_regprocedure('public.evently_consume_review_analysis_quota(uuid)') is not null
   and to_regclass('public.evently_reviews_one_per_reservation_uidx') is not null
   and exists(select 1 from pg_catalog.pg_trigger where tgrelid='public.reviews'::regclass
     and tgname='evently_one_review_per_reservation' and not tgisinternal)
   and exists(select 1 from pg_catalog.pg_class where oid='public.evently_public_reviews'::regclass
       and coalesce(reloptions,array[]::text[]) @> array['security_invoker=true'])
   and has_table_privilege('anon','public.evently_public_reviews','select');
$$;

create or replace view public.evently_public_reviews
with (security_invoker=true,security_barrier=true) as
select rating,public_review_text as review_text,service_category,created_at as review_date,
       'Verified Customer'::text as display_name,true as verified_booking
from public.reviews where is_published=true and moderation_status='approved';

alter table public.reviews enable row level security;
drop policy if exists "Published reviews are public; authors and moderators can read" on public.reviews;
drop policy if exists "Evently restrict review row visibility" on public.reviews;
drop policy if exists "Review rows are private to authors and authorized moderators" on public.reviews;
drop policy if exists "Evently restrict private review row visibility" on public.reviews;
drop policy if exists "Evently approved public review rows" on public.reviews;
drop policy if exists "Evently restrict anonymous reviews" on public.reviews;
drop policy if exists "Evently customer and moderator review rows" on public.reviews;
drop policy if exists "Evently restrict customer and moderator review rows" on public.reviews;
create policy "Evently approved public review rows" on public.reviews for select to anon
  using(is_published=true and moderation_status='approved');
create policy "Evently restrict anonymous reviews" on public.reviews as restrictive for select to anon
  using(is_published=true and moderation_status='approved');
create policy "Evently customer and moderator review rows" on public.reviews for select to authenticated
  using(customer_id=auth.uid() or public.is_evently_admin() or public.evently_staff_has_permission('moderate_reviews'));
create policy "Evently restrict customer and moderator review rows" on public.reviews as restrictive for select to authenticated
  using(customer_id=auth.uid() or public.is_evently_admin() or public.evently_staff_has_permission('moderate_reviews'));

revoke insert,update,delete on public.reviews from public,anon,authenticated;
revoke all on public.reviews from public,anon;
do $$
declare v_columns text;
begin
  select string_agg(pg_catalog.quote_ident(a.attname),', ' order by a.attnum) into v_columns
  from pg_catalog.pg_attribute a where a.attrelid='public.reviews'::regclass and a.attnum>0 and not a.attisdropped;
  if v_columns is not null then execute pg_catalog.format('revoke select (%s) on public.reviews from public, anon',v_columns); end if;
end;
$$;
grant select on public.reviews to authenticated;
grant select(rating,public_review_text,service_category,created_at,is_published,moderation_status) on public.reviews to anon;
revoke all on public.evently_public_reviews from public,anon,authenticated;
grant select on public.evently_public_reviews to anon,authenticated;

revoke all on function public.evently_review_text_has_profanity(text) from public,anon,authenticated;
revoke all on function public.evently_review_text_needs_moderation(text) from public,anon,authenticated;
revoke all on function public.evently_safe_public_review_text(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.evently_guard_one_review_per_reservation() from public,anon,authenticated;
revoke all on function public.evently_submit_customer_review(uuid,integer,text) from public;
revoke all on function public.evently_update_customer_review(uuid,integer,text) from public;
revoke all on function public.evently_admin_moderate_review(uuid,text,text) from public;
revoke all on function public.evently_record_review_sentiment(uuid,text,numeric,text,text) from public,anon,authenticated;
revoke all on function public.evently_consume_review_analysis_quota(uuid) from public,anon,authenticated;
revoke all on function public.evently_review_features_ready() from public;
grant execute on function public.evently_submit_customer_review(uuid,integer,text) to authenticated;
grant execute on function public.evently_update_customer_review(uuid,integer,text) to authenticated;
grant execute on function public.evently_admin_moderate_review(uuid,text,text) to authenticated;
grant execute on function public.evently_record_review_sentiment(uuid,text,numeric,text,text) to service_role;
grant execute on function public.evently_consume_review_analysis_quota(uuid) to service_role;
grant execute on function public.evently_review_features_ready() to anon,authenticated,service_role;

-- ---------------------------------------------------------------------------
-- 3. Verify all modules are still wired to their existing secured RPC paths.
-- ---------------------------------------------------------------------------
do $$
begin
  if public.evently_review_features_ready() is distinct from true then
    raise exception 'Review readiness check failed after repair';
  end if;
  if has_column_privilege('anon','public.reviews','customer_id','select')
    or has_column_privilege('anon','public.reviews','reservation_id','select')
    or has_column_privilege('anon','public.reviews','id','select') then
    raise exception 'Anonymous access to private review identifiers remains';
  end if;
  if has_function_privilege('anon','public.evently_submit_customer_review(uuid,integer,text)','execute')
    or has_function_privilege('authenticated','public.evently_record_review_sentiment(uuid,text,numeric,text,text)','execute') then
    raise exception 'Review RPC grants are too broad';
  end if;
end;
$$;

notify pgrst,'reload schema';
commit;
