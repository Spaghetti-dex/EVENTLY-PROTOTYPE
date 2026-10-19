-- READ-ONLY Resort/Staycation rate and booking-chain preflight.
-- This script reads catalog/metadata only and never changes booking data.

select current_database() as database_name,current_user as sql_editor_role,
       current_setting('server_version') as postgres_version,
       to_regclass('supabase_migrations.schema_migrations') as migration_ledger;

do $$
declare v_versions text;
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute 'select string_agg(version::text,'', '' order by version::text) from supabase_migrations.schema_migrations'
      into v_versions;
    raise notice 'RECORDED_MIGRATIONS=%',coalesce(v_versions,'(none)');
  else
    raise notice 'MIGRATION_LEDGER=missing; verify the installed function chain before applying';
  end if;
end;
$$;

select to_jsonb(package) as resort_package_snapshot
from public.packages package
where lower(package.service_type::text)='resort'
  and lower(package.name) in ('standard room','kubo room','non-air-conditioned venue','air-conditioned venue')
order by lower(package.name),package.id;

select to_jsonb(variant) as active_variant_snapshot
from public.package_variants variant
join public.packages package on package.id=variant.package_id
where variant.is_active and lower(package.service_type::text)='resort'
  and lower(package.name) in ('standard room','kubo room','non-air-conditioned venue','air-conditioned venue')
order by package.id,variant.id;

do $$
declare v_json text;
begin
  if to_regclass('public.evently_resort_service_rates') is not null then
    execute $q$select coalesce(jsonb_agg(to_jsonb(rate) order by rate.rate_key),'[]'::jsonb)::text
      from public.evently_resort_service_rates rate$q$ into v_json;
    raise notice 'INSTALLED_RESORT_RATE_MAPPING=%',v_json;
  else raise notice 'INSTALLED_RESORT_RATE_MAPPING=not installed'; end if;
  if to_regclass('public.evently_resort_rate_catalog_backup') is not null then
    execute $q$select coalesce(jsonb_agg(jsonb_build_object(
      'package_id',package_id,'captured_at',captured_at,
      'name',row_data->'name','price',row_data->'price',
      'guest_capacity',row_data->'guest_capacity','min_guest_count',row_data->'min_guest_count',
      'package_category',row_data->'package_category','pricing_mode',row_data->'pricing_mode',
      'pool_access_fee',row_data->'pool_access_fee','deposit_percentage',row_data->'deposit_percentage',
      'duration_minutes',row_data->'duration_minutes'
    ) order by package_id),'[]'::jsonb)::text
      from public.evently_resort_rate_catalog_backup$q$ into v_json;
    raise notice 'RESORT_CATALOG_BACKUP=%',v_json;
  else raise notice 'RESORT_CATALOG_BACKUP=not installed'; end if;
end;
$$;

select expected.signature,proc.oid is not null as exists,
       case when proc.oid is not null then proc.prosecdef end as security_definer,
       case when proc.oid is not null then has_function_privilege('authenticated',proc.oid,'execute') end as authenticated_execute,
       case when proc.oid is not null then lower(pg_catalog.pg_get_functiondef(proc.oid)) end as function_definition
from (values
  ('public.create_evently_reservation(jsonb)'),
  ('public.create_evently_reservation_before_exact_resource_assignment(jsonb)'),
  ('public.create_evently_reservation_before_resort_staycation_pricing(jsonb)'),
  ('public.create_evently_reservation_before_verified_pool_tour_pricing(jsonb)'),
  ('public.evently_resort_service_amount(uuid,integer,integer,boolean)'),
  ('public.evently_pool_tour_total(uuid,integer,uuid)'),
  ('public.evently_admin_set_pool_capacity(uuid,boolean,integer,text)')
) expected(signature)
left join pg_catalog.pg_proc proc on proc.oid=to_regprocedure(expected.signature)
order by expected.signature;

select package.id,package.name,package.service_type,package.package_category,
       package.price,package.pricing_mode,package.min_guest_count,package.guest_capacity,
       package.pool_access_fee,package.deposit_percentage,package.duration_minutes,
       package.schedule_mode,package.operating_start_time,package.operating_end_time,
       package.resource_mode,package.resource_key,
       count(reservation.id) filter(where lower(reservation.status::text)
         not in ('cancelled','canceled','rejected','completed','expired')) as active_reservations
from public.packages package
left join public.reservations reservation on reservation.package_id=package.id
having lower(package.service_type::text)='resort'
  and lower(package.name) in ('standard room','kubo room','non-air-conditioned venue','air-conditioned venue')
order by lower(package.name),package.id;

select relation.relname as table_name,
       has_table_privilege('anon',relation.oid,'INSERT') as anon_insert,
       has_table_privilege('anon',relation.oid,'UPDATE') as anon_update,
       has_table_privilege('authenticated',relation.oid,'INSERT') as authenticated_insert,
       has_table_privilege('authenticated',relation.oid,'UPDATE') as authenticated_update,
       has_table_privilege('authenticated',relation.oid,'DELETE') as authenticated_delete
from pg_catalog.pg_class relation
join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
where namespace.nspname='public' and relation.relname in ('packages','reservations','orders','payments')
order by relation.relname;
