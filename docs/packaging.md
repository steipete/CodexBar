---
summary: "Packaging, signing, and bundled CLI notes."
read_when:
  - Packaging/signing builds
  - Updating bundle layout or CLI bundling
---

# Packaging & signing

## Scripts
- `Scripts/package_app.sh`: builds host arch with ad-hoc signing by default; set `ARCHES="arm64 x86_64"` for universal. Verifies slices. Stable-certificate packaging requires explicit `CODEXBAR_SIGNING=identity` plus `APP_IDENTITY`.
- `Scripts/compile_and_run.sh`: uses host arch; pass `--release-universal` or `--release-arches="arm64 x86_64"` for release packaging.
- `Scripts/sign-and-notarize.sh`: explicitly selects Developer ID signing, notarizes, staples, and zips (accepts `ARCHES` for universal).
- `Scripts/make_appcast.sh`: wrapper around the shared `mac-release make-appcast` helper; app metadata comes from `.mac-release.env`.
- `Scripts/changelog-to-html.sh`: converts the per-version changelog section to HTML for Sparkle.

## Optional ccusage fallback

CodexBar can use a locally supplied `ccusage` executable only when the native Codex history scan reports incomplete coverage. It never downloads the helper or searches `PATH`.

For a local run, set `CODEXBAR_CCUSAGE_PATH` to a vetted executable. For a packaged app, set `CODEXBAR_CCUSAGE_SOURCE`, `CODEXBAR_CCUSAGE_VERSION`, and `CODEXBAR_CCUSAGE_SHA256` while running `Scripts/package_app.sh`; the helper must contain every architecture in `ARCHES`, and its SHA-256 must match before it is copied to `Contents/Helpers/ccusage`. The package records the version and verified digest in `Contents/Helpers/ccusage.provenance`. Set `CODEXBAR_REQUIRE_CCUSAGE=1` to make packaging fail when the source or provenance metadata is missing. The fallback is best-effort: missing helpers, timeouts, invalid JSON, and non-zero exits retain the native result.

## Bundle contents
- `CodexBarWidget.appex` is built by `WidgetExtension/CodexBarWidgetExtension.xcodeproj` as a real macOS app extension, then bundled with app-group entitlements.
- `CodexBarCLI` copied to `CodexBar.app/Contents/Helpers/` for symlinking.
- SwiftPM resource bundles (e.g. `KeyboardShortcuts_KeyboardShortcuts.bundle`) copied into `Contents/Resources` (required for `KeyboardShortcuts.Recorder`).

## Releases
- Full checklist in `docs/RELEASING.md`.

See also: `docs/sparkle.md`.
