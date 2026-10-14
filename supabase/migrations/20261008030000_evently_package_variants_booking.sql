-- Connect the package_variants catalog to atomic reservation creation.
-- Variant prices and capacities are always re-read and validated in this RPC.

alter table public.reservations
  add column if not exists package_variant_id uuid references public.package_variants(id);

create index if not exists reservations_package_variant_id_idx
  on public.reservations (package_variant_id);

alter table public.package_variants enable row level security;

drop policy if exists "Active package variants are readable" on public.package_variants;
create policy "Active package variants are readable"
  on public.package_variants for select
  using (is_active or public.is_evently_admin());

grant select on public.package_variants to anon, authenticated;

create or replace function public.create_evently_reservation(p_booking jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_package public.packages%rowtype;
  v_variant public.package_variants%rowtype;
  v_variant_id uuid;
  v_variant_count integer;
  v_reservation_id uuid;
  v_order_id uuid;
  v_reservation_code text;
  v_order_code text;
  v_subtotal numeric(12,2);
  v_base_price numeric(12,2);
  v_deposit numeric(12,2);
  v_addon_total numeric(12,2) := 0;
  v_addons jsonb := coalesce(p_booking -> 'addons', '[]'::jsonb);
  v_addon_snapshots jsonb := '[]'::jsonb;
  v_addon jsonb;
  v_catalog_addon public.addons%rowtype;
  v_guest_count integer;
  v_guest_capacity integer;
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

  select count(*) into v_variant_count
  from public.package_variants
  where package_id = v_package.id and is_active;

  v_variant_id := nullif(p_booking ->> 'package_variant_id', '')::uuid;
  if v_variant_id is null and v_variant_count > 0 then
    raise exception 'Select an active variant for this package';
  end if;

  if v_variant_id is not null then
    select * into v_variant
    from public.package_variants
    where id = v_variant_id
      and package_id = v_package.id
      and is_active
    for share;
    if not found then raise exception 'The selected package variant is unavailable'; end if;
  end if;

  v_date := (p_booking ->> 'reservation_date')::date;
  v_guest_count := (p_booking ->> 'guest_count')::integer;
  v_guest_capacity := coalesce(v_variant.guest_capacity, v_package.guest_capacity);
  if v_date < current_date then raise exception 'The reservation date must be in the future'; end if;
  if v_guest_count < 1 then raise exception 'Guest count must be at least one'; end if;
  if nullif(trim(p_booking ->> 'customer_name'), '') is null
     or nullif(trim(p_booking ->> 'customer_phone'), '') is null
     or nullif(trim(p_booking ->> 'customer_email'), '') is null
     or (p_booking ->> 'customer_email') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Complete and valid customer information is required';
  end if;
  if v_guest_capacity is not null and v_guest_count > v_guest_capacity then
    raise exception 'Guest count exceeds the selected package variant capacity';
  end if;
  if lower(v_package.service_type::text) = 'catering'
     and jsonb_object_length(coalesce(p_booking -> 'menu', '{}'::jsonb)) = 0 then
    raise exception 'Catering menu selections are required';
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
    v_addon_snapshots := v_addon_snapshots || jsonb_build_array(jsonb_build_object(
      'id', v_catalog_addon.id,
      'name', v_catalog_addon.name,
      'description', v_catalog_addon.description,
      'price', v_catalog_addon.price,
      'quantity', 1
    ));
  end loop;

  v_base_price := coalesce(v_variant.price, v_package.price);
  v_subtotal := v_base_price + v_addon_total;
  v_deposit := round(
    v_subtotal * least(100, greatest(0, coalesce(v_package.deposit_percentage, 0))) / 100,
    2
  );
  v_reservation_code := 'EVT-' || upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 10));

  insert into public.reservations (
    customer_id, client_request_id, package_id, package_variant_id,
    reservation_code, service_type, package_name, package_variant,
    reservation_date, start_time, guest_count, subtotal,
    deposit_amount, total_amount, amount_paid, remaining_balance,
    payment_status, customer_name, customer_email, customer_phone,
    selected_menu, selected_addons, special_requests
  ) values (
    auth.uid(), v_request_id, v_package.id, v_variant_id,
    v_reservation_code, v_package.service_type, v_package.name,
    case when v_variant_id is null then null else v_variant.name end,
    v_date, nullif(p_booking ->> 'start_time', '')::time, v_guest_count,
    v_subtotal, v_deposit, v_subtotal, 0, v_subtotal,
    public.evently_status_value('public.reservations', 'payment_status', 'unpaid')::public.payment_status,
    nullif(trim(p_booking ->> 'customer_name'), ''),
    nullif(trim(p_booking ->> 'customer_email'), ''),
    nullif(trim(p_booking ->> 'customer_phone'), ''),
    coalesce(p_booking -> 'menu', '{}'::jsonb), v_addon_snapshots,
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
    null, coalesce(p_booking -> 'menu', '{}'::jsonb), v_addon_snapshots,
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
    'package_variant_id', v_variant_id,
    'package_variant', case when v_variant_id is null then null else v_variant.name end,
    'subtotal', v_subtotal,
    'deposit_amount', v_deposit,
    'remaining_balance', v_subtotal
  );
exception
  when unique_violation then
    raise exception 'This booking was already submitted or contains duplicate catalog selections';
end;
$$;

revoke all on function public.create_evently_reservation(jsonb) from public;
grant execute on function public.create_evently_reservation(jsonb) to authenticated;

notify pgrst, 'reload schema';
