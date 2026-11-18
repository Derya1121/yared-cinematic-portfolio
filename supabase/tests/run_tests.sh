#!/usr/bin/env bash
# Database tests for the Stage 8 migration. Throw-away local Postgres ONLY.
#   PGHOST=/tmp PGPORT=54329 PGUSER=postgres ./run_tests.sh
# Needs psql and a Postgres 15+ server you own. Creates and drops database derya_stage8_test.
# It never contacts Supabase and refuses to run if the host looks remote.
set -euo pipefail
cd "$(dirname "$0")"
case "${PGHOST:-}" in ""|localhost|127.0.0.1|/*) ;; *) echo "refusing to run against remote host $PGHOST"; exit 2;; esac
DB=derya_stage8_test
MIGS=("${MIG_DIR:-../migrations}"/*.sql)   # every migration, in filename order (MIG_DIR only for runner self-tests)
P="psql -X -q -v ON_ERROR_STOP=1"

$P -d postgres -c "drop database if exists $DB" -c "create database $DB"
trap '$P -d postgres -c "drop database if exists $DB" >/dev/null 2>&1; $P -d postgres -c "drop role if exists t_owner" >/dev/null 2>&1' EXIT

# Applies one SQL file. ANY non-zero psql exit status (ON_ERROR_STOP=1 makes SQL errors non-zero) stops the
# whole runner at once. psql's full output is kept and shown on failure so the SQL error stays readable.
apply_sql() {
  local file="$1" out; out=$(mktemp)
  if ! $P -d $DB -f "$file" >"$out" 2>&1; then
    echo "FAIL: psql exited non-zero applying $(basename "$file")"; cat "$out"; exit 1
  fi
  if grep -q "ERROR:" "$out"; then   # belt and braces: an ERROR line with exit 0 is still a failure
    echo "FAIL: $(basename "$file") printed an ERROR"; cat "$out"; exit 1
  fi
  sed '/NOTICE:/d' "$out"             # show anything useful, minus idempotency notices
}

echo "== apply test stubs, then every migration in order"
apply_sql 00_test_stubs.sql
for m in "${MIGS[@]}"; do echo "applying $(basename "$m")"; apply_sql "$m"; done

# Structure snapshot after the first application (tables, columns, policies, functions, grants...).
schema_dump() { pg_dump -s -n public -n private -n storage "$DB" 2>/dev/null | grep -vE '^(--|SET |\\restrict |\\unrestrict |SELECT pg_catalog\.set_config)' ; }
HAVE_DUMP=0; command -v pg_dump >/dev/null 2>&1 && HAVE_DUMP=1
if [ $HAVE_DUMP = 1 ]; then BEFORE=$(mktemp); schema_dump > "$BEFORE"; fi

echo "== re-apply every migration: it must succeed again AND leave the schema unchanged (idempotency)"
for m in "${MIGS[@]}"; do echo "re-applying $(basename "$m")"; apply_sql "$m"; done
if [ $HAVE_DUMP = 1 ]; then
  AFTER=$(mktemp); schema_dump > "$AFTER"
  if ! diff -u "$BEFORE" "$AFTER" >/tmp/idempotency.diff; then echo "FAIL: second application changed the schema"; head -40 /tmp/idempotency.diff; exit 1; fi
  echo "schema identical after the second application ($(wc -l < "$BEFORE") dump lines compared)"
else
  echo "NOTE: pg_dump not found; idempotency checked by exit status only"
fi
echo "migrations applied twice without error"

echo "== assertions"
LOG=$(mktemp)
if ! $P -d $DB -f 01_stage8.test.sql >"$LOG" 2>&1; then
  grep -E "FAIL|ERROR" "$LOG" || cat "$LOG"
  exit 1
fi
echo "assertions passed: $(grep -c 'PASS:' "$LOG")"
grep -E "ALL SQL" "$LOG"

echo "== concurrency: 12 workers claim 20 queued deliveries (one per booking, mixed channels); none may be claimed twice"
$P -d $DB -c "delete from public.notification_deliveries; delete from public.bookings;"
$P -d $DB -c "insert into public.bookings (reference,name,email,service,description,dedupe_hash)
  select 'DB-C'||lpad(g::text,5,'0'),'C'||g,'c'||g||'@example.com','other','concurrency test row '||g,'h'||g from generate_series(1,20) g;
  update public.bookings set delivery_channel = case when right(reference,1) in ('0','2','4','6','8') then 'whatsapp' else 'telegram' end;
  insert into public.notification_deliveries (booking_id, channel) select id, delivery_channel from public.bookings;"
OUT=$(mktemp)
for i in $(seq 1 12); do
  ( $P -d $DB -At -c "set role service_role; select (e->>'id') from jsonb_array_elements(public.claim_notifications_v1(5)) e" >> "$OUT" 2>&1 ) &
done
wait
TOTAL=$(grep -cE '^[0-9a-f-]{36}$' "$OUT" || true)
UNIQ=$(grep -E '^[0-9a-f-]{36}$' "$OUT" | sort -u | wc -l)
echo "claimed rows: $TOTAL, distinct: $UNIQ"
[ "$TOTAL" = "$UNIQ" ] && [ "$TOTAL" = "20" ] || { echo "FAIL: expected 20 distinct claims (one delivery per booking), got $TOTAL total / $UNIQ distinct"; exit 1; }
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
[ "$STORED" = "1" ] && [ "$NOTIF" = "1" ] || { echo "FAIL: expected exactly 1 booking and 1 notification (single selected channel), got $STORED bookings / $NOTIF notifications"; exit 1; }
echo "PASS: 8 simultaneous identical submissions stored exactly one booking"
echo "ALL DATABASE TESTS PASSED"
