-- Customer-facing payment options include only active, complete destinations.
-- The payment amount is also checked against the locked reservation and linked
-- order; browser-provided totals are never used as the authority.

create or replace function public.evently_customer_payment_options()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_settings public.evently_business_settings%rowtype;
  v_accounts jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or not (
    public.is_evently_admin()
    or exists (
      select 1 from public.profiles profile
      where profile.id = auth.uid() and profile.role = 'customer'
    )
  ) then
    raise exception 'Customer payment information is not available to this account';
  end if;

  select * into v_settings
  from public.evently_business_settings settings
  where settings.id = true;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', account.value ->> 'id',
    'method', account.value ->> 'method',
    'display_name', account.value ->> 'display_name',
    'account_holder', account.value ->> 'account_holder',
    'bank_name', account.value ->> 'bank_name',
    'account_number', account.value ->> 'account_number',
    'mobile_wallet_number', account.value ->> 'mobile_wallet_number',
    'instructions', account.value ->> 'instructions',
    'qr_code_url', account.value ->> 'qr_code_url',
    'is_active', true
  ) order by account.ordinality), '[]'::jsonb)
  into v_accounts
  from jsonb_array_elements(case
    when jsonb_typeof(v_settings.payment_accounts) = 'array' then v_settings.payment_accounts
    else '[]'::jsonb
  end) with ordinality account(value, ordinality)
  where account.value @> '{"is_active":true}'::jsonb
    and account.value ->> 'method' in ('gcash', 'maya', 'bank_transfer')
    and nullif(btrim(account.value ->> 'display_name'), '') is not null
    and nullif(btrim(account.value ->> 'account_holder'), '') is not null
    and nullif(btrim(account.value ->> 'instructions'), '') is not null
    and case account.value ->> 'method'
      when 'gcash' then nullif(btrim(account.value ->> 'mobile_wallet_number'), '') is not null
      when 'maya' then nullif(btrim(account.value ->> 'mobile_wallet_number'), '') is not null
      when 'bank_transfer' then nullif(btrim(account.value ->> 'bank_name'), '') is not null
        and nullif(btrim(account.value ->> 'account_number'), '') is not null
      else false
    end;

  return jsonb_build_object(
    'configured', jsonb_array_length(v_accounts) > 0,
    'demo_mode', coalesce(v_settings.demo_payment_mode, true),
    'accounts', v_accounts,
    'legacy_instructions', '{}'::jsonb
  );
end;
$$;

revoke all on function public.evently_customer_payment_options() from public, anon;
grant execute on function public.evently_customer_payment_options() to authenticated;

do $$
begin
  if to_regprocedure('public.submit_evently_payment_before_fixed_due_guard(uuid,numeric,text,text,text)') is null then
    alter function public.submit_evently_payment(uuid, numeric, text, text, text)
      rename to submit_evently_payment_before_fixed_due_guard;
  end if;
end;
$$;

revoke all on function public.submit_evently_payment_before_fixed_due_guard(uuid,numeric,text,text,text)
  from public, anon, authenticated;

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
  v_reservation public.reservations%rowtype;
  v_order public.orders%rowtype;
  v_booking_total numeric(12,2);
  v_amount_due numeric(12,2);
  v_method text := lower(trim(coalesce(p_method, '')));
  v_options jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  select * into v_reservation
  from public.reservations reservation
  where reservation.id = p_reservation_id
    and reservation.customer_id = auth.uid()
  for update;
  if not found then raise exception 'Reservation not found'; end if;

  select * into v_order
  from public.orders order_record
  where order_record.reservation_id = p_reservation_id
    and order_record.customer_id = auth.uid()
  limit 1
  for update;
  if not found then raise exception 'The reservation is not linked to an order'; end if;

  -- Reservation/order totals are written by the trusted booking calculator,
  -- which includes selected add-ons. Refuse inconsistent snapshots.
  if v_reservation.total_amount is distinct from v_order.total_amount then
    raise exception 'The saved reservation and order totals do not match; contact an administrator';
  end if;
  v_booking_total := coalesce(v_reservation.total_amount, 0);
  if coalesce(v_reservation.amount_paid, 0) > 0 then
    v_amount_due := greatest(coalesce(
      v_reservation.remaining_balance,
      v_order.remaining_balance,
      v_booking_total - v_reservation.amount_paid
    ), 0);
  else
    v_amount_due := least(v_booking_total, case
      when coalesce(v_reservation.deposit_amount, 0) > 0 then v_reservation.deposit_amount
      else v_booking_total
    end);
  end if;
  if p_amount is null or round(p_amount, 2) <> round(v_amount_due, 2) then
    raise exception 'Submitted amount must exactly match the saved amount due: %', round(v_amount_due, 2);
  end if;

  if v_method = 'bank transfer' then v_method := 'bank_transfer'; end if;
  v_options := public.evently_customer_payment_options();
  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_options -> 'accounts', '[]'::jsonb)) account
    where lower(account ->> 'method') = v_method
      and account @> '{"is_active":true}'::jsonb
  ) then
    raise exception 'Choose an active, correctly configured payment destination';
  end if;

  return public.submit_evently_payment_before_fixed_due_guard(
    p_reservation_id,
    p_amount,
    v_method,
    p_reference_number,
    p_proof_url
  );
end;
$$;

revoke all on function public.submit_evently_payment(uuid,numeric,text,text,text) from public, anon;
grant execute on function public.submit_evently_payment(uuid,numeric,text,text,text) to authenticated;

notify pgrst, 'reload schema';
