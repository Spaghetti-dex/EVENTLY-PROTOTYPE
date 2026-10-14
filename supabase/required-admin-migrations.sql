-- REVIEW BEFORE APPLYING. This file is intentionally not timestamped, so it is
-- not applied automatically. It contains only storage that is absent from the
-- repository's inspected migrations.

-- Keep the function name requested by the application specification while
-- preserving the existing is_evently_admin() implementation.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select public.is_evently_admin(); $$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- Prevent role escalation even if broader table grants or policies are added
-- later. Owner role changes must be performed by trusted server-side code.
create or replace function public.protect_evently_profile_role()
returns trigger
language plpgsql
security definer
set search_path = ''
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
create trigger protect_evently_profile_role
before update of role on public.profiles
for each row execute function public.protect_evently_profile_role();

-- A reusable catalog is required because reservation_addons must remain a
-- historical snapshot of each reservation's selected names and prices.
create table if not exists public.addons (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text not null default '',
  price numeric(12,2) not null check (price >= 0),
  compatible_services text[] not null default array['Catering']::text[],
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

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
  contact_email text,
  contact_number text,
  address text,
  notification_preferences jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);

alter table public.addons enable row level security;
alter table public.catering_menu_items enable row level security;
alter table public.evently_business_settings enable row level security;

create policy "Active addons are readable" on public.addons for select
using (is_active or public.is_evently_admin());
create policy "Admins manage addons" on public.addons for all to authenticated
using (public.is_evently_admin()) with check (public.is_evently_admin());
create policy "Active menu items are readable" on public.catering_menu_items for select
using (is_active or public.is_evently_admin());
create policy "Admins manage menu items" on public.catering_menu_items for all to authenticated
using (public.is_evently_admin()) with check (public.is_evently_admin());
create policy "Admins manage business settings" on public.evently_business_settings for all to authenticated
using (public.is_evently_admin()) with check (public.is_evently_admin());

grant select on public.addons, public.catering_menu_items to anon, authenticated;
grant insert, update on public.addons, public.catering_menu_items to authenticated;
grant select, insert, update on public.evently_business_settings to authenticated;

-- Payment verification, reservation status transitions, package price-history
-- writes, and trusted audit-log insertion still require schema-specific RPCs.
-- Their column names and constraints must be inspected in production before
-- those functions are authored; do not implement them with a generic dynamic
-- SQL function.
