#!/bin/sh
# Step 3.5 (option B) of deployment.md: move the Postgres volume from 14 to 16
# by dump/restore.
#
#   . ./upgrade.vars && ./upgrade/postgres-16.sh
#
# Needs the dump made by upgrade/backup.sh. Keeps a copy of the v14 data
# directory in the volume ${PROJECT}_db-data-pg14. Prints "POSTGRES 16
# RESTORE OK" only if everything succeeded.
set -eu

[ -f upgrade.vars ] || { echo "upgrade.vars not found: run from the install directory" >&2; exit 1; }
. ./upgrade.vars
: "${PROJECT:?}" "${BACKUP:?}"
HELPER_IMAGE="${HELPER_IMAGE:-alpine}"
DUMP="$BACKUP/plausible_db.dump"
[ -s "$DUMP" ] || { echo "$DUMP is missing, run upgrade/backup.sh first" >&2; exit 1; }
if grep -q '^POSTGRES_VERSION=' .env 2>/dev/null; then
  echo "POSTGRES_VERSION is set in .env; remove it to use Postgres 16" >&2
  exit 1
fi

docker compose rm -sf plausible_db

if docker volume inspect "${PROJECT}_db-data-pg14" > /dev/null 2>&1; then
  echo "-> ${PROJECT}_db-data-pg14 already exists, keeping it as is"
else
  echo "-> copying the v14 data directory to ${PROJECT}_db-data-pg14"
  docker volume create "${PROJECT}_db-data-pg14" > /dev/null
  docker run --rm -v "${PROJECT}_db-data:/from:ro" -v "${PROJECT}_db-data-pg14:/to" "$HELPER_IMAGE" \
    cp -a /from/. /to/
fi

echo "-> emptying ${PROJECT}_db-data and starting Postgres 16"
docker run --rm -v "${PROJECT}_db-data:/volume" "$HELPER_IMAGE" find /volume -mindepth 1 -delete
docker compose up -d --wait plausible_db

echo "-> restoring $DUMP"
docker compose exec -T plausible_db createdb -U postgres plausible_db < /dev/null
docker compose exec -T plausible_db pg_restore -U postgres -d plausible_db --exit-on-error < "$DUMP"
docker compose exec -T plausible_db psql -U postgres -d plausible_db -At -c 'SELECT version()' < /dev/null
echo "POSTGRES 16 RESTORE OK"
