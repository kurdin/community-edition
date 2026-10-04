# Combined review handoff: persistent tracking, lossless upgrade, DAU/WAU/MAU

This is a single, self-contained handoff for everything built so far, plus all
review findings and their fixes (rounds 1–7). You're reviewing the final
state. **Report findings only; don't change files.**

## 1. Repositories, branch, commits

Both repos are on branch **`claude/determined-cerf-dqrxgj`**, pushed to GitHub.

```sh
git fetch origin claude/determined-cerf-dqrxgj && git checkout claude/determined-cerf-dqrxgj
```

### `kurdin/plausible-analytics-deviceId` (Elixir app fork; base `d21298d` = upstream master)

| Commit | Content |
| --- | --- |
| `cc34b04` | A. Persistent tracking (deviceId / persistent salt), fork compose + deploy docs |
| `b265b74` | Link to `deployment.md` |
| `534f84c` | Round 2/3 fixes: EE id collision (length-prefixed hashing), config/doc fixes |
| `66d99ba` | C. DAU/WAU/MAU metrics, persistent tracking periods, dashboard tiles |
| `b26b074` | Round 5 fixes for DAU/WAU/MAU (render loop, reported days, warnings, periods) |
| `712bd27` | Round 6 doc fixes (npm tracker example, arm64 override) |
| `3a8c83b` | Round 7: coverage per reported window and for the comparison period; `SINCE` seed persisted at boot |

Whole feature: `git diff d21298d..3a8c83b`. By area: `git diff d21298d..534f84c` (A),
`git diff 534f84c..3a8c83b` (C and later fixes). Round 7 only: `git diff 712bd27..3a8c83b`.

### `kurdin/community-edition` (Docker deployment; base `06f122f` = upstream v2.0)

| Commit | Content |
| --- | --- |
| `fc2135b` | Compose builds the fork; env, ClickHouse configs, README |
| `337c5a3` | `deployment.md` (install / upgrade / rollback) + `upgrade/data-check.sh` |
| `f97402e`, `d98e1cf` | Round 2 fixes; data-changing steps moved into self-checking scripts |
| `59efeb5`, `5a33bc4` | B. Script flow `backup → migrate (staged) → verify → finalize/rollback` |
| `a4f7aeb` | Default `PLAUSIBLE_SRC` = feature branch |
| `c6f45ef`…`d5cbc53` | Handoffs; DAU/WAU/MAU docs |
| `967c4b0` | Round 6 fixes (v2.1.0 stage, rollback archives, cutoff for Postgres counts, quoting, Compose minimum) |
| HEAD | Round 7 fixes (TOTP key for v2.1.0/v2.1.1, `sessions_v2` pre-conversion, baseline with cutoff) + this file |

Whole feature: `git diff 06f122f..HEAD`. Round 7 only: `git diff 967c4b0..HEAD`.

## 2. What was built

### A. Opt-in persistent visitor ids (fork)
- **Flag:** `ENABLE_PERSISTENT_TRACKING` (default `false`). When off, the upstream
  daily-salt code path is unchanged.
- **Config:** `config/runtime.exs`, `config/config.exs`.
  - `PERSISTENT_SALT_SECRET` is required when enabled, at least 16 bytes;
    boot fails otherwise.
  - `PERSISTENT_TRACKING_DEVICE_ID_PROP` defaults to `deviceId`.
- **Ids** (`lib/plausible/ingestion/persistent_id.ex`, wired in
  `lib/plausible/ingestion/event.ex` `put_user_id/2`, `register_session/2`):
  - Tier 1: `SipHash(key, encode(["device", site_id, device_id]))`.
  - Tier 2: `SipHash(key, encode(["fp", site_id, ua, ip]))`.
  - EE adds `replay_session_id` as an extra field.
  - `encode/1` length-prefixes every field.
  - `key = sha256(secret)[0..16]`.
  - `user_id` stays a UInt64; the schema is unchanged.
- **Prop kept:** `deviceId` is deliberately kept as a normal custom prop
  (owner decision).
- **Queries:** no stats query changes. `visitors` is already
  `uniq(user_id)` over the range.
- **Tests:** `test/plausible/ingestion/persistent_id_test.exs`,
  `persistent_tracking_test.exs`.

### B. Deployment and lossless upgrade (community-edition; fork mirrors compose)
- **`docker-compose.yml`:**
  - builds the fork via `PLAUSIBLE_SRC` (default: the feature branch);
  - Postgres `${POSTGRES_VERSION:-16}`, ClickHouse `${CLICKHOUSE_VERSION:-24.12}`;
  - TCP `pg_isready` healthcheck; generous ClickHouse healthcheck;
  - `CLICKHOUSE_SKIP_USER_SETUP=1`;
  - `plausible-data` volume;
  - optional low-resources config split between `config.d` and `users.d`.
- **`deployment.md`:** install, the upgrade from v2.0, rollback, updates,
  backups, troubleshooting, configuration.
- **Upgrade scripts** (`upgrade/`). Each one is `set -eu`, verifies its own
  output and ends with an explicit OK line.
  - `backup.sh`:
    - writes the config files, `pg_dump -Fc`, cold volume tars and a
      baseline (`before.txt`, counted with the cutoff in `cutoff.txt`, like
      every later check) into `./backups/<ts>` (`BACKUP_DIR` overrides);
    - writes `upgrade.vars`.
  - `postgres-16.sh`: optional 14 → 16 dump/restore. It keeps a
    `<project>_db-data-pg14` volume copy.
  - `migrate.sh`:
    - ClickHouse 23.8 → 24.3, then its own `sessions_v2` →
      `VersionedCollapsingMergeTree` conversion (`convert_sessions_v2`, the
      upstream SQL with the EXCHANGE → two-renames fallback for error 48,
      resumable between the renames), then the official images **v2.1.0 →
      v2.1.1 → v2.1.5**;
    - v2.1.0/v2.1.1 get a throwaway `TOTP_VAULT_KEY` (`-e`, only those two
      stages, only if `plausible-conf.env` has none). Config is not changed;
      the fork derives its key from `SECRET_KEY_BASE` when unset;
    - ClickHouse 24.8 → 24.12, then **v3.0.1 → v3.1.0 → v3.2.0**, then the
      fork;
    - checks counts (before the cutoff) after each stage, can be resumed
      (`$BACKUP/migrate.done`), never downgrades ClickHouse;
    - runs stage images through `upgrade/stage-image.yml`.
  - `verify.sh`: readiness check plus `data-check.sh` diffed against the
    baseline.
  - `rollback.sh`: archives the current state to a new
    `pre-rollback-<ts>/`, restores the volumes in place and the config files
    exactly, starts only the databases, then diffs the data.
  - `finalize.sh`:
    - re-checks the data first (`--ignore-data-check` for expected
      differences);
    - checks `sessions_v2` was converted;
    - deletes the backup and the leftovers (`sessions_v2_tmp_versioned`,
      `sessions_v2_backup*`);
    - confirms first (`--yes` skips the prompt).
  - `data-check.sh`:
    - Postgres counts (users, sites, shared links, api keys, distinct
      goals), counting only rows with `inserted_at < cutoff`;
    - event and session counts, and per-site
      `count, uniq(user_id), sum(cityHash64(...))` before the cutoff;
    - imported rows.

### C. DAU / WAU / MAU (fork)
- **Definitions:**
  - `dau` = unique users on day D; `wau` = the 7 days ending on D; `mau` =
    the 30 days ending on D;
  - approximate `uniq`.
  - Values reported: the last day (or today) with no dimension; each
    bucket's last day for `time:week|month`; every day for `time:day`.
- **SQL** (`lib/plausible/stats/sql/active_users.ex`):
  - `reported_days/2` lists the days to compute.
  - Per-day `uniqState(user_id)` comes from the regular
    `SQL.QueryBuilder` on a derived query: internal metric
    `:user_id_state`, `time:day`, range starting 29 days before the first
    reported day, imports off, `:no_sampling`.
  - Then `ARRAY JOIN range(0, 30)` with `uniqMergeIf` per window, limited to
    the reported days.
  - Bucketing uses `argMax`.
- **Routing:** `SQL.QueryBuilder.build/2` sends queries with only
  active-user metrics straight here.
- **Validation** (`lib/plausible/stats/query_builder.ex`):
  - only these metrics in a query;
  - at most one dimension, from `time:day|week|month` (generic `time`
    rejected);
  - no realtime.
- **Imports:** `Imported.schema_supports_query?` returns false, which gives
  `unsupported_query`.
- **Accuracy warning:**
  - New table `persistent_tracking_periods` (migrations `20261005090000`,
    `20261005090001`, the latter a unique partial index allowing one open
    period).
  - `Plausible.Ingestion.PersistentId.Periods`:
    - `record_boot/1` runs as a Task in `application.ex` (disabled in the
      test config);
    - `coverage/3`;
    - `PERSISTENT_TRACKING_SINCE` seeds earlier installs. On the first boot
      with an empty table it's stored as a real period (open if enabled,
      ended at that boot if disabled); with recorded rows that start later,
      `list/0` adds it as a synthetic period ending at the first one. An
      empty value counts as unset.
  - `QueryBuilder.set_active_users_coverage/1` (runs after
    `put_comparison_utc_time_range/1`) checks each window from
    `ActiveUsers.reported_windows/2` (one per reported day, merged when they
    overlap or touch), clamped to the native stats start and `now`, for the
    main range and, if compared, the comparison range.
  - `QueryResult.metric_warning/2` emits `persistent_tracking_partial` with
    `scope: :period | :comparison`.
- **Dashboard:**
  - `data-persistent-tracking` → `site-context.tsx`;
  - `fetch-top-stats.ts` makes a separate `active-users` request and merges
    it via `mergeActiveUsersData`, memoized on the stable `data`
    references; placeholder data and mismatched comparisons aren't merged;
  - `isGraphableMetric` (day/week/month only);
  - `visitor-graph.tsx` graphs visitors on hour/minute and keeps the stored
    selection while active users load;
  - labels, formatters, and the `*` warning text (separate text for
    `scope: comparison`).
- **Tests:**
  - `test/plausible/stats/query/query_active_users_test.exs`
  - `test/plausible_web/controllers/api/external_stats_controller/query_active_users_test.exs`
  - `test/plausible/ingestion/persistent_id/periods_test.exs`
  - `assets/js/dashboard/stats/graph/fetch-top-stats-active-users.test.tsx`

## 3. All review findings and fixes

| Round | Finding | Fix (where) |
| --- | --- | --- |
| 1 | Rollback could delete live volumes with an unset `$BACKUP` | Scripts with `upgrade.vars` + `:?` guards; rollback aborts unless all archives exist (`upgrade/rollback.sh`) |
| 1 | README quick start built `master` without the feature | `PLAUSIBLE_SRC` default/README use the feature branch |
| 1 | `low-resources.xml` profile ignored in `config.d` | Split into `config.d` + `users.d` files (both repos) |
| 1 | `pull` fails on the buildable image | `pull --ignore-buildable` |
| 1 | Rollback diff broken by new traffic; `.env` not backed up | Cutoff used; `.env`/override backed up and restored |
| 1 | bytemark/smtp amd64-only; `MAILER_EMAIL` forced to example.com | Documented; `MAILER_EMAIL` optional |
| 1 | Healthcheck timing; `data-check` memory/failure handling | 10s interval, CH retries 60, TCP pg check; `uniq` + checksum; assign-then-use |
| 1 | Build during downtime; stale README defaults; "never discard" claim | Build in step 1; banner + defaults fixed; claim reworded |
| 2 | Heredoc blocks consumed by `docker compose exec` stdin; failed archive unnoticed | Real script files; stdin redirected; archives verified |
| 3 | P1 default build lacked the feature | Feature-branch default |
| 3 | P1 direct v2.0 → latest jump fails (site imports preload `Site`) | Staged official-release migrations (`upgrade/migrate.sh`) |
| 3 | P1 rollback must restore `.env`/override, including absence | `backup.sh` / `rollback.sh` |
| 3 | EE: `device-1`+`23` = `device-12`+`3` = `device-123` | Length-prefixed fields (`persistent_id.ex`) + test |
| 3 | Fork docs: volume reuse needs `COMPOSE_PROJECT_NAME` | Documented |
| 3 | Routine backup used an unset `PROJECT`; data-check hid failures | Resolved inline; fixed |
| 3 | Goals dedup migration made the check fail | Distinct goals |
| 5 | **Blocker:** dashboard endless re-render | Memoize on `data` refs; render test fails on the old code (71 updates) |
| 5 | Tiles scanned the whole range with a 30× fan-out | Reported days only |
| 5 | Warning too broad; no native-start clamp; comparison unchecked | Anchored on reported days; clamped (comparisons inherit the main query's coverage) |
| 5 | `SINCE` hid later gaps; an empty `SINCE` crashed boot | Ends at first recorded period; `""` = unset |
| 5 | Placeholder merge; lost graph selection; 400 on hourly | Fixed in `fetch-top-stats.ts` / `visitor-graph.tsx` |
| 5 | `record_boot` race / partial close; two time dims gave a 500 | `update_all`, unique open index, `on_conflict: :nothing`; validation |
| 5 | Docs: generic `time` unsupported; "or today" | Documented (schema, READMEs) |
| 6 | **P1** v2.1.1 runs Postgres before ClickHouse (interleaving arrived in v2.1.2); site imports need `import_id`/`imported_custom_events` | **v2.1.0 stage first** (`migrate.sh`, `deployment.md`) |
| 6 | Rollback retries overwrote the recovery archives | New `pre-rollback-<ts>/` per attempt |
| 6 | New users/sites after the upgrade blocked finalize | Postgres counts `inserted_at < cutoff`; `--ignore-data-check` |
| 6 | Paths with spaces broke `migrate.sh` | Quoted `stage_compose()` |
| 6 | npm tracker example unusable (`domain` required, `endpoint` defaults to plausible.io) | Separate npm example with `import { init }`, domain, endpoint (fork `deploy/README.md`) |
| 6 | arm64 note left `depends_on: mail` | Full override documented (both repos) |
| 6 | Compose minimum too low for `!override` | Docker Compose v2.24.4+ |
| 7 | **P1** v2.1.0/v2.1.1 refuse to boot without `TOTP_VAULT_KEY` | Throwaway key passed with `-e` to those two stages only, when the config has none (`migrate.sh`, `deployment.md`) |
| 7 | **P1** v2.1.0's `sessions_v2` conversion only handles EXCHANGE error 1, crashes on 48 (plausible/analytics#4167) | `convert_sessions_v2` before v2.1.0: upstream SQL, row check, EXCHANGE or two renames (backup name suffixed if taken), resumes an interrupted swap; v2.1.0 then sees it versioned and skips (`migrate.sh`, `finalize.sh`) |
| 7 | Baseline counted without the cutoff, later checks with it | `backup.sh` passes `cutoff.txt`; `migrate.sh` `check_counts` filters by it |
| 7 | `SINCE` seed stayed open forever after a disabled first boot | Stored as a real period at boot (`periods.ex`) + tests |
| 7 | Comparison period coverage ignored | Checked too; `scope: :comparison` warning (`query_builder.ex`, `query_result.ex`, `top-stats.js`) + test |
| 7 | Coverage used the interval spanning all reported windows | Per window via `ActiveUsers.reported_windows/2` + test |

## 4. Verification

**Done in the sandbox:**
- **Rolling SQL:** compared with brute-force `uniqExact` windows on
  ClickHouse 24.12. All 34 days matched exactly, including days without
  events.
- **The real `ActiveUsers` Ecto code**, run in a harness with ecto 3.14.2 +
  ecto_ch 0.11.1 (the `mix.lock` versions) on ClickHouse 24.12:
  - covers `reported_days`, `rolling_query`, `bucket` and `select_metrics`;
  - reproduces every value in `query_active_users_test.exs` (day, none,
    single, week, month, filtered, empty);
  - also a 6-week `time:week` range and a 2-month `time:month` range.
- **`Periods`:** compiles with no warnings; coverage cases pass.
- **Round 7 harness** (35 checks, all pass), with postgrex 0.22.4 (the
  `mix.lock` version) against real Postgres 16:
  - the real `periods.ex`: `record_boot/1` seed on enabled and disabled first
    boots, no re-seed, a future `SINCE`, existing rows, then `list/0`;
  - `reported_windows/2` and `set_active_users_coverage/1`, copied verbatim
    from the sources by a script (only `Query.date_range`, `DateTimeRange.new!`
    and `get_comparison_query` stubbed, UTC): merging, gaps between windows,
    comparison scope and `since`, native-start clamp.
- **Elixir formatting:** clean, with Ecto's `locals_without_parens`.
- **Frontend:**
  - `tsc`, eslint, prettier, Jest 35 suites / 527 tests;
  - the render-loop test fails on the old code and passes now.
- **Upgrade rehearsals** on a v2.0-shaped dataset (real `postgres:14` +
  `clickhouse 23.3.7.5` volumes):
  - ClickHouse hops 23.3 → 24.12 with identical counts;
  - the `sessions_v2` engine conversion on 23.3, 24.3 and 24.12;
  - the Postgres 14 → 16 restore.
- **The full script flow, in a directory whose name contains spaces:**
  - backup → postgres-16 → migrate (with stub release images, incl. v2.1.0)
    → rerun → verify;
  - post-upgrade users, sites and goals don't block `verify`/`finalize`;
  - two rollbacks, with two `pre-rollback-*` dirs and the first copy
    unchanged;
  - `finalize` refuses after deleting pre-upgrade events, and
    `--ignore-data-check` overrides.
- **Round 7 rehearsals** (fresh v2.0-shaped data, path with spaces, stub
  release images that fail like v2.1.0/v2.1.1 without a 32-byte key, plus
  one event and one session timestamped 2099):
  - baseline excludes the 2099 rows; every stage's count check matched;
  - EXCHANGE path; the old table is dropped by `finalize`;
  - forced EXCHANGE failure: rename fallback with a pre-existing
    `sessions_v2_backup` (suffixed name used), interrupted between the
    renames, rerun finished the swap, `finalize` dropped both leftovers;
  - the throwaway key reached only v2.1.0/v2.1.1; an existing key in
    `plausible-conf.env` was used as is.
- `docker compose config` passes for both repos, including the arm64
  override.

**Not verified (weigh these):**
- **`mix test` / `mix compile --warnings-as-errors`** for the fork. hex.pm
  is blocked in the sandbox, so none of the ExUnit files have run:
  `persistent_id_test`, `persistent_tracking_test`,
  `query_active_users_test`, the API test, `periods_test`.
- **Real official release images** (`ghcr.io/plausible/community-edition:v2.1.0…v3.2.0`)
  and the real fork image. The image blobs couldn't be downloaded and the
  fork couldn't be built, so stand-in images replaced them in the
  rehearsal.
- The new migrations against a real Postgres via `mix ecto.migrate`.
- `finalize.sh`'s interactive prompt (only `--yes` was tested).
- The real v2.1.0 image skipping its conversion on an already versioned
  table (read from its source: it checks the engine first and prints
  "already versioned, no migration needed").
- A real ClickHouse returning error 48 on EXCHANGE (forced with a different
  failing EXCHANGE instead).

## 5. Please scrutinise

1. **Staged migrations.** Is v2.1.0 → v2.1.1 → v2.1.5 → v3.0.1 → v3.1.0 →
   v3.2.0 → fork safe? Check for any stage whose Postgres data migrations
   need ClickHouse migrations or schema columns that aren't there yet.
   - Relevant: `20240528115149` (site imports), `20250410105143` (backfill
     teams), `20250520073535` (tracker config), `20250807164200` (tracker
     ids).
   - Do v2.1.x/v3.x accept the new `plausible-conf.env`?
2. **`ActiveUsers` through the real query pipeline:**
   - `per_day_states_query` via `SQL.QueryBuilder`, `QueryOptimizer` and
     `QueryRunner`;
   - comparisons;
   - `time_labels` / `empty_metrics` for the dashboard graph;
   - the `has(?, ? + ?)` reported-days filter with `type(^days, {:array,
     :date})`.
3. **Warning semantics:** per reported window, clamped to the native stats
   start and `now`; comparison windows checked too (`scope`), `since` from
   the main range unless only the comparison is uncovered. `SINCE` seeding
   at boot: concurrent first boots (disabled) could insert two identical
   closed rows; is that harmless?
4. **`convert_sessions_v2` vs upstream `VersionedSessions`:** same DDL
   (`AS sessions_v2`, engine, keys, `SAMPLE BY`, extracted `SETTINGS`), `ATTACH
   PARTITION ID` vs upstream's `ATTACH PARTITION '<partition>'`, the
   fallback, and the resume path. The throwaway TOTP key: is any data
   encrypted with it by v2.1.0/v2.1.1 migrations?
5. **Frontend merge:** `useTopStatsQuery` / `mergeActiveUsersData`, and the
   `visitor-graph.tsx` fallback and `graphMetric`.
6. **Scripts:** `set -eu` edge cases, quoting, `find -delete` in-place
   restores, `data-check.sh`'s `inserted_at < cutoff` on all five tables,
   `finalize.sh` options.
7. **Docs vs. code:** `deployment.md`, `README.md`, the fork's
   `deploy/README.md`, the JSON schema descriptions.

## 6. Commands

```sh
# fork (needs hex.pm, Postgres, ClickHouse)
mix compile --warnings-as-errors
mix format --check-formatted
mix test test/plausible/ingestion/persistent_id_test.exs \
         test/plausible/ingestion/persistent_tracking_test.exs \
         test/plausible/ingestion/persistent_id/periods_test.exs \
         test/plausible/stats/query/query_active_users_test.exs \
         test/plausible_web/controllers/api/external_stats_controller/query_active_users_test.exs
npm --prefix assets ci && npm --prefix assets run typecheck && npm --prefix assets test

# community-edition
for f in upgrade/*.sh; do sh -n "$f"; done
shellcheck -s sh upgrade/*.sh
docker compose config -q
```

## 7. Output wanted

Findings, most severe first. Each one needs:
- severity (P0–P3);
- `repo:file:line`;
- what's wrong;
- evidence (quoted code or a reproduction);
- a suggested fix.

Also list the items above you checked and found correct.
