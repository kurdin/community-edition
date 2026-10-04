#!/bin/sh
# Finishes an upgrade once you've validated it (deployment.md, step 8):
# deletes the backup and the leftovers the upgrade kept for safety.
#
#   ./upgrade/finalize.sh          # asks for confirmation
#   ./upgrade/finalize.sh --yes
#
# Run from the install directory. It first re-checks the data against the
# pre-upgrade baseline and refuses to delete anything if it differs. Then it
# removes:
#   * the backup directory ($BACKUP from upgrade.vars)
#   * the ClickHouse table left by the sessions_v2 engine conversion
#     (sessions_v2_tmp_versioned or sessions_v2_backup)
#   * the ${PROJECT}_db-data-pg14 volume (only exists after a Postgres 16 move)
#   * upgrade.vars
# After this, rolling back is no longer possible.
set -eu

[ -f upgrade.vars ] || { echo "upgrade.vars not found: nothing to finalize" >&2; exit 1; }
. ./upgrade.vars
: "${PROJECT:?}" "${BACKUP:?}"

echo "This permanently deletes:"
echo "  backup directory:  $BACKUP ($(du -sh "$BACKUP" 2>/dev/null | cut -f1))"
echo "  ClickHouse tables: sessions_v2_tmp_versioned / sessions_v2_backup (if present)"
echo "  Docker volume:     ${PROJECT}_db-data-pg14 (if present)"
echo "After this you can no longer roll back."
if [ "${1:-}" != "--yes" ]; then
  printf 'Type "delete" to continue: '
  read -r answer < /dev/tty
  [ "$answer" = "delete" ] || { echo "aborted"; exit 1; }
fi

# last safety net: the data must still match the baseline taken before the upgrade
SCRIPTS_DIR=$(cd "$(dirname "$0")" && pwd)
"$SCRIPTS_DIR/data-check.sh" "$(cat "$BACKUP/cutoff.txt")" > "$BACKUP/finalize-check.txt"
if ! diff "$BACKUP/before.txt" "$BACKUP/finalize-check.txt"; then
  echo "data differs from the pre-upgrade baseline (diff above): not deleting the backup" >&2
  exit 1
fi

engine=$(docker compose exec -T plausible_events_db clickhouse-client -d plausible_events_db \
  -q "SELECT engine FROM system.tables WHERE database = currentDatabase() AND name = 'sessions_v2'" < /dev/null)
case "$engine" in
  *VersionedCollapsingMergeTree) ;;
  *) echo "sessions_v2 is '$engine', not VersionedCollapsingMergeTree: the migration didn't finish, not deleting anything" >&2; exit 1 ;;
esac

for table in sessions_v2_tmp_versioned sessions_v2_backup; do
  docker compose exec -T plausible_events_db clickhouse-client -d plausible_events_db \
    -q "DROP TABLE IF EXISTS $table" < /dev/null
done
if docker volume inspect "${PROJECT}_db-data-pg14" > /dev/null 2>&1; then
  docker volume rm "${PROJECT}_db-data-pg14" > /dev/null
fi
rm -rf "$BACKUP"
rm -f upgrade.vars
echo "FINALIZED: backup and upgrade leftovers removed."
