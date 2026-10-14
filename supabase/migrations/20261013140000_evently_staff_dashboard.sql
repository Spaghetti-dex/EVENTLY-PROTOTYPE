-- Extend least-privilege staff capabilities and power dashboard orders/notifications.
-- Apply after 20261013090000, 20261013120000, and 20261013130000.
-- Existing reservations/orders/notifications tables and Admin-only approval RPCs are reused.

do $$
declare
  v_signature text;
  v_item record;
  v_missing_columns text[] := array[]::text[];
begin
  if to_regprocedure('public.evently_staff_role_ready()') is null then
    raise exception 'Apply 20261013130000_evently_staff_role_readiness.sql before the dashboard migration';
  end if;
  if public.evently_staff_role_ready() is distinct from true then
    raise exception 'Apply the staff role readiness migration and confirm evently_staff_role_ready() before the dashboard migration';
  end if;

  foreach v_signature in array array[
    'public.evently_staff_has_permission(text)',
    'public.evently_staff_can_access_reservation(uuid)',
    'public.evently_existing_column(regclass,text[])',
    'public.is_evently_admin()',
    'public.evently_admin_set_reservation_schedule(uuid,time,time,text)',
    'public.evently_admin_approve_booking(uuid,boolean)',
    'public.admin_transition_reservation(uuid,text,text)'
  ] loop
    if to_regprocedure(v_signature) is null then
      raise exception 'Apply the staff/workflow prerequisite migration before dashboard migration: %', v_signature;
    end if;
  end loop;

  if (select proargnames[1:4] from pg_catalog.pg_proc
      where oid = to_regprocedure('public.evently_admin_set_reservation_schedule(uuid,time,time,text)'))
       is distinct from array['p_reservation_id','p_start_time','p_end_time','p_resource_key']::text[]
     or (select proargnames[1:2] from pg_catalog.pg_proc
      where oid = to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)'))
       is distinct from array['p_reservation_id','p_schedule_verified']::text[]
     or (select proargnames[1:3] from pg_catalog.pg_proc
      where oid = to_regprocedure('public.admin_transition_reservation(uuid,text,text)'))
       is distinct from array['p_reservation_id','p_status','p_reason']::text[] then
    raise exception 'Existing workflow RPC parameter names do not match the dashboard review calls';
  end if;

  if pg_catalog.pg_get_function_result(to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)')) <> 'jsonb'
     or pg_catalog.pg_get_function_result(to_regprocedure('public.admin_transition_reservation(uuid,text,text)')) <> 'void'
     or pg_catalog.pg_get_functiondef(to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)')) not ilike '%is_evently_admin%'
     or pg_catalog.pg_get_functiondef(to_regprocedure('public.admin_transition_reservation(uuid,text,text)')) not ilike '%is_evently_admin%' then
    raise exception 'Existing final booking RPCs must have the expected result types and Owner/Admin guard';
  end if;

  if to_regclass('public.evently_staff_permissions') is null
     or to_regclass('public.evently_staff_permission_policy') is null
     or to_regclass('public.evently_booking_recommendations') is null
     or to_regclass('public.evently_reservation_staff_notes') is null
     or to_regclass('public.evently_schedule_proposals') is null then
    raise exception 'Apply 20261013090000_evently_staff_and_reviews.sql before the dashboard migration';
  end if;

  if to_regclass('public.profiles') is null
     or to_regclass('public.reservations') is null
     or to_regclass('public.orders') is null
     or to_regclass('public.admin_activity_logs') is null
     or to_regclass('public.notifications') is null then
    raise exception 'Dashboard prerequisites are missing: profiles, reservations, orders, admin_activity_logs, and notifications must exist';
  end if;

  for v_item in
    select * from (values
      ('profiles','id'), ('profiles','role'), ('profiles','staff_active'),
      ('reservations','id'), ('reservations','reservation_code'), ('reservations','customer_id'),
      ('reservations','customer_name'), ('reservations','customer_email'), ('reservations','customer_phone'),
      ('reservations','service_type'), ('reservations','package_id'), ('reservations','package_name'),
      ('reservations','package_variant'), ('reservations','reservation_date'), ('reservations','start_time'),
      ('reservations','end_time'), ('reservations','resource_key'), ('reservations','resource_name'),
      ('reservations','status'), ('reservations','guest_count'), ('reservations','special_requests'),
      ('reservations','created_at'), ('reservations','updated_at'),
      ('orders','id'), ('orders','reservation_id'), ('orders','order_code'), ('orders','event_date'),
      ('orders','guest_count'), ('orders','package_name'), ('orders','created_at'),
      ('admin_activity_logs','admin_id'), ('admin_activity_logs','action'), ('admin_activity_logs','entity_type'),
      ('admin_activity_logs','entity_id'), ('admin_activity_logs','description'),
      ('notifications','user_id'), ('notifications','title'), ('notifications','message'), ('notifications','type'),
      ('notifications','entity_type'), ('notifications','entity_id'), ('notifications','dedupe_key'),
      ('notifications','is_read'),
      ('evently_staff_permissions','staff_id'), ('evently_staff_permissions','permission'),
      ('evently_staff_permissions','granted'), ('evently_staff_permissions','granted_by'), ('evently_staff_permissions','updated_at'),
      ('evently_staff_permission_policy','permission'), ('evently_staff_permission_policy','allowed_for_admins'),
      ('evently_staff_permission_policy','updated_by'), ('evently_staff_permission_policy','updated_at'),
      ('evently_booking_recommendations','id'), ('evently_booking_recommendations','reservation_id'),
      ('evently_booking_recommendations','staff_id'), ('evently_booking_recommendations','recommendation'),
      ('evently_booking_recommendations','reason'), ('evently_booking_recommendations','notes'),
      ('evently_booking_recommendations','review_state'), ('evently_booking_recommendations','decision_by'),
      ('evently_booking_recommendations','decision_at'), ('evently_booking_recommendations','decision_note'),
      ('evently_booking_recommendations','created_at'), ('evently_booking_recommendations','updated_at')
    ) as required(table_name, column_name)
  loop
    if not exists (
      select 1 from pg_catalog.pg_attribute attribute
      where attribute.attrelid = to_regclass(format('public.%I', v_item.table_name))
        and attribute.attname = v_item.column_name
        and not attribute.attisdropped
    ) then
      v_missing_columns := array_append(v_missing_columns,
        format('public.%s.%s', v_item.table_name, v_item.column_name));
    end if;
  end loop;

  if cardinality(v_missing_columns) > 0 then
    raise exception 'Dashboard schema is incompatible; missing required columns: %',
      array_to_string(v_missing_columns, ', ');
  end if;

  if public.evently_existing_column('public.orders'::regclass, array['order_status','status']) is null then
    raise exception 'The existing orders table must have order_status or status';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_index index_info
    where index_info.indrelid = 'public.notifications'::regclass
      and index_info.indexrelid = to_regclass('public.notifications_dedupe_key_unique')
      and index_info.indisunique
      and index_info.indpred is not null
  ) then
    raise exception 'The partial unique notifications_dedupe_key_unique index is required by dashboard notification triggers';
  end if;
end;
$$;

-- Replace only the canonical permission checks created by 20261013090000.
-- Do not remove unrelated/custom CHECK constraints from either table.
alter table public.evently_staff_permissions
  drop constraint if exists evently_staff_permissions_permission_check;
alter table public.evently_staff_permissions
  add constraint evently_staff_permissions_permission_check check (permission in (
    'view_reservations','edit_reservation_details','propose_schedule_changes',
    'view_calendar','view_customer_details','recommend_approval','recommend_rejection',
    'moderate_reviews','view_orders'
  ));

alter table public.evently_staff_permission_policy
  drop constraint if exists evently_staff_permission_policy_permission_check;
alter table public.evently_staff_permission_policy
  add constraint evently_staff_permission_policy_permission_check check (permission in (
    'view_reservations','edit_reservation_details','propose_schedule_changes',
    'view_calendar','view_customer_details','recommend_approval','recommend_rejection',
    'moderate_reviews','view_orders'
  ));

insert into public.evently_staff_permission_policy(permission, allowed_for_admins)
values ('view_orders', false)
on conflict (permission) do nothing;

alter table public.evently_booking_recommendations
  add column if not exists updated_at timestamptz not null default now();

create or replace function public.evently_touch_recommendation_updated_at()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists evently_touch_recommendation_updated_at on public.evently_booking_recommendations;
create trigger evently_touch_recommendation_updated_at
  before update on public.evently_booking_recommendations
  for each row execute function public.evently_touch_recommendation_updated_at();

create or replace function public.evently_manage_staff_permission(
  p_staff_id uuid, p_permission text, p_granted boolean
) returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if not exists (select 1 from public.profiles where id = p_staff_id and role = 'staff') then
    raise exception 'Staff account not found';
  end if;
  if p_permission not in ('view_reservations','edit_reservation_details','propose_schedule_changes',
    'view_calendar','view_customer_details','recommend_approval','recommend_rejection','moderate_reviews','view_orders') then
    raise exception 'Unsupported staff permission';
  end if;
  if p_granted and not exists (
    select 1 from public.evently_staff_permission_policy
    where permission = p_permission and allowed_for_admins
  ) then
    raise exception 'An Owner must enable this capability in Staff Permission Policy before administrators can grant it';
  end if;
  insert into public.evently_staff_permissions(staff_id, permission, granted, granted_by, updated_at)
    values (p_staff_id, p_permission, p_granted, auth.uid(), now())
  on conflict (staff_id, permission) do update
    set granted = excluded.granted, granted_by = excluded.granted_by, updated_at = now();
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), 'staff_permission_changed', 'profile', p_staff_id,
      p_permission || ' ' || case when p_granted then 'granted' else 'revoked' end);
end;
$$;

-- Keep the Owner policy RPC in sync with view_orders. The permission starts
-- disabled; only an Owner can enable it for Admins.
create or replace function public.evently_owner_set_staff_permission_policy(p_permission text, p_allowed boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'owner') then
    raise exception 'Owner access required to configure staff permission policy';
  end if;
  if p_permission not in ('view_reservations','edit_reservation_details','propose_schedule_changes',
    'view_calendar','view_customer_details','recommend_approval','recommend_rejection',
    'moderate_reviews','view_orders') then
    raise exception 'Unsupported staff permission';
  end if;
  insert into public.evently_staff_permission_policy(permission, allowed_for_admins, updated_by, updated_at)
    values (p_permission, p_allowed, auth.uid(), now())
  on conflict (permission) do update set allowed_for_admins = excluded.allowed_for_admins,
    updated_by = auth.uid(), updated_at = now();
  if not p_allowed then
    update public.evently_staff_permissions set granted = false, granted_by = auth.uid(), updated_at = now()
      where permission = p_permission and granted;
  end if;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), 'staff_permission_policy_changed', 'staff_permission', auth.uid(),
      p_permission || ' ' || case when p_allowed then 'enabled' else 'disabled' end || ' for administrators');
end;
$$;

create or replace function public.evently_staff_submit_booking_recommendation(
  p_reservation_id uuid, p_recommendation text, p_reason text default null, p_notes text default null
) returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_recommendation_id uuid;
  v_permission text;
  v_latest public.evently_booking_recommendations%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if lower(p_recommendation) not in ('approve','reject') then raise exception 'Invalid recommendation'; end if;
  v_permission := case when lower(p_recommendation) = 'approve' then 'recommend_approval' else 'recommend_rejection' end;
  if not public.evently_staff_has_permission(v_permission) then raise exception 'This staff permission has not been granted'; end if;
  if not public.evently_staff_can_access_reservation(p_reservation_id) then raise exception 'This reservation is not available to your account'; end if;
  if lower(p_recommendation) = 'reject' and nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required when recommending rejection';
  end if;

  perform 1 from public.reservations
    where id = p_reservation_id and lower(status::text) = 'pending' for update;
  if not found then raise exception 'Only pending reservations can be recommended'; end if;
  if exists (select 1 from public.evently_booking_recommendations
    where reservation_id = p_reservation_id and review_state = 'awaiting_admin') then
    raise exception 'This reservation already has a recommendation awaiting admin decision';
  end if;
  select * into v_latest from public.evently_booking_recommendations
    where reservation_id = p_reservation_id order by created_at desc limit 1;
  if found and v_latest.review_state = 'revision_requested' and v_latest.staff_id <> auth.uid() then
    raise exception 'This recommendation was returned to another staff member for revision';
  end if;

  insert into public.evently_booking_recommendations(reservation_id, staff_id, recommendation, reason, notes, updated_at)
  values (p_reservation_id, auth.uid(), lower(p_recommendation), nullif(trim(p_reason), ''), nullif(trim(p_notes), ''), now())
  returning id into v_recommendation_id;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), 'booking_recommendation_submitted', 'reservation', p_reservation_id,
      'Staff recommended ' || lower(p_recommendation));
  return v_recommendation_id;
end;
$$;

create or replace function public.evently_staff_list_reservations()
returns setof jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_customer_details boolean := public.evently_staff_has_permission('view_customer_details');
begin
  if not (public.evently_staff_has_permission('view_reservations') or public.evently_staff_has_permission('view_calendar')) then
    raise exception 'Reservation or calendar access has not been granted';
  end if;
  return query select jsonb_build_object(
    'id', r.id, 'reservation_code', r.reservation_code,
    'customer_id', case when v_customer_details then r.customer_id else null end,
    'customer_name', case when v_customer_details then r.customer_name else null end,
    'customer_email', case when v_customer_details then r.customer_email else null end,
    'customer_phone', case when v_customer_details then r.customer_phone else null end,
    'service_type', r.service_type, 'package_id', r.package_id,
    'package_name', r.package_name, 'package_variant', r.package_variant,
    'reservation_date', r.reservation_date, 'start_time', r.start_time, 'end_time', r.end_time,
    'resource_key', r.resource_key, 'resource_name', r.resource_name, 'status', r.status,
    'guest_count', r.guest_count, 'special_requests', r.special_requests, 'created_at', r.created_at,
    'staff_recommendation', recommendation.recommendation,
    'staff_recommendation_status', recommendation.review_state,
    'staff_recommendation_staff_id', recommendation.staff_id
  ) from public.reservations r
  left join lateral (
    select rec.recommendation, rec.review_state, rec.staff_id
    from public.evently_booking_recommendations rec
    where rec.reservation_id = r.id
    order by rec.created_at desc
    limit 1
  ) recommendation on true
  order by r.created_at desc
  limit 500;
end;
$$;

create index if not exists evently_staff_reservations_status_date_idx
  on public.reservations (status, reservation_date);
create index if not exists evently_staff_recommendations_staff_latest_idx
  on public.evently_booking_recommendations (staff_id, created_at desc);

create or replace function public.evently_staff_dashboard_stats()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_total bigint;
  v_pending bigint;
  v_confirmed bigint;
  v_today bigint;
  v_awaiting bigint;
  v_submitted bigint;
  v_can_recommend boolean := public.evently_staff_has_permission('recommend_approval')
    or public.evently_staff_has_permission('recommend_rejection');
begin
  if not (public.evently_staff_has_permission('view_reservations') or public.evently_staff_has_permission('view_calendar')) then
    raise exception 'Reservation or calendar access has not been granted';
  end if;
  select count(*),
    count(*) filter (where lower(status::text) = 'pending'),
    count(*) filter (where lower(status::text) = 'confirmed'),
    count(*) filter (where reservation_date = (now() at time zone 'Asia/Manila')::date and lower(status::text) <> 'cancelled')
  into v_total, v_pending, v_confirmed, v_today
  from public.reservations;
  select count(*) into v_awaiting
  from public.reservations reservation
  where v_can_recommend
    and lower(reservation.status::text) = 'pending'
    and not exists (
      select 1 from public.evently_booking_recommendations recommendation
      where recommendation.reservation_id = reservation.id
        and recommendation.review_state = 'awaiting_admin'
    )
    and (
      not exists (select 1 from public.evently_booking_recommendations recommendation where recommendation.reservation_id = reservation.id)
      or exists (
        select 1 from public.evently_booking_recommendations recommendation
        where recommendation.reservation_id = reservation.id
          and recommendation.staff_id = auth.uid()
          and recommendation.review_state = 'revision_requested'
          and recommendation.created_at = (
            select max(latest.created_at) from public.evently_booking_recommendations latest
            where latest.reservation_id = reservation.id
          )
      )
    );
  select count(*) into v_submitted from public.evently_booking_recommendations where staff_id = auth.uid();
  return jsonb_build_object(
    'total_reservations', v_total,
    'pending_reservations', v_pending,
    'confirmed_reservations', v_confirmed,
    'today_bookings', v_today,
    'awaiting_my_recommendation', v_awaiting,
    'my_submitted_recommendations', v_submitted
  );
end;
$$;

create or replace function public.evently_staff_list_orders()
returns setof jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_status_column text;
  v_sql text;
  v_customer_details boolean := public.evently_staff_has_permission('view_customer_details');
begin
  if not public.evently_staff_has_permission('view_orders') then raise exception 'Order access has not been granted'; end if;
  v_status_column := public.evently_existing_column('public.orders', array['order_status','status']);
  if v_status_column is null then raise exception 'Order status column is missing'; end if;
  v_sql := format(
    'select jsonb_build_object(
      ''id'', orders.id,
      ''reservation_id'', orders.reservation_id,
      ''order_code'', orders.order_code,
      ''reservation_code'', reservation.reservation_code,
      ''customer_name'', case when $1 then reservation.customer_name else null end,
      ''service_type'', reservation.service_type,
      ''package_name'', coalesce(orders.package_name, reservation.package_name),
      ''event_date'', orders.event_date,
      ''start_time'', reservation.start_time,
      ''end_time'', reservation.end_time,
      ''resource_name'', reservation.resource_name,
      ''guest_count'', orders.guest_count,
      ''status'', orders.%I,
      ''created_at'', orders.created_at
    ) from public.orders orders
    left join public.reservations reservation on reservation.id = orders.reservation_id
    order by orders.event_date desc nulls last, orders.created_at desc
    limit 500',
    v_status_column
  );
  return query execute v_sql using v_customer_details;
end;
$$;

-- Notifications are written only for real reservations and workflow decisions.
create or replace function public.evently_notify_staff_reservation_created()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if lower(new.status::text) = 'pending' then
    insert into public.notifications(user_id, title, message, type, entity_type, entity_id, dedupe_key)
    select staff.id, 'New reservation awaiting review',
      'Reservation ' || new.reservation_code || ' is ready for staff review.',
      'staff_booking_review', 'reservation', new.id,
      'staff-booking-review:' || new.id || ':' || staff.id
    from public.profiles staff
    join public.evently_staff_permissions permission_row on permission_row.staff_id = staff.id
    where staff.role = 'staff' and staff.staff_active
      and permission_row.permission = 'view_reservations' and permission_row.granted
    on conflict (dedupe_key) where dedupe_key is not null do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists evently_notify_staff_reservation_created on public.reservations;
create trigger evently_notify_staff_reservation_created after insert on public.reservations
  for each row execute function public.evently_notify_staff_reservation_created();

create or replace function public.evently_notify_staff_schedule_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.reservation_date is not distinct from old.reservation_date
     and new.start_time is not distinct from old.start_time
     and new.end_time is not distinct from old.end_time
     and new.resource_key is not distinct from old.resource_key then
    return new;
  end if;
  insert into public.notifications(user_id, title, message, type, entity_type, entity_id, dedupe_key)
  select staff.id, 'Reservation schedule updated',
    'Reservation ' || new.reservation_code || ' has an updated date, time, or resource.',
    'staff_schedule_update', 'reservation', new.id,
    'staff-schedule:' || new.id || ':' || coalesce(new.updated_at::text, now()::text) || ':' || staff.id
  from public.profiles staff
  join public.evently_staff_permissions permission_row on permission_row.staff_id = staff.id
  where staff.role = 'staff' and staff.staff_active and permission_row.granted
    and permission_row.permission in ('view_calendar','view_reservations')
  on conflict (dedupe_key) where dedupe_key is not null do nothing;
  return new;
end;
$$;

drop trigger if exists evently_notify_staff_schedule_change on public.reservations;
create trigger evently_notify_staff_schedule_change
  after update of reservation_date, start_time, end_time, resource_key on public.reservations
  for each row execute function public.evently_notify_staff_schedule_change();

create or replace function public.evently_notify_staff_booking_confirmation()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if lower(new.status::text) = 'confirmed' and lower(old.status::text) <> 'confirmed' then
    insert into public.notifications(user_id, title, message, type, entity_type, entity_id, dedupe_key)
    select staff.id, 'Upcoming confirmed event',
      'Reservation ' || new.reservation_code || ' is confirmed for ' || new.reservation_date || '.',
      'staff_confirmed_event', 'reservation', new.id,
      'staff-confirmed-event:' || new.id || ':' || staff.id
    from public.profiles staff
    join public.evently_staff_permissions permission_row on permission_row.staff_id = staff.id
    where staff.role = 'staff' and staff.staff_active and permission_row.granted
      and permission_row.permission in ('view_calendar','view_reservations')
    on conflict (dedupe_key) where dedupe_key is not null do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists evently_notify_staff_booking_confirmation on public.reservations;
create trigger evently_notify_staff_booking_confirmation after update of status on public.reservations
  for each row execute function public.evently_notify_staff_booking_confirmation();

create or replace function public.evently_notify_booking_recommendation()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.notifications(user_id, title, message, type, entity_type, entity_id, dedupe_key)
    select administrator.id, 'Staff recommendation awaiting decision',
      'A staff member recommends ' || new.recommendation || ' for reservation ' || reservation.reservation_code || '.',
      'staff_recommendation', 'reservation', new.reservation_id,
      'staff-recommendation-admin:' || new.id || ':' || administrator.id
    from public.profiles administrator
    join public.reservations reservation on reservation.id = new.reservation_id
    where administrator.role in ('admin','owner')
    on conflict (dedupe_key) where dedupe_key is not null do nothing;
  elsif new.review_state is distinct from old.review_state then
    insert into public.notifications(user_id, title, message, type, entity_type, entity_id, dedupe_key)
    select new.staff_id,
      case new.review_state
        when 'approved' then 'Your recommendation was approved'
        when 'rejected' then 'Your recommendation was rejected'
        when 'revision_requested' then 'Your recommendation needs revision'
        else 'Recommendation updated'
      end,
      'Reservation ' || reservation.reservation_code || ': ' || coalesce(new.decision_note, new.review_state) || '.',
      'staff_recommendation_update', 'reservation', new.reservation_id,
      'staff-recommendation-update:' || new.id || ':' || new.review_state
    from public.reservations reservation where reservation.id = new.reservation_id
    on conflict (dedupe_key) where dedupe_key is not null do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists evently_notify_booking_recommendation on public.evently_booking_recommendations;
create trigger evently_notify_booking_recommendation after insert or update on public.evently_booking_recommendations
  for each row execute function public.evently_notify_booking_recommendation();

create or replace function public.evently_notify_schedule_proposal()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.notifications(user_id, title, message, type, entity_type, entity_id, dedupe_key)
    select administrator.id, 'Staff schedule proposal',
      'A staff member proposed a schedule update for reservation ' || reservation.reservation_code || '.',
      'staff_schedule_proposal', 'reservation', new.reservation_id,
      'staff-schedule-proposal-admin:' || new.id || ':' || administrator.id
    from public.profiles administrator
    join public.reservations reservation on reservation.id = new.reservation_id
    where administrator.role in ('admin','owner')
    on conflict (dedupe_key) where dedupe_key is not null do nothing;
  elsif new.proposal_state is distinct from old.proposal_state then
    insert into public.notifications(user_id, title, message, type, entity_type, entity_id, dedupe_key)
    select new.staff_id, 'Schedule proposal reviewed',
      'Your schedule proposal for reservation ' || reservation.reservation_code || ' was ' || new.proposal_state || '.',
      'staff_schedule_update', 'reservation', new.reservation_id,
      'staff-schedule-update:' || new.id || ':' || new.proposal_state
    from public.reservations reservation where reservation.id = new.reservation_id
    on conflict (dedupe_key) where dedupe_key is not null do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists evently_notify_schedule_proposal on public.evently_schedule_proposals;
create trigger evently_notify_schedule_proposal after insert or update on public.evently_schedule_proposals
  for each row execute function public.evently_notify_schedule_proposal();

grant select on public.notifications to authenticated;
revoke all on function public.evently_staff_dashboard_stats() from public;
grant execute on function public.evently_staff_dashboard_stats() to authenticated;
revoke all on function public.evently_staff_list_orders() from public;
grant execute on function public.evently_staff_list_orders() to authenticated;
revoke all on function public.evently_owner_set_staff_permission_policy(text,boolean) from public;
grant execute on function public.evently_owner_set_staff_permission_policy(text,boolean) to authenticated;
revoke all on function public.evently_touch_recommendation_updated_at() from public;
revoke all on function public.evently_notify_staff_reservation_created() from public;
revoke all on function public.evently_notify_staff_schedule_change() from public;
revoke all on function public.evently_notify_staff_booking_confirmation() from public;
revoke all on function public.evently_notify_booking_recommendation() from public;
revoke all on function public.evently_notify_schedule_proposal() from public;

create or replace function public.evently_staff_permissions_ready()
returns boolean language sql stable security definer set search_path = ''
as $$
  select public.evently_staff_role_ready()
    and to_regclass('public.evently_staff_permissions') is not null
    and to_regclass('public.evently_staff_permission_policy') is not null
    and to_regclass('public.evently_booking_recommendations') is not null
    and to_regclass('public.evently_reservation_staff_notes') is not null
    and to_regclass('public.evently_schedule_proposals') is not null
    and to_regprocedure('public.evently_staff_has_permission(text)') is not null
    and to_regprocedure('public.evently_staff_list_reservations()') is not null
    and to_regprocedure('public.evently_staff_can_access_reservation(uuid)') is not null
    and to_regprocedure('public.evently_staff_add_reservation_note(uuid,text)') is not null
    and to_regprocedure('public.evently_staff_propose_reservation_schedule(uuid,date,time,time,text,text)') is not null
    and to_regprocedure('public.evently_admin_decide_schedule_proposal(uuid,boolean,text)') is not null
    and to_regprocedure('public.evently_manage_staff_permission(uuid,text,boolean)') is not null
    and to_regprocedure('public.evently_owner_set_staff_permission_policy(text,boolean)') is not null
    and to_regprocedure('public.evently_admin_set_staff_active(uuid,boolean)') is not null
    and to_regprocedure('public.evently_staff_dashboard_stats()') is not null
    and to_regprocedure('public.evently_staff_list_orders()') is not null
    and to_regprocedure('public.evently_staff_submit_booking_recommendation(uuid,text,text,text)') is not null
    and to_regprocedure('public.evently_admin_review_booking_recommendation(uuid,text,text,boolean)') is not null
    and to_regprocedure('public.evently_touch_recommendation_updated_at()') is not null
    and to_regprocedure('public.evently_notify_staff_reservation_created()') is not null
    and to_regprocedure('public.evently_notify_staff_schedule_change()') is not null
    and to_regprocedure('public.evently_notify_staff_booking_confirmation()') is not null
    and to_regprocedure('public.evently_notify_booking_recommendation()') is not null
    and to_regprocedure('public.evently_notify_schedule_proposal()') is not null
    and exists (
      select 1 from pg_catalog.pg_trigger
      where tgrelid = to_regclass('public.reservations')
        and tgname = 'evently_notify_staff_reservation_created' and not tgisinternal
    )
    and exists (
      select 1 from pg_catalog.pg_trigger
      where tgrelid = to_regclass('public.reservations')
        and tgname = 'evently_notify_staff_schedule_change' and not tgisinternal
    )
    and exists (
      select 1 from pg_catalog.pg_trigger
      where tgrelid = to_regclass('public.reservations')
        and tgname = 'evently_notify_staff_booking_confirmation' and not tgisinternal
    )
    and exists (
      select 1 from pg_catalog.pg_trigger
      where tgrelid = to_regclass('public.evently_booking_recommendations')
        and tgname = 'evently_notify_booking_recommendation' and not tgisinternal
    )
    and exists (
      select 1 from pg_catalog.pg_trigger
      where tgrelid = to_regclass('public.evently_schedule_proposals')
        and tgname = 'evently_notify_schedule_proposal' and not tgisinternal
    )
    and exists (
      select 1 from pg_catalog.pg_trigger
      where tgrelid = to_regclass('public.evently_booking_recommendations')
        and tgname = 'evently_touch_recommendation_updated_at' and not tgisinternal
    );
$$;

revoke all on function public.evently_staff_permissions_ready() from public;
grant execute on function public.evently_staff_permissions_ready() to authenticated, service_role;

notify pgrst, 'reload schema';
