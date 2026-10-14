-- A booking is persisted before the customer uploads a receipt. Keep the
-- trusted catalog/quantity calculator, but do not submit or verify payment
-- from create_evently_reservation. The browser then calls the already-existing
-- evently_submit_payment_proof RPC with the private uploaded object path.

do $$
begin
  if to_regprocedure('public.create_evently_reservation_before_exact_resource_assignment(jsonb)') is null
     or to_regprocedure('public.create_evently_reservation_before_payment_submission(jsonb)') is null then
    raise exception 'Apply the EVENTLY booking, payment verification, and resource migrations first';
  end if;
end;
$$;

create or replace function public.create_evently_reservation_before_exact_resource_assignment(p_booking jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_package public.packages%rowtype;
  v_reservation_id uuid;
  v_existing_id uuid;
  v_booking_service text := lower(trim(coalesce(p_booking ->> 'booking_service', '')));
  v_unit_price numeric(12,2);
  v_old_base numeric(12,2);
  v_new_base numeric(12,2);
  v_item_quantity integer;
  v_room_count integer;
  v_nights integer;
  v_guest_count integer;
  v_new_subtotal numeric(12,2);
  v_new_deposit numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if jsonb_typeof(p_booking) is distinct from 'object' then raise exception 'Booking details are required'; end if;
  if nullif(p_booking ->> 'idempotency_key', '') is null then raise exception 'An idempotency key is required'; end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('evently-booking:' || auth.uid()::text || ':' || (p_booking ->> 'idempotency_key'), 0)
  );
  select id into v_existing_id
  from public.reservations
  where customer_id = auth.uid()
    and client_request_id = (p_booking ->> 'idempotency_key')::uuid;

  v_result := public.create_evently_reservation_before_payment_submission(p_booking - 'payment');
  v_reservation_id := nullif(v_result ->> 'reservation_id', '')::uuid;
  if v_reservation_id is null then raise exception 'The reservation was not saved'; end if;

  -- Preserve the established quantity pricing for trays and rooms. These
  -- adjustments are applied only to a newly created reservation, never retries.
  if v_existing_id is null and v_booking_service in ('food orders & party trays', 'room accommodation') then
    select * into v_package from public.packages
    where id = (p_booking ->> 'package_id')::uuid and is_active;
    if not found then raise exception 'The selected package is unavailable'; end if;
    v_unit_price := v_package.price;
    if nullif(p_booking ->> 'package_variant_id', '') is not null then
      select price into v_unit_price
      from public.package_variants
      where id = (p_booking ->> 'package_variant_id')::uuid
        and package_id = v_package.id and is_active;
      if not found then raise exception 'The selected package variant is unavailable'; end if;
    end if;
    v_guest_count := greatest(1, coalesce(nullif(p_booking ->> 'guest_count', '')::integer, 1));
    v_nights := greatest(1, coalesce(nullif(p_booking ->> 'nights', '')::integer, 1));
    v_old_base := case v_package.pricing_mode
      when 'per_guest' then v_unit_price * v_guest_count
      when 'per_night' then v_unit_price * v_nights
      else v_unit_price
    end;
    if v_booking_service = 'food orders & party trays' then
      if lower(v_package.service_type::text) <> v_booking_service then
        raise exception 'The selected package does not match the food-order service';
      end if;
      v_item_quantity := coalesce(nullif(p_booking ->> 'item_quantity', '')::integer, 1);
      if v_item_quantity < 1 or v_item_quantity > 100 then raise exception 'Tray quantity must be between 1 and 100'; end if;
      v_new_base := v_unit_price * v_item_quantity;
    else
      if lower(v_package.service_type::text) <> 'resort'
         or not (lower(coalesce(v_package.package_category, '')) like '%room%'
           or lower(v_package.name) in ('standard room', 'kubo room')) then
        raise exception 'The selected package is not a configured room accommodation';
      end if;
      v_room_count := coalesce(nullif(p_booking ->> 'rooms', '')::integer, 1);
      if v_room_count < 1 or v_room_count > 100 or v_nights > 365 then
        raise exception 'Room count or stay length is outside the supported range';
      end if;
      v_new_base := v_unit_price * v_room_count * v_nights;
    end if;
    if v_old_base is distinct from v_new_base then
      v_new_subtotal := coalesce((v_result ->> 'subtotal')::numeric, 0) - v_old_base + v_new_base;
      v_new_deposit := round(
        v_new_subtotal * least(100, greatest(0, coalesce(v_package.deposit_percentage, 0))) / 100,
        2
      );
      update public.reservations
      set subtotal = v_new_subtotal,
          total_amount = v_new_subtotal,
          deposit_amount = v_new_deposit,
          remaining_balance = greatest(v_new_subtotal - amount_paid, 0),
          updated_at = now()
      where id = v_reservation_id and customer_id = auth.uid();
      update public.orders
      set total_amount = v_new_subtotal,
          remaining_balance = greatest(v_new_subtotal - amount_paid, 0),
          updated_at = now()
      where reservation_id = v_reservation_id and customer_id = auth.uid();
      v_result := v_result || jsonb_build_object(
        'subtotal', v_new_subtotal,
        'deposit_amount', v_new_deposit,
        'remaining_balance', v_new_subtotal
      );
    end if;
  end if;

  return v_result;
end;
$$;

revoke all on function public.create_evently_reservation_before_exact_resource_assignment(jsonb)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
