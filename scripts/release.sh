#!/usr/bin/env bash
# Builds a Developer ID-signed, notarized Shell.app and packages it as a
# signed, notarized, stapled disk image for GitHub Releases.
#
#   ./scripts/release.sh               build, sign, notarize, staple, dmg
#   ./scripts/release.sh --install     …and copy to /Applications
#   ./scripts/release.sh --skip-notarize
#
# Output: build/dist/Shell-<version>.dmg and its .sha256.
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

# Submits a file to Apple's notary service and waits. notarytool exits 0 even
# when Apple rejects the upload, so check the status and show the rejection
# log instead of failing later at stapling.
notarize_file() {
    local result id
    result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)
    if ! grep -q "status: Accepted" <<<"$result"; then
        id=$(awk '/^  id:/ { print $2; exit }' <<<"$result")
        echo "notarization failed; Apple's log:" >&2
        [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
        exit 1
    fi
}

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

# Sign the disk image with the same Developer ID identity as the app.
TEAM=$(awk -F= '/^TeamIdentifier=/ { print $2 }' <<<"$info")
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' -v t="($TEAM)" 'index($2, "Developer ID Application") && index($2, t) { print $2; exit }')
[[ -n $IDENTITY ]] || { echo "no Developer ID Application identity for team $TEAM in the keychain" >&2; exit 1; }

mkdir -p "$DIST"

if (( notarize )); then
    # Notarize and staple the app itself first, so the copy a user drags out
    # of the disk image carries its own ticket and opens offline.
    step "Notarizing Shell.app (this usually takes a few minutes)"
    ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
    notarize_file "$DIST/notarize.zip"
    rm -f "$DIST/notarize.zip"
    step "Stapling Shell.app"
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

step "Creating disk image"
DMG="$DIST/Shell-$VERSION.dmg"
./scripts/make-dmg.sh "$APP" "$DMG" "$VERSION" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=1 "$DMG"

if (( notarize )); then
    step "Notarizing disk image"
    notarize_file "$DMG"
    step "Stapling disk image"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
step "Done: Shell $VERSION (build $BUILD)"
echo "$DMG"
echo "$DMG.sha256"

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
