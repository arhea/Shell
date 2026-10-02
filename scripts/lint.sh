#!/usr/bin/env bash
# SwiftFormat + SwiftLint for Shell. Configs: .swiftformat, .swiftlint.yml
# (Tests/.swiftlint.yml relaxes the force-unwrap rules for tests).
#
#   scripts/lint.sh               check formatting and lint (what CI runs)
#   scripts/lint.sh --fix         apply formatting, then lint
#   scripts/lint.sh --install DIR download the pinned tools into DIR (CI)
#
# Versions are pinned so a tool release can't change the rules under us.
# To bump: update the version and the SHA-256 of the release zip below, run
# `scripts/lint.sh --fix`, and commit the result with the bump.
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFTLINT_VERSION=0.65.1
SWIFTLINT_SHA256=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0 # portable_swiftlint.zip
SWIFTFORMAT_VERSION=0.63.1
SWIFTFORMAT_SHA256=385ef1a263ba28685157b98c5536b9c9105e124518f28b7ef8a2bee4b167eaeb # swiftformat.zip

install() {
  local dest=$1 tmp
  mkdir -p "$dest"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  fetch "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip" \
    "$SWIFTLINT_SHA256" "$tmp/swiftlint.zip"
  fetch "https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat.zip" \
    "$SWIFTFORMAT_SHA256" "$tmp/swiftformat.zip"
  unzip -oq "$tmp/swiftlint.zip" swiftlint -d "$dest"
  unzip -oq "$tmp/swiftformat.zip" swiftformat -d "$dest"
  "$dest/swiftlint" version
  "$dest/swiftformat" --version
}

fetch() {
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 --output "$3" "$1"
  echo "$2  $3" | shasum -a 256 --check --strict >/dev/null
}

require() {
  local tool=$1 want=$2 have
  if ! command -v "$tool" >/dev/null; then
    echo "error: $tool not found. Install it with: brew install $tool" >&2
    exit 1
  fi
  have=$("$tool" --version 2>/dev/null || "$tool" version)
  if [[ $have != "$want" ]]; then
    echo "warning: $tool $have is installed; CI uses $want, so results may differ." >&2
  fi
}

case "${1:-}" in
--install)
  install "${2:?usage: scripts/lint.sh --install DIR}"
  exit
  ;;
--fix)
  require swiftformat "$SWIFTFORMAT_VERSION"
  require swiftlint "$SWIFTLINT_VERSION"
  swiftformat --quiet .
  ;;
"")
  require swiftformat "$SWIFTFORMAT_VERSION"
  require swiftlint "$SWIFTLINT_VERSION"
  swiftformat --lint --quiet .
  ;;
*)
  echo "usage: scripts/lint.sh [--fix | --install DIR]" >&2
  exit 2
  ;;
esac

# Errors (crash and leak rules) fail; style warnings are reported only.
swiftlint lint --quiet
