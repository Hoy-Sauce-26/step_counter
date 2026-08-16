# Roamfree

A free, no-ads, no-catch step counter. Live step tracking with a persistent
background service, a daily target with progress ring, distance/calorie/time
estimates, a 7-day history chart, and sensor calibration — built to keep
growing with fun features over time (gamified milestones, etc.) without ever
charging for it.

- **Package:** `com.nttech.roamfree`
- **Platform:** Android only. iOS has never been built or tested against
  this codebase — several core pieces (the background service, the
  persistent notification, the sensor permission flow) are Android-specific
  and would need real work to port.

## What it does

- **Live step tracking**, via the phone's hardware step-count sensor,
  running continuously in a background service — not just while the app is
  open.
- **Persistent notification** showing today's step count, target, and
  progress percentage, kept up to date by that same background service.
- **Daily target** with a circular progress ring, editable from the app bar.
- **Distance / calories / active time** estimates derived from step count
  (no GPS).
- **7-day history chart**, target-relative: bars are colored by whether that
  day hit the target, y-axis floor is always at least the target.
- **Hourly breakdown**: tap a day in the 7-day chart for its hour-by-hour
  distribution.
- **Saved routes**: name a walk, track it live in the notification, and keep a
  running average of what it costs you. A route can be cancelled without
  recording a session, or logged to today after the fact when you walked it
  without tracking.
- **Personalization**: height and weight sharpen the distance and calorie
  estimates; both are optional and fall back to flat-rate averages. Metric or
  imperial throughout.
- **Calibration**: a manual percentage slider (90–110%) plus a guided
  100-step test that measures the sensor's real accuracy and suggests a
  correction factor.
- **Auto-starts on boot** (once the app has been opened at least once, per
  Android's restrictions on cold-installed apps — see Known limitations).

## Architecture — read this before touching sensor code

The single most important design constraint in this codebase:

> **Only one place is allowed to call `Pedometer.stepCountStream.listen()`.**

Android's step-count sensor plugin only supports one active native listener
at a time. Two independent `.listen()` calls — even briefly, even from
different Dart isolates — can silently break the "loser" listener, including
tearing down the app's ability to count steps at all until a full restart.
This has happened twice during development (once between the main app and a
calibration-test helper, once between the main isolate and the background
service) and both times manifested as "steps just stop updating, no error."

The current, correct ownership split:

| Sensor stream | Owner | Why |
| :--- | :--- | :--- |
| `Pedometer.stepCountStream` (step count) | `background_service.dart`, inside `onServiceStart` | Needs to keep running when the app is backgrounded, killed, or not yet opened — a main-isolate listener can't survive any of those. |
| `Pedometer.pedestrianStatusStream` (walking/stopped) | `PedometerService`, main isolate | Separate native channel, never involved in the conflict above. Nothing consumes its output any more — it is subscribed to purely for a side effect: dropping it made step readings arrive in laggy batches. Holding a fast listener on a related sensor appears to keep the sensor hub from batching the step counter. |

The main app never talks to the step-count sensor directly. `PedometerService`
listens to the background service's `stepUpdate` / `rawStep` broadcasts
(`FlutterBackgroundService().on(...)`) and exposes those as normal Dart
streams for the UI and calibration test to consume.

### Where the counting actually happens

`StepAccumulator` turns raw sensor readings into daily and hourly totals. It
reaches storage only through `StepStore`, which a test satisfies with four
maps — so a day, a reboot and an hour boundary can be driven through in
milliseconds without a device. Nearly every counting bug this project has had
lived in that logic while it was still inline in `onServiceStart` and
unreachable from a test.

Two things about it are load-bearing and easy to undo by accident:

- **The day's total is derived, not accumulated.** Every reading recomputes it
  as `(raw − baseline) × correctionFactor`. That is what makes a lost write
  harmless — the next reading recreates it — and it is why `ThrottledStepStore`
  can buffer writes at all.
- **A counter reset is detected by comparing against the previous reading, not
  against the baseline.** The baseline goes negative after the first reboot of
  a day, and nothing falls below a negative number, so comparing against it
  misses a second reboot and silently reverts the day. The previous reading is
  persisted on every reading and deliberately never buffered.

Two settings — the daily target and the correction factor — are mirrored into
the service isolate over `invoke`. They cannot be read from storage there:
SharedPreferences hands each isolate a private copy, so a value written by the
app is invisible to the service. `StepAccumulator` has no storage access for
the factor at all, which makes that mistake impossible rather than merely
discouraged.

### Key files

```
lib/
├── main.dart                        — app entry point, service init order matters here
├── models/
│   ├── daily_steps.dart             — {date, stepCount} record
│   ├── hourly_steps.dart            — {date, hour, stepCount} record
│   └── saved_route.dart             — a named route plus its session average
├── services/
│   ├── background_service.dart      — owns the sole step-count listener; foreground service config
│   ├── step_accumulator.dart        — the counting itself: StepAccumulator, StepStore and its two implementations
│   ├── pedometer_service.dart       — main-isolate bridge; reads background service broadcasts
│   ├── notification_service.dart    — the persistent notification (flutter_local_notifications)
│   ├── database_helper.dart         — sqflite: daily/hourly history, saved routes and their sessions
│   ├── preferences_service.dart     — shared_preferences: target, calibration, baseline, last raw reading
│   ├── metrics.dart                 — step → distance/calories/time formulas
│   └── providers.dart               — Riverpod providers wiring the above together
├── screens/
│   ├── home_page.dart               — ring, metric cards, 7-day chart, and the permission/sensor states
│   └── routes_page.dart             — saved routes: track, cancel, log to today
└── widgets/
    ├── step_progress_ring.dart
    ├── metric_card.dart
    ├── edit_target_dialog.dart
    ├── personalize_dialog.dart
    ├── calibration_dialog.dart
    ├── calibration_test_dialog.dart
    ├── hourly_breakdown_dialog.dart
    └── charts/
        ├── weekly_bar_chart.dart
        └── hourly_bar_chart.dart

test/                                — 90 tests, no device required; `flutter test`
```

## Setup

```
flutter pub get
```

### Tests

```
flutter test
```

Around 90 tests, none of which need a device or a sensor. The step accounting
runs against an in-memory `StepStore`, and the database tests run sqflite on
the host through `sqflite_common_ffi` — including both schema migrations,
which are the only part of this codebase that can destroy history a user
already has, and the only part that never runs during ordinary development.

`./scripts/release.sh` runs these before it will build anything.

### Android permissions & manifest

These need to already be present in `android/app/src/main/AndroidManifest.xml`
(all were added incrementally — if you're setting this up fresh on another
machine, check they're all there):

```xml
<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_HEALTH" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
```

And, inside `<application>`, an override on the background service plugin's
own service declaration (required on Android 14+, which enforces explicit
foreground service types):

```xml
<service
    android:name="id.flutter.flutter_background_service.BackgroundService"
    android:foregroundServiceType="health"
    tools:replace="android:exported" />
```

(`tools:replace` requires `xmlns:tools="http://schemas.android.com/tools"`
on the root `<manifest>` tag.)

**The type must be `health`, and this is not cosmetic.** Android refuses to
start a `dataSync` foreground service from `BOOT_COMPLETED`, and it throws
rather than declining — the service dies in `onCreate` before any Dart runs,
the plugin's watchdog restarts it into the same wall, and the OS eventually
shows "Roamfree keeps stopping". Nothing reaches logcat from Flutter, because
Flutter never started. `health` is on the permitted-from-boot list and is the
honest description of a pedometer besides.

It only ever fires on a boot-initiated start, so opening the app by hand
always looks fine — which is what made it look intermittent for days.

The same type is also declared in `AndroidConfiguration` in
`background_service.dart`, so the two cannot drift apart.

### App icon

Regenerated via `flutter_launcher_icons` from `assets/icon/icon.png`, with
an explicit adaptive-icon foreground/background split (a flat square logo
without one gets auto-shrunk by Android's adaptive icon masking). Config
lives in `pubspec.yaml` under the `flutter_launcher_icons:` key. Re-run with:

```
dart run flutter_launcher_icons
```

## Building a release

Signed releases use a real keystore, not Flutter's debug key — required for
Android to treat successive builds as updates-in-place (preserving a
tester's step history) rather than forcing an uninstall each time.

1. `android/key.properties` holds the keystore credentials — **not
   committed** (see `.gitignore`). Without it, `build.gradle.kts` silently
   falls back to debug signing, which breaks in-place updates for anyone
   who already has the app installed.
2. Cut a release with:
   ```
   ./scripts/release.sh [patch|minor|major]
   ```
   It runs `flutter analyze` and `flutter test` first and stops on either.
   A release APK goes straight onto testers' phones with no store review and
   no staged rollout, so this is the only gate there is — and it fails before
   the build, before the counters advance, and before anything is pushed.
3. On success it advances `android/next_build_number.txt` and the patch
   component of `android/next_version_name.txt`, writes the released version
   back into `pubspec.yaml`, and outputs a uniquely-named APK per version
   (e.g. `roamfree_0.3.0.apk`) to `build/app/outputs/flutter-apk/` rather
   than overwriting the same file each time.
4. Both counter files hold the *next* version, not the last one, and both
   **are** committed — they're shared state, not secrets, so everyone
   releasing from this repo stays in sync.
5. The release commit stages those three files by name. It deliberately does
   not `git add .`: that swept whatever happened to be untracked at release
   time into the release commit, which is how a Gradle report ended up in the
   repo.

Testers install by tapping the APK directly (no Play Store). As long as the
signing key and `applicationId` stay consistent between builds, installing a
new one updates in place and preserves their data.

## Known limitations

- **iOS is unbuilt and untested.** Everything above is Android-specific.
- **First launch requires manually opening the app once.** Android puts
  freshly-installed apps in a "stopped" state that blocks the boot-completed
  broadcast (and therefore auto-start) until the user opens the app by hand
  at least once. After that, auto-start-on-boot works normally on
  subsequent reboots.
- **Some OEM battery managers (Xiaomi, Huawei, Oppo, Vivo, Samsung, OnePlus)
  kill background services more aggressively than stock Android allows.**
  If a tester on one of these reports steps silently stopping overnight
  despite everything here being correctly configured, it's very likely an
  OEM-specific battery whitelist setting on their end, not an app bug.
- **Steps taken with the screen off for extended periods arrive in a batch**
  rather than in real time, because the hardware sensor buffers readings while
  the CPU sleeps. They are counted in full — the reading that delivers a batch
  carries all of it — but the on-screen figure and the notification can lag
  behind reality until that batch lands.
- **Up to ten seconds of steps can be lost in an unclean reboot.** Writes to
  the database are buffered and flushed on a timer, and while an ordinary kill
  costs nothing (the next reading recomputes the total from the baseline), a
  reboot re-derives the baseline *from* the stored total. The window is
  `flushInterval` in `ThrottledStepStore`; lower it to trade writes for
  precision.
