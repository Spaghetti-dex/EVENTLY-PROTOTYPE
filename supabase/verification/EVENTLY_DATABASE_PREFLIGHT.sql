-- EVENTLY live-database preflight (READ ONLY)
-- Run this first in the Supabase SQL Editor. It performs catalog reads only;
-- it does not change tables, records, policies, functions, or migration history.

select current_database() as database_name,
       current_user as sql_editor_role,
       current_setting('server_version') as postgres_version,
       to_regclass('supabase_migrations.schema_migrations') as migration_ledger;

-- The migration ledger is reported dynamically because some projects install
-- Supabase migrations under another schema or have no CLI ledger.
do $$
declare
  v_versions text;
begin
  if to_regclass('supabase_migrations.schema_migrations') is null then
    raise notice 'Migration ledger supabase_migrations.schema_migrations is not present; compare the deployed schema with the repository migrations manually.';
  else
    execute 'select string_agg(version::text, '', '' order by version::text) from supabase_migrations.schema_migrations'
      into v_versions;
    raise notice 'Recorded Supabase migration versions: %', coalesce(v_versions, '(none)');
  end if;
end;
$$;

-- Required objects, current relation types, RLS state, and row counts only.
with required_objects(object_name) as (
  values
    ('profiles'), ('packages'), ('package_variants'), ('addons'), ('reservations'),
    ('orders'), ('payments'), ('reviews'), ('evently_resources'),
    ('evently_staff_permissions'), ('evently_booking_recommendations'),
    ('evently_review_analysis_rate_limits'), ('evently_catering_change_requests'), ('admin_activity_logs')
)
select required.object_name,
       relation.relkind,
       relation.relrowsecurity as rls_enabled,
       relation.relforcerowsecurity as force_rls
from required_objects required
left join pg_catalog.pg_namespace namespace on namespace.nspname = 'public'
left join pg_catalog.pg_class relation
  on relation.relnamespace = namespace.oid and relation.relname = required.object_name
order by required.object_name;

-- Columns and types for tables that exist. No private row values are selected.
select table_name, ordinal_position, column_name, data_type, udt_name,
       is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = any(array[
    'profiles','packages','package_variants','addons','reservations','orders','payments',
    'reviews','evently_resources','evently_staff_permissions','evently_booking_recommendations',
    'evently_review_analysis_rate_limits','evently_catering_change_requests','admin_activity_logs'
  ])
order by table_name, ordinal_position;

-- Constraints and indexes for booking, payment, resource, and review integrity.
select namespace.nspname as schema_name, relation.relname as table_name,
       constraint_row.conname as constraint_name,
       constraint_row.contype as constraint_type,
       pg_catalog.pg_get_constraintdef(constraint_row.oid, true) as definition,
       constraint_row.convalidated as validated
from pg_catalog.pg_constraint constraint_row
join pg_catalog.pg_class relation on relation.oid = constraint_row.conrelid
join pg_catalog.pg_namespace namespace on namespace.oid = relation.relnamespace
where namespace.nspname = 'public'
  and relation.relname = any(array['profiles','packages','package_variants','addons','reservations','orders','payments','reviews','evently_resources','evently_catering_change_requests'])
order by relation.relname, constraint_row.conname;

select schemaname, tablename, indexname, indexdef
from pg_catalog.pg_indexes
where schemaname = 'public'
  and tablename = any(array['packages','package_variants','addons','reservations','orders','payments','reviews','evently_resources','evently_catering_change_requests'])
order by tablename, indexname;

-- All review, booking, payment, role, and staff RPCs/triggers by signature.
select namespace.nspname as schema_name, procedure.proname as function_name,
       pg_catalog.pg_get_function_identity_arguments(procedure.oid) as arguments,
       pg_catalog.pg_get_function_result(procedure.oid) as result_type,
       procedure.prosecdef as security_definer,
       procedure.provolatile as volatility,
       procedure.proconfig as function_settings,
       has_function_privilege('anon', procedure.oid, 'EXECUTE') as anon_execute,
       has_function_privilege('authenticated', procedure.oid, 'EXECUTE') as authenticated_execute,
       has_function_privilege('service_role', procedure.oid, 'EXECUTE') as service_role_execute
from pg_catalog.pg_proc procedure
join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
where namespace.nspname = 'public'
  and (procedure.proname like 'evently_%'
       or procedure.proname in ('admin_update_evently_catalog','admin_review_payment','admin_transition_reservation','admin_transition_order'))
order by procedure.proname, arguments;

select namespace.nspname as schema_name, relation.relname as table_name,
       trigger_row.tgname as trigger_name,
       pg_catalog.pg_get_triggerdef(trigger_row.oid, true) as definition,
       trigger_row.tgenabled as enabled
from pg_catalog.pg_trigger trigger_row
join pg_catalog.pg_class relation on relation.oid = trigger_row.tgrelid
join pg_catalog.pg_namespace namespace on namespace.oid = relation.relnamespace
where namespace.nspname = 'public' and not trigger_row.tgisinternal
  and relation.relname = any(array['reservations','orders','payments','reviews','evently_resources','profiles','evently_catering_change_requests'])
order by relation.relname, trigger_row.tgname;

-- RLS policy definitions and roles, including permissive/restrictive mode.
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_catalog.pg_policies
where schemaname = 'public'
  and tablename = any(array[
    'profiles','packages','package_variants','addons','reservations','orders','payments','reviews',
    'evently_resources','evently_staff_permissions','evently_booking_recommendations',
    'evently_review_analysis_rate_limits','evently_catering_change_requests','admin_activity_logs'
  ])
order by tablename, policyname;

-- Views and their execution options; verify public review views are invoker-safe.
select namespace.nspname as schema_name, relation.relname as view_name,
       relation.relkind, relation.reloptions,
       pg_catalog.pg_get_viewdef(relation.oid, true) as definition
from pg_catalog.pg_class relation
join pg_catalog.pg_namespace namespace on namespace.oid = relation.relnamespace
where namespace.nspname = 'public' and relation.relkind in ('v','m')
  and (relation.relname like '%review%' or relation.relname like '%reservation%' or relation.relname like '%payment%')
order by relation.relname;

-- Anonymous/authenticated grants for review and reservation data. This reads
-- ACL metadata, not customer records.
select table_schema, table_name, column_name, grantee, privilege_type
from information_schema.column_privileges
where table_schema = 'public'
  and table_name in ('reviews','reservations','payments','profiles','evently_public_reviews','evently_catering_change_requests')
  and grantee in ('anon','authenticated','PUBLIC')
order by table_name, column_name, grantee, privilege_type;

-- Business configuration only, dynamically serialized so optional columns do
-- not make preflight fail. No customer or reservation rows are returned.
do $$
declare
  v_json text;
begin
  if to_regclass('public.packages') is not null then
    execute 'select coalesce(jsonb_agg(to_jsonb(package)), ''[]''::jsonb)::text from public.packages package'
      into v_json;
    raise notice 'PACKAGE_CATALOG_JSON=%', v_json;
  else
    raise notice 'PACKAGE_CATALOG_JSON=table missing';
  end if;
  if to_regclass('public.addons') is not null then
    execute 'select coalesce(jsonb_agg(to_jsonb(addon)), ''[]''::jsonb)::text from public.addons addon'
      into v_json;
    raise notice 'ADDON_CATALOG_JSON=%', v_json;
  else
    raise notice 'ADDON_CATALOG_JSON=table missing';
  end if;
  if to_regclass('public.evently_resources') is not null then
    execute 'select coalesce(jsonb_agg(to_jsonb(resource)), ''[]''::jsonb)::text from public.evently_resources resource'
      into v_json;
    raise notice 'RESOURCE_CATALOG_JSON=%', v_json;
  else
    raise notice 'RESOURCE_CATALOG_JSON=table missing';
  end if;
end;
$$;

-- Verify only presence/types of business-critical fields. This deliberately
-- does not read reservation, payment, or review content.
select table_name, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and (table_name, column_name) in (
    ('reservations','customer_id'),('reservations','package_id'),('reservations','reservation_date'),
    ('reservations','status'),('reservations','payment_due_at'),('reservations','expired_at'),
    ('reservations','start_time'),('reservations','end_time'),('reservations','resource_key'),
    ('reviews','customer_id'),('reviews','reservation_id'),('reviews','package_id'),
    ('reviews','rating'),('reviews','review_text'),('reviews','sentiment_label'),
    ('reviews','sentiment_model_version'),('reviews','sentiment_status'),
    ('payments','reservation_id'),('payments','verification_status'),('payments','submitted_at'),
    ('packages','deposit_percentage'),('packages','service_type'),('packages','resource_key')
  )
order by table_name, column_name;
