# Unique visitors and persistent tracking

This fork can recognise returning visitors across days. Upstream Plausible
resets every visitor id at midnight, so someone who visits on 7 days counts
as 7 visitors in a weekly report. With persistent tracking that person counts
once, and the dashboard gains **Daily / Weekly / Monthly active users**.

It is **off by default**. With `ENABLE_PERSISTENT_TRACKING=false` the app
behaves exactly like upstream Plausible.

Contents:
1. [How visitors are identified](#1-how-visitors-are-identified)
2. [Turning it on](#2-turning-it-on)
3. [Turning it off (and on again)](#3-turning-it-off-and-on-again)
4. [Sending a device id: apps and websites](#4-sending-a-device-id-apps-and-websites)
5. [The reports](#5-the-reports)
6. [Settings reference](#6-settings-reference)
7. [Privacy](#7-privacy)
8. [FAQ](#8-faq)

---

## 1. How visitors are identified

Every event gets a visitor id (`user_id`). Which one depends on the setting
and on the event:

| `ENABLE_PERSISTENT_TRACKING` | The event… | Visitor id is built from | Stays the same… | Changes when… |
| --- | --- | --- | --- | --- |
| `false` (default) | any | site + IP + browser + a **salt that rotates daily** | for one day | every midnight (upstream behaviour) |
| `true` | **has a `deviceId` property** | site + `deviceId` (+ your secret) | forever: across days, networks, IP changes, app updates | the app is reinstalled or its storage cleared |
| `true` | **has no `deviceId`** | site + IP + browser user agent + your secret | across days, while IP and browser stay the same | the visitor changes network (home ↔ office ↔ mobile), updates the browser, or uses another device |

Key points:

* **`deviceId` is optional.** Events without it automatically use IP +
  browser. Websites need no changes to benefit.
* **Nothing generates a `deviceId` automatically.** The server only sees IP
  and browser. A device id has to come from the client: an app's install
  id, or a random id a web page keeps in `localStorage`
  ([section 4](#4-sending-a-device-id-apps-and-websites)).
* **Send it on every event, including the first pageview.** If one person's
  events sometimes have `deviceId` and sometimes don't, they get two ids and
  count twice. The tracker's `customProperties` option adds it to every
  event.
* **Ids are per site.** The same person on two sites (say your website and
  your app) never gets the same id.
* **The IP + browser method is approximate.**
  - People behind one shared IP with an identical browser version (an
    office, a school) can merge into one visitor.
  - A phone that changes IP splits into several visitors.
  - `deviceId` is exact.
* **Old data isn't rewritten.** Events recorded while tracking was off keep
  their daily ids. Only new events use persistent ids.
* The ids are a 64-bit hash, stored in the same ClickHouse column as
  before. No schema change, and the secret can't be recovered from the
  ids.

---

## 2. Turning it on

Run this in your install directory (where `docker-compose.yml` is):

```sh
# 1. a secret, set once (merge-config.sh may already have generated one)
grep '^PERSISTENT_SALT_SECRET=' plausible-conf.env
#    if it's missing or "replace-me":
sed -i "s|^PERSISTENT_SALT_SECRET=.*|PERSISTENT_SALT_SECRET=$(openssl rand -base64 48 | tr -d '\n')|" plausible-conf.env
grep -q '^PERSISTENT_SALT_SECRET=' plausible-conf.env || \
  echo "PERSISTENT_SALT_SECRET=$(openssl rand -base64 48 | tr -d '\n')" >> plausible-conf.env

# 2. keep a copy of the config OFF the server (the secret must never change)
cp plausible-conf.env /root/plausible-conf.env.backup

# 3. switch it on and recreate the app container
sed -i 's/^ENABLE_PERSISTENT_TRACKING=.*/ENABLE_PERSISTENT_TRACKING=true/' plausible-conf.env
grep -q '^ENABLE_PERSISTENT_TRACKING=' plausible-conf.env || echo 'ENABLE_PERSISTENT_TRACKING=true' >> plausible-conf.env
docker compose up -d plausible

# 4. check
sleep 40
curl -s http://127.0.0.1:8000/api/health; echo
docker compose exec plausible printenv ENABLE_PERSISTENT_TRACKING   # true
docker compose exec plausible_db psql -U postgres -d plausible_db \
  -c "SELECT id, started_at, ended_at FROM persistent_tracking_periods"
```

Expect `true`, and a row whose `started_at` is the time of the restart
(UTC) with an empty `ended_at`. Builds from `plausible-kurdin` after
2026-10-05 also log
`[notice] Persistent tracking enabled, recording period start at …`
(`docker compose logs plausible | grep 'Persistent tracking'`). Older
builds log it at `info` level, which the default `LOG_LEVEL=notice` hides.

* The app **refuses to start** if the flag is on and `PERSISTENT_SALT_SECRET`
  is missing or shorter than 16 bytes. `docker compose logs plausible`
  shows why.
* **Never change `PERSISTENT_SALT_SECRET` afterwards.** A new secret gives
  every visitor a new id, so everyone looks new from that moment.
* Visits in progress at the moment of the switch start a new visit, because
  the id changes mid-visit. That is a one-time, minor bump in visits for
  that day.

### Verify it works

1. Send two events with the same `deviceId` from different IPs and
   browsers. Use one of your site domains. These are real test events, so
   use a test site if you don't want them in your stats.
   ```sh
   SITE=your-site.com
   for ip in 81.2.69.160 89.160.20.112; do
     curl -s -X POST http://127.0.0.1:8000/api/event -H 'Content-Type: application/json' \
       -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36 $ip" \
       -H "X-Forwarded-For: $ip" \
       -d "{\"name\":\"pageview\",\"url\":\"https://$SITE/persistent-test\",\"domain\":\"$SITE\",\"props\":{\"deviceId\":\"test-device-1\"}}"; echo
   done
   ```
2. After a few seconds, both events should share **one** `user_id`:
   ```sh
   docker compose exec plausible_events_db clickhouse-client -q \
     "SELECT user_id, count() FROM plausible_events_db.events_v2 WHERE pathname = '/persistent-test' GROUP BY user_id"
   ```
3. Reload the dashboard. The **Daily / Weekly / Monthly active users** tiles
   now appear.

---

## 3. Turning it off (and on again)

```sh
sed -i 's/^ENABLE_PERSISTENT_TRACKING=.*/ENABLE_PERSISTENT_TRACKING=false/' plausible-conf.env
docker compose up -d plausible
sleep 40
docker compose exec plausible_db psql -U postgres -d plausible_db \
  -c "SELECT id, started_at, ended_at FROM persistent_tracking_periods"   # the open row now has an ended_at
```

What happens:

* **New events** get upstream's daily-rotating ids again. **Recorded data
  is not changed**, so multi-day counts for the period when tracking was on
  stay deduplicated.
* The **active-users tiles disappear** from the dashboard. The Stats API
  still answers `dau`/`wau`/`mau`, with a `persistent_tracking_partial`
  warning for windows that include days without tracking.
* **Keep `PERSISTENT_SALT_SECRET` in the config.** If you turn tracking on
  again later with the same secret, returning visitors get the same ids as
  before. The gap shows as `*` warnings on windows that include it.
* The app records every on/off switch at startup, in the Postgres table
  `persistent_tracking_periods`. That's how it knows which days have
  reliable ids. Nothing else needs to be done.

If you enabled tracking before the app recorded these periods (installs
from before this feature), set `PERSISTENT_TRACKING_SINCE=YYYY-MM-DD` once.

---

## 4. Sending a device id: apps and websites

### Apps (desktop or mobile)

Generate a random id **once**, for example a UUID on first launch. Store it
in the app's settings, and send it as the `deviceId` property **on every
event**. Don't use hardware serial numbers, emails or account ids.

Which code depends on how your app sends events:

**New Plausible snippet.** Copy it from *Site settings → Site installation*;
it calls `plausible.init(...)`. Add `customProperties` to that call. Don't
call `init` a second time.

```js
plausible.init({
  // ...the options already in your snippet...
  customProperties: { deviceId: getAppInstallId() }
})
```

**npm package `@plausible-analytics/tracker`.** `domain` is required.
Without `endpoint`, events go to plausible.io:

```js
import { init } from '@plausible-analytics/tracker'

init({
  domain: 'app.example.com',                            // as in your site settings
  endpoint: 'https://stats.example.com/api/event',      // your instance
  customProperties: { deviceId: getAppInstallId() }
})
```

**Direct HTTP calls** (native apps, servers): add the property to every
event body. Send a real `User-Agent` header too, so browser and OS reports
work.

```sh
curl -X POST https://stats.example.com/api/event \
  -H 'Content-Type: application/json' -H 'User-Agent: MyApp/1.2 (Windows NT 10.0)' \
  -d '{"name":"pageview","url":"app://myapp/history","domain":"app.example.com","props":{"deviceId":"<install id>"}}'
```

**Old snippet** (`<script defer data-domain="…" src="…/js/script.js">`):
it can't attach a property to every event. Switch to the new snippet from
Site settings.

### Websites

You don't need to change anything: without `deviceId`, visitors are
identified by IP + browser, stable across days.

For better accuracy you can keep a random id in the browser. Read
[section 7](#7-privacy) first.

```js
function getOrCreateDeviceId() {
  try {
    let id = localStorage.getItem('deviceId')
    if (!id) {
      id = crypto.randomUUID()
      localStorage.setItem('deviceId', id)
    }
    return id
  } catch (e) {
    return undefined   // storage blocked: falls back to IP + browser
  }
}

plausible.init({
  // ...the options already in your snippet...
  customProperties: { deviceId: getOrCreateDeviceId() }
})
```

### Using a different property name

If your clients already send an id under another name, for example
`installId`, point the server at it instead of changing the clients:

```env
PERSISTENT_TRACKING_DEVICE_ID_PROP=installId
```

Then run `docker compose up -d plausible`.

### Hiding `deviceId` from the Properties report

`deviceId` is stored like any custom property and counts towards the
30-property limit per event. While no list is configured in *Site settings →
Custom properties*, the Properties report shows every property, `deviceId`
included. Once you configure that list, only the listed properties are
shown: leave `deviceId` off it. The visitor id is computed from the raw
event, so this doesn't affect tracking.

---

## 5. The reports

### Unique visitors, deduplicated across days

There's no new tile here. "Unique visitors" for any multi-day range ("Last
7 days", "This month", ...) now counts each person once, for data recorded
with tracking on. Daily charts still show each day's own unique visitors.
Imported data (Google Analytics, CSV) has no visitor ids, so it's still
summed per day, as upstream does.

### Daily / Weekly / Monthly active users (DAU / WAU / MAU)

Three tiles in the dashboard's top row. They're shown only while tracking
is on, and not in the realtime view.

| Tile | Definition |
| --- | --- |
| **Daily active users** | unique users on the day |
| **Weekly active users** | unique users in the 7 days ending on the day (rolling) |
| **Monthly active users** | unique users in the 30 days ending on the day (rolling) |

* **The tile value** is the one on the **last day of the selected period**,
  or today if the period runs past today, as in "This month".
* **Click a tile** to graph it by **day, week or month**. A weekly or
  monthly point is the value on the bucket's last day. Hourly and
  per-minute graphs aren't available for these metrics.
* **Windows reach back before the selected period.** The MAU of 1 March
  includes visitors from February.
* **A `*`** means a window includes days without persistent tracking,
  before you turned it on or while it was off. Those days count returning
  visitors once per day, so the value is overestimated. MAU loses the `*`
  30 days after you switch on. When comparing periods, the tooltip says if
  only the comparison period is affected.
* **Accuracy:** values are approximate (ClickHouse `uniq`, typically within
  1–2%), the same as "Unique visitors". Imported data is not included.

### Stats API v2

The same numbers are available as the metrics `dau`, `wau` and `mau`. A
query can contain only these metrics, with no dimension or one of
`time:day`, `time:week`, `time:month`.

```sh
# tiles: value for the last day of the last 30 days
curl -sS https://stats.example.com/api/v2/query -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"site_id":"app.example.com","metrics":["dau","wau","mau"],"date_range":"30d"}'

# a daily MAU series
curl -sS https://stats.example.com/api/v2/query -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"site_id":"app.example.com","metrics":["mau"],"date_range":"90d","dimensions":["time:day"]}'
```

A partial window comes back in `meta.metric_warnings`:

```json
{"mau": {"code": "persistent_tracking_partial", "scope": "period",
         "message": "Part of this period was tracked without persistent tracking (enabled on 2026-10-05). ..."}}
```

`scope` is `"comparison"` when only the comparison period is affected.

---

## 6. Settings reference

All of these go in `plausible-conf.env`. Apply changes with
`docker compose up -d plausible`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ENABLE_PERSISTENT_TRACKING` | `false` | `true` turns persistent visitor ids on |
| `PERSISTENT_SALT_SECRET` | none | Required when on. At least 16 bytes (`openssl rand -base64 48`). **Never change it** |
| `PERSISTENT_TRACKING_DEVICE_ID_PROP` | `deviceId` | Name of the custom property that carries the device id |
| `PERSISTENT_TRACKING_SINCE` | none | `YYYY-MM-DD`: when tracking was first enabled, for installs from before periods were recorded. Leave unset otherwise |

---

## 7. Privacy

Upstream Plausible deliberately rotates ids daily, so visitors can't be
followed across days. Persistent tracking changes that:

* A `deviceId` kept in `localStorage`, a cookie or an app's storage is an
  identifier stored on the user's device. In the EU, ePrivacy rules
  generally require consent for that on websites. App ids are usually
  covered by the app's own terms and privacy policy.
* The IP + browser method stores nothing on the device. It is still a
  persistent pseudonymous identifier (a fingerprint), and GDPR applies to
  it.

Update your privacy policy accordingly, and check your own obligations. A
common pattern: apps send their install id; websites send nothing, or a
`deviceId` only after consent.

---

## 8. FAQ

**Is `deviceId` required?**
No. Without it, visitors are identified by IP + browser, which is stable
across days but not across networks or devices.

**Will the tracker create a device id automatically?**
No. The tracker and the server never create or store one. Your app (or
your page script) provides it.

**What if some events have `deviceId` and others don't?**
They get different ids, so the same person can count twice. Send it on
every event, using `customProperties` in `init`.

**Can the same person be linked between my website and my app?**
No. Ids are per site, even with the same `deviceId`.

**Does turning it on change old numbers?**
No. Old events keep their daily ids. Only data recorded from then on is
deduplicated across days. DAU/WAU/MAU windows that reach back into the old
data are marked `*`.

**Can I turn it off and on again?**
Yes ([section 3](#3-turning-it-off-and-on-again)). Keep the same
`PERSISTENT_SALT_SECRET`, and returning visitors get their old ids back.

**I lost `PERSISTENT_SALT_SECRET`.**
Set a new one. Visitors get new ids from that moment, so multi-day counts
across the change count them twice, and DAU/WAU/MAU are briefly inflated.
Recorded data is unaffected.
