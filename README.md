# Roamfree

A free, no-ads step counter: live tracking from a persistent background
service, a daily target with progress ring, distance/calorie/time estimates,
history charts, saved routes, and sensor calibration.

- **Package:** `com.nttech.roamfree`
- **Platform:** Android only. iOS has never been built or tested — the
  background service, the notification and the permission flow are all
  Android-specific.

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
  metric or imperial throughout.
- **Calibration**: a 90–110% slider, plus a guided 100-step test that measures
  the sensor's accuracy and suggests a correction factor.
- **Auto-starts on boot**, once the app has been opened at least once.

## Architecture — read this before touching sensor code

> **Only one place may call `Pedometer.stepCountStream.listen()`.**

The plugin supports a single active native listener. A second `.listen()` —
even briefly, even from another isolate — can silently kill the first, and it
presents as "steps just stop updating, no error." It has happened twice here.

| Stream | Owner | Why |
| :--- | :--- | :--- |
| `stepCountStream` | `background_service.dart`, in `onServiceStart` | Must survive the app being backgrounded, killed, or never opened. |
| `pedestrianStatusStream` | `PedometerService`, main isolate | Different native channel, so no conflict. Nothing reads its output — it is subscribed purely because dropping it made step readings arrive in laggy batches. |

The app never touches the step sensor. `PedometerService` relays the service's
`stepUpdate` / `rawStep` broadcasts as ordinary Dart streams.

### Where the counting happens

`StepAccumulator` turns raw readings into daily and hourly totals, reaching
storage only through `StepStore` — which a test satisfies with four maps, so a
day, a reboot and an hour boundary run in milliseconds. Nearly every counting
bug this project has had lived in that logic while it was inline in
`onServiceStart` and unreachable from a test.

Three things are load-bearing:

- **The day's total is derived, not accumulated** — recomputed each reading as
  `(raw − baseline) × correctionFactor`. That is why a lost write is harmless,
  and why `ThrottledStepStore` can buffer writes at all.
- **A counter reset is detected against the previous reading, not the
  baseline.** The baseline goes negative after the first reboot of a day, and
  nothing falls below a negative number — comparing against it misses a second
  reboot and reverts the day. The previous reading is persisted on every
  reading and never buffered.
- **The daily target and correction factor are mirrored to the service over
  `invoke`.** SharedPreferences gives each isolate a private copy, so a value
  the app writes is invisible there. `StepAccumulator` has no storage access
  for the factor, making a re-read impossible rather than merely discouraged.

### Key files

```
lib/
├── main.dart                    — entry point; service init order matters
├── models/                      — daily_steps, hourly_steps, saved_route
├── services/
│   ├── background_service.dart  — sole step-count listener; foreground config
│   ├── step_accumulator.dart    — the counting: StepAccumulator, StepStore
│   ├── pedometer_service.dart   — main-isolate bridge to the service
│   ├── notification_service.dart
│   ├── database_helper.dart     — sqflite: history, routes, sessions
│   ├── preferences_service.dart — target, calibration, baseline, last raw
│   ├── metrics.dart             — step → distance/calories/time
│   └── providers.dart           — Riverpod wiring
├── screens/                     — home_page, routes_page
└── widgets/                     — ring, cards, dialogs, charts/

test/                            — ~90 tests, no device needed
```

## Setup

```
flutter pub get
flutter test
```

The tests need no device or sensor: step accounting runs against an in-memory
`StepStore`, and the database tests run sqflite on the host via
`sqflite_common_ffi` — including both schema migrations, the only part of this
codebase that can destroy history a user already has and the only part that
never runs during ordinary development.

### Android permissions & manifest

In `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_HEALTH" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
```

And inside `<application>`, an override on the plugin's own service
declaration — Android 14+ requires an explicit foreground service type:

```xml
<service
    android:name="id.flutter.flutter_background_service.BackgroundService"
    android:foregroundServiceType="health"
    tools:replace="android:exported" />
```

`tools:replace` needs `xmlns:tools="http://schemas.android.com/tools"` on the
root `<manifest>` tag.

**The type must be `health`.** Android refuses to start a `dataSync` foreground
service from `BOOT_COMPLETED`, and throws rather than declining: the service
dies in `onCreate` before Flutter starts, the plugin's watchdog restarts it
into the same wall, and the OS shows "Roamfree keeps stopping" with nothing in
logcat. It only fires on boot-initiated starts, so opening the app by hand
always looks fine. The same type is set in `AndroidConfiguration` so the two
can't drift apart.

### App icon

`dart run flutter_launcher_icons`, configured in `pubspec.yaml`. The adaptive
foreground/background split is deliberate — a flat square logo without one gets
shrunk by Android's icon masking.

## Building a release

Releases are signed with a real keystore rather than Flutter's debug key, so
Android treats successive builds as in-place updates and testers keep their
history. Credentials live in `android/key.properties`, **not committed** —
without it `build.gradle.kts` falls back to debug signing and silently breaks
updates for anyone who already has the app installed.

```
./scripts/release.sh [patch|minor|major]
```

It runs `flutter analyze` and `flutter test` first and stops on either. A
release goes straight onto testers' phones with no store review, so this is the
only gate there is, and it fails before the build, before the counters advance
and before anything is pushed.

On success it advances `android/next_build_number.txt` and
`android/next_version_name.txt`, writes the released version back to
`pubspec.yaml`, and produces a per-version APK (`roamfree_0.3.0.apk`) instead
of overwriting one file. The counter files hold the *next* version and are
committed, so everyone releasing stays in sync.

The release commit stages those three files by name and never `git add .` —
that swept whatever was untracked into release commits, which is how a Gradle
report ended up in the repo.

Testers install the APK directly. As long as the signing key and
`applicationId` stay consistent, it updates in place and preserves their data.

## Known limitations

- **iOS is unbuilt and untested.**
- **First launch needs the app opened by hand once.** Android holds
  freshly-installed apps in a "stopped" state that blocks the boot-completed
  broadcast until then. Auto-start works normally on later reboots.
- **Some OEM battery managers** (Xiaomi, Huawei, Oppo, Vivo, Samsung, OnePlus)
  kill background services more aggressively than stock Android. A tester
  reporting steps that stop overnight, with everything here configured
  correctly, is almost certainly hitting a battery whitelist rather than a bug.
- **Screen-off steps arrive in batches**, because the sensor buffers readings
  while the CPU sleeps. They are counted in full — the reading that delivers a
  batch carries all of it — but the display and notification lag until it
  lands.
- **An unclean reboot can lose up to ten seconds of steps.** Database writes
  are buffered and flushed on a timer; an ordinary kill costs nothing, since
  the next reading recomputes the total from the baseline, but a reboot
  re-derives the baseline *from* the stored total. Tune `flushInterval` in
  `ThrottledStepStore` to trade writes for precision.
