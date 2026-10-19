# Resort/Staycation rate migration rollback

Run `supabase/verification/EVENTLY_RESORT_STAYCATION_PREFLIGHT.sql` first and
retain the output. The migration creates a private row snapshot in
`evently_resort_rate_catalog_backup`; use it to compare all four packages before
considering rollback.

`EVENTLY_RESORT_STAYCATION_ROLLBACK.sql` is a manual, transactional rollback for
`20261019090000_evently_resort_staycation_pricing.sql` only. It refuses to run if
the rate packages changed after deployment, restores only the package price,
capacity/minimum/category/pricing mode/Pool Access/deposit/duration fields from
the saved catalog snapshot, and reinstalls the exact prior Swimming Tour
resource-pricing wrapper. It leaves all reservations, orders, payments, room
quantity snapshots, schedule/resource configuration, and historical amounts
untouched. It restores each package's earlier schedule mode but leaves any
Administrator-entered operating hours and resource assignments untouched. The
private backup table is retained for audit.

Apply the rollback only after putting the application on the matching reviewed
version. Optional Pool Access is unavailable after rollback; if the current UI
still shows that option, bookings selecting it will fail closed in the restored
server RPC until the matching application version is restored.

Do not restore a full database snapshot or remove the earlier pool pricing,
schedule-hold, payment-deadline, or capacity-audit migrations as part of this
rollback. If the guard aborts because a catalog row changed, review and reconcile
the values manually rather than overwriting a newer Administrator edit.
