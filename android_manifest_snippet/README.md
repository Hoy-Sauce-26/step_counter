# Android setup

Add this permission inside the `<manifest>` tag (above `<application>`) in
`android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />
```

Minimum SDK: the `pedometer` plugin requires `minSdkVersion 19` or higher
(set in `android/app/build.gradle`, under `defaultConfig`). Most current
Flutter projects already default to 21+, so you likely don't need to change
anything, just confirm it's not lower than 19.

No further Gradle changes are needed — `ACTIVITY_RECOGNITION` is a normal
(not dangerous-at-install) runtime permission on Android 10+, and the app
requests it at runtime via `permission_handler` (see `lib/services/
pedometer_service.dart`).
