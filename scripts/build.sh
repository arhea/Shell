#!/usr/bin/env bash
# Builds Shell.app and prints only errors/warnings from our sources.
set -o pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-Debug}"
xcodegen generate --quiet
xcodebuild -project Shell.xcodeproj -scheme Shell -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build 2>&1 \
  | grep -E "^/.*(error|warning):|BUILD (SUCCEEDED|FAILED)" | grep -v "/Vendor/" | sort -u
