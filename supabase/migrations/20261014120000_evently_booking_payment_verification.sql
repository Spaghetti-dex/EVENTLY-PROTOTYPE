-- Keep payment proof private and gate final booking approval on verified proof.
-- Reservation creation persists the booking separately from the receipt upload.

do $$
begin
  if to_regprocedure('public.create_evently_reservation(jsonb)') is null
     or to_regprocedure('public.submit_evently_payment(uuid,numeric,text,text,text)') is null
     or to_regprocedure('public.evently_admin_approve_booking(uuid,boolean)') is null
     or to_regprocedure('public.admin_transition_reservation(uuid,text,text)') is null
     or to_regprocedure('public.admin_review_payment(uuid,text,text)') is null
     or to_regprocedure('public.evently_existing_column(regclass,text[])') is null then
    raise exception 'Apply the existing EVENTLY booking, pricing, payment-settings, and workflow migrations first';
  end if;
end;
$$;

alter table public.payments
  add column if not exists demo_mode boolean not null default false,
  add column if not exists submitted_at timestamptz,
  add column if not exists reviewed_by uuid references public.profiles(id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_notes text;

update public.payments
set submitted_at = coalesce(submitted_at, created_at, now())
where submitted_at is null;

alter table public.payments
  alter column submitted_at set default now(),
  alter column submitted_at set not null;

alter table public.evently_business_settings
  add column if not exists demo_payment_mode boolean not null default true;

-- Some existing installations use an enum for the payment method. Extend it
-- only when needed so the supported Maya option can be stored safely.
do $$
declare
  v_method_column text;
  v_type_name text;
  v_is_enum boolean;
  v_has_maya boolean;
begin
  v_method_column := public.evently_existing_column(
    'public.payments', array['method', 'payment_method']
  );
  select format('%I.%I', ns.nspname, ty.typname),
         ty.typtype = 'e',
         exists (
           select 1 from pg_catalog.pg_enum enum_value
           where enum_value.enumtypid = ty.oid
             and lower(enum_value.enumlabel) = 'maya'
         )
    into v_type_name, v_is_enum, v_has_maya
  from pg_catalog.pg_attribute attribute
  join pg_catalog.pg_type ty on ty.oid = attribute.atttypid
  join pg_catalog.pg_namespace ns on ns.oid = ty.typnamespace
  where attribute.attrelid = 'public.payments'::regclass
    and attribute.attname = v_method_column
    and not attribute.attisdropped;
  if v_is_enum and not v_has_maya then
    execute format('alter type %s add value %L', v_type_name, 'maya');
  end if;
end;
$$;

comment on column public.evently_business_settings.demo_payment_mode is
  'When true, payment submissions are demonstration records and do not represent actual financial settlement.';
comment on column public.payments.demo_mode is
  'Snapshot of demo/manual payment mode when submitted; true does not mean money was transferred.';

-- Private receipts are images only, limited to 10 MiB. Customers can upload
-- only beneath their own UUID folder. Existing private-read and unsubmitted
-- object-delete policies from the booking workflow are retained.
update storage.buckets
set public = false,
    file_size_limit = 10485760,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
where id = 'payment-proofs';

drop policy if exists "Customers upload their payment proofs" on storage.objects;
create policy "Customers upload their payment proofs" on storage.objects for insert
to authenticated with check (
  bucket_id = 'payment-proofs'
  and (storage.foldername(name))[1] = auth.uid()::text
  and lower(storage.extension(name)) in ('jpg', 'jpeg', 'png', 'webp')
  and coalesce(metadata ->> 'mimetype', '') in ('image/jpeg', 'image/png', 'image/webp')
);

create or replace function public.evently_admin_get_payment_accounts()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_accounts jsonb;
  v_legacy jsonb;
  v_demo_mode boolean := true;
  v_updated_at timestamptz;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  select coalesce(settings.payment_accounts, '[]'::jsonb),
         jsonb_build_object(
           'gcash_instructions', coalesce(settings.gcash_instructions, ''),
           'bank_transfer_instructions', coalesce(settings.bank_transfer_instructions, ''),
           'cash_instructions', coalesce(settings.cash_instructions, '')
         ),
         coalesce(settings.demo_payment_mode, true),
         settings.updated_at
    into v_accounts, v_legacy, v_demo_mode, v_updated_at
  from public.evently_business_settings settings
  where settings.id = true;
  return jsonb_build_object(
    'accounts', coalesce(v_accounts, '[]'::jsonb),
    'legacy_instructions', coalesce(v_legacy, jsonb_build_object(
      'gcash_instructions', '', 'bank_transfer_instructions', '', 'cash_instructions', ''
    )),
    'demo_mode', coalesce(v_demo_mode, true),
    'updated_at', v_updated_at
  );
end;
$$;

create or replace function public.evently_customer_payment_options()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_settings public.evently_business_settings%rowtype;
  v_configured boolean := false;
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
  select * into v_settings from public.evently_business_settings where id = true;
  v_configured := coalesce(
    jsonb_typeof(v_settings.payment_accounts) = 'array'
      and jsonb_array_length(v_settings.payment_accounts) > 0,
    false
  );
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
  from jsonb_array_elements(coalesce(v_settings.payment_accounts, '[]'::jsonb))
    with ordinality account(value, ordinality)
  where coalesce((account.value ->> 'is_active')::boolean, false);

  return jsonb_build_object(
    'configured', v_configured,
    'demo_mode', coalesce(v_settings.demo_payment_mode, true),
    'accounts', coalesce(v_accounts, '[]'::jsonb),
    'legacy_instructions', case when v_configured then '{}'::jsonb else jsonb_build_object(
      'gcash_instructions', v_settings.gcash_instructions,
      'bank_transfer_instructions', v_settings.bank_transfer_instructions,
      'cash_instructions', v_settings.cash_instructions
    ) end
  );
end;
$$;

create or replace function public.evently_admin_set_demo_payment_mode(
  p_enabled boolean,
  p_expected_updated_at timestamptz
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current boolean := true;
  v_updated_at timestamptz;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'A verified MFA (AAL2) session is required to change demo payment mode';
  end if;
  select coalesce(demo_payment_mode, true), updated_at
    into v_current, v_updated_at
  from public.evently_business_settings
  where id = true
  for update;
  if found and p_expected_updated_at is distinct from v_updated_at then
    raise exception 'Payment settings changed since they were loaded. Refresh and review before changing demo mode';
  elsif not found and p_expected_updated_at is not null then
    raise exception 'Payment settings changed since they were loaded. Refresh and review before changing demo mode';
  end if;
  if v_current = p_enabled then return; end if;

  insert into public.evently_payment_account_audit (changed_by, changed_methods, old_accounts, new_accounts)
  values (
    auth.uid(),
    array['demo_payment_mode'],
    jsonb_build_array(jsonb_build_object('demo_payment_mode', v_current)),
    jsonb_build_array(jsonb_build_object('demo_payment_mode', p_enabled))
  );
  insert into public.evently_business_settings (id, demo_payment_mode, updated_at, updated_by)
  values (true, p_enabled, now(), auth.uid())
  on conflict (id) do update set
    demo_payment_mode = excluded.demo_payment_mode,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;
  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (auth.uid(), 'demo_payment_mode_changed', 'payment_settings', null,
    case when p_enabled then 'Enabled demo payment mode; submissions are not financial settlement'
         else 'Disabled demo payment mode' end);
end;
$$;

revoke all on function public.evently_admin_set_demo_payment_mode(boolean,timestamptz) from public, anon;
grant execute on function public.evently_admin_set_demo_payment_mode(boolean,timestamptz) to authenticated;

-- Preserve the existing reservation calculator and its signature, then add
-- the payment insert in the same database transaction. Failed proof checks or
-- payment inserts roll back the new reservation and its linked order.
do $$
begin
  if to_regprocedure('public.create_evently_reservation_before_payment_submission(jsonb)') is null then
    alter function public.create_evently_reservation(jsonb)
      rename to create_evently_reservation_before_payment_submission;
  end if;
end;
$$;

revoke all on function public.create_evently_reservation_before_payment_submission(jsonb)
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
  v_payment_id uuid;
  v_order_id uuid;
  v_method text := lower(trim(coalesce(p_method, '')));
  v_status_column text;
  v_method_column text;
  v_pending_count integer;
  v_minimum_amount numeric(12,2);
  v_demo_verified numeric(12,2) := 0;
  v_accounts jsonb := '[]'::jsonb;
  v_configured boolean := false;
  v_demo_mode boolean := true;
  v_legacy_instructions text;
  v_status_value text;
  v_method_value text;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  select * into v_reservation
  from public.reservations
  where id = p_reservation_id and customer_id = auth.uid()
  for update;
  if not found then raise exception 'Reservation not found'; end if;

  if v_method = 'bank transfer' then v_method := 'bank_transfer'; end if;
  if v_method not in ('gcash', 'maya', 'bank_transfer') then
    raise exception 'Choose GCash, Maya, or Bank Transfer';
  end if;
  if p_amount is null or p_amount <= 0
     or p_amount > coalesce(v_reservation.remaining_balance, v_reservation.total_amount) then
    raise exception 'Payment amount is invalid';
  end if;
  v_minimum_amount := case
    when coalesce(v_reservation.amount_paid, 0) > 0 then 0.01
    when coalesce(v_reservation.deposit_amount, 0) > 0 then v_reservation.deposit_amount
    else coalesce(v_reservation.total_amount, 0)
  end;
  if p_amount < v_minimum_amount then
    raise exception 'The submitted amount must cover the required deposit of %', v_minimum_amount;
  end if;
  if nullif(trim(coalesce(p_reference_number, '')), '') is null
     or length(trim(p_reference_number)) > 160 then
    raise exception 'Enter a valid payment reference number';
  end if;
  if nullif(trim(coalesce(p_proof_url, '')), '') is null
     or p_proof_url !~ ('^' || auth.uid()::text || '/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    raise exception 'Upload a JPG, PNG, or WebP receipt image in your private payment folder';
  end if;
  if not exists (
    select 1 from storage.objects object
    where object.bucket_id = 'payment-proofs'
      and object.name = p_proof_url
      and coalesce(object.metadata ->> 'mimetype', '') in ('image/jpeg', 'image/png', 'image/webp')
  ) then
    raise exception 'The private receipt upload could not be verified';
  end if;

  select coalesce(settings.payment_accounts, '[]'::jsonb),
         coalesce(jsonb_typeof(settings.payment_accounts) = 'array'
           and jsonb_array_length(settings.payment_accounts) > 0, false),
         coalesce(settings.demo_payment_mode, true),
         case v_method
           when 'gcash' then settings.gcash_instructions
           when 'bank_transfer' then settings.bank_transfer_instructions
           else null
         end
    into v_accounts, v_configured, v_demo_mode, v_legacy_instructions
  from public.evently_business_settings settings
  where settings.id = true;
  if v_configured then
    if not exists (
      select 1 from jsonb_array_elements(v_accounts) account
      where lower(account ->> 'method') = v_method
        and coalesce((account ->> 'is_active')::boolean, false)
    ) then raise exception 'This payment method is not active'; end if;
  elsif coalesce(trim(v_legacy_instructions), '') = '' then
    raise exception 'This payment method is not configured';
  end if;

  v_status_column := public.evently_existing_column(
    'public.payments', array['verification_status', 'status']
  );
  v_method_column := public.evently_existing_column(
    'public.payments', array['method', 'payment_method']
  );
  if v_status_column is null or v_method_column is null then
    raise exception 'Payment status or method columns are missing';
  end if;
  if v_demo_mode then
    execute format(
      'select coalesce(sum(amount), 0) from public.payments
       where reservation_id = $1 and demo_mode is true
         and lower(%I::text) = ''verified''
         and nullif(trim(reference_number), '''') is not null
         and nullif(trim(proof_url), '''') is not null',
      v_status_column
    ) into v_demo_verified using p_reservation_id;
    if v_demo_verified >= v_minimum_amount then
      raise exception 'Demo payment proof has already been accepted for this booking; no additional demo payment is needed';
    end if;
  end if;
  execute format(
    'select count(*) from public.payments where reservation_id = $1 and lower(%I::text) = ''pending''',
    v_status_column
  ) into v_pending_count using p_reservation_id;
  if v_pending_count > 0 then
    raise exception 'A payment submission is already awaiting review';
  end if;
  if exists (
    select 1 from public.payments
    where lower(reference_number) = lower(trim(p_reference_number))
  ) then raise exception 'This transaction reference was already submitted'; end if;

  select id into v_order_id
  from public.orders
  where reservation_id = p_reservation_id and customer_id = auth.uid()
  limit 1;
  if v_order_id is null then raise exception 'The reservation is not linked to an order'; end if;

  v_status_value := public.evently_status_value('public.payments', v_status_column, 'pending');
  v_method_value := public.evently_status_value('public.payments', v_method_column, v_method);
  execute format(
    'insert into public.payments (
       customer_id, reservation_id, order_id, amount, %I, %I,
       reference_number, proof_url, demo_mode, submitted_at
     ) values ($1, $2, $3, $4, %L, %L, $5, $6, $7, now())
     returning id',
    v_status_column, v_method_column, v_status_value, v_method_value
  ) into v_payment_id using
    auth.uid(), p_reservation_id, v_order_id, p_amount,
    trim(p_reference_number), p_proof_url, v_demo_mode;
  return v_payment_id;
end;
$$;

create or replace function public.create_evently_reservation(p_booking jsonb)
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
  v_reservation_id := (v_result ->> 'reservation_id')::uuid;

  -- The existing calculator remains authoritative for package and add-on
  -- prices. Apply the already-supported tray/room quantities to new bookings
  -- only; never recalculate historical reservations on an idempotent retry.
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

  -- Reservation persistence is intentionally independent from payment proof.
  -- The customer uploads a private receipt after this result is returned, then
  -- submits it through the existing evently_submit_payment_proof RPC.
  return v_result;
end;
$$;

revoke all on function public.create_evently_reservation(jsonb) from public, anon;
grant execute on function public.create_evently_reservation(jsonb) to authenticated;
revoke all on function public.submit_evently_payment(uuid,numeric,text,text,text) from public, anon;
grant execute on function public.submit_evently_payment(uuid,numeric,text,text,text) to authenticated;

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
  v_status_column text;
  v_target text;
  v_current text;
  v_verified numeric(12,2);
  v_total numeric(12,2);
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if lower(trim(coalesce(p_decision, ''))) not in ('verified', 'rejected') then
    raise exception 'Invalid payment decision';
  end if;
  v_status_column := public.evently_existing_column(
    'public.payments', array['verification_status', 'status']
  );
  if v_status_column is null then raise exception 'Payment verification status column is missing'; end if;
  execute format(
    'select payment.*, payment.%I::text as _review_status
     from public.payments payment where id = $1 for update',
    v_status_column
  ) into v_payment using p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  v_current := v_payment._review_status;
  if lower(v_current) <> 'pending' then raise exception 'Only pending payments can be reviewed'; end if;
  if lower(p_decision) = 'rejected' and nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'A payment rejection reason is required';
  end if;
  if lower(p_decision) = 'verified'
     and (nullif(trim(coalesce(v_payment.reference_number, '')), '') is null
       or nullif(trim(coalesce(v_payment.proof_url, '')), '') is null
       or v_payment.amount <= 0) then
    raise exception 'Payment proof, transaction reference, and a positive amount are required before verification';
  end if;

  v_target := public.evently_status_value('public.payments', v_status_column, lower(p_decision));
  execute format(
    'update public.payments
     set %I = %L,
         rejection_reason = $1,
         verified_at = $2,
         verified_by = case when $5 = ''verified'' then $3 else null end,
         reviewed_at = now(),
         reviewed_by = $3,
         review_notes = $1,
         updated_at = now()
     where id = $4',
    v_status_column, v_target
  ) using
    case when lower(p_decision) = 'rejected' then trim(p_reason) else null end,
    case when lower(p_decision) = 'verified' then now() else null end,
    auth.uid(), p_payment_id, lower(p_decision);

  if lower(p_decision) = 'verified' and not exists (
    select 1 from storage.objects object
    where object.bucket_id = 'payment-proofs'
      and object.name = v_payment.proof_url
  ) then
    raise exception 'The private receipt file is missing and cannot be verified';
  end if;

  execute format(
    'select coalesce(sum(amount), 0) from public.payments
     where reservation_id = $1 and lower(%I::text) = ''verified''
       and demo_mode is not true',
    v_status_column
  ) into v_verified using v_payment.reservation_id;
  select total_amount into v_total
  from public.reservations where id = v_payment.reservation_id for update;
  if not found then raise exception 'Linked reservation not found'; end if;

  update public.reservations
  set amount_paid = v_verified,
      remaining_balance = greatest(v_total - v_verified, 0),
      payment_status = public.evently_status_value(
        'public.reservations', 'payment_status',
        case when v_verified <= 0 then 'unpaid' when v_verified < v_total then 'partial' else 'paid' end
      )::public.payment_status,
      updated_at = now()
  where id = v_payment.reservation_id;
  update public.orders
  set amount_paid = v_verified,
      remaining_balance = greatest(total_amount - v_verified, 0),
      payment_status = public.evently_status_value(
        'public.orders', 'payment_status',
        case when v_verified <= 0 then 'unpaid' when v_verified < total_amount then 'partial' else 'paid' end
      )::public.payment_status,
      updated_at = now()
  where id = v_payment.order_id;

  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (
    auth.uid(), 'payment_' || lower(p_decision), 'payment', p_payment_id,
    coalesce(nullif(trim(p_reason), ''), case when coalesce(v_payment.demo_mode, false)
      then 'Demonstration proof accepted by an administrator; no financial settlement implied'
      else 'Payment proof reviewed' end)
  );
  insert into public.notifications (user_id, title, message, type, entity_type, entity_id, dedupe_key)
  values (
    v_payment.customer_id,
    case when lower(p_decision) = 'verified' then 'Payment proof verified' else 'Payment proof rejected' end,
    case when lower(p_decision) = 'verified'
      then case when coalesce(v_payment.demo_mode, false)
        then 'Your demonstration payment proof was accepted for booking review. No actual money transfer is represented.'
        else 'Your submitted payment proof was verified and your booking may proceed to administrator review.' end
      else 'Your payment proof needs attention. ' || trim(p_reason) end,
    'payment_status', 'payment', p_payment_id,
    'payment-status:' || p_payment_id || ':' || lower(p_decision)
  ) on conflict (dedupe_key) where dedupe_key is not null do nothing;
end;
$$;

revoke all on function public.admin_review_payment(uuid,text,text) from public, anon;
grant execute on function public.admin_review_payment(uuid,text,text) to authenticated;

-- Wrap the existing approval implementation so its schedule/resource conflict
-- checks, status enum handling, audit log, and notification remain authoritative.
do $$
begin
  if to_regprocedure('public.evently_admin_approve_booking_before_payment_verification(uuid,boolean)') is null then
    alter function public.evently_admin_approve_booking(uuid, boolean)
      rename to evently_admin_approve_booking_before_payment_verification;
  end if;
end;
$$;

revoke all on function public.evently_admin_approve_booking_before_payment_verification(uuid,boolean)
  from public, anon, authenticated;

create or replace function public.evently_admin_approve_booking(
  p_reservation_id uuid,
  p_schedule_verified boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.reservations%rowtype;
  v_status_column text;
  v_verified_total numeric(12,2);
  v_has_verified_proof boolean;
  v_minimum_amount numeric(12,2);
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  select * into v_reservation
  from public.reservations where id = p_reservation_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if lower(v_reservation.status::text) <> 'pending' then
    raise exception 'Only pending reservations can be approved';
  end if;
  v_status_column := public.evently_existing_column(
    'public.payments', array['verification_status', 'status']
  );
  if v_status_column is null then raise exception 'Payment verification status column is missing'; end if;
  execute format(
    'select coalesce(sum(payment.amount), 0), coalesce(bool_or(payment.amount > 0), false)
     from public.payments payment
     where payment.reservation_id = $1 and lower(payment.%I::text) = ''verified''
       and nullif(trim(payment.reference_number), '''') is not null
       and nullif(trim(payment.proof_url), '''') is not null
       and exists (
         select 1 from storage.objects object
         where object.bucket_id = ''payment-proofs''
           and object.name = payment.proof_url
       )',
    v_status_column
  ) into v_verified_total, v_has_verified_proof using p_reservation_id;
  v_minimum_amount := case
    when coalesce(v_reservation.deposit_amount, 0) > 0 then v_reservation.deposit_amount
    else coalesce(v_reservation.total_amount, 0)
  end;
  if not v_has_verified_proof or v_verified_total < v_minimum_amount then
    raise exception 'Booking approval requires submitted payment proof verified by an Owner/Admin for at least %', v_minimum_amount;
  end if;
  return public.evently_admin_approve_booking_before_payment_verification(
    p_reservation_id, p_schedule_verified
  );
end;
$$;

revoke all on function public.evently_admin_approve_booking(uuid,boolean) from public, anon;
grant execute on function public.evently_admin_approve_booking(uuid,boolean) to authenticated;

-- The generic status-transition RPC must not bypass proof and schedule checks.
do $$
begin
  if to_regprocedure('public.admin_transition_reservation_before_payment_guard(uuid,text,text)') is null then
    alter function public.admin_transition_reservation(uuid, text, text)
      rename to admin_transition_reservation_before_payment_guard;
  end if;
end;
$$;

revoke all on function public.admin_transition_reservation_before_payment_guard(uuid,text,text)
  from public, anon, authenticated;

create or replace function public.admin_transition_reservation(
  p_reservation_id uuid,
  p_status text,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if lower(trim(coalesce(p_status, ''))) in ('confirmed', 'approved') then
    raise exception 'Use evently_admin_approve_booking so payment verification and schedule conflicts are checked';
  end if;
  perform public.admin_transition_reservation_before_payment_guard(
    p_reservation_id, p_status, p_reason
  );
end;
$$;

revoke all on function public.admin_transition_reservation(uuid,text,text) from public, anon;
grant execute on function public.admin_transition_reservation(uuid,text,text) to authenticated;

revoke all on function public.evently_admin_get_payment_accounts() from public, anon;
revoke all on function public.evently_customer_payment_options() from public, anon;
grant execute on function public.evently_admin_get_payment_accounts() to authenticated;
grant execute on function public.evently_customer_payment_options() to authenticated;

notify pgrst, 'reload schema';
