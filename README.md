# Roamfree

A free, no-ads Android step counter. Live tracking from a persistent
foreground service, a daily target with progress ring, distance/calorie/time
estimates, history charts, saved routes, and sensor calibration.

- **Package:** `com.nttech.roamfree` (`.dev` suffix on debug builds, so a
  `flutter run` install sits alongside the real app with its own database and
  preferences — a dev build showing no history is working as intended)
- **Platform:** Android only. iOS has never been built or tested — the
  background service, the notification and the permission flow are all
  Android-specific.
- **Stack:** Flutter · Riverpod 3 · sqflite · SharedPreferences ·
  `flutter_local_notifications` · `roameter` (this repo's own sensor plugin,
  `packages/roameter`). The foreground service, the boot receiver and the
  periodic sampler are hand-written Kotlin in `android/app`.

## What it does

- **Live step tracking** from the hardware step sensor, in a background
  service — not only while the app is open.
- **Ongoing notification** with today's count, target and progress —
  switchable off, without switching off the counting.
- **Daily target** with a progress ring, editable from the app bar.
- **Distance / calories / active time**, derived from step count (no GPS).
- **7-day chart**, target-relative: bars colored by whether the day hit the
  target, y-axis floor at least the target. Tap a day for its hourly
  breakdown.
- **Saved routes**: name a walk, track it live, keep a running average.
  Cancel without recording a session, or log one to today after the fact.
- **Personalization**: optional height and weight sharpen the estimates;
  metric or imperial throughout. Pace drives active time directly, and
  calories through walking speed.
- **Calibration**, two kinds: a 90–110% slider with a guided 100-step test for
  the sensor's accuracy, and a steps-per-minute setting with a guided
  60-second test for the walker's own pace.
- **Recovers days it wasn't running for.** Totals are derived from a journal
  of counter readings rather than accumulated live, so a service an OEM killed
  on Tuesday still yields Tuesday's steps.
- **Auto-starts on boot**, once the app has been opened at least once, unless
  the ongoing notification has been turned off.

## Getting started

```
flutter pub get
flutter test        # ~167 tests, no device or sensor needed
(cd packages/roameter && flutter test)   # the sensor plugin's own tests
flutter analyze
flutter run         # installs as "Roamfree Dev"
```

The fold that derives totals is a pure function over a list of readings, so
days, reboots, hour boundaries and midnight all run in milliseconds with no
device. The database tests run sqflite on the host via `sqflite_common_ffi`,
including every schema migration — the only part of this codebase that can
destroy history a user already has, and the only part that never runs during
ordinary development.

## Architecture: two isolates, one counter

Everything here follows from the app running in two Dart isolates that share
no memory:

| | **App isolate** (`main.dart`) | **Service isolate** (`onServiceStart`) |
| :--- | :--- | :--- |
| Lives as long as | the UI is open | the foreground service does — across the app being backgrounded, killed, or never opened |
| Owns | the UI, Riverpod, route CRUD | the notification, and counting while nobody is looking |
| Reads the sensor | only while on screen *and* no service is running | whenever it runs |

> **Exactly one of the two counts at a time.**

Both write to the same journal, and two writers would fight over the same rows
and double-count. `_ensureBackgroundServiceRunning` in `HomePage` is the one
place that decides, and it stops one before starting the other.

Which one is counting is a question about *liveness*, not correctness.
`TYPE_STEP_COUNTER` is a cumulative hardware register that runs whether or not
anything is listening, so a reading before a gap and a reading after it are
enough to recover everything in between. That is what the journal is for, and
why nothing here has to stay subscribed to be right.

| Situation | What counts | What the user sees |
| :--- | :--- | :--- |
| Notification on | the service | a live count, app open or not |
| Notification off, app open | the app isolate | a live count while they watch |
| Notification off, app away | the native sampler, every 15 min | totals catch up on the next open |

The app isolate drops its subscription the moment it leaves the screen. That
subscription is only worth its power draw while somebody is looking at the
number it produces.

## What owns what

**SharedPreferences is loaded into memory per isolate at first use.** Each
isolate sees its own writes immediately and the other's not at all. Live state
crosses over `service_channel` for exactly this reason; the few reads that
genuinely need the other side's writes call `PreferencesService.reload()`
first, which drops the cached snapshot. sqflite is the same story with a
separate connection per isolate, except that reads do hit the file.

| State | Written by | Read by |
| :--- | :--- | :--- |
| `step_journal` table | whichever isolate is counting, and the native sampler | both |
| `daily_steps`, `hourly_steps` tables | derived from the journal by `StepProjection` | app (charts, seed value) |
| `manual_steps` table | service, on an `addManualSteps` command | both |
| `activeRoute` | service (sole writer) | both |
| `stepSensorAvailable` | service | app, at launch |
| `serviceHeartbeat` | service, on a timer | app, to tell a live service from a deaf one |
| `foregroundTrackingEnabled` | app | app, and Kotlin on boot |
| `dailyTarget`, `stepCorrectionFactor` | app | service, at start-up |
| `heightCm`, `weightKg`, `unitSystem`, `stepsPerMinute` | app | app |
| `routes`, `route_sessions` tables | app | app |

Three consequences worth knowing before editing:

- **A setting the app writes is invisible to a running service.** The target
  and correction factor are mirrored over `service_channel` for exactly this
  reason. Cadence needs no channel: only `StepMetrics` reads it, and the
  service isolate never calls into `StepMetrics`.
- **The active route is written only by the service isolate.** The app keeps
  its own copy for the UI and must not persist it. Clearing is the exception —
  both sides may clear, because clearing is idempotent and can only ever end a
  route.
- **`foregroundTrackingEnabled` is read from Kotlin as well as Dart.**
  `BootReceiver` has to know whether the user wants the service before any
  Dart has run, so `TrackingPreference` reads Flutter's own preferences file
  directly. Without that, a reboot switched tracking back on behind the back
  of anyone who had turned it off.

## Crossing the boundary: `service_channel.dart`

Every message between the isolates is declared once, with its name, its
encoding and its direction baked into the type. `ServiceCommand` only travels
app → service and `ServiceReport` only service → app, so neither can be sent
backwards, and a typo is a compile error rather than a setting that quietly
stops working.

| Channel | Direction | Payload | Purpose |
| :--- | :--- | :--- | :--- |
| `setCorrectionFactor` | app → service | `double` | mirror a recalibration |
| `setDailyTarget` | app → service | `int` | mirror a new target |
| `addManualSteps` | app → service | `int` | credit a route logged after the fact |
| `startRoute` | app → service | `{routeId, routeName}` | begin live route tracking |
| `stopRoute` | app → service | *(signal)* | end it |
| `stepUpdate` | service → app | `{steps, date}` | today's total; the date lets the app tell a live figure from a stored one |
| `rawStep` | service → app | `int` | raw cumulative reading, for the calibration test |
| `routeUpdate` | service → app | `int` | live route step count |
| `sensorStatus` | service → app | `bool` | whether this device has a step counter |

`stopService` is handled as a raw string in `onServiceStart`; there is no
foreground/background toggle any more, because this service is only ever
foreground.

The transport underneath changed in the move off `flutter_background_service`
and `service_channel.dart` did not: both sides still `invoke` and `on`, but a
`TrackingService`/`TrackingServiceInstance` pair now carries the messages over
two method channels that `ServiceBridge.kt` routes between. A message with no
live counterpart is dropped rather than queued — if the app is not running
there is nobody to receive a report, and if the service is not running a
command has nothing to act on.

**To add a message:** declare it in `service_channel.dart`, then `.handle(...)`
it in `onServiceStart`'s start-up half — above the sensor listener, so it is
registered before the first reading can arrive — or `.listen(...)` it in
`PedometerService`. If it mirrors a stored setting, add the accessor and the
channel name to `_mirroredSettings` in
`test/background_service_invariants_test.dart`.

## Counting: the journal

`TYPE_STEP_COUNTER` is a cumulative register that counts whether or not
anything is listening. Totals are therefore *derived from readings* rather
than accumulated live: `step_journal` holds `(raw, timestamp)` rows, and
`foldJournal` differences adjacent pairs into daily and hourly totals.

That one decision is what fixes a day the service never ran. The steps were
never lost — only unrecorded — so a reading on either side of a gap recovers
everything inside it.

Four things are load-bearing:

- **Steps are attributed to an interval's start.** They happened somewhere
  inside it and nothing says where, so the choice is between biasing early and
  biasing late. Early is right because a reading is taken at midnight: the
  interval *ending* at 00:00 belongs to the day that just finished, and the one
  *starting* there to the new day. Day boundaries come out exact, and within a
  day the error is bounded by the sampling interval rather than by how long the
  device slept.

- **A falling raw count means a reboot — and that reading is only sound while
  entries are in order.** Two readings of one counter can disagree about which
  is larger only if they disagree about which came first. Since readings may
  carry sensor event times *older than the moment they arrive*,
  `StepProjection` enforces strictly increasing timestamps, filing a late
  arrival just after the newest entry rather than before it. Without that, one
  late arrival looks exactly like a reboot and credits a whole counter's worth
  of steps.

- **Readings are journalled at the sensor's own event time where possible.**
  A reading buffered through a device sleep stands for the moment the counter
  reached it, which is when the walking happened — not the moment the phone
  woke up and delivered it. Falling back to arrival time when the event time is
  in the future or out of order.

- **The display does not wait for a journal write.** Journalling every reading
  would be thousands of rows a day for nothing. `LiveStepCounter` writes every
  five minutes, on the hour, and on the date turning; in between, the shown
  figure is the last derived total plus the steps taken since the last write.
  A database peek showing less than the screen is that, not a bug.

Manual credits live in their own table and are added on top of the fold rather
than into it: nobody walked them, so they belong to a day's total and to no
hour. They moved out of preferences precisely because re-deriving an older day
has to be able to give them back.

### Upgrading an install that has no journal

Derived totals replace stored ones, so a journal that starts mid-morning would
otherwise shrink today to whatever it happens to cover — an install upgrading
into this would watch its step count collapse.

`backfillFromStoredTotal` works *backwards* instead: the stored total says how
many steps today holds and the counter says where it is now, so the difference
is the reading today opened at. Writing that at midnight makes the fold
reproduce the day it is replacing. It runs once, against an empty journal.

### Journal retention

The journal is a rolling buffer, not the archive. `StepProjection` re-derives
the last 14 days and prunes readings older than 30; the totals those readings
were folded into outlive them in `daily_steps`.

### Notification throttling

`NotificationThrottle` collapses notification rewrites into one per second.
Every rewrite is a platform-channel hop, an IPC to `NotificationManagerService`
and a SystemUI relayout, and it was happening once per step; nobody can read a
number that changes faster than that anyway.

The first update in a quiet period goes out immediately, which is what keeps
the notification feeling live. The trailing send is the load-bearing part: the
most recent update to arrive during a window is sent when the window ends, so
the last reading of a walk always lands and the notification can never settle
showing a stale total. `flush()` is called on `stopService`, because a timer
that never fires is the one way a held update goes missing for good — the same
reason the journal is flushed there.

Route and daily updates share the throttle deliberately — they target the same
notification id, so last writer wins either way.

### Estimates

`StepMetrics` turns a step count into distance, calories and active time.
Two things there are easy to get wrong:

- **Intensity is a function of speed, not cadence.** `metWalking` takes km/h,
  and `speedKmh` derives that from cadence × stride — reusing `distanceKm`,
  so the stride model exists in exactly one place. Mapping cadence straight to
  a MET would call a tall, unhurried walker brisk and a short, hurrying one
  slow; going through speed makes that impossible.
- **Cost per step is U-shaped**, bottoming out around 100 spm and rising at
  both ends. A slow shuffle really does cost more per step than a normal walk.
  That is the published curve, not a bug, and there is a test pinning it
  because it reads like one.

MET anchors come from the Compendium of Physical Activities for level
walking, discounted by `incidentalWalkingFactor` — those values describe
sustained purposeful walking, and a day's step total is mostly corridors and
kitchen trips. The discount is a separate named constant so the anchors stay
checkable against the source.

## Service lifecycle

`StepTrackingService` is this repo's own Kotlin foreground service, and the
things it does *not* do matter as much as the things it does.

- **It holds no wakelock.** A foreground service keeps the process from being
  reclaimed; it does not, and should not, keep the CPU awake. The counter runs
  through suspend and delivers what it buffered on the next wake, so nothing is
  lost by letting the application processor sleep — only the notification lags
  until it does. The plugin this replaced acquired a `PARTIAL_WAKE_LOCK` with
  no timeout and never released it; `dumpsys power` showed it held for fifteen
  hours straight. `WAKE_LOCK` is no longer in the merged manifest at all, so
  the app cannot hold one by accident.

- **It returns `START_STICKY`.** Android restarts a sticky service it had to
  kill, with no exact alarms and no polling. The plugin this replaced used
  `START_NOT_STICKY` plus an alarm-driven watchdog that armed once, five
  seconds after start, and never re-armed — so once the service had been up for
  five seconds there was no recovery mechanism at all.

- **The restart arrives with a null Intent,** which is why the Dart entrypoint
  handle is persisted (`TrackingCallback`) rather than passed in. On that cold
  restart the service is the first thing in the process, so
  `FlutterLoader.ensureInitializationComplete` has to run *before*
  `FlutterCallbackInformation.lookupCallbackInformation` — the lookup is a
  native call, and nothing has loaded `libflutter` yet. Starting from the
  activity happens to work either way, which makes this the failure mode you
  only see once the service has to come up on its own. It is also exactly what
  a reboot does.

- **The isolate needs `WidgetsFlutterBinding.ensureInitialized()`.** It is
  entered directly from Kotlin, so nothing has set up the binding the way a
  normal launch would, and every platform channel below it — notifications,
  preferences, sqflite, the sensor — needs it first.

- **Notification id `888` and channel id `step_counter_channel`** are shared by
  the foreground-service notification and every update the service pushes. The
  channel is created in Kotlin as well as Dart, because the service can start
  on boot before any Dart runs. **Don't change the channel id**; it would
  orphan the notification settings of every install.

- **A single midnight `Timer`** resets the notification to `0/target` and
  reschedules itself, rather than polling. It is skipped while a route is
  active so it can't stomp the route notification.

### Sampling

`StepSampler` takes a reading every fifteen minutes — or at midnight, whichever
comes first — whether or not anything else is running. It is the safety net
under the whole design: without it, a reboot while the notification is off
loses everything since the app was last opened, because the counter zeroes and
there is no reading on the far side of it.

Deliberately native. Spinning a Flutter engine for a two-column insert would
cost more than the sample it is taking, so `JournalWriter` opens the database
without an `SQLiteOpenHelper` — a helper would carry its own version number and
try to "upgrade" a schema sqflite owns — and inserts into a table Dart has
already created. Those two columns are the whole Kotlin/Dart contract.

The alarm is inexact (`setAndAllowWhileIdle`). An exact one needs
`SCHEDULE_EXACT_ALARM`, a restricted Play Console permission, and the inexact
version still fires through Doze. A sample landing a few minutes late costs a
little attribution accuracy and never loses a step.

### Deciding who runs

`_ensureBackgroundServiceRunning()` in `HomePage` runs after permission is
granted and on every `resumed` event. It reads `foregroundTrackingEnabled`
first and either starts the service (stopping local counting) or starts local
counting (stopping the service).

`isRunning()` only reports that an Android service object exists. It says
nothing about whether the isolate inside it is alive or whether a reading has
arrived since, so a service that is running is additionally checked against
`serviceHeartbeat`: silence past `serviceHeartbeatTimeout` (45 minutes, three
missed beats) means stop-then-start, because `start()` on a service the
platform still considers alive is a no-op. A heartbeat rather than the last
reading's timestamp, because somebody asleep for eight hours produces no
readings either, and restarting the service every morning on that evidence is
pure churn.

## The UI side

Riverpod, one `ProviderScope` at the root. `PedometerService` is a singleton
provider; everything else hangs off it.

| Provider | What it gives |
| :--- | :--- |
| `todayStepsProvider` | live daily total, seeded from the DB then fed by `stepUpdate` — or, with no service running, by the app's own `LiveStepCounter` |
| `stepSensorAvailableProvider` | replays its last value to late subscribers — the report is a single event, and a subscriber created afterwards would otherwise wait forever on hardware without a sensor |
| `foregroundTrackingProvider` | whether the ongoing notification runs; acts on the setting rather than only storing it, so the notification appears or disappears as the switch moves |
| `dailyTargetProvider`, `calibrationFactorProvider`, `heightCmProvider`, `weightKgProvider`, `unitSystemProvider` | settings, via the shared `SettingNotifier` base — synchronous fallback first, hydrated from prefs, saved through the service where it must be mirrored |
| `systemSettingsProvider` | the battery and notification-channel screens the app can only point at |
| `past7DaysProvider`, `hourlyStepsForDateProvider` | chart data, zero-filled for missing days/hours |
| `activeRouteProvider`, `activeRouteStepsProvider` | the route in progress; keyed by start time so a new session gets a genuinely fresh subscription |

Charts re-fetch off `_chartRefreshBucketProvider`, which changes every 100
steps rather than every step.

## Key files

```
lib/
├── main.dart                     — entry point; init order matters
├── models/                       — daily_steps, hourly_steps, saved_route,
│                                   step_journal_entry
├── services/
│   ├── background_service.dart   — service isolate: sensor listener, route
│   │                               bookkeeping, heartbeat, liveness helpers
│   ├── step_journal.dart         — foldJournal: readings → totals, pure
│   ├── step_projection.dart      — journal → stored totals; ordering,
│   │                               manual credits, upgrade backfill
│   ├── live_step_counter.dart    — keeps the display exact between writes
│   ├── step_sync.dart            — one reading, no service, on resume
│   ├── tracking_service.dart     — app ↔ service transport
│   ├── service_channel.dart      — every cross-isolate message, typed
│   ├── pedometer_service.dart    — app-isolate bridge; also counts locally
│   │                               when no service is running
│   ├── system_settings.dart      — battery + notification-channel intents
│   ├── notification_service.dart — the one notification, three faces
│   ├── database_helper.dart      — sqflite: journal, history, routes
│   ├── preferences_service.dart  — settings, heartbeat, legacy cleanup
│   ├── metrics.dart              — step → distance/calories/time;
│   │                               intensity via speed, not cadence
│   ├── formatting.dart           — dateKey (local, never UTC), durations
│   └── providers.dart            — Riverpod wiring
├── screens/                      — home_page, routes_page, settings_page
└── widgets/                      — ring, cards, dialogs, charts/

packages/roameter/                — the sensor plugin: batching control,
                                    real event timestamps, one-shot reads

android/app/src/main/kotlin/com/nttech/roamfree/
├── StepTrackingService.kt        — the foreground service; no wakelock
├── StepSampler.kt                — the 15-minute / midnight alarm
├── JournalWriter.kt              — native insert into step_journal
├── ServiceBridge.kt              — routes messages between the isolates
├── BootReceiver.kt               — boot and package-replaced
├── TrackingCallback.kt           — the persisted Dart entrypoint handle
├── TrackingPreference.kt         — the notification setting, from Kotlin
└── MainActivity.kt               — system-settings and service channels
```

### Storage layout

```
sqflite (step_counter.db, version 7)
  step_journal(recordedAt PK, rawSteps)      readings; a rolling 30 days
  daily_steps(date PK, stepCount)            derived from the journal
  hourly_steps(date, hour, stepCount, PK(date, hour))
  manual_steps(date PK, stepCount)           credits that never came from
                                             the sensor
  routes(id PK, name, createdAt)
  route_sessions(id PK, routeId, date, steps, durationSeconds)

SharedPreferences
  dailyTarget · stepCorrectionFactor · stepsPerMinute
  heightCm · weightKg · unitSystem
  foregroundTrackingEnabled   also read from Kotlin, on boot
  serviceHeartbeat            proof of life, written on a timer
  batteryPromptDismissed
  stepSensorAvailable · activeRoute (JSON blob, so it reads and clears
                                     atomically)
```

Baselines and `lastRawReading` are gone — the journal records raw readings
now, so nothing needs to remember one separately.
`PreferencesService.removeSupersededKeys()` clears what earlier versions left
behind; preferences load whole on first access, so orphans are paid for on
every launch until they go.

Dates are `yyyy-MM-dd` **local** time (`dateKey`), never UTC, and sort
chronologically as plain strings so SQL `BETWEEN`/`ORDER BY` work directly.

## Tests

| File | Covers |
| :--- | :--- |
| `step_journal_test.dart` | `foldJournal` in isolation: gaps, reboots, midnight, out-of-order entries, correction factors |
| `step_projection_test.dart` | journal → stored totals, manual credits, retention, the upgrade backfill, and the ordering that keeps the reboot rule sound |
| `live_step_counter_test.dart` | journal cadence, the live figure between writes, and event-time attribution |
| `local_counting_test.dart` | that a reading reaches the display with **no service running** |
| `step_sync_test.dart` | the one-shot resume sample and its throttle |
| `preferences_service_test.dart` | heartbeat round-trip, manual-credit pruning, superseded-key cleanup |
| `database_helper_test.dart` | queries, concurrent opens, and every schema migration |
| `route_progress_test.dart` | `resolveRouteProgress` across reboots and segments |
| `metrics_test.dart` | distance/calorie/time formulas, personalized and flat-rate |
| `notification_throttle_test.dart` | leading edge, coalescing, and the trailing send |
| `sensor_available_stream_test.dart` | that the sensor report replays to late subscribers |
| `settings_page_test.dart` | the battery section's three states, and that the notification row offers a real switch |
| `background_service_invariants_test.dart` | **a source-reading guard, not a unit test** |
| `packages/roameter/test/` | reading payloads, one-shot reads, and that `batchLatency` is passed through |

That second-to-last one parses `background_service.dart` as text, because the
rule it protects can't be observed from inside a single isolate: mirrored
settings must be read exactly once, at start-up, *above* the sensor listener. A
read below it would return the start-up snapshot and silently revert anything
the app mirrored in since. If you move the listener, the test tells you to
update its `_startupBoundary` constant — which is exactly what it did during
the move off `pedometer`.

`local_counting_test.dart` exists because of a real regression: turning the
notification off left the displayed count frozen, moving only when a resume
happened to re-read the database — always one resume behind. Nothing was
pushing totals to the UI at all.

## Android configuration

In `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_HEALTH" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
```

Notably **not** `WAKE_LOCK`. It was only ever there because a plugin declared
it, and its absence is what makes it impossible to reintroduce the drain by
accident.

And inside `<application>`, the service and its two receivers:

```xml
<service
    android:name=".StepTrackingService"
    android:foregroundServiceType="health"
    android:exported="false"
    android:stopWithTask="false" />

<receiver android:name=".StepSampleReceiver" android:exported="false" />
<receiver android:name=".BootReceiver" android:exported="false">
    <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED" />
        <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
    </intent-filter>
</receiver>
```

`stopWithTask="false"` keeps tracking alive when the app is swiped out of
recents. Both receivers are `exported="false"`, which also means a shell
`am broadcast` cannot reach them — worth knowing before concluding the sampler
is broken.

**The service type must be `health`.** Android refuses to start a `dataSync`
foreground service from `BOOT_COMPLETED`, and throws rather than declining: the
service dies in `onCreate` before Flutter starts, and the OS shows "Roamfree
keeps stopping" with nothing in logcat. It only fires on boot-initiated starts,
so opening the app by hand always looks fine.

**App icon:** `dart run flutter_launcher_icons`, configured in `pubspec.yaml`.
The adaptive foreground/background split is deliberate — a flat square logo
without one gets shrunk by Android's icon masking.

## Releasing

```
./scripts/release.sh [patch|minor|major]
```

Releases are signed with a real keystore rather than Flutter's debug key, so
Android treats successive builds as in-place updates and testers keep their
history. Credentials live in `android/key.properties`, **not committed** —
without it `build.gradle.kts` falls back to debug signing, which silently
breaks updates for anyone who already has the app installed.

The script runs `flutter analyze` and `flutter test` first and stops on
either. A release goes straight onto testers' phones with no store review, so
this is the only gate there is, and it fails before the build, before the
counters advance and before anything is pushed.

On success it advances `android/next_build_number.txt` and
`android/next_version_name.txt`, writes the released version back to
`pubspec.yaml`, and produces a per-version APK (`roamfree_0.3.4.apk`) rather
than overwriting one file. The counter files hold the *next* version and are
committed, so everyone releasing stays in sync. The release commit stages
those three files by name and never `git add .` — that swept whatever was
untracked into release commits, which is how a Gradle report ended up in the
repo.

## Known limitations

- **iOS is unbuilt and untested.**

- **First launch needs the app opened by hand once.** Android holds
  freshly-installed apps in a "stopped" state that blocks the boot-completed
  broadcast until then. Auto-start works normally on later reboots.

- **A force-stop stops everything until the app is opened again.** Android
  cancels the sampler's alarm and blocks the boot broadcast for an app in the
  stopped state, so nothing records until somebody launches it. The fold
  recovers the gap on that launch — unless the device rebooted inside it, in
  which case the counter zeroed and the pre-reboot part is unrecoverable.

- **Screen-off steps reach the display late.** The sensor buffers readings
  while the CPU sleeps and hands the batch over on the next wake, so the
  notification lags. They are counted in full, and since readings are journalled
  at their own event times they are attributed to the hours they actually
  happened in — the lag is in the display, not in the totals.

- **An unclean reboot loses steps since the last journal write.** The counter
  zeroes and there is no reading on the far side of the restart. Bounded by the
  journal cadence: up to five minutes with the service running, up to fifteen
  with only the sampler. Tune `LiveStepCounter.interval` and
  `StepSampler.INTERVAL_MS` to trade writes for precision.

- **A gap with no reading inside it lands on the day it began.** Steps are
  attributed to an interval's start, so a stretch the sampler slept through
  entirely credits the earlier day. Nothing is lost, but a long outage can
  weight one day over its neighbour. The midnight reading is what keeps this
  from crossing a date boundary in ordinary use.

- **Some OEM battery managers** (Xiaomi, Huawei, Oppo, Vivo, Samsung, OnePlus)
  kill background services more aggressively than stock Android. Much less
  likely to bite than it was — those managers target apps that hold permanent
  wakelocks, which this no longer does — but the Settings screen offers the
  battery-optimization exemption for the ones that still do.

- **Health Connect is not read.** It would only add history from before
  Roamfree was installed, or a reboot during a force-stopped stretch, and it
  holds step data only if some *other* app writes it. Judged not worth the
  dependency, the health-data permissions and the Play Console declaration
  once the journal covered ordinary gaps.

- **`roameter` is not published.** It lives at `packages/roameter` as a path
  dependency. The boundary is real, so publishing later is cheap; the API has
  not been stable long enough to be worth anyone else depending on.
