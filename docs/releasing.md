# Releasing

Maintainer notes for producing a signed, notarized build. Contributors don't need any of this.

## One-time setup

1. Install a **Developer ID Application** certificate for your team (Xcode › Settings › Accounts › Manage Certificates).
2. Set `DEVELOPMENT_TEAM` in [`project.yml`](../project.yml) to your team ID.
3. Store notarization credentials with an [app-specific password](https://support.apple.com/102654):

```bash
xcrun notarytool store-credentials shell-notary --apple-id <your-apple-id> --team-id <TEAM_ID>
```

`scripts/release.sh` uses the `shell-notary` keychain profile by default. Override it with `NOTARY_PROFILE`.

## Cutting a release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml`.
2. Run:

```bash
make dist
```

[`scripts/release.sh`](../scripts/release.sh) builds Release for arm64 and verifies the signature, including hardened runtime and secure timestamp. It then notarizes and staples the app, packages it into a disk image with an `/Applications` shortcut, signs, notarizes and staples the disk image, and writes `build/dist/Shell-<version>.dmg` plus a `.sha256` checksum.

The disk image window is styled by [`scripts/make-dmg.sh`](../scripts/make-dmg.sh): a terminal-themed background rendered by [`scripts/dmg-background.swift`](../scripts/dmg-background.swift) (with the version printed in it), 128pt icons, and the app icon as the volume icon. The layout is applied through Finder with AppleScript, so the first run asks to let your terminal control Finder (System Settings › Privacy & Security › Automation). The build fails rather than shipping a plain window if Finder doesn't save the layout. To check the window without a release build, run `make dmg-preview`, which packages the Debug build unsigned and opens it.

| Flag | Effect |
| --- | --- |
| `--install` | Also copy the app to `/Applications` |
| `--skip-notarize` | Sign only, app and DMG (for local testing; the updater rejects un-notarized builds) |

3. Publish it with `gh release`: create a draft release from the changelog, attach the `.dmg` and its SHA-256 checksum as release assets (`gh release upload`), push the release commit to `main`, then publish the draft as the latest release so it tags `v<version>`. The exact commands are in the **Releasing a new version** section of [`CLAUDE.md`](../CLAUDE.md).

## What the auto-updater expects

Installed copies of Shell poll `GET https://api.github.com/repos/arhea/Shell/releases/latest` every six hours ([`SoftwareUpdater`](../Sources/Shell/Integrations/Updates/SoftwareUpdater.swift)). A release is picked up only when all of these hold:

| Requirement | Why |
| --- | --- |
| Published (not a draft), not a pre-release, and marked **Latest** | `/releases/latest` only returns that release |
| Tag is `v<version>` and `<version>` equals the app's `CFBundleShortVersionString` | The tag is compared with the running version (numeric SemVer), and the downloaded app must report the same version |
| Assets include `Shell-<version>.dmg` **and** `Shell-<version>.dmg.sha256` | The updater ignores a release until both exist, so uploading assets before publishing never serves a half-finished release |
| The app inside the DMG is signed by the same Developer ID team, notarized and stapled | The updater checks the signature requirement and `spctl` before staging it |

The staged update replaces the installed bundle after Shell quits (a detached helper swaps it with two renames and rolls back on failure; its output goes to `~/Library/Logs/Shell/update.log`). To test against a fork, launch a Release build with `SHELL_APP_UPDATE_REPOSITORY=<owner>/<repo>`. Development (ad-hoc signed) builds never check automatically or replace themselves.

Pulling a bad release: mark the previous release as **Latest** (or delete the bad one). Copies that already installed it stay on it until a newer version ships.

## Time Sensitive notifications

Shell marks "needs your input" alerts as Time Sensitive when the user opts in. macOS only honors this when the app is signed with the `com.apple.developer.usernotifications.time-sensitive` entitlement. Without it, the alerts arrive as normal notifications.

That entitlement needs a provisioning profile, so it isn't in the default entitlements. Debug builds are ad-hoc signed, and a profile-backed entitlement there would stop them from launching. To enable it in release builds:

1. In the Apple Developer portal, enable **Time Sensitive Notifications** for the `app.bethesdalabs.Shell` App ID, and create a Developer ID provisioning profile.
2. Add the entitlement and the profile to the **Release** configuration only, in `project.yml`.

## Entitlements

The app is hardened-runtime signed with these entitlements. The reasons matter for security review:

| Entitlement | Why |
| --- | --- |
| `com.apple.security.automation.apple-events` | Lets programs in the terminal use AppleScript (`osascript`), as in any terminal |
| `com.apple.security.device.audio-input`, `…device.camera` | Lets programs in the terminal ask for the microphone and camera |
| `com.apple.security.personal-information.addressbook`, `…calendars`, `…location`, `…photos-library` | Lets programs in the terminal ask for contacts, calendars, location and photos |

macOS attributes privacy prompts from child processes to the terminal app, so under the hardened runtime the terminal needs these entitlements for the programs it runs to be able to ask at all; the `NS*UsageDescription` strings in `Info.plist` are the prompts' text. This matches Ghostty.app.

Shell has **no** `allow-jit` (libghostty doesn't JIT) and **no** `disable-library-validation` in Release: those only relax checks on Shell's own process, which loads no third-party libraries. Programs you run in a tab have their own signatures and entitlements and aren't affected. Debug builds add `disable-library-validation` (`Resources/ShellDebug.entitlements`) because they're ad-hoc signed and load Xcode's debug dylibs.
