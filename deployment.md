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
so you can jump straight from v2.0 to the latest version. Migrations add
columns and tables and convert data in place. Your stats, users, sites,
goals, shared links and API keys are kept. The few things removed are
features upstream retired: for example, the unused `custom_domains` table is
dropped, empty site-import records are cleaned up, and source names are
normalised (`fb` → `Facebook`). The one table conversion (ClickHouse
`sessions_v2` → `VersionedCollapsingMergeTree`) leaves the old table behind
as a backup.

**Persistent tracking is opt-in.** With `ENABLE_PERSISTENT_TRACKING=false`
the app behaves exactly like upstream Plausible. Turning it on changes only
how *new* events are identified. Historical data is never rewritten.

---

## 2. Fresh install

### 2.1 Requirements

* Linux server, x86_64 or arm64 with SSE 4.2 / NEON, **4 GB RAM minimum**.
  Building the image needs about 4 GB of free memory; build elsewhere (see 5.2)
  if the server is smaller.
  The bundled `mail` relay (`bytemark/smtp`) is **amd64-only**. On arm64,
  point the `SMTP_*` variables in `plausible-conf.env` at a real SMTP server
  and remove the relay with this `docker-compose.override.yml`:
  ```yaml
  services:
    mail: !reset null
    plausible:
      depends_on: !override
        plausible_db:
          condition: service_healthy
        plausible_events_db:
          condition: service_healthy
  ```
* Docker Engine 24+ with the Compose v2 plugin (`docker compose version`).
* Outbound internet access during the build: github.com, hex.pm
  (repo.hex.pm, builds.hex.pm), registry.npmjs.org, dl-cdn.alpinelinux.org
  and download.db-ip.com (free geolocation database).
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
```

Mail is sent from `plausible@<BASE_URL host>` by default. To use another
sender, set `MAILER_EMAIL` to an address on a domain you control; SPF/DMARC
reject mail from domains you don't.

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

Plausible's site snippet already calls `plausible.init()`. Edit that call to
add `customProperties`, rather than adding a second `init()`. A second call
is ignored once the script is initialised.

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
<!-- the existing init() call in your Plausible snippet, with customProperties added -->
<script>
  plausible.init({
    // ...options already in your snippet...
    customProperties: { deviceId: getOrCreateDeviceId() }
  })
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
   cold archives of every volume and of your config files.
2. **A baseline of row counts.** [`upgrade/data-check.sh`](./upgrade/data-check.sh)
   records counts of users, sites, goals, shared links, API keys, events and
   sessions; per-site event counts, visitors and a checksum of the events;
   and imported rows. It runs again after the upgrade, and the two outputs
   must be identical.
3. **Each step is verified before the next one.** Every step can be undone
   by restoring the archives (section 4).

This procedure was rehearsed on a v2.0-shaped dataset: ClickHouse 23.3.7.5 →
23.8 → 24.3 → 24.8 → 24.12, the `sessions_v2` engine conversion, Postgres
14 → 16 dump/restore, and a full rollback. `data-check.sh` produced
identical output before the upgrade, after it, and after the rollback. The
application migrations in step 3.6 are upstream Plausible's own, unchanged
by this fork. They are the same ones every CE install runs when upgrading
from v2.0.

### Overview and downtime

| Step | App online? |
| --- | --- |
| 3.1 Prepare: checks, config backup, new files, **build the image** | yes |
| 3.2 Stop the app, record the baseline | **downtime starts** |
| 3.3 Back up the data | down |
| 3.4 Upgrade ClickHouse | down |
| 3.5 Upgrade or keep Postgres | down |
| 3.6 Run the migrations | down |
| 3.7 Start and verify | **back online** |
| 3.8 Enable persistent tracking, 3.9 clean up | online |

Events sent while the app is down are not queued, so they're lost (stored
data is not affected). Expect 15–60 minutes of downtime, depending on data
size.

> **Shell state.** Every step needs `PROJECT` and `BACKUP`. Step 3.1 saves
> them to `upgrade.vars`, and each later step starts with
> `. ./upgrade.vars && : "${PROJECT:?}" "${BACKUP:?}"`. That line reloads them
> and stops with an error if they're missing. Always run the steps from your
> install directory, even in a new terminal.
>
> The steps that change data run as scripts in [`upgrade/`](./upgrade):
> `backup.sh`, `postgres-16.sh` and `rollback.sh`. Each one stops at the
> first error, checks what it produced, and ends with an explicit `… OK`
> line. **If you don't see that line, don't continue.**

### 3.1 Prepare (old instance still running)

**a) Variables and backup location.** Run this in the directory of your
existing install (where your current `docker-compose.yml` is):

```sh
cd /path/to/your/plausible        # e.g. ~/hosting
docker compose ps                 # plausible, plausible_db, plausible_events_db, mail

DEPLOY_REF=claude/determined-cerf-dqrxgj
APP_REF=claude/determined-cerf-dqrxgj
PROJECT=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' \
  "$(docker compose ps -aq plausible_db)")
BACKUP="$HOME/plausible-backup-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP/config"
printf "PROJECT='%s'\nBACKUP='%s'\nDEPLOY_REF='%s'\nAPP_REF='%s'\n" \
  "$PROJECT" "$BACKUP" "$DEPLOY_REF" "$APP_REF" > upgrade.vars
cat upgrade.vars
docker volume ls --filter label=com.docker.compose.project="$PROJECT"
# expect: ${PROJECT}_db-data  ${PROJECT}_event-data  ${PROJECT}_event-logs
```

**b) Disk space.** You need free space of at least **2× the size of
`event-data` plus `db-data`**: one copy for the backup archives, and
headroom for ClickHouse mutations that rewrite data parts during migration.

```sh
for v in db-data event-data; do docker run --rm -v "${PROJECT}_${v}:/v:ro" alpine du -sh /v; done
df -h "$BACKUP"
```

**c) Check that your data is in the v2 tables.** An install that started on
v1.x and skipped the v2.0 data migration would still have it in the legacy
`events`/`sessions` tables:

```sh
docker compose exec plausible_events_db clickhouse-client -d plausible_events_db -q \
  "SELECT name, total_rows FROM system.tables WHERE database = currentDatabase() AND name IN ('events','sessions','events_v2','sessions_v2')"
```

If `events` has rows but `events_v2` is empty or much smaller, **stop here**.
Finish the v2.0 "NumericIDs" data migration on the old image first; see the
upstream v2.0.0 release notes.

**d) Back up the config files.**

```sh
for f in docker-compose.yml docker-compose.override.yml plausible-conf.env .env; do
  [ -f "$f" ] && cp "$f" "$BACKUP/config/"
done
cp -r clickhouse "$BACKUP/config/"
ls -la "$BACKUP/config"
```

**e) Switch to the new deployment files.** This doesn't affect the running
containers.

```sh
git stash                                 # your local edits (also saved in $BACKUP/config)
git remote add deviceid https://github.com/kurdin/community-edition.git
git fetch deviceid
git checkout -b persistent-tracking "deviceid/$DEPLOY_REF"
echo "PLAUSIBLE_SRC=https://github.com/kurdin/plausible-analytics-deviceid.git#$APP_REF" >> .env
```

> If your directory isn't a git clone, copy `docker-compose.yml`,
> `plausible-conf.env`, `clickhouse/` and `upgrade/` from the fork into it.
> Don't move the install to another directory: the project name, and with
> it the volume names, would change.

**f) Merge your old settings into the new `plausible-conf.env`.**

```sh
diff "$BACKUP/config/plausible-conf.env" plausible-conf.env
```

* Copy **`BASE_URL` and `SECRET_KEY_BASE` exactly** from the old file. Don't
  generate a new `SECRET_KEY_BASE`.
* Copy any other variables you had set (Google integration, `MAXMIND_*`,
  `DISABLE_REGISTRATION`, `MAILER_EMAIL`, SMTP credentials, …).
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

**g) Build the new image now, while the old app still serves traffic.** It
takes 10–20 minutes and needs about 4 GB of free RAM. On a small server,
build elsewhere (5.2).

```sh
docker compose build plausible
```

> Until step 3.4, don't run `docker compose up`. It would recreate
> containers from the new files. `stop`, `start` and `exec` are safe.

### 3.2 Stop the app and record the baseline (downtime starts)

```sh
. ./upgrade.vars && : "${PROJECT:?}" "${BACKUP:?}"
docker compose stop plausible
date -u '+%Y-%m-%d %H:%M:%S' > "$BACKUP/cutoff.txt"
cp upgrade/data-check.sh upgrade/rollback.sh "$BACKUP/"     # usable even after a rollback restores old files
"$BACKUP/data-check.sh" > "$BACKUP/before.txt"
cat "$BACKUP/before.txt"
```

### 3.3 Back up the data

```sh
. ./upgrade.vars && : "${PROJECT:?}" "${BACKUP:?}"
./upgrade/backup.sh
```

[`upgrade/backup.sh`](./upgrade/backup.sh) does the following:
1. Dumps Postgres (`pg_dump -Fc`).
2. Stops all services.
3. Archives `db-data`, `event-data` and `event-logs` with `tar` (through a
   throw-away `alpine` container).
4. Checks that every archive exists, isn't empty and is readable, and that
   the dump can be listed by `pg_restore`.

It ends with `BACKUP OK: <dir>`. The services stay stopped.

Keep `$BACKUP` until you've run the new version for a while, and ideally
copy it off the server too.

### 3.4 Upgrade ClickHouse in place (23.3 → 24.12)

ClickHouse upgrades its data files in place on first start. Go through the LTS
releases one at a time, checking the counts after each:

```sh
. ./upgrade.vars && : "${PROJECT:?}" "${BACKUP:?}"
for v in 23.8 24.3 24.8 24.12; do
  echo "== ClickHouse $v"
  CLICKHOUSE_VERSION=$v docker compose up -d --wait plausible_events_db || { echo "ClickHouse $v did not become healthy"; break; }
  docker compose exec -T plausible_events_db clickhouse-client -q \
    "SELECT version(), (SELECT count() FROM plausible_events_db.events_v2), (SELECT sum(sign) FROM plausible_events_db.sessions_v2)"
done
docker compose logs plausible_events_db | grep -iE '<Error>|Exception' | tail
```

Every line should show the same event and session counts as
`$BACKUP/before.txt`.

`--wait` allows ClickHouse up to about 11 minutes to load its data after
each version change. If a hop still fails, check `docker compose logs
plausible_events_db`. A big dataset may simply need more time: rerun the
same version. Otherwise roll back (section 4).

After the last hop, `docker compose up` uses 24.12 by default (no variable
needed).

### 3.5 Upgrade PostgreSQL (14 → 16) or stay on 14

**Option A: stay on Postgres 14 (simplest).** The current code needs nothing
newer than Postgres 13:

```sh
. ./upgrade.vars && : "${PROJECT:?}" "${BACKUP:?}"
echo 'POSTGRES_VERSION=14' >> .env
docker compose up -d --wait plausible_db
```

**Option B: move to Postgres 16.** A major-version upgrade needs a dump and
restore. Postgres 16 refuses to start on a v14 data directory ("database files
are incompatible with server") without changing it, so a mistake here is safe.

```sh
. ./upgrade.vars && : "${PROJECT:?}" "${BACKUP:?}"
./upgrade/postgres-16.sh
```

[`upgrade/postgres-16.sh`](./upgrade/postgres-16.sh) refuses to run if the
dump is missing or `POSTGRES_VERSION` is still set in `.env`. It then:
1. Copies the v14 data directory to the volume `${PROJECT}_db-data-pg14`.
2. Empties `db-data` in place.
3. Starts Postgres 16 and restores the dump with `pg_restore --exit-on-error`.

It ends with `POSTGRES 16 RESTORE OK`.

With either option, the Postgres part of the check must match the baseline:

```sh
"$BACKUP/data-check.sh" | head -7
head -7 "$BACKUP/before.txt"
```

### 3.6 Run the migrations

```sh
. ./upgrade.vars && : "${PROJECT:?}" "${BACKUP:?}"

# preview what will run (Postgres and ClickHouse, interleaved by date)
docker compose run --rm plausible db pending-migrations

# run them in the foreground so you can watch them
docker compose run --rm plausible db migrate
```

Notes:

* On large datasets some ClickHouse migrations rewrite data with mutations
  (normalising source names, adding columns). They can take a while.
  **Don't interrupt them.** If the command is killed anyway, rerun
  `db migrate`: finished migrations are recorded and skipped.
* Expected log lines include `Migration done!` (sessions engine conversion),
  `Finished backfilling sites` (site imports) and the teams backfill. Any
  error stops the command with a non-zero exit code.
* The command must end without errors before you continue.

### 3.7 Start and verify (back online)

```sh
. ./upgrade.vars && : "${PROJECT:?}" "${BACKUP:?}"
docker compose up -d
docker compose logs -f plausible           # wait for the endpoint to be running, then Ctrl-C
curl -fsS http://127.0.0.1:8000/api/system/health/ready && echo ready

./upgrade/data-check.sh "$(cat "$BACKUP/cutoff.txt")" > "$BACKUP/after.txt"
diff "$BACKUP/before.txt" "$BACKUP/after.txt" && echo "DATA IDENTICAL"
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
. ./upgrade.vars && : "${PROJECT:?}" "${BACKUP:?}"

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

Restoring the archives returns the install to its exact state at step 3.3.

> [!WARNING]
> A rollback **discards everything written after the upgrade started**: new
> events, and any sites, users or goals created since. The script
> archives the current state into `$BACKUP/pre-rollback/` first, so nothing
> is destroyed. Copy that data over by hand later if you need it.

Run it from your install directory:

```sh
. ./upgrade.vars && "$BACKUP/rollback.sh"
```

`rollback.sh` (copied to `$BACKUP` in step 3.2, so it's still there after
the old files are restored) refuses to touch anything unless all three
archives, the config backup, the baseline and the cutoff exist. It then:
1. Archives the current state to `$BACKUP/pre-rollback/`.
2. Restores the volumes **in place** (they keep their Compose labels).
3. Restores `docker-compose.yml`, `plausible-conf.env`,
   `docker-compose.override.yml`, `.env` and `clickhouse/` exactly as they
   were.
4. Starts only the databases (old images) and compares `data-check.sh`
   against the baseline.

It ends with `ROLLBACK DATA OK`. Then start the app:

```sh
docker compose up -d
```

Your working tree is still on the `persistent-tracking` branch, with the old
files copied over it. To return to your original branch, run
`git checkout -f <old branch> && git stash pop`.

You can't downgrade a migrated database by running old images on it.
Always roll back by restoring the archives.

---

## 5. Updating later

### 5.1 New versions of the fork

```sh
cd /path/to/your/plausible
docker compose exec -T plausible_db pg_dump -U postgres -Fc plausible_db > "plausible_db-$(date +%F).dump"
git pull                                           # deployment files
docker compose build --pull --no-cache plausible   # rebuild from PLAUSIBLE_SRC; the app keeps running
docker compose up -d                               # short restart; migrations run on start
docker compose logs -f plausible
```

For bigger jumps, follow section 3 (backups, baseline, `data-check.sh`)
instead.

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

Minor updates (`16.x`, `24.12.x`) only need
`docker compose pull --ignore-buildable && docker compose up -d`.
`--ignore-buildable` skips the locally built `plausible` image, which can't
be pulled.
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
PROJECT=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' \
  "$(docker compose ps -aq plausible_events_db)")
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
