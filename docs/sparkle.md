---
summary: "Sparkle integration details for CodexBar: updater config, keys, and release flow."
read_when:
  - Touching Sparkle settings, feed URL, or keys
  - Generating or troubleshooting the Sparkle appcast
  - Validating update toggles or updater UI
---

# Sparkle integration

- Framework: Sparkle 2.8.1 via SwiftPM.
- Updater: `SPUStandardUpdaterController` owned by `AppDelegate` (see `CodexbarApp.swift`).
- Feed: `SUFeedURL` in Info.plist points to GitHub Releases appcast (`appcast.xml`).
- Key: `SUPublicEDKey` set to `AGCY8w5vHirVfGGDGc8Szc5iuOqupZSh9pMj/Qs67XI=`. Keep the Ed25519 private key safe; use it when generating the appcast.
- UI: menu items “Check for Updates…” and “Automatically check for updates” (toggle). Auto-check enabled by default.
- LSUIElement: works; updater window will show when checking. App is non-sandboxed.

## Release flow
1) Build & notarize as usual (`./Scripts/sign-and-notarize.sh`), producing notarized `CodexBar-<ver>.zip`.
2) Generate appcast entry with Sparkle `generate_appcast` using the Ed25519 private key; point to the notarized zip.
3) Upload `appcast.xml` + zip to GitHub Releases (feed URL stays stable).
4) Tag/release.

## Notes
- If you change the feed host or key, update Info.plist (`SUFeedURL`, `SUPublicEDKey`) and bump the app.
- Auto-check toggle is persisted via Sparkle; “Check for Updates…” available from the menu.
