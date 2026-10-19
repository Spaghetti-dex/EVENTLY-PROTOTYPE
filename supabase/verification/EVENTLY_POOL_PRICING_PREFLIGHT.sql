-- READ-ONLY EVENTLY Swimming Tour pricing/capacity preflight.
-- Run this before the pool-capacity migration. It reads catalog rows and catalog
-- metadata only; it never changes packages, reservations, prices, or permissions.

select current_database() as database_name,current_user as sql_editor_role,
       current_setting('server_version') as postgres_version,
       to_regclass('supabase_migrations.schema_migrations') as migration_ledger;

do $$
declare v_versions text;
begin
  if to_regclass('supabase_migrations.schema_migrations') is null then
    raise notice 'Migration ledger missing; verify installed RPC signatures and complete migration 20261017110000 manually.';
  else
    execute 'select string_agg(version::text,'', '' order by version::text) from supabase_migrations.schema_migrations'
      into v_versions;
    raise notice 'Recorded migrations: %',coalesce(v_versions,'(none)');
  end if;
end;
$$;

select table_name,ordinal_position,column_name,data_type,udt_name,is_nullable,column_default
from information_schema.columns where table_schema='public'
  and table_name in ('packages','package_variants','addons','reservations','orders','payments',
    'evently_resources','evently_schedule_hold_catalog_backup','evently_pool_capacity_audit')
order by table_name,ordinal_position;

-- Catalog snapshots contain no customer booking rows. Examine guest_capacity,
-- any separately configured max, and verified-capacity metadata before changes.
do $$
declare v_json text;
begin
  if to_regclass('public.packages') is not null then
    execute $q$select coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]'::jsonb)::text
      from public.packages p where p.id::text=any(array[
        '4ae972a8-6503-4776-90c9-899246cbc4dc',
        '5afda244-a615-4bd3-98eb-d360d000100b',
        '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'])$q$ into v_json;
    raise notice 'POOL_PACKAGE_ROWS=%',v_json;
  else raise notice 'POOL_PACKAGE_ROWS=public.packages missing'; end if;
  if to_regclass('public.addons') is not null then
    execute $q$select coalesce(jsonb_agg(to_jsonb(a) order by a.id),'[]'::jsonb)::text
      from public.addons a where a.id::text=any(array[
        '1e97b2bf-ca43-492a-8a15-2d20f6abf040','928c269f-c38a-4345-86a5-d1f4c65555f0'])$q$ into v_json;
    raise notice 'COTTAGE_ADDONS=%',v_json;
  else raise notice 'COTTAGE_ADDONS=public.addons missing'; end if;
  if to_regclass('public.evently_resources') is not null then
    execute $q$select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb)::text
      from public.evently_resources r where to_jsonb(r)->>'resource_key'='venice-main-pool'$q$ into v_json;
    raise notice 'POOL_RESOURCE=%',v_json;
  else raise notice 'POOL_RESOURCE=public.evently_resources missing'; end if;
  if to_regclass('public.evently_schedule_hold_catalog_backup') is not null then
    execute $q$select coalesce(jsonb_agg(jsonb_build_object(
      'entity_key',entity_key,'legacy_guest_capacity',row_data->'guest_capacity',
      'max_guest_count',row_data->'max_guest_count','capacity_verified',row_data->'pool_capacity_verified'
    ) order by entity_key),'[]'::jsonb)::text from public.evently_schedule_hold_catalog_backup
      where entity_type='package' and entity_key=any(array[
        '4ae972a8-6503-4776-90c9-899246cbc4dc','5afda244-a615-4bd3-98eb-d360d000100b',
        '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'])$q$ into v_json;
    raise notice 'SCHEDULE_HOLD_BACKUP=%',v_json;
  else raise notice 'SCHEDULE_HOLD_BACKUP=missing'; end if;
end;
$$;

-- Counts and schedule-integrity diagnostics without customer identifiers.
do $$
declare v_json text;
begin
  if to_regclass('public.package_variants') is not null then
    execute $q$select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb)::text from (
      select to_jsonb(v)->>'package_id' as package_id,count(*) as active_variants
      from public.package_variants v where coalesce((to_jsonb(v)->>'is_active')::boolean,false)
        and to_jsonb(v)->>'package_id'=any(array[
          '4ae972a8-6503-4776-90c9-899246cbc4dc','5afda244-a615-4bd3-98eb-d360d000100b',
          '925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8']) group by to_jsonb(v)->>'package_id'
    ) s$q$ into v_json;
    raise notice 'ACTIVE_POOL_VARIANTS=%',v_json;
  end if;
  if to_regclass('public.reservations') is not null then
    execute $q$select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb)::text from (
      select lower(j->>'status') as status,count(*) as active_rows,
        count(*) filter(where nullif(j->>'reservation_date','') is null
          or nullif(j->>'start_time','') is null or nullif(j->>'end_time','') is null) as incomplete_schedules
      from (select to_jsonb(r) as j from public.reservations r) data
      where j->>'package_id'=any(array['4ae972a8-6503-4776-90c9-899246cbc4dc',
        '5afda244-a615-4bd3-98eb-d360d000100b','925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8'])
        and lower(j->>'status') not in ('cancelled','canceled','rejected','completed','expired')
      group by lower(j->>'status')
    ) s$q$ into v_json;
    raise notice 'ACTIVE_POOL_RESERVATIONS=%',v_json;
  end if;
end;
$$;

select expected.signature,proc.oid is not null as exists,
       case when proc.oid is not null then pg_catalog.pg_get_function_result(proc.oid) end as result_type,
       case when proc.oid is not null then proc.prosecdef end as security_definer,
       case when proc.oid is not null then has_function_privilege('authenticated',proc.oid,'execute') end as authenticated_execute,
       case when proc.oid is not null then lower(pg_catalog.pg_get_functiondef(proc.oid)) end as function_definition
from (values
  ('public.create_evently_reservation(jsonb)'),
  ('public.create_evently_reservation_before_exact_resource_assignment(jsonb)'),
  ('public.create_evently_reservation_before_verified_pool_tour_pricing(jsonb)'),
  ('public.create_evently_reservation_before_payment_submission(jsonb)'),
  ('public.admin_update_evently_catalog(text,uuid,jsonb)'),
  ('public.evently_pool_tour_total(uuid,integer,uuid)'),
  ('public.evently_check_availability(uuid,date)'),
  ('public.evently_reservation_holds_schedule(uuid)'),
  ('public.evently_has_timely_pending_payment(uuid)'),
  ('public.evently_expire_unpaid_reservations()'),
  ('public.evently_auto_confirm_verified_reservation(uuid)'),
  ('public.submit_evently_payment(uuid,numeric,text,text,text)'),
  ('public.evently_submit_payment_proof(uuid,numeric,text,text,text)'),
  ('public.admin_review_payment(uuid,text,text)'),
  ('public.evently_admin_override_reservation(uuid,text,text,date,time,time,text,timestamptz)')
) expected(signature)
left join pg_catalog.pg_proc proc on proc.oid=to_regprocedure(expected.signature)
order by expected.signature;

select indexname,indexdef from pg_catalog.pg_indexes where schemaname='public'
  and tablename in ('reservations','packages','evently_resources') order by tablename,indexname;
select schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check
from pg_catalog.pg_policies where schemaname='public'
  and tablename in ('reservations','orders','payments','packages','evently_resources')
order by tablename,policyname;

select relation.relname as table_name,
       has_table_privilege('anon',relation.oid,'INSERT') as anon_insert,
       has_table_privilege('anon',relation.oid,'UPDATE') as anon_update,
       has_table_privilege('authenticated',relation.oid,'INSERT') as authenticated_insert,
       has_table_privilege('authenticated',relation.oid,'UPDATE') as authenticated_update,
       has_table_privilege('authenticated',relation.oid,'DELETE') as authenticated_delete
from pg_catalog.pg_class relation join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
where namespace.nspname='public' and relation.relname in ('reservations','orders','payments','packages')
order by relation.relname;
