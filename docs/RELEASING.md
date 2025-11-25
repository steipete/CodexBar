---
summary: "CodexBar release checklist: package, sign, notarize, appcast, and asset validation."
read_when:
  - Starting a CodexBar release
  - Updating signing/notarization or appcast steps
  - Validating release assets or Sparkle feed
---

# Release process (CodexBar)

SwiftPM-only; package/sign/notarize manually (no Xcode project). Sparkle feed is served from GitHub Releases. Checklist below merges Trimmy’s release flow with CodexBar specifics.

**Must read first:** open the master macOS release guide at `~/Projects/agent-scripts/docs/RELEASING-MAC.md` alongside this file and reconcile any differences in favor of CodexBar specifics before starting a release.

## Expectations
- When someone says “release CodexBar”, do the entire end-to-end flow: bump versions/CHANGELOG, build, sign and notarize, upload the zip to the GitHub release, generate/update the appcast with the new signature, publish the tag/release, and verify the enclosure URL responds with 200/OK and installs via Sparkle (no 404s or stale feeds).

## Prereqs
- Xcode 26+ installed at `/Applications/Xcode.app` (for ictool/iconutil and SDKs).
- Developer ID Application cert installed: `Developer ID Application: Peter Steinberger (Y5PE65HELJ)`.
- ASC API creds in env: `APP_STORE_CONNECT_API_KEY_P8`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`.
- Sparkle keys: public key already in Info.plist; private key path set via `SPARKLE_PRIVATE_KEY_FILE` when generating appcast.

## Icon (glass .icon → .icns)
```
./Scripts/build_icon.sh Icon.icon CodexBar
```
Uses Xcode’s `ictool` + transparent padding + iconset → Icon.icns.

## Build, sign, notarize (arm64)
```
./Scripts/sign-and-notarize.sh
```
What it does:
- `swift build -c release --arch arm64`
- Packages `CodexBar.app` with Info.plist and Icon.icns
- Embeds Sparkle.framework, Updater, Autoupdate, XPCs
- Codesigns **everything** with runtime + timestamp (deep) and adds rpath
- Zips to `CodexBar-<version>.zip`
- Submits to notarytool, waits, staples, validates

Gotchas fixed:
- Sparkle needs signing for framework, Autoupdate, Updater, XPCs (Downloader/Installer) or notarization fails.
- Use `--timestamp` and `--deep` when signing the app to avoid invalid signature errors.
- Avoid `unzip` — it can add AppleDouble `._*` files that break the sealed signature and trigger “app is damaged”. Use Finder or `ditto -x -k CodexBar-<ver>.zip /Applications`. If Gatekeeper complains, delete the app bundle, re-extract with `ditto`, then `spctl -a -t exec` to verify.
- Manual sanity check before uploading: `find CodexBar.app -name '._*'` should return nothing; then `spctl --assess --type execute --verbose CodexBar.app` and `codesign --verify --deep --strict --verbose CodexBar.app` should both pass on the packaged bundle.

## Appcast (Sparkle)
After notarization:
```
SPARKLE_PRIVATE_KEY_FILE=/path/to/ed25519-priv.key \
./Scripts/make_appcast.sh CodexBar-0.1.0.zip \
  https://raw.githubusercontent.com/steipete/CodexBar/main/appcast.xml
```
Uploads not handled automatically—commit/publish appcast + zip to the feed location (GitHub Releases/raw URL).

## Tag & release
```
git tag v<version>
./Scripts/make_appcast.sh ...
# upload zip + appcast to Releases
# then create GitHub release (gh release create v<version> ...)
```

## Checklist (quick)
- [ ] Read both this file and `~/Projects/agent-scripts/docs/RELEASING-MAC.md`; resolve any conflicts toward CodexBar’s specifics.
- [ ] Update versions (scripts/Info.plist, CHANGELOG, About text)
- [ ] `swiftformat`, `swiftlint`, `swift test` (zero warnings/errors)
- [ ] `./Scripts/build_icon.sh` if icon changed
- [ ] `./Scripts/sign-and-notarize.sh`
- [ ] Generate Sparkle appcast with private key
  - Sparkle ed25519 private key path: `/Users/steipete/Library/CloudStorage/Dropbox/Backup/Sparkle/sparkle-private-key-KEEP-SECURE.txt` (primary) and `/Users/steipete/Library/CloudStorage/Dropbox/Backup/Sparkle-VibeTunnel/sparkle-private-key-KEEP-SECURE.txt` (older backup)
  - Upload the dSYM archive alongside the app zip on the GitHub release; the release script now automates this and will fail if it’s missing.
  - After publishing the release, run `Scripts/check-release-assets.sh <tag>` to confirm both the app zip and dSYM zip are present on GitHub.
  - Sign the zip with `sign_update --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" CodexBar-<ver>.zip`; use that exact signature and length in the appcast (no manual base64 copy/paste).
  - After generating the appcast, download the enclosure URL and re-run `sign_update --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" <downloaded.zip>`; abort if signature or length differs from the appcast.
- [ ] Upload zip + appcast to feed; publish tag + GitHub release so Sparkle URL is live (avoid 404)
- [ ] Version continuity: confirm the new version is the immediate next patch/minor (no gaps) and CHANGELOG has no skipped numbers (e.g., after 0.2.0 use 0.2.1, not 0.2.2)
- [ ] Changelog sanity: single top-level title, no duplicate version sections, versions strictly descending with no repeats
- [ ] Release pages: title format `CodexBar <version>`, notes as Markdown list (no stray blank lines)
- [ ] Changelog/release notes are user-facing: avoid internal-only bullets (build numbers, script bumps) and keep entries concise
- [ ] Download uploaded `CodexBar-<ver>.zip`, unzip via `ditto`, run, and verify signature (`spctl -a -t exec -vv CodexBar.app` + `stapler validate`)
- [ ] Confirm `appcast.xml` points to the new zip/version and renders correct release notes
- [ ] Verify on GitHub Releases: assets present (zip, appcast), release notes match changelog, version/tag correct
- [ ] Open the appcast URL in browser to confirm the new entry is visible and enclosure URL is reachable
- [ ] Manually visit the enclosure URL (curl -I) to ensure 200/OK (no 404) after publishing assets/release
- [ ] Ensure `sparkle:edSignature` is present for the enclosure in appcast (generate with `sign_update`/ed25519 key)
- [ ] When creating the GitHub release, paste the CHANGELOG entry as Markdown list (one `-` per line, blank line between sections); visually confirm bullets render correctly after publishing
- [ ] Keep a previous signed build in `/Applications/CodexBar.app` to test Sparkle delta/full update to the new release
- [ ] Manual Gatekeeper sanity: after packaging, `find CodexBar.app -name '._*'` is empty, `spctl --assess --type execute --verbose CodexBar.app` and `codesign --verify --deep --strict --verbose CodexBar.app` succeed
- [ ] For Sparkle verification: if replacing `/Applications/CodexBar.app`, quit first, replace, relaunch, and test update
- **Definition of “done” for a release:** all of the above are complete, the appcast/enclosure link resolves, and a previous public build can update to the new one via Sparkle. Anything short of that is not a finished release.

## Troubleshooting
- **White plate icon**: regenerate icns via `build_icon.sh` (ictool) to ensure transparent padding.
- **Notarization invalid**: verify deep+timestamp signing, especially Sparkle’s Autoupdate/Updater and XPCs; rerun package + sign-and-notarize.
- **App won’t launch**: ensure Sparkle.framework is embedded under `Contents/Frameworks` and rpath added; codesign deep.
- **App “damaged” dialog after unzip**: re-extract with `ditto -x -k`, removing any `._*` files, then re-verify with `spctl`.
- **Update download fails (404)**: ensure the release asset referenced in appcast exists and is published in the corresponding GitHub release; verify with `curl -I <enclosure-url>`.
