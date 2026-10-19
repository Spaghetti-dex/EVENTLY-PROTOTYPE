# EVENTLY database repair — deployment instructions

## Important scope and live-database status

No live Supabase connection was available in the coding environment. The repair
has **not** been executed against the project. Run the read-only preflight first
and retain its results. The master repair is fail-closed: it preserves the
existing booking/payment RPC chain and stops before changes if the prepared
schedule-hold migration, pool catalog, staff permissions, or core RLS state do
not match.

Files:

- `supabase/verification/EVENTLY_DATABASE_PREFLIGHT.sql` — read-only live
  inventory; run first.
- `supabase/repair/EVENTLY_COMPLETE_DATABASE_FIX.sql` — one transaction,
  copy/paste repair for reviews, automatic clean-review publication, anonymous
  projection, and database-enforced Catering change requests; it checks and
  preserves the existing booking/payment/Staff workflows.
- `supabase/verification/EVENTLY_DATABASE_REPAIR_VERIFICATION.sql` —
  post-repair, read-only assertions and reports.
- `supabase/repair/EVENTLY_DATABASE_FIX_ROLLBACK.md` — non-destructive recovery.

## Apply with Supabase SQL Editor

1. Take a current Supabase backup/snapshot and use a staging project first.
2. Open **SQL Editor** in the intended project and run the complete contents of
   `supabase/verification/EVENTLY_DATABASE_PREFLIGHT.sql`. It only reads system
   catalogs and business catalog rows; it does not change data.
3. Confirm the migration ledger contains `20261017110000`, or confirm manually
   that its deadline, expiry, schedule-hold, auto-confirmation, audited override,
   and cron objects all exist. The complete repair will stop if the hold chain
   is missing. Do not bypass that guard or paste the schedule-hold migration a
   second time.
4. Confirm the three existing pool packages, the exclusive `venice-main-pool`
   resource, cottage rows, rates, minimum guest counts, and 30% deposit match the
   business-approved values printed by preflight. This repair does not insert,
   update, or delete packages, add-ons, resources, or schedules.
5. Review the complete script, then paste and run
   `supabase/repair/EVENTLY_COMPLETE_DATABASE_FIX.sql` in SQL Editor. The script
   is wrapped in a transaction and aborts on incompatible schema, privileges,
   pool configuration, or pre-existing duplicate reviews. An error rolls back
   its changes; do not remove failing assertions to force it through.
6. Run `supabase/verification/EVENTLY_DATABASE_REPAIR_VERIFICATION.sql` and
   retain the result. Also run the existing booking/payment and schedule-hold
   behavioral verification scripts against a **disposable/staging database**.
 7. Confirm a customer can review their own completed reservation, a second
    review is rejected, clean feedback is immediately published, flagged
    feedback remains private, and the Admin Reviews page reports ready. Also
    verify Catering cancellation/reschedule requests at exactly 72 hours are
    accepted, requests inside 72 hours are rejected, unapproved change attempts
    are blocked, and the Admin decision writes the audited schedule override.
    Confirm the other service categories still use their existing schedule and
    payment RPCs.

Running SQL Editor does not record a Supabase CLI migration version. Do not
insert rows into `supabase_migrations.schema_migrations` manually. If you later
resume CLI deployments, preview `supabase db push --dry-run` first; the pending
review migrations are designed to be additive/rerunnable, but inspect the
preview and verify before applying it.

If the preflight shows that `20261017110000` is not applied, stop here. Apply the
already prepared schedule-hold migration using its reviewed deployment guide
on staging first; it contains the established wrappers, pool concurrency,
deadline, expiry, automatic confirmation, override audit, and cron schedule.
This repair intentionally does not duplicate or simplify that 1,495-line
workflow. Re-run preflight before continuing.

## Secrets and sentiment service

The database SQL stores sentiment output only when the existing trusted Edge
Function submits a valid model result. It contains no model key. Keep
`HF_INFERENCE_TOKEN` only in Supabase Edge Function secrets; never put it in a
`NEXT_PUBLIC_` variable. Confirm the existing `server` Edge Function is deployed
with the secret, and check its analysis response and logs in staging. Failed
inference remains pending; star-only feedback is marked unavailable.

## Current test limitations

No SQL was run against production or staging in this workspace. `psql` and the
Supabase CLI were unavailable here, and the repository has no configured
automated test script. TypeScript/build results are reported separately from
database verification; do not treat the SQL files as tested until the checks
above have run against a suitable database.
