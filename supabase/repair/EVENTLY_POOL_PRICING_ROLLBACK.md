# Swimming Tour pricing/capacity rollback procedure

## Before applying

Run `supabase/verification/EVENTLY_POOL_PRICING_PREFLIGHT.sql` and retain the
output. Do not apply the migrations if the exact tour IDs, exclusive
`venice-main-pool` resource, fixed tour times, cottage IDs/prices, 30% deposit,
active reservation state, or booking/payment wrapper signatures differ from the
preflight contract. `guest_capacity` is preserved and is not interpreted as the
physical pool maximum.

## SQL error before COMMIT

Both `20261017110000_evently_schedule_holds_and_auto_confirmation.sql` and
`20261018160000_evently_pool_per_guest_capacity_safe.sql` are transactional. If
the SQL editor reports an open transaction after an error, issue `ROLLBACK;`,
retain the full error, and rerun the read-only preflight. Do not remove an
assertion or apply selected migration blocks.

## If post-migration verification fails

1. Pool bookings remain paused unless each tour has an authenticated Administrator
   capacity audit. If a verified value must be withdrawn, use the Admin capacity
   editor or `evently_admin_set_pool_capacity` with `false`, `NULL`, and a reason
   for each affected tour.
2. Keep package rows, `guest_capacity`, the package/add-on catalog backup,
   reservations, orders, payments, schedules, capacity audits, and all
   booking/payment RPC layers while investigating. The migrations do not rewrite
   historical booking/payment totals.
3. Rerun the read-only preflight and the applicable verification scripts. Check
   `pool_capacity_verified_by`, `pool_capacity_audit_id`, `verification_source`,
   rate rows, and the complete `guest_capacity` snapshot.
4. Do not restore the old Overnight fixed rate while the per-person wrapper is
   installed, and do not restore RPC definitions by hand. The schedule-hold,
   availability, idempotency, payment-deadline, expiry, and auto-confirmation
   chain must be reviewed as a whole.

There is no safe partial SQL rollback for the schedule-hold and pool-pricing
chain: those migrations compose several existing booking/payment wrappers. If a
full database restore is required, rehearse it on staging from a reviewed
consistent snapshot and verify the complete RPC chain before production. Never
use `DROP ... CASCADE`.

## Capacity audit

The migrations leave `max_guest_count` unset and capacity unverified. An
authenticated Administrator must verify the actual physical maximum on site,
enter it with a reason through the audited Admin RPC for each tour, and create a
matching audit record. No value—including legacy `guest_capacity=50`—is presumed
to be the physical limit. Until each applicable audit matches its package row,
the booking total RPC fails closed.
