#!/usr/bin/env bash
# Renders the light and dark variants of Resources/AppIcon.icon to PNGs in the
# app bundle, so AppIcon.swift can show the variant that matches the active
# theme when it differs from the system appearance.
#
# Runs as a build phase (project.yml). Uses Icon Composer's ictool, which ships
# inside Xcode 26. If it's missing the build continues and the Dock keeps the
# system-appearance icon.
set -euo pipefail

ICON="$SRCROOT/Resources/AppIcon.icon"
OUT="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
ICTOOL="$DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool"

if [[ ! -x $ICTOOL ]]; then
  echo "warning: Icon Composer's ictool not found; the Dock icon won't follow the theme"
  exit 0
fi

mkdir -p "$OUT"
# 824 px is the icon body on macOS's 1024 px grid; AppIcon.swift adds the margin.
for rendition in Default Dark; do
  name=AppIconLight
  [[ $rendition == Dark ]] && name=AppIconDark
  "$ICTOOL" "$ICON" --export-image --output-file "$OUT/$name.png" --platform macOS \
    --rendition "$rendition" --width 412 --height 412 --scale 2 >/dev/null
done
