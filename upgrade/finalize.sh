#!/bin/sh
# Finishes an upgrade once you've validated it (deployment.md, step 8):
# deletes the backup and the leftovers the upgrade kept for safety.
#
#   ./upgrade/finalize.sh                       # asks for confirmation
#   ./upgrade/finalize.sh --yes
#   ./upgrade/finalize.sh --ignore-data-check   # differences you know are expected
#
# Run from the install directory. It first re-checks the data against the
# pre-upgrade baseline and refuses to delete anything if it differs. Then it
# removes:
#   * the backup directory ($BACKUP from upgrade.vars)
#   * the ClickHouse table left by the sessions_v2 engine conversion
#     (sessions_v2_tmp_versioned or sessions_v2_backup[_<time>])
#   * empty leftovers of the old v1 -> v2 data migration
#     (tmp_events_v2, tmp_sessions_v2, domains_lookup)
#   * the ${PROJECT}_db-data-pg14 volume (only exists after a Postgres 16 move)
#   * upgrade.vars
# After this, rolling back is no longer possible.
set -eu

YES=false
IGNORE_DATA_CHECK=false
for arg in "$@"; do
  case "$arg" in
    --yes) YES=true ;;
    --ignore-data-check) IGNORE_DATA_CHECK=true ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

[ -f upgrade.vars ] || { echo "upgrade.vars not found: nothing to finalize" >&2; exit 1; }
. ./upgrade.vars
: "${PROJECT:?}" "${BACKUP:?}"

echo "This permanently deletes:"
echo "  backup directory:  $BACKUP ($(du -sh "$BACKUP" 2>/dev/null | cut -f1))"
echo "  ClickHouse tables: sessions_v2_tmp_versioned / sessions_v2_backup* (if present)"
echo "  Docker volume:     ${PROJECT}_db-data-pg14 (if present)"
echo "After this you can no longer roll back."
if [ "$YES" != true ]; then
  printf 'Type "delete" to continue: '
  read -r answer < /dev/tty
  [ "$answer" = "delete" ] || { echo "aborted"; exit 1; }
fi

# last safety net: the data must still match the baseline taken before the upgrade
SCRIPTS_DIR=$(cd "$(dirname "$0")" && pwd)
"$SCRIPTS_DIR/data-check.sh" "$(cat "$BACKUP/cutoff.txt")" > "$BACKUP/finalize-check.txt"
if ! diff "$BACKUP/before.txt" "$BACKUP/finalize-check.txt"; then
  if [ "$IGNORE_DATA_CHECK" = true ]; then
    echo "data differs from the pre-upgrade baseline (diff above), continuing because of --ignore-data-check" >&2
  else
    echo "data differs from the pre-upgrade baseline (diff above): not deleting the backup." >&2
    echo "If every difference is expected (e.g. a site deleted after the upgrade), rerun with --ignore-data-check." >&2
    exit 1
  fi
fi

engine=$(docker compose exec -T plausible_events_db clickhouse-client -d plausible_events_db \
  -q "SELECT engine FROM system.tables WHERE database = currentDatabase() AND name = 'sessions_v2'" < /dev/null)
case "$engine" in
  *VersionedCollapsingMergeTree) ;;
  *) echo "sessions_v2 is '$engine', not VersionedCollapsingMergeTree: the migration didn't finish, not deleting anything" >&2; exit 1 ;;
esac

leftovers=$(docker compose exec -T plausible_events_db clickhouse-client -d plausible_events_db \
  -q "SELECT name FROM system.tables WHERE database = currentDatabase()
        AND (name = 'sessions_v2_tmp_versioned' OR name LIKE 'sessions\\_v2\\_backup%')" < /dev/null)
# empty leftovers of the old v1 -> v2 data migration (NumericIDs), if present
leftovers="$leftovers $(docker compose exec -T plausible_events_db clickhouse-client -d plausible_events_db \
  -q "SELECT name FROM system.tables WHERE database = currentDatabase()
        AND name IN ('tmp_events_v2', 'tmp_sessions_v2', 'domains_lookup') AND total_rows = 0" < /dev/null)"
for table in $leftovers; do
  docker compose exec -T plausible_events_db clickhouse-client -d plausible_events_db \
    -q "DROP TABLE IF EXISTS $table" < /dev/null
done
if docker volume inspect "${PROJECT}_db-data-pg14" > /dev/null 2>&1; then
  docker volume rm "${PROJECT}_db-data-pg14" > /dev/null
fi
rm -rf "$BACKUP"
rm -f upgrade.vars
echo "FINALIZED: backup and upgrade leftovers removed."
