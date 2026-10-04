#!/bin/sh
# Prints row counts for the Plausible databases so you can compare them
# before and after an upgrade (see deployment.md).
#
#   ./upgrade/data-check.sh                       > before.txt
#   ./upgrade/data-check.sh "2026-10-04 12:00:00" > after.txt
#   diff before.txt after.txt
#
# The optional argument is a UTC cutoff timestamp: only events and sessions
# older than it are counted, so traffic ingested after the upgrade does not
# show up as a difference. Use the time you stopped the old `plausible`
# container. Run it from the directory that holds docker-compose.yml.
set -eu

CUTOFF="${1:-2100-01-01 00:00:00}"

pg() {
  docker compose exec -T plausible_db psql -U postgres -d plausible_db -At -c "$1"
}

ch() {
  docker compose exec -T plausible_events_db clickhouse-client -d plausible_events_db -q "$1"
}

echo "## PostgreSQL (plausible_db)"
for table in users sites goals shared_links api_keys; do
  if [ "$(pg "SELECT to_regclass('public.$table') IS NOT NULL")" = "t" ]; then
    echo "$table: $(pg "SELECT count(*) FROM $table")"
  fi
done

echo
echo "counting events/sessions before $CUTOFF UTC" >&2
echo "## ClickHouse (plausible_events_db)"
echo "events_v2 rows: $(ch "SELECT count() FROM events_v2 WHERE timestamp < toDateTime('$CUTOFF')")"
echo "sessions_v2 sessions: $(ch "SELECT sum(sign) FROM sessions_v2 WHERE start < toDateTime('$CUTOFF')")"

echo
echo "### events_v2 per site (site_id, events, unique user_ids)"
ch "SELECT site_id, count(), uniqExact(user_id) FROM events_v2
    WHERE timestamp < toDateTime('$CUTOFF') GROUP BY site_id ORDER BY site_id
    FORMAT TSV"

echo
echo "### imported_* tables (table, rows)"
ch "SELECT table, sum(rows) FROM system.parts
    WHERE database = 'plausible_events_db' AND active AND table LIKE 'imported\\_%'
      AND table != 'imported_custom_events'
    GROUP BY table ORDER BY table
    FORMAT TSV"
