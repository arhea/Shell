#!/usr/bin/env bash
# Builds libghostty (GhosttyKit.xcframework) from a pinned Ghostty commit and
# stages the runtime resources (themes, shell integration, terminfo) that the
# app bundles. Safe to re-run; skips work that is already done.
set -euo pipefail

GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
GHOSTTY_COMMIT="d67ab3213ea272a51b0aecffdc1c5704d7b9b2fe"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
SRC="$VENDOR/ghostty"
FORCE="${1:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required ($2)" >&2; exit 1; }; }
need xcodegen "brew install xcodegen"
need git "xcode-select --install"

if [[ ! -d "$SRC/.git" ]]; then
  echo "==> Fetching Ghostty @ ${GHOSTTY_COMMIT:0:10}"
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$GHOSTTY_REPO"
fi
if [[ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$GHOSTTY_COMMIT" ]]; then
  git -C "$SRC" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
  git -C "$SRC" checkout -q FETCH_HEAD
fi

STAMP="$VENDOR/.ghostty-built-$GHOSTTY_COMMIT"
if [[ -f "$STAMP" && -d "$VENDOR/GhosttyKit.xcframework" && "$FORCE" != "--force" ]]; then
  echo "==> libghostty already built for ${GHOSTTY_COMMIT:0:10} (use --force to rebuild)"
else
  # Zig and the Metal toolchain are only needed to build libghostty, so a
  # cached build (CI, or a re-run) skips them.
  need zig "brew install zig"
  if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "==> Installing the Metal toolchain (required to compile Ghostty's shaders)"
    xcodebuild -downloadComponent MetalToolchain
  fi

  echo "==> Prefetching Zig dependencies"
  # Zig's own fetcher occasionally fails TLS setup when many downloads run in
  # parallel, so warm the global cache one package at a time with retries.
  while read -r url; do
    [[ -z "$url" ]] && continue
    for attempt in 1 2 3; do
      zig fetch "$url" >/dev/null 2>&1 && break
      [[ $attempt == 3 ]] && echo "warning: prefetch failed for $url (zig build will retry)" >&2
      sleep 1
    done
  done < "$SRC/build.zig.zon.txt"

  echo "==> Building GhosttyKit.xcframework (ReleaseFast, native arch)"
  (cd "$SRC" && zig build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native)

  rm -rf "$VENDOR/GhosttyKit.xcframework" "$VENDOR/GhosttyResources"
  cp -R "$SRC/macos/GhosttyKit.xcframework" "$VENDOR/GhosttyKit.xcframework"
  mkdir -p "$VENDOR/GhosttyResources"
  cp -R "$SRC/zig-out/share/ghostty" "$VENDOR/GhosttyResources/ghostty"
  cp -R "$SRC/zig-out/share/terminfo" "$VENDOR/GhosttyResources/terminfo"
  # Ghostty's default font, so the native input editor matches the terminal.
  mkdir -p "$VENDOR/GhosttyResources/fonts"
  cp "$SRC"/src/font/res/JetBrainsMonoNerdFont-{Regular,Bold,Italic,BoldItalic}.ttf "$VENDOR/GhosttyResources/fonts/"
  cp "$SRC/src/font/res/OFL.txt" "$VENDOR/GhosttyResources/fonts/JetBrainsMono-OFL.txt"
  rm -f "$VENDOR"/.ghostty-built-*
  touch "$STAMP"
fi

echo "==> Generating Xcode project"
(cd "$ROOT" && xcodegen generate --quiet)
echo "==> Done. Open Shell.xcodeproj or run: make run"
