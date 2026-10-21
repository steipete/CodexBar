---
summary: "Sparkle integration details for CodexBar: updater config, keys, and release flow."
read_when:
  - Touching Sparkle settings, feed URL, or keys
  - Generating or troubleshooting the Sparkle appcast
  - Validating update toggles or updater UI
---

# Sparkle integration

- Framework: Sparkle 2.9.6 via SwiftPM.
- Updater: `SPUStandardUpdaterController` owned by `AppDelegate` in `CodexbarApp.swift`.
- Feed: `SUFeedURL` in Info.plist points to GitHub Releases appcast (`appcast.xml`).
- Key: `SUPublicEDKey` set to `AGCY8w5vHirVfGGDGc8Szc5iuOqupZSh9pMj/Qs67XI=`. Keep the Ed25519 private key safe; use it when generating the appcast.
- UI: auto-check toggle (About) enables auto-downloads; menu shows “Check for Updates…” when no update is staged, or “Update ready, restart now?” once an update is downloaded. These actions and About → Check for Updates open Sparkle's update UI, including its install confirmation for a staged update.
- LSUIElement: works; updater window will show when checking. App is non-sandboxed.
- Channels: stable vs beta are served from the same appcast. Prerelease items contain a `<sparkle:channel>beta</sparkle:channel>` element; About → Update Channel controls `allowedChannels`.

## Release flow

The [CI release workflow](https://github.com/steipete/CodexBar/blob/main/.github/workflows/release.yml) builds and notarizes the app, signs and verifies its appcast entry, publishes the verified assets, and updates the existing feed on main. See [the release process](RELEASING.md) for signed tags and no-publish dry runs. Prerelease versions such as `X.Y.Z-beta.N` stay on the opt-in beta channel and do not replace stable Homebrew packages.

## Notes
- HTML release notes are embedded in the appcast entry; the Sparkle update dialog should show formatted bullets (not raw tags).
- If you change the feed host or key, update Info.plist (`SUFeedURL`, `SUPublicEDKey`) and bump the app.
- Auto-check toggle is persisted via Sparkle; manual “Check for Updates…” remains in About.
- Sparkle retains installation control after a background download. The install-on-quit delegate records update readiness and returns `false`; returning `true` stalls Sparkle's update session and causes manual checks to do nothing. Dismissing a downloaded or staged installation keeps the update-ready menu action available.
- CodexBar disables Sparkle in Homebrew and unsigned builds; those installs should be updated via `brew` or reinstalling from Releases. Homebrew installs check their receipt's owning cask version daily (official or steipete/tap, when automatic checks are on) and offer a one-click `brew upgrade` from the menu and About.
- Homebrew detection follows the Caskroom artifact symlink to the installed app, including apps moved into `/Applications`; separate app copies remain eligible for Sparkle.
