#!/bin/sh
# Full backup of a Plausible install before an upgrade (deployment.md, step 2).
#
#   ./upgrade/backup.sh                     # backup to ./backups/<timestamp>
#   BACKUP_DIR=/mnt/backups ./upgrade/backup.sh
#
# Run from the install directory (where docker-compose.yml is). It:
#   1. stops the `plausible` app (the databases keep running for the dump)
#   2. records the cutoff time and a data baseline (upgrade/data-check.sh)
#   3. copies the config files (compose files, plausible-conf.env, .env,
#      clickhouse/) and the upgrade scripts into the backup
#   4. dumps Postgres, stops all services and archives every data volume
#   5. verifies every file and prints "BACKUP OK"
# It writes upgrade.vars (PROJECT, BACKUP) for the other upgrade scripts.
# All services are stopped when it finishes.
set -eu

HELPER_IMAGE="${HELPER_IMAGE:-alpine}"
SCRIPTS_DIR=$(cd "$(dirname "$0")" && pwd)
[ -f docker-compose.yml ] || { echo "docker-compose.yml not found: run from the install directory" >&2; exit 1; }

container=$(docker compose ps -aq plausible_db)
[ -n "$container" ] || { echo "no plausible_db container found for this directory" >&2; exit 1; }
PROJECT=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$container")
BACKUP="${BACKUP_DIR:-$PWD/backups}/$(date -u +%Y%m%dT%H%M%SZ)"
case "$BACKUP" in /*) ;; *) BACKUP="$PWD/$BACKUP" ;; esac
mkdir -p "$BACKUP/config"
printf "PROJECT='%s'\nBACKUP='%s'\n" "$PROJECT" "$BACKUP" > upgrade.vars
echo "-> project $PROJECT, backup directory $BACKUP"

for v in db-data event-data event-logs; do
  docker volume inspect "${PROJECT}_${v}" > /dev/null
done

echo "-> stopping the app, starting the databases"
docker compose stop plausible
docker compose start plausible_db plausible_events_db
tries=0
until docker compose exec -T plausible_events_db clickhouse-client -q 'SELECT 1' < /dev/null > /dev/null 2>&1 &&
  docker compose exec -T plausible_db pg_isready -U postgres -h 127.0.0.1 < /dev/null > /dev/null 2>&1; do
  tries=$((tries + 1))
  [ "$tries" -lt 150 ] || { echo "databases did not come up" >&2; exit 1; }
  sleep 2
done

echo "-> recording the data baseline"
date -u '+%Y-%m-%d %H:%M:%S' > "$BACKUP/cutoff.txt"
cp "$SCRIPTS_DIR/data-check.sh" "$SCRIPTS_DIR/rollback.sh" "$SCRIPTS_DIR/finalize.sh" "$BACKUP/"
# counted with the same cutoff as every later check (verify, rollback,
# finalize), so rows timestamped after it never cause a mismatch
"$BACKUP/data-check.sh" "$(cat "$BACKUP/cutoff.txt")" > "$BACKUP/before.txt"

echo "-> copying config files"
for f in docker-compose.yml docker-compose.override.yml plausible-conf.env .env; do
  if [ -f "$f" ]; then cp "$f" "$BACKUP/config/"; fi
done
if [ -d clickhouse ]; then cp -r clickhouse "$BACKUP/config/"; fi

echo "-> dumping Postgres"
docker compose exec -T plausible_db pg_dump -U postgres -Fc plausible_db < /dev/null > "$BACKUP/plausible_db.dump"
[ -s "$BACKUP/plausible_db.dump" ] || { echo "Postgres dump is empty" >&2; exit 1; }
docker compose exec -T plausible_db pg_restore --list < "$BACKUP/plausible_db.dump" > /dev/null

echo "-> stopping all services and archiving the volumes"
docker compose stop
for v in db-data event-data event-logs; do
  docker run --rm -v "${PROJECT}_${v}:/volume:ro" -v "$BACKUP:/backup" "$HELPER_IMAGE" \
    tar -C /volume -czf "/backup/${v}.tar.gz" .
  [ -s "$BACKUP/${v}.tar.gz" ] || { echo "archive ${v}.tar.gz is missing or empty" >&2; exit 1; }
  tar -tzf "$BACKUP/${v}.tar.gz" > /dev/null
  echo "   ${v}.tar.gz OK"
done

du -sh "$BACKUP"
echo "BACKUP OK: $BACKUP"
echo "Services are stopped. Continue with the upgrade, or run 'docker compose up -d' to cancel."
