---
summary: "Packaging, signing, and bundled CLI notes."
read_when:
  - Packaging/signing builds
  - Updating bundle layout or CLI bundling
---

# Packaging & signing

## Scripts
- `Scripts/package_app.sh`: builds host arch with ad-hoc signing by default; set `ARCHES="arm64 x86_64"` for universal. Verifies slices. Stable-certificate packaging requires explicit `CODEXBAR_SIGNING=identity` plus `APP_IDENTITY`.
- `Scripts/install_latest_release.sh`: resolves the latest stable GitHub release, selects its exact universal app archive, and verifies the release version, bundle identifier, Developer ID authority, team, and Gatekeeper notarization before using the staged installer and Finder launch flow. It needs no local signing certificate; pass `--verify-only` to stop after verification or `--force` to reinstall the current official version.
- `Scripts/build_and_install.sh`: builds a release app by default and installs it as `/Applications/CodexBar.app`; pass `debug` for a debug build. It requires stable identity signing by default, derives the app-group team from that identity, rejects a mismatched `APP_TEAM_ID`, quits the running installed CodexBar instance before replacement, and leaves the app stopped. An explicit `CODEXBAR_SIGNING=adhoc` override remains available for disposable local testing, but replacing the production bundle identifier with an ad-hoc signature can invalidate app-group access and Tahoe menu bar attribution.
- `Scripts/build_install_and_run.sh`: runs the same staged installation flow, asks Finder to launch the newly installed `/Applications/CodexBar.app` through macOS LaunchServices, verifies the same process through a four-second startup grace period, and reports a matching Control Center blocked-status-item log. The previous bundle remains available until this check passes and is restored if launch validation fails.
- `Scripts/pull_build_install_and_run.sh`: runs `git pull --ff-only` and invokes `build_install_and_run.sh` unless the recorded commit/configuration still matches the installed bundle's signed identifier and embedded `CodexGitCommit`. Failed, deleted, or externally replaced installs are retried instead of being skipped.
- `Scripts/compile_and_run.sh`: uses host arch; pass `--release-universal` or `--release-arches="arm64 x86_64"` for release packaging.
- `Scripts/sign-and-notarize.sh`: explicitly selects Developer ID signing, notarizes, staples, and zips (accepts `ARCHES` for universal).
- `Scripts/make_appcast.sh`: wrapper around the shared `mac-release make-appcast` helper; app metadata comes from `.mac-release.env`.
- `Scripts/changelog-to-html.sh`: converts the per-version changelog section to HTML for Sparkle.

## Tahoe menu bar attribution

macOS Tahoe can attribute a status item to the application that launched it. If CodexBar is opened from a terminal
whose **System Settings → Menu Bar → Allow in the Menu Bar** switch is off, Control Center can keep CodexBar's
status item under that disabled terminal even while CodexBar's own switch is on. In Console this appears as:

```text
Moving host to blocked list; (bid:com.steipete.codexbar-…)
```

`build_install_and_run.sh` delegates the launch to Finder to avoid creating terminal attribution. If stale attribution
already exists, back up
`~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`
before removing CodexBar from another application's `menuItemLocations`. Do not automate edits to this private
Control Center state; its format is undocumented and macOS-version-specific. See CodexBar issue #1945 for the
known Tahoe failure mode and recovery details.

## Bundle contents
- `CodexBarWidget.appex` is built by `WidgetExtension/CodexBarWidgetExtension.xcodeproj` as a real macOS app extension, then bundled with app-group entitlements.
- `CodexBarCLI` copied to `CodexBar.app/Contents/Helpers/` for symlinking.
- SwiftPM resource bundles (e.g. `KeyboardShortcuts_KeyboardShortcuts.bundle`) copied into `Contents/Resources` (required for `KeyboardShortcuts.Recorder`).

## Releases
- Full checklist in `docs/RELEASING.md`.

See also: `docs/sparkle.md`.
