#!/bin/sh
# Step 3.3 of deployment.md: back up all Plausible data before an upgrade.
#
#   . ./upgrade.vars && ./upgrade/backup.sh
#
# Run from the install directory (where docker-compose.yml and upgrade.vars
# are). Writes a Postgres dump and cold archives of every volume to $BACKUP,
# verifies them, and prints "BACKUP OK" only if everything succeeded.
# Stops all services (they stay stopped afterwards).
set -eu

[ -f upgrade.vars ] || { echo "upgrade.vars not found: run from the install directory" >&2; exit 1; }
. ./upgrade.vars
: "${PROJECT:?}" "${BACKUP:?}"
HELPER_IMAGE="${HELPER_IMAGE:-alpine}"
mkdir -p "$BACKUP"

for v in db-data event-data event-logs; do
  docker volume inspect "${PROJECT}_${v}" > /dev/null
done

echo "-> dumping Postgres to $BACKUP/plausible_db.dump"
docker compose exec -T plausible_db pg_dump -U postgres -Fc plausible_db < /dev/null > "$BACKUP/plausible_db.dump"
[ -s "$BACKUP/plausible_db.dump" ] || { echo "Postgres dump is empty" >&2; exit 1; }

echo "-> stopping all services"
docker compose stop

for v in db-data event-data event-logs; do
  echo "-> archiving volume ${PROJECT}_${v}"
  rm -f "$BACKUP/${v}.tar.gz"
  docker run --rm -v "${PROJECT}_${v}:/volume:ro" -v "$BACKUP:/backup" "$HELPER_IMAGE" \
    tar -C /volume -czf "/backup/${v}.tar.gz" .
  [ -s "$BACKUP/${v}.tar.gz" ] || { echo "archive ${v}.tar.gz is missing or empty" >&2; exit 1; }
  tar -tzf "$BACKUP/${v}.tar.gz" > /dev/null
done

echo "-> verifying the Postgres dump"
docker compose start plausible_db
docker compose exec -T plausible_db pg_restore --list < "$BACKUP/plausible_db.dump" > /dev/null
docker compose stop plausible_db

ls -lh "$BACKUP"
echo "BACKUP OK: $BACKUP"
