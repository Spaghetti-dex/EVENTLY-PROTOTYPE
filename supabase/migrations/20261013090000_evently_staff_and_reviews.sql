-- EVENTLY staff permissions and two-step booking review.
-- Additive: final reservation status remains governed by the existing admin RPCs.

-- Fail before changing schema if the established Admin-only booking workflow
-- signatures/guards from the earlier workflow migrations are not installed.
do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.evently_admin_set_reservation_schedule(uuid,time,time,text)',
    'public.evently_admin_approve_booking(uuid,boolean)',
    'public.admin_transition_reservation(uuid,text,text)',
    'public.evently_existing_column(regclass,text[])',
    'public.is_evently_admin()'
  ] loop
    if to_regprocedure(v_signature) is null then
      raise exception 'Required earlier EVENTLY workflow RPC is missing: %', v_signature;
    end if;
  end loop;

  if pg_catalog.pg_get_functiondef(to_regprocedure('public.evently_admin_set_reservation_schedule(uuid,time,time,text)'))
       not ilike '%is_evently_admin%'
     or pg_catalog.pg_get_functiondef(to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)'))
       not ilike '%is_evently_admin%'
     or pg_catalog.pg_get_functiondef(to_regprocedure('public.admin_transition_reservation(uuid,text,text)'))
       not ilike '%is_evently_admin%' then
    raise exception 'Existing schedule/booking RPCs must retain their Owner/Admin authorization checks';
  end if;

  if not has_function_privilege('authenticated', to_regprocedure('public.evently_admin_set_reservation_schedule(uuid,time,time,text)'), 'EXECUTE')
     or not has_function_privilege('authenticated', to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)'), 'EXECUTE')
     or not has_function_privilege('authenticated', to_regprocedure('public.admin_transition_reservation(uuid,text,text)'), 'EXECUTE') then
    raise exception 'Authenticated must retain EXECUTE on the existing Owner/Admin-guarded workflow RPCs';
  end if;

  if has_function_privilege('anon', to_regprocedure('public.evently_admin_set_reservation_schedule(uuid,time,time,text)'), 'EXECUTE')
     or has_function_privilege('anon', to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)'), 'EXECUTE')
     or has_function_privilege('anon', to_regprocedure('public.admin_transition_reservation(uuid,text,text)'), 'EXECUTE') then
    raise exception 'Anonymous users must not have EXECUTE on booking decision/schedule RPCs';
  end if;

  if (select proargnames[1:4] from pg_catalog.pg_proc
      where oid = to_regprocedure('public.evently_admin_set_reservation_schedule(uuid,time,time,text)'))
       is distinct from array['p_reservation_id','p_start_time','p_end_time','p_resource_key']::text[]
     or (select proargnames[1:2] from pg_catalog.pg_proc
      where oid = to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)'))
       is distinct from array['p_reservation_id','p_schedule_verified']::text[]
     or (select proargnames[1:3] from pg_catalog.pg_proc
      where oid = to_regprocedure('public.admin_transition_reservation(uuid,text,text)'))
       is distinct from array['p_reservation_id','p_status','p_reason']::text[] then
    raise exception 'Existing workflow RPC parameter names do not match the staff-review calls; inspect pg_proc.proargnames before applying';
  end if;

  if pg_catalog.pg_get_function_result(to_regprocedure('public.evently_admin_set_reservation_schedule(uuid,time,time,text)')) <> 'void'
     or pg_catalog.pg_get_function_result(to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)')) <> 'jsonb'
     or pg_catalog.pg_get_function_result(to_regprocedure('public.admin_transition_reservation(uuid,text,text)')) <> 'void' then
    raise exception 'Existing workflow RPC return types differ from the staff-review contract';
  end if;
end;
$$;

-- Verify every pre-existing relation/column used by the staff RPCs and RLS
-- policies before adding tables, triggers, or dependent functions.
do $schema_preflight$
declare
  v_item record;
  v_missing_tables text[] := array[]::text[];
  v_missing_columns text[] := array[]::text[];
begin
  for v_item in
    select * from (values
      ('profiles'), ('reservations'), ('orders'), ('payments'), ('notifications'),
      ('admin_activity_logs'), ('packages'), ('package_variants'), ('evently_resources')
    ) as required(table_name)
  loop
    if to_regclass(format('public.%I', v_item.table_name)) is null then
      v_missing_tables := array_append(v_missing_tables, 'public.' || v_item.table_name);
    end if;
  end loop;

  if cardinality(v_missing_tables) > 0 then
    raise exception 'Apply the earlier EVENTLY base migrations first; missing tables: %',
      array_to_string(v_missing_tables, ', ');
  end if;

  for v_item in
    select * from (values
      ('profiles','id'), ('profiles','role'),
      ('reservations','id'), ('reservations','customer_id'), ('reservations','reservation_code'),
      ('reservations','customer_name'), ('reservations','customer_email'), ('reservations','customer_phone'),
      ('reservations','service_type'), ('reservations','package_id'), ('reservations','package_variant'),
      ('reservations','reservation_date'), ('reservations','start_time'), ('reservations','end_time'),
      ('reservations','resource_key'), ('reservations','resource_name'), ('reservations','status'),
      ('reservations','guest_count'), ('reservations','special_requests'), ('reservations','created_at'),
      ('reservations','updated_at'),
      ('orders','id'), ('orders','customer_id'), ('orders','reservation_id'),
      ('payments','customer_id'),
      ('notifications','user_id'), ('notifications','title'), ('notifications','message'),
      ('notifications','type'), ('notifications','entity_type'), ('notifications','entity_id'), ('notifications','dedupe_key'),
      ('admin_activity_logs','admin_id'), ('admin_activity_logs','action'), ('admin_activity_logs','entity_type'),
      ('admin_activity_logs','entity_id'), ('admin_activity_logs','description'),
      ('packages','id'), ('package_variants','id'), ('package_variants','package_id'),
      ('evently_resources','resource_key'), ('evently_resources','is_active')
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
    raise exception 'Existing EVENTLY schema is incompatible; missing required columns: %',
      array_to_string(v_missing_columns, ', ');
  end if;

  if public.evently_existing_column('public.orders'::regclass, array['order_status','status']) is null then
    raise exception 'The existing orders table must have order_status or status';
  end if;
end;
$schema_preflight$;

do $$
declare
  v_role_type oid;
  v_role_type_kind text;
  constraint_row record;
begin
  select role_type.oid, role_type.typtype::text
  into v_role_type, v_role_type_kind
  from pg_catalog.pg_attribute attribute
  join pg_catalog.pg_type role_type on role_type.oid = attribute.atttypid
  where attribute.attrelid = 'public.profiles'::regclass
    and attribute.attname = 'role'
    and not attribute.attisdropped;

  if v_role_type is null then
    raise exception 'public.profiles.role is missing; staff migration cannot continue';
  elsif v_role_type_kind = 'e' then
    -- Keep an enum authoritative: never add/drop enum labels or replace its
    -- type with text. The enum itself must already support the staff label.
    if not exists (
      select 1 from pg_catalog.pg_enum
      where enumtypid = v_role_type and enumlabel = 'staff'
    ) then
      raise exception 'The existing public.profiles.role enum does not contain staff; apply the role-enum migration first';
    end if;
  else
    -- Text-based deployments need a CHECK constraint. Refuse to discard any
    -- role values already present outside EVENTLY's four supported roles.
    if exists (
      select 1 from public.profiles
      where role::text not in ('customer', 'owner', 'admin', 'staff')
    ) then
      raise exception 'public.profiles contains an unsupported role value; preserve and resolve it before changing role checks';
    end if;

    for constraint_row in
      select conname
      from pg_catalog.pg_constraint
      where conrelid = 'public.profiles'::regclass
        and contype = 'c'
        and pg_catalog.pg_get_constraintdef(oid) ilike '%role%'
        and conname <> 'profiles_role_check'
    loop
      raise exception 'Custom role CHECK constraint % requires review; refusing to drop it automatically', constraint_row.conname;
    end loop;
    alter table public.profiles drop constraint if exists profiles_role_check;
    alter table public.profiles add constraint profiles_role_check
      check (role in ('customer', 'owner', 'admin', 'staff'));
  end if;
end;
$$;

alter table public.profiles add column if not exists staff_active boolean not null default true;

-- Keep profile role changes protected from browser-authenticated users while
-- allowing the service-role invitation endpoint to provision Staff profiles.
create or replace function public.protect_evently_profile_role()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.role is distinct from old.role
     and not exists (select 1 from public.profiles where id = auth.uid() and role = 'owner')
     and coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
     raise exception 'Only the Owner or trusted provisioning service may change account roles';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_evently_profile_role on public.profiles;
create trigger protect_evently_profile_role before update of role on public.profiles
  for each row execute function public.protect_evently_profile_role();

create or replace function public.evently_guard_customer_reservation_insert()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is not null and not exists (
    select 1 from public.profiles where id = auth.uid() and role = 'customer'
  ) then
    raise exception 'Only customer accounts may submit customer reservations';
  end if;
  return new;
end;
$$;

drop trigger if exists evently_guard_customer_reservation_insert on public.reservations;
create trigger evently_guard_customer_reservation_insert before insert on public.reservations
  for each row execute function public.evently_guard_customer_reservation_insert();

create table if not exists public.evently_staff_permissions (
  staff_id uuid not null references public.profiles(id) on delete cascade,
  permission text not null check (permission in (
    'view_reservations', 'edit_reservation_details', 'propose_schedule_changes',
    'view_calendar', 'view_customer_details', 'recommend_approval',
    'recommend_rejection', 'moderate_reviews'
  )),
  granted boolean not null default false,
  granted_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  primary key (staff_id, permission)
);

create table if not exists public.evently_staff_permission_policy (
  permission text primary key check (permission in (
    'view_reservations', 'edit_reservation_details', 'propose_schedule_changes',
    'view_calendar', 'view_customer_details', 'recommend_approval',
    'recommend_rejection', 'moderate_reviews'
  )),
  allowed_for_admins boolean not null default false,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

insert into public.evently_staff_permission_policy(permission, allowed_for_admins)
values ('view_reservations',false),('edit_reservation_details',false),('propose_schedule_changes',false),
  ('view_calendar',false),('view_customer_details',false),('recommend_approval',false),
  ('recommend_rejection',false),('moderate_reviews',false)
on conflict (permission) do nothing;

create table if not exists public.evently_booking_recommendations (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  staff_id uuid not null references public.profiles(id),
  recommendation text not null check (recommendation in ('approve', 'reject')),
  reason text,
  notes text,
  review_state text not null default 'awaiting_admin'
    check (review_state in ('awaiting_admin', 'approved', 'rejected', 'revision_requested')),
  decision_by uuid references public.profiles(id),
  decision_at timestamptz,
  decision_note text,
  created_at timestamptz not null default now()
);

create table if not exists public.evently_reservation_staff_notes (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  staff_id uuid not null references public.profiles(id),
  note text not null check (length(trim(note)) between 1 and 3000),
  created_at timestamptz not null default now()
);

create table if not exists public.evently_schedule_proposals (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  staff_id uuid not null references public.profiles(id),
  proposed_date date not null,
  proposed_start_time time not null,
  proposed_end_time time not null,
  proposed_resource_key text,
  note text,
  proposal_state text not null default 'pending' check (proposal_state in ('pending','accepted','rejected')),
  decided_by uuid references public.profiles(id),
  decided_at timestamptz,
  decision_note text,
  created_at timestamptz not null default now(),
  check (proposed_start_time <> proposed_end_time)
);

create table if not exists public.evently_review_analysis_rate_limits (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  request_count integer not null default 0
);

-- Reuse public.reviews when it exists; otherwise create the single canonical
-- review table used by the customer site and admin workspace.
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles(id) on delete cascade,
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  review_text text not null,
  is_published boolean not null default false,
  moderation_status text not null default 'pending',
  moderation_reason text,
  sentiment_label text,
  sentiment_confidence numeric(6,5),
  sentiment_analyzed_at timestamptz,
  sentiment_model_version text,
  created_at timestamptz not null default now()
);

alter table public.reviews
  add column if not exists customer_id uuid references public.profiles(id) on delete cascade,
  add column if not exists reservation_id uuid references public.reservations(id) on delete cascade,
  add column if not exists rating smallint,
  add column if not exists review_text text,
  add column if not exists is_published boolean not null default false,
  add column if not exists moderation_status text not null default 'pending',
  add column if not exists moderation_reason text,
  add column if not exists sentiment_label text,
  add column if not exists sentiment_confidence numeric(6,5),
  add column if not exists sentiment_analyzed_at timestamptz,
  add column if not exists sentiment_model_version text,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

do $$
begin
  if exists (select 1 from pg_catalog.pg_attribute where attrelid = 'public.reviews'::regclass and attname = 'user_id' and not attisdropped) then
    execute 'update public.reviews set customer_id = user_id::uuid where customer_id is null';
  end if;
  if exists (select 1 from pg_catalog.pg_attribute where attrelid = 'public.reviews'::regclass and attname = 'comment' and not attisdropped) then
    execute 'update public.reviews set review_text = comment where review_text is null';
  elsif exists (select 1 from pg_catalog.pg_attribute where attrelid = 'public.reviews'::regclass and attname = 'content' and not attisdropped) then
    execute 'update public.reviews set review_text = content where review_text is null';
  end if;
end;
$$;

-- Preserve existing public reviews as approved; unapproved and unpublished rows
-- remain in the moderation queue.
update public.reviews
set moderation_status = 'approved'
where is_published and moderation_status = 'pending';

do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint where conname = 'evently_reviews_rating_check' and conrelid = 'public.reviews'::regclass) then
    alter table public.reviews add constraint evently_reviews_rating_check check (rating between 1 and 5) not valid;
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint where conname = 'evently_reviews_moderation_check' and conrelid = 'public.reviews'::regclass) then
    alter table public.reviews add constraint evently_reviews_moderation_check check (moderation_status in ('pending','approved','rejected','flagged')) not valid;
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint where conname = 'evently_reviews_sentiment_check' and conrelid = 'public.reviews'::regclass) then
    alter table public.reviews add constraint evently_reviews_sentiment_check check (sentiment_label is null or sentiment_label in ('positive','neutral','negative')) not valid;
  end if;
end;
$$;

create index if not exists evently_reviews_published_created_idx
  on public.reviews(is_published, created_at desc);

create index if not exists evently_booking_recommendations_latest_idx
  on public.evently_booking_recommendations (reservation_id, created_at desc);

alter table public.evently_staff_permissions enable row level security;
alter table public.evently_staff_permission_policy enable row level security;
alter table public.evently_booking_recommendations enable row level security;
alter table public.evently_reservation_staff_notes enable row level security;
alter table public.evently_schedule_proposals enable row level security;
alter table public.evently_review_analysis_rate_limits enable row level security;

-- Keep any older permissive policies from accidentally exposing customer or
-- financial rows to the new staff role.
drop policy if exists "Evently restrict reservation visibility" on public.reservations;
create policy "Evently restrict reservation visibility" on public.reservations as restrictive for select to authenticated
  using (customer_id = auth.uid() or public.is_evently_admin());
drop policy if exists "Evently restrict order visibility" on public.orders;
create policy "Evently restrict order visibility" on public.orders as restrictive for select to authenticated
  using (customer_id = auth.uid() or public.is_evently_admin());
drop policy if exists "Evently restrict payment visibility" on public.payments;
create policy "Evently restrict payment visibility" on public.payments as restrictive for select to authenticated
  using (customer_id = auth.uid() or public.is_evently_admin());
drop policy if exists "Evently restrict notification visibility" on public.notifications;
create policy "Evently restrict notification visibility" on public.notifications as restrictive for select to authenticated
  using (user_id = auth.uid() or public.is_evently_admin());
drop policy if exists "Evently restrict profile visibility" on public.profiles;
create policy "Evently restrict profile visibility" on public.profiles as restrictive for select to authenticated
  using (id = auth.uid() or public.is_evently_admin() or
    (role = 'customer' and public.evently_staff_has_permission('view_customer_details')));
drop policy if exists "Evently restrict admin activity visibility" on public.admin_activity_logs;
create policy "Evently restrict admin activity visibility" on public.admin_activity_logs as restrictive for select to authenticated
  using (public.is_evently_admin());
alter table public.reviews enable row level security;

create or replace function public.evently_staff_has_permission(p_permission text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'staff' and p.staff_active
      and exists (
        select 1 from public.evently_staff_permissions grant_row
        where grant_row.staff_id = p.id
          and grant_row.permission = p_permission and grant_row.granted
      )
  );
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
    'customer_id', case when public.evently_staff_has_permission('view_customer_details') then r.customer_id else null end,
    'customer_name', case when v_customer_details then r.customer_name else null end,
    'customer_email', case when v_customer_details then r.customer_email else null end,
    'customer_phone', case when v_customer_details then r.customer_phone else null end,
    'package_name', r.package_name, 'package_variant', r.package_variant,
    'reservation_date', r.reservation_date, 'start_time', r.start_time, 'end_time', r.end_time,
    'resource_key', r.resource_key, 'resource_name', r.resource_name, 'status', r.status,
    'guest_count', r.guest_count, 'special_requests', r.special_requests, 'created_at', r.created_at
  ) from public.reservations r
  where lower(r.status::text) <> 'cancelled'
  order by r.reservation_date;
end;
$$;

create or replace function public.evently_staff_can_access_reservation(p_reservation_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select (public.evently_staff_has_permission('view_reservations') or public.evently_staff_has_permission('view_calendar'))
    and exists (select 1 from public.reservations where id = p_reservation_id);
$$;

create or replace function public.evently_staff_add_reservation_note(p_reservation_id uuid, p_note text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if not public.evently_staff_has_permission('edit_reservation_details') then raise exception 'Reservation edit permission has not been granted'; end if;
  if not public.evently_staff_can_access_reservation(p_reservation_id) then raise exception 'This reservation is not available to your account'; end if;
  if length(trim(coalesce(p_note,''))) not between 1 and 3000 then raise exception 'Note must contain 1 to 3000 characters'; end if;
  if not exists (select 1 from public.reservations where id = p_reservation_id) then raise exception 'Reservation not found'; end if;
  insert into public.evently_reservation_staff_notes(reservation_id, staff_id, note)
    values (p_reservation_id, auth.uid(), trim(p_note)) returning id into v_id;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), 'staff_booking_note_added', 'reservation', p_reservation_id, 'Internal staff note added');
  return v_id;
end;
$$;

create or replace function public.evently_staff_propose_reservation_schedule(
  p_reservation_id uuid, p_date date, p_start_time time, p_end_time time,
  p_resource_key text default null, p_note text default null
) returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if not public.evently_staff_has_permission('propose_schedule_changes') then raise exception 'Schedule proposal permission has not been granted'; end if;
  if not public.evently_staff_can_access_reservation(p_reservation_id) then raise exception 'This reservation is not available to your account'; end if;
  if p_date < current_date or p_start_time is null or p_end_time is null or p_start_time = p_end_time then
    raise exception 'A future date and distinct schedule times are required';
  end if;
  if not exists (select 1 from public.reservations where id = p_reservation_id and lower(status::text) = 'pending') then
    raise exception 'Only pending reservations may receive schedule proposals';
  end if;
  if p_date <> (select reservation_date from public.reservations where id = p_reservation_id) then
    raise exception 'Date changes require a separate admin-reviewed booking change';
  end if;
  if nullif(trim(p_resource_key), '') is null then raise exception 'A configured resource is required'; end if;
  if not exists (
    select 1 from public.evently_resources where lower(resource_key) = lower(trim(p_resource_key)) and is_active
  ) then raise exception 'Select an active configured resource'; end if;
  insert into public.evently_schedule_proposals(reservation_id, staff_id, proposed_date, proposed_start_time, proposed_end_time, proposed_resource_key, note)
    values (p_reservation_id, auth.uid(), p_date, p_start_time, p_end_time, nullif(trim(p_resource_key), ''), nullif(trim(p_note), '')) returning id into v_id;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), 'staff_schedule_proposed', 'reservation', p_reservation_id, 'Staff proposed a schedule change');
  return v_id;
end;
$$;

create or replace function public.evently_admin_decide_schedule_proposal(
  p_proposal_id uuid, p_accept boolean, p_reason text default null
) returns void language plpgsql security definer set search_path = ''
as $$
declare v_proposal public.evently_schedule_proposals%rowtype;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  select * into v_proposal from public.evently_schedule_proposals where id = p_proposal_id for update;
  if not found or v_proposal.proposal_state <> 'pending' then raise exception 'Schedule proposal is no longer pending'; end if;
  if p_accept then
    if v_proposal.proposed_date <> (select reservation_date from public.reservations where id = v_proposal.reservation_id) then
      raise exception 'Date changes require a separately reviewed booking change; this proposal can only update time and resource';
    end if;
    perform public.evently_admin_set_reservation_schedule(
      p_reservation_id => v_proposal.reservation_id,
      p_start_time => v_proposal.proposed_start_time,
      p_end_time => v_proposal.proposed_end_time,
      p_resource_key => v_proposal.proposed_resource_key
    );
  elsif nullif(trim(p_reason), '') is null then raise exception 'A reason is required to decline a schedule proposal'; end if;
  update public.evently_schedule_proposals set proposal_state = case when p_accept then 'accepted' else 'rejected' end,
    decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(p_reason), '') where id = v_proposal.id;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), case when p_accept then 'staff_schedule_accepted' else 'staff_schedule_rejected' end,
      'reservation', v_proposal.reservation_id, coalesce(nullif(trim(p_reason), ''), 'Staff schedule proposal reviewed'));
end;
$$;

create or replace function public.evently_manage_staff_permission(
  p_staff_id uuid, p_permission text, p_granted boolean
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if not exists (select 1 from public.profiles where id = p_staff_id and role = 'staff') then
    raise exception 'Staff account not found';
  end if;
  if p_permission not in ('view_reservations','edit_reservation_details','propose_schedule_changes',
    'view_calendar','view_customer_details','recommend_approval','recommend_rejection','moderate_reviews') then
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

create or replace function public.evently_owner_set_staff_permission_policy(p_permission text, p_allowed boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'owner') then
    raise exception 'Owner access required to configure staff permission policy';
  end if;
  if p_permission not in ('view_reservations','edit_reservation_details','propose_schedule_changes',
    'view_calendar','view_customer_details','recommend_approval','recommend_rejection','moderate_reviews') then
    raise exception 'Unsupported staff permission';
  end if;
  insert into public.evently_staff_permission_policy(permission, allowed_for_admins, updated_by, updated_at)
    values (p_permission, p_allowed, auth.uid(), now())
  on conflict (permission) do update set allowed_for_admins = excluded.allowed_for_admins,
    updated_by = excluded.updated_by, updated_at = now();
  if not p_allowed then
    update public.evently_staff_permissions set granted = false, granted_by = auth.uid(), updated_at = now()
      where permission = p_permission and granted;
  end if;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), 'staff_permission_policy_changed', 'staff_permission', auth.uid(),
      p_permission || ' ' || case when p_allowed then 'enabled' else 'disabled' end || ' for administrators');
end;
$$;

create or replace function public.evently_admin_set_staff_active(p_staff_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  update public.profiles set staff_active = p_active, updated_at = now()
    where id = p_staff_id and role = 'staff';
  if not found then raise exception 'Staff account not found'; end if;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), case when p_active then 'staff_activated' else 'staff_deactivated' end,
      'profile', p_staff_id, case when p_active then 'Staff access activated' else 'Staff access deactivated' end);
end;
$$;

create or replace function public.evently_staff_submit_booking_recommendation(
  p_reservation_id uuid, p_recommendation text, p_reason text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_recommendation_id uuid;
  v_permission text;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if lower(p_recommendation) not in ('approve', 'reject') then raise exception 'Invalid recommendation'; end if;
  v_permission := case when lower(p_recommendation) = 'approve' then 'recommend_approval' else 'recommend_rejection' end;
  if not public.evently_staff_has_permission(v_permission) then raise exception 'This staff permission has not been granted'; end if;
  if not public.evently_staff_can_access_reservation(p_reservation_id) then raise exception 'This reservation is not available to your account'; end if;
  if lower(p_recommendation) = 'reject' and nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required when recommending rejection';
  end if;
  perform 1 from public.reservations where id = p_reservation_id and lower(status::text) = 'pending' for update;
  if not found then raise exception 'Only pending reservations can be recommended'; end if;
  if exists (select 1 from public.evently_booking_recommendations
    where reservation_id = p_reservation_id and review_state = 'awaiting_admin') then
    raise exception 'This reservation already has a recommendation awaiting admin decision';
  end if;
  insert into public.evently_booking_recommendations(reservation_id, staff_id, recommendation, reason, notes)
  values (p_reservation_id, auth.uid(), lower(p_recommendation), nullif(trim(p_reason), ''), nullif(trim(p_notes), ''))
  returning id into v_recommendation_id;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), 'booking_recommendation_submitted', 'reservation', p_reservation_id,
      'Staff recommended ' || lower(p_recommendation));
  return v_recommendation_id;
end;
$$;

create or replace function public.evently_admin_review_booking_recommendation(
  p_recommendation_id uuid, p_decision text, p_reason text default null, p_schedule_verified boolean default false
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_rec public.evently_booking_recommendations%rowtype;
  v_result jsonb;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  select * into v_rec from public.evently_booking_recommendations
    where id = p_recommendation_id for update;
  if not found or v_rec.review_state <> 'awaiting_admin' then
    raise exception 'Recommendation is no longer awaiting a decision';
  end if;
  if p_decision = 'return' then
    update public.evently_booking_recommendations set review_state = 'revision_requested',
      decision_by = auth.uid(), decision_at = now(), decision_note = nullif(trim(p_reason), '') where id = v_rec.id;
  elsif p_decision = 'approve' then
    v_result := public.evently_admin_approve_booking(
      p_reservation_id => v_rec.reservation_id,
      p_schedule_verified => p_schedule_verified
    );
    update public.evently_booking_recommendations set review_state = 'approved',
      decision_by = auth.uid(), decision_at = now(), decision_note = nullif(trim(p_reason), '') where id = v_rec.id;
  elsif p_decision = 'reject' then
    if nullif(trim(p_reason), '') is null then raise exception 'A rejection reason is required'; end if;
    perform public.admin_transition_reservation(
      p_reservation_id => v_rec.reservation_id,
      p_status => 'cancelled',
      p_reason => p_reason
    );
    update public.evently_booking_recommendations set review_state = 'rejected',
      decision_by = auth.uid(), decision_at = now(), decision_note = trim(p_reason) where id = v_rec.id;
  else
    raise exception 'Invalid admin decision';
  end if;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'booking_recommendation_' || p_decision, 'reservation', v_rec.reservation_id,
    coalesce(nullif(trim(p_reason), ''), 'Staff recommendation reviewed'));
  return coalesce(v_result, jsonb_build_object('review_state', case when p_decision = 'return' then 'revision_requested' else p_decision end));
end;
$$;

create or replace function public.evently_review_text_has_profanity(p_text text)
returns boolean language sql immutable set search_path = ''
as $$
  with normalized as (
    select regexp_replace(
      translate(lower(coalesce(p_text, '')), '013457@!$', 'oieastais'),
      '[^a-z]+', ' ', 'g'
    ) as body
  )
  select body ~ '(^| )(fuck|fucking|shit|bullshit|bitch|bastard|asshole|cunt|putangina|putang ina|gago|tanga|bobo|pakyu|puki)( |$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])f[^[:alpha:]]*u[^[:alpha:]]*c[^[:alpha:]]*k([^[:alpha:]]|$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])s[^[:alpha:]]*h[^[:alpha:]]*i[^[:alpha:]]*t([^[:alpha:]]|$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])g[^[:alpha:]]*a[^[:alpha:]]*g[^[:alpha:]]*o([^[:alpha:]]|$)'
    or lower(coalesce(p_text,'')) ~* '(^|[^[:alpha:]])t[^[:alpha:]]*a[^[:alpha:]]*n[^[:alpha:]]*g[^[:alpha:]]*a([^[:alpha:]]|$)'
  from normalized;
$$;

create or replace function public.evently_review_text_needs_moderation(p_text text)
returns boolean language sql immutable set search_path = ''
as $$
  select lower(coalesce(p_text, '')) ~* '(kill[[:space:]]+you|you[[:space:]]+should[[:space:]]+die|go[[:space:]]+die|threaten(ed|ing)?|racial[[:space:]]+slur|homophobic[[:space:]]+slur)';
$$;

create or replace function public.evently_submit_customer_review(
  p_reservation_id uuid, p_rating integer, p_review_text text
) returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_review_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to submit a review'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'customer') then
    raise exception 'Only customer accounts may submit a review';
  end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'Rating must be between 1 and 5'; end if;
  if length(trim(coalesce(p_review_text,''))) < 10 then raise exception 'Write at least 10 characters in your review'; end if;
  if length(p_review_text) > 3000 then raise exception 'Review must be 3000 characters or fewer'; end if;
  if public.evently_review_text_has_profanity(p_review_text) then
    raise exception 'Please edit profanity or abusive wording before submitting your review';
  end if;
  perform 1 from public.reservations
    where id = p_reservation_id and customer_id = auth.uid() and lower(status::text) = 'completed';
  if not found then raise exception 'Only the customer who completed this booking may review it'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_reservation_id::text, 0));
  if exists (select 1 from public.reviews where reservation_id = p_reservation_id and customer_id = auth.uid()) then
    raise exception 'A review has already been submitted for this booking';
  end if;
  insert into public.reviews(customer_id, reservation_id, rating, review_text, moderation_status, moderation_reason, is_published)
  values (auth.uid(), p_reservation_id, p_rating, trim(p_review_text),
    case when public.evently_review_text_needs_moderation(p_review_text) then 'flagged' else 'pending' end,
    case when public.evently_review_text_needs_moderation(p_review_text) then 'Automated flag: potentially abusive phrasing requires manual review' else null end,
    false)
  returning id into v_review_id;
  return v_review_id;
exception when unique_violation then
  raise exception 'A review has already been submitted for this booking';
end;
$$;

create or replace function public.evently_admin_moderate_review(
  p_review_id uuid, p_decision text, p_reason text default null
) returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_evently_admin() and not (p_decision = 'flagged' and public.evently_staff_has_permission('moderate_reviews')) then
    raise exception 'Review moderation access required';
  end if;
  if not public.is_evently_admin() and p_decision <> 'flagged' then
    raise exception 'Staff may flag reviews for administrator oversight but cannot publish or reject them';
  end if;
  if p_decision not in ('approved','rejected','flagged') then raise exception 'Invalid moderation decision'; end if;
  if p_decision <> 'approved' and nullif(trim(p_reason), '') is null then raise exception 'A moderation reason is required'; end if;
  update public.reviews set moderation_status = p_decision,
    is_published = case when public.is_evently_admin() then (p_decision = 'approved') else is_published end,
    moderation_reason = nullif(trim(p_reason), '')
    where id = p_review_id;
  if not found then raise exception 'Review not found'; end if;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), 'review_' || p_decision, 'review', p_review_id, coalesce(nullif(trim(p_reason), ''), 'Review moderated'));
end;
$$;

create or replace function public.evently_record_review_sentiment(
  p_review_id uuid, p_sentiment text, p_confidence numeric, p_model_version text
) returns void language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'Trusted analysis service required';
  end if;
  if p_sentiment not in ('positive','neutral','negative') then raise exception 'Invalid sentiment label'; end if;
  update public.reviews set sentiment_label = p_sentiment,
    sentiment_confidence = case when p_confidence between 0 and 1 then p_confidence else null end,
    sentiment_analyzed_at = now(), sentiment_model_version = p_model_version
    where id = p_review_id;
  if not found then raise exception 'Review not found'; end if;
end;
$$;

create or replace function public.evently_consume_review_analysis_quota(p_user_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_count integer;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'Trusted analysis service required';
  end if;
  insert into public.evently_review_analysis_rate_limits(user_id, window_started_at, request_count)
    values (p_user_id, now(), 1)
  on conflict (user_id) do update set
    request_count = case when public.evently_review_analysis_rate_limits.window_started_at < now() - interval '1 minute'
      then 1 else public.evently_review_analysis_rate_limits.request_count + 1 end,
    window_started_at = case when public.evently_review_analysis_rate_limits.window_started_at < now() - interval '1 minute'
      then now() else public.evently_review_analysis_rate_limits.window_started_at end
  returning request_count into v_count;
  return v_count <= 8;
end;
$$;

drop policy if exists "Staff read permitted reservations" on public.reservations;

drop policy if exists "Staff read permitted customer profiles" on public.profiles;
create policy "Staff read permitted customer profiles" on public.profiles for select to authenticated
  using (role = 'customer' and public.evently_staff_has_permission('view_customer_details'));

drop policy if exists "Staff read own permission grants" on public.evently_staff_permissions;
create policy "Staff read own permission grants" on public.evently_staff_permissions for select to authenticated
  using (staff_id = auth.uid() or public.is_evently_admin());
drop policy if exists "Admins manage staff permission grants" on public.evently_staff_permissions;
create policy "Admins manage staff permission grants" on public.evently_staff_permissions for all to authenticated
  using (public.is_evently_admin()) with check (public.is_evently_admin());
drop policy if exists "Operations read staff permission policy" on public.evently_staff_permission_policy;
create policy "Operations read staff permission policy" on public.evently_staff_permission_policy for select to authenticated
  using (public.is_evently_admin());
drop policy if exists "Owner manages staff permission policy" on public.evently_staff_permission_policy;
create policy "Owner manages staff permission policy" on public.evently_staff_permission_policy for all to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'owner'))
  with check (exists (select 1 from public.profiles where id = auth.uid() and role = 'owner'));

drop policy if exists "Staff and admins read booking recommendations" on public.evently_booking_recommendations;
create policy "Staff and admins read booking recommendations" on public.evently_booking_recommendations for select to authenticated
  using (staff_id = auth.uid() or public.is_evently_admin());

drop policy if exists "Staff and admins read own operational notes" on public.evently_reservation_staff_notes;
create policy "Staff and admins read own operational notes" on public.evently_reservation_staff_notes for select to authenticated
  using (staff_id = auth.uid() or public.is_evently_admin());
drop policy if exists "Staff and admins read schedule proposals" on public.evently_schedule_proposals;
create policy "Staff and admins read schedule proposals" on public.evently_schedule_proposals for select to authenticated
  using (staff_id = auth.uid() or public.is_evently_admin());

-- Browser clients may read these rows under RLS, but all writes go through the
-- SECURITY DEFINER RPCs below so Admin grants remain Owner-policy-gated.
revoke all on public.evently_staff_permissions, public.evently_staff_permission_policy,
  public.evently_booking_recommendations, public.evently_reservation_staff_notes,
  public.evently_schedule_proposals from public, anon, authenticated;
grant select on public.evently_staff_permissions, public.evently_staff_permission_policy,
  public.evently_booking_recommendations, public.evently_reservation_staff_notes,
  public.evently_schedule_proposals to authenticated;

drop policy if exists "Published reviews are public; authors and moderators can read" on public.reviews;
create policy "Published reviews are public; authors and moderators can read" on public.reviews for select
  using (is_published or customer_id = auth.uid() or public.is_evently_admin() or public.evently_staff_has_permission('moderate_reviews'));

revoke insert, update, delete on public.reviews from public, anon, authenticated;
revoke select on public.reviews from public, anon;
grant select on public.reviews to authenticated;
drop policy if exists "Evently restrict review row visibility" on public.reviews;
create policy "Evently restrict review row visibility" on public.reviews as restrictive for select
  using (is_published or customer_id = auth.uid() or public.is_evently_admin() or public.evently_staff_has_permission('moderate_reviews'));

revoke all on function public.evently_staff_has_permission(text) from public;
revoke all on function public.protect_evently_profile_role() from public;
revoke all on function public.evently_guard_customer_reservation_insert() from public;
revoke all on function public.evently_staff_list_reservations() from public;
revoke all on function public.evently_staff_can_access_reservation(uuid) from public;
revoke all on function public.evently_staff_add_reservation_note(uuid,text) from public;
revoke all on function public.evently_staff_propose_reservation_schedule(uuid,date,time,time,text,text) from public;
revoke all on function public.evently_admin_decide_schedule_proposal(uuid,boolean,text) from public;
revoke all on function public.evently_manage_staff_permission(uuid,text,boolean) from public;
revoke all on function public.evently_owner_set_staff_permission_policy(text,boolean) from public;
revoke all on function public.evently_admin_set_staff_active(uuid,boolean) from public;
revoke all on function public.evently_staff_submit_booking_recommendation(uuid,text,text,text) from public;
revoke all on function public.evently_admin_review_booking_recommendation(uuid,text,text,boolean) from public;
grant execute on function public.evently_staff_has_permission(text) to anon, authenticated;
grant execute on function public.evently_staff_list_reservations() to authenticated;
grant execute on function public.evently_staff_can_access_reservation(uuid) to authenticated;
grant execute on function public.evently_staff_add_reservation_note(uuid,text) to authenticated;
grant execute on function public.evently_staff_propose_reservation_schedule(uuid,date,time,time,text,text) to authenticated;
grant execute on function public.evently_admin_decide_schedule_proposal(uuid,boolean,text) to authenticated;
grant execute on function public.evently_manage_staff_permission(uuid,text,boolean) to authenticated;
grant execute on function public.evently_owner_set_staff_permission_policy(text,boolean) to authenticated;
grant execute on function public.evently_admin_set_staff_active(uuid,boolean) to authenticated;
grant execute on function public.evently_staff_submit_booking_recommendation(uuid,text,text,text) to authenticated;
grant execute on function public.evently_admin_review_booking_recommendation(uuid,text,text,boolean) to authenticated;
revoke all on function public.evently_review_text_has_profanity(text) from public;
revoke all on function public.evently_review_text_needs_moderation(text) from public;
revoke all on function public.evently_submit_customer_review(uuid,integer,text) from public;
revoke all on function public.evently_admin_moderate_review(uuid,text,text) from public;
revoke all on function public.evently_record_review_sentiment(uuid,text,numeric,text) from public, anon, authenticated;
revoke all on function public.evently_consume_review_analysis_quota(uuid) from public, anon, authenticated;
grant execute on function public.evently_review_text_has_profanity(text) to authenticated;
grant execute on function public.evently_review_text_needs_moderation(text) to authenticated;
grant execute on function public.evently_submit_customer_review(uuid,integer,text) to authenticated;
grant execute on function public.evently_admin_moderate_review(uuid,text,text) to authenticated;
grant execute on function public.evently_record_review_sentiment(uuid,text,numeric,text) to service_role;
grant execute on function public.evently_consume_review_analysis_quota(uuid) to service_role;

notify pgrst, 'reload schema';
