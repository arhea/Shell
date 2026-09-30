#!/usr/bin/env bash
# Builds a Developer ID-signed, notarized Shell.app.
#
#   ./scripts/release.sh               build, sign, notarize, staple, zip
#   ./scripts/release.sh --install     …and copy to /Applications
#   ./scripts/release.sh --skip-notarize
#
# One-time setup: a "Developer ID Application" certificate for the team in
# project.yml (DEVELOPMENT_TEAM) in the login keychain, and notarization
# credentials (see docs/releasing.md):
#
#   xcrun notarytool store-credentials shell-notary \
#     --apple-id <your-apple-id> --team-id <TEAM_ID>
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-shell-notary}"
DERIVED=build/DerivedData
APP="$DERIVED/Build/Products/Release/Shell.app"
DIST=build/dist
install=0 notarize=1
for arg in "$@"; do
    case $arg in
        --install) install=1 ;;
        --skip-notarize) notarize=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

step() { printf '\n==> %s\n' "$*"; }

step "Building Release"
xcodegen generate --quiet
xcodebuild -project Shell.xcodeproj -scheme Shell -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build -quiet 2>&1 \
    | grep -Ev "^$|DVTPlugIn|CoreSimulator|Details:|Expected in:|NSLocalized|UserInfo" || true
[[ -d $APP ]] || { echo "build failed: $APP missing" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")

step "Verifying signature"
codesign --verify --strict --deep --verbose=1 "$APP"
info=$(codesign -dvv "$APP" 2>&1)
grep -q "Authority=Developer ID Application" <<<"$info" || { echo "not signed with Developer ID" >&2; exit 1; }
grep -q "flags=.*runtime" <<<"$info" || { echo "hardened runtime missing" >&2; exit 1; }
grep -q "Timestamp=" <<<"$info" || { echo "secure timestamp missing" >&2; exit 1; }
grep -E "Authority=Developer ID Application|TeamIdentifier" <<<"$info"
# Notarization rejects the debugger entitlement; catch it before uploading.
while IFS= read -r bin; do
    if codesign -d --entitlements - "$bin" 2>/dev/null | grep -q "get-task-allow"; then
        echo "get-task-allow entitlement present in $bin" >&2; exit 1
    fi
done < <(find "$APP" -type f -perm -u+x -path "*/MacOS/*")

mkdir -p "$DIST"
ZIP="$DIST/Shell-$VERSION-$BUILD.zip"
rm -f "$ZIP"

if (( notarize )); then
    step "Notarizing (this usually takes a few minutes)"
    ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
    # notarytool exits 0 even when Apple rejects the upload; check the status
    # and show the rejection log instead of failing later at stapling.
    result=$(xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)
    rm -f "$DIST/notarize.zip"
    if ! grep -q "status: Accepted" <<<"$result"; then
        id=$(awk '/^  id:/ { print $2; exit }' <<<"$result")
        echo "notarization failed; Apple's log:" >&2
        [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
        exit 1
    fi
    step "Stapling"
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

step "Packaging"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$ZIP"

if (( install )); then
    step "Installing to /Applications"
    if pgrep -xq Shell && pgrep -f "/Applications/Shell.app/Contents/MacOS/Shell" >/dev/null; then
        echo "Shell is running from /Applications; quit it first (it restores your tabs)." >&2
        exit 1
    fi
    rm -rf /Applications/Shell.app
    ditto "$APP" /Applications/Shell.app
    echo "/Applications/Shell.app ($VERSION build $BUILD)"
fi
