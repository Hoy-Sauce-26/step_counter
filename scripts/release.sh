#!/bin/bash
set -e

COUNTER_FILE="android/build_number.txt"

if [ ! -f "$COUNTER_FILE" ]; then
  echo 2 > "$COUNTER_FILE"
fi

BUILD_NUMBER=$(cat "$COUNTER_FILE")

echo "Building release APK — build number $BUILD_NUMBER..."
flutter build apk --release --build-number="$BUILD_NUMBER"

echo $((BUILD_NUMBER + 1)) > "$COUNTER_FILE"

echo "Done — build $BUILD_NUMBER at build/app/outputs/flutter-apk/app-release.apk"