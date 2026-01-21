---
summary: "Packaging, signing, and bundled CLI notes."
read_when:
  - Packaging/signing builds
  - Updating bundle layout or CLI bundling
---

# Packaging & signing

## Scripts
- `Scripts/package_app.sh`: builds host arch by default; set `ARCHES="arm64 x86_64"` for universal. Verifies slices.
- `Scripts/compile_and_run.sh`: uses host arch; pass `--release-universal` or `--release-arches="arm64 x86_64"` for release packaging.
- `Scripts/sign-and-notarize.sh`: signs, notarizes, staples, zips (accepts `ARCHES` for universal).
- `Scripts/make_appcast.sh`: generates Sparkle appcast and embeds HTML release notes.
- `Scripts/changelog-to-html.sh`: converts the per-version changelog section to HTML for Sparkle.

## Bundle contents
- `CodexBarWidget.appex` bundled with app-group entitlements.
- `CodexBarCLI` copied to `CodexBar.app/Contents/Helpers/` for symlinking.
- SwiftPM resource bundles (e.g. `KeyboardShortcuts_KeyboardShortcuts.bundle`) copied into `Contents/Resources` (required for `KeyboardShortcuts.Recorder`).

## Releases
- Full checklist in `docs/RELEASING.md`.

See also: `docs/sparkle.md`.
