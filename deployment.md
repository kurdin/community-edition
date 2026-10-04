# Deployment guide: Plausible CE with persistent tracking

This guide covers:

1. [What you are deploying](#1-what-you-are-deploying)
2. [Fresh install](#2-fresh-install)
3. [Upgrading an existing Docker install (v2.0 → this version) without data loss](#3-upgrading-an-existing-docker-install-without-data-loss)
4. [Rollback](#4-rollback)
5. [Updating later](#5-updating-later)
6. [Backups](#6-routine-backups)
7. [Troubleshooting](#7-troubleshooting)
8. [Configuration reference](#8-configuration-reference)

> **Branches.** Until these changes are merged, they live on the
> `claude/determined-cerf-dqrxgj` branch of both
> [kurdin/community-edition](https://github.com/kurdin/community-edition) and
> [kurdin/plausible-analytics-deviceid](https://github.com/kurdin/plausible-analytics-deviceid).
> The commands below use two variables. Set them once per shell, and change
> them to the merged branch or tag later:
>
> ```sh
> DEPLOY_REF=claude/determined-cerf-dqrxgj   # branch of kurdin/community-edition
> APP_REF=claude/determined-cerf-dqrxgj      # branch/tag of kurdin/plausible-analytics-deviceid
> ```

---

## 1. What you are deploying

| Service | Image | Notes |
| --- | --- | --- |
| `plausible` | built from [kurdin/plausible-analytics-deviceid](https://github.com/kurdin/plausible-analytics-deviceid) | Plausible CE (latest upstream) + opt-in persistent tracking |
| `plausible_db` | `postgres:${POSTGRES_VERSION:-16}-alpine` | users, sites, goals, settings |
| `plausible_events_db` | `clickhouse/clickhouse-server:${CLICKHOUSE_VERSION:-24.12}-alpine` | events and sessions |
| `mail` | `bytemark/smtp` | outgoing mail relay |

Volumes (names are unchanged from the original community-edition setup):
`db-data` (Postgres), `event-data` and `event-logs` (ClickHouse), and the new
`plausible-data` (app cache and session handover between restarts).

**Schema migrations are automatic.** Each time the `plausible` container
starts, it runs `db createdb` and `db migrate`. `db migrate` applies all
pending Postgres *and* ClickHouse migrations together, in chronological order,
so you can jump straight from v2.0 to the latest version. Migrations only add
or convert data, they never discard it. The one table conversion
(ClickHouse `sessions_v2` → `VersionedCollapsingMergeTree`) leaves the old
table behind as a backup.

**Persistent tracking is opt-in.** With `ENABLE_PERSISTENT_TRACKING=false`
the app behaves exactly like upstream Plausible. Turning it on changes only
how *new* events are identified. Historical data is never rewritten.

---

## 2. Fresh install

### 2.1 Requirements

* Linux server, x86_64 or arm64 with SSE 4.2 / NEON, **4 GB RAM minimum**.
  Building the image needs about 4 GB of free memory; build elsewhere (see 5.2)
  if the server is smaller.
* Docker Engine 24+ with the Compose v2 plugin (`docker compose version`).
* Outbound internet access during the build (GitHub, hex.pm, npm, Alpine
  mirrors).
* A DNS record pointing your domain to the server.

### 2.2 Get the files

```sh
git clone -b "$DEPLOY_REF" https://github.com/kurdin/community-edition plausible-ce
cd plausible-ce
echo "PLAUSIBLE_SRC=https://github.com/kurdin/plausible-analytics-deviceid.git#$APP_REF" > .env
```

> The directory name becomes the Compose *project name*, which prefixes the
> volume names (`plausible-ce_event-data`, …). Keep using the same directory.

### 2.3 Configure

Edit `plausible-conf.env`:

```sh
sed -i "s|^BASE_URL=.*|BASE_URL=https://plausible.example.com|" plausible-conf.env
sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')|" plausible-conf.env
sed -i "s|^PERSISTENT_SALT_SECRET=.*|PERSISTENT_SALT_SECRET=$(openssl rand -base64 48 | tr -d '\n')|" plausible-conf.env
sed -i "s|^MAILER_EMAIL=.*|MAILER_EMAIL=plausible@example.com|" plausible-conf.env
```

Back up the generated secrets somewhere safe (a password manager):

* `SECRET_KEY_BASE`: losing or changing it logs everyone out and breaks
  2FA, which is derived from it.
* `PERSISTENT_SALT_SECRET`: changing it makes every visitor look new.

Set `ENABLE_PERSISTENT_TRACKING=false` if you want upstream behaviour for now.
You can switch later at any time.

### 2.4 Choose where the source comes from

`PLAUSIBLE_SRC` in `.env` (written in 2.2) decides what gets built. Compose
reads `.env` for variable substitution; it is a different file from
`plausible-conf.env`. Without it the default is
`https://github.com/kurdin/plausible-analytics-deviceid.git#master`. Point it
at any branch, tag or commit, or at a local checkout:

```sh
# pin a tag
sed -i 's|^PLAUSIBLE_SRC=.*|PLAUSIBLE_SRC=https://github.com/kurdin/plausible-analytics-deviceid.git#<tag>|' .env
# or build from a local checkout
sed -i 's|^PLAUSIBLE_SRC=.*|PLAUSIBLE_SRC=../plausible-analytics-deviceid|' .env
```

### 2.5 Build and start

```sh
docker compose build plausible        # 10–20 minutes the first time
docker compose up -d
docker compose logs -f plausible      # wait for "Running PlausibleWeb.Endpoint"
curl -fsS http://127.0.0.1:8000/api/system/health/ready && echo ready
```

### 2.6 Expose it over HTTPS

The app listens on `127.0.0.1:8000` only. Put a reverse proxy in front of it;
examples are in [`reverse-proxy/`](./reverse-proxy) (Caddy, nginx, Traefik,
Apache). Make sure `BASE_URL` matches the public URL.

### 2.7 First login and first site

1. Open `BASE_URL`. On a fresh database you're sent to the registration page
   to create the admin account. After that, registration is invite-only by
   default (`DISABLE_REGISTRATION=invite_only`).
2. Add your site and copy the snippet.

### 2.8 Send the device id (when persistent tracking is on)

Pass the id as a custom property on **every** event, pageviews included. An
event without it falls back to an IP + user-agent id, which is different from
the device id.

```html
<script>
  function getOrCreateDeviceId() {
    try {
      var id = localStorage.getItem('deviceId')
      if (!id) {
        id = crypto.randomUUID()
        localStorage.setItem('deviceId', id)
      }
      return id
    } catch (e) {
      return undefined
    }
  }
</script>
<!-- In the snippet Plausible gives you, add customProperties to init(): -->
<script>
  plausible.init({ customProperties: { deviceId: getOrCreateDeviceId() } })
</script>
```

Mobile apps and servers can send events directly:

```sh
curl -X POST https://plausible.example.com/api/event \
  -H 'Content-Type: application/json' -H 'User-Agent: MyApp/1.0' \
  -H 'X-Forwarded-For: <client ip>' \
  -d '{"name":"pageview","url":"app://myapp/home","domain":"example.com","props":{"deviceId":"<stable id>"}}'
```

If your clients already send the id under another name, set
`PERSISTENT_TRACKING_DEVICE_ID_PROP` (e.g. `visitor_uid`) instead of changing
the clients.

---

## 3. Upgrading an existing Docker install without data loss

This is for installs made from the original `plausible/community-edition`
v2.0 setup (`plausible/analytics:v2.0`, `postgres:14-alpine`,
`clickhouse/clickhouse-server:23.3.7.5-alpine`). Older or newer upstream CE
installs follow the same steps.

### What changes

| | Before (v2.0) | After |
| --- | --- | --- |
| App | `plausible/analytics:v2.0` | built from the fork (latest Plausible CE) |
| Postgres | 14 | 16 (dump/restore), or stay on 14 |
| ClickHouse | 23.3 | 24.12, upgraded in place through 23.8 → 24.3 → 24.8 |
| Postgres schema | v2.0 | migrated automatically (teams backfill, site imports, new tables and columns) |
| ClickHouse schema | v2.0 | migrated automatically (new columns, `sessions_v2` engine conversion, source-name normalisation) |

### How "no data loss" is guaranteed

1. **Full backups before anything changes:** a logical Postgres dump, plus
   cold archives of every volume.
2. **A baseline of row counts.** [`upgrade/data-check.sh`](./upgrade/data-check.sh)
   counts users, sites, goals, events, sessions, per-site visitors and imported
   rows. It runs again after the upgrade, and the two outputs must be identical.
3. **Each step is verified before the next one.** Every step can be undone
   by restoring the archives (section 4).

This exact procedure was rehearsed on a v2.0-shaped dataset: ClickHouse
23.3.7.5 → 23.8 → 24.3 → 24.8 → 24.12, the `sessions_v2` engine conversion,
Postgres 14 → 16 dump/restore, and a full rollback. `data-check.sh` produced
identical output before the upgrade, after it, and after the rollback. The application
migrations in step 3.6 are upstream Plausible's own, unchanged by this fork.
They are the same ones every CE install runs when upgrading from v2.0.

### 3.0 Before you start

Plan a maintenance window. Tracking stops while the app is down: visitors are
not queued, so events sent during the window are lost (stored data is not
affected). Expect 15–60 minutes depending on data size, plus the image build.

Run everything from **the directory of your existing install** (where your
current `docker-compose.yml` is):

```sh
cd /path/to/your/plausible        # e.g. ~/hosting
docker compose ps                 # should list plausible, plausible_db, plausible_events_db, mail
```

Find the Compose project name and volume names:

```sh
PROJECT=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' \
  $(docker compose ps -aq plausible_db))
echo "$PROJECT"
docker volume ls --filter label=com.docker.compose.project="$PROJECT"
# expect: ${PROJECT}_db-data  ${PROJECT}_event-data  ${PROJECT}_event-logs
```

Check disk space. You need free space of at least **2× the size of
`event-data` plus `db-data`**: one copy for the backup archives, and
headroom for ClickHouse mutations that rewrite data parts during migration.

```sh
for v in db-data event-data; do
  docker run --rm -v "${PROJECT}_${v}:/v:ro" alpine du -sh /v
done
df -h .
```

Check that your data is in the v2 tables. An install that started on v1.x and
skipped the v2.0 data migration would still have it in the legacy
`events`/`sessions` tables:

```sh
docker compose exec plausible_events_db clickhouse-client -d plausible_events_db -q \
  "SELECT name, total_rows FROM system.tables WHERE database = currentDatabase() AND name IN ('events','sessions','events_v2','sessions_v2')"
```

If `events` has rows but `events_v2` is empty or much smaller, **stop here**.
Run the v2.0 NumericIDs data migration on the old image first; see the
upstream v2.0.0 release notes.

### 3.1 Stop the app and record the baseline

```sh
docker compose stop plausible
date -u '+%Y-%m-%d %H:%M:%S' > upgrade-cutoff.txt     # used by the after-check

# data-check.sh ships with the new files; fetch it now to take the baseline
curl -fsSLo data-check.sh \
  "https://raw.githubusercontent.com/kurdin/community-edition/$DEPLOY_REF/upgrade/data-check.sh"
chmod +x data-check.sh
./data-check.sh > upgrade-before.txt
cat upgrade-before.txt
```

### 3.2 Back up everything

```sh
BACKUP="$HOME/plausible-backup-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"

# 1. config files
cp docker-compose.yml plausible-conf.env "$BACKUP"/
cp docker-compose.override.yml "$BACKUP"/ 2>/dev/null || true
cp -r clickhouse "$BACKUP"/

# 2. logical Postgres dump (custom format, used for the 14 -> 16 upgrade)
docker compose exec -T plausible_db pg_dump -U postgres -Fc plausible_db > "$BACKUP/plausible_db.dump"

# 3. cold archives of every volume (databases must be stopped)
docker compose stop
for v in db-data event-data event-logs; do
  docker run --rm -v "${PROJECT}_${v}:/volume:ro" -v "$BACKUP:/backup" alpine \
    tar -C /volume -czf "/backup/${v}.tar.gz" .
done

# 4. verify the backup
ls -lh "$BACKUP"
docker compose start plausible_db
docker compose exec -T plausible_db pg_restore --list < "$BACKUP/plausible_db.dump" | head
for v in db-data event-data event-logs; do tar -tzf "$BACKUP/${v}.tar.gz" > /dev/null && echo "$v OK"; done
docker compose stop plausible_db
```

Keep `$BACKUP` until you have run the new version for a while. Ideally also
copy it off the server.

### 3.3 Update the deployment files

Your directory is a git clone of `plausible/community-edition`. Switch it to
the fork without losing your local edits:

```sh
git stash                                  # your edited plausible-conf.env / compose (also in $BACKUP)
git remote add deviceid https://github.com/kurdin/community-edition.git
git fetch deviceid
git checkout -b persistent-tracking "deviceid/$DEPLOY_REF"
echo "PLAUSIBLE_SRC=https://github.com/kurdin/plausible-analytics-deviceid.git#$APP_REF" >> .env
```

> If your directory isn't a git clone, copy `docker-compose.yml`,
> `plausible-conf.env`, `clickhouse/` and `upgrade/` from the fork into it.
> Don't move the install to another directory, or the project name and
> volume names will change.

Merge your old settings into the new `plausible-conf.env`:

```sh
diff "$BACKUP/plausible-conf.env" plausible-conf.env
```

* Copy **`BASE_URL` and `SECRET_KEY_BASE` exactly** from the old file. Don't
  generate a new `SECRET_KEY_BASE`.
* Copy any other variables you had set (Google integration, `MAXMIND_*`,
  `DISABLE_REGISTRATION`, SMTP credentials, …).
* If you had `MAILER_ADAPTER=Bamboo.SMTPAdapter`, change it to
  `Bamboo.Mua`. The old adapter was removed and the app refuses to start with
  it.
* Set **`ENABLE_PERSISTENT_TRACKING=false` for the upgrade itself**. You'll
  turn it on in step 3.8, once the upgrade is verified.
* Generate `PERSISTENT_SALT_SECRET` now so it's ready:
  ```sh
  sed -i "s|^PERSISTENT_SALT_SECRET=.*|PERSISTENT_SALT_SECRET=$(openssl rand -base64 48 | tr -d '\n')|" plausible-conf.env
  ```

If you had a `docker-compose.override.yml`, check it doesn't pin the old
`image: plausible/analytics:v2.0` or old database images.

### 3.4 Upgrade ClickHouse in place (23.3 → 24.12)

ClickHouse upgrades its data files in place on first start. Go through the LTS
releases one at a time, checking the counts after each:

```sh
for v in 23.8 24.3 24.8 24.12; do
  echo "== ClickHouse $v"
  CLICKHOUSE_VERSION=$v docker compose up -d --wait plausible_events_db || break
  docker compose exec -T plausible_events_db clickhouse-client -q \
    "SELECT version(), (SELECT count() FROM plausible_events_db.events_v2), (SELECT sum(sign) FROM plausible_events_db.sessions_v2)"
done
docker compose logs plausible_events_db | grep -iE '<Error>|Exception' | tail
```

Every line should show the same event and session counts as
`upgrade-before.txt`. If a hop fails to start, don't continue; see section 4.

After the last hop, `docker compose up` uses 24.12 by default (no variable
needed).

### 3.5 Upgrade PostgreSQL (14 → 16) or stay on 14

**Option A: stay on Postgres 14 (simplest).** It is fully supported:

```sh
echo 'POSTGRES_VERSION=14' >> .env
docker compose up -d --wait plausible_db
```

**Option B: move to Postgres 16.** A major-version upgrade needs a dump and
restore. Postgres 16 refuses to start on a v14 data directory ("database files
are incompatible with server") without changing it, so a mistake here is safe.

```sh
docker compose rm -sf plausible_db

# keep the v14 data directory as an extra safety copy
docker volume create "${PROJECT}_db-data-pg14"
docker run --rm -v "${PROJECT}_db-data:/from:ro" -v "${PROJECT}_db-data-pg14:/to" alpine cp -a /from/. /to/

# start Postgres 16 on a fresh db-data volume and restore the dump
docker volume rm "${PROJECT}_db-data"
docker compose up -d --wait plausible_db
docker compose exec -T plausible_db createdb -U postgres plausible_db
docker compose exec -T plausible_db pg_restore -U postgres -d plausible_db --exit-on-error < "$BACKUP/plausible_db.dump"
docker compose exec -T plausible_db psql -U postgres -d plausible_db -c "SELECT count(*) FROM users"
```

Before continuing, confirm the counts with
`./data-check.sh | head -8` (the Postgres part should match
`upgrade-before.txt`).

### 3.6 Build the new app and run the migrations

```sh
docker compose build plausible

# preview what will run (Postgres and ClickHouse, interleaved by date)
docker compose run --rm plausible db pending-migrations

# run them in the foreground so you can watch them
docker compose run --rm plausible db migrate
```

Notes:

* On large datasets some ClickHouse migrations rewrite data with mutations
  (normalising source names, adding columns). They can take a while.
  **Don't interrupt them.** If the command is killed anyway, rerunning
  `db migrate` resumes from the first unfinished migration.
* Expected log lines include `Exchanging sessions_v2 …` or `Migration done!`
  (sessions engine conversion), `Finished backfilling sites` (site imports)
  and the teams backfill. Errors stop the command with a non-zero exit code.
* The command must end without errors before you continue.

### 3.7 Start and verify

```sh
docker compose up -d
docker compose logs -f plausible           # wait for the endpoint to be running
curl -fsS http://127.0.0.1:8000/api/system/health/ready && echo ready

./upgrade/data-check.sh "$(cat upgrade-cutoff.txt)" > upgrade-after.txt
diff upgrade-before.txt upgrade-after.txt && echo "DATA IDENTICAL"
```

`diff` must print nothing. The cutoff argument makes sure traffic that
arrived after the upgrade isn't counted. Then check by hand:

* Log in with your existing account (and 2FA, if enabled).
* Open each site's dashboard for "All time". Visitors and pageviews must
  match what you saw before. Source names may be normalised (e.g. `fb` →
  `Facebook`); totals are unchanged.
* Make sure new pageviews show up in the realtime view.

### 3.8 Enable persistent tracking

Once you're happy with the upgrade:

```sh
sed -i 's/^ENABLE_PERSISTENT_TRACKING=.*/ENABLE_PERSISTENT_TRACKING=true/' plausible-conf.env
grep PERSISTENT_SALT_SECRET plausible-conf.env      # must be set, >= 16 chars
docker compose up -d plausible                      # recreates the container with the new env
```

Then update your tracking snippet to send `deviceId` (section 2.8).

Effect on stats: data from before this point keeps its daily-rotating ids.
Visitors who come back on later days are now counted once over multi-day
ranges. Sessions in progress at the moment of the switch are split once.

### 3.9 Clean up (after a week or so)

```sh
# old sessions_v2 table left by the engine conversion (one of these exists)
docker compose exec plausible_events_db clickhouse-client -d plausible_events_db -q \
  "SELECT name, engine FROM system.tables WHERE name LIKE 'sessions_v2_%'"
docker compose exec plausible_events_db clickhouse-client -d plausible_events_db -q \
  "DROP TABLE IF EXISTS sessions_v2_tmp_versioned"     # or sessions_v2_backup

# extra Postgres 14 copy (option B only)
docker volume rm "${PROJECT}_db-data-pg14"

# the stashed old config, once you no longer need it
git stash drop
```

Keep the `$BACKUP` archives as long as your retention policy requires.

---

## 4. Rollback

You can return to the exact pre-upgrade state at any point:

```sh
docker compose down                                     # stops containers, keeps volumes
for v in db-data event-data event-logs; do
  docker volume rm "${PROJECT}_${v}"
  docker volume create "${PROJECT}_${v}"
  docker run --rm -v "${PROJECT}_${v}:/volume" -v "$BACKUP:/backup:ro" alpine \
    tar -C /volume -xzf "/backup/${v}.tar.gz"
done

cp "$BACKUP/docker-compose.yml" "$BACKUP/plausible-conf.env" .
cp -r "$BACKUP/clickhouse" .
rm -f .env                                              # drop PLAUSIBLE_SRC / POSTGRES_VERSION overrides
docker compose up -d                                    # old images: plausible v2.0, Postgres 14, ClickHouse 23.3
./data-check.sh > rollback.txt; diff upgrade-before.txt rollback.txt && echo "ROLLBACK OK"
```

You can't downgrade a migrated database by running old images on it.
Always roll back by restoring the archives.

---

## 5. Updating later

### 5.1 New versions of the fork

```sh
cd /path/to/your/plausible
./upgrade/data-check.sh > before.txt               # optional sanity baseline
docker compose exec -T plausible_db pg_dump -U postgres -Fc plausible_db > "plausible_db-$(date +%F).dump"
git pull                                           # deployment files
docker compose build --pull --no-cache plausible   # rebuild from PLAUSIBLE_SRC
docker compose up -d                               # migrations run on start
docker compose logs -f plausible
```

To pin a version, point `PLAUSIBLE_SRC` at a tag or commit
(`…plausible-analytics-deviceid.git#<tag>`).

### 5.2 Building on another machine

```sh
# on a build machine / CI
docker build -t registry.example.com/plausible-deviceid:2026-10 \
  "https://github.com/kurdin/plausible-analytics-deviceid.git#$APP_REF"
docker push registry.example.com/plausible-deviceid:2026-10
```

On the server, put this in `docker-compose.override.yml`:

```yaml
services:
  plausible:
    image: registry.example.com/plausible-deviceid:2026-10
    build: !reset null
```

### 5.3 Database engine updates

Minor updates (`16.x`, `24.12.x`) only need `docker compose pull && docker compose up -d`.
Major Postgres versions need the dump/restore from 3.5. For major ClickHouse
versions, step through LTS releases as in 3.4.

---

## 6. Routine backups

Daily, while running:

```sh
docker compose exec -T plausible_db pg_dump -U postgres -Fc plausible_db > "pg-$(date +%F).dump"
```

ClickHouse can be backed up while running with its native `BACKUP` command
if you configure a backup disk. The simplest consistent option is a short
stop and an archive of the volume:

```sh
docker compose stop plausible plausible_events_db
docker run --rm -v "${PROJECT}_event-data:/volume:ro" -v "$PWD:/backup" alpine \
  tar -C /volume -czf "/backup/event-data-$(date +%F).tar.gz" .
docker compose start plausible_events_db plausible
```

Also back up `plausible-conf.env`. Without `SECRET_KEY_BASE` and
`PERSISTENT_SALT_SECRET`, a restored install can't log users in or keep
visitor ids continuous.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `plausible_db` restarts, log says *database files are incompatible with server* | Postgres 16 on a v14 volume. Set `POSTGRES_VERSION=14` in `.env`, or do the dump/restore in 3.5. Nothing was changed on disk. |
| ClickHouse is up, but the app logs `Authentication failed` / connection refused on 8123 | Newer ClickHouse images lock down the passwordless `default` user. The compose file sets `CLICKHOUSE_SKIP_USER_SETUP=1`; make sure an override doesn't remove it. |
| ClickHouse fails with `ulimit` / `rlimit` errors | Some hosts (LXC, rootless Docker) can't raise `nofile`. Remove the `ulimits` block in an override (`ulimits: !reset {}`). |
| ClickHouse fails to start on IPv6-less hosts | `clickhouse/ipv4-only.xml` is mounted for this; make sure the file exists. |
| App exits: `PERSISTENT_SALT_SECRET must be set …` | Tracking is enabled without a secret (or with one shorter than 16 bytes). Generate one (2.3). |
| App exits: `Bamboo.SMTPAdapter is no longer supported` | Set `MAILER_ADAPTER=Bamboo.Mua` (or remove the line). |
| Dashboard empty after the upgrade | You're probably running from another directory, so Compose created new empty volumes (`<newproject>_event-data`). Stop, `cd` to the original directory (or set `COMPOSE_PROJECT_NAME=<old project>` in `.env`) and start again. Your data is in the old volumes. |
| `db migrate` is slow / ClickHouse uses lots of CPU | Mutations are rewriting data on a large dataset. Let it finish; `SELECT * FROM system.mutations WHERE is_done = 0` shows progress. |
| Small server runs out of memory | Uncomment the `low-resources.xml` mount for ClickHouse in `docker-compose.yml`, and build the image elsewhere (5.2). |
| Same visitor still counted per day | `ENABLE_PERSISTENT_TRACKING` isn't `true` in the running container (`docker compose exec plausible env | grep PERSISTENT`), or the client doesn't send `deviceId` on every event. |

---

## 8. Configuration reference

Fork-specific variables (in `plausible-conf.env`):

| Variable | Default | Description |
| --- | --- | --- |
| `ENABLE_PERSISTENT_TRACKING` | `false` | `true` uses stable visitor ids. `false` gives upstream behaviour (daily rotating salt). |
| `PERSISTENT_SALT_SECRET` | — | Required when enabled, at least 16 bytes. Keys the visitor id hashes. Keep it stable and secret. |
| `PERSISTENT_TRACKING_DEVICE_ID_PROP` | `deviceId` | Custom property name to read the device id from. |

Compose variables (in `.env`, next to `docker-compose.yml`):

| Variable | Default | Description |
| --- | --- | --- |
| `PLAUSIBLE_SRC` | `https://github.com/kurdin/plausible-analytics-deviceid.git#master` | Build context for the app image (git URL with `#ref`, or a local path). |
| `POSTGRES_VERSION` | `16` | Postgres major version. Use `14` to keep an existing v14 volume. |
| `CLICKHOUSE_VERSION` | `24.12` | ClickHouse image version. |
| `COMPOSE_PROJECT_NAME` | directory name | Pins the volume name prefix if you move the directory. |

All upstream variables (`BASE_URL`, `SECRET_KEY_BASE`, `DISABLE_REGISTRATION`,
`MAXMIND_LICENSE_KEY`, `GOOGLE_CLIENT_ID`, SMTP settings, …) work as
documented in the
[upstream configuration wiki](https://github.com/plausible/community-edition/wiki/configuration).
