# Review handoff: persistent tracking fork + lossless upgrade flow (round 3)

You are reviewing fixes made in response to two earlier reviews. Verify that
each fix is correct and complete, and look for new problems the fixes may
have introduced. **Report findings only; don't change files.**

## Repositories and what to diff

Both repos are on branch **`claude/determined-cerf-dqrxgj`**, pushed to GitHub:

| Repo | Base of feature | Last reviewed | Current head |
| --- | --- | --- | --- |
| `kurdin/plausible-analytics-deviceId` (Elixir app fork) | `d21298d` | `b265b74` | `534f84c` |
| `kurdin/community-edition` (Docker deployment) | `06f122f` | `337c5a3` | `a4f7aeb` |

```sh
git fetch origin claude/determined-cerf-dqrxgj && git checkout claude/determined-cerf-dqrxgj
# fork: changes since the last review / whole feature
git diff b265b74..534f84c
git diff d21298d..534f84c
# community-edition: changes since the last review / whole feature
git diff 337c5a3..a4f7aeb
git diff 06f122f..a4f7aeb
```

## Feature recap (unchanged intent)

- `ENABLE_PERSISTENT_TRACKING` (default `false`): when true, `user_id` comes
  from `lib/plausible/ingestion/persistent_id.ex` instead of the daily
  rotating salt. When false, upstream behaviour must be unchanged.
- **Tier 1:** the custom prop `PERSISTENT_TRACKING_DEVICE_ID_PROP` (default
  `deviceId`) gives `SipHash(key, encode(["device", site_id, device_id]))`.
- **Tier 2:** without the prop, `SipHash(key, encode(["fp", site_id, ua, ip]))`.
- In EE builds the replay session id is appended as an extra field.
  `key = sha256(PERSISTENT_SALT_SECRET)[0..16]`.
- `deviceId` is **intentionally kept** as a normal custom prop (owner
  decision).
- No stats query changes: visitors are already `uniq(user_id)` over the
  range.

## What changed since the last review

### Fork (`b265b74..534f84c`, one commit `534f84c`)

| # | Finding | Fix | Where |
| --- | --- | --- | --- |
| F1 | EE collision: the replay id was concatenated to the device id (`device-1`+`23` = `device-12`+`3` = `device-123`) | Every field is length-prefixed (`"<bytes>:<field>"`). The replay id is a separate field (none when nil) | `persistent_id.ex:58-79`; test `persistent_id_test.exs:107` |
| F2 | `low-resources.xml` profile settings ignored under `config.d` | Split: `low-resources.xml` (server: `mark_cache_size`) + `default-profile-low-resources-overrides.xml` (`users.d`) | `deploy/clickhouse/*`, `docker-compose.yml` comments |
| F3 | Healthcheck timing too tight for ClickHouse after a version change; `pg_isready` passes during initdb | `pg_isready -h 127.0.0.1`, `interval: 10s`, CH `retries: 60` | `docker-compose.yml` |
| F4 | `MAILER_EMAIL=plausible@example.com` overrode the sane default | Commented out (default is `plausible@<BASE_URL host>`); noted that `bytemark/smtp` is amd64-only | `plausible-conf.env.example` |
| F5 | Docs implied volumes are reused from any directory | Explain the Compose project prefix and `COMPOSE_PROJECT_NAME` / `POSTGRES_VERSION=14` | `docker-compose.yml` header, `deploy/README.md` |
| F6 | ClickHouse checked before the 5s ingest flush | `sleep 6` | `deploy/README.md` |
| F7 | Moduledoc overstated privacy | Notes that the device id is still stored as a prop | `persistent_id.ex` moduledoc |

Note: the length-prefixed encoding changes the hash input format compared
with `cc34b04`. Nothing has been deployed, so no ids need to stay stable
across this change.

### community-edition (`337c5a3..a4f7aeb`, 5 commits)

**Design change: the upgrade is now a script flow** (see `deployment.md` §3):

```text
upgrade/backup.sh    -> "BACKUP OK"        config + pg_dump + volume tars + data baseline, writes ./upgrade.vars
(switch files: git checkout of the branch, merge plausible-conf.env)
upgrade/postgres-16.sh (optional) -> "POSTGRES 16 RESTORE OK"
upgrade/migrate.sh   -> "MIGRATIONS OK"    CH 23.8->24.3, CE v2.1.1->v2.1.5, CH 24.8->24.12, CE v3.0.1->v3.1.0->v3.2.0, fork
docker compose up -d && upgrade/verify.sh -> "UPGRADE VERIFIED"
"$BACKUP/rollback.sh" -> "ROLLBACK DATA OK"   |   upgrade/finalize.sh -> "FINALIZED" (deletes the backup)
```

| # | Finding | Fix | Where |
| --- | --- | --- | --- |
| C1 | (P1) The default build used fork `master`, which lacks the feature | Default `PLAUSIBLE_SRC` = `…deviceid.git#claude/determined-cerf-dqrxgj`; README/guide updated | `docker-compose.yml:57`, `README.md`, `deployment.md` §2.4, §8 |
| C2 | (P1) A direct v2.0 → latest jump fails: `20240528115149_migrate_site_imports` preloads today's `Plausible.Site` | Staged migrations through the official `ghcr.io/plausible/community-edition` images; must start at **v2.1.1** because v2.1.5's `Site` already has `installation_meta`, `team_id`, `scroll_depth_visible_at` | `upgrade/migrate.sh`, `upgrade/stage-image.yml`, `deployment.md` §3 "Why migrate in stages?" |
| C3 | (P1) Rollback lost `.env`/override, possibly changing the project name | `backup.sh` saves compose, override, env, `.env` and `clickhouse/`; `rollback.sh` restores them exactly, including absence | `upgrade/backup.sh`, `upgrade/rollback.sh` |
| C4 | Rollback with unset `$BACKUP` could delete live volumes | All mutating steps are `set -eu` scripts reading `upgrade.vars` with `:?` guards; rollback aborts unless every archive and the baseline exist, archives the current state to `pre-rollback/` first, and restores volumes **in place** (`find -delete` + untar; keeps Compose labels) | `upgrade/rollback.sh` |
| C5 | Heredoc `sh <<EOF` blocks were broken (`docker compose exec` reads stdin) | Replaced by script files; every `exec` call redirects stdin | `upgrade/*.sh` |
| C6 | A failed volume archive went unnoticed (Docker Hub 429 during the test) | `backup.sh` checks each archive is non-empty and `tar -t` readable, and `pg_restore --list` works | `upgrade/backup.sh` |
| C7 | `data-check.sh` hid query failures; `uniqExact` used too much memory | Every query result is assigned before use (`set -e` catches failures); per site: `count, uniq(user_id), sum(cityHash64(user_id, session_id, timestamp, name, pathname))` | `upgrade/data-check.sh` |
| C8 | Goals dedup (`20230914071245_goals_unique`) made the check fail falsely | Compares `count(DISTINCT site_id, page_path, event_name)` | `upgrade/data-check.sh:37` |
| C9 | Routine backup used an unset `$PROJECT` | Resolved from the container label inside the block | `deployment.md` §6 |
| C10 | `docker compose pull` fails on the buildable image | `pull --ignore-buildable` | `deployment.md` §5.3 |
| C11 | The image build happened during downtime | Built in step 1 while the old app is online (`docker build -t plausible-deviceid:local <git url>`) | `deployment.md` §3 step 1 |
| C12 | `finalize.sh` could delete the backup after data loss | Re-runs `data-check.sh` against the baseline and refuses on any diff; drops leftover tables only if `sessions_v2` is `VersionedCollapsingMergeTree`; asks for confirmation (`--yes` skips it) | `upgrade/finalize.sh:36-46` |
| C13 | `migrate.sh` rerun safety | Progress in `$BACKUP/migrate.done`; finished stages skipped; never starts an older ClickHouse than the data has (start version recorded from the old container's image, or `CLICKHOUSE_START`) | `upgrade/migrate.sh` |
| C14 | Stale v2.0 README defaults; `upgrade/postgres.md` pointer; "migrations never discard" claim; arm64 mail; `plausible.init()` double call; build hosts list | Banner + corrected defaults; pointer to step 4; claim reworded (`custom_domains` dropped, empty imports removed, sources normalised); tested `mail: !reset null` override; edit the existing `init()`; adds `download.db-ip.com` | `README.md`, `deployment.md` |
| C15 | Low-resources / healthchecks / `MAILER_EMAIL` | Same as F2–F4 | `docker-compose.yml`, `clickhouse/*`, `plausible-conf.env` |

`.gitignore` now ignores `/backups/`, `/upgrade.vars` and `/.env`.

## How it was verified (and what wasn't)

**Verified in a sandbox with Docker:**
- **Mock v2.0 install.** Real `postgres:14-alpine` and
  `clickhouse-server:23.3.7.5-alpine` volumes, the v2.0 compose file, the
  v2.0 `events_v2`/`sessions_v2` DDL from `priv/data_migrations/NumericIDs`,
  200k events, 20k sessions with collapsing pairs, imported rows, and goals
  with a duplicate.
- **The full script flow, run as in `deployment.md` §3.**
  - `git checkout deviceid/<ref> -- upgrade/`, then `backup.sh`
    (`BACKUP_DIR`), then the switch (stash/checkout/`.env`).
  - `postgres-16.sh`, then `migrate.sh`, then a second `migrate.sh` (all
    stages skipped).
  - The expected migration effects applied by hand: dedupe a goal, convert
    `sessions_v2` with the exact VersionedSessions SQL, remap `fb`→`Facebook`.
  - `up -d`, then `verify.sh`, which correctly **failed** after deleting 3
    events (diff showed site 5's count and checksum).
  - `rollback.sh`, twice: identical to the baseline; `.env` absence and the
    override restored; `pre-rollback/` written.
  - `finalize.sh`: refused when sessions_v2 wasn't converted, refused when
    the data differed, succeeded otherwise.
- **ClickHouse hops** 23.3→23.8→24.3→24.8→24.12: counts identical. The
  VersionedSessions conversion was reproduced on 23.3, 24.3 and 24.12 with
  identical sums.
- **Postgres 14 → 16** `pg_restore --exit-on-error`: OK (citext case-insensitive
  lookup works). Postgres 16 refuses a v14 volume without modifying it.
- **Split low-resources config on 24.12:** `max_threads=1`,
  `max_block_size=8192`, `mark_cache_size=524288000`.
- **Elixir:** `persistent_id.ex` compiled with stubs and
  `--warnings-as-errors` in CE and EE modes, with no warnings. The collision
  cases give 3 distinct ids in EE. All changed `.ex`/`.exs` files are
  `mix format` clean.
- `docker compose config` is valid for both repos, including the
  `mail: !reset null` + `depends_on: !override` override.

**NOT verified (please weigh these):**
- **`mix test` and `mix compile --warnings-as-errors`:** hex.pm is blocked
  in the sandbox. The new and changed tests
  (`test/plausible/ingestion/persistent_id_test.exs`,
  `test/plausible/ingestion/persistent_tracking_test.exs`) have never run.
- **Real migrations of the official images** (`ghcr.io/plausible/community-edition:v2.1.1 … v3.2.0`)
  and the real fork image. The sandbox can't download ghcr blobs or build
  the image, so `migrate.sh`/`verify.sh` ran against **stub images** that
  answer `db migrate` and the health endpoint. The tags exist (manifests
  resolved).
- Whether each official release runs cleanly with the env file and
  ClickHouse version `migrate.sh` gives it (v2.1.x on CH 24.3, v3.x on 24.12,
  Postgres 14 or 16).
- The interactive `finalize.sh` prompt (reads `/dev/tty`); only `--yes` was
  tested.

## Please scrutinise in particular

1. **`migrate.sh` stage choice.** Is v2.1.1 → v2.1.5 → v3.0.1 → v3.1.0 →
   v3.2.0 → fork safe? Does any stage's data migration load schemas with
   columns that only a later migration creates? Relevant: `20240528115149`
   (site imports), `20250410105143` (backfill teams), `20250520073535`
   (tracker config), `20250807164200` (tracker ids). Can a release's
   `db migrate` run before reaching its own final migration (e.g. does
   v2.1.1's `interweave_migrate` stop at its own last migration)? Are the
   v2.1.x/v3.x env requirements met by the new `plausible-conf.env`?
2. **`migrate.sh` mechanics:**
   - `docker compose -f docker-compose.yml [-f override] -f upgrade/stage-image.yml run --rm plausible db migrate`
     with `STAGE_IMAGE` and `CLICKHOUSE_VERSION` set: could `run` recreate
     dependency containers with a different ClickHouse image?
   - The ClickHouse version detection in `clickhouse-start` parsing, and
     `sort -V` comparisons.
   - What happens if the user's override sets `depends_on` or the image.
3. **Scripts under `set -eu`:** paths with spaces, `BACKUP_DIR` relative
   paths, `find /volume -mindepth 1 -delete` safety, `rm -rf "$BACKUP"` in
   `finalize.sh`, `docker compose stop` vs `down` (does `down` in
   `rollback.sh` remove anything besides containers and networks?).
4. **`data-check.sh` stability.** Do any migrations between v2.0 and the
   fork legitimately change `users`, `sites`, `shared_links`, `api_keys`
   counts, per-site `count()`, `uniq(user_id)` or the checksum columns
   (`user_id, session_id, timestamp, name, pathname`) of pre-cutoff events?
   That would make `verify.sh`/`finalize.sh` fail falsely. Does `uniq()`
   return the same value for the same data across ClickHouse 23.3 and 24.12?
   It was identical in the test, but confirm it isn't version-dependent.
5. **`persistent_id.ex`.** Encoding correctness, EE `replay_session_id`
   clauses (nil vs integer), any compile or typing warnings, and test
   expectations in `persistent_id_test.exs:107`.
6. Any remaining contradictions between `deployment.md`, `README.md`,
   `deploy/README.md` and the code.

## Commands worth running (where tools exist)

```sh
# fork (needs hex.pm, Postgres, ClickHouse)
mix compile --warnings-as-errors
mix test test/plausible/ingestion/persistent_id_test.exs test/plausible/ingestion/persistent_tracking_test.exs
mix format --check-formatted

# community-edition
for f in upgrade/*.sh; do sh -n "$f"; done
shellcheck -s sh upgrade/*.sh
docker compose config -q
```

## Output wanted

Findings ranked most severe first, each with: severity (P0–P3),
`repo:file:line`, what's wrong, evidence (quoted code or a reproduction),
and a suggested fix. List explicitly which items above you checked and
found correct.
