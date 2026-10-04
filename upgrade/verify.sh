#!/bin/sh
# Checks the upgraded install against the backup baseline (deployment.md,
# step 6).
#
#   ./upgrade/verify.sh
#
# Run from the install directory after `docker compose up -d`. Compares
# upgrade/data-check.sh output (events and sessions up to the backup cutoff,
# so new traffic doesn't count) with the baseline taken by
# upgrade/backup.sh. Checks the app's readiness endpoint. Prints
# "UPGRADE VERIFIED" if everything matches.
set -eu

[ -f upgrade.vars ] || { echo "upgrade.vars not found: run from the install directory" >&2; exit 1; }
. ./upgrade.vars
: "${PROJECT:?}" "${BACKUP:?}"
SCRIPTS_DIR=$(cd "$(dirname "$0")" && pwd)

echo "-> waiting for the app to be ready"
tries=0
until docker compose exec -T plausible wget -q -O /dev/null http://127.0.0.1:8000/api/system/health/ready < /dev/null 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -lt 90 ] || { echo "the app did not become ready, see: docker compose logs plausible" >&2; exit 1; }
  sleep 2
done
echo "   app is ready"

echo "-> comparing data with the backup baseline"
"$SCRIPTS_DIR/data-check.sh" "$(cat "$BACKUP/cutoff.txt")" > "$BACKUP/after.txt"
if diff "$BACKUP/before.txt" "$BACKUP/after.txt"; then
  echo "UPGRADE VERIFIED: data matches the backup taken before the upgrade."
  echo "Check the dashboard too. When you're happy, run ./upgrade/finalize.sh to delete the backup."
else
  echo "data differs from the baseline (diff above). Investigate, or roll back with:" >&2
  echo "  . ./upgrade.vars && \"\$BACKUP/rollback.sh\"" >&2
  exit 1
fi
