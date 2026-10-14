-- EVENTLY booking, payment, and administrative workflow support.
-- This migration is additive and preserves existing operational records.

create extension if not exists pgcrypto;

alter table public.packages
  add column if not exists deposit_percentage numeric(5,2);

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'packages_deposit_percentage_range'
      and conrelid = 'public.packages'::regclass
  ) then
    alter table public.packages
      add constraint packages_deposit_percentage_range
      check (deposit_percentage is null or deposit_percentage between 0 and 100)
      not valid;
  end if;
end;
$$;

alter table public.reservations
  add column if not exists client_request_id uuid,
  add column if not exists package_name text,
  add column if not exists package_variant text,
  add column if not exists customer_name text,
  add column if not exists customer_email text,
  add column if not exists customer_phone text,
  add column if not exists selected_menu jsonb not null default '{}'::jsonb,
  add column if not exists selected_addons jsonb not null default '[]'::jsonb,
  add column if not exists cancellation_reason text;

create unique index if not exists reservations_customer_request_unique
  on public.reservations (customer_id, client_request_id)
  where client_request_id is not null;

alter table public.orders
  add column if not exists package_name text,
  add column if not exists selected_menu jsonb not null default '{}'::jsonb,
  add column if not exists selected_addons jsonb not null default '[]'::jsonb,
  add column if not exists cancellation_reason text;

alter table public.payments
  add column if not exists rejection_reason text,
  add column if not exists updated_at timestamptz not null default now();

alter table public.notifications
  add column if not exists entity_type text,
  add column if not exists entity_id uuid,
  add column if not exists dedupe_key text;

create unique index if not exists notifications_dedupe_key_unique
  on public.notifications (dedupe_key)
  where dedupe_key is not null;

create unique index if not exists payments_reference_number_unique
  on public.payments (lower(reference_number))
  where reference_number is not null;

create table if not exists public.addons (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text not null default '',
  price numeric(12,2) not null check (price >= 0),
  compatible_services text[] not null default array['catering']::text[],
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.reservation_addons
  add column if not exists addon_id uuid references public.addons(id),
  add column if not exists name text,
  add column if not exists description text,
  add column if not exists price numeric(12,2);

create table if not exists public.catering_menu_items (
  id uuid primary key default gen_random_uuid(),
  category text not null,
  name text not null,
  is_available boolean not null default true,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (category, name)
);

create table if not exists public.evently_business_settings (
  id boolean primary key default true check (id),
  business_name text not null default 'Venice Catering Services',
  gcash_instructions text,
  bank_transfer_instructions text,
  cash_instructions text,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);

alter table public.evently_business_settings
  add column if not exists gcash_instructions text,
  add column if not exists bank_transfer_instructions text,
  add column if not exists cash_instructions text;

insert into storage.buckets (id, name, public)
values ('payment-proofs', 'payment-proofs', false)
on conflict (id) do update set public = false;

alter table public.addons enable row level security;
alter table public.catering_menu_items enable row level security;
alter table public.evently_business_settings enable row level security;

drop policy if exists "Active addons are readable" on public.addons;
create policy "Active addons are readable" on public.addons for select
using (is_active or public.is_evently_admin());
drop policy if exists "Admins manage addons" on public.addons;
create policy "Admins manage addons" on public.addons for all to authenticated
using (public.is_evently_admin()) with check (public.is_evently_admin());

drop policy if exists "Active menu items are readable" on public.catering_menu_items;
create policy "Active menu items are readable" on public.catering_menu_items for select
using ((is_active and is_available) or public.is_evently_admin());
drop policy if exists "Admins manage menu items" on public.catering_menu_items;
create policy "Admins manage menu items" on public.catering_menu_items for all to authenticated
using (public.is_evently_admin()) with check (public.is_evently_admin());

drop policy if exists "Customers read payment settings" on public.evently_business_settings;
create policy "Customers read payment settings" on public.evently_business_settings for select
to authenticated using (true);
drop policy if exists "Admins manage payment settings" on public.evently_business_settings;
create policy "Admins manage payment settings" on public.evently_business_settings for all
to authenticated using (public.is_evently_admin()) with check (public.is_evently_admin());

drop policy if exists "Customers upload their payment proofs" on storage.objects;
create policy "Customers upload their payment proofs" on storage.objects for insert
to authenticated with check (
  bucket_id = 'payment-proofs'
  and (storage.foldername(name))[1] = auth.uid()::text
);
drop policy if exists "Owners and admins read payment proofs" on storage.objects;
create policy "Owners and admins read payment proofs" on storage.objects for select
to authenticated using (
  bucket_id = 'payment-proofs'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.is_evently_admin()
  )
);
drop policy if exists "Customers remove unsubmitted payment proofs" on storage.objects;
create policy "Customers remove unsubmitted payment proofs" on storage.objects for delete
to authenticated using (
  bucket_id = 'payment-proofs'
  and (storage.foldername(name))[1] = auth.uid()::text
  and not exists (
    select 1 from public.payments where proof_url = storage.objects.name
  )
);

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
  select e.enumlabel into v_value
  from pg_catalog.pg_attribute a
  join pg_catalog.pg_type t on t.oid = a.atttypid
  join pg_catalog.pg_enum e on e.enumtypid = t.oid
  where a.attrelid = p_table
    and a.attname = p_column
    and lower(e.enumlabel) = lower(p_requested)
  limit 1;
  return coalesce(v_value, lower(p_requested));
end;
$$;

create or replace function public.evently_check_availability(
  p_package_id uuid,
  p_reservation_date date
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1
    from public.reservations
    where reservation_date = p_reservation_date
      and package_id = p_package_id
      and lower(status::text) not in ('cancelled', 'rejected')
  );
$$;

create or replace function public.create_evently_reservation(p_booking jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_package public.packages%rowtype;
  v_reservation_id uuid;
  v_order_id uuid;
  v_reservation_code text;
  v_order_code text;
  v_subtotal numeric(12,2);
  v_deposit numeric(12,2);
  v_addon_total numeric(12,2) := 0;
  v_addons jsonb := coalesce(p_booking -> 'addons', '[]'::jsonb);
  v_addon jsonb;
  v_catalog_addon public.addons%rowtype;
  v_guest_count integer;
  v_date date;
  v_request_id uuid;
  v_existing public.reservations%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if coalesce(p_booking ->> 'idempotency_key', '') = '' then raise exception 'An idempotency key is required'; end if;

  v_request_id := (p_booking ->> 'idempotency_key')::uuid;
  select * into v_existing from public.reservations
  where customer_id = auth.uid() and client_request_id = v_request_id;
  if found then
    return jsonb_build_object(
      'reservation_id', v_existing.id,
      'reservation_code', v_existing.reservation_code,
      'subtotal', v_existing.total_amount,
      'deposit_amount', v_existing.deposit_amount,
      'remaining_balance', v_existing.remaining_balance
    );
  end if;

  select * into v_package
  from public.packages
  where id = (p_booking ->> 'package_id')::uuid and is_active
  for share;
  if not found then raise exception 'The selected package is unavailable'; end if;

  v_date := (p_booking ->> 'reservation_date')::date;
  v_guest_count := (p_booking ->> 'guest_count')::integer;
  if v_date < current_date then raise exception 'The reservation date must be in the future'; end if;
  if v_guest_count < 1 then raise exception 'Guest count must be at least one'; end if;
  if nullif(trim(p_booking ->> 'customer_name'), '') is null
     or nullif(trim(p_booking ->> 'customer_phone'), '') is null
     or nullif(trim(p_booking ->> 'customer_email'), '') is null
     or (p_booking ->> 'customer_email') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Complete and valid customer information is required';
  end if;
  if v_package.guest_capacity is not null and v_guest_count > v_package.guest_capacity then
    raise exception 'Guest count exceeds this package capacity';
  end if;
  if lower(v_package.service_type::text) = 'catering'
     and jsonb_object_length(coalesce(p_booking -> 'menu', '{}'::jsonb)) = 0 then
    raise exception 'Catering menu selections are required';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_package.id::text || ':' || v_date::text, 0)
  );
  if not public.evently_check_availability(v_package.id, v_date) then
    raise exception 'The selected date is no longer available';
  end if;

  for v_addon in select value from jsonb_array_elements(v_addons)
  loop
    select * into v_catalog_addon
    from public.addons
    where id = (v_addon ->> 'id')::uuid
      and is_active
      and lower(v_package.service_type::text) = any (
        select lower(value) from unnest(compatible_services) value
      );
    if not found then raise exception 'A selected add-on is unavailable'; end if;
    v_addon_total := v_addon_total + v_catalog_addon.price;
  end loop;

  v_subtotal := v_package.price + v_addon_total;
  v_deposit := round(
    v_subtotal * least(100, greatest(0, coalesce(v_package.deposit_percentage, 0))) / 100,
    2
  );
  v_reservation_code := 'EVT-' || upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 10));

  insert into public.reservations (
    customer_id, client_request_id, package_id, reservation_code, service_type, package_name,
    package_variant, reservation_date, start_time, guest_count, subtotal,
    deposit_amount, total_amount, amount_paid, remaining_balance,
    payment_status, customer_name, customer_email, customer_phone,
    selected_menu, selected_addons, special_requests
  ) values (
    auth.uid(), v_request_id, v_package.id, v_reservation_code, v_package.service_type,
    v_package.name, null, v_date,
    nullif(p_booking ->> 'start_time', '')::time, v_guest_count,
    v_subtotal, v_deposit, v_subtotal, 0, v_subtotal,
    public.evently_status_value('public.reservations', 'payment_status', 'unpaid')::public.payment_status,
    nullif(trim(p_booking ->> 'customer_name'), ''),
    nullif(trim(p_booking ->> 'customer_email'), ''),
    nullif(trim(p_booking ->> 'customer_phone'), ''),
    coalesce(p_booking -> 'menu', '{}'::jsonb), v_addons,
    nullif(trim(p_booking ->> 'special_requests'), '')
  ) returning id into v_reservation_id;

  for v_addon in select value from jsonb_array_elements(v_addons)
  loop
    select * into v_catalog_addon from public.addons where id = (v_addon ->> 'id')::uuid;
    insert into public.reservation_addons (reservation_id, addon_id, name, description, price, quantity)
    values (v_reservation_id, v_catalog_addon.id, v_catalog_addon.name, v_catalog_addon.description, v_catalog_addon.price, 1);
  end loop;

  v_order_code := 'ORD-' || upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 10));
  insert into public.orders (
    customer_id, reservation_id, order_code, package_name, event_date,
    guest_count, total_amount, amount_paid, remaining_balance,
    payment_status, payment_method, selected_menu, selected_addons, special_requests
  ) values (
    auth.uid(), v_reservation_id, v_order_code, v_package.name, v_date,
    v_guest_count, v_subtotal, 0, v_subtotal,
    public.evently_status_value('public.orders', 'payment_status', 'unpaid')::public.payment_status,
    null, coalesce(p_booking -> 'menu', '{}'::jsonb), v_addons,
    nullif(trim(p_booking ->> 'special_requests'), '')
  ) returning id into v_order_id;

  insert into public.notifications (user_id, title, message, type, entity_type, entity_id, dedupe_key)
  values (
    auth.uid(), 'Booking submitted',
    'Your booking ' || v_reservation_code || ' was submitted and is awaiting review.',
    'booking_submitted', 'reservation', v_reservation_id,
    'booking-submitted:' || v_reservation_id
  );

  return jsonb_build_object(
    'reservation_id', v_reservation_id,
    'reservation_code', v_reservation_code,
    'order_id', v_order_id,
    'order_code', v_order_code,
    'subtotal', v_subtotal,
    'deposit_amount', v_deposit,
    'remaining_balance', v_subtotal
  );
exception
  when unique_violation then
    raise exception 'This booking was already submitted or the selected date is no longer available';
end;
$$;

create or replace function public.submit_evently_payment(
  p_reservation_id uuid,
  p_amount numeric,
  p_method text,
  p_reference_number text default null,
  p_proof_url text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment_id uuid;
  v_order_id uuid;
  v_remaining numeric;
  v_method text := lower(trim(p_method));
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  select remaining_balance into v_remaining
  from public.reservations
  where id = p_reservation_id and customer_id = auth.uid()
  for update;
  if not found then raise exception 'Reservation not found'; end if;
  if v_method = 'bank transfer' then v_method := 'bank_transfer'; end if;
  if v_method not in ('gcash', 'bank_transfer', 'cash') then raise exception 'Unsupported payment method'; end if;
  if p_amount <= 0 or p_amount > v_remaining then raise exception 'Payment amount is invalid'; end if;
  if v_method in ('gcash', 'bank_transfer') and (
    nullif(trim(p_reference_number), '') is null or nullif(trim(p_proof_url), '') is null
  ) then raise exception 'A reference number and proof of payment are required'; end if;
  if p_reference_number is not null and exists (
    select 1 from public.payments where lower(reference_number) = lower(trim(p_reference_number))
  ) then raise exception 'This transaction reference was already submitted'; end if;

  select id into v_order_id from public.orders where reservation_id = p_reservation_id limit 1;
  execute format(
    'insert into public.payments (customer_id,reservation_id,order_id,amount,status,method,reference_number,proof_url) values ($1,$2,$3,$4,%L,%L,$5,$6) returning id',
    public.evently_status_value('public.payments', 'status', 'pending'),
    public.evently_status_value('public.payments', 'method', v_method)
  ) into v_payment_id using auth.uid(), p_reservation_id, v_order_id, p_amount, nullif(trim(p_reference_number), ''), p_proof_url;
  return v_payment_id;
end;
$$;

create or replace function public.admin_transition_reservation(
  p_reservation_id uuid,
  p_status text,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer_id uuid;
  v_current text;
  v_target text;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  select customer_id, status::text into v_customer_id, v_current
  from public.reservations where id = p_reservation_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  v_target := public.evently_status_value('public.reservations', 'status', p_status);
  if lower(v_current) = lower(v_target) then return; end if;
  if not (
    (lower(v_current) = 'pending' and lower(v_target) in ('confirmed', 'cancelled'))
    or (lower(v_current) = 'confirmed' and lower(v_target) in ('completed', 'cancelled'))
  ) then raise exception 'Invalid reservation status transition'; end if;
  if lower(v_target) = 'cancelled' and nullif(trim(p_reason), '') is null then
    raise exception 'A cancellation reason is required';
  end if;
  execute format('update public.reservations set status = %L, cancellation_reason = $1, updated_at = now() where id = $2', v_target)
    using case when lower(p_status) in ('cancelled','rejected') then nullif(trim(p_reason), '') end, p_reservation_id;
  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'reservation_status_changed', 'reservation', p_reservation_id, v_current || ' → ' || v_target || coalesce(': ' || nullif(trim(p_reason), ''), ''));
  insert into public.notifications (user_id, title, message, type, entity_type, entity_id, dedupe_key)
  values (v_customer_id, 'Reservation ' || lower(v_target), 'Your reservation is now ' || v_target || '.', 'reservation_status', 'reservation', p_reservation_id, 'reservation-status:' || p_reservation_id || ':' || lower(v_target))
  on conflict (dedupe_key) where dedupe_key is not null do nothing;
end;
$$;

create or replace function public.admin_transition_order(
  p_order_id uuid,
  p_status text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer_id uuid;
  v_current text;
  v_target text;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  select customer_id, status::text into v_customer_id, v_current from public.orders where id = p_order_id for update;
  if not found then raise exception 'Order not found'; end if;
  v_target := public.evently_status_value('public.orders', 'status', p_status);
  if lower(v_current) = lower(v_target) then return; end if;
  if not (
    (lower(v_current) = 'pending' and lower(v_target) in ('confirmed', 'cancelled'))
    or (lower(v_current) = 'confirmed' and lower(v_target) in ('preparing', 'cancelled'))
    or (lower(v_current) = 'preparing' and lower(v_target) in ('ready', 'cancelled'))
    or (lower(v_current) = 'ready' and lower(v_target) in ('completed', 'cancelled'))
  ) then raise exception 'Invalid order status transition'; end if;
  execute format('update public.orders set status = %L, updated_at = now() where id = $1', v_target) using p_order_id;
  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'order_status_changed', 'order', p_order_id, v_current || ' → ' || v_target);
  insert into public.notifications (user_id, title, message, type, entity_type, entity_id, dedupe_key)
  values (v_customer_id, 'Order status updated', 'Your order is now ' || v_target || '.', 'order_status', 'order', p_order_id, 'order-status:' || p_order_id || ':' || lower(v_target))
  on conflict (dedupe_key) where dedupe_key is not null do nothing;
end;
$$;

create or replace function public.admin_review_payment(
  p_payment_id uuid,
  p_decision text,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments%rowtype;
  v_target text;
  v_verified numeric(12,2);
  v_total numeric(12,2);
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if lower(p_decision) not in ('verified', 'rejected') then raise exception 'Invalid payment decision'; end if;
  select * into v_payment from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if lower(v_payment.status::text) <> 'pending' then raise exception 'Only pending payments can be reviewed'; end if;
  if lower(p_decision) = 'rejected' and nullif(trim(p_reason), '') is null then raise exception 'A rejection reason is required'; end if;
  v_target := public.evently_status_value('public.payments', 'status', p_decision);
  execute 'update public.payments set status = $1, rejection_reason = $2, verified_at = $3, verified_by = $4, updated_at = now() where id = $5'
    using v_target, case when lower(p_decision) = 'rejected' then trim(p_reason) end,
      case when lower(p_decision) = 'verified' then now() end,
      case when lower(p_decision) = 'verified' then auth.uid() end, p_payment_id;

  select coalesce(sum(amount), 0) into v_verified
  from public.payments
  where reservation_id = v_payment.reservation_id and lower(status::text) = 'verified';
  select total_amount into v_total from public.reservations where id = v_payment.reservation_id for update;
  update public.reservations set
    amount_paid = v_verified,
    remaining_balance = greatest(v_total - v_verified, 0),
    payment_status = public.evently_status_value('public.reservations', 'payment_status',
      case when v_verified <= 0 then 'unpaid' when v_verified < v_total then 'partial' else 'paid' end)::public.payment_status,
    updated_at = now()
  where id = v_payment.reservation_id;
  update public.orders set
    amount_paid = v_verified,
    remaining_balance = greatest(total_amount - v_verified, 0),
    payment_status = public.evently_status_value('public.orders', 'payment_status',
      case when v_verified <= 0 then 'unpaid' when v_verified < total_amount then 'partial' else 'paid' end)::public.payment_status,
    updated_at = now()
  where id = v_payment.order_id;
  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'payment_' || lower(p_decision), 'payment', p_payment_id, coalesce(nullif(trim(p_reason), ''), 'Payment reviewed'));
  insert into public.notifications (user_id, title, message, type, entity_type, entity_id, dedupe_key)
  values (v_payment.customer_id, 'Payment ' || lower(v_target), 'Your payment has been ' || lower(v_target) || '.', 'payment_status', 'payment', p_payment_id, 'payment-status:' || p_payment_id || ':' || lower(v_target))
  on conflict (dedupe_key) where dedupe_key is not null do nothing;
end;
$$;

revoke all on function public.create_evently_reservation(jsonb) from public;
revoke all on function public.evently_status_value(regclass,text,text) from public;
revoke all on function public.submit_evently_payment(uuid,numeric,text,text,text) from public;
revoke all on function public.admin_transition_reservation(uuid,text,text) from public;
revoke all on function public.admin_transition_order(uuid,text) from public;
revoke all on function public.admin_review_payment(uuid,text,text) from public;
grant execute on function public.evently_check_availability(uuid,date) to anon, authenticated;
grant execute on function public.create_evently_reservation(jsonb) to authenticated;
grant execute on function public.submit_evently_payment(uuid,numeric,text,text,text) to authenticated;
grant execute on function public.admin_transition_reservation(uuid,text,text) to authenticated;
grant execute on function public.admin_transition_order(uuid,text) to authenticated;
grant execute on function public.admin_review_payment(uuid,text,text) to authenticated;

alter table public.reservations enable row level security;
alter table public.orders enable row level security;
alter table public.payments enable row level security;
alter table public.notifications enable row level security;

drop policy if exists "Customers read their reservations" on public.reservations;
create policy "Customers read their reservations" on public.reservations for select to authenticated
using (customer_id = auth.uid() or public.is_evently_admin());
drop policy if exists "Customers read their orders" on public.orders;
create policy "Customers read their orders" on public.orders for select to authenticated
using (customer_id = auth.uid() or public.is_evently_admin());
drop policy if exists "Customers read their payments" on public.payments;
create policy "Customers read their payments" on public.payments for select to authenticated
using (customer_id = auth.uid() or public.is_evently_admin());
drop policy if exists "Customers read their notifications" on public.notifications;
create policy "Customers read their notifications" on public.notifications for select to authenticated
using (user_id = auth.uid() or public.is_evently_admin());
drop policy if exists "Customers update their notifications" on public.notifications;

create or replace function public.mark_evently_notifications_read(p_ids uuid[])
returns void
language sql
security definer
set search_path = ''
as $$
  update public.notifications
  set is_read = true
  where user_id = auth.uid() and id = any(p_ids);
$$;

revoke all on function public.mark_evently_notifications_read(uuid[]) from public;
grant execute on function public.mark_evently_notifications_read(uuid[]) to authenticated;

grant select on public.addons, public.catering_menu_items to anon, authenticated;
grant select, insert, update on public.evently_business_settings to authenticated;
revoke insert, update, delete on public.reservations, public.orders, public.payments, public.notifications from anon, authenticated;
grant update (deposit_percentage) on public.packages to authenticated;

drop policy if exists "Admins configure package deposits" on public.packages;
create policy "Admins configure package deposits" on public.packages for update to authenticated
using (public.is_evently_admin()) with check (public.is_evently_admin());

notify pgrst, 'reload schema';
