-- Focused, self-contained recovery for missing EVENTLY Staff Dashboard objects.
-- It restores missing catalog helpers and uses the existing Admin-only workflow RPCs.
-- It preserves profile roles and reservation/payment rows and does not replace
-- existing Owner/Admin booking approval RPC bodies.

begin;

do $preflight$
declare
  v_item record;
  v_signature text;
  v_missing_columns text[] := array[]::text[];
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.reservations') is null
     or to_regclass('public.orders') is null
     or to_regclass('public.admin_activity_logs') is null
     or to_regclass('public.notifications') is null
     or to_regclass('public.packages') is null
     or to_regclass('public.package_variants') is null
     or to_regclass('public.evently_resources') is null then
    raise exception 'EVENTLY prerequisites are missing: profiles, reservations, orders, logs, notifications, packages, package_variants, and evently_resources must exist';
  end if;

  if to_regprocedure('public.evently_staff_role_ready()') is null then
    raise exception 'public.evently_staff_role_ready() is required before Staff Dashboard recovery';
  end if;
  if not exists (
    select 1
    from pg_catalog.pg_attribute attribute
    join pg_catalog.pg_type role_type on role_type.oid = attribute.atttypid
    join pg_catalog.pg_namespace role_schema on role_schema.oid = role_type.typnamespace
    where attribute.attrelid = 'public.profiles'::regclass
      and attribute.attname = 'role'
      and not attribute.attisdropped
      and role_schema.nspname = 'public'
      and role_type.typname = 'user_role'
      and role_type.typtype = 'e'
  ) then
    raise exception 'Expected public.profiles.role to remain the existing public.user_role enum; recovery will not change role types';
  end if;
  if exists (
    select required.label
    from (values ('customer'),('admin'),('owner'),('staff')) as required(label)
    where not exists (
      select 1
      from pg_catalog.pg_enum enum_value
      join pg_catalog.pg_type enum_type on enum_type.oid = enum_value.enumtypid
      join pg_catalog.pg_namespace enum_schema on enum_schema.oid = enum_type.typnamespace
      where enum_schema.nspname = 'public'
        and enum_type.typname = 'user_role'
        and enum_value.enumlabel = required.label
    )
  ) then
    raise exception 'public.user_role must already contain customer, admin, owner, and staff labels';
  end if;
  if public.evently_staff_role_ready() is distinct from true then
    raise exception 'evently_staff_role_ready() must return true before installing the Staff Dashboard objects';
  end if;

  foreach v_signature in array array[
    'public.is_evently_admin()',
    'public.evently_admin_set_reservation_schedule(uuid,time,time,text)',
    'public.evently_admin_approve_booking(uuid,boolean)',
    'public.admin_transition_reservation(uuid,text,text)'
  ] loop
    if to_regprocedure(v_signature) is null then
      raise exception 'Required existing EVENTLY dependency is missing: %', v_signature;
    end if;
  end loop;

  if pg_catalog.pg_get_functiondef(to_regprocedure('public.is_evently_admin()'))
       not ilike '%owner%' or pg_catalog.pg_get_functiondef(to_regprocedure('public.is_evently_admin()'))
       not ilike '%admin%' then
    raise exception 'Existing is_evently_admin() does not show both Owner and Admin role checks; review before recovery';
  end if;

  if pg_catalog.pg_get_functiondef(to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)'))
       not ilike '%is_evently_admin%' or pg_catalog.pg_get_functiondef(to_regprocedure('public.admin_transition_reservation(uuid,text,text)'))
       not ilike '%is_evently_admin%' then
    raise exception 'Existing final booking RPCs must enforce is_evently_admin(); review them before recovery';
  end if;

  if pg_catalog.pg_get_functiondef(to_regprocedure('public.evently_admin_set_reservation_schedule(uuid,time,time,text)'))
       not ilike '%is_evently_admin%' then
    raise exception 'Existing reservation schedule RPC must enforce is_evently_admin(); review it before recovery';
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
    raise exception 'Existing workflow RPC parameter names do not match the recovery calls';
  end if;

  if pg_catalog.pg_get_function_result(to_regprocedure('public.evently_admin_set_reservation_schedule(uuid,time,time,text)')) <> 'void'
     or pg_catalog.pg_get_function_result(to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)')) <> 'jsonb'
     or pg_catalog.pg_get_function_result(to_regprocedure('public.admin_transition_reservation(uuid,text,text)')) <> 'void' then
    raise exception 'Existing workflow RPC return types differ from the recovery contract';
  end if;

  if not has_function_privilege('authenticated', to_regprocedure('public.evently_admin_set_reservation_schedule(uuid,time,time,text)'), 'EXECUTE')
     or not has_function_privilege('authenticated', to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)'), 'EXECUTE')
     or not has_function_privilege('authenticated', to_regprocedure('public.admin_transition_reservation(uuid,text,text)'), 'EXECUTE') then
    raise exception 'Authenticated must have EXECUTE on existing Owner/Admin-guarded workflow RPCs';
  end if;

  if has_function_privilege('anon', to_regprocedure('public.evently_admin_set_reservation_schedule(uuid,time,time,text)'), 'EXECUTE')
     or has_function_privilege('anon', to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)'), 'EXECUTE')
     or has_function_privilege('anon', to_regprocedure('public.admin_transition_reservation(uuid,text,text)'), 'EXECUTE') then
    raise exception 'Anonymous users must not have EXECUTE on booking decision/schedule RPCs';
  end if;

  for v_item in
    select * from (values
      ('profiles', 'id'),
      ('profiles', 'role'),
      ('profiles', 'full_name'),
      ('profiles', 'email'),
      ('profiles', 'mobile_number'),
      ('profiles', 'updated_at'),
      ('reservations', 'id'),
      ('reservations', 'reservation_code'),
      ('reservations', 'customer_id'),
      ('reservations', 'service_type'),
      ('reservations', 'package_id'),
      ('reservations', 'package_variant'),
      ('reservations', 'reservation_date'),
      ('reservations', 'start_time'),
      ('reservations', 'end_time'),
      ('reservations', 'resource_key'),
      ('reservations', 'status'),
      ('reservations', 'guest_count'),
      ('reservations', 'special_requests'),
      ('reservations', 'created_at'),
      ('reservations', 'updated_at'),
      ('reservations', 'package_variant_id'),
      ('orders', 'id'),
      ('orders', 'reservation_id'),
      ('orders', 'package_id'),
      ('orders', 'order_code'),
      ('orders', 'event_date'),
      ('orders', 'guest_count'),
      ('orders', 'created_at'),
      ('packages', 'id'),
      ('packages', 'name'),
      ('package_variants', 'id'),
      ('package_variants', 'package_id'),
      ('evently_resources', 'resource_key'),
      ('evently_resources', 'resource_name'),
      ('evently_resources', 'is_active'),
      ('admin_activity_logs', 'admin_id'),
      ('admin_activity_logs', 'action'),
      ('admin_activity_logs', 'entity_type'),
      ('admin_activity_logs', 'entity_id'),
      ('admin_activity_logs', 'description'),
      ('notifications', 'user_id'),
      ('notifications', 'id'),
      ('notifications', 'title'),
      ('notifications', 'message'),
      ('notifications', 'type'),
      ('notifications', 'is_read'),
      ('evently_staff_permissions', 'staff_id'),
      ('evently_staff_permissions', 'permission'),
      ('evently_staff_permissions', 'granted'),
      ('evently_staff_permissions', 'granted_by'),
      ('evently_staff_permissions', 'updated_at'),
      ('evently_booking_recommendations', 'id'),
      ('evently_booking_recommendations', 'reservation_id'),
      ('evently_booking_recommendations', 'staff_id'),
      ('evently_booking_recommendations', 'recommendation'),
      ('evently_booking_recommendations', 'reason'),
      ('evently_booking_recommendations', 'notes'),
      ('evently_booking_recommendations', 'review_state'),
      ('evently_booking_recommendations', 'decision_by'),
      ('evently_booking_recommendations', 'decision_at'),
      ('evently_booking_recommendations', 'decision_note'),
      ('evently_booking_recommendations', 'created_at'),
      ('evently_staff_permission_policy', 'permission'),
      ('evently_staff_permission_policy', 'allowed_for_admins'),
      ('evently_staff_permission_policy', 'updated_by'),
      ('evently_staff_permission_policy', 'updated_at'),
      ('evently_reservation_staff_notes', 'id'),
      ('evently_reservation_staff_notes', 'reservation_id'),
      ('evently_reservation_staff_notes', 'staff_id'),
      ('evently_reservation_staff_notes', 'note'),
      ('evently_reservation_staff_notes', 'created_at'),
      ('evently_schedule_proposals', 'id'),
      ('evently_schedule_proposals', 'reservation_id'),
      ('evently_schedule_proposals', 'staff_id'),
      ('evently_schedule_proposals', 'proposed_date'),
      ('evently_schedule_proposals', 'proposed_start_time'),
      ('evently_schedule_proposals', 'proposed_end_time'),
      ('evently_schedule_proposals', 'proposed_resource_key'),
      ('evently_schedule_proposals', 'note'),
      ('evently_schedule_proposals', 'proposal_state'),
      ('evently_schedule_proposals', 'decided_by'),
      ('evently_schedule_proposals', 'decided_at'),
      ('evently_schedule_proposals', 'decision_note'),
      ('evently_schedule_proposals', 'created_at')
    ) as required(table_name, column_name)
  loop
    if to_regclass(format('public.%I', v_item.table_name)) is null
       and v_item.table_name in (
         'evently_staff_permissions','evently_staff_permission_policy','evently_booking_recommendations',
         'evently_reservation_staff_notes','evently_schedule_proposals'
       ) then
      continue;
    end if;
    if not exists (
      select 1
      from pg_catalog.pg_attribute attribute
      where attribute.attrelid = to_regclass(format('public.%I', v_item.table_name))
        and attribute.attname = v_item.column_name
        and not attribute.attisdropped
    ) then
      v_missing_columns := array_append(v_missing_columns, format('public.%s.%s', v_item.table_name, v_item.column_name));
    end if;
  end loop;

  if cardinality(v_missing_columns) > 0 then
    raise exception 'Existing EVENTLY schema is incompatible; missing required columns: %', array_to_string(v_missing_columns, ', ');
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_attribute attribute
    where attribute.attrelid = 'public.orders'::regclass
      and attribute.attname in ('order_status', 'status')
      and not attribute.attisdropped
  ) then
    raise exception 'Existing orders table must have order_status or status';
  end if;

end;
$preflight$;

-- The live database is missing this small catalog helper from the earlier
-- workflow migration. Reinstall the same read-only implementation so existing
-- SECURITY DEFINER workflow RPCs and the staff orders RPC can resolve aliases.
create or replace function public.evently_existing_column(
  p_table regclass,
  p_candidates text[]
) returns text
language sql
stable
security definer
set search_path = ''
as $$
  select candidate.name
  from unnest(p_candidates) with ordinality candidate(name, position)
  join pg_catalog.pg_attribute attribute
    on attribute.attrelid = p_table
   and attribute.attname = candidate.name
   and not attribute.attisdropped
  order by candidate.position
  limit 1;
$$;
revoke all on function public.evently_existing_column(regclass, text[]) from public;

-- Likewise restore the enum-aware value helper used by the existing
-- Owner/Admin reservation and order transition functions.
create or replace function public.evently_status_value(
  p_table regclass,
  p_column text,
  p_requested text
) returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_value text;
begin
  select enum_value.enumlabel into v_value
  from pg_catalog.pg_attribute attribute
  join pg_catalog.pg_type column_type on column_type.oid = attribute.atttypid
  join pg_catalog.pg_enum enum_value on enum_value.enumtypid = column_type.oid
  where attribute.attrelid = p_table
    and attribute.attname = p_column
    and lower(enum_value.enumlabel) = lower(p_requested)
  limit 1;
  return coalesce(v_value, lower(p_requested));
end;
$$;
revoke all on function public.evently_status_value(regclass, text, text) from public;

-- The supplied live schema predates these display/scheduling/notification
-- fields. Add them without rewriting reservation, order, notification, or
-- payment rows; existing Owner/Admin workflow RPC bodies remain untouched.
alter table public.packages
  add column if not exists schedule_mode text not null default 'admin_assign',
  add column if not exists fixed_start_time time,
  add column if not exists fixed_end_time time,
  add column if not exists duration_minutes integer,
  add column if not exists operating_start_time time,
  add column if not exists operating_end_time time,
  add column if not exists resource_key text;

alter table public.package_variants
  add column if not exists schedule_mode text,
  add column if not exists fixed_start_time time,
  add column if not exists fixed_end_time time,
  add column if not exists duration_minutes integer,
  add column if not exists operating_start_time time,
  add column if not exists operating_end_time time,
  add column if not exists resource_key text;

alter table public.reservations
  add column if not exists customer_name text,
  add column if not exists customer_email text,
  add column if not exists customer_phone text,
  add column if not exists package_name text,
  add column if not exists resource_name text,
  add column if not exists schedule_mode text not null default 'admin_assign';

alter table public.orders
  add column if not exists package_name text,
  add column if not exists cancellation_reason text;

alter table public.notifications
  add column if not exists entity_type text,
  add column if not exists entity_id uuid,
  add column if not exists dedupe_key text;

do $notification_index_preflight$
begin
  if to_regclass('public.notifications_dedupe_key_unique') is not null
     and not exists (
       select 1 from pg_catalog.pg_index index_info
       where index_info.indrelid = 'public.notifications'::regclass
         and index_info.indexrelid = to_regclass('public.notifications_dedupe_key_unique')
         and index_info.indisunique
         and index_info.indpred is not null
         and pg_catalog.pg_get_indexdef(index_info.indexrelid) ilike '%(dedupe_key)%'
     ) then
    raise exception 'notifications_dedupe_key_unique exists but is not the expected partial unique index; inspect it before recovery';
  end if;

  if exists (
    select dedupe_key
    from public.notifications
    where dedupe_key is not null
    group by dedupe_key
    having count(*) > 1
  ) then
    raise exception 'notifications contains duplicate non-null dedupe_key values; review them before creating the staff notification index';
  end if;
end;
$notification_index_preflight$;

create unique index if not exists notifications_dedupe_key_unique
  on public.notifications (dedupe_key)
  where dedupe_key is not null;

-- Staff can read their own notifications; Admin/Owner can read all. The
-- restrictive policy prevents any older permissive policy from widening that.
alter table public.notifications enable row level security;
drop policy if exists "Customers read their notifications" on public.notifications;
create policy "Customers read their notifications"
  on public.notifications for select to authenticated
  using (user_id = auth.uid() or public.is_evently_admin());
drop policy if exists "Evently restrict notification visibility" on public.notifications;
create policy "Evently restrict notification visibility"
  on public.notifications as restrictive for select to authenticated
  using (user_id = auth.uid() or public.is_evently_admin());
revoke insert, update, delete on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;

-- Add only the staff activation flag; profiles.role remains the existing enum.
alter table public.profiles
  add column if not exists staff_active boolean not null default true;

create table if not exists public.evently_staff_permission_policy (
  permission text primary key check (permission in (
    'view_reservations','edit_reservation_details','propose_schedule_changes',
    'view_calendar','view_customer_details','recommend_approval','recommend_rejection',
    'moderate_reviews','view_orders'
  )),
  allowed_for_admins boolean not null default false,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

-- Install the current permission set, including the newer view_orders
-- capability. No staff-specific permission grants are created.
create table if not exists public.evently_staff_permissions (
  staff_id uuid not null references public.profiles(id) on delete cascade,
  permission text not null check (permission in (
    'view_reservations', 'edit_reservation_details', 'propose_schedule_changes',
    'view_calendar', 'view_customer_details', 'recommend_approval',
    'recommend_rejection', 'moderate_reviews', 'view_orders'
  )),
  granted boolean not null default false,
  granted_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  primary key (staff_id, permission)
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
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.evently_booking_recommendations
  add column if not exists updated_at timestamptz not null default now();

create index if not exists evently_booking_recommendations_latest_idx
  on public.evently_booking_recommendations (reservation_id, created_at desc);
create index if not exists evently_staff_recommendations_staff_latest_idx
  on public.evently_booking_recommendations (staff_id, created_at desc);
create index if not exists evently_staff_reservations_status_date_idx
  on public.reservations (status, reservation_date);

-- Match the current 20261013140000 migration's allowed permission set.
-- The new 'view_orders' policy is disabled by default; this does not grant it.
do $permission_checks$
begin
  alter table public.evently_staff_permissions
    drop constraint if exists evently_staff_permissions_permission_check;
  alter table public.evently_staff_permissions
    add constraint evently_staff_permissions_permission_check check (permission in (
      'view_reservations','edit_reservation_details','propose_schedule_changes',
      'view_calendar','view_customer_details','recommend_approval','recommend_rejection',
      'moderate_reviews','view_orders'
    ));
end;
$permission_checks$;

alter table public.evently_staff_permission_policy
  drop constraint if exists evently_staff_permission_policy_permission_check;
alter table public.evently_staff_permission_policy
  add constraint evently_staff_permission_policy_permission_check check (permission in (
    'view_reservations','edit_reservation_details','propose_schedule_changes',
    'view_calendar','view_customer_details','recommend_approval','recommend_rejection',
    'moderate_reviews','view_orders'
  ));

insert into public.evently_staff_permission_policy(permission, allowed_for_admins)
values
  ('view_reservations',false), ('edit_reservation_details',false),
  ('propose_schedule_changes',false), ('view_calendar',false),
  ('view_customer_details',false), ('recommend_approval',false),
  ('recommend_rejection',false), ('moderate_reviews',false), ('view_orders',false)
on conflict (permission) do nothing;

alter table public.evently_staff_permissions enable row level security;
alter table public.evently_reservation_staff_notes enable row level security;
alter table public.evently_schedule_proposals enable row level security;
alter table public.evently_booking_recommendations enable row level security;
alter table public.evently_staff_permission_policy enable row level security;

drop policy if exists "Staff read own permission grants" on public.evently_staff_permissions;
create policy "Staff read own permission grants"
  on public.evently_staff_permissions for select to authenticated
  using (staff_id = auth.uid() or public.is_evently_admin());

drop policy if exists "Admins manage staff permission grants" on public.evently_staff_permissions;
create policy "Admins manage staff permission grants"
  on public.evently_staff_permissions for all to authenticated
  using (public.is_evently_admin()) with check (public.is_evently_admin());

drop policy if exists "Staff and admins read booking recommendations" on public.evently_booking_recommendations;
create policy "Staff and admins read booking recommendations"
  on public.evently_booking_recommendations for select to authenticated
  using (staff_id = auth.uid() or public.is_evently_admin());

drop policy if exists "Staff and admins read own operational notes" on public.evently_reservation_staff_notes;
create policy "Staff and admins read own operational notes"
  on public.evently_reservation_staff_notes for select to authenticated
  using (staff_id = auth.uid() or public.is_evently_admin());

drop policy if exists "Staff and admins read schedule proposals" on public.evently_schedule_proposals;
create policy "Staff and admins read schedule proposals"
  on public.evently_schedule_proposals for select to authenticated
  using (staff_id = auth.uid() or public.is_evently_admin());

drop policy if exists "Operations read staff permission policy" on public.evently_staff_permission_policy;
create policy "Operations read staff permission policy"
  on public.evently_staff_permission_policy for select to authenticated
  using (public.is_evently_admin());

drop policy if exists "Owner manages staff permission policy" on public.evently_staff_permission_policy;
create policy "Owner manages staff permission policy"
  on public.evently_staff_permission_policy for all to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'owner'))
  with check (exists (select 1 from public.profiles where id = auth.uid() and role = 'owner'));

-- No direct browser writes: mutations go through the role-checked RPCs below.
revoke all on public.evently_staff_permissions, public.evently_booking_recommendations,
  public.evently_staff_permission_policy, public.evently_reservation_staff_notes,
  public.evently_schedule_proposals from public, anon, authenticated;
grant select on public.evently_staff_permissions, public.evently_booking_recommendations,
  public.evently_staff_permission_policy, public.evently_reservation_staff_notes,
  public.evently_schedule_proposals to authenticated;

-- Keep the existing Admin/Owner permission-management path functional for the
-- new view_orders capability. Owner policy remains the gate for Admin grants.
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

create or replace function public.evently_owner_set_staff_permission_policy(p_permission text, p_allowed boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'owner') then
    raise exception 'Owner access required to configure staff permission policy';
  end if;
  if p_permission not in ('view_reservations','edit_reservation_details','propose_schedule_changes',
    'view_calendar','view_customer_details','recommend_approval','recommend_rejection','moderate_reviews','view_orders') then
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

create or replace function public.evently_staff_can_access_reservation(p_reservation_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select (public.evently_staff_has_permission('view_reservations')
       or public.evently_staff_has_permission('view_calendar'))
    and exists (select 1 from public.reservations where id = p_reservation_id);
$$;

create or replace function public.evently_staff_add_reservation_note(p_reservation_id uuid, p_note text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if not public.evently_staff_has_permission('edit_reservation_details') then
    raise exception 'Reservation edit permission has not been granted';
  end if;
  if not public.evently_staff_can_access_reservation(p_reservation_id) then
    raise exception 'This reservation is not available to your account';
  end if;
  if length(trim(coalesce(p_note,''))) not between 1 and 3000 then
    raise exception 'Note must contain 1 to 3000 characters';
  end if;
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
  if not public.evently_staff_has_permission('propose_schedule_changes') then
    raise exception 'Schedule proposal permission has not been granted';
  end if;
  if not public.evently_staff_can_access_reservation(p_reservation_id) then
    raise exception 'This reservation is not available to your account';
  end if;
  if p_date < current_date or p_start_time is null or p_end_time is null or p_start_time = p_end_time then
    raise exception 'A future date and distinct schedule times are required';
  end if;
  if not exists (
    select 1 from public.reservations
    where id = p_reservation_id and lower(status::text) = 'pending'
  ) then
    raise exception 'Only pending reservations may receive schedule proposals';
  end if;
  if p_date <> (select reservation_date from public.reservations where id = p_reservation_id) then
    raise exception 'Date changes require a separate admin-reviewed booking change';
  end if;
  if nullif(trim(p_resource_key), '') is null then
    raise exception 'A configured resource is required';
  end if;
  if not exists (
    select 1 from public.evently_resources
    where lower(resource_key) = lower(trim(p_resource_key)) and is_active
  ) then
    raise exception 'Select an active configured resource';
  end if;
  insert into public.evently_schedule_proposals(
    reservation_id, staff_id, proposed_date, proposed_start_time, proposed_end_time, proposed_resource_key, note
  ) values (
    p_reservation_id, auth.uid(), p_date, p_start_time, p_end_time,
    nullif(trim(p_resource_key), ''), nullif(trim(p_note), '')
  ) returning id into v_id;
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
  select * into v_proposal
  from public.evently_schedule_proposals where id = p_proposal_id for update;
  if not found or v_proposal.proposal_state <> 'pending' then
    raise exception 'Schedule proposal is no longer pending';
  end if;
  if p_accept then
    if v_proposal.proposed_date <> (
      select reservation_date from public.reservations where id = v_proposal.reservation_id
    ) then
      raise exception 'Date changes require a separately reviewed booking change';
    end if;
    perform public.evently_admin_set_reservation_schedule(
      p_reservation_id => v_proposal.reservation_id,
      p_start_time => v_proposal.proposed_start_time,
      p_end_time => v_proposal.proposed_end_time,
      p_resource_key => v_proposal.proposed_resource_key
    );
  elsif nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required to decline a schedule proposal';
  end if;
  update public.evently_schedule_proposals
  set proposal_state = case when p_accept then 'accepted' else 'rejected' end,
      decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(p_reason), '')
  where id = v_proposal.id;
  insert into public.admin_activity_logs(admin_id, action, entity_type, entity_id, description)
    values (auth.uid(), case when p_accept then 'staff_schedule_accepted' else 'staff_schedule_rejected' end,
      'reservation', v_proposal.reservation_id, coalesce(nullif(trim(p_reason), ''), 'Staff schedule proposal reviewed'));
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
    'customer_name', case when v_customer_details then coalesce(nullif(r.customer_name, ''), customer_profile.full_name) else null end,
    'customer_email', case when v_customer_details then coalesce(nullif(r.customer_email, ''), customer_profile.email) else null end,
    'customer_phone', case when v_customer_details then coalesce(nullif(r.customer_phone, ''), customer_profile.mobile_number) else null end,
    'service_type', r.service_type, 'package_id', r.package_id,
    'package_name', coalesce(nullif(r.package_name, ''), package.name), 'package_variant', r.package_variant,
    'reservation_date', r.reservation_date, 'start_time', r.start_time, 'end_time', r.end_time,
    'resource_key', r.resource_key, 'resource_name', coalesce(nullif(r.resource_name, ''), resource.resource_name), 'status', r.status,
    'guest_count', r.guest_count, 'special_requests', r.special_requests, 'created_at', r.created_at,
    'staff_recommendation', recommendation.recommendation,
    'staff_recommendation_status', recommendation.review_state,
    'staff_recommendation_staff_id', recommendation.staff_id
  ) from public.reservations r
  left join public.profiles customer_profile on customer_profile.id = r.customer_id
  left join public.packages package on package.id = r.package_id
  left join public.evently_resources resource on resource.resource_key = r.resource_key
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
  select count(*) into v_submitted
  from public.evently_booking_recommendations where staff_id = auth.uid();
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
       ''customer_name'', case when $1 then coalesce(nullif(reservation.customer_name, ''''), customer_profile.full_name) else null end,
       ''service_type'', reservation.service_type,
       ''package_name'', coalesce(nullif(orders.package_name, ''''), nullif(reservation.package_name, ''''), package.name),
      ''event_date'', orders.event_date,
      ''start_time'', reservation.start_time,
      ''end_time'', reservation.end_time,
       ''resource_name'', coalesce(nullif(reservation.resource_name, ''''), resource.resource_name),
      ''guest_count'', orders.guest_count,
      ''status'', orders.%I,
      ''created_at'', orders.created_at
    ) from public.orders orders
     left join public.reservations reservation on reservation.id = orders.reservation_id
     left join public.profiles customer_profile on customer_profile.id = reservation.customer_id
     left join public.packages package on package.id = coalesce(orders.package_id, reservation.package_id)
     left join public.evently_resources resource on resource.resource_key = reservation.resource_key
    order by orders.event_date desc nulls last, orders.created_at desc
    limit 500',
    v_status_column
  );
  return query execute v_sql using v_customer_details;
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

create or replace function public.evently_admin_review_booking_recommendation(
  p_recommendation_id uuid, p_decision text, p_reason text default null, p_schedule_verified boolean default false
) returns jsonb language plpgsql security definer set search_path = ''
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
create trigger evently_notify_booking_recommendation
  after insert or update on public.evently_booking_recommendations
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

-- Keep recommendation updated_at current without changing reservation status.
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

-- Latest readiness contract from 20261013140000; it reports actual object
-- presence and never creates or grants staff permissions.
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

revoke all on function public.evently_staff_has_permission(text) from public;
revoke all on function public.evently_staff_can_access_reservation(uuid) from public;
revoke all on function public.evently_staff_add_reservation_note(uuid,text) from public;
revoke all on function public.evently_staff_propose_reservation_schedule(uuid,date,time,time,text,text) from public;
revoke all on function public.evently_admin_decide_schedule_proposal(uuid,boolean,text) from public;
revoke all on function public.evently_admin_set_staff_active(uuid,boolean) from public;
revoke all on function public.evently_manage_staff_permission(uuid,text,boolean) from public;
revoke all on function public.evently_owner_set_staff_permission_policy(text,boolean) from public;
revoke all on function public.evently_staff_list_reservations() from public;
revoke all on function public.evently_staff_dashboard_stats() from public;
revoke all on function public.evently_staff_list_orders() from public;
revoke all on function public.evently_staff_submit_booking_recommendation(uuid,text,text,text) from public;
revoke all on function public.evently_admin_review_booking_recommendation(uuid,text,text,boolean) from public;
revoke all on function public.evently_touch_recommendation_updated_at() from public;
revoke all on function public.evently_notify_staff_reservation_created() from public;
revoke all on function public.evently_notify_staff_schedule_change() from public;
revoke all on function public.evently_notify_staff_booking_confirmation() from public;
revoke all on function public.evently_notify_booking_recommendation() from public;
revoke all on function public.evently_notify_schedule_proposal() from public;
revoke all on function public.evently_staff_permissions_ready() from public;

grant execute on function public.evently_staff_has_permission(text) to anon, authenticated;
grant execute on function public.evently_staff_can_access_reservation(uuid) to authenticated;
grant execute on function public.evently_staff_add_reservation_note(uuid,text) to authenticated;
grant execute on function public.evently_staff_propose_reservation_schedule(uuid,date,time,time,text,text) to authenticated;
grant execute on function public.evently_admin_decide_schedule_proposal(uuid,boolean,text) to authenticated;
grant execute on function public.evently_admin_set_staff_active(uuid,boolean) to authenticated;
grant execute on function public.evently_manage_staff_permission(uuid,text,boolean) to authenticated;
grant execute on function public.evently_owner_set_staff_permission_policy(text,boolean) to authenticated;
grant execute on function public.evently_staff_list_reservations() to authenticated;
grant execute on function public.evently_staff_dashboard_stats() to authenticated;
grant execute on function public.evently_staff_list_orders() to authenticated;
grant execute on function public.evently_staff_submit_booking_recommendation(uuid,text,text,text) to authenticated;
grant execute on function public.evently_admin_review_booking_recommendation(uuid,text,text,boolean) to authenticated;
grant execute on function public.evently_staff_permissions_ready() to authenticated, service_role;

commit;

notify pgrst, 'reload schema';

select public.evently_staff_permissions_ready() as staff_dashboard_ready;
