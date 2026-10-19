-- Read-only deployment preflight. Run this against the disposable database
-- before applying 20261017110000; compare results with the verified production
-- snapshot and retain the output with the migration review.

-- Applied repository migrations in the required version range.
select version, name
from supabase_migrations.schema_migrations
where version in (
  '20261008000000', '20261008030000', '20261008060000',
  '20261010080000', '20261013090000', '20261014100000',
  '20261014110000', '20261014120000', '20261014130000',
  '20261015130000', '20261015140000', '20261015150000',
  '20261015160000', '20261017100000'
)
order by version;

-- Confirm the known starting schema that the migration repairs.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'packages'
  and column_name in (
    'guest_capacity', 'pricing_mode', 'min_guest_count', 'cottage_fee',
    'cottage_addon_id', 'pool_access_fee', 'deposit_percentage',
    'resource_key', 'resource_mode', 'schedule_mode',
    'fixed_start_time', 'fixed_end_time', 'operating_start_time', 'operating_end_time'
  )
order by column_name;

-- Existing tour/resource/schedule/deposit rows. Resource identity and fixed
-- times must match; the migration can normalize the package link to the already
-- active exclusive pool resource, but does not create resources or change times.
select id, name, is_active, price, guest_capacity, deposit_percentage,
       resource_key, resource_mode, schedule_mode,
       fixed_start_time, fixed_end_time, operating_start_time, operating_end_time
from public.packages
where id in (
  '4ae972a8-6503-4776-90c9-899246cbc4dc',
  '5afda244-a615-4bd3-98eb-d360d000100b',
  '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
)
order by id;

select resource_key, resource_name, resource_type, is_active, is_exclusive
from public.evently_resources where resource_key = 'venice-main-pool';

select id, name, price, compatible_services, is_active
from public.addons
where id in (
  '1e97b2bf-ca43-492a-8a15-2d20f6abf040',
  '928c269f-c38a-4345-86a5-d1f4c65555f0'
)
order by id;

-- Active variants must be reviewed explicitly; the pool migration fails closed
-- rather than guessing per-variant rates or capacities.
select id, package_id, name, price, guest_capacity, is_active
from public.package_variants
where is_active and package_id in (
  '4ae972a8-6503-4776-90c9-899246cbc4dc',
  '5afda244-a615-4bd3-98eb-d360d000100b',
  '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
);

-- Legacy active pool reservations requiring schedule/resource reconciliation.
select id, reservation_code, status, reservation_date, start_time, end_time,
       resource_key, payment_status, amount_paid, deposit_amount, created_at
from public.reservations
where package_id in (
  '4ae972a8-6503-4776-90c9-899246cbc4dc',
  '5afda244-a615-4bd3-98eb-d360d000100b',
  '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
)
  and lower(status::text) not in ('cancelled', 'canceled', 'rejected', 'completed')
order by reservation_date, start_time;

-- Confirm prerequisite RPC signatures and SECURITY DEFINER status.
select signature,
       (proc.oid is not null) as exists,
       proc.prosecdef as security_definer,
       case when proc.oid is not null then has_function_privilege('authenticated', proc.oid, 'EXECUTE') end as authenticated_execute,
       case when proc.oid is not null then has_function_privilege('anon', proc.oid, 'EXECUTE') end as anon_execute
from (values
  ('public.create_evently_reservation(jsonb)'),
  ('public.create_evently_reservation_before_exact_resource_assignment(jsonb)'),
  ('public.create_evently_reservation_before_payment_submission(jsonb)'),
  ('public.submit_evently_payment(uuid,numeric,text,text,text)'),
  ('public.admin_review_payment(uuid,text,text)'),
  ('public.evently_admin_approve_booking(uuid,boolean)'),
  ('public.admin_transition_reservation(uuid,text,text)'),
  ('public.evently_admin_set_reservation_schedule(uuid,time,time,text)'),
  ('public.evently_admin_check_reservation_schedule(uuid)')
) expected(signature)
left join pg_catalog.pg_proc proc on proc.oid = to_regprocedure(expected.signature)
order by signature;

-- Existing RLS and direct DML privilege baseline. This migration deliberately
-- does not change reservation/order/payment table DML grants or their policies.
select relation.relname as table_name, relation.relrowsecurity as row_security,
       has_table_privilege('anon', relation.oid, 'INSERT') as anon_insert,
       has_table_privilege('anon', relation.oid, 'UPDATE') as anon_update,
       has_table_privilege('anon', relation.oid, 'DELETE') as anon_delete,
       has_table_privilege('authenticated', relation.oid, 'INSERT') as authenticated_insert,
       has_table_privilege('authenticated', relation.oid, 'UPDATE') as authenticated_update,
       has_table_privilege('authenticated', relation.oid, 'DELETE') as authenticated_delete
from pg_catalog.pg_class relation
join pg_catalog.pg_namespace ns on ns.oid = relation.relnamespace
where ns.nspname = 'public'
  and relation.relname in ('packages','reservations','orders','payments')
order by relation.relname;

-- Test prerequisites and scheduler support.
select role, count(*)
from public.profiles
where role in ('customer','admin','owner','staff')
group by role order by role;

select name, default_version, installed_version
from pg_catalog.pg_available_extensions
where name = 'pg_cron';
