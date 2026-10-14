create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text not null default '',
  username text unique,
  mobile_number text not null default '',
  avatar_url text,
  role text not null default 'customer' check (role in ('customer', 'owner', 'admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create or replace function public.is_evently_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role in ('owner', 'admin')
  );
$$;

create or replace function public.handle_evently_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name, username, mobile_number, avatar_url, role)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', ''),
    nullif(new.raw_user_meta_data ->> 'username', ''),
    coalesce(new.raw_user_meta_data ->> 'mobile_number', new.raw_user_meta_data ->> 'mobile', ''),
    coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture'),
    case
      when new.raw_app_meta_data ->> 'role' in ('owner', 'admin')
        then new.raw_app_meta_data ->> 'role'
      else 'customer'
    end
  )
  on conflict (id) do update set
    email = excluded.email,
    full_name = coalesce(nullif(excluded.full_name, ''), public.profiles.full_name),
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert or update of email, raw_user_meta_data, raw_app_meta_data
  on auth.users
  for each row execute procedure public.handle_evently_user();

insert into public.profiles (id, email, full_name, username, mobile_number, avatar_url, role)
select
  id,
  coalesce(email, ''),
  coalesce(raw_user_meta_data ->> 'full_name', raw_user_meta_data ->> 'name', ''),
  nullif(raw_user_meta_data ->> 'username', ''),
  coalesce(raw_user_meta_data ->> 'mobile_number', raw_user_meta_data ->> 'mobile', ''),
  coalesce(raw_user_meta_data ->> 'avatar_url', raw_user_meta_data ->> 'picture'),
  case
    when raw_app_meta_data ->> 'role' in ('owner', 'admin')
      then raw_app_meta_data ->> 'role'
    else 'customer'
  end
from auth.users
on conflict (id) do update set
  email = excluded.email,
  role = excluded.role,
  updated_at = now();

drop policy if exists "Profiles are visible to their owner or admins" on public.profiles;
create policy "Profiles are visible to their owner or admins"
  on public.profiles for select
  to authenticated
  using (id = auth.uid() or public.is_evently_admin());

drop policy if exists "Customers can create their own profile" on public.profiles;
create policy "Customers can create their own profile"
  on public.profiles for insert
  to authenticated
  with check (id = auth.uid() and role = 'customer');

drop policy if exists "Customers can update their own profile" on public.profiles;
create policy "Customers can update their own profile"
  on public.profiles for update
  to authenticated
  using (id = auth.uid() or public.is_evently_admin())
  with check (id = auth.uid() or public.is_evently_admin());

grant select, insert on public.profiles to authenticated;
grant update (full_name, username, mobile_number, avatar_url, updated_at) on public.profiles to authenticated;
revoke update (role) on public.profiles from authenticated;
