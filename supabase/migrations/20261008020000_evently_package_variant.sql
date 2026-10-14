-- Preserve the selected variant name as a historical reservation snapshot.
-- The package_variants table is the source of truth for selectable variants.

alter table public.reservations
  add column if not exists package_variant text;

notify pgrst, 'reload schema';
