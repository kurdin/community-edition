#!/bin/sh
# Checks that the ClickHouse tables have every column the app writes, so new
# events and sessions can be stored (MIGRATION-GUIDE.md, troubleshooting).
#
#   ./upgrade/check-columns.sh          # report only; non-zero exit if something is missing
#   ./upgrade/check-columns.sh --fix    # also add missing optional columns
#
# Run from the install directory. Some installs miss columns that a migration
# recorded as applied but that their tables don't have (e.g. after an old
# v1 -> v2 data migration recreated events_v2). The app then accepts events
# (HTTP 202) but can't store them: "No such column revenue_source_amount".
# --fix adds those columns with ADD COLUMN IF NOT EXISTS: a metadata-only
# change that doesn't rewrite or touch existing data. Missing core columns
# can't be fixed this way and are only reported.
# Prints "COLUMNS OK" when everything is present.
set -eu

FIX=false
case "${1:-}" in
  --fix) FIX=true ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac

ch() {
  docker compose exec -T plausible_events_db clickhouse-client -d plausible_events_db -q "$1" < /dev/null
}

# Columns added by migrations over time: safe to add when missing (table column type)
ADDABLE="events_v2 revenue_source_amount Nullable(Decimal64(3))
events_v2 revenue_source_currency FixedString(3)
events_v2 revenue_reporting_amount Nullable(Decimal64(3))
events_v2 revenue_reporting_currency FixedString(3)
events_v2 scroll_depth UInt8
events_v2 engagement_time UInt32
events_v2 click_id_param LowCardinality(String)
sessions_v2 click_id_param LowCardinality(String)
sessions_v2 exit_page_hostname String
sessions_v2 transferred_from String"

CORE_EVENTS="name site_id hostname pathname user_id session_id timestamp meta.key meta.value referrer referrer_source utm_medium utm_source utm_campaign utm_content utm_term country_code subdivision1_code subdivision2_code city_geoname_id screen_size operating_system operating_system_version browser browser_version acquisition_channel"
CORE_SESSIONS="hostname site_id user_id session_id start duration is_bounce entry_page exit_page pageviews events sign entry_meta.key entry_meta.value utm_medium utm_source utm_campaign utm_content utm_term referrer referrer_source country_code subdivision1_code subdivision2_code city_geoname_id screen_size operating_system operating_system_version browser browser_version timestamp acquisition_channel"

existing=$(ch "SELECT concat(table, ' ', name) FROM system.columns
               WHERE database = currentDatabase() AND table IN ('events_v2', 'sessions_v2')")
has_column() { printf '%s\n' "$existing" | grep -qxF "$1 $2"; }

problems=0
for c in $CORE_EVENTS; do
  has_column events_v2 "$c" || { echo "MISSING core column events_v2.$c (can't be added automatically)" >&2; problems=1; }
done
for c in $CORE_SESSIONS; do
  has_column sessions_v2 "$c" || { echo "MISSING core column sessions_v2.$c (can't be added automatically)" >&2; problems=1; }
done

while read -r table column type; do
  if ! has_column "$table" "$column"; then
    if [ "$FIX" = true ]; then
      ch "ALTER TABLE $table ADD COLUMN IF NOT EXISTS $column $type"
      echo "   added $table.$column $type"
    else
      echo "MISSING $table.$column $type (fix: ./upgrade/check-columns.sh --fix)" >&2
      problems=1
    fi
  fi
done <<EOF
$ADDABLE
EOF

[ "$problems" -eq 0 ] || { echo "columns are missing: new events can't be stored" >&2; exit 1; }
echo "COLUMNS OK"
