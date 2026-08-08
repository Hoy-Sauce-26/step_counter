# Step Counter

A simple Flutter step counter app: live step tracking, daily target
progress, distance/calorie/time estimates, and 7-day / monthly / yearly
charts. Built from `step_counter_implementation_plan.md`.

## Setup

1. Copy this whole `step_counter/` folder into `/Users/matt/dev/prompt/`
   (or create a fresh Flutter project there with `flutter create step_counter`
   and copy the `lib/` folder and `pubspec.yaml` over it).
2. From inside the project folder:
   ```bash
   flutter pub get
   ```
3. **Android:** open `android/app/src/main/AndroidManifest.xml` and add the
   permission described in `android_manifest_snippet/README.md`.
4. **iOS:** open `ios/Runner/Info.plist` and add the key described in
   `ios_snippet/README.md`.
5. Run on a physical device (the pedometer sensor doesn't work in the iOS
   Simulator, and Android emulators generally have no step sensor either —
   test on real hardware):
   ```bash
   flutter run
   ```

## What's implemented (mapped to the plan's phases)

- **Phase 1** — `pubspec.yaml` has `pedometer`, `permission_handler`,
  `shared_preferences`, `sqflite`, `fl_chart`, `flutter_riverpod`.
- **Phase 2** — `lib/models/daily_steps.dart` (data model) and
  `lib/services/database_helper.dart` (sqflite: upsert today, past-N-days,
  month records, yearly monthly totals). `lib/services/
  preferences_service.dart` stores `dailyTarget` (default 10,000).
- **Phase 3** — `lib/services/pedometer_service.dart` listens to
  `Pedometer.stepCountStream`, establishes a per-day baseline so the raw
  (since-reboot) sensor value becomes "steps since midnight," and persists
  every update to SQLite.
- **Phase 4** — `lib/screens/home_page.dart` + `lib/widgets/
  step_progress_ring.dart` (circular progress, clamped at 100%) +
  `lib/widgets/metric_card.dart` (Distance/Calories/Time, using the
  formulas in `lib/services/metrics.dart`) + `lib/widgets/
  edit_target_dialog.dart` for customizing the target.
- **Phase 5** — `lib/screens/analytics_page.dart` wires up
  `weekly_bar_chart.dart` (7-day bars + average line),
  `monthly_bar_chart.dart` (day-of-month bars), and
  `yearly_bar_chart.dart` (month bars as % of `dailyTarget * daysInMonth`,
  with a 100% reference line).

## Notes / things worth knowing

- The pedometer plugin reports a value that's cumulative since the device's
  last reboot — it does **not** reset at midnight on its own. The baseline
  logic in `pedometer_service.dart` is what converts that into "today's
  steps," and it's also what makes the count survive an app restart
  mid-day without jumping or resetting.
- Charts and metric cards are all driven off real data from the local
  SQLite database — nothing is hardcoded/mocked.
- This was written without a local Flutter SDK to compile against (the
  sandbox this was built in has no Flutter toolchain and no network
  access), so treat `flutter pub get` + a first `flutter run` as the real
  correctness check — happy to fix anything that surfaces.
