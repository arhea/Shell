# Building from source

## Requirements

- macOS 26 (Tahoe) or later, on **Apple Silicon**. libghostty is built for the native architecture only.
- Xcode 26 or later (Swift 6 language mode; tested with Xcode 27 / Swift 6.4), with the command-line tools selected (`xcode-select -p`).
- Zig at the version the pinned Ghostty commit asks for (`minimum_zig_version` in `Vendor/ghostty/build.zig.zon`; 0.16 today).
- [Homebrew](https://brew.sh), for the two build tools:

```bash
brew install zig xcodegen
```

## Build and run

```bash
git clone <this-repo> Shell
```

```bash
cd Shell && make bootstrap
```

```bash
make run
```

`make bootstrap` runs [`scripts/bootstrap.sh`](../scripts/bootstrap.sh), which:

1. Clones Ghostty into `Vendor/ghostty` at the commit pinned in `GHOSTTY_COMMIT`.
2. Installs Apple's Metal toolchain if it's missing (`xcodebuild -downloadComponent MetalToolchain`).
3. Builds `GhosttyKit.xcframework` (ReleaseFast) and stages the runtime resources: themes, terminfo, shell integration and JetBrains Mono.
4. Generates `Shell.xcodeproj` with XcodeGen.

The first run takes about 3 minutes. After that, bootstrap skips the libghostty build unless the pinned commit changes. Everything it produces is git-ignored.

`Shell.xcodeproj` is generated from [`project.yml`](../project.yml). Change `project.yml`, not the project file, then run `make project`.

## Make targets

| Command | What it does |
| --- | --- |
| `make bootstrap` | Build libghostty and generate the Xcode project |
| `make project` | Regenerate `Shell.xcodeproj` from `project.yml` |
| `make build` / `make release` | Debug / Release build into `build/DerivedData` |
| `make run` | Debug build, then open the app |
| `make dist` | Developer ID-signed, notarized, stapled `.dmg` in `build/dist` (see [Releasing](releasing.md)) |
| `make dmg-preview` | Unsigned `.dmg` of the Debug build, opened in Finder, to check the installer window |
| `make install` | Same as `dist`, then copy to `/Applications` (quit Shell first) |
| `make clean` | Remove `build/` |
| `./scripts/build.sh` | Build and print only this project's errors and warnings |
| `xcodebuild -project Shell.xcodeproj -scheme Shell test` | Unit tests |

## Code signing for local builds

Debug builds are ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`), so you don't need an Apple Developer account to build and run Shell. `project.yml` sets `DEVELOPMENT_TEAM` to the maintainer's team. If Xcode complains about the team when you open the project, clear it in `project.yml` locally, or set your own.

Release builds (`make release`, `make dist`) need a Developer ID certificate. See [Releasing](releasing.md).

The desktop widget (`ShellWidgets.appex`, embedded in `Contents/PlugIns`) shares data with the app through the app group `T9PCKZ42NK.app.bethesdalabs.Shell`. The group ID is prefixed with the team ID, so Developer ID builds need no provisioning profile. Ad-hoc-signed Debug builds can still register the widget. If macOS asks whether Shell may access data from other apps, or the widget stays on *Shell isn't running*, test with a Release build (`make release`) instead. If you build under a different team, change `WidgetSnapshot.appGroup` and the three `.entitlements` files to match.

## Updating Ghostty

1. Change `GHOSTTY_COMMIT` in `scripts/bootstrap.sh`.
2. Run `./scripts/bootstrap.sh --force`.
3. Build. libghostty's embedding API (`include/ghostty.h`) isn't stable, so expect small fixes in `Sources/Shell/Ghostty/`.
4. Check `Vendor/ghostty/build.zig.zon` for dependency changes, and update [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
5. If `minimum_zig_version` in `Vendor/ghostty/build.zig.zon` changed, update the Zig `version` and `sha256` in [`.github/workflows/test.yml`](../.github/workflows/test.yml). Take the checksum for `aarch64-macos` from [ziglang.org/download/index.json](https://ziglang.org/download/index.json). CI rebuilds libghostty on the first run after the bump, because the cache is keyed by the Ghostty commit.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `error: 'zig' is required` | `brew install zig`. The Ghostty commit pins a Zig version, so check `Vendor/ghostty/build.zig.zon` (`minimum_zig_version`) if the build fails early. |
| Zig fetch errors or TLS failures | Re-run `make bootstrap`. Dependencies are prefetched one at a time with retries. |
| `metal: error: ... toolchain` | `xcodebuild -downloadComponent MetalToolchain` |
| Link errors after changing the Ghostty commit | `./scripts/bootstrap.sh --force` |
| The app launches without themes or shell integration | `Vendor/GhosttyResources` is missing. Re-run `make bootstrap`. |
