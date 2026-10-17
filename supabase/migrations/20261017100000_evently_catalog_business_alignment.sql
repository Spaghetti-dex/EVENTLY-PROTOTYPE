-- Targeted catalog text/category reconciliation for verified active records.
-- No prices, package IDs, resource keys, reservations, or RPCs are changed.

begin;

update public.catering_menu_items
set category = 'Pasta / Pancit',
    name = 'Mixed Pancit',
    updated_at = now()
where id = '8d685e58-027a-43cc-aed0-e046cf5805fa'
  and category = 'Pancit'
  and name = 'Mixed Pansit'
  and is_active;

update public.catering_menu_items
set category = 'Pasta / Pancit',
    updated_at = now()
where id in (
    'f15b34a7-93f6-4ef3-b61f-529ec7c1a1ce',
    '35721657-117e-47b3-8ac5-ba239949d2b7',
    'be858293-2d1d-46c8-8b43-d61a2a9d6c13',
    '5b2d367e-5303-45f3-ad36-15dc8253d681',
    'ceaa86fb-7fc8-4688-9b0e-d9732a672798'
  )
  and category = 'Pancit'
  and is_active;

update public.catering_menu_items
set name = 'Chopsuey', updated_at = now()
where id = 'c52df1ab-0eb6-45de-9bf0-c79e2c54410e'
  and category = 'Vegetable'
  and name = 'Chopseuy'
  and is_active;

update public.catering_menu_items
set name = 'Iced Tea', updated_at = now()
where id = 'b2fd5e32-c7fe-45ed-b3c1-f7146e637353'
  and category = 'Drinks'
  and name = 'Ice Tea'
  and is_active;

update public.packages
set description = 'Catering at customer-provided venue for 100 guests. Backdrop included.'
where id = 'efb07c79-b467-417c-8fae-05de34224b2b'
  and name = 'Outside Venue Catering — 100 pax'
  and lower(service_type::text) = 'catering'
  and price = 50000
  and package_category = 'outside_catering'
  and description = 'Catering at customer-provided venue for 100 guests. Backdrop is charged separately.';

commit;
