# CodexBar 🟦🟩

May your tokens never run out—keep agent limits in view.

Tiny macOS 15+ menu bar app that shows how much Codex usage you have left (5‑hour + weekly windows) and when each window resets. No Dock icon, minimal UI, dynamic bar icon in the menu bar.

Login story
- **No login needed** for the core rate-limit view: we read the latest `rollout-*.jsonl` session logs under `~/.codex/sessions/…` plus `~/.codex/auth.json` to show 5h/weekly limits, reset times, and your account email/plan.
- **Credits auto-fetched**: We read the Codex CLI `/status` output directly via a local PTY (no browser/session login needed) to show credits and limits.

Icon bar mapping (grayscale)
- Top bar: 5‑hour window when available; if weekly is exhausted, the top becomes a thick credits bar (scaled to a 1k cap) to show paid credits left.
- Bottom bar: weekly window (a thin line). If weekly is zero you’ll see it empty under the credits bar; when weekly has budget it stays filled proportionally.
- Errors/unknowns dim the icon; no text is drawn in the icon to stay legible.

![CodexBar Screenshot](docs/codexbar.png)

## Features
- Reads the newest `rollout-*.jsonl` in `~/.codex/sessions/...` and extracts the latest `token_count` event (`used_percent`, `window_minutes`, `resets_at`).
- Shows 5h + weekly windows, last-updated time, your ChatGPT account email + plan (decoded locally from `~/.codex/auth.json`), and a configurable refresh cadence.
- Horizontal bar icon: top bar = 5h window, bottom hairline = weekly window. Filled portion shows “percent left” and dims on errors.
- CLI-only: does not hit chatgpt.com or browsers; keeps tokens on-device.
- Auto-update via Sparkle (Check for Updates… menu item, auto-check enabled). Feed defaults to GitHub Releases appcast (replace SupublicEDKey with your Ed25519 public key).

## Download
- Ready-to-run zips are published in GitHub Releases: <https://github.com/steipete/CodexBar/releases>

## Build & run
```bash
swift build -c release          # or debug for development
./Scripts/package_app.sh        # builds CodexBar.app in-place
open CodexBar.app
```

Requirements:
- Codex CLI ≥ 0.55.0 installed and logged in (`codex --version`).
- At least one Codex prompt this session so `token_count` events exist (otherwise you’ll see “No usage yet”).

## Refresh cadence
Menu → “Refresh every …” presets: Manual, 1 min, 2 min (default), 5 min. Manual still allows “Refresh now.”

## Notarization & signing
```bash
export APP_STORE_CONNECT_API_KEY_P8="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
export APP_STORE_CONNECT_KEY_ID="ABC123XYZ"
export APP_STORE_CONNECT_ISSUER_ID="00000000-0000-0000-0000-000000000000"
./Scripts/sign-and-notarize.sh
```
Outputs `CodexBar-0.4.2.zip` ready to ship. Adjust `APP_IDENTITY` in the script if needed.

## How account info is read
`~/.codex/auth.json` is decoded locally (JWT only) to show your email + plan (Pro/Plus/Business). Nothing is sent anywhere.

## Limitations / edge cases
- If the newest session log has no `token_count` yet, you’ll see “No usage yet.” Run one Codex prompt and refresh.
- If Codex changes the event schema, percentages may fail to parse; the menu will show the error string.
- Only arm64 build is scripted; add `--arch x86_64` if you want a universal binary.

## Release checklist
- [ ] Update version in Scripts/package_app.sh, Scripts/sign-and-notarize.sh, About panel (CodexBarApp) and CHANGELOG.md
- [ ] Run swiftlint & swiftformat
- [ ] swift test / swift build -c release
- [ ] ./Scripts/package_app.sh release
- [ ] ./Scripts/sign-and-notarize.sh (arm64)
- [ ] Verify .app: `spctl -a -t exec -vv CodexBar.app`; `stapler validate CodexBar.app`
- [ ] Generate Sparkle appcast with notarized zip using your Ed25519 key; upload appcast + zip to Releases; set SUPublicEDKey in Info.plist
- [ ] Upload `CodexBar-<version>.zip` to GitHub Releases and tag
- [ ] README download link points to the new release

## Changelog
See [CHANGELOG.md](CHANGELOG.md).

## Related
- [Trimmy](https://github.com/steipete/Trimmy) ✂️ “Paste once, run once” — flattens multi-line shell snippets so they actually run.
- [MCPorter](https://mcporter.dev) 🧳 TypeScript runtime/CLI/codegen toolkit for the Model Context Protocol.
- Cross-promote: Download CodexBar at [codexbar.app](https://codexbar.app) and Trimmy at [trimmy.app](https://trimmy.app).
