# Recovery guide for the schedule-hold migration

There is no safe partial SQL rollback for
`20261017110000_evently_schedule_holds_and_auto_confirmation.sql`. It wraps
multiple booking, payment, availability, Admin approval, and catalog RPCs and
records a private pre-migration catalog snapshot. Dropping/replacing selected
functions can remove idempotency, conflict checks, payment deadlines, or Admin
verification.

## If an error occurs before COMMIT

The migration is transactional. If the SQL Editor reports an open transaction,
issue `ROLLBACK;`, retain the full error, then rerun
`supabase/verification/20261017_schedule_holds_deployment_preflight.sql` and the
read-only pool/Resort preflights. Do not remove assertions or run partial blocks.

## If a committed deployment must be paused

1. Keep the existing RPC chain and all reservation/order/payment history in
   place while investigating.
2. To pause the pool tours, have an authenticated Administrator clear each
   package's capacity through `evently_admin_set_pool_capacity` with `false`,
   `NULL`, and a reason. This preserves historical bookings and makes new pool
   bookings fail closed.
3. If other packages need to stop accepting bookings, use the audited Admin
   catalog control to deactivate only the affected package rows. Do not alter
   historical reservations or payment amounts.
4. Use `evently_schedule_hold_catalog_backup` and the preflight output to compare
   original catalog metadata. In particular, do not assume
   `guest_capacity` was non-null: legacy NULL values must remain valid, and
   pool physical capacity is recorded separately.
5. If a complete restore is required, rehearse it on staging from a reviewed
   consistent database snapshot and validate the full booking/payment RPC chain
   before any production restore. Never use `DROP ... CASCADE` or restore only a
   subset of the wrapped functions.
