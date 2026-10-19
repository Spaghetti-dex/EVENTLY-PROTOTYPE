# Phase 1 foundation rollback considerations

`EVENTLY_PHASE1_SAFE_FOUNDATION.sql` is an additive review candidate. It adds
nullable `payment_due_at` and `expired_at` columns without defaults or backfill,
and creates a private override-audit table. It does not alter RPCs or existing
reservation/payment rows.

If Phase 1 fails before `COMMIT`, PostgreSQL rolls back the transaction. If it
commits, prefer leaving the additive columns and audit table in place while
investigating. Do not drop the audit table if it contains rows, and do not drop
the deadline columns after any later phase has begun writing them. A database
restore, if required, must be rehearsed from a consistent snapshot and must
preserve later audit records and booking/payment history.

Phase 1 does not enable deadlines, expire bookings, or confirm reservations. A
Phase 2 implementation must first be authored against the live RPC definitions
exported by `EVENTLY_PHASE2_LIVE_RPC_EXPORT.sql`.
