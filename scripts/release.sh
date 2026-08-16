#!/bin/bash
set -e

RELEASE_TYPE="${1:-patch}"
if [[ "$RELEASE_TYPE" != "patch" && "$RELEASE_TYPE" != "minor" && "$RELEASE_TYPE" != "major" ]]; then
  echo "Error: release type must be 'patch', 'minor', or 'major' (got '$RELEASE_TYPE')."
  echo "Usage: $0 [patch|minor|major]"
  exit 1
fi

BUILD_NUMBER_FILE="android/next_build_number.txt"
VERSION_NAME_FILE="android/next_version_name.txt"

if [ ! -f "$BUILD_NUMBER_FILE" ]; then
  echo 1 > "$BUILD_NUMBER_FILE"
fi
if [ ! -f "$VERSION_NAME_FILE" ]; then
  echo "0.0.1" > "$VERSION_NAME_FILE"
fi

BUILD_NUMBER=$(cat "$BUILD_NUMBER_FILE")
VERSION_NAME=$(cat "$VERSION_NAME_FILE")

IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION_NAME"
case "$RELEASE_TYPE" in
  "major")
    ((MAJOR+=1))
    MINOR=0
    PATCH=0
    ;;
  "minor")
    ((MINOR+=1))
    PATCH=0
    ;;
esac

VERSION_NAME="${MAJOR}.${MINOR}.${PATCH}"

echo "Building release APK — version $VERSION_NAME, build number $BUILD_NUMBER..."
flutter build apk --release \
  --build-number="$BUILD_NUMBER" \
  --build-name="$VERSION_NAME"

mv build/app/outputs/flutter-apk/app-release.apk build/app/outputs/flutter-apk/roamfree_"$VERSION_NAME".apk

# Only advance the counters after a successful build, so a failed build
# doesn't burn a number or bump the version.
echo $((BUILD_NUMBER + 1)) > "$BUILD_NUMBER_FILE"

echo "${MAJOR}.${MINOR}.$((PATCH + 1))" > "$VERSION_NAME_FILE"

git add "$BUILD_NUMBER_FILE" "$VERSION_NAME_FILE"
git commit -m "Released version $VERSION_NAME"
git push --set-upstream origin "$(git rev-parse --abbrev-ref HEAD)"

echo "Done — v$VERSION_NAME (build $BUILD_NUMBER) at build/app/outputs/flutter-apk/roamfree_${VERSION_NAME}.apk"
