# Migration guide: existing Plausible CE → persistent-tracking fork

This guide walks you through moving an existing Docker install of Plausible
Community Edition (v2.0, or any v2.1.x release or release candidate) to this
fork. You keep all data: users, sites, goals, stats, 2FA and settings.

It was used on a production server with these starting versions:
- `ghcr.io/plausible/community-edition:v2.1.0-rc.0`
- Postgres 14
- ClickHouse 23.3.7.5
- 3.07M events and 1.42M sessions

The verified result:
- every migration stage kept the event and session counts identical;
- the final check reported `UPGRADE VERIFIED`;
- downtime was a few minutes.

`deployment.md` is the full reference: fresh installs, an in-place
upgrade, routine backups and configuration. This guide is the practical
path, with the lessons learned on the way.

## How it works: copy, upgrade the copy, switch

```text
 old install (OLD_DIR)            new install (NEW_DIR)
 ┌────────────────────┐   copy    ┌────────────────────────────┐
 │ v2.x, port 8000    │ ───────▶  │ same data, upgraded through │
 │ volumes untouched  │           │ the official releases, then │
 └────────────────────┘           │ the fork; takes port 8000   │
        ▲                         └────────────────────────────┘
        └──── rollback = stop the new one, start the old one
```

* **The old install's data is never modified.** It stays on disk as your
  way back until you delete it yourself.
* **The new install is a separate Compose project.** Its folder name is the
  project name, so its volumes are separate too. It takes over port 8000, so
  **your reverse proxy (nginx) doesn't change**.
* **Rehearsal is optional but recommended.** You can do the whole thing
  first on a throwaway copy on port 8001 while the old install keeps
  serving.

| Phase | What | Old install |
| --- | --- | --- |
| 0 | Checks | online |
| 1 | Prepare: BuildKit, build the image, download images | online |
| 2 | Rehearse on a copy (optional) | online (down ~1 min for the copy) |
| 3 | Switch over | **down a few minutes** |
| 4 | Verify, enable persistent tracking | — |
| 5 | Clean up (after a week or so) | deleted |

Run everything as root (or with `sudo`) on the server. Run long steps inside
`tmux`.

---

## Variables used in this guide

Set these in every new shell. Use folder names with only lowercase letters,
digits and dashes: the folder name becomes the Compose project name and
the volume prefix.

```sh
OLD_DIR=/home/gits/plausible-stats     # your current install (where its docker-compose.yml is)
NEW_DIR=/home/gits/plausible-kurdin    # the new install (must not exist yet)
TEST_DIR=/home/gits/plausible-test     # the rehearsal copy (phase 2 only)
REF=plausible-kurdin                   # branch of both kurdin repos
OLD_PROJECT=$(cd "$OLD_DIR" && docker compose config 2>/dev/null | sed -n 's/^name: //p')
echo "$OLD_PROJECT"                     # e.g. plausible-stats
```

---

## Phase 0: checks (old install keeps running)

```sh
cd "$OLD_DIR"
docker compose version                  # must be v2.24.4 or newer (the scripts use "docker compose", with a space)
docker compose ps                       # plausible, plausible_db, plausible_events_db (+ mail)
docker volume ls | grep "${OLD_PROJECT}_"   # db-data, event-data, event-logs
grep -c '^TOTP_VAULT_KEY=.' plausible-conf.env   # 1 = you have a 2FA key: it will be carried over
for v in db-data event-data; do docker run --rm -v "${OLD_PROJECT}_$v:/v:ro" alpine du -sh /v; done
df -h /var/lib/docker                   # free space: at least 3x the data size
free -h                                 # building needs ~4 GB available (see phase 1)
docker compose exec plausible_events_db clickhouse-client -d plausible_events_db -q \
  "SELECT name, engine, total_rows FROM system.tables WHERE database = currentDatabase() AND name IN ('events','sessions','events_v2','sessions_v2')"
git status --short; git remote -v       # is the folder a git clone? (plausible/hosting or community-edition)
```

What to look for:
- **`docker compose` is missing or old:** install the plugin, e.g.
  `apt install docker-compose-plugin`.
- **The volumes:** all three must exist: `db-data`, `event-data`,
  `event-logs`.
- **The ClickHouse tables:** `events_v2` and `sessions_v2` must hold your
  data. If `events` has rows but `events_v2` is empty, the v2.0 data
  migration was never finished: **stop**, and see the upstream v2.0.0
  release notes.
- **The `sessions_v2` engine** can be `CollapsingMergeTree` or
  `VersionedCollapsingMergeTree`; both are handled.

---

## Phase 1: prepare (old install keeps running)

### 1.1 BuildKit

The app's `Dockerfile` uses `COPY --chmod`, which needs BuildKit. Ubuntu's
`docker.io` package ships without it, and the old builder fails with
`unknown flag: --progress` or `the --chmod option requires BuildKit`.

```sh
docker buildx version || { apt update && apt install -y docker-buildx; }
docker buildx version
```

With Docker's own packages (`docker-ce`), the package is
`docker-buildx-plugin`. Installing it doesn't restart running containers.

### 1.2 Memory for the build

The build briefly needs about 4 GB of RAM. If `free -h` shows less
**available** memory, add temporary swap and/or pause non-critical stacks:

```sh
fallocate -l 4G /swap-build && chmod 600 /swap-build && mkswap /swap-build && swapon /swap-build
# optional: cd /path/to/other-stack && docker compose stop   (start it again later)
```

### 1.3 Build the app image

```sh
tmux new -s plausible          # if tmux says "sessions should be nested", you're already in one: just continue
docker build --progress=plain -t plausible-deviceid:local \
  "https://github.com/kurdin/plausible-analytics-deviceid.git#$REF" 2>&1 | tee /root/plausible-build.log
docker image ls plausible-deviceid           # plausible-deviceid  local  ~190MB
```

This takes 15–30 minutes. It ends with
`naming to docker.io/library/plausible-deviceid:local done`. Then clean up:

```sh
swapoff /swap-build && rm /swap-build        # if you added it
docker builder prune -f                      # frees the build cache (~1 GB)
```

### 1.4 Download everything the migration needs

```sh
for v in v2.1.0 v2.1.1 v2.1.5 v3.0.1 v3.1.0 v3.2.0; do docker pull ghcr.io/plausible/community-edition:$v; done
for v in 23.8 24.3 24.8 24.12; do docker pull clickhouse/clickhouse-server:$v-alpine; done
docker pull postgres:16-alpine; docker pull alpine
```

**tmux tips:**
- Scroll with `Ctrl+b` then `[`, then PgUp/PgDn; `q` exits.
- Or run `tmux set -g mouse on` once.
- After a dropped SSH connection, `tmux attach` brings you back.

---

## Phase 2: rehearse on a copy (optional, recommended)

This runs the exact upgrade on a copy of your data on port 8001. Live keeps
serving, except for about a minute while the volumes are copied.

### 2.1 Make the copy

```sh
cp -a "$OLD_DIR" "$TEST_DIR"
cd "$TEST_DIR"
[ -f .env ] && sed -i '/^COMPOSE_PROJECT_NAME=/d' .env    # must not point at the old project
TEST_PROJECT=$(docker compose config 2>/dev/null | sed -n 's/^name: //p'); echo "$TEST_PROJECT"   # MUST be the test folder name

cat > docker-compose.override.yml <<'YML'
services:
  plausible:
    ports: !override
      - 127.0.0.1:8001:8000
YML

# the copy must never email your users, and is opened through an SSH tunnel
sed -i -e 's|^BASE_URL=.*|BASE_URL=http://localhost:8001|' -e 's|^SMTP_HOST_PORT=.*|SMTP_HOST_PORT=1|' plausible-conf.env
grep -q '^SMTP_HOST_PORT=' plausible-conf.env || echo 'SMTP_HOST_PORT=1' >> plausible-conf.env
```

If the old folder already had a `docker-compose.override.yml`, merge the
`ports` part into it instead of replacing it.

### 2.2 Copy the data (old install down for about a minute)

```sh
(cd "$OLD_DIR" && docker compose stop)
for v in db-data event-data event-logs; do
  docker run --rm -v "${OLD_PROJECT}_$v:/from:ro" -v "${TEST_PROJECT}_$v:/to" alpine cp -a /from/. /to/
done
(cd "$OLD_DIR" && docker compose up -d)                    # old install back online

cd "$TEST_DIR"
docker compose up -d                                       # the OLD version, running on the copy
sleep 30; curl -s http://127.0.0.1:8001/api/health; echo   # {"postgres":"ok","clickhouse":"ok",...}
```

You'll see two harmless warnings:
- "volume … already exists but was not created by Docker Compose";
- "the attribute `version` is obsolete".

The health check is empty for the first ~30 seconds, while the app runs its
startup checks.

### 2.3 Upgrade the copy

Run the same steps as phase 3, steps 3.3–3.6, inside `$TEST_DIR`. The
config step keeps the test `BASE_URL` and `SMTP_HOST_PORT=1`, because they
come from the copy's old config.

### 2.4 Look at it

On your PC, open an SSH tunnel and keep it open:

```sh
ssh -L 8001:127.0.0.1:8001 root@your-server        # with a custom SSH port: ssh -p 8822 -L 8001:127.0.0.1:8001 root@your-server
```

Then open **http://localhost:8001**:
- log in, with 2FA if you use it;
- compare a past month with the live dashboard;
- note how long the backup and migration took: that's your downtime in
  phase 3.

> Do **not** point your reverse proxy at port 8001. The copy has old data,
> a localhost `BASE_URL` and email disabled.

### 2.5 Remove the copy

Run this only from inside the test folder:

```sh
cd "$TEST_DIR" && docker compose down -v && cd .. && rm -rf "$TEST_DIR"
```

---

## Phase 3: switch over

### 3.1 Prepare the new folder (old install keeps running)

```sh
cp -a "$OLD_DIR" "$NEW_DIR"
cd "$NEW_DIR"
[ -f .env ] && sed -i '/^COMPOSE_PROJECT_NAME=/d' .env    # must not point at the old project
NEW_PROJECT=$(docker compose config 2>/dev/null | sed -n 's/^name: //p'); echo "$NEW_PROJECT"     # MUST be the new folder name
git remote add deviceid https://github.com/kurdin/community-edition.git
git fetch deviceid
git checkout "deviceid/$REF" -- upgrade/
ls upgrade/                       # backup.sh merge-config.sh migrate.sh verify.sh rollback.sh finalize.sh ...
```

If the folder isn't a git clone, download the scripts instead:

```sh
curl -fsSL "https://github.com/kurdin/community-edition/archive/refs/heads/$REF.tar.gz" \
  | tar -xz --strip-components=1 --wildcards '*/upgrade/*'
```

### 3.2 Downtime starts: shut down the old install and copy its data

```sh
(cd "$OLD_DIR" && docker compose down)     # DOWN, not stop: removes containers, keeps the data volumes
for v in db-data event-data event-logs; do
  docker run --rm -v "${OLD_PROJECT}_$v:/from:ro" -v "${NEW_PROJECT}_$v:/to" alpine cp -a /from/. /to/
done
cd "$NEW_DIR"
docker compose up -d plausible_db plausible_events_db       # databases only, still the old versions
```

Use `down`, not `stop`. The containers have `restart: always`, so stopped
ones would come back after a reboot and fight the new install for port 8000.

### 3.3 Back up

```sh
./upgrade/backup.sh                        # must end with BACKUP OK
```

### 3.4 Switch to the new deployment files and build the config

```sh
. ./upgrade.vars
git stash                                  # your old local edits (also saved in $BACKUP/config)
git checkout -b persistent-tracking "deviceid/$REF"
printf 'POSTGRES_VERSION=14\nPLAUSIBLE_SRC=https://github.com/kurdin/plausible-analytics-deviceid.git#%s\n' "$REF" >> .env
./upgrade/merge-config.sh                  # must end with CONFIG MERGED
```

Not a git clone? Download the files instead of `git stash`/`checkout`:

```sh
curl -fsSL "https://github.com/kurdin/community-edition/archive/refs/heads/$REF.tar.gz" | tar -xz --strip-components=1
```

[`upgrade/merge-config.sh`](./upgrade/merge-config.sh) builds the new
`plausible-conf.env` from the template and **every setting of your old
file**: `BASE_URL`, `SECRET_KEY_BASE`, `TOTP_VAULT_KEY`, SMTP, Google,
MaxMind and so on. It sets `ENABLE_PERSISTENT_TRACKING=false` for the
upgrade, and generates `PERSISTENT_SALT_SECRET` once. Check its output:

* `BASE_URL` is your real URL (or `http://localhost:8001` in the rehearsal).
* `SMTP_HOST_PORT` is your real port (`1` in the rehearsal).
* `TOTP_VAULT_KEY: carried over`, if you had one. Without it, users with 2FA
  can't log in, and `migrate.sh` refuses to run.
* No `WARNING` lines. `MAILER_ADAPTER=Bamboo.SMTPAdapter` must become
  `Bamboo.Mua`.

`POSTGRES_VERSION=14` keeps your Postgres 14 data as it is. Moving to 16 is
optional: see `deployment.md` step 4 and `upgrade/postgres-16.sh`.

### 3.5 Migrate

```sh
./upgrade/migrate.sh 2>&1 | tee /root/migrate.log     # must end with MIGRATIONS OK
```

It goes through the official releases in order, each with the ClickHouse
version it was released for:

```text
ClickHouse 23.8 → 24.3 → sessions_v2 conversion → CE v2.1.0 → v2.1.1 → v2.1.5
→ ClickHouse 24.8 → 24.12 → CE v3.0.1 → v3.1.0 → v3.2.0 → the fork
```

After every step it prints `events,sessions = … (matches the backup)`.
Long runs of `acquisition_channel_functions-NN Done!` are normal. If it
stops, fix the cause and run it again: finished steps are skipped.
For a progress summary:

```sh
grep -E -- '^-> |matches|EXCHANGE' /root/migrate.log
```

### 3.6 Start the new version: downtime ends

```sh
docker compose up -d
./upgrade/verify.sh                                  # must end with UPGRADE VERIFIED
curl -s http://127.0.0.1:8000/api/health; echo
docker ps --format '{{.Names}}  {{.Image}}  {{.Ports}}' | grep 8000   # <new project>-plausible-1  plausible-deviceid:local
```

Your site now serves the new version through the unchanged reverse proxy.
Check:
- login with 2FA;
- the dashboards;
- the realtime view, to see new visits arriving.

Then start any stacks you paused in phase 1.

---

## Rollback (any time before phase 5)

```sh
cd "$NEW_DIR" && docker compose down
cd "$OLD_DIR" && docker compose up -d
```

You're back exactly where you were before 3.2. Visits recorded by the new
version in between stay in the new volumes.

---

## Phase 4: enable persistent tracking

> Full details: [PERSISTENT-TRACKING.md](./PERSISTENT-TRACKING.md) covers
> how visitors are identified, turning it on and off, sending `deviceId`
> from apps and websites, and the new reports.

1. **Back up the new `plausible-conf.env` off the server.** It holds
   `PERSISTENT_SALT_SECRET`, which must never change: a new secret makes
   every visitor look new.
2. **Turn tracking on:**
   ```sh
   cd "$NEW_DIR"
   sed -i 's/^ENABLE_PERSISTENT_TRACKING=.*/ENABLE_PERSISTENT_TRACKING=true/' plausible-conf.env
   docker compose up -d plausible
   sleep 40 && docker compose logs plausible | grep -i persistent    # "Persistent tracking enabled, recording period start ..."
   ```
3. **Send a stable `deviceId`** with every event. See `deployment.md` §2.8
   for the script tag and npm examples. Without it, visitors are
   identified by IP + browser, which is stable across days but not across
   networks.
4. **The DAU / WAU / MAU tiles appear.** They're marked `*` until the windows
   no longer reach back before the day you turned tracking on.

Check that one device counts as one visitor:

```sh
docker compose exec plausible_events_db clickhouse-client -q \
  "SELECT user_id, count() FROM plausible_events_db.events_v2 WHERE timestamp > now() - INTERVAL 10 MINUTE GROUP BY user_id ORDER BY count() DESC LIMIT 5"
```

---

## Phase 5: clean up (after a week or so)

Only when you're sure you won't roll back:

```sh
cd "$NEW_DIR" && ./upgrade/finalize.sh               # deletes this install's backup and conversion leftovers
cd "$OLD_DIR" && docker compose down -v              # deletes the OLD data: point of no return
for v in v2.1.0 v2.1.1 v2.1.5 v3.0.1 v3.1.0 v3.2.0; do docker rmi ghcr.io/plausible/community-edition:$v; done
for v in 23.3.7.5 23.8 24.3 24.8; do docker rmi clickhouse/clickhouse-server:$v-alpine; done
```

You can delete the old folder afterwards. Keep the new folder's name: it is
the Compose project name of your data volumes.

---

## Updating later

```sh
cd "$NEW_DIR"
git branch -u "deviceid/$REF"               # once: follow the $REF branch
git pull                                    # new deployment files
docker build -t plausible-deviceid:local "https://github.com/kurdin/plausible-analytics-deviceid.git#$REF"
docker compose up -d                        # runs new migrations on start
```

Take a backup first (`deployment.md` §6).

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `unknown flag: --progress`, or `--chmod option requires BuildKit` | Install BuildKit: `apt install docker-buildx` (phase 1.1) |
| Build is very slow or other containers die | Out of memory: add temporary swap, pause other stacks (1.2) |
| `sessions should be nested with care` | You're already inside tmux; just run the command |
| Can't scroll in tmux | `Ctrl+b` `[` then PgUp/PgDn (`q` to exit), or `tmux set -g mouse on` |
| `the attribute version is obsolete` | Old compose file; harmless, gone after 3.4 |
| `volume … already exists but was not created by Docker Compose` | Expected for copied volumes |
| Health check prints nothing | The app is still starting; wait 30–60 s |
| `TOTP_VAULT_KEY … missing or differs` from `migrate.sh` | Copy it exactly from `$BACKUP/config/plausible-conf.env` (`merge-config.sh` does this) |
| `migrate.sh` stops at a stage | Paste the end of `/root/migrate.log` into an issue; rerun after the fix (it resumes) |
| `verify.sh` shows a diff | Fewer goals can be upstream de-duplication; anything else, roll back and investigate |
| Port 8000 already in use when starting the new install | The old install is still up: `cd "$OLD_DIR" && docker compose down` |
