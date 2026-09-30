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

[`scripts/release.sh`](../scripts/release.sh) builds Release for arm64 and verifies the signature, including hardened runtime and secure timestamp. It then notarizes, staples, checks with `spctl`, and writes `build/dist/Shell-<version>-<build>.zip`.

| Flag | Effect |
| --- | --- |
| `--install` | Also copy the app to `/Applications` |
| `--skip-notarize` | Sign only (for local testing) |

3. Publish it with `gh release`: create a draft release from the changelog, attach the zip and its SHA-256 checksum, push the release commit to `main`, then publish the draft so it tags `v<version>`. The exact commands are in the **Releasing a new version** section of [`CLAUDE.md`](../CLAUDE.md).

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
