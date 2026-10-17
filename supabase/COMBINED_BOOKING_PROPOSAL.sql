-- PROPOSAL ONLY — DO NOT APPLY.
--
-- The current reservations/create_evently_reservation contract stores one
-- package_id, one package_variant_id, one resource_key, and one total. The
-- optional Catering + Events Place flows need a linked component model so one
-- reservation/payment/review record can contain both service selections.
--
-- This additive table is the minimum data shape to review. It intentionally
-- does not alter existing reservations, prices, RPCs, RLS, or Admin/Staff
-- authorization. It is not sufficient to launch combined booking by itself.
--
-- Before converting this proposal into an executable migration, the database
-- owners must approve:
--   1. The component schema and snapshot semantics.
--   2. A new/extended SECURITY DEFINER booking RPC that writes the parent and
--      components atomically, computes component totals/deposit once, locks
--      actual venue resources, and revalidates availability at submit time.
--   3. Admin/Staff detail, schedule, review, payment, reporting, and RLS access
--      to component data while preserving current permissions.
--   4. A catering availability policy. No catering capacity/parallel-booking
--      rule is represented in the current catalog, so no “available” result
--      may be returned until an Admin-configured capacity/commitment source is
--      approved. Do not choose a default maximum in application code.
--   5. Current venue-inclusive packages are service_type=event and already
--      include catering. The current booking RPC rejects non-empty menu JSON
--      for those packages. It must support an explicitly included catering
--      component without adding a standalone catering package price.
--   6. Venue-only catalog rows need confirmed package_category, actual active
--      resource_key, schedule mode, and operating hours before they can be
--      offered as selectable inventory. Never infer a resource from the name.
--   7. Payment proof and Admin/Staff approval must remain attached to one parent
--      reservation and its single calculated total.
--
-- Proposed additive schema (review only):
/*
create table public.evently_reservation_components (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  component_type text not null check (component_type in ('catering', 'event_venue')),
  package_id uuid references public.packages(id),
  package_variant_id uuid references public.package_variants(id),
  resource_key text references public.evently_resources(resource_key),
  is_included boolean not null default false,
  guest_count integer not null check (guest_count > 0),
  reservation_date date not null,
  start_time time,
  end_time time,
  component_subtotal numeric(12,2) not null check (component_subtotal >= 0),
  selected_menu jsonb not null default '{}'::jsonb,
  selected_addons jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  check (is_included or package_id is not null),
  check (component_type <> 'event_venue' or is_included or resource_key is not null),
  unique (reservation_id, component_type)
);

create index evently_reservation_components_resource_time_idx
  on public.evently_reservation_components (resource_key, reservation_date, start_time, end_time)
  where resource_key is not null;

create index evently_reservation_components_package_idx
  on public.evently_reservation_components (package_id, package_variant_id);

-- Catering availability requires an explicitly configured service window.
-- Keep this empty until the business defines max parallel events and/or guest
-- capacity for each window. An empty/missing row means “availability unknown”,
-- not available.
create table public.evently_catering_capacity_windows (
  id uuid primary key default gen_random_uuid(),
  service_date date not null,
  start_time time not null,
  end_time time not null,
  max_parallel_events integer not null check (max_parallel_events > 0),
  max_guests integer check (max_guests > 0),
  is_open boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_time <> start_time),
  unique (service_date, start_time, end_time)
);

create index evently_catering_capacity_windows_date_idx
  on public.evently_catering_capacity_windows (service_date, start_time, end_time)
  where is_open;
*/

-- Venue-inclusive Events Place packages should store an included catering
-- component with zero additional subtotal; standalone catering plus venue-only
-- should store two independently priced components. The final RPC must reject
-- menu/add-on price duplication and calculate deposit/payment once at the parent.
-- Proposed RPC responsibilities (not implemented here):
--   * check both services against the selected date/time, component IDs, actual
--     resource key and the Admin-configured catering window;
--   * return “unknown” when catering capacity is not configured;
--   * repeat those checks under transaction/advisory locks immediately before
--     writing one parent reservation and its component rows;
--   * preserve the caller idempotency key and calculate bundle/deposit/remaining
--     amounts once, while leaving existing create_evently_reservation and
--     payment/admin approval contracts untouched for standalone bookings.
