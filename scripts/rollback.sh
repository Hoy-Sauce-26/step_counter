#!/bin/bash
set -e

BUILD_NUMBER_FILE="android/next_build_number.txt"
VERSION_NAME_FILE="android/next_version_name.txt"

# 1. Verify tracking files exist
if [ ! -f "$BUILD_NUMBER_FILE" ] || [ ! -f "$VERSION_NAME_FILE" ]; then
  echo "Error: Version tracking files not found."
  exit 1
fi

CURRENT_BUILD_NUMBER=$(cat "$BUILD_NUMBER_FILE")
CURRENT_VERSION_NAME=$(cat "$VERSION_NAME_FILE")

# 2. Parse SemVer (Major.Minor.Patch)
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION_NAME"

# 3. Safety checks to prevent negative values
if [ "$CURRENT_BUILD_NUMBER" -le 1 ]; then
  echo "Error: Build number is already at minimum (1). Cannot decrement."
  exit 1
fi

if [ "$PATCH" -le 0 ]; then
  echo "Error: Patch version is already at 0 (${CURRENT_VERSION_NAME}). Cannot decrement automatically."
  exit 1
fi

# 4. Calculate decremented values
NEW_BUILD_NUMBER=$((CURRENT_BUILD_NUMBER - 1))
NEW_PATCH=$((PATCH - 1))
NEW_VERSION_NAME="${MAJOR}.${MINOR}.${NEW_PATCH}"

# 5. Locate and delete the generated artifact for this version (if it exists)
TARGET_APK="build/app/outputs/flutter-apk/roamfree_${NEW_VERSION_NAME}.apk"

if [ -f "$TARGET_APK" ]; then
  echo "Found previous build artifact: $TARGET_APK"
  rm -f "$TARGET_APK"
  echo "Artifact deleted successfully."
else
  echo "No artifact found at $TARGET_APK (skipping deletion)."
fi

# 6. Update tracking files
echo "$NEW_BUILD_NUMBER" > "$BUILD_NUMBER_FILE"
echo "$NEW_VERSION_NAME" > "$VERSION_NAME_FILE"

echo "Reverted next build targets to: Version $NEW_VERSION_NAME, Build $NEW_BUILD_NUMBER"

# 7. Sync changes to Git
git add "$BUILD_NUMBER_FILE" "$VERSION_NAME_FILE"
git commit -m "Revert release counter to version $NEW_VERSION_NAME (build $NEW_BUILD_NUMBER)"
git push --set-upstream origin "$(git rev-parse --abbrev-ref HEAD)"

echo "Done — rolled back to v$NEW_VERSION_NAME (build $NEW_BUILD_NUMBER)."
