#!/bin/sh
# Checks the upgraded install against the backup baseline (deployment.md,
# step 6).
#
#   ./upgrade/verify.sh
#
# Run from the install directory after `docker compose up -d`. Compares
# upgrade/data-check.sh output (events and sessions up to the backup cutoff,
# so new traffic doesn't count) with the baseline taken by
# upgrade/backup.sh. Checks the app's readiness endpoint, that every column
# the app writes exists, and that the app logs no write errors. Prints
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

# Data can match while new events still fail to be written (a missing column
# makes every insert fail, although the app answers 202), so check that too.
echo "-> checking that new events can be stored"
if ! "$SCRIPTS_DIR/check-columns.sh"; then
  echo "fix with ./upgrade/check-columns.sh --fix, then rerun ./upgrade/verify.sh" >&2
  exit 1
fi
sleep 20
write_errors=$(docker compose logs --since 60s plausible 2>&1 | grep -cE 'No such column|WriteBuffer terminating' || true)
if [ "$write_errors" -gt 0 ]; then
  docker compose logs --since 60s plausible 2>&1 | grep -E 'No such column|WriteBuffer terminating' | tail -3 >&2
  echo "the app logged $write_errors errors writing to ClickHouse: new events are NOT being stored (see above)" >&2
  exit 1
fi
echo "   no write errors"

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
