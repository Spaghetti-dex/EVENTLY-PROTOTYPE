-- Configure the supplied physical venue mapping without changing prices,
-- package details, variants, or existing reservations. The booking RPC already
-- resolves variant.resource_key before package.resource_key and snapshots the
-- result into reservations.resource_key.

update public.packages
set resource_key = 'catering-alfamart-daffodil-2f',
    updated_at = now()
where lower(service_type::text) = 'catering'
  and (
    lower(name) ~ '(^|[^a-z0-9])package[[:space:]_-]*1([^0-9]|$)'
    or lower(name) like '%basic catering%'
  )
  and resource_key is distinct from 'catering-alfamart-daffodil-2f';

update public.packages
set resource_key = 'catering-alfamart-amarillo-4f',
    updated_at = now()
where lower(service_type::text) = 'catering'
  and (
    lower(name) ~ '(^|[^a-z0-9])package[[:space:]_-]*2([^0-9]|$)'
    or lower(name) like '%standard catering%'
  )
  and resource_key is distinct from 'catering-alfamart-amarillo-4f';

update public.packages
set resource_key = 'catering-alfamart-amarillo-3f',
    updated_at = now()
where lower(service_type::text) = 'catering'
  and (
    lower(name) ~ '(^|[^a-z0-9])package[[:space:]_-]*3([^0-9]|$)'
    or lower(name) like '%premium catering%'
  )
  and resource_key is distinct from 'catering-alfamart-amarillo-3f';

-- Keep every selectable variant on its parent package's physical venue so
-- overlapping bookings across variants contend for the same exclusive resource.
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

notify pgrst, 'reload schema';
