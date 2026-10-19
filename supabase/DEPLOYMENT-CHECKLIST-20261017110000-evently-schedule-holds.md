# Deployment checklist — EVENTLY guarded booking and Resort/Staycation pricing

Use `supabase/repair/EVENTLY_POOL_PRICING_DEPLOYMENT.md` as the authoritative
ordered deployment guide for migrations `20261017110000`, `20261018160000`, and
`20261019090000`. Do not apply this migration by itself; the later pool-pricing
and Resort/Staycation migrations are required for the final guarded RPC chain.

## Disposable project

1. Restore a recent staging snapshot with the existing package/catalog rows,
   `venice-main-pool` resource, cottage add-ons, booking/payment RPCs, roles,
   private payment bucket, and RLS policies.
2. Seed test Customer and Administrator/Owner profiles. Keep any legacy
   `packages.guest_capacity` values, including NULL values, as they are.
3. Run both read-only preflights from the deployment guide and retain their
   output. Resolve mismatches instead of bypassing assertions.
4. Apply the three migrations in the documented order on staging. Confirm that
    pool bookings remain paused until all three tours have authenticated Admin
    capacity audits. Record the actual on-site physical maximum through the Admin
    UI; do not infer it from the legacy `guest_capacity` value.
5. Configure business-approved Venue Only operating hours/resources through the
   Admin workflow; the migration supplies durations but does not invent opening
   hours or physical inventory.
6. Run pool and Resort/Staycation verification, the rollback behavior checks,
   and the two-session pool-concurrency test. No live production booking or
   payment records should be used as test fixtures.

## Production gate

Take a backup, rerun the read-only preflights against production, review the
active reservation/payment state and the complete RPC definitions, and inspect
the Supabase CLI dry-run before applying. Execute only the migrations in the
reviewed order. Do not run behavioral fixtures against production.

For an SQL error before `COMMIT`, roll back the transaction and rerun the
preflights. For a committed deployment, use the corresponding procedures in
`supabase/repair/EVENTLY_POOL_PRICING_ROLLBACK.md` and
`supabase/repair/EVENTLY_RESORT_STAYCATION_ROLLBACK.md`; do not restore selected
RPCs or use `DROP ... CASCADE`.
