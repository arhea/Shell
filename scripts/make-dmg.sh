#!/usr/bin/env bash
# Packages an app bundle into a compressed disk image with a styled Finder
# window: terminal-themed background, Shell.app on the left, an /Applications
# shortcut on the right, and the app icon as the volume icon.
#
#   ./scripts/make-dmg.sh <path/to/Shell.app> <out.dmg> [version]
#
# release.sh signs and notarizes the result. To preview the layout without a
# release build: `make dmg-preview`.
#
# The Finder layout is applied with AppleScript, so the first run asks for
# permission to control Finder (System Settings › Privacy & Security ›
# Automation).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${1:?usage: make-dmg.sh <Shell.app> <out.dmg> [version]}
DMG=${2:?usage: make-dmg.sh <Shell.app> <out.dmg> [version]}
VERSION=${3:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}
VOLNAME="Shell $VERSION"

# Window content size and icon centers; keep in sync with dmg-background.swift.
WIN_W=660 WIN_H=400 ICON_SIZE=128
APP_X=180 APPS_X=480 ICON_Y=190

[[ -d $APP ]] || { echo "no app bundle at $APP" >&2; exit 1; }
if [[ -d "/Volumes/$VOLNAME" ]]; then
    echo "a volume named \"$VOLNAME\" is already mounted; eject it first" >&2
    exit 1
fi

WORK=$(mktemp -d)
MOUNT=""
cleanup() {
    [[ -n $MOUNT ]] && hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Background at 1x and 2x, combined into one HiDPI TIFF that Finder picks
# the right resolution from.
mkdir -p "$WORK/stage/.background"
swift scripts/dmg-background.swift "$VERSION" "$WORK/bg.png" 1
swift scripts/dmg-background.swift "$VERSION" "$WORK/bg@2x.png" 2
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/stage/.background/background.tiff" 2>/dev/null

ditto "$APP" "$WORK/stage/Shell.app"
ln -s /Applications "$WORK/stage/Applications"

# Writable image with headroom for Finder's .DS_Store.
SIZE_MB=$(( $(du -sm "$WORK/stage" | cut -f1) + 20 ))
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$WORK/stage" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" -ov "$WORK/rw.dmg"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" \
    | awk -F'\t' '/\/Volumes\// { print $NF; exit }')
[[ -n $MOUNT ]] || { echo "failed to mount $WORK/rw.dmg" >&2; exit 1; }
DISK=$(basename "$MOUNT")

SetFile -a V "$MOUNT/.background"
# Placeholder so its position can be parked below; the real icon is copied in
# after the layout is saved.
touch "$MOUNT/.VolumeIcon.icns"

# Finder's bounds include the title bar; add it so the content area matches
# the background exactly.
TITLEBAR=28
osascript <<EOF
tell application "Finder"
    tell disk "$DISK"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H + TITLEBAR))}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to $ICON_SIZE
        set text size of opts to 13
        set label position of opts to bottom
        set shows item info of opts to false
        set shows icon preview of opts to true
        set background picture of opts to file ".background:background.tiff"
        set position of item "Shell.app" of container window to {$APP_X, $ICON_Y}
        set position of item "Applications" of container window to {$APPS_X, $ICON_Y}
        set extension hidden of item "Shell.app" to true
        -- Park helper files out of view for people who show hidden files.
        repeat with helper in {".background", ".VolumeIcon.icns", ".fseventsd"}
            try
                set position of item helper of container window to {$((WIN_W + 200)), $((WIN_H + 200))}
            end try
        end repeat
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

# Finder writes .DS_Store asynchronously and in stages; wait until the
# background is in it, or the image ships with a plain white window.
saved() { grep -q backgroundImageAlias "$MOUNT/.DS_Store" 2>/dev/null; }
for _ in {1..30}; do saved && break; sleep 0.5; done
saved || { echo "Finder didn't save the window layout" >&2; exit 1; }

# Volume icon. Set it after the Finder layout: Finder's `update` command
# deletes .VolumeIcon.icns on macOS 26.
rm -f "$MOUNT/.VolumeIcon.icns"
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
    SetFile -a V "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT"
fi
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach -quiet "$MOUNT" || hdiutil detach -quiet -force "$MOUNT"
MOUNT=""

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
# Compress. `hdiutil convert` fails with "Resource temporarily unavailable" on
# macOS 26, so use its replacement there and fall back on older systems.
if diskutil image create from -h >/dev/null 2>&1; then
    diskutil image create from --format UDZO "$WORK/rw.dmg" "$DMG" >/dev/null 2>"$WORK/diskutil.log" \
        || { cat "$WORK/diskutil.log" >&2; exit 1; }
else
    hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
fi
echo "$DMG"
