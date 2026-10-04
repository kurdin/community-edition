#!/bin/sh
# Section 4 of deployment.md: roll an upgrade back to the state archived by
# upgrade/backup.sh.
#
#   . ./upgrade.vars && "$BACKUP/rollback.sh"
#
# Run from the install directory. Aborts before touching anything unless all
# archives and the config backup exist. Archives the current (post-upgrade)
# state to $BACKUP/pre-rollback first, restores volumes in place, restores the
# config files, starts only the databases and compares the data with the
# pre-upgrade baseline. Start the app afterwards with `docker compose up -d`.
set -eu

[ -f upgrade.vars ] || { echo "upgrade.vars not found: run from the install directory" >&2; exit 1; }
. ./upgrade.vars
: "${PROJECT:?}" "${BACKUP:?}"
HELPER_IMAGE="${HELPER_IMAGE:-alpine}"

for v in db-data event-data event-logs; do
  [ -s "$BACKUP/${v}.tar.gz" ] || { echo "missing $BACKUP/${v}.tar.gz, aborting" >&2; exit 1; }
done
for f in config/docker-compose.yml config/plausible-conf.env config/clickhouse before.txt cutoff.txt data-check.sh; do
  [ -e "$BACKUP/$f" ] || { echo "missing $BACKUP/$f, aborting" >&2; exit 1; }
done

echo "-> archiving the current state to $BACKUP/pre-rollback"
mkdir -p "$BACKUP/pre-rollback"
docker compose stop
for v in db-data event-data event-logs; do
  docker run --rm -v "${PROJECT}_${v}:/volume:ro" -v "$BACKUP/pre-rollback:/backup" "$HELPER_IMAGE" \
    tar -C /volume -czf "/backup/${v}.tar.gz" .
done
for f in docker-compose.yml docker-compose.override.yml plausible-conf.env .env; do
  if [ -f "$f" ]; then cp "$f" "$BACKUP/pre-rollback/"; fi
done

echo "-> restoring volumes in place"
docker compose down
for v in db-data event-data event-logs; do
  docker run --rm -v "${PROJECT}_${v}:/volume" -v "$BACKUP:/backup:ro" "$HELPER_IMAGE" \
    sh -c 'find /volume -mindepth 1 -delete && tar -C /volume -xzf "/backup/$0.tar.gz"' "$v"
done

echo "-> restoring config files"
rm -f .env docker-compose.override.yml
cp "$BACKUP/config/docker-compose.yml" "$BACKUP/config/plausible-conf.env" .
for f in docker-compose.override.yml .env; do
  if [ -f "$BACKUP/config/$f" ]; then cp "$BACKUP/config/$f" .; fi
done
rm -rf clickhouse
cp -r "$BACKUP/config/clickhouse" .

echo "-> starting the databases and checking the data"
docker compose up -d plausible_db plausible_events_db
tries=0
until docker compose exec -T plausible_events_db clickhouse-client -q 'SELECT 1' < /dev/null > /dev/null 2>&1 &&
  docker compose exec -T plausible_db pg_isready -U postgres -h 127.0.0.1 < /dev/null > /dev/null 2>&1; do
  tries=$((tries + 1))
  [ "$tries" -lt 150 ] || { echo "databases did not come up" >&2; exit 1; }
  sleep 2
done
"$BACKUP/data-check.sh" "$(cat "$BACKUP/cutoff.txt")" > "$BACKUP/rollback.txt"
if diff "$BACKUP/before.txt" "$BACKUP/rollback.txt"; then
  echo "ROLLBACK DATA OK: start the app with: docker compose up -d"
else
  echo "data differs from the baseline, see the diff above" >&2
  exit 1
fi
