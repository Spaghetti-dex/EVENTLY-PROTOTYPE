-- Manual rollback for 20261019090000 only. Review the companion rollback notes.
-- This retains reservation/order snapshots and never changes historical totals.
begin;

do $$
begin
  if to_regclass('public.evently_resort_service_rates') is null
     or to_regclass('public.evently_resort_rate_catalog_backup') is null
     or to_regprocedure('public.create_evently_reservation_before_exact_resource_assignment(jsonb)') is null
     or to_regprocedure('public.create_evently_reservation_before_resort_staycation_pricing(jsonb)') is null
     or to_regprocedure('public.evently_resort_service_amount(uuid,integer,integer,boolean)') is null then
    raise exception 'Rollback stopped: the Resort migration objects do not match the expected installed state';
  end if;
  if (select count(*) from public.evently_resort_service_rates rates
      join public.packages package on package.id=rates.package_id
      join public.evently_resort_rate_catalog_backup backup on backup.package_id=package.id
      where package.is_active and package.price=rates.expected_price
        and package.deposit_percentage=30 and package.pool_access_fee=5000
        and package.name is not distinct from backup.row_data->>'name'
        and package.service_type::text is not distinct from backup.row_data->>'service_type'
        and ((rates.rate_key='standard_room' and package.package_category='room'
             and package.pricing_mode='per_night' and package.min_guest_count=4
             and package.guest_capacity=5
             and package.duration_minutes is not distinct from nullif(backup.row_data->>'duration_minutes','')::integer)
          or (rates.rate_key='kubo_room' and package.package_category='room'
             and package.pricing_mode='per_night' and package.min_guest_count=1
             and package.guest_capacity is not distinct from nullif(backup.row_data->>'guest_capacity','')::integer)
          or (rates.rate_key='venue_non_aircon' and package.package_category='event_venue'
             and package.pricing_mode='fixed' and package.duration_minutes=300
             and package.schedule_mode='customer_select')
          or (rates.rate_key='venue_aircon' and package.package_category='event_venue'
             and package.pricing_mode='fixed' and package.duration_minutes=240
             and package.schedule_mode='customer_select')))<>4 then
    raise exception 'Rollback stopped: one or more rate packages changed after deployment; inspect the catalog before restoring anything';
  end if;
end;
$$;

drop function public.create_evently_reservation_before_exact_resource_assignment(jsonb);
alter function public.create_evently_reservation_before_resort_staycation_pricing(jsonb)
  rename to create_evently_reservation_before_exact_resource_assignment;
drop function public.evently_resort_service_amount(uuid,integer,integer,boolean);

update public.packages package
set price=nullif(backup.row_data->>'price','')::numeric,
    guest_capacity=nullif(backup.row_data->>'guest_capacity','')::integer,
    min_guest_count=nullif(backup.row_data->>'min_guest_count','')::integer,
    package_category=backup.row_data->>'package_category',
    pricing_mode=backup.row_data->>'pricing_mode',
    pool_access_fee=coalesce(nullif(backup.row_data->>'pool_access_fee','')::numeric,0),
    deposit_percentage=nullif(backup.row_data->>'deposit_percentage','')::numeric,
    duration_minutes=nullif(backup.row_data->>'duration_minutes','')::integer,
    schedule_mode=backup.row_data->>'schedule_mode',
    updated_at=now()
from public.evently_resort_rate_catalog_backup backup
where backup.package_id=package.id;

drop table public.evently_resort_service_rates;
notify pgrst,'reload schema';
commit;
