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
  `flutter_background_service` · `pedometer` · `flutter_local_notifications`

## What it does

- **Live step tracking** from the hardware step sensor, in a background
  service — not only while the app is open.
- **Persistent notification** with today's count, target and progress.
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
- **Auto-starts on boot**, once the app has been opened at least once.

## Getting started

```
flutter pub get
flutter test        # ~130 tests, no device or sensor needed
flutter analyze
flutter run         # installs as "Roamfree Dev"
```

Step accounting runs against an in-memory `StepStore`; the database tests run
sqflite on the host via `sqflite_common_ffi`, including both schema
migrations — the only part of this codebase that can destroy history a user
already has, and the only part that never runs during ordinary development.

## Architecture: two isolates, one sensor

Everything here follows from the app running in two Dart isolates that share
no memory:

| | **App isolate** (`main.dart`) | **Service isolate** (`onServiceStart`) |
| :--- | :--- | :--- |
| Lives as long as | the UI is open | the foreground service does — across the app being backgrounded, killed, or never opened |
| Owns | the UI, Riverpod, route CRUD | the step sensor, all counting, the notification |
| Sensor access | none | `Pedometer.stepCountStream` |

> **Only one place may call `Pedometer.stepCountStream.listen()`, and that
> place is `onServiceStart`.**

The plugin supports a single active native listener. A second `.listen()` —
even briefly, even from the other isolate — can silently kill the first, and
it presents as "steps just stop updating, no error." It has happened twice.

| Stream | Owner | Why |
| :--- | :--- | :--- |
| `stepCountStream` | `background_service.dart`, in `onServiceStart` | Must survive the app being backgrounded, killed, or never opened. |
| `pedestrianStatusStream` | `PedometerService`, app isolate | Different native channel, so no conflict. Nothing reads its output — it is subscribed purely because dropping it made step readings arrive in laggy batches. |

The app never touches the step sensor. `PedometerService` is a bridge: it
relays the service's broadcasts as ordinary Dart streams and sends commands
back.

## What owns what

**SharedPreferences is loaded into memory per isolate at first use.** Each
isolate sees its own writes immediately and the other's not at all. Persisted
state therefore crosses the boundary *only at start-up*, when each side reads
it once; everything live crosses over `service_channel` instead. sqflite is
the same story with a separate connection per isolate, except that reads do
hit the file — so the app sees service writes as soon as they are flushed
(within `ThrottledStepStore.flushInterval`, 10s).

| State | Written by | Read by |
| :--- | :--- | :--- |
| `daily_steps`, `hourly_steps` tables | service | app (charts, seed value) |
| `baseline_<date>`, `manualSteps_<date>`, `lastRawReading` | service | service |
| `stepSensorAvailable` | service | app, at launch |
| `activeRoute` | service (sole writer) | both |
| `dailyTarget`, `stepCorrectionFactor` | app | service, at start-up |
| `heightCm`, `weightKg`, `unitSystem`, `stepsPerMinute` | app | app |
| `routes`, `route_sessions` tables | app | app |

Two consequences worth knowing before editing:

- **A setting the app writes is invisible to a running service.** The target
  and correction factor are mirrored over `service_channel` for exactly this
  reason, and `StepAccumulator` deliberately has no storage access for the
  factor, making a stale re-read impossible rather than merely discouraged.
  Cadence needs no channel: only `StepMetrics` reads it, and the service
  isolate never calls into `StepMetrics`.
- **The active route is written only by the service isolate.** The app keeps
  its own copy for the UI and must not persist it. Clearing is the exception —
  both sides may clear, because clearing is idempotent and can only ever end a
  route.

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

`setAsForeground`, `setAsBackground` and `stopService` are the plugin's own
built-in names and are still handled as raw strings in `onServiceStart`.

**To add a message:** declare it in `service_channel.dart`, then `.handle(...)`
it in `onServiceStart`'s start-up half — above the sensor listener, so it is
registered before the first reading can arrive — or `.listen(...)` it in
`PedometerService`. If it mirrors a stored setting, add the accessor and the
channel name to `_mirroredSettings` in
`test/background_service_invariants_test.dart`.

## Counting: `StepAccumulator`

`StepAccumulator` turns raw readings into daily and hourly totals, reaching
storage only through the `StepStore` interface — which a test satisfies with
four maps, so a day, a reboot and an hour boundary run in milliseconds. Nearly
every counting bug this project has had lived in that logic while it was
inline in `onServiceStart` and unreachable from a test.

Four things are load-bearing:

- **The day's total is derived, not accumulated** — recomputed each reading as
  `(raw − baseline) × correctionFactor`. That is why a lost write is harmless,
  and why `ThrottledStepStore` can buffer writes at all.
- **A counter reset is detected against the previous reading, not the
  baseline.** The baseline goes negative after the first reboot of a day, and
  nothing falls below a negative number — comparing against it misses a second
  reboot and reverts the day. The previous reading is persisted on every
  reading and never buffered.
- **A new day is anchored at the previous reading, not at the one that opens
  it.** The sensor counts while the CPU sleeps and hands over the whole batch
  when it wakes, so the first reading of a day routinely arrives *after* the
  walk that produced it and carries all of it. Anchoring the day at that
  reading makes the walk the day's zero — which is how a night with the app
  closed plus a morning walk came to count nothing at all. Past
  `StepAccumulator.maxCarryOverGap` (18h) the batch is dropped instead: that
  gap means a service down for a day or more, and there is no telling which
  day its steps belong to.
- **The reading and its arrival time are one stored value, under one key.** A
  count whose age is unknown can't be carried over, so the pair is useless
  split — and two keys let a process die between them. `LastRawReading`
  encodes as `<raw>@<millis>`; `getLastRawReading` falls back to the older
  single-int key so an upgrade doesn't lose the reading and miss the next
  reboot.

### Write buffering

`ThrottledStepStore` wraps the real store and holds daily/hourly rows back for
`flushInterval` (10s), collapsing a walk's worth of updates into one row each.
Reads see buffered values, so the app never reads behind the buffer by more
than that interval.

Not buffered, and not to be: **baselines** and **manual credits** (both flush
the buffer first, so a stored baseline can't outrun the total it anchors), and
**the last raw reading** (a stale value sitting below a post-reboot reading
makes the restart invisible). `flush()` is called on `stopService`, because a
timer that never fires is the one way buffered steps go missing for good.

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

- `initializeBackgroundService()` runs from `main()` and only *configures* the
  service: `autoStart: false`, `autoStartOnBoot: true`, foreground mode,
  service type `health`.
- The app starts it — `_ensureBackgroundServiceRunning()` in `HomePage`, after
  permission is granted and again on every `resumed` lifecycle event, so an
  OEM battery manager that killed the service doesn't leave tracking silently
  off. A failure raises a retry banner above the counts rather than replacing
  them: the stored total is still real, it just isn't advancing.
- On resume the app also calls `refreshForCurrentDate()`, so a date rollover
  while the app was away can't leave yesterday's total on screen.
- Notification id `888` and channel id `step_counter_channel` are shared by
  the foreground-service notification and every update the service pushes —
  daily total, route progress, sensor-unavailable. That shared id is what lets
  the service rewrite the FGS notification in place. **Don't change the
  channel id**; it would orphan the notification settings of every install.
- A single midnight `Timer` resets the notification to `0/target` and
  reschedules itself, rather than polling. It is skipped while a route is
  active so it can't stomp the route notification, and it touches no counting
  state — that resolves on the first real reading regardless.

## The UI side

Riverpod, one `ProviderScope` at the root. `PedometerService` is a singleton
provider; everything else hangs off it.

| Provider | What it gives |
| :--- | :--- |
| `todayStepsProvider` | live daily total, seeded from the DB then fed by `stepUpdate` |
| `stepSensorAvailableProvider` | replays its last value to late subscribers — the report is a single event, and a subscriber created afterwards would otherwise wait forever on hardware without a sensor |
| `walkingStatusProvider` | no UI consumer; keep it subscribed (see the stream table above) |
| `dailyTargetProvider`, `calibrationFactorProvider`, `heightCmProvider`, `weightKgProvider`, `unitSystemProvider` | settings, via the shared `SettingNotifier` base — synchronous fallback first, hydrated from prefs, saved through the service where it must be mirrored |
| `past7DaysProvider`, `hourlyStepsForDateProvider` | chart data, zero-filled for missing days/hours |
| `activeRouteProvider`, `activeRouteStepsProvider` | the route in progress; keyed by start time so a new session gets a genuinely fresh subscription |

Charts re-fetch off `_chartRefreshBucketProvider`, which changes every 100
steps rather than every step.

## Key files

```
lib/
├── main.dart                     — entry point; init order matters
├── models/                       — daily_steps, hourly_steps, saved_route
├── services/
│   ├── background_service.dart   — service isolate: sole sensor listener,
│   │                               route bookkeeping, foreground config
│   ├── step_accumulator.dart     — the counting: StepAccumulator, StepStore,
│   │                               ThrottledStepStore, PersistentStepStore
│   ├── service_channel.dart      — every cross-isolate message, typed
│   ├── pedometer_service.dart    — app-isolate bridge to the service
│   ├── notification_service.dart — the one notification, three faces
│   ├── database_helper.dart      — sqflite: history, routes, sessions
│   ├── preferences_service.dart  — settings, baseline, last raw reading
│   ├── metrics.dart              — step → distance/calories/time;
│   │                               intensity via speed, not cadence
│   ├── formatting.dart           — dateKey (local, never UTC), durations
│   └── providers.dart            — Riverpod wiring
├── screens/                      — home_page, routes_page
└── widgets/                      — ring, cards, dialogs, charts/
```

### Storage layout

```
sqflite (step_counter.db, version 4)
  daily_steps(date PK, stepCount)
  hourly_steps(date, hour, stepCount, PK(date, hour))
  routes(id PK, name, createdAt)
  route_sessions(id PK, routeId, date, steps, durationSeconds)

SharedPreferences
  dailyTarget · stepCorrectionFactor · stepsPerMinute
  heightCm · weightKg · unitSystem
  lastRawReading            "<raw>@<millisSinceEpoch>"
  baseline_<yyyy-MM-dd>     only the current day's is kept; writing one
                            drops every other
  manualSteps_<yyyy-MM-dd>  credits that never came from the sensor
  stepSensorAvailable · activeRoute (JSON blob, so it reads and clears
                                     atomically)
```

Dates are `yyyy-MM-dd` **local** time (`dateKey`), never UTC, and sort
chronologically as plain strings so SQL `BETWEEN`/`ORDER BY` work directly.

## Tests

| File | Covers |
| :--- | :--- |
| `step_accumulator_test.dart` | the counting: days, reboots, hour boundaries, batches across midnight, manual credits, recalibration |
| `baseline_test.dart` | `resolveBaselineValue` in isolation |
| `throttled_step_store_test.dart` | buffering, flush ordering, and that throttling changes *when* rows are written and nothing else |
| `preferences_service_test.dart` | the `lastRawReading` round-trip and the once-per-install upgrade read |
| `database_helper_test.dart` | queries, concurrent opens, and both schema migrations |
| `route_progress_test.dart` | `resolveRouteProgress` across reboots and segments |
| `metrics_test.dart` | distance/calorie/time formulas, personalized and flat-rate |
| `sensor_available_stream_test.dart` | that the sensor report replays to late subscribers |
| `background_service_invariants_test.dart` | **a source-reading guard, not a unit test** |

That last one parses `background_service.dart` as text, because the rule it
protects can't be observed from inside a single isolate: mirrored settings
must be read exactly once, at start-up, *above* the sensor listener. A read
below it would return the start-up snapshot and silently revert anything the
app mirrored in since. If you move the listener, the test tells you to update
its `_startupBoundary` constant.

## Android configuration

In `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_HEALTH" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
```

And inside `<application>`, an override on the plugin's own service
declaration — Android 14+ requires an explicit foreground service type
(`tools:replace` needs `xmlns:tools` on the root `<manifest>` tag):

```xml
<service
    android:name="id.flutter.flutter_background_service.BackgroundService"
    android:foregroundServiceType="health"
    tools:replace="android:exported" />
```

**The type must be `health`.** Android refuses to start a `dataSync` foreground
service from `BOOT_COMPLETED`, and throws rather than declining: the service
dies in `onCreate` before Flutter starts, the plugin's watchdog restarts it
into the same wall, and the OS shows "Roamfree keeps stopping" with nothing in
logcat. It only fires on boot-initiated starts, so opening the app by hand
always looks fine. The same type is set in `AndroidConfiguration` so the two
can't drift apart.

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
- **Some OEM battery managers** (Xiaomi, Huawei, Oppo, Vivo, Samsung, OnePlus)
  kill background services more aggressively than stock Android. A tester
  reporting steps that stop overnight, with everything here configured
  correctly, is more likely hitting a battery whitelist than a bug.
- **Screen-off steps arrive in batches**, because the sensor buffers readings
  while the CPU sleeps. They are counted in full — the reading that delivers a
  batch carries all of it — but the display and notification lag until it
  lands. A batch spanning midnight counts entirely toward the day it is
  delivered on: it carries no timestamps to split it by, so a late-night walk
  the device slept through can land on the following morning, and a batch more
  than 18h stale is dropped rather than misattributed.
- **An unclean reboot can lose up to ten seconds of steps.** Database writes
  are buffered and flushed on a timer; an ordinary kill costs nothing, since
  the next reading recomputes the total from the baseline, but a reboot
  re-derives the baseline *from* the stored total. Tune `flushInterval` in
  `ThrottledStepStore` to trade writes for precision.
- **A sensor error before the first reading is latched.** `recordSensorStatus`
  records the first outcome only, so a transient error at start-up persists
  `stepSensorAvailable: false` and shows the "no step sensor" screen until
  something overwrites it.
