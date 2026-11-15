#!/usr/bin/env bash
# Runs the database tests against a throw-away Postgres database.
#   PGHOST=/var/run/postgresql PGPORT=54329 PGUSER=postgres ./run_tests.sh
# Needs: psql and a reachable Postgres 15+ server. Creates and drops database derya_portfolio_test.
set -euo pipefail
cd "$(dirname "$0")"
DB=derya_portfolio_test
MIG=../migrations/20261115000000_portfolio_booking_cms.sql
P="psql -X -q -v ON_ERROR_STOP=1"

$P -d postgres -c "drop database if exists $DB" -c "create database $DB"
trap '$P -d postgres -c "drop database if exists $DB" >/dev/null' EXIT

echo "== apply test stubs, then the migration"
$P -d $DB -f 00_test_stubs.sql
$P -d $DB -f $MIG
echo "== re-apply the migration to prove it is idempotent"
$P -d $DB -f $MIG 2>/dev/null
echo "migration applied twice without error"

echo "== assertions"
LOG=$(mktemp)
# the assertions leave rows behind, so they run exactly once per fresh database
if ! $P -d $DB -f 01_booking_cms.test.sql >"$LOG" 2>&1; then
  grep -E "FAIL|ERROR" "$LOG" || cat "$LOG"
  exit 1
fi
echo "assertions passed: $(grep -c 'PASS:' "$LOG")"
grep -E "ALL SQL" "$LOG"

echo "== concurrency: 8 simultaneous requests for the same slot"
$P -d $DB -c "delete from public.bookings; delete from private.booking_attempts;"
SLOT=$($P -d $DB -At -c "select slot_start from public.get_available_slots((select day from public.get_booking_days() where available_slots>0 order by day limit 1)) where available order by slot_start limit 1")
SVC=$($P -d $DB -At -c "select id from public.services where slug='business-automation'")
OUT=$(mktemp)
for i in $(seq 1 8); do
  ( $P -d $DB -At -c "begin; select set_config('request.headers','{\"x-forwarded-for\":\"198.51.100.$i\"}',true); set local role anon; select (public.create_booking('$SVC','$SLOT','Racer $i','racer$i@example.com',null,null,6000))->>'code' is null as won; commit;" >> "$OUT" 2>&1 ) &
done
wait
WON=$(grep -c '^t$' "$OUT" || true)
STORED=$($P -d $DB -At -c "select count(*) from public.bookings where starts_at='$SLOT'")
echo "winners reported: $WON, rows stored for that slot: $STORED"
[ "$STORED" = "1" ] || { echo "FAIL: expected exactly 1 stored booking"; exit 1; }
echo "PASS: exactly one of 8 concurrent bookings was stored"
echo "ALL DATABASE TESTS PASSED"
