#!/usr/bin/env bash
set -euo pipefail

: "${TEST_DATABASE_URL:?Set TEST_DATABASE_URL to a disposable Supabase database}"
: "${EVENTLY_TEST_DATE:?Set EVENTLY_TEST_DATE to a future non-Sunday date}"
: "${EVENTLY_TEST_CUSTOMER_ID:?Set EVENTLY_TEST_CUSTOMER_ID to a disposable customer profile UUID}"
: "${EVENTLY_TEST_ADMIN_ID:?Set EVENTLY_TEST_ADMIN_ID to a disposable Admin/Owner profile UUID}"

key_a="$(uuidgen | tr '[:upper:]' '[:lower:]')"
key_b="$(uuidgen | tr '[:upper:]' '[:lower:]')"
tmp_dir="$(mktemp -d)"
cleanup_test_rows() {
  psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 \
    -v admin_id="$EVENTLY_TEST_ADMIN_ID" -v request_key_a="$key_a" -v request_key_b="$key_b" \
    -f supabase/verification/20261017_concurrent_pool_booking_cleanup.sql >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup_test_rows EXIT

date_is_available="$(psql "$TEST_DATABASE_URL" -XAtq -v ON_ERROR_STOP=1 -v reservation_date="$EVENTLY_TEST_DATE" \
  -c "select (:reservation_date::date > current_date and extract(dow from :reservation_date::date) <> 0 and public.evently_check_availability('4ae972a8-6503-4776-90c9-899246cbc4dc', :reservation_date::date))")"
if [[ "$date_is_available" != "t" ]]; then
  echo "Test date is not an available future customer-calendar date: $EVENTLY_TEST_DATE" >&2
  exit 1
fi

day_capacity_verified="$(psql "$TEST_DATABASE_URL" -XAtq -v ON_ERROR_STOP=1 \
  -c "select (pool_capacity_verified and (max_guest_count is null or max_guest_count >= 20)) from public.packages where id='4ae972a8-6503-4776-90c9-899246cbc4dc'")"
if [[ "$day_capacity_verified" != "t" ]]; then
  echo "Test is blocked until an Administrator verifies the confirmed Day Tour maximum of 50 guests. No capacity is inferred." >&2
  exit 1
fi

psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 \
  -v customer_id="$EVENTLY_TEST_CUSTOMER_ID" -v reservation_date="$EVENTLY_TEST_DATE" -v request_key="$key_a" \
  -f supabase/verification/20261017_concurrent_pool_booking_attempt.sql >"$tmp_dir/a.log" 2>&1 &
pid_a=$!
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 \
  -v customer_id="$EVENTLY_TEST_CUSTOMER_ID" -v reservation_date="$EVENTLY_TEST_DATE" -v request_key="$key_b" \
  -f supabase/verification/20261017_concurrent_pool_booking_attempt.sql >"$tmp_dir/b.log" 2>&1 &
pid_b=$!

set +e
wait "$pid_a"
status_a=$?
wait "$pid_b"
status_b=$?
set -e

successes=0
if [[ "$status_a" -eq 0 ]]; then successes=$((successes + 1)); fi
if [[ "$status_b" -eq 0 ]]; then successes=$((successes + 1)); fi

if [[ "$successes" -ne 1 ]]; then
  cat "$tmp_dir/a.log" "$tmp_dir/b.log" >&2
  echo "FAIL: expected exactly one of two overlapping bookings to succeed; got $successes" >&2
  exit 1
fi
if [[ "$status_a" -ne 0 ]] && ! grep -Eiq 'available|conflict|held' "$tmp_dir/a.log"; then
  cat "$tmp_dir/a.log" >&2
  echo "FAIL: the losing request failed for a reason other than the schedule conflict" >&2
  exit 1
fi
if [[ "$status_b" -ne 0 ]] && ! grep -Eiq 'available|conflict|held' "$tmp_dir/b.log"; then
  cat "$tmp_dir/b.log" >&2
  echo "FAIL: the losing request failed for a reason other than the schedule conflict" >&2
  exit 1
fi

echo "PASS: concurrent overlapping exclusive-pool booking attempts produced exactly one reservation"
