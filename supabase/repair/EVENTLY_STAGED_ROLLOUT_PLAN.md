# EVENTLY booking-hold rollout plan — review only

This plan preserves live booking/payment behavior until every phase has been
validated against a staging copy of the actual Supabase schema. No phase is
approved for production by this document.

## Before Phase 1

Run `supabase/verification/EVENTLY_SAFE_ROLLOUT_PREFLIGHT.sql` and
`supabase/verification/EVENTLY_PHASE2_LIVE_RPC_EXPORT.sql` read-only. Export the
full current definitions for the customer booking RPC, its exact-resource
wrapper, payment verification/proof RPCs, every Admin status/approval path, and
all schedule/resource writers. Record their argument names, return types,
SECURITY DEFINER status, privileges, table constraints, triggers, RLS, and lock
keys. Do not author Phase 2 until this export is reviewed.

## Phase 1 — additive foundation candidate

Review `supabase/repair/EVENTLY_PHASE1_SAFE_FOUNDATION.sql`. It adds nullable
deadline/expiration fields and a private audit table only. It has no historical
backfill and does not replace or call booking/payment functions. Run its
read-only verification on staging and compare reservation/payment counts with
the preflight output.

## Phase 2 — coordinated booking holds (blocked on live RPC exports)

Patch the actual live `create_evently_reservation(jsonb)` and all current
schedule/resource writers, preserving each signature and its existing
idempotency key representation. New reservations only receive
`created_at + interval '24 hours'`; existing rows with no deadline remain
untouched. Use one shared resource-lock convention across booking, Admin
reschedule, cancellation/release, payment-confirmation, and expiry paths. Check
full timestamp overlap, including overnight end times, while retaining the
existing conflict/resource rules. Do not require an `orders` row where the live
booking workflow does not create one.

## Phase 3 — payment verification and confirmation (blocked on live RPC exports)

Extend the live `admin_review_payment(uuid,boolean,text)` without changing its
signature. Preserve receipt validation and its anti-reuse lock. Use the live
verified-payment fields and saved service-specific deposit amount. Ensure all
pending-to-confirmed paths, including the live status setter, are guarded by
verified payment and a conflict-free saved schedule. Keep the deliberately
disabled public `evently_admin_approve_booking` entry point disabled until its
replacement is tested.

## Phase 4 — expiration (blocked on the deployed scheduler decision)

Use a scheduler that is actually available in the project (Supabase scheduler
or an Edge Function) after the expiry function is tested. Do not assume
`pg_cron`. Never expire historical reservations whose deadline is NULL. A
timely pending payment proof must hold the schedule until its review resolves.
Use a consistent lock acquisition order to avoid deadlocks.

## Phase 5 — Swimming Tour pricing

Use the corrected existing pool-pricing migration only after the actual booking
chain is compatible. Validate the submitted guest count and capacity before
calling a legacy inner RPC; do not rewrite the payload guest count. Keep the
three tour rates, optional cottage IDs/fees, and 30% configured deposit, and
leave pool bookings blocked until the authenticated Administrator capacity audit
is valid.

## Staging tests before production

- Confirm all eight supplied historical reservations and five payments retain
  their original rows, totals, statuses, proof references, and deposit values.
- Test new bookings across `per_booking`, `per_guest`, and other actual live
  pricing modes; service-specific deposit rates must remain unchanged.
- Test text idempotency keys, retries, duplicate key races, and the live booking
  path when no order row is created.
- Test valid/invalid proof, duplicate receipt reuse, verification and confirmation
  racing expiry, and all alternate status/approval paths.
- Race booking against Admin reschedule/cancel/release using the same physical
  resource, including cross-midnight overlaps and next-day slots.
- Verify Customer, Staff, Admin, and Owner permissions and the existing disabled
  approval placeholder.
- Verify a historical confirmed-but-unpaid reservation remains unchanged and is
  never expired or demoted.
- Rehearse rollback from a consistent staging snapshot; retain audit history and
  never use `DROP ... CASCADE`.
