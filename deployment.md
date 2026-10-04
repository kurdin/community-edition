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
pending Postgres *and* ClickHouse migrations together, in chronological
order. For a big jump such as v2.0 → latest, run `upgrade/migrate.sh`
instead; it goes through the official releases in order (section 3).
Migrations add
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
`clickhouse/clickhouse-server:23.3.7.5-alpine`).

### The short version

```text
1. prepare  (app online)   fetch the upgrade scripts, build the new image
2. backup   (downtime)     ./upgrade/backup.sh            -> "BACKUP OK"
3. switch                  new docker-compose.yml / plausible-conf.env
4. postgres                keep 14, or ./upgrade/postgres-16.sh
5. migrate                 ./upgrade/migrate.sh           -> "MIGRATIONS OK"
6. start    (app online)   docker compose up -d && ./upgrade/verify.sh -> "UPGRADE VERIFIED"
7. not happy?              "$BACKUP/rollback.sh"          -> back to v2.0, exactly as before
8. happy?                  ./upgrade/finalize.sh          -> backup deleted, done
```

The backup stays untouched until **you** run `finalize.sh`. Until then you
can always roll back to the state from step 2.

### What changes

| | Before (v2.0) | After |
| --- | --- | --- |
| App | `plausible/analytics:v2.0` | built from the fork (latest Plausible CE) |
| Postgres | 14 | 16 (dump/restore), or stay on 14 |
| ClickHouse | 23.3 | 24.12, upgraded in place through 23.8 → 24.3 → 24.8 |
| Postgres schema | v2.0 | migrated through the official releases v2.1.1 → v2.1.5 → v3.0.1 → v3.1.0 → v3.2.0, then the fork |
| ClickHouse schema | v2.0 | migrated along the same path (new columns, `sessions_v2` engine conversion, source-name normalisation) |

**Why migrate in stages?** Some Plausible data migrations load the
application's *current* database schema. For example, the 2024 site-imports
migration preloads `sites`. Run with code that is years newer, they'd expect
columns that later migrations haven't created yet, and fail. Running each
official release's own migrations in order avoids this, and each release
runs with the ClickHouse version it was released for. `migrate.sh` does this
for you.

### How "no data loss" is guaranteed

1. **Full backup first:** `backup.sh` saves a Postgres dump, archives of all
   data volumes and your config files, and verifies all of them.
2. **A baseline of the data.** `backup.sh` records counts of users, sites,
   distinct goals, shared links and API keys; event and session counts;
   per-site visitors and a checksum of all events; and imported rows.
   `migrate.sh` re-checks the event and session counts after every stage,
   and `verify.sh` compares the full baseline at the end.
3. **The backup stays untouched until you finalize.** `rollback.sh`
   restores it exactly.

**Rehearsed here:** on a v2.0-shaped dataset I ran:
- the ClickHouse hops 23.3.7.5 → 23.8 → 24.3 → 24.8 → 24.12;
- the `sessions_v2` engine conversion SQL;
- the Postgres 14 → 16 restore;
- `backup.sh`, `data-check.sh` and `rollback.sh`.

The data was identical at every check.

**Not rehearsed here:** the staged migrations with the official release
images (they couldn't be downloaded in the test environment). They are the
same migrations every upstream CE install ran when upgrading release by
release.

### Step 1: prepare (app still online)

Run everything from the directory of your existing install (where your
current `docker-compose.yml` is). The directory name is the Compose project
name, which prefixes the volume names, so don't move it.

```sh
cd /path/to/your/plausible        # e.g. ~/hosting
docker compose ps                 # plausible, plausible_db, plausible_events_db, mail

DEPLOY_REF=claude/determined-cerf-dqrxgj     # branch/tag of kurdin/community-edition
APP_REF=claude/determined-cerf-dqrxgj        # branch/tag of kurdin/plausible-analytics-deviceid

# a) get the upgrade scripts. This only adds files under upgrade/; nothing else changes yet
git remote add deviceid https://github.com/kurdin/community-edition.git
git fetch deviceid
git checkout "deviceid/$DEPLOY_REF" -- upgrade/
```

> If your directory isn't a git clone, download the scripts instead:
> `curl -fsSL "https://github.com/kurdin/community-edition/archive/$DEPLOY_REF.tar.gz" | tar -xz --strip-components=1 --wildcards '*/upgrade/*'`

```sh
# b) build the new app image now, while the old app keeps serving (10-20 min, ~4 GB RAM)
docker build -t plausible-deviceid:local "https://github.com/kurdin/plausible-analytics-deviceid.git#$APP_REF"

# c) pre-download everything the upgrade needs, so the downtime is shorter
for v in v2.1.1 v2.1.5 v3.0.1 v3.1.0 v3.2.0; do docker pull "ghcr.io/plausible/community-edition:$v"; done
for v in 23.8 24.3 24.8 24.12; do docker pull "clickhouse/clickhouse-server:$v-alpine"; done
docker pull postgres:16-alpine; docker pull alpine
```

**d) Check disk space.** You need free space of at least **2× the size of
your data**: one copy for the backup, and headroom for ClickHouse rewriting
data during the migrations.

```sh
PROJECT=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' \
  "$(docker compose ps -aq plausible_db)")
for v in db-data event-data; do docker run --rm -v "${PROJECT}_${v}:/v:ro" alpine du -sh /v; done
df -h .
```

**e) Check that your data is in the v2 tables.** An install that started on
v1.x and skipped the v2.0 data migration would still have it in the legacy
tables:

```sh
docker compose exec plausible_events_db clickhouse-client -d plausible_events_db -q \
  "SELECT name, total_rows FROM system.tables WHERE database = currentDatabase() AND name IN ('events','sessions','events_v2','sessions_v2')"
```

If `events` has rows but `events_v2` is empty or much smaller, **stop here**.
Finish the v2.0 "NumericIDs" data migration on the old image first; see the
upstream v2.0.0 release notes.

### Step 2: back up (downtime starts)

```sh
./upgrade/backup.sh
```

[`upgrade/backup.sh`](./upgrade/backup.sh):
1. Stops the app.
2. Records the time and a data baseline.
3. Copies your config files (`docker-compose.yml`, the override,
   `plausible-conf.env`, `.env`, `clickhouse/`) and the rollback scripts.
4. Dumps Postgres, stops all services and archives every data volume.
5. Verifies each file.

Everything goes into `./backups/<timestamp>/`; set `BACKUP_DIR=/other/disk`
to put it elsewhere. It also writes `upgrade.vars`, so the other scripts
know where the backup is. It must end with **`BACKUP OK`**; if it doesn't,
don't continue (`docker compose up -d` brings the old version back).

Ideally, also copy the backup directory off the server.

### Step 3: switch to the new deployment files

```sh
. ./upgrade.vars
git stash                                    # your local edits (also saved in $BACKUP/config)
git checkout -b persistent-tracking "deviceid/$DEPLOY_REF"
echo "PLAUSIBLE_SRC=https://github.com/kurdin/plausible-analytics-deviceid.git#$APP_REF" >> .env
diff "$BACKUP/config/plausible-conf.env" plausible-conf.env
```

> In a new terminal, set `DEPLOY_REF` and `APP_REF` again first (step 1).
> Not a git clone? Copy `docker-compose.yml`, `plausible-conf.env` and
> `clickhouse/` from the fork into the directory.

Edit `plausible-conf.env`:

* Copy **`BASE_URL` and `SECRET_KEY_BASE` exactly** from the old file
  (`$BACKUP/config/plausible-conf.env`). Don't generate a new
  `SECRET_KEY_BASE`.
* Copy any other variables you had set (Google integration, `MAXMIND_*`,
  `DISABLE_REGISTRATION`, `MAILER_EMAIL`, SMTP credentials, …).
* If you had `MAILER_ADAPTER=Bamboo.SMTPAdapter`, change it to `Bamboo.Mua`.
  The old adapter was removed and the app refuses to start with it.
* Set **`ENABLE_PERSISTENT_TRACKING=false` for the upgrade itself**. You'll
  turn it on in step 8.
* Generate `PERSISTENT_SALT_SECRET` now so it's ready:
  ```sh
  sed -i "s|^PERSISTENT_SALT_SECRET=.*|PERSISTENT_SALT_SECRET=$(openssl rand -base64 48 | tr -d '\n')|" plausible-conf.env
  ```

If you had a `docker-compose.override.yml`, it is still in place. Check that
it doesn't pin `image: plausible/analytics:v2.0` or old database images.

### Step 4: Postgres: keep 14 or move to 16

**Option A: stay on Postgres 14 (simplest).** The current code needs nothing
newer than Postgres 13:

```sh
echo 'POSTGRES_VERSION=14' >> .env
```

**Option B: move to Postgres 16** (dump/restore):

```sh
./upgrade/postgres-16.sh
```

[`upgrade/postgres-16.sh`](./upgrade/postgres-16.sh):
1. Copies the v14 data directory to the volume `<project>_db-data-pg14`.
2. Empties `db-data` in place.
3. Starts Postgres 16 and restores the dump from the backup with
   `--exit-on-error`.

It must end with **`POSTGRES 16 RESTORE OK`**. If you skip this step and
forget option A, Postgres 16 refuses to start on the v14 data ("database
files are incompatible with server") without changing it.

### Step 5: migrate

```sh
./upgrade/migrate.sh
```

[`upgrade/migrate.sh`](./upgrade/migrate.sh):
1. Upgrades ClickHouse to 23.8 and 24.3.
2. Runs the migrations of Plausible CE v2.1.1 and v2.1.5.
3. Upgrades ClickHouse to 24.8 and 24.12.
4. Runs the migrations of v3.0.1, v3.1.0, v3.2.0 and finally the fork.

After every stage it checks that the event and session counts still match
the backup. It must end with **`MIGRATIONS OK`**.

* On large datasets some stages take a while: ClickHouse rewrites data to
  normalise source names and add columns. **Don't interrupt it.** If it
  stops anyway (error, lost SSH session), run it again: finished stages are
  recorded in `$BACKUP/migrate.done` and skipped.
* Use `tmux` or `screen` on a remote server.

### Step 6: start and verify (back online)

```sh
docker compose up -d
./upgrade/verify.sh
```

[`upgrade/verify.sh`](./upgrade/verify.sh) waits for the app to be ready,
then compares the data with the backup baseline. Events and sessions are
counted up to the backup time, so new traffic doesn't count. It must end
with **`UPGRADE VERIFIED`**. Then check by hand:

* Log in with your existing account (and 2FA, if enabled).
* Open each site's dashboard for "All time". Visitors and pageviews must
  match what you saw before. Source names may be normalised (e.g. `fb` →
  `Facebook`); totals are unchanged.
* Make sure new pageviews show up in the realtime view.

Take as long as you need: days, if you like. The backup stays until step 8.

### Step 7: not happy? Roll back

See [section 4](#4-rollback): `. ./upgrade.vars && "$BACKUP/rollback.sh"`.

### Step 8: happy? Enable tracking and delete the backup

Turn on persistent tracking:

```sh
sed -i 's/^ENABLE_PERSISTENT_TRACKING=.*/ENABLE_PERSISTENT_TRACKING=true/' plausible-conf.env
grep PERSISTENT_SALT_SECRET plausible-conf.env      # must be set, >= 16 chars
docker compose up -d plausible                      # recreates the container with the new env
```

Update your tracking snippet to send `deviceId` (section 2.8). Data from
before this point keeps its daily-rotating ids. Visitors who come back on
later days are now counted once over multi-day ranges.

When you no longer need a way back, delete the backup and the upgrade
leftovers:

```sh
./upgrade/finalize.sh
```

[`upgrade/finalize.sh`](./upgrade/finalize.sh) shows what it will delete and
asks you to type `delete`:
* the backup directory;
* the old `sessions_v2` table kept by the engine conversion (only once
  `sessions_v2` is confirmed converted);
* the `<project>_db-data-pg14` volume (option B only);
* `upgrade.vars`.

It ends with **`FINALIZED`**. Optionally, also run `git stash drop` to
forget the stashed old config.

---

## 4. Rollback

Restoring the backup returns the install to its exact state when
`backup.sh` ran (step 2).

> [!WARNING]
> A rollback **discards everything written after the upgrade started**: new
> events, and any sites, users or goals created since. The script
> archives the current state into `$BACKUP/pre-rollback/` first, so nothing
> is destroyed. Copy that data over by hand later if you need it.

Run it from your install directory:

```sh
. ./upgrade.vars && "$BACKUP/rollback.sh"
```

`rollback.sh` (copied into the backup by `backup.sh`, so it's still there
after the old files are restored) refuses to touch anything unless all three
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
Major Postgres versions need a dump/restore (see `upgrade/postgres-16.sh`).
For major ClickHouse versions, step through the LTS releases, as
`upgrade/migrate.sh` does.

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
| `plausible_db` restarts, log says *database files are incompatible with server* | Postgres 16 on a v14 volume. Set `POSTGRES_VERSION=14` in `.env`, or run `upgrade/postgres-16.sh` (step 4). Nothing was changed on disk. |
| `migrate.sh` stops with an error | Fix the cause it prints, then run it again; finished stages are skipped. If it can't pull `ghcr.io/plausible/community-edition:*` images, run the `docker pull` lines from step 1c first (or log in to ghcr.io). If you're stuck, roll back. |
| `migrate.sh` says the event/session counts changed | Stop and don't start the app. Keep the logs, and roll back (section 4). |
| `verify.sh` shows a difference in `goals (distinct)` or the per-site lines | Don't finalize. Investigate first, or roll back. |
| ClickHouse is up, but the app logs `Authentication failed` / connection refused on 8123 | Newer ClickHouse images lock down the passwordless `default` user. The compose file sets `CLICKHOUSE_SKIP_USER_SETUP=1`; make sure an override doesn't remove it. |
| ClickHouse fails with `ulimit` / `rlimit` errors | Some hosts (LXC, rootless Docker) can't raise `nofile`. Remove the `ulimits` block in an override (`ulimits: !reset {}`). |
| ClickHouse fails to start on IPv6-less hosts | `clickhouse/ipv4-only.xml` is mounted for this; make sure the file exists. |
| App exits: `PERSISTENT_SALT_SECRET must be set …` | Tracking is enabled without a secret (or with one shorter than 16 bytes). Generate one (2.3). |
| App exits: `Bamboo.SMTPAdapter is no longer supported` | Set `MAILER_ADAPTER=Bamboo.Mua` (or remove the line). |
| Dashboard empty after the upgrade | You're probably running from another directory, so Compose created new empty volumes (`<newproject>_event-data`). Stop, `cd` to the original directory (or set `COMPOSE_PROJECT_NAME=<old project>` in `.env`) and start again. Your data is in the old volumes. |
| `db migrate` is slow / ClickHouse uses lots of CPU | Mutations are rewriting data on a large dataset. Let it finish; `SELECT * FROM system.mutations WHERE is_done = 0` shows progress. |
| Small server runs out of memory | Uncomment both `low-resources` mounts for ClickHouse in `docker-compose.yml`, and build the image elsewhere (5.2). |
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
