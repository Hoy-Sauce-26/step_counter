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

The main app never talks to the step-count sensor directly. `PedometerService`
listens to the background service's `stepUpdate` / `rawStep` broadcasts
(`FlutterBackgroundService().on(...)`) and exposes those as normal Dart
streams for the UI and calibration test to consume.

### Key files

```
lib/
├── main.dart                        — app entry point, service init order matters here
├── models/
│   └── daily_steps.dart             — {date, stepCount} record
├── services/
│   ├── background_service.dart      — owns the sole step-count listener; foreground service config
│   ├── pedometer_service.dart       — main-isolate bridge; reads background service broadcasts
│   ├── notification_service.dart    — the persistent notification (flutter_local_notifications)
│   ├── database_helper.dart         — sqflite: daily step history
│   ├── preferences_service.dart     — shared_preferences: daily target, calibration factor
│   ├── metrics.dart                 — step → distance/calories/time formulas
│   └── providers.dart               — Riverpod providers wiring the above together
├── screens/
│   └── home_page.dart               — the whole UI: ring, metric cards, 7-day chart
└── widgets/
    ├── step_progress_ring.dart
    ├── metric_card.dart
    ├── edit_target_dialog.dart
    ├── calibration_dialog.dart
    ├── calibration_test_dialog.dart
    └── charts/weekly_bar_chart.dart
```

## Setup

```
flutter pub get
```

### Android permissions & manifest

These need to already be present in `android/app/src/main/AndroidManifest.xml`
(all were added incrementally — if you're setting this up fresh on another
machine, check they're all there):

```xml
<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
```

And, inside `<application>`, an override on the background service plugin's
own service declaration (required on Android 14+, which enforces explicit
foreground service types):

```xml
<service
    android:name="id.flutter.flutter_background_service.BackgroundService"
    android:foregroundServiceType="dataSync"
    tools:replace="android:exported" />
```

(`tools:replace` requires `xmlns:tools="http://schemas.android.com/tools"`
on the root `<manifest>` tag.)

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
   ./scripts/release.sh
   ```
   This auto-increments both the build number (`android/build_number.txt`)
   and the patch version (`android/version_name.txt`) on every successful
   build, and outputs a uniquely-named APK per version (e.g.
   `version0.0.3.apk`) to `build/app/outputs/flutter-apk/`, rather than
   overwriting the same file each time.
3. Both counter files **are** committed — they're shared state, not
   secrets, so everyone releasing from this repo stays in sync.

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
- **Steps taken with the screen off for extended periods may arrive in a
  batch** rather than in real time, due to how the hardware step sensor
  buffers data while the CPU sleeps — the background service processes and
  persists them as soon as the next reading arrives, but there can be a
  short visible lag.
