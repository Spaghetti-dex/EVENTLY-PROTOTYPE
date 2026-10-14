-- Audited catalog management and customer-visible payment destinations.
-- All writes remain behind SECURITY DEFINER RPCs with explicit Owner/Admin checks.

alter table public.catering_menu_items
  add column if not exists price numeric(12,2) not null default 0,
  add column if not exists description text not null default '',
  add column if not exists updated_by uuid references public.profiles(id);

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'catering_menu_items_price_nonnegative'
      and conrelid = 'public.catering_menu_items'::regclass
  ) then
    alter table public.catering_menu_items
      add constraint catering_menu_items_price_nonnegative check (price >= 0) not valid;
  end if;
end;
$$;

-- Existing package prices include the menu by default. A non-zero menu price
-- is treated as an additional per-guest charge for new bookings only.
insert into public.catering_menu_items (category, name, price, is_available, is_active)
values
  ('Beef', 'Mushroom', 0, true, true),
  ('Beef', 'Broccoli', 0, true, true),
  ('Beef', 'Steak', 0, true, true),
  ('Beef', 'Caldereta', 0, true, true),
  ('Pork', 'Caldereta', 0, true, true),
  ('Pork', 'Dinakdakan', 0, true, true),
  ('Pork', 'Sweet & Sour', 0, true, true),
  ('Pork', 'Grilled Liempo', 0, true, true),
  ('Pork', 'Asado', 0, true, true),
  ('Pork', 'Humba', 0, true, true),
  ('Chicken', 'Cordon Bleu', 0, true, true),
  ('Chicken', 'Chicken Inasal', 0, true, true),
  ('Chicken', 'Chicken Teriyaki', 0, true, true),
  ('Chicken', 'Butter Garlic Chicken', 0, true, true),
  ('Chicken', 'Lemon Chicken', 0, true, true),
  ('Chicken', 'Spicy Wings', 0, true, true),
  ('Seafood', 'Fish Fillet', 0, true, true),
  ('Seafood', 'Shrimp Tempura', 0, true, true),
  ('Seafood', 'Buttered Shrimp', 0, true, true),
  ('Seafood', 'Sweet & Sour Fish', 0, true, true),
  ('Vegetable', 'Chopsuey', 0, true, true),
  ('Vegetable', 'Lumpiang Ubod', 0, true, true),
  ('Vegetable', 'Buttered Vegetable', 0, true, true),
  ('Vegetable', 'Vegetable Salad', 0, true, true),
  ('Vegetable', 'Fried Vegetable Lumpia', 0, true, true),
  ('Pasta / Pancit', 'Mixed Pancit', 0, true, true),
  ('Pasta / Pancit', 'Mixed Sotanghon', 0, true, true),
  ('Pasta / Pancit', 'Palabok', 0, true, true),
  ('Pasta / Pancit', 'Carbonara', 0, true, true),
  ('Pasta / Pancit', 'Spaghetti', 0, true, true),
  ('Pasta / Pancit', 'Shanghai Rolls', 0, true, true),
  ('Dessert', 'Fruit Salad', 0, true, true),
  ('Dessert', 'Coffee Jelly', 0, true, true),
  ('Dessert', 'Mango Tapioca', 0, true, true),
  ('Dessert', 'Buko Pandan', 0, true, true),
  ('Dessert', 'Buko Salad', 0, true, true),
  ('Drinks', 'Iced Tea', 0, true, true),
  ('Drinks', 'Cucumber Lemon', 0, true, true),
  ('Drinks', 'Four Seasons', 0, true, true),
  ('Drinks', 'Pineapple', 0, true, true)
on conflict (category, name) do nothing;

alter table public.evently_business_settings
  add column if not exists payment_accounts jsonb not null default '[]'::jsonb;

comment on column public.evently_business_settings.payment_accounts is
  'Published customer-facing payment destinations only; never store provider credentials, passwords, PINs, or OTPs.';

create table if not exists public.evently_payment_account_audit (
  id bigint generated always as identity primary key,
  changed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  changed_methods text[] not null default array[]::text[],
  old_accounts jsonb not null default '[]'::jsonb,
  new_accounts jsonb not null default '[]'::jsonb
);

comment on table public.evently_payment_account_audit is
  'Restricted audit snapshots for payment destination changes; accessible only to Owner/Admin accounts.';

alter table public.evently_payment_account_audit enable row level security;
drop policy if exists "Admins read payment destination audit" on public.evently_payment_account_audit;
create policy "Admins read payment destination audit"
  on public.evently_payment_account_audit for select to authenticated
  using (public.is_evently_admin());
revoke all on public.evently_payment_account_audit from public, anon, authenticated;
grant select on public.evently_payment_account_audit to authenticated;
grant usage, select on sequence public.evently_payment_account_audit_id_seq to authenticated;

-- Do not let direct table writes bypass the audited RPCs. The security-definer
-- functions below are the only supported write path for catalog/settings rows.
revoke insert, update, delete on public.packages, public.package_variants,
  public.addons, public.catering_menu_items from public, anon, authenticated;
revoke update (deposit_percentage) on public.packages from public, anon, authenticated;
revoke select, insert, update, delete on public.evently_business_settings from public, anon, authenticated;
drop policy if exists "Customers read payment settings" on public.evently_business_settings;
drop policy if exists "Admins manage payment settings" on public.evently_business_settings;

create or replace function public.admin_update_evently_catalog(
  p_entity text,
  p_id uuid,
  p_patch jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_price numeric;
  v_deposit numeric;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if p_id is null or jsonb_typeof(p_patch) is distinct from 'object' then raise exception 'A catalog record and object patch are required'; end if;
  if p_patch ? 'price' then
    if nullif(p_patch ->> 'price', '') is null then raise exception 'A numeric catalog price is required'; end if;
    v_price := (p_patch ->> 'price')::numeric;
    if v_price < 0 or v_price > 1000000000 then raise exception 'Catalog price is outside the supported range'; end if;
  end if;
  if p_patch ? 'deposit_percentage' then
    v_deposit := nullif(p_patch ->> 'deposit_percentage', '')::numeric;
    if v_deposit is not null and (v_deposit < 0 or v_deposit > 100) then raise exception 'Deposit percentage must be between 0 and 100'; end if;
  end if;

  if p_entity = 'package' then
    select to_jsonb(item) into v_before from public.packages item where item.id = p_id for update;
    if v_before is null then raise exception 'Catalog record not found'; end if;
    update public.packages
    set name = coalesce(nullif(trim(p_patch ->> 'name'), ''), name),
        description = case when p_patch ? 'description' then coalesce(p_patch ->> 'description', '') else description end,
        price = case when p_patch ? 'price' then v_price else price end,
        guest_capacity = case when p_patch ? 'guest_capacity' then nullif(p_patch ->> 'guest_capacity', '')::integer else guest_capacity end,
        deposit_percentage = case when p_patch ? 'deposit_percentage' then v_deposit else deposit_percentage end,
        is_active = case when p_patch ? 'is_active' then (p_patch ->> 'is_active')::boolean else is_active end,
        updated_at = now()
    where id = p_id;
    select to_jsonb(item) into v_after from public.packages item where item.id = p_id;
  elsif p_entity = 'package_variant' then
    select to_jsonb(item) into v_before from public.package_variants item where item.id = p_id for update;
    if v_before is null then raise exception 'Catalog record not found'; end if;
    update public.package_variants
    set name = coalesce(nullif(trim(p_patch ->> 'name'), ''), name),
        price = case when p_patch ? 'price' then v_price else price end,
        guest_capacity = case when p_patch ? 'guest_capacity' then nullif(p_patch ->> 'guest_capacity', '')::integer else guest_capacity end,
        has_aircon = case when p_patch ? 'has_aircon' then (p_patch ->> 'has_aircon')::boolean else has_aircon end,
        is_active = case when p_patch ? 'is_active' then (p_patch ->> 'is_active')::boolean else is_active end,
        updated_at = now()
    where id = p_id;
    select to_jsonb(item) into v_after from public.package_variants item where item.id = p_id;
  elsif p_entity = 'addon' then
    if p_patch ? 'compatible_services' and jsonb_typeof(p_patch -> 'compatible_services') is distinct from 'array' then
      raise exception 'Compatible services must be an array';
    end if;
    select to_jsonb(item) into v_before from public.addons item where item.id = p_id for update;
    if v_before is null then raise exception 'Catalog record not found'; end if;
    update public.addons
    set name = coalesce(nullif(trim(p_patch ->> 'name'), ''), name),
        description = case when p_patch ? 'description' then coalesce(p_patch ->> 'description', '') else description end,
        price = case when p_patch ? 'price' then v_price else price end,
        compatible_services = case
          when p_patch ? 'compatible_services'
            then array(select lower(trim(value)) from jsonb_array_elements_text(p_patch -> 'compatible_services') value where trim(value) <> '')
          else compatible_services
        end,
        is_active = case when p_patch ? 'is_active' then (p_patch ->> 'is_active')::boolean else is_active end,
        updated_at = now()
    where id = p_id;
    select to_jsonb(item) into v_after from public.addons item where item.id = p_id;
  else
    raise exception 'Unsupported catalog entity';
  end if;

  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (
    auth.uid(),
    'catalog_updated',
    p_entity,
    p_id,
    jsonb_build_object(
      'before', jsonb_strip_nulls(jsonb_build_object('name', v_before -> 'name', 'price', v_before -> 'price', 'is_active', v_before -> 'is_active', 'deposit_percentage', v_before -> 'deposit_percentage')),
      'after', jsonb_strip_nulls(jsonb_build_object('name', v_after -> 'name', 'price', v_after -> 'price', 'is_active', v_after -> 'is_active', 'deposit_percentage', v_after -> 'deposit_percentage'))
    )::text
  );
end;
$$;

create or replace function public.evently_admin_update_catering_menu_item(
  p_id uuid,
  p_patch jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_category text;
  v_price numeric;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if p_id is null or jsonb_typeof(p_patch) is distinct from 'object' then raise exception 'A menu record and object patch are required'; end if;
  if p_patch ? 'price' then
    if nullif(p_patch ->> 'price', '') is null then raise exception 'A numeric menu price is required'; end if;
    v_price := (p_patch ->> 'price')::numeric;
    if v_price < 0 or v_price > 1000000000 then raise exception 'Menu price is outside the supported range'; end if;
  end if;
  if p_patch ? 'category' then
    v_category := trim(p_patch ->> 'category');
    if v_category not in ('Beef', 'Pork', 'Chicken', 'Seafood', 'Vegetable', 'Pasta / Pancit', 'Dessert', 'Drinks') then
      raise exception 'Unsupported catering menu category';
    end if;
  end if;

  select to_jsonb(item) into v_before from public.catering_menu_items item where item.id = p_id for update;
  if v_before is null then raise exception 'Catering menu item not found'; end if;
  update public.catering_menu_items
  set name = coalesce(nullif(trim(p_patch ->> 'name'), ''), name),
      category = coalesce(v_category, category),
      description = case when p_patch ? 'description' then coalesce(p_patch ->> 'description', '') else description end,
      price = case when p_patch ? 'price' then v_price else price end,
      is_active = case when p_patch ? 'is_active' then (p_patch ->> 'is_active')::boolean else is_active end,
      is_available = case when p_patch ? 'is_available' then (p_patch ->> 'is_available')::boolean else is_available end,
      updated_at = now(),
      updated_by = auth.uid()
  where id = p_id;
  select to_jsonb(item) into v_after from public.catering_menu_items item where item.id = p_id;

  insert into public.admin_activity_logs (admin_id, action, entity_type, entity_id, description)
  values (
    auth.uid(), 'catalog_updated', 'catering_menu_item', p_id,
    jsonb_build_object(
      'before', jsonb_strip_nulls(jsonb_build_object('name', v_before -> 'name', 'category', v_before -> 'category', 'price', v_before -> 'price', 'is_active', v_before -> 'is_active', 'is_available', v_before -> 'is_available')),
      'after', jsonb_strip_nulls(jsonb_build_object('name', v_after -> 'name', 'category', v_after -> 'category', 'price', v_after -> 'price', 'is_active', v_after -> 'is_active', 'is_available', v_after -> 'is_available'))
    )::text
  );
end;
$$;

create table if not exists public.evently_business_settings (
  id boolean primary key default true check (id),
  business_name text not null default 'Venice Catering Services',
  gcash_instructions text,
  bank_transfer_instructions text,
  cash_instructions text,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  payment_accounts jsonb not null default '[]'::jsonb
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
  v_updated_at timestamptz;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  select coalesce(payment_accounts, '[]'::jsonb), updated_at
    into v_accounts, v_updated_at
  from public.evently_business_settings where id = true;
  return jsonb_build_object(
    'accounts', coalesce(v_accounts, '[]'::jsonb),
    'legacy_instructions', coalesce((
      select jsonb_build_object(
        'gcash_instructions', coalesce(settings.gcash_instructions, ''),
        'bank_transfer_instructions', coalesce(settings.bank_transfer_instructions, ''),
        'cash_instructions', coalesce(settings.cash_instructions, '')
      )
      from public.evently_business_settings settings where settings.id = true
    ), jsonb_build_object('gcash_instructions', '', 'bank_transfer_instructions', '', 'cash_instructions', '')),
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
    or exists (select 1 from public.profiles profile where profile.id = auth.uid() and profile.role = 'customer')
  ) then
    raise exception 'Customer payment information is not available to this account';
  end if;
  select * into v_settings from public.evently_business_settings where id = true;
  v_configured := coalesce(jsonb_typeof(v_settings.payment_accounts) = 'array' and jsonb_array_length(v_settings.payment_accounts) > 0, false);
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
  from jsonb_array_elements(coalesce(v_settings.payment_accounts, '[]'::jsonb)) with ordinality account(value, ordinality)
  where coalesce((account.value ->> 'is_active')::boolean, false);

  return jsonb_build_object(
    'configured', v_configured,
    'accounts', coalesce(v_accounts, '[]'::jsonb),
    'legacy_instructions', case when v_configured then '{}'::jsonb else jsonb_build_object(
      'gcash_instructions', v_settings.gcash_instructions,
      'bank_transfer_instructions', v_settings.bank_transfer_instructions,
      'cash_instructions', v_settings.cash_instructions
    ) end
  );
end;
$$;

create or replace function public.evently_admin_save_payment_accounts(
  p_accounts jsonb,
  p_expected_updated_at timestamptz
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_accounts jsonb := '[]'::jsonb;
  v_next_accounts jsonb := '[]'::jsonb;
  v_current_updated_at timestamptz;
  v_existing boolean := false;
  v_item jsonb;
  v_previous jsonb;
  v_account jsonb;
  v_id text;
  v_method text;
  v_display_name text;
  v_account_holder text;
  v_bank_name text;
  v_account_number text;
  v_mobile_number text;
  v_instructions text;
  v_qr_url text;
  v_is_active boolean;
  v_methods text[] := array[]::text[];
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'A verified MFA (AAL2) session is required to change payment destinations';
  end if;
  if jsonb_typeof(p_accounts) is distinct from 'array' then
    raise exception 'Payment destinations must be provided as an array';
  end if;
  if jsonb_array_length(p_accounts) > 12 then
    raise exception 'Payment destinations must be an array with no more than 12 methods';
  end if;

  select coalesce(payment_accounts, '[]'::jsonb), updated_at
    into v_old_accounts, v_current_updated_at
  from public.evently_business_settings where id = true for update;
  v_existing := found;
  if v_existing and p_expected_updated_at is distinct from v_current_updated_at then
    raise exception 'Payment settings changed since they were loaded. Refresh and review before publishing';
  elsif not v_existing and p_expected_updated_at is not null then
    raise exception 'Payment settings changed since they were loaded. Refresh and review before publishing';
  end if;

  for v_item in select value from jsonb_array_elements(p_accounts)
  loop
    if jsonb_typeof(v_item) is distinct from 'object' then raise exception 'Each payment method must be an object'; end if;
    if exists (
      select 1 from jsonb_object_keys(v_item) key
      where key not in ('id','method','display_name','account_holder','bank_name','account_number','mobile_wallet_number','instructions','qr_code_url','is_active')
    ) then raise exception 'Payment destination contains an unsupported field'; end if;

    v_method := lower(trim(coalesce(v_item ->> 'method', '')));
    if v_method not in ('gcash','maya','bank_transfer','other','cash') then raise exception 'Unsupported payment method'; end if;
    v_id := coalesce(nullif(trim(v_item ->> 'id'), ''), gen_random_uuid()::text);
    v_display_name := trim(coalesce(v_item ->> 'display_name', ''));
    v_account_holder := trim(coalesce(v_item ->> 'account_holder', ''));
    v_bank_name := trim(coalesce(v_item ->> 'bank_name', ''));
    v_account_number := trim(coalesce(v_item ->> 'account_number', ''));
    v_mobile_number := trim(coalesce(v_item ->> 'mobile_wallet_number', ''));
    v_instructions := trim(coalesce(v_item ->> 'instructions', ''));
    v_qr_url := trim(coalesce(v_item ->> 'qr_code_url', ''));
    v_is_active := coalesce((v_item ->> 'is_active')::boolean, false);

    if v_display_name = '' or length(v_display_name) > 100 or length(v_instructions) > 1500
       or length(v_account_holder) > 150 or length(v_bank_name) > 150
       or length(v_account_number) > 100 or length(v_mobile_number) > 100 then
      raise exception 'Payment destination fields are empty or exceed their supported length';
    end if;
    if v_qr_url <> '' and (length(v_qr_url) > 2048 or v_qr_url !~* '^https://') then
      raise exception 'QR code images must use a secure HTTPS URL';
    end if;
    if v_is_active and v_instructions = '' then raise exception 'Active payment methods require customer instructions'; end if;
    if v_is_active and v_method in ('gcash','maya') and (v_account_holder = '' or v_mobile_number = '') then
      raise exception 'Active wallet methods require an account holder and wallet number';
    end if;
    if v_is_active and v_method = 'bank_transfer' and (v_account_holder = '' or v_bank_name = '' or v_account_number = '') then
      raise exception 'Active bank transfers require a bank, account holder, and account number';
    end if;
    if v_is_active and v_method = 'other' and v_account_number = '' and v_mobile_number = '' then
      raise exception 'Active custom methods require an account or wallet destination';
    end if;

    v_account := jsonb_build_object(
      'id', v_id,
      'method', v_method,
      'display_name', v_display_name,
      'account_holder', v_account_holder,
      'bank_name', v_bank_name,
      'account_number', v_account_number,
      'mobile_wallet_number', v_mobile_number,
      'instructions', v_instructions,
      'qr_code_url', v_qr_url,
      'is_active', v_is_active
    );
    select value into v_previous
    from jsonb_array_elements(v_old_accounts) value
    where value ->> 'id' = v_id;
    if v_previous is not null and (v_previous - 'updated_at' - 'updated_by') = v_account then
      v_account := v_account || jsonb_build_object(
        'updated_at', v_previous -> 'updated_at',
        'updated_by', v_previous -> 'updated_by'
      );
    else
      v_account := v_account || jsonb_build_object('updated_at', now(), 'updated_by', auth.uid());
    end if;
    v_next_accounts := v_next_accounts || jsonb_build_array(v_account);
    v_methods := array_append(v_methods, v_method);
  end loop;

  if exists (
    select account.value ->> 'id'
    from jsonb_array_elements(v_next_accounts) account(value)
    group by account.value ->> 'id'
    having count(*) > 1
  ) then
    raise exception 'Payment destination IDs must be unique';
  end if;
  if exists (
    select account.value ->> 'method'
    from jsonb_array_elements(v_next_accounts) account(value)
    where coalesce((account.value ->> 'is_active')::boolean, false)
    group by account.value ->> 'method'
    having count(*) > 1
  ) then
    raise exception 'Only one active destination per payment method is supported';
  end if;

  if v_next_accounts = v_old_accounts then return; end if;
  insert into public.evently_payment_account_audit (changed_by, changed_methods, old_accounts, new_accounts)
  values (auth.uid(), array(select distinct unnest(v_methods)), v_old_accounts, v_next_accounts);

  insert into public.evently_business_settings (id, payment_accounts, updated_at, updated_by)
  values (true, v_next_accounts, now(), auth.uid())
  on conflict (id) do update set
    payment_accounts = excluded.payment_accounts,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;
end;
$$;

create or replace function public.evently_admin_save_legacy_payment_instructions(
  p_instructions jsonb,
  p_expected_updated_at timestamptz
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb;
  v_next jsonb;
  v_updated_at timestamptz;
  v_existing boolean := false;
  v_gcash text;
  v_bank text;
  v_cash text;
begin
  if not public.is_evently_admin() then raise exception 'Administrative access required'; end if;
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'A verified MFA (AAL2) session is required to change payment instructions';
  end if;
  if jsonb_typeof(p_instructions) is distinct from 'object' then
    raise exception 'Payment instructions must be provided as an object';
  end if;
  if exists (
    select 1 from jsonb_object_keys(p_instructions) key
    where key not in ('gcash_instructions','bank_transfer_instructions','cash_instructions')
  ) then raise exception 'Payment instructions contain an unsupported field'; end if;

  v_gcash := trim(coalesce(p_instructions ->> 'gcash_instructions', ''));
  v_bank := trim(coalesce(p_instructions ->> 'bank_transfer_instructions', ''));
  v_cash := trim(coalesce(p_instructions ->> 'cash_instructions', ''));
  if greatest(length(v_gcash), length(v_bank), length(v_cash)) > 1500 then
    raise exception 'Each payment instruction must be 1,500 characters or fewer';
  end if;

  select jsonb_build_object(
      'gcash_instructions', coalesce(gcash_instructions, ''),
      'bank_transfer_instructions', coalesce(bank_transfer_instructions, ''),
      'cash_instructions', coalesce(cash_instructions, '')
    ), updated_at
    into v_old, v_updated_at
  from public.evently_business_settings where id = true for update;
  v_existing := found;
  if v_existing and p_expected_updated_at is distinct from v_updated_at then
    raise exception 'Payment settings changed since they were loaded. Refresh and review before saving';
  elsif not v_existing and p_expected_updated_at is not null then
    raise exception 'Payment settings changed since they were loaded. Refresh and review before saving';
  end if;
  if not v_existing then
    v_old := jsonb_build_object('gcash_instructions', '', 'bank_transfer_instructions', '', 'cash_instructions', '');
  end if;
  v_next := jsonb_build_object(
    'gcash_instructions', v_gcash,
    'bank_transfer_instructions', v_bank,
    'cash_instructions', v_cash
  );
  if v_old = v_next then return; end if;

  insert into public.evently_payment_account_audit (changed_by, changed_methods, old_accounts, new_accounts)
  values (
    auth.uid(),
    array['legacy_instructions'],
    jsonb_build_array(jsonb_build_object('legacy_instructions', v_old)),
    jsonb_build_array(jsonb_build_object('legacy_instructions', v_next))
  );
  insert into public.evently_business_settings (
    id, gcash_instructions, bank_transfer_instructions, cash_instructions, updated_at, updated_by
  ) values (true, v_gcash, v_bank, v_cash, now(), auth.uid())
  on conflict (id) do update set
    gcash_instructions = excluded.gcash_instructions,
    bank_transfer_instructions = excluded.bank_transfer_instructions,
    cash_instructions = excluded.cash_instructions,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;
end;
$$;

-- The payment method may be backed by an enum in the supplied project. Add
-- supported labels only when necessary; text-backed schemas need no DDL.
do $$
declare
  v_type oid;
  v_type_name text;
  v_type_kind text;
  v_label text;
begin
  select attribute.atttypid, pg_catalog.format('%I.%I', namespace.nspname, type.typname), type.typtype
    into v_type, v_type_name, v_type_kind
  from pg_catalog.pg_attribute attribute
  join pg_catalog.pg_type type on type.oid = attribute.atttypid
  join pg_catalog.pg_namespace namespace on namespace.oid = type.typnamespace
  where attribute.attrelid = 'public.payments'::regclass
    and attribute.attname = 'method'
    and not attribute.attisdropped;
  if v_type_kind = 'e' then
    foreach v_label in array array['gcash','bank_transfer','cash','maya','other'] loop
      if not exists (select 1 from pg_catalog.pg_enum where enumtypid = v_type and lower(enumlabel) = lower(v_label)) then
        execute format('alter type %s add value %L', v_type_name, v_label);
      end if;
    end loop;
  end if;
end;
$$;

-- Wrap the existing server-authoritative reservation workflow. It continues
-- to own package/add-on pricing, date checks, resource rules, snapshots, and
-- idempotency; this layer validates current menu availability and adds menu
-- surcharges without changing historical bookings.
do $$
begin
  if to_regprocedure('public.create_evently_reservation_before_catalog_menu(jsonb)') is null then
    alter function public.create_evently_reservation(jsonb)
      rename to create_evently_reservation_before_catalog_menu;
  end if;
end;
$$;

revoke all on function public.create_evently_reservation_before_catalog_menu(jsonb) from public, anon, authenticated;

create or replace function public.create_evently_reservation(p_booking jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing_id uuid;
  v_package public.packages%rowtype;
  v_result jsonb;
  v_menu jsonb := coalesce(p_booking -> 'menu', '{}'::jsonb);
  v_selection record;
  v_menu_item_price numeric(12,2);
  v_menu_total numeric(12,2) := 0;
  v_guest_count integer;
  v_subtotal numeric(12,2);
  v_deposit numeric(12,2);
  v_reservation_id uuid;
  v_order_id uuid;
  v_category text;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if nullif(p_booking ->> 'idempotency_key', '') is null then raise exception 'An idempotency key is required'; end if;
  select id into v_existing_id
  from public.reservations
  where customer_id = auth.uid() and client_request_id = (p_booking ->> 'idempotency_key')::uuid;
  if found then return public.create_evently_reservation_before_catalog_menu(p_booking); end if;

  select * into v_package
  from public.packages
  where id = (p_booking ->> 'package_id')::uuid and is_active
  for share;
  if not found then raise exception 'The selected package is unavailable'; end if;

  if jsonb_typeof(v_menu) is distinct from 'object' then
    raise exception 'Menu selections must be provided as a category object';
  end if;

  if lower(v_package.service_type::text) = 'catering' then
    if jsonb_object_length(v_menu) <> 8 then
      raise exception 'Choose one available menu item from each required catering category';
    end if;
    foreach v_category in array array['Beef','Pork','Chicken','Seafood','Vegetable','Pasta / Pancit','Dessert','Drinks'] loop
      if not (v_menu ? v_category) then raise exception 'A required catering menu category is missing'; end if;
    end loop;
    v_guest_count := (p_booking ->> 'guest_count')::integer;
    if v_guest_count < 1 then raise exception 'Guest count must be at least one'; end if;
    for v_selection in select key, value from jsonb_each_text(v_menu)
    loop
      select item.price into v_menu_item_price
      from public.catering_menu_items item
      where lower(item.category) = lower(v_selection.key)
        and lower(item.name) = lower(v_selection.value)
        and item.is_active
        and item.is_available
      for share;
      if not found then raise exception 'A selected catering menu item is unavailable'; end if;
      v_menu_total := v_menu_total + v_menu_item_price * v_guest_count;
    end loop;
  elsif jsonb_object_length(v_menu) > 0 then
    raise exception 'Menu selections are only supported for catering bookings';
  end if;

  v_result := public.create_evently_reservation_before_catalog_menu(p_booking);
  v_reservation_id := (v_result ->> 'reservation_id')::uuid;
  v_order_id := nullif(v_result ->> 'order_id', '')::uuid;
  v_subtotal := coalesce((v_result ->> 'subtotal')::numeric, 0) + v_menu_total;
  v_deposit := round(v_subtotal * least(100, greatest(0, coalesce(v_package.deposit_percentage, 0))) / 100, 2);

  update public.reservations
  set subtotal = v_subtotal,
      total_amount = v_subtotal,
      deposit_amount = v_deposit,
      remaining_balance = greatest(v_subtotal - amount_paid, 0),
      updated_at = now()
  where id = v_reservation_id and customer_id = auth.uid();
  update public.orders
  set total_amount = v_subtotal,
      remaining_balance = greatest(v_subtotal - amount_paid, 0),
      updated_at = now()
  where id = v_order_id and customer_id = auth.uid();

  return v_result || jsonb_build_object(
    'subtotal', v_subtotal,
    'deposit_amount', v_deposit,
    'remaining_balance', greatest(v_subtotal, 0),
    'menu_total', v_menu_total
  );
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
  v_accounts jsonb := '[]'::jsonb;
  v_configured boolean := false;
  v_legacy_instructions text;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  select remaining_balance into v_remaining
  from public.reservations
  where id = p_reservation_id and customer_id = auth.uid()
  for update;
  if not found then raise exception 'Reservation not found'; end if;
  if v_method = 'bank transfer' then v_method := 'bank_transfer'; end if;
  if v_method not in ('gcash', 'maya', 'bank_transfer', 'other', 'cash') then raise exception 'Unsupported payment method'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > v_remaining then raise exception 'Payment amount is invalid'; end if;

  select coalesce(payment_accounts, '[]'::jsonb),
         coalesce(jsonb_typeof(payment_accounts) = 'array' and jsonb_array_length(payment_accounts) > 0, false),
         case v_method
           when 'gcash' then gcash_instructions
           when 'bank_transfer' then bank_transfer_instructions
           when 'cash' then cash_instructions
           else null
         end
    into v_accounts, v_configured, v_legacy_instructions
  from public.evently_business_settings where id = true;
  if v_configured then
    if not exists (
      select 1 from jsonb_array_elements(v_accounts) account
      where lower(account ->> 'method') = v_method
        and coalesce((account ->> 'is_active')::boolean, false)
    ) then raise exception 'This payment method is not active'; end if;
  elsif coalesce(trim(v_legacy_instructions), '') = '' then
    raise exception 'This payment method is not configured';
  end if;
  if v_method <> 'cash' and (
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

revoke all on function public.admin_update_evently_catalog(text, uuid, jsonb) from public, anon;
revoke all on function public.evently_admin_update_catering_menu_item(uuid, jsonb) from public, anon;
revoke all on function public.evently_admin_get_payment_accounts() from public, anon;
revoke all on function public.evently_customer_payment_options() from public, anon;
revoke all on function public.evently_admin_save_payment_accounts(jsonb, timestamptz) from public, anon;
revoke all on function public.evently_admin_save_legacy_payment_instructions(jsonb, timestamptz) from public, anon;
revoke all on function public.create_evently_reservation(jsonb) from public, anon;
revoke all on function public.submit_evently_payment(uuid, numeric, text, text, text) from public, anon;
grant execute on function public.admin_update_evently_catalog(text, uuid, jsonb) to authenticated;
grant execute on function public.evently_admin_update_catering_menu_item(uuid, jsonb) to authenticated;
grant execute on function public.evently_admin_get_payment_accounts() to authenticated;
grant execute on function public.evently_customer_payment_options() to authenticated;
grant execute on function public.evently_admin_save_payment_accounts(jsonb, timestamptz) to authenticated;
grant execute on function public.evently_admin_save_legacy_payment_instructions(jsonb, timestamptz) to authenticated;
grant execute on function public.create_evently_reservation(jsonb) to authenticated;
grant execute on function public.submit_evently_payment(uuid, numeric, text, text, text) to authenticated;

notify pgrst, 'reload schema';
