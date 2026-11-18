#!/usr/bin/env bash
# Database tests for the Stage 8 migration. Throw-away local Postgres ONLY.
#   PGHOST=/tmp PGPORT=54329 PGUSER=postgres ./run_tests.sh
# Needs psql and a Postgres 15+ server you own. Creates and drops database derya_stage8_test.
# It never contacts Supabase and refuses to run if the host looks remote.
set -euo pipefail
cd "$(dirname "$0")"
case "${PGHOST:-}" in ""|localhost|127.0.0.1|/*) ;; *) echo "refusing to run against remote host $PGHOST"; exit 2;; esac
DB=derya_stage8_test
MIGS=(../migrations/*.sql)   # every migration, in filename order
P="psql -X -q -v ON_ERROR_STOP=1"

$P -d postgres -c "drop database if exists $DB" -c "create database $DB"
trap '$P -d postgres -c "drop database if exists $DB" >/dev/null 2>&1; $P -d postgres -c "drop role if exists t_owner" >/dev/null 2>&1' EXIT

echo "== apply test stubs, then the migration"
$P -d $DB -f 00_test_stubs.sql
for m in "${MIGS[@]}"; do echo "applying $(basename $m)"; $P -d $DB -f $m 2>&1 | grep -v NOTICE || true; done
echo "== re-apply the migration to prove it is idempotent"
for m in "${MIGS[@]}"; do $P -d $DB -f $m 2>&1 | grep -E "ERROR" && { echo "FAIL: second apply of $m errored"; exit 1; } || true; done
echo "migration applied twice without error"

echo "== assertions"
LOG=$(mktemp)
if ! $P -d $DB -f 01_stage8.test.sql >"$LOG" 2>&1; then
  grep -E "FAIL|ERROR" "$LOG" || cat "$LOG"
  exit 1
fi
echo "assertions passed: $(grep -c 'PASS:' "$LOG")"
grep -E "ALL SQL" "$LOG"

echo "== concurrency: 12 workers claim 40 queued deliveries; none may be claimed twice"
$P -d $DB -c "delete from public.notification_deliveries; delete from public.bookings;"
$P -d $DB -c "insert into public.bookings (reference,name,email,service,description,dedupe_hash)
  select 'DB-C'||lpad(g::text,5,'0'),'C'||g,'c'||g||'@example.com','other','concurrency test row '||g,'h'||g from generate_series(1,20) g;
  insert into public.notification_deliveries (booking_id, channel) select id, delivery_channel from public.bookings;"
OUT=$(mktemp)
for i in $(seq 1 12); do
  ( $P -d $DB -At -c "set role service_role; select (e->>'id') from jsonb_array_elements(public.claim_notifications_v1(5)) e" >> "$OUT" 2>&1 ) &
done
wait
TOTAL=$(grep -cE '^[0-9a-f-]{36}$' "$OUT" || true)
UNIQ=$(grep -E '^[0-9a-f-]{36}$' "$OUT" | sort -u | wc -l)
echo "claimed rows: $TOTAL, distinct: $UNIQ"
[ "$TOTAL" = "$UNIQ" ] && [ "$TOTAL" = "20" ] || { echo "FAIL: expected 40 distinct claims"; exit 1; }
echo "PASS: each delivery was claimed exactly once across 12 parallel workers"

echo "== concurrency: 8 simultaneous identical bookings"
$P -d $DB -c "delete from public.notification_deliveries; delete from public.bookings;"
for i in $(seq 1 8); do
  ( $P -d $DB -At -c "set role service_role; select public.create_booking_v1('{\"name\":\"Racer\",\"email\":\"race@example.com\",\"service\":\"other\",\"description\":\"the very same request sent eight times\"}'::jsonb)->>'duplicate'" >> "$OUT.b" 2>&1 ) &
done
wait
STORED=$($P -d $DB -At -c "select count(*) from public.bookings")
NOTIF=$($P -d $DB -At -c "select count(*) from public.notification_deliveries")
echo "bookings stored: $STORED, notification rows: $NOTIF"
[ "$STORED" = "1" ] && [ "$NOTIF" = "1" ] || { echo "FAIL: expected exactly 1 booking and 2 notifications"; exit 1; }
echo "PASS: 8 simultaneous identical submissions stored exactly one booking"
echo "ALL DATABASE TESTS PASSED"
