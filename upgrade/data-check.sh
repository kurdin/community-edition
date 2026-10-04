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
# It aborts (non-zero exit) if a database is unreachable or a query fails.
set -eu

CUTOFF="${1:-2100-01-01 00:00:00}"

pg() {
  docker compose exec -T plausible_db psql -U postgres -d plausible_db -At -c "$1" < /dev/null
}

ch() {
  docker compose exec -T plausible_events_db clickhouse-client -d plausible_events_db -q "$1" < /dev/null
}

echo "## PostgreSQL (plausible_db)"
for table in users sites goals shared_links api_keys; do
  exists=$(pg "SELECT to_regclass('public.$table') IS NOT NULL")
  if [ "$exists" = "t" ]; then
    count=$(pg "SELECT count(*) FROM $table")
    echo "$table: $count"
  fi
done

echo "counting events/sessions before $CUTOFF UTC" >&2
echo
echo "## ClickHouse (plausible_events_db)"
events=$(ch "SELECT count() FROM events_v2 WHERE timestamp < toDateTime('$CUTOFF')")
sessions=$(ch "SELECT sum(sign) FROM sessions_v2 WHERE start < toDateTime('$CUTOFF')")
echo "events_v2 rows: $events"
echo "sessions_v2 sessions: $sessions"

# Per site: event count, approximate unique visitors and a checksum over the
# event identity columns (cheap on memory, unlike uniqExact; changes if any
# event is lost, duplicated or altered).
per_site=$(ch "SELECT site_id, count(), uniq(user_id),
                      sum(cityHash64(user_id, session_id, timestamp, name, pathname))
               FROM events_v2 WHERE timestamp < toDateTime('$CUTOFF')
               GROUP BY site_id ORDER BY site_id FORMAT TSV")
echo
echo "### events_v2 per site (site_id, events, unique visitors, checksum)"
echo "$per_site"

imported=$(ch "SELECT table, sum(rows) FROM system.parts
               WHERE database = 'plausible_events_db' AND active AND table LIKE 'imported\\_%'
                 AND table != 'imported_custom_events'
               GROUP BY table ORDER BY table FORMAT TSV")
echo
echo "### imported_* tables (table, rows)"
echo "$imported"
