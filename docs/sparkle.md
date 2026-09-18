---
summary: "Sparkle integration details for CodexBar: updater config, keys, and release flow."
read_when:
  - Touching Sparkle settings, feed URL, or keys
  - Generating or troubleshooting the Sparkle appcast
  - Validating update toggles or updater UI
---

# Sparkle integration

- Framework: Sparkle 2.9.6 via SwiftPM.
- Updater: `SPUStandardUpdaterController` owned by `AppDelegate` (see `Sources/CodexBar/CodexbarApp.swift:1`).
- Feed: `SUFeedURL` in Info.plist points to GitHub Releases appcast (`appcast.xml`).
- Key: `SUPublicEDKey` set to `AGCY8w5vHirVfGGDGc8Szc5iuOqupZSh9pMj/Qs67XI=`. Keep the Ed25519 private key safe; use it when generating the appcast.
- UI: auto-check toggle (About) enables auto-downloads; menu only shows “Update ready, restart now?” once an update is downloaded. Both that action and About → Check for Updates open Sparkle's update UI, including its install confirmation for a staged update.
- LSUIElement: works; updater window will show when checking. App is non-sandboxed.
- Channels: stable vs beta are served from the same appcast. Beta items are tagged with `sparkle:channel="beta"`; About → Update Channel controls `allowedChannels`.

## Release flow
1) Build & notarize as usual (`./Scripts/sign-and-notarize.sh`), producing notarized `CodexBar-macos-universal-<ver>.zip`.
2) Generate appcast entry with Sparkle `generate_appcast` using the Ed25519 private key; HTML release notes come from `CHANGELOG.md` via `Scripts/changelog-to-html.sh`. For beta releases: set `SPARKLE_CHANNEL=beta` to tag the entry.
3) Upload `appcast.xml` + zip to GitHub Releases (feed URL stays stable).
4) Tag/release.

## Notes
- HTML release notes are embedded in the appcast entry; the Sparkle update dialog should show formatted bullets (not raw tags).
- If you change the feed host or key, update Info.plist (`SUFeedURL`, `SUPublicEDKey`) and bump the app.
- Auto-check toggle is persisted via Sparkle; manual “Check for Updates…” remains in About.
- Sparkle retains installation control after a background download. The install-on-quit delegate records update readiness and returns `false`; returning `true` stalls Sparkle's update session and causes manual checks to do nothing. Dismissing a downloaded or staged installation keeps the update-ready menu action available.
- CodexBar disables Sparkle in Homebrew and unsigned builds; those installs should be updated via `brew` or reinstalling from Releases.
- Homebrew detection follows the Caskroom artifact symlink to the installed app, including apps moved into `/Applications`; separate app copies remain eligible for Sparkle.
