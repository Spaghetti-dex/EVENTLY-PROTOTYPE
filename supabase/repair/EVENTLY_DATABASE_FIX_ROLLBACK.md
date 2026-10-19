# EVENTLY database repair — safe recovery plan

## Before running the repair

- Take a Supabase backup/snapshot and retain the read-only preflight output.
- Run on staging first.
- The repair runs in a transaction. If any preflight, DDL, data-projection, or
  grant statement errors before `COMMIT`, PostgreSQL rolls back the transaction.
  Correct the schema mismatch and rerun the preflight; do not remove guards.

## If SQL Editor reports an error

1. Do not run a partial selection from the failed transaction.
2. Record the full error and statement position.
3. Check that the Editor connection did not leave an open transaction. If it
   reports `in transaction`, issue `ROLLBACK;` in that same session.
4. Re-run `EVENTLY_DATABASE_PREFLIGHT.sql` read-only and compare actual columns,
   function signatures, policies, and migration versions with the error.
5. Resolve mismatches on staging, then rerun the complete script as one unit.

## If the transaction committed but post-verification fails

Do **not** drop tables, delete review/reservation data, remove the migration
ledger row, or restore an older booking/payment function from memory. Preserve
the records and capture these read-only outputs first:

- `EVENTLY_DATABASE_PREFLIGHT.sql`
- `EVENTLY_DATABASE_REPAIR_VERIFICATION.sql`
- `pg_get_functiondef` for the affected RPCs and current `pg_policies` rows
- Admin activity log entries related to review moderation

The repair is designed to be forward-recoverable. If the issue is limited to
anonymous review visibility, immediately disable the public grants while
retaining the base data:

```sql
begin;
revoke all on public.evently_public_reviews from public, anon, authenticated;
revoke all on public.reviews from public, anon;
do $$
declare v_columns text;
begin
  select string_agg(pg_catalog.quote_ident(a.attname), ', ' order by a.attnum) into v_columns
  from pg_catalog.pg_attribute a where a.attrelid='public.reviews'::regclass and a.attnum>0 and not a.attisdropped;
  if v_columns is not null then execute pg_catalog.format('revoke select (%s) on public.reviews from public, anon',v_columns); end if;
end;
$$;
commit;
```

This temporarily hides public reviews; it does not delete them or affect
customer-owned/authenticated Admin data. Repair the view/policy/grant mismatch
on staging, then restore only the intended safe-view `SELECT` grants after
verification. Do not grant anonymous access to `reviews` or private
`reservations`, `profiles`, or `payments` tables to restore the page.

If the issue affects booking, payment, resource availability, or the scheduled
expiry job, stop booking mutations through the application and use the existing
schedule-hold migration's reviewed recovery process. Do not rename or replace
the active booking/payment RPC chain with simplified functions. In particular,
preserve `payment_due_at`, `expired_at`, payment proofs, the override audit,
and all existing reservations until an Administrator/database owner reviews a
staging recovery plan.

## Reversal boundaries

- Do not delete the rate-limit rows or sentiment history as part of rollback.
- Do not drop the one-review unique index while duplicate submissions could
  occur.
- Do not drop `public_review_text` or `service_category`; they are additive
  projections and preserve original `review_text`.
- Do not delete Catering change-request rows or remove the reservation guard
  trigger as a shortcut. Those rows are the approval audit for 72-hour requests;
  retain them and disable customer request submission only through a separately
  reviewed feature flag/permission change if recovery requires it.
- Do not remove the existing `20261017110000` schedule-hold migration or cron
  job as part of review rollback.
- Any rollback that changes business records or removes database objects
  requires a reviewed, separately tested SQL plan and a current backup.
