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
#
# Two workarounds for the v2.1.0 stage:
#   * v2.1.0/v2.1.1 refuse to boot without TOTP_VAULT_KEY. If plausible-conf.env
#     has none, those stages get a throwaway key (v2.0 has no 2FA data to
#     encrypt, and later releases don't need it). Your config isn't changed.
#   * v2.1.0's sessions_v2 engine conversion crashes when ClickHouse can't
#     EXCHANGE tables (error 48, plausible/analytics#4167). This script does
#     that conversion first, with the same SQL and the same non-atomic rename
#     fallback as v2.1.1, so v2.1.0 finds it already done.
# Prints "MIGRATIONS OK" at the end.
set -eu

[ -f upgrade.vars ] || { echo "upgrade.vars not found: run upgrade/backup.sh first" >&2; exit 1; }
. ./upgrade.vars
: "${PROJECT:?}" "${BACKUP:?}"
[ -f "$BACKUP/before.txt" ] || { echo "$BACKUP/before.txt not found: run upgrade/backup.sh first" >&2; exit 1; }

# Installs that ran a v2.1 release or RC encrypt 2FA secrets with TOTP_VAULT_KEY.
# Without the same key in the new config, users with 2FA could no longer log in.
old_totp=$(sed -n 's/^TOTP_VAULT_KEY=//p' "$BACKUP/config/plausible-conf.env" 2> /dev/null | tail -n 1)
new_totp=$(sed -n 's/^TOTP_VAULT_KEY=//p' plausible-conf.env 2> /dev/null | tail -n 1)
if [ -n "$old_totp" ] && [ "$old_totp" != "$new_totp" ]; then
  echo "TOTP_VAULT_KEY in plausible-conf.env is missing or differs from your old config." >&2
  echo "Copy it exactly from $BACKUP/config/plausible-conf.env, then rerun." >&2
  exit 1
fi

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
# the baseline counts rows before the cutoff (upgrade/data-check.sh), so count the same rows
CUTOFF=$(cat "$BACKUP/cutoff.txt")

ch() {
  docker compose exec -T plausible_events_db clickhouse-client -d plausible_events_db -q "$1" < /dev/null
}

check_counts() {
  counts=$(ch "SELECT (SELECT count() FROM events_v2 WHERE timestamp < toDateTime('$CUTOFF')),
                      (SELECT sum(sign) FROM sessions_v2 WHERE start < toDateTime('$CUTOFF')) FORMAT CSV")
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

# v2.1.0 and v2.1.1 refuse to start without TOTP_VAULT_KEY (base64, 32 bytes).
# Pass a throwaway one to those two stages if the config has none; an
# existing key is used as is.
if grep -q '^TOTP_VAULT_KEY=.' plausible-conf.env 2> /dev/null; then
  TOTP_VAULT_KEY=
else
  TOTP_VAULT_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
fi

migrate_with() {
  image=$1
  if done_step "migrate-$image"; then return; fi
  echo "-> migrating with $image (ClickHouse $ch_current)"
  case "$image" in
    *:v2.1.0 | *:v2.1.1) totp_key=$TOTP_VAULT_KEY ;;
    *) totp_key= ;;
  esac
  if [ -n "$totp_key" ]; then
    STAGE_IMAGE="$image" CLICKHOUSE_VERSION="$ch_current" \
      stage_compose run --rm -e TOTP_VAULT_KEY="$totp_key" plausible db migrate
  else
    STAGE_IMAGE="$image" CLICKHOUSE_VERSION="$ch_current" \
      stage_compose run --rm plausible db migrate
  fi
  check_counts
  mark_done "migrate-$image"
}

# sessions_v2: CollapsingMergeTree -> VersionedCollapsingMergeTree, as in
# upstream's VersionedSessions data migration (single node). The partitions
# are attached to a new table (hard links, no data copied), then the tables
# are swapped. Without EXCHANGE support (error 48 in some Docker setups) the
# swap is two renames and the old table stays as sessions_v2_backup.
# finalize.sh drops the leftover table.
convert_sessions_v2() {
  if done_step "sessions-v2-versioned"; then return; fi
  engine=$(ch "SELECT engine FROM system.tables WHERE database = currentDatabase() AND name = 'sessions_v2'")
  case "$engine" in
    VersionedCollapsingMergeTree)
      echo "-> sessions_v2 is already versioned"
      mark_done "sessions-v2-versioned"
      return
      ;;
    CollapsingMergeTree) ;;
    "")
      # interrupted between the two renames below: finish the swap
      if [ "$(ch "SELECT engine FROM system.tables WHERE database = currentDatabase() AND name = 'sessions_v2_tmp_versioned'")" = "VersionedCollapsingMergeTree" ]; then
        echo "-> finishing the interrupted sessions_v2 swap"
        ch "RENAME TABLE sessions_v2_tmp_versioned TO sessions_v2"
        check_counts
        mark_done "sessions-v2-versioned"
        return
      fi
      echo "sessions_v2 table not found" >&2; exit 1
      ;;
    *) echo "unexpected sessions_v2 engine '$engine'" >&2; exit 1 ;;
  esac

  echo "-> converting sessions_v2 to VersionedCollapsingMergeTree"
  settings=$(ch "SELECT extract(engine_full, 'SETTINGS .+') FROM system.tables
                 WHERE database = currentDatabase() AND name = 'sessions_v2'")
  ch "DROP TABLE IF EXISTS sessions_v2_tmp_versioned"
  ch "CREATE TABLE sessions_v2_tmp_versioned AS sessions_v2
      ENGINE = VersionedCollapsingMergeTree(sign, events)
      PARTITION BY toYYYYMM(start)
      PRIMARY KEY (site_id, toDate(start), user_id, session_id)
      ORDER BY (site_id, toDate(start), user_id, session_id)
      SAMPLE BY user_id
      $settings"
  for partition in $(ch "SELECT DISTINCT partition_id FROM system.parts
                         WHERE database = currentDatabase() AND table = 'sessions_v2' AND active
                         ORDER BY partition_id"); do
    ch "ALTER TABLE sessions_v2_tmp_versioned ATTACH PARTITION ID '$partition' FROM sessions_v2"
  done

  # the new table must hold the same sessions. Background merges may already
  # have dropped cancelled +1/-1 pairs from either table (differently per
  # engine), so physical row counts can differ. Compare totals such a pair
  # cancels out of: sessions, and a signed checksum of the sorting key that
  # every collapsed pair shares.
  totals="SELECT sum(sign), sum(toInt128(sign) * cityHash64(site_id, toDate(start), user_id, session_id))"
  old=$(ch "$totals FROM sessions_v2 FORMAT CSV")
  new=$(ch "$totals FROM sessions_v2_tmp_versioned FORMAT CSV")
  [ "$old" = "$new" ] || { echo "sessions_v2_tmp_versioned has sessions,checksum $new, sessions_v2 has $old: stopping" >&2; exit 1; }

  if ! ch "EXCHANGE TABLES sessions_v2_tmp_versioned AND sessions_v2"; then
    engine=$(ch "SELECT engine FROM system.tables WHERE database = currentDatabase() AND name = 'sessions_v2'")
    [ "$engine" = "CollapsingMergeTree" ] || { echo "EXCHANGE failed and sessions_v2 is now '$engine': stopping" >&2; exit 1; }
    echo "   EXCHANGE is not supported here, swapping the tables with two renames"
    backup_table=sessions_v2_backup
    if [ "$(ch "EXISTS TABLE $backup_table")" = "1" ]; then
      backup_table="sessions_v2_backup_$(date -u +%Y%m%d%H%M%S)"
    fi
    ch "RENAME TABLE sessions_v2 TO $backup_table"
    ch "RENAME TABLE sessions_v2_tmp_versioned TO sessions_v2"
  fi
  check_counts
  mark_done "sessions-v2-versioned"
}

echo "-> starting Postgres"
docker compose up -d --wait plausible_db

clickhouse_to 23.8 24.3
convert_sessions_v2
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

# Some installs miss columns that a migration recorded as applied (e.g. after
# an old v1 -> v2 data migration recreated events_v2). New events then can't
# be stored. Add any missing optional ones (metadata only, data untouched).
echo "-> checking the columns new events and sessions are written to"
"$(dirname "$0")/check-columns.sh" --fix

echo "MIGRATIONS OK"
echo "Start Plausible with 'docker compose up -d', then run ./upgrade/verify.sh"
