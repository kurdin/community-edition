#!/bin/sh
# Checks a migrated install and cleans up what the migration left behind
# (MIGRATION-GUIDE.md, phase 5).
#
#   ./upgrade/post-migration.sh                        # checks only (read-only, safe any time)
#   ./upgrade/post-migration.sh --cleanup              # + remove migration leftovers (asks first)
#   ./upgrade/post-migration.sh --cleanup --yes        #   ... without asking
#   ./upgrade/post-migration.sh --remove-old-install /path/to/old/install
#                                                      # + delete the OLD install's data (asks for its name)
#
# Run from the new install's directory.
#
# Checks: the app runs the fork image and is healthy; new events are being
# stored and the app logs no write errors; every column the app writes and
# the sessions_v2 index exist (check-columns.sh); table engines; config
# values aren't placeholders; persistent tracking state. Then it lists
# leftovers: tables, the upgrade backup, volumes, migration-only images.
#
# --cleanup (only when no check failed):
#   * finalize.sh: re-checks the data against the pre-upgrade baseline, then
#     deletes the backup, the sessions_v2 conversion leftover, empty v1 -> v2
#     leftovers and the db-data-pg14 volume
#   * drops the empty v1 tables `events` and `sessions`
#   * removes images only the migration used (CE v2.1.0 ... v3.2.0,
#     ClickHouse 23.8 / 24.3 / 24.8)
# --remove-old-install DIR: deletes the containers and data volumes of the
#   old install in DIR (point of no return: no rollback afterwards).
# Prints "POST-MIGRATION CHECKS OK" (and "CLEANUP DONE").
set -eu

CLEANUP=false
YES=false
OLD_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup) CLEANUP=true ;;
    --yes) YES=true ;;
    --remove-old-install) shift; OLD_DIR=${1:-}; [ -n "$OLD_DIR" ] || { echo "--remove-old-install needs a directory" >&2; exit 1; } ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

SCRIPTS_DIR=$(cd "$(dirname "$0")" && pwd)
[ -f docker-compose.yml ] || { echo "docker-compose.yml not found: run from the install directory" >&2; exit 1; }
PROJECT=$(docker compose config 2> /dev/null | sed -n 's/^name: //p')

ch() { docker compose exec -T plausible_events_db clickhouse-client -d plausible_events_db -q "$1" < /dev/null; }
pg() { docker compose exec -T plausible_db psql -U postgres -d plausible_db -At -c "$1" < /dev/null; }
app_env() { docker compose exec -T plausible printenv "$1" < /dev/null 2> /dev/null || true; }

failures=0
warnings=0
ok() { echo "  OK    $*"; }
warn() { echo "  WARN  $*"; warnings=$((warnings + 1)); }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
info() { echo "  --    $*"; }

echo "Project: $PROJECT ($(pwd))"

echo "== app"
app=$(docker compose ps --format '{{.Image}} {{.State}}' plausible 2> /dev/null || true)
case "$app" in
  "plausible-deviceid:local running"*) ok "plausible runs plausible-deviceid:local" ;;
  "") fail "the plausible container isn't running (docker compose up -d)" ;;
  *) fail "plausible: $app (expected plausible-deviceid:local running)" ;;
esac
if docker compose exec -T plausible wget -q -O /dev/null http://127.0.0.1:8000/api/system/health/ready < /dev/null 2> /dev/null; then
  ok "health check: ready"
else
  fail "health check failed (docker compose logs plausible)"
fi

echo "== new events are being stored"
recent=$(ch "SELECT count() FROM events_v2 WHERE timestamp > now() - INTERVAL 15 MINUTE" || echo 0)
last=$(ch "SELECT max(timestamp) FROM events_v2 WHERE timestamp > now() - INTERVAL 30 DAY" || echo '?')
if [ "$recent" -gt 0 ]; then
  ok "$recent events in the last 15 minutes (last: $last UTC)"
else
  warn "no events in the last 15 minutes (last: $last UTC); fine only if your sites have no traffic right now"
fi
write_errors=$(docker compose logs --since 15m plausible 2>&1 | grep -cE 'No such column|WriteBuffer terminating' || true)
if [ "$write_errors" -eq 0 ]; then
  ok "no write errors in the app log (15 min)"
else
  fail "$write_errors write errors in the app log: new events are NOT stored (./upgrade/check-columns.sh --fix)"
fi

echo "== tables"
if columns=$("$SCRIPTS_DIR/check-columns.sh" 2>&1); then
  ok "all written columns and the sessions_v2 index exist"
else
  printf '%s\n' "$columns" | sed 's/^/        /'
  fail "missing columns or index (./upgrade/check-columns.sh --fix)"
fi
engines=$(ch "SELECT name, engine FROM system.tables WHERE database = currentDatabase()
              AND name IN ('events_v2', 'sessions_v2') ORDER BY name FORMAT CSV" | tr -d '"' | tr '\n' ' ')
if [ "$engines" = "events_v2,MergeTree sessions_v2,VersionedCollapsingMergeTree " ]; then
  ok "events_v2 MergeTree, sessions_v2 VersionedCollapsingMergeTree"
else
  fail "unexpected table engines: $engines"
fi

echo "== configuration"
for var in BASE_URL SECRET_KEY_BASE; do
  value=$(app_env "$var")
  case "$value" in
    "" | replace-me) fail "$var is empty or replace-me" ;;
    *) ok "$var is set" ;;
  esac
done
tracking=$(app_env ENABLE_PERSISTENT_TRACKING)
if [ "$tracking" = "true" ]; then
  secret_length=$(app_env PERSISTENT_SALT_SECRET | tr -d '\n' | wc -c)
  if [ "$secret_length" -ge 16 ]; then ok "persistent tracking on, secret set"; else fail "persistent tracking on, but PERSISTENT_SALT_SECRET is shorter than 16 bytes"; fi
  open_since=$(pg "SELECT max(started_at) FROM persistent_tracking_periods WHERE ended_at IS NULL" 2> /dev/null || true)
  if [ -n "$open_since" ]; then ok "tracking period open since $open_since UTC"; else warn "no open tracking period recorded yet (restart: docker compose up -d plausible)"; fi
  info "keep a copy of plausible-conf.env off the server: PERSISTENT_SALT_SECRET must never change"
else
  info "persistent tracking is off (PERSISTENT-TRACKING.md to turn it on)"
fi

echo "== leftovers"
leftover_tables=$(ch "SELECT concat(name, ' (', toString(total_rows), ' rows)') FROM system.tables
                      WHERE database = currentDatabase()
                        AND (name IN ('events', 'sessions', 'tmp_events_v2', 'tmp_sessions_v2', 'domains_lookup')
                             OR name = 'sessions_v2_tmp_versioned' OR name LIKE 'sessions\\_v2\\_backup%')
                      ORDER BY name")
if [ -n "$leftover_tables" ]; then
  printf '%s\n' "$leftover_tables" | sed 's/^/  --    table /'
else
  info "no leftover tables"
fi
if [ -f upgrade.vars ]; then
  backup=$(. ./upgrade.vars && echo "${BACKUP:-}")
  info "upgrade backup: $backup ($(du -sh "$backup" 2> /dev/null | cut -f1 || echo '?'); deleted by --cleanup)"
fi
if docker volume inspect "${PROJECT}_db-data-pg14" > /dev/null 2>&1; then
  info "volume ${PROJECT}_db-data-pg14 (Postgres 14 copy from postgres-16.sh)"
fi
STAGE_IMAGES="ghcr.io/plausible/community-edition:v2.1.0 ghcr.io/plausible/community-edition:v2.1.1 ghcr.io/plausible/community-edition:v2.1.5 ghcr.io/plausible/community-edition:v3.0.1 ghcr.io/plausible/community-edition:v3.1.0 ghcr.io/plausible/community-edition:v3.2.0 clickhouse/clickhouse-server:23.8-alpine clickhouse/clickhouse-server:24.3-alpine clickhouse/clickhouse-server:24.8-alpine"
present_images=""
for image in $STAGE_IMAGES; do
  if docker image inspect "$image" > /dev/null 2>&1; then present_images="$present_images $image"; fi
done
if [ -n "$present_images" ]; then
  info "migration-only images:$(printf '%s' "$present_images" | sed 's| ghcr.io/plausible/community-edition:| ce:|g; s| clickhouse/clickhouse-server:| ch:|g')"
fi
other_volumes=$(docker volume ls --format '{{.Name}}' | grep -E '_(db-data|event-data|event-logs)$' | grep -v "^${PROJECT}_" || true)
if [ -n "$other_volumes" ]; then
  info "Plausible data volumes of other projects (the old install?): $(printf '%s' "$other_volumes" | tr '\n' ' ')"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "POST-MIGRATION CHECKS FAILED: $failures failed, $warnings warnings" >&2
  [ "$CLEANUP" = false ] && [ -z "$OLD_DIR" ] || echo "not cleaning up anything until the checks pass" >&2
  exit 1
fi
echo "POST-MIGRATION CHECKS OK ($warnings warnings)"

confirm() {
  [ "$YES" = true ] && return 0
  printf '%s [type "%s"]: ' "$1" "$2"
  read -r answer < /dev/tty
  [ "$answer" = "$2" ] || { echo "aborted"; exit 1; }
}

if [ "$CLEANUP" = true ]; then
  echo
  echo "== cleanup"
  echo "This deletes the upgrade backup (if any), leftover tables and migration-only images."
  echo "Rolling back with \$BACKUP/rollback.sh is no longer possible afterwards."
  confirm "Continue?" cleanup

  if [ -f upgrade.vars ]; then
    "$SCRIPTS_DIR/finalize.sh" --yes
  else
    for table in $(ch "SELECT name FROM system.tables WHERE database = currentDatabase()
                         AND (name = 'sessions_v2_tmp_versioned' OR name LIKE 'sessions\\_v2\\_backup%'
                              OR (name IN ('tmp_events_v2', 'tmp_sessions_v2', 'domains_lookup') AND total_rows = 0))"); do
      ch "DROP TABLE IF EXISTS $table"
      echo "   dropped $table"
    done
  fi
  for table in $(ch "SELECT name FROM system.tables WHERE database = currentDatabase()
                       AND name IN ('events', 'sessions') AND total_rows = 0"); do
    ch "DROP TABLE IF EXISTS $table"
    echo "   dropped empty v1 table $table"
  done
  for image in $present_images; do
    docker image rm "$image" > /dev/null 2>&1 && echo "   removed image $image" || echo "   kept image $image (in use)"
  done
  echo "CLEANUP DONE"
fi

if [ -n "$OLD_DIR" ]; then
  echo
  echo "== remove the old install"
  [ -f "$OLD_DIR/docker-compose.yml" ] || { echo "no docker-compose.yml in $OLD_DIR" >&2; exit 1; }
  OLD_PROJECT=$(cd "$OLD_DIR" && docker compose config 2> /dev/null | sed -n 's/^name: //p')
  [ -n "$OLD_PROJECT" ] || { echo "can't read the Compose project of $OLD_DIR" >&2; exit 1; }
  [ "$OLD_PROJECT" != "$PROJECT" ] || { echo "$OLD_DIR is this install's project ($PROJECT): refusing" >&2; exit 1; }
  if [ -n "$(cd "$OLD_DIR" && docker compose ps -q 2> /dev/null)" ]; then
    echo "the old install still has containers: run 'docker compose down' in $OLD_DIR first" >&2
    exit 1
  fi
  old_volumes=$(docker volume ls --format '{{.Name}}' | grep "^${OLD_PROJECT}_" || true)
  echo "Old install: $OLD_DIR (project $OLD_PROJECT)"
  echo "Volumes to delete: $(printf '%s' "$old_volumes" | tr '\n' ' ')"
  echo "This is the point of no return: the old data is gone afterwards."
  YES=false   # always ask here, even with --yes
  confirm "Delete the old install's data?" "$OLD_PROJECT"
  old_images=$(cd "$OLD_DIR" && docker compose config --images 2> /dev/null || true)
  (cd "$OLD_DIR" && docker compose down -v)
  for image in $old_images; do
    docker image inspect "$image" > /dev/null 2>&1 || continue
    docker image rm "$image" > /dev/null 2>&1 && echo "   removed image $image" || echo "   kept image $image (in use by the new install)"
  done
  echo "OLD INSTALL REMOVED. You can delete the folder $OLD_DIR."
fi
