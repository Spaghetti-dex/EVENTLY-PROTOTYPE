-- REVIEW CANDIDATE ONLY. Phase 1 adds nullable hold metadata and a private audit
-- table; it does not alter booking/payment functions or backfill existing rows.
-- Run the read-only EVENTLY_SAFE_ROLLOUT_PREFLIGHT.sql first. Do not execute
-- until the live column types, RLS policies, and grants match that preflight.
begin;

do $phase1_preflight$
begin
  if to_regclass('public.reservations') is null or to_regclass('public.profiles') is null then
    raise exception 'Phase 1 stopped: public.reservations and public.profiles must already exist';
  end if;
  if to_regprocedure('public.is_evently_admin()') is null then
    raise exception 'Phase 1 stopped: the existing public.is_evently_admin() authorization function is required';
  end if;
  if not (select prosecdef from pg_catalog.pg_proc
      where oid=to_regprocedure('public.is_evently_admin()'))
     or pg_catalog.pg_get_functiondef(to_regprocedure('public.is_evently_admin()')) not ilike '%admin%'
     or pg_catalog.pg_get_functiondef(to_regprocedure('public.is_evently_admin()')) not ilike '%owner%' then
    raise exception 'Phase 1 stopped: is_evently_admin() must be SECURITY DEFINER and retain both Admin and Owner checks';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='reservations' and column_name='id' and udt_name='uuid')
     or not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='profiles' and column_name='id' and udt_name='uuid') then
    raise exception 'Phase 1 stopped: reservation/profile primary keys must be UUID before adding audit foreign keys';
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='reservations' and column_name='payment_due_at'
      and (udt_name<>'timestamptz' or is_nullable<>'YES')) then
    raise exception 'Phase 1 stopped: existing reservations.payment_due_at is not nullable timestamptz';
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='reservations' and column_name='expired_at'
      and (udt_name<>'timestamptz' or is_nullable<>'YES')) then
    raise exception 'Phase 1 stopped: existing reservations.expired_at is not nullable timestamptz';
  end if;

  if to_regclass('public.evently_reservation_override_audit') is not null then
    raise exception 'Phase 1 stopped: the override-audit table already exists; inspect its schema and use the applicable existing migration path';
  end if;
  if to_regprocedure('gen_random_uuid()') is null then
    raise exception 'Phase 1 stopped: gen_random_uuid() is unavailable; do not install extensions implicitly';
  end if;
end;
$phase1_preflight$;

-- Phase 2 can assign deadlines to new reservations. There is deliberately no
-- UPDATE/backfill here; if these columns already contain values, they remain untouched.
alter table public.reservations
  add column if not exists payment_due_at timestamptz,
  add column if not exists expired_at timestamptz;

create table if not exists public.evently_reservation_override_audit (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete restrict,
  admin_id uuid not null references public.profiles(id),
  action text not null,
  reason text not null,
  previous_values jsonb not null,
  new_values jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.evently_reservation_override_audit enable row level security;
revoke all on public.evently_reservation_override_audit from public,anon,authenticated;
grant select on public.evently_reservation_override_audit to authenticated;

do $phase1_policy$
begin
  if not exists(select 1 from pg_catalog.pg_policies
    where schemaname='public' and tablename='evently_reservation_override_audit'
      and policyname='Administrators read reservation override audit') then
    create policy "Administrators read reservation override audit"
      on public.evently_reservation_override_audit for select to authenticated
      using (public.is_evently_admin());
  end if;
end;
$phase1_policy$;

create index if not exists reservations_payment_due_pending_idx
  on public.reservations(payment_due_at)
  where payment_due_at is not null and expired_at is null;

comment on column public.reservations.payment_due_at is
  'For newly created reservations only: Phase 2 sets created_at + 24 hours. Existing NULL deadlines are historical.';
comment on column public.reservations.expired_at is
  'Set by the coordinated expiry workflow only for newly held unpaid reservations.';

notify pgrst,'reload schema';
commit;
