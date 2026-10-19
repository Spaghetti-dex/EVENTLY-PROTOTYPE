# EVENTLY Resort/Staycation pricing deployment

No database script runs automatically from this repository. Test on a disposable
Supabase project first. Keep the full output of both read-only preflights:

- `supabase/verification/EVENTLY_POOL_PRICING_PREFLIGHT.sql`
- `supabase/verification/EVENTLY_RESORT_STAYCATION_PREFLIGHT.sql`

If the live privilege preflight confirms direct browser-role writes to
reservations/orders/payments, review and, if approved by the database owner,
manually execute `supabase/repair/EVENTLY_POOL_PRICING_EMERGENCY_GUARD.sql` before
applying migrations. It blocks new pool-tour inserts and revokes direct lifecycle
DML while preserving existing rows and the guarded RPCs.

## Ordered steps

1. Inspect the migration ledger and full booking/payment function definitions.
   Apply `20261017110000_evently_schedule_holds_and_auto_confirmation.sql` only
   if it is not already recorded. Before applying it, its preflight requires the
   all earlier repository migrations in order, including the booking/schedule
   foundation (`20261008000000`, `20261008030000`, `20261008060000`,
   `20261010080000`), Admin/catalog/payment/schedule chain (`20261014110000`,
   `20261014120000`, `20261014130000`), reservation/resource/booking wrappers
   (`20261015130000`, `20261015140000`, `20261015150000`, `20261015160000`),
   and catalog alignment (`20261017100000`). Also confirm the Staff/Admin
   support tables and functions required by its preflight are present. Use
    `supabase/verification/20261017_schedule_holds_deployment_preflight.sql` to
    confirm the complete signature/object chain. The migration refuses unexpected
    signatures, resources, schedules, or active reservation states. It reconciles
    `packages_pricing_mode_check` to include `per_booking`, preserves the existing
    `per_booking` and `per_guest` values, and keeps `per_booking` as the default. It leaves
   every pool-capacity flag unverified; existing `guest_capacity` values remain
   legacy metadata and are not approval evidence.
 2. Apply `20261018160000_evently_pool_per_guest_capacity_safe.sql`. It preserves
    the Day/Night minimum of 1 and Overnight minimum of 20, leaves each maximum
    unset, and validates per-person formulas. It does **not** mark physical
    capacity as verified or create an audit row.
   It verifies and sets each cottage add-on's `resort` compatibility, maps the
   package `cottage_addon_id`, and rejects duplicate cottage add-on selections.
   Pool bookings remain blocked unless a valid Administrator audit already
   exists.
3. Review `supabase/verification/EVENTLY_RESORT_STAYCATION_PREFLIGHT.sql`, then
   apply `20261019090000_evently_resort_staycation_pricing.sql`. This configures
   Standard Room at ₱3,000 per room/night for 4–5 guests per room, Kubo at ₱1,500
   per room/night without inventing a capacity, Non-Aircon Venue Only at
   ₱10,000/5 hours, Aircon Venue Only at ₱15,000/4 hours, and a distinct optional
   ₱5,000 Pool Access charge for eligible room/venue packages. Existing operating
   hours, physical room inventory, and venue resource assignments are not guessed.
 4. In the authenticated Administrator catalog, open each Day, Night, and
    Overnight package, verify the actual physical pool maximum on site, enter
    that value and the required verification note, and save through
    `evently_admin_set_pool_capacity`. Do not copy `guest_capacity` or presume a
    value of 50. This must create three user-attributed `authenticated_admin_rpc`
    audit records that match the package maxima. The RPC also synchronizes the
    shared `evently_resources.capacity`; all verified tours on that resource
    must agree on the same maximum.
   Without this step, all pool bookings remain paused by design.
5. Configure any missing Venue Only operating hours and existing venue/resource
   assignments using the Admin schedule/resource workflow. The durations are
   fixed by the rate sheet; opening/closing times are not supplied and must not
   be inferred. Room bookings continue through their existing Administrator
   schedule/resource assignment workflow.
6. After the capacity audit and required schedule setup, run
   `supabase/verification/EVENTLY_POOL_PRICING_VERIFICATION.sql` and
   `supabase/verification/EVENTLY_RESORT_STAYCATION_VERIFICATION.sql`. Then run
   `supabase/verification/20261017_staycation_booking_rpc_behavior.sql` and the
   two-session `supabase/verification/run_concurrent_pool_booking_test.sh` with
   test accounts. The scripts require a real verified capacity and do not change
    booking or payment rows.

If you apply a migration by pasting it into SQL Editor, that does not record its
version in `supabase_migrations.schema_migrations`. Do not insert ledger rows by
hand; reconcile the migration state before a later CLI `db push`.

## Capacity and legacy values

`max_guest_count` remains NULL until an Administrator explicitly verifies the
physical limit. The booking total RPC requires that value to match the shared
resource capacity, an authenticated Admin audit record, `pool_capacity_verified_by`,
and a non-null verification timestamp; it then rejects guest counts above the
recorded maximum.
The older `guest_capacity` field is preserved and is never used as physical
capacity evidence. Future capacity changes or withdrawals must go through the
audited Admin RPC and include a reason.

Kubo's capacity is left as currently configured; the migration does not supply a
new cap. If the existing value is NULL, no maximum is enforced. Room rates are
calculated per room per night; Standard Room occupancy is 4–5 guests for each
booked room. Pool Access is charged once only when explicitly selected, never
bundled into a tour or room/venue price.
