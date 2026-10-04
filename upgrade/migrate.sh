#!/bin/sh
# Upgrades ClickHouse and migrates both databases from Plausible CE v2.0 to
# this fork (deployment.md, step 5).
#
#   ./upgrade/migrate.sh
#
# Run from the install directory after upgrade/backup.sh, after switching to
# the new deployment files and after the Postgres step.
#
# Plausible's data migrations load the application's current schemas, so
# jumping straight from v2.0 to the latest code can fail (e.g. the 2024 site
# imports migration). Instead, this goes through the official releases in
# order, each with the ClickHouse version it was released for:
#
#   ClickHouse 23.8 -> 24.3,   then Plausible CE v2.1.0 -> v2.1.1 -> v2.1.5
#   ClickHouse 24.8 -> 24.12,  then Plausible CE v3.0.1 -> v3.1.0 -> v3.2.0
#   then this fork (image plausible-deviceid:local, built beforehand)
#
# After every step it checks that the event and session counts still match
# the backup baseline. It stops at the first error. Rerunning is safe:
# completed steps are recorded in $BACKUP/migrate.done and skipped.
#
# Why v2.1.0 first: releases before v2.1.2 run all Postgres migrations before
# the ClickHouse ones. v2.1.1's site imports migration reads ClickHouse
# columns/tables (import_id, imported_custom_events) that only v2.1.0's
# ClickHouse migrations create.
# ClickHouse versions older than the one you already run are skipped too.
# Prints "MIGRATIONS OK" at the end.
set -eu

[ -f upgrade.vars ] || { echo "upgrade.vars not found: run upgrade/backup.sh first" >&2; exit 1; }
. ./upgrade.vars
: "${PROJECT:?}" "${BACKUP:?}"
[ -f "$BACKUP/before.txt" ] || { echo "$BACKUP/before.txt not found: run upgrade/backup.sh first" >&2; exit 1; }

RELEASES="ghcr.io/plausible/community-edition"
STAGE_FILE=$(cd "$(dirname "$0")" && pwd)/stage-image.yml
DONE="$BACKUP/migrate.done"
touch "$DONE"

docker image inspect plausible-deviceid:local > /dev/null 2>&1 || {
  echo "image plausible-deviceid:local not found: build it first (docker compose build plausible)" >&2
  exit 1
}

# docker compose with an upstream release image instead of the fork
# (quoted, so install paths with spaces work)
stage_compose() {
  if [ -f docker-compose.override.yml ]; then
    docker compose -f docker-compose.yml -f docker-compose.override.yml -f "$STAGE_FILE" "$@"
  else
    docker compose -f docker-compose.yml -f "$STAGE_FILE" "$@"
  fi
}

expected_events=$(sed -n 's/^events_v2 rows: //p' "$BACKUP/before.txt")
expected_sessions=$(sed -n 's/^sessions_v2 sessions: //p' "$BACKUP/before.txt")
[ -n "$expected_events" ] && [ -n "$expected_sessions" ] || { echo "can't read counts from before.txt" >&2; exit 1; }

check_counts() {
  counts=$(docker compose exec -T plausible_events_db clickhouse-client -q \
    "SELECT (SELECT count() FROM plausible_events_db.events_v2), (SELECT sum(sign) FROM plausible_events_db.sessions_v2) FORMAT CSV" < /dev/null)
  if [ "$counts" != "$expected_events,$expected_sessions" ]; then
    echo "event/session counts changed: expected $expected_events,$expected_sessions, got $counts" >&2
    exit 1
  fi
  echo "   events,sessions = $counts (matches the backup)"
}

done_step() { grep -qx "$1" "$DONE"; }
mark_done() { echo "$1" >> "$DONE"; }

# ClickHouse version currently used by the data (recorded on the first run)
# (CLICKHOUSE_START=23.3.7.5 overrides the detection if the container is gone)
if ! grep -q '^clickhouse-start ' "$DONE"; then
  if [ -n "${CLICKHOUSE_START:-}" ]; then
    start=$CLICKHOUSE_START
  else
    container=$(docker compose ps -aq plausible_events_db)
    [ -n "$container" ] || { echo "no plausible_events_db container: set CLICKHOUSE_START=<version your data was written with>" >&2; exit 1; }
    image=$(docker inspect --format '{{.Config.Image}}' "$container")
    start=${image##*:}
  fi
  echo "clickhouse-start $start" >> "$DONE"
fi
ch_current=$(sed -n 's/^clickhouse-start //p' "$DONE" | sed 's/-alpine$//')
ch_current_step=$(grep '^clickhouse-' "$DONE" | grep -v '^clickhouse-start' | tail -n 1 | sed 's/^clickhouse-//')
[ -n "$ch_current_step" ] && ch_current=$ch_current_step
echo "-> ClickHouse data currently at version $ch_current"

version_gt() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ] && [ "$1" != "$2" ]; }

clickhouse_to() {
  for v in "$@"; do
    if done_step "clickhouse-$v" || ! version_gt "$v" "$ch_current"; then
      continue
    fi
    echo "-> ClickHouse $v"
    CLICKHOUSE_VERSION=$v docker compose up -d --wait plausible_events_db
    docker compose exec -T plausible_events_db clickhouse-client -q 'SELECT version()' < /dev/null
    check_counts
    mark_done "clickhouse-$v"
    ch_current=$v
  done
}

migrate_with() {
  image=$1
  if done_step "migrate-$image"; then return; fi
  echo "-> migrating with $image (ClickHouse $ch_current)"
  STAGE_IMAGE="$image" CLICKHOUSE_VERSION="$ch_current" \
    stage_compose run --rm plausible db migrate
  check_counts
  mark_done "migrate-$image"
}

echo "-> starting Postgres"
docker compose up -d --wait plausible_db

clickhouse_to 23.8 24.3
migrate_with "$RELEASES:v2.1.0"
migrate_with "$RELEASES:v2.1.1"
migrate_with "$RELEASES:v2.1.5"

clickhouse_to 24.8 24.12
migrate_with "$RELEASES:v3.0.1"
migrate_with "$RELEASES:v3.1.0"
migrate_with "$RELEASES:v3.2.0"

if ! done_step "migrate-fork"; then
  echo "-> migrating with this fork (plausible-deviceid:local)"
  CLICKHOUSE_VERSION="$ch_current" docker compose run --rm plausible db migrate
  check_counts
  mark_done "migrate-fork"
fi

echo "MIGRATIONS OK"
echo "Start Plausible with 'docker compose up -d', then run ./upgrade/verify.sh"
