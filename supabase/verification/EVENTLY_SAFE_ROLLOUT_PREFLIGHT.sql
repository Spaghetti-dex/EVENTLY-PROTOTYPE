-- READ-ONLY inventory for the staged EVENTLY booking-hold rollout.
-- This script performs SELECTs/catalog inspection only; it never changes data.

select current_database() as database_name,
       current_user as sql_editor_role,
       current_setting('server_version') as postgres_version,
       to_regclass('supabase_migrations.schema_migrations') as migration_ledger,
       to_regclass('public.evently_business_settings') as business_settings,
       to_regclass('public.evently_schedule_proposals') as schedule_proposals,
       to_regclass('public.evently_reservation_override_audit') as override_audit,
       to_regclass('public.evently_pool_capacity_audit') as pool_capacity_audit;

-- Relevant column types/defaults, including live-specific idempotency/payment fields.
select table_name,ordinal_position,column_name,data_type,udt_name,is_nullable,column_default
from information_schema.columns
where table_schema='public'
  and table_name in (
    'reservations','orders','payments','packages','package_variants','reservation_addons',
    'addons','profiles','evently_resources','evently_business_settings',
    'evently_schedule_proposals','evently_reservation_override_audit'
  )
order by table_name,ordinal_position;

-- Constraint/index definitions for the keys and status/amount columns the later
-- phases must preserve. This intentionally reports live shape rather than
-- assuming the repository migration's types.
select constraint_row.conrelid::regclass as table_name,
       constraint_row.conname,
       constraint_row.contype,
       pg_catalog.pg_get_constraintdef(constraint_row.oid) as definition
from pg_catalog.pg_constraint constraint_row
where constraint_row.conrelid in (
  to_regclass('public.reservations'),to_regclass('public.orders'),
  to_regclass('public.payments'),to_regclass('public.packages'),
  to_regclass('public.reservation_addons'),to_regclass('public.evently_resources')
)
order by table_name,constraint_row.conname;

select schemaname,tablename,indexname,indexdef
from pg_catalog.pg_indexes
where schemaname='public'
  and tablename in ('reservations','orders','payments','packages','evently_resources')
order by tablename,indexname;

-- Current state counts only; no customer names, references, or payment proof paths.
select 'reservations' as relation,count(*) as row_count from public.reservations
union all
select 'orders',count(*) from public.orders
union all
select 'payments',count(*) from public.payments;

select lower(status::text) as reservation_status,count(*) as row_count,
       count(*) filter(where nullif(to_jsonb(reservation)->>'payment_due_at','') is null) as no_deadline_rows,
       count(*) filter(where nullif(to_jsonb(reservation)->>'expired_at','') is not null) as expired_rows
from public.reservations reservation
group by lower(status::text)
order by lower(status::text);

select count(*) as reservations_without_orders
from public.reservations reservation
where not exists(select 1 from public.orders order_row where order_row.reservation_id=reservation.id);

select pricing_mode,count(*) as package_count
from public.packages
group by pricing_mode
order by pricing_mode;

-- Verify supplied facts without exposing customer data. client_request_id's
-- actual type is important to idempotency and must remain text if live says text.
select package.id,
       to_jsonb(package)->>'name' as name,
       to_jsonb(package)->>'price' as price,
       to_jsonb(package)->>'deposit_percentage' as deposit_percentage,
       to_jsonb(package)->>'pricing_mode' as pricing_mode,
       to_jsonb(package)->>'min_guest_count' as min_guest_count,
       to_jsonb(package)->>'max_guest_count' as max_guest_count,
       to_jsonb(package)->>'resource_key' as resource_key,
       to_jsonb(package)->>'resource_mode' as resource_mode,
       to_jsonb(package)->>'schedule_mode' as schedule_mode,
       to_jsonb(package)->>'fixed_start_time' as fixed_start_time,
       to_jsonb(package)->>'fixed_end_time' as fixed_end_time
from public.packages package
where package.id in (
  '4ae972a8-6503-4776-90c9-899246cbc4dc',
  '5afda244-a615-4bd3-98eb-d360d000100b',
  '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'
)
order by package.id;

select addon.id,addon.name,addon.price,addon.is_active,addon.compatible_services
from public.addons addon
where addon.id in (
  '1e97b2bf-ca43-492a-8a15-2d20f6abf040',
  '928c269f-c38a-4345-86a5-d1f4c65555f0'
)
order by addon.id;

-- Existing schedule/payment/RLS policies and triggers that Phase 2 must coordinate.
select schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check
from pg_catalog.pg_policies
where schemaname='public'
  and tablename in ('reservations','orders','payments','packages','addons','evently_resources')
order by tablename,policyname;

select trigger_row.tgrelid::regclass as table_name,trigger_row.tgname,
       pg_catalog.pg_get_triggerdef(trigger_row.oid) as definition
from pg_catalog.pg_trigger trigger_row
where not trigger_row.tgisinternal
  and trigger_row.tgrelid in (
    to_regclass('public.reservations'),to_regclass('public.orders'),
    to_regclass('public.payments'),to_regclass('public.packages')
  )
order by table_name,trigger_row.tgname;

select extension.extname,extension.extversion
from pg_catalog.pg_extension extension
where extension.extname='pg_cron';

select relation.relname as table_name,
       has_table_privilege('anon',relation.oid,'INSERT') as anon_insert,
       has_table_privilege('anon',relation.oid,'UPDATE') as anon_update,
       has_table_privilege('authenticated',relation.oid,'INSERT') as authenticated_insert,
       has_table_privilege('authenticated',relation.oid,'UPDATE') as authenticated_update,
       has_table_privilege('authenticated',relation.oid,'DELETE') as authenticated_delete
from pg_catalog.pg_class relation
join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
where namespace.nspname='public'
  and relation.relname in ('reservations','orders','payments','packages','addons')
order by relation.relname;
