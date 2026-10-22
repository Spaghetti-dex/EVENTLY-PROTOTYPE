-- Apply only after review in the intended Supabase environment.
-- Shared acceptance ledger (also provisions EVENTLY-STAGING, where absent).
create table if not exists public.evently_terms_acceptances (
 id uuid primary key default gen_random_uuid(),
 customer_id uuid not null references auth.users(id),
 reservation_id uuid unique references public.reservations(id),
 order_id uuid unique references public.orders(id),
 terms_version text not null default '2026-10-22-v1',
 accepted_at timestamptz not null default now(),
 accepted boolean not null default true check (accepted),
 constraint evently_terms_one_subject check ((reservation_id is not null) <> (order_id is not null))
);
alter table public.evently_terms_acceptances enable row level security;
revoke all on public.evently_terms_acceptances from anon,authenticated;
grant select on public.evently_terms_acceptances to authenticated;
drop policy if exists evently_terms_admin_read on public.evently_terms_acceptances;
create policy evently_terms_admin_read on public.evently_terms_acceptances
 for select to authenticated using (public.is_evently_admin());
drop policy if exists evently_terms_customer_read on public.evently_terms_acceptances;
create policy evently_terms_customer_read on public.evently_terms_acceptances
 for select to authenticated using (customer_id=(select auth.uid()));
drop policy if exists evently_terms_permitted_staff_read on public.evently_terms_acceptances;
create policy evently_terms_permitted_staff_read on public.evently_terms_acceptances
 for select to authenticated using (exists (
 select 1 from public.evently_staff_permissions p
 where p.staff_id=(select auth.uid()) and p.permission='view_reservations' and p.granted=true
));

create or replace function public.evently_accept_terms(
 p_reservation_id uuid default null,
 p_order_id uuid default null,
 p_version text default '2026-10-22-v1'
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_customer uuid := auth.uid(); v_id uuid;
begin
 if v_customer is null then raise exception 'Sign in to accept terms'; end if;
 if (p_reservation_id is null) = (p_order_id is null) then raise exception 'Choose one reservation or order'; end if;
 if p_version <> '2026-10-22-v1' then raise exception 'Terms version is outdated'; end if;
 if p_reservation_id is not null then
  if not exists(select 1 from public.reservations where id=p_reservation_id and customer_id=v_customer)
    then raise exception 'Reservation not found or access denied'; end if;
  insert into public.evently_terms_acceptances(customer_id,reservation_id,terms_version,accepted)
   values(v_customer,p_reservation_id,p_version,true) on conflict(reservation_id) do nothing;
  select id into v_id from public.evently_terms_acceptances
   where reservation_id=p_reservation_id and customer_id=v_customer and terms_version=p_version and accepted=true;
 else
  if not exists(select 1 from public.orders where id=p_order_id and customer_id=v_customer)
    then raise exception 'Order not found or access denied'; end if;
  insert into public.evently_terms_acceptances(customer_id,order_id,terms_version,accepted)
   values(v_customer,p_order_id,p_version,true) on conflict(order_id) do nothing;
  select id into v_id from public.evently_terms_acceptances
   where order_id=p_order_id and customer_id=v_customer and terms_version=p_version and accepted=true;
 end if;
 if v_id is null then raise exception 'Existing acceptance does not match the current version'; end if;
 return jsonb_build_object('id',v_id,'version',p_version,'accepted',true);
end
$$;
revoke all on function public.evently_accept_terms(uuid,uuid,text) from public,anon;
grant execute on function public.evently_accept_terms(uuid,uuid,text) to authenticated;


-- Customer requests are pending until an Admin/Owner decides; no refunds or damage charges are automated.
create table if not exists public.evently_catering_change_requests (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  customer_id uuid not null references auth.users(id),
  request_action text not null check (request_action in ('cancel','reschedule')),
  reason text not null check (length(btrim(reason)) between 1 and 2000),
  proposed_reservation_date date,
  proposed_start_time time,
  proposed_end_time time,
  request_status text not null default 'pending' check (request_status in ('pending','approved','rejected')),
  requested_at timestamptz not null default now(),
  original_reservation_date date not null,
  original_start_time time,
  decision_note text,
  decided_at timestamptz,
  decided_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check (request_action='cancel' or (proposed_reservation_date is not null and proposed_start_time is not null and proposed_end_time is not null and proposed_end_time>proposed_start_time))
);
create unique index if not exists evently_one_pending_catering_change_per_reservation
on public.evently_catering_change_requests(reservation_id) where request_status='pending';
alter table public.evently_catering_change_requests enable row level security;
revoke all on public.evently_catering_change_requests from anon, authenticated;
grant select on public.evently_catering_change_requests to authenticated;
drop policy if exists evently_change_customer_select on public.evently_catering_change_requests;
create policy evently_change_customer_select on public.evently_catering_change_requests
for select to authenticated using (customer_id=(select auth.uid()));
drop policy if exists evently_change_admin_select on public.evently_catering_change_requests;
create policy evently_change_admin_select on public.evently_catering_change_requests
for select to authenticated using (public.is_evently_admin());
drop policy if exists evently_change_staff_select on public.evently_catering_change_requests;
create policy evently_change_staff_select on public.evently_catering_change_requests
for select to authenticated using (
 exists (select 1 from public.evently_staff_permissions p
 where p.staff_id=(select auth.uid()) and p.permission='view_reservations' and p.granted=true)
);

create or replace function public.evently_customer_request_catering_change(
 p_reservation_id uuid, p_action text, p_reason text,
 p_proposed_reservation_date date default null,
 p_proposed_start_time time default null,
 p_proposed_end_time time default null
) returns uuid language plpgsql security definer set search_path=''
as $$
declare
 v_res public.reservations%rowtype;
 v_today date := (now() at time zone 'Asia/Manila')::date;
 v_request_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 if p_action not in ('cancel','reschedule') then raise exception 'Invalid request type'; end if;
 if length(btrim(coalesce(p_reason,''))) not between 1 and 2000 then raise exception 'Provide a reason (1-2000 characters)'; end if;
 select * into v_res from public.reservations
 where id=p_reservation_id and customer_id=auth.uid() for update;
 if not found then raise exception 'Booking not found or access denied'; end if;
 if lower(v_res.service_type) not like '%cater%' then raise exception 'This request flow is limited to catering bookings'; end if;
 if v_res.status::text in ('cancelled','completed','rejected') or v_res.expired_at is not null then
  raise exception 'This booking cannot be changed';
 end if;
 if v_res.reservation_date-v_today < 3 then
  raise exception 'Requests must be submitted at least three Manila calendar days before the service date';
 end if;
 if p_action='reschedule' then
   if p_proposed_reservation_date is null or p_proposed_reservation_date < v_today
      or p_proposed_start_time is null or p_proposed_end_time is null
      or p_proposed_end_time <= p_proposed_start_time then
     raise exception 'Choose a valid replacement date and time';
   end if;
 end if;
 insert into public.evently_catering_change_requests(
  reservation_id,customer_id,request_action,reason,original_reservation_date,original_start_time,proposed_reservation_date,
  proposed_start_time,proposed_end_time
 ) values (
  v_res.id,auth.uid(),p_action,btrim(p_reason),v_res.reservation_date,v_res.start_time,
  case when p_action='reschedule' then p_proposed_reservation_date else null end,
  case when p_action='reschedule' then p_proposed_start_time else null end,
  case when p_action='reschedule' then p_proposed_end_time else null end
 ) returning id into v_request_id;
 return v_request_id;
end
$$;
revoke all on function public.evently_customer_request_catering_change(uuid,text,text,date,time,time) from public,anon;
grant execute on function public.evently_customer_request_catering_change(uuid,text,text,date,time,time) to authenticated;

-- The existing booking RPC is retained as a private implementation to preserve
-- package/menu/add-on/availability rules. This public wrapper enforces consent
-- and saves the acceptance within the same transaction as reservation creation.
do $migration$
begin
 if to_regprocedure('public.evently_create_reservation_internal(jsonb)') is null then
  execute 'alter function public.create_evently_reservation(jsonb) rename to evently_create_reservation_internal';
 end if;
end
$migration$;
revoke all on function public.evently_create_reservation_internal(jsonb) from public,anon,authenticated;

create or replace function public.create_evently_reservation(p_booking jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
 v_result jsonb;
 v_reservation uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if jsonb_typeof(p_booking) is distinct from 'object'
   or p_booking->>'terms_accepted' is distinct from 'true'
   or p_booking->>'terms_version' is distinct from '2026-10-22-v1'
 then
  raise exception 'Accept the current Terms and Conditions before checkout';
 end if;
 v_result := public.evently_create_reservation_internal(p_booking);
 v_reservation := nullif(v_result->>'reservation_id','')::uuid;
 if v_reservation is null then raise exception 'Reservation confirmation missing'; end if;
 perform public.evently_accept_terms(v_reservation,null,'2026-10-22-v1');
 return v_result;
end
$$;
revoke all on function public.create_evently_reservation(jsonb) from public,anon;
grant execute on function public.create_evently_reservation(jsonb) to authenticated;

-- Payment rows must always be backed by affirmative, current-version acceptance.
create or replace function public.evently_require_terms_for_payment()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
 if not exists (
  select 1 from public.evently_terms_acceptances a
  where a.customer_id=new.customer_id and a.accepted=true
   and a.terms_version='2026-10-22-v1'
   and ((new.reservation_id is not null and a.reservation_id=new.reservation_id)
     or (new.order_id is not null and a.order_id=new.order_id))
 ) then
  raise exception 'Accept the current Terms and Conditions before payment';
 end if;
 return new;
end
$$;
drop trigger if exists evently_payment_requires_terms on public.payments;
create trigger evently_payment_requires_terms before insert or update of customer_id,reservation_id,order_id on public.payments
for each row execute function public.evently_require_terms_for_payment();

-- Only Admin/Owner may decide on a submitted request. Rescheduling is
-- checked transactionally against the existing resource/schedule validator.
create or replace function public.evently_admin_decide_catering_change(
 p_request_id uuid, p_decision text, p_decision_note text
) returns void language plpgsql security definer set search_path=''
as $$
declare
 v_request public.evently_catering_change_requests%rowtype;
 v_booking public.reservations%rowtype;
 v_check jsonb;
begin
 if auth.uid() is null or not public.is_evently_admin() then
  raise exception 'Owner/Admin access required';
 end if;
 if p_decision not in ('approved','rejected') then raise exception 'Invalid decision'; end if;
 if length(btrim(coalesce(p_decision_note,''))) < 1 then raise exception 'Decision note is required'; end if;
 select * into v_request from public.evently_catering_change_requests
 where id=p_request_id for update;
 if not found or v_request.request_status <> 'pending' then
  raise exception 'Request not found or already decided';
 end if;
 select * into v_booking from public.reservations
 where id=v_request.reservation_id for update;
 if not found then raise exception 'Reservation not found'; end if;
 if p_decision='approved' then
  if v_booking.status::text in ('cancelled','completed','rejected')
     or v_booking.expired_at is not null then
    raise exception 'Booking cannot be modified';
  end if;
  if v_request.request_action='cancel' then
    perform public.admin_set_reservation_status(v_booking.id,'cancelled'::public.booking_status,
      'Customer requested cancellation: ' || v_request.reason);
    -- Deposits remain non-refundable; no payment refund or damage charges are created.
  elsif v_request.request_action='reschedule' then
    if v_request.proposed_reservation_date < (now() at time zone 'Asia/Manila')::date then
      raise exception 'Requested replacement date is in the past';
    end if;
    update public.reservations
    set reservation_date=v_request.proposed_reservation_date,
        start_time=v_request.proposed_start_time,
        end_time=v_request.proposed_end_time,
        updated_at=now()
    where id=v_booking.id;
    v_check:=public.evently_admin_check_reservation_schedule(v_booking.id);
    if coalesce((v_check->>'no_conflict')::boolean,false) <> true then
      raise exception 'Replacement schedule unavailable: %',coalesce(v_check->>'reason','Validation failed');
    end if;
  end if;
 end if;
 update public.evently_catering_change_requests
 set request_status=p_decision,decision_note=btrim(p_decision_note),
     decided_by=auth.uid(),decided_at=now()
 where id=p_request_id;
end
$$;
revoke all on function public.evently_admin_decide_catering_change(uuid,text,text) from public,anon;
grant execute on function public.evently_admin_decide_catering_change(uuid,text,text) to authenticated;

-- Refresh PostgREST's RPC metadata when the migration is actually applied.
notify pgrst, 'reload schema';
