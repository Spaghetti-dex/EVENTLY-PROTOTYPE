-- Keep reservation, order, payment, audit, and notification updates atomic.
-- Every entry point verifies the caller through is_evently_admin().

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
  v_order_target text;
  v_status_column text;
  v_order_status_column text;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;

  v_status_column := public.evently_existing_column(
    'public.reservations',
    array['booking_status', 'reservation_status', 'status']
  );
  if v_status_column is null then raise exception 'Reservation status column is missing'; end if;
  execute format(
    'select customer_id, %I::text from public.reservations where id = $1 for update',
    v_status_column
  ) into v_customer_id, v_current using p_reservation_id;
  if not found then raise exception 'Reservation not found'; end if;

  v_target := public.evently_status_value('public.reservations', v_status_column, p_status);
  if lower(v_current) = lower(v_target) then return; end if;
  if not (
    (lower(v_current) = 'pending' and lower(v_target) in ('confirmed', 'cancelled'))
    or (lower(v_current) = 'confirmed' and lower(v_target) in ('completed', 'cancelled'))
  ) then
    raise exception 'Invalid reservation status transition from % to %', v_current, v_target;
  end if;
  if lower(v_target) = 'cancelled' and nullif(trim(p_reason), '') is null then
    raise exception 'A booking rejection or cancellation reason is required';
  end if;

  execute format(
    'update public.reservations set %I = %L, cancellation_reason = $1, updated_at = now() where id = $2',
    v_status_column,
    v_target
  ) using case when lower(v_target) = 'cancelled' then trim(p_reason) end, p_reservation_id;

  if lower(v_target) = 'confirmed'
     and exists (
       select 1 from pg_catalog.pg_attribute
       where attrelid = 'public.reservations'::regclass and attname = 'approved_by' and not attisdropped
     )
     and exists (
       select 1 from pg_catalog.pg_attribute
       where attrelid = 'public.reservations'::regclass and attname = 'approved_at' and not attisdropped
     ) then
    execute 'update public.reservations set approved_by = $1, approved_at = now() where id = $2'
      using auth.uid(), p_reservation_id;
  end if;
  if lower(v_target) = 'cancelled'
     and exists (
       select 1 from pg_catalog.pg_attribute
       where attrelid = 'public.reservations'::regclass and attname = 'rejection_reason' and not attisdropped
     ) then
    execute 'update public.reservations set rejection_reason = $1 where id = $2'
      using trim(p_reason), p_reservation_id;
  end if;

  if lower(v_target) = 'confirmed' then
    v_order_status_column := public.evently_existing_column('public.orders', array['order_status', 'status']);
    if v_order_status_column is null then raise exception 'Order status column is missing'; end if;
    v_order_target := public.evently_status_value('public.orders', v_order_status_column, lower(v_target));
    execute format(
      'update public.orders set %I = %L, updated_at = now()
       where reservation_id = $1
         and lower(%I::text) = ''pending''',
      v_order_status_column,
      v_order_target,
      v_order_status_column
    ) using p_reservation_id;
  elsif lower(v_target) = 'cancelled' then
    v_order_status_column := public.evently_existing_column('public.orders', array['order_status', 'status']);
    if v_order_status_column is null then raise exception 'Order status column is missing'; end if;
    v_order_target := public.evently_status_value('public.orders', v_order_status_column, lower(v_target));
    execute format(
      'update public.orders set %I = %L, cancellation_reason = $1, updated_at = now()
       where reservation_id = $2
         and lower(%I::text) not in (''completed'', ''cancelled'')',
      v_order_status_column,
      v_order_target,
      v_order_status_column
    ) using trim(p_reason), p_reservation_id;
  end if;

  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (
    auth.uid(),
    'reservation_status_changed',
    'reservation',
    p_reservation_id,
    v_current || ' → ' || v_target || coalesce(': ' || nullif(trim(p_reason), ''), '')
  );

  insert into public.notifications (user_id, title, message, type, entity_type, entity_id, dedupe_key)
  values (
    v_customer_id,
    'Reservation ' || lower(v_target),
    'Your reservation is now ' || lower(v_target) ||
      case when nullif(trim(p_reason), '') is null then '.' else '. Reason: ' || trim(p_reason) end,
    'reservation_status',
    'reservation',
    p_reservation_id,
    'reservation-status:' || p_reservation_id || ':' || lower(v_target)
  )
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
  v_status_column text;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  v_status_column := public.evently_existing_column('public.orders', array['order_status', 'status']);
  if v_status_column is null then raise exception 'Order status column is missing'; end if;
  execute format(
    'select customer_id, %I::text from public.orders where id = $1 for update',
    v_status_column
  ) into v_customer_id, v_current using p_order_id;
  if not found then raise exception 'Order not found'; end if;

  v_target := public.evently_status_value('public.orders', v_status_column, p_status);
  if lower(v_current) = lower(v_target) then return; end if;
  if not (
    (lower(v_current) = 'pending' and lower(v_target) in ('confirmed', 'cancelled'))
    or (lower(v_current) = 'confirmed' and lower(v_target) in ('preparing', 'cancelled'))
    or (lower(v_current) = 'preparing' and lower(v_target) in ('ready', 'cancelled'))
    or (lower(v_current) = 'ready' and lower(v_target) in ('completed', 'cancelled'))
  ) then
    raise exception 'Invalid order status transition from % to %', v_current, v_target;
  end if;

  execute format(
    'update public.orders set %I = %L, updated_at = now() where id = $1',
    v_status_column,
    v_target
  ) using p_order_id;
  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'order_status_changed', 'order', p_order_id, v_current || ' → ' || v_target);
  insert into public.notifications (user_id, title, message, type, entity_type, entity_id, dedupe_key)
  values (
    v_customer_id,
    'Order status updated',
    'Your order is now ' || lower(v_target) || '.',
    'order_status',
    'order',
    p_order_id,
    'order-status:' || p_order_id || ':' || lower(v_target)
  )
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
  v_payment record;
  v_target text;
  v_verified numeric(12,2);
  v_total numeric(12,2);
  v_current text;
  v_status_column text;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if lower(p_decision) not in ('verified', 'rejected') then raise exception 'Invalid payment decision'; end if;

  v_status_column := public.evently_existing_column('public.payments', array['verification_status', 'status']);
  if v_status_column is null then raise exception 'Payment verification status column is missing'; end if;
  execute format(
    'select payment.*, payment.%I::text as _current_status
     from public.payments payment where id = $1 for update',
    v_status_column
  ) into v_payment using p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  v_current := v_payment._current_status;
  if lower(v_current) <> 'pending' then raise exception 'Only pending payments can be reviewed'; end if;
  if lower(p_decision) = 'rejected' and nullif(trim(p_reason), '') is null then
    raise exception 'A payment rejection reason is required';
  end if;

  v_target := public.evently_status_value('public.payments', v_status_column, p_decision);
  execute format(
    'update public.payments
     set %I = %L, rejection_reason = $1, verified_at = $2, verified_by = $3, updated_at = now()
     where id = $4',
    v_status_column,
    v_target
  ) using
    case when lower(p_decision) = 'rejected' then trim(p_reason) end,
    case when lower(p_decision) = 'verified' then now() end,
    case when lower(p_decision) = 'verified' then auth.uid() end,
    p_payment_id;

  execute format(
    'select coalesce(sum(amount), 0) from public.payments
     where reservation_id = $1 and lower(%I::text) = ''verified''',
    v_status_column
  ) into v_verified using v_payment.reservation_id;

  select total_amount into v_total
  from public.reservations
  where id = v_payment.reservation_id
  for update;
  if not found then raise exception 'Linked reservation not found'; end if;

  update public.reservations
  set amount_paid = v_verified,
      remaining_balance = greatest(v_total - v_verified, 0),
      payment_status = public.evently_status_value(
        'public.reservations',
        'payment_status',
        case when v_verified <= 0 then 'unpaid' when v_verified < v_total then 'partial' else 'paid' end
      )::public.payment_status,
      updated_at = now()
  where id = v_payment.reservation_id;

  update public.orders
  set amount_paid = v_verified,
      remaining_balance = greatest(total_amount - v_verified, 0),
      payment_status = public.evently_status_value(
        'public.orders',
        'payment_status',
        case when v_verified <= 0 then 'unpaid' when v_verified < total_amount then 'partial' else 'paid' end
      )::public.payment_status,
      updated_at = now()
  where id = v_payment.order_id;

  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (
    auth.uid(),
    'payment_' || lower(p_decision),
    'payment',
    p_payment_id,
    coalesce(nullif(trim(p_reason), ''), 'Payment reviewed')
  );

  insert into public.notifications (user_id, title, message, type, entity_type, entity_id, dedupe_key)
  values (
    v_payment.customer_id,
    'Payment ' || lower(v_target),
    'Your payment has been ' || lower(v_target) ||
      case when nullif(trim(p_reason), '') is null then '.' else '. Reason: ' || trim(p_reason) end,
    'payment_status',
    'payment',
    p_payment_id,
    'payment-status:' || p_payment_id || ':' || lower(v_target)
  )
  on conflict (dedupe_key) where dedupe_key is not null do nothing;
end;
$$;

create or replace function public.admin_update_evently_catalog(
  p_entity text,
  p_id uuid,
  p_patch jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if p_entity = 'package' then
    update public.packages
    set name = coalesce(nullif(trim(p_patch ->> 'name'), ''), name),
        description = case when p_patch ? 'description' then coalesce(p_patch ->> 'description', '') else description end,
        price = case when p_patch ? 'price' then (p_patch ->> 'price')::numeric else price end,
        guest_capacity = case when p_patch ? 'guest_capacity' then nullif(p_patch ->> 'guest_capacity', '')::integer else guest_capacity end,
        deposit_percentage = case when p_patch ? 'deposit_percentage' then nullif(p_patch ->> 'deposit_percentage', '')::numeric else deposit_percentage end,
        is_active = case when p_patch ? 'is_active' then (p_patch ->> 'is_active')::boolean else is_active end,
        updated_at = now()
    where id = p_id;
  elsif p_entity = 'package_variant' then
    update public.package_variants
    set name = coalesce(nullif(trim(p_patch ->> 'name'), ''), name),
        price = case when p_patch ? 'price' then (p_patch ->> 'price')::numeric else price end,
        guest_capacity = case when p_patch ? 'guest_capacity' then nullif(p_patch ->> 'guest_capacity', '')::integer else guest_capacity end,
        has_aircon = case when p_patch ? 'has_aircon' then (p_patch ->> 'has_aircon')::boolean else has_aircon end,
        is_active = case when p_patch ? 'is_active' then (p_patch ->> 'is_active')::boolean else is_active end,
        updated_at = now()
    where id = p_id;
  elsif p_entity = 'addon' then
    update public.addons
    set name = coalesce(nullif(trim(p_patch ->> 'name'), ''), name),
        description = case when p_patch ? 'description' then coalesce(p_patch ->> 'description', '') else description end,
        price = case when p_patch ? 'price' then (p_patch ->> 'price')::numeric else price end,
        compatible_services = case
          when p_patch ? 'compatible_services'
            then array(select lower(trim(value)) from jsonb_array_elements_text(p_patch -> 'compatible_services') value where trim(value) <> '')
          else compatible_services
        end,
        is_active = case when p_patch ? 'is_active' then (p_patch ->> 'is_active')::boolean else is_active end,
        updated_at = now()
    where id = p_id;
  else
    raise exception 'Unsupported catalog entity';
  end if;

  if not found then raise exception 'Catalog record not found'; end if;
  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'catalog_updated', p_entity, p_id, 'Updated ' || p_entity || ' catalog fields');
end;
$$;

revoke all on function public.evently_existing_column(regclass, text[]) from public;
revoke all on function public.admin_transition_reservation(uuid, text, text) from public;
revoke all on function public.admin_transition_order(uuid, text) from public;
revoke all on function public.admin_review_payment(uuid, text, text) from public;
revoke all on function public.admin_update_evently_catalog(text, uuid, jsonb) from public;
grant execute on function public.admin_transition_reservation(uuid, text, text) to authenticated;
grant execute on function public.admin_transition_order(uuid, text) to authenticated;
grant execute on function public.admin_review_payment(uuid, text, text) to authenticated;
grant execute on function public.admin_update_evently_catalog(text, uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
