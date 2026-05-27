---
name: release-codexbar
description: "CodexBar release: versioning, notarization, appcast, Homebrew, post-release bump."
---

# CodexBar Release

Use for releasing signed/notarized macOS apps, especially repos with Sparkle appcasts and Homebrew casks.

## Start

1. Work from the app repo unless asked otherwise.
2. Check repo state, current version, latest tag/release, and release docs/scripts.
3. Confirm `CHANGELOG.md` is complete, user-facing, deduped, and dated for the release.
4. Prefer the repo release script; patch small script/test blockers instead of bypassing the release path.
5. Never print key material. Keep 1Password references and local key paths as references only.
6. Load `$release-private` if it exists before resolving Peter-owned credential locators.

## Key Material

Use `$one-password` for secret handling. `op` only in tmux/persistent shell; no broad `env`, `set`, `export -p`, or secret scans.

Known App Store Connect shape:

- fields: `private_key_p8`, `key_id`, `issuer_id`
- keep all three fields from the same 1Password item; do not mix with stale values from `~/.profile`
- resolve Peter-owned item refs from `$release-private`

Known Sparkle key:

- resolve the private key file from `$release-private`
- pass as `SPARKLE_PRIVATE_KEY_FILE`

Safe env file pattern:

```text
APP_STORE_CONNECT_API_KEY_P8=<1Password ref from release-private>
APP_STORE_CONNECT_KEY_ID=<1Password ref from release-private>
APP_STORE_CONNECT_ISSUER_ID=<1Password ref from release-private>
SPARKLE_PRIVATE_KEY_FILE=<path from release-private>
```

Run with `op run --account my.1password.com --env-file <file> -- <script>`, then delete the temp env file.

## CodexBar

Paths:

- repo: `~/Projects/codexbar`
- release script: `Scripts/release.sh`
- signing/notarization: `Scripts/sign-and-notarize.sh`
- appcast: `Scripts/make_appcast.sh`, `appcast.xml`
- release assets: `CodexBar-macos-universal-<version>.zip`, `CodexBar-macos-universal-<version>.dSYM.zip`
- packaged app: `CodexBar.app`
- version file: `version.env`
- changelog: `CHANGELOG.md`
- Homebrew tap: `~/Projects/homebrew-tap`
- cask: `~/Projects/homebrew-tap/Casks/codexbar.rb`
- formula: `~/Projects/homebrew-tap/Formula/codexbar.rb`
- CLI release workflow: `.github/workflows/release-cli.yml`

Normal release:

```bash
tmux new-session -d -s codexbar-release 'op run --account my.1password.com --env-file /tmp/codexbar-release-op.env -- Scripts/release.sh'
tmux attach -t codexbar-release
```

If notarization fails with `401 Unauthenticated`, rerun using all three App Store Connect fields from the 1Password item above. Mismatched `key_id` / `issuer_id` from `~/.profile` can cause this.

If widget metadata generation times out, `CODEXBAR_WIDGET_METADATA_TIMEOUT_SECONDS=600` is a known-good floor.

CodexBar CLI tarballs are not produced by `Scripts/release.sh` itself. The GitHub release event triggers `.github/workflows/release-cli.yml`, which builds and uploads:

- `CodexBarCLI-v<version>-macos-arm64.tar.gz`
- `CodexBarCLI-v<version>-macos-x86_64.tar.gz`
- `CodexBarCLI-v<version>-linux-aarch64.tar.gz`
- `CodexBarCLI-v<version>-linux-x86_64.tar.gz`
- matching `.sha256` files

If the workflow fails only in `update-homebrew-tap` with GitHub API rate limiting, the CLI assets may already be uploaded. Verify assets live, then update `Formula/codexbar.rb` manually from the tarball checksums.

## Verify

Release is not done until the published chain checks out:

```bash
gh release view v<VERSION> --json tagName,name,isDraft,isPrerelease,url,assets,body
Scripts/check-release-assets.sh v<VERSION>
python3 - <<'PY'
import xml.etree.ElementTree as ET
ns={'sparkle':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
root=ET.parse('appcast.xml').getroot()
item=root.find('channel').find('item')
enc=item.find('enclosure')
print(item.findtext('title'))
print(item.findtext('sparkle:version', namespaces=ns))
print(item.findtext('sparkle:shortVersionString', namespaces=ns))
print(enc.attrib.get('url'))
print(enc.attrib.get('length'))
print(bool(enc.attrib.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature')))
PY
codesign --verify --deep --strict --verbose=2 CodexBar.app
spctl --assess --type execute --verbose CodexBar.app
```

For Homebrew:

```bash
shasum -a 256 CodexBar-macos-universal-<VERSION>.zip
cd /Users/steipete/Projects/homebrew-tap
python3 .github/scripts/update_formula.py --formula codexbar --tag v<VERSION> --repository steipete/CodexBar --artifact-template 'CodexBarCLI-{tag}-{target}.tar.gz' --target-aliases 'darwin_arm64=macos-arm64,darwin_amd64=macos-x86_64,linux_arm64=linux-aarch64,linux_amd64=linux-x86_64'
brew fetch --cask --force --retry codexbar
brew fetch --formula --force --retry steipete/tap/codexbar
```

Update the cask when app zip assets exist. Update the formula only when standalone CLI tarballs for that version exist.

Tap audit can be noisy from unrelated formulae; keep evidence specific to the app cask.

## Closeout

1. Create/push tag and GitHub release through the release script.
2. Verify appcast points to the new GitHub release asset with signature and length.
3. Update/push the Homebrew cask if the app zip changed.
4. Bump the app repo to next patch `Unreleased`:
   - `version.env`: next `MARKETING_VERSION`, next `BUILD_NUMBER`
   - `CHANGELOG.md`: top `## <next> — Unreleased`
5. Commit, push, then pull `--ff-only`.
6. Restart the local app from the packaged bundle and verify the running bundle version.
7. Check no release/notary/op temp sessions or temp env files remain.

CodexBar restart:

```bash
pkill -x CodexBar || pkill -f CodexBar.app || true
cd "$(git rev-parse --show-toplevel)"
open -n CodexBar.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' CodexBar.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' CodexBar.app/Contents/Info.plist
```
