-- Database-backed Catering change requests. Exactly 72 hours remains eligible.
-- Existing booking, payment, and audited override RPCs remain authoritative.
begin;

do $$
begin
  if to_regprocedure('public.evently_admin_override_reservation(uuid,text,text,date,time,time,text,timestamptz)') is null
    or to_regprocedure('public.evently_reservation_holds_schedule(uuid)') is null
    or to_regclass('public.evently_resources') is null then
    raise exception 'Apply and verify the prepared schedule-hold/override migration before Catering change requests';
  end if;
end;
$$;

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
  request_status text not null default 'pending' check (request_status in ('pending','approved','rejected')),
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
  v_event_start := (v_reservation.reservation_date+v_reservation.start_time) at time zone 'Asia/Manila';
  if clock_timestamp()>v_event_start-interval '72 hours' then
    raise exception 'Catering cancellation or rescheduling must be requested at least 72 hours before the event';
  end if;
  if v_action='reschedule' then
    if p_proposed_reservation_date is null or p_proposed_start_time is null or p_proposed_end_time is null
       or p_proposed_start_time=p_proposed_end_time then
      raise exception 'A proposed date and distinct start/end times are required';
    end if;
    if ((p_proposed_reservation_date+p_proposed_start_time) at time zone 'Asia/Manila')<=clock_timestamp() then
      raise exception 'The proposed event time must be in the future';
    end if;
  elsif p_proposed_reservation_date is not null or p_proposed_start_time is not null or p_proposed_end_time is not null then
    raise exception 'Do not include a proposed schedule with a cancellation request';
  end if;
  insert into public.evently_catering_change_requests(
    reservation_id,customer_id,request_action,reason,original_reservation_date,
    original_start_time,original_end_time,proposed_reservation_date,proposed_start_time,proposed_end_time
  ) values (
    p_reservation_id,v_customer_id,v_action,btrim(p_reason),v_reservation.reservation_date,
    v_reservation.start_time,v_reservation.end_time,p_proposed_reservation_date,p_proposed_start_time,p_proposed_end_time
  ) returning id into v_request_id;
  return v_request_id;
exception when unique_violation then
  raise exception 'A Catering change request is already awaiting Administrator review';
end;
$$;

create or replace function public.evently_guard_catering_change_request()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_service_type text; v_request public.evently_catering_change_requests%rowtype;
  v_is_cancellation boolean; v_is_schedule_change boolean;
begin
  v_is_cancellation:=lower(new.status::text) in ('cancelled','canceled')
    and lower(old.status::text) not in ('cancelled','canceled');
  v_is_schedule_change:=new.reservation_date is distinct from old.reservation_date
    or new.start_time is distinct from old.start_time or new.end_time is distinct from old.end_time;
  if not v_is_cancellation and not v_is_schedule_change then return new; end if;
  if new.expired_at is not null and old.expired_at is null then return new; end if;
  -- Admin rejection of a pending booking is distinct from a customer cancel
  -- request; customers have no direct reservation DML grants.
  if v_is_cancellation and lower(old.status::text)='pending' then return new; end if;
  select lower(coalesce(package.service_type::text,'')) into v_service_type
  from public.packages package where package.id=old.package_id;
  if coalesce(v_service_type,'') not like '%cater%' then return new; end if;
  select * into v_request from public.evently_catering_change_requests request_row
  where request_row.reservation_id=old.id and request_row.request_status='approved' and request_row.applied_at is null
    and request_row.original_reservation_date=old.reservation_date
    and request_row.original_start_time=old.start_time and request_row.original_end_time=old.end_time
    and request_row.requested_at<=((old.reservation_date+old.start_time) at time zone 'Asia/Manila')-interval '72 hours'
    and ((v_is_cancellation and request_row.request_action='cancel')
      or (v_is_schedule_change and request_row.request_action='reschedule'))
  order by request_row.requested_at desc limit 1 for update;
  if not found then raise exception 'Catering cancellation or schedule changes require a timely customer request and Administrator approval'; end if;
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
    update public.evently_catering_change_requests set request_status='rejected',decision_note=btrim(p_decision_note),
      decided_by=auth.uid(),decided_at=now() where id=v_request.id;
  else
    if v_request.request_action='reschedule'
       and ((v_request.proposed_reservation_date+v_request.proposed_start_time) at time zone 'Asia/Manila')<=clock_timestamp() then
      raise exception 'The proposed Catering schedule has passed; request a new future schedule';
    end if;
    update public.evently_catering_change_requests set request_status='approved',decision_note=btrim(p_decision_note),
      decided_by=auth.uid(),decided_at=now() where id=v_request.id;
    if v_request.request_action='cancel' then
      v_result:=public.evently_admin_override_reservation(v_request.reservation_id,'cancel',btrim(p_decision_note));
    else
      v_result:=public.evently_admin_override_reservation(
        p_reservation_id=>v_request.reservation_id,p_action=>'reschedule',p_reason=>btrim(p_decision_note),
        p_reservation_date=>v_request.proposed_reservation_date,p_start_time=>v_request.proposed_start_time,
        p_end_time=>v_request.proposed_end_time,p_resource_key=>v_resource_key,p_payment_due_at=>null);
    end if;
    update public.evently_catering_change_requests set applied_at=coalesce(applied_at,now()) where id=v_request.id;
  end if;
  insert into public.admin_activity_logs(admin_id,action,entity_type,entity_id,description)
  values(auth.uid(),'catering_change_request_'||p_decision,'reservation',v_request.reservation_id,btrim(p_decision_note));
  insert into public.notifications(user_id,title,message,type,entity_type,entity_id,dedupe_key)
  values(v_request.customer_id,
    case when p_decision='approved' then 'Catering change request approved' else 'Catering change request declined' end,
    case when p_decision='approved' then 'An Administrator approved your timely Catering request.'
      else 'An Administrator declined your Catering request. '||btrim(p_decision_note) end,
    'reservation_status','reservation',v_request.reservation_id,'catering-change-request:'||v_request.id||':'||p_decision)
  on conflict(dedupe_key) where dedupe_key is not null do nothing;
  return jsonb_build_object('request_id',v_request.id,'decision',p_decision,'reservation_result',v_result);
end;
$$;

revoke all on function public.evently_customer_request_catering_change(uuid,text,text,date,time,time) from public,anon;
grant execute on function public.evently_customer_request_catering_change(uuid,text,text,date,time,time) to authenticated;
revoke all on function public.evently_admin_decide_catering_change(uuid,text,text) from public,anon;
grant execute on function public.evently_admin_decide_catering_change(uuid,text,text) to authenticated;
revoke all on function public.evently_guard_catering_change_request() from public,anon,authenticated;

notify pgrst,'reload schema';
commit;
