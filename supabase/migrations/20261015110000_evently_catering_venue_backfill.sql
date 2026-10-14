-- Safely assign the three configured physical catering venues to catalog rows
-- and legacy pending reservations. Existing non-null reservation assignments
-- are preserved so an Owner/Admin's manual venue change is never overwritten.
-- No booking status or price is changed.

update public.packages package
set resource_key = mapping.resource_key,
    updated_at = now()
from (values
  ('catering-alfamart-daffodil-2f'::text, '(^|[^a-z0-9])package[[:space:]_-]*1([^0-9]|$)|basic[[:space:]_-]*catering'),
  ('catering-alfamart-amarillo-4f'::text, '(^|[^a-z0-9])package[[:space:]_-]*2([^0-9]|$)|standard[[:space:]_-]*catering'),
  ('catering-alfamart-amarillo-3f'::text, '(^|[^a-z0-9])package[[:space:]_-]*3([^0-9]|$)|premium[[:space:]_-]*catering')
) mapping(resource_key, name_pattern)
where lower(package.service_type::text) = 'catering'
  and lower(package.name) ~ mapping.name_pattern
  and package.resource_key is distinct from mapping.resource_key;

-- Variant rows for these packages identify tiers/prices/capacities, not new
-- physical venues. Normalize each to its mapped parent resource.
update public.package_variants variant
set resource_key = package.resource_key
from public.packages package
where variant.package_id = package.id
  and lower(package.service_type::text) = 'catering'
  and package.resource_key in (
    'catering-alfamart-daffodil-2f',
    'catering-alfamart-amarillo-4f',
    'catering-alfamart-amarillo-3f'
  )
  and variant.resource_key is distinct from package.resource_key;

-- Backfill only missing assignments; retain every existing assignment even
-- when it differs from the package default because it may be an admin override.
update public.reservations reservation
set resource_key = package.resource_key,
    updated_at = now()
from public.packages package
where package.id = reservation.package_id
  and lower(package.service_type::text) = 'catering'
  and package.resource_key in (
    'catering-alfamart-daffodil-2f',
    'catering-alfamart-amarillo-4f',
    'catering-alfamart-amarillo-3f'
  )
  and reservation.resource_key is null
  and lower(reservation.status::text) = 'pending';

notify pgrst, 'reload schema';
