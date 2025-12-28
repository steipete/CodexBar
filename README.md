# CodexBar 🎚️ - May your tokens never run out.

Tiny macOS 15+ menu bar app (with Linux CLI + tray support) that keeps your Codex, Claude Code, Cursor, Gemini, Antigravity, Windsurf, GitHub Copilot, and z.ai limits visible (session + weekly where available) and when each window resets. One status item per provider; enable what you use from Settings. No Dock icon, minimal UI, dynamic bar icons in the menu bar.

## Install
- Homebrew (UI app; Sparkle disabled): `brew install --cask steipete/tap/codexbar` (update via `brew upgrade --cask steipete/tap/codexbar`)
- Or download the ready-to-run zip from GitHub Releases: <https://github.com/steipete/CodexBar/releases>

Login story
- **Codex** — Prefers the local codex app-server RPC for 5h/weekly limits + credits. Falls back to a PTY scrape of `codex /status` (auth/email/plan from the RPC or `~/.codex/auth.json`). All parsing stays on-device; no browser required.
- **Codex (optional OpenAI web)** — Settings → General → "Access OpenAI via web" reuses an existing signed-in `chatgpt.com` session (Safari → Chrome → Firefox cookie import) to show **Code review remaining**, **Usage breakdown**, and **Credits usage history** (when available). No passwords stored; may require granting Full Disk Access for Safari cookie import.
- **Claude Code** — Reads session + weekly + Sonnet-only weekly usage from the Claude CLI by running `/usage` + `/status` in a local PTY (no tmux). Shows email/org/login method directly from the CLI output. No browser or network calls beyond the CLI itself.
- **Cursor** — Fetches plan usage and on-demand usage from cursor.com API using browser session cookies (Safari → Chrome → Firefox). Requires cursor.com + cursor.sh cookies; shows included plan percentage, on-demand spend, and billing cycle reset time. Supports Pro, Enterprise, and other membership types. No CLI required; just stay signed in to cursor.com in your browser.
- **Gemini** — Uses the Gemini CLI `/stats` output for quota, with OAuth-backed API fetches for plan/limits.
- **Antigravity** — Local Antigravity language server probe; conservative parsing and no external auth.
- **z.ai** — Calls the z.ai quota API (API token stored in Keychain via Preferences → Providers) to show Tokens + MCP windows; dashboard: https://z.ai/manage-apikey/subscription
- **Windsurf** — Fetches usage from Windsurf via Firebase token extraction from browser IndexedDB. Shows credits usage and reset timing. Set `WINDSURF_TOKEN` environment variable or let CodexBar extract it from Chrome's IndexedDB automatically.
- **GitHub Copilot** — Fetches premium requests usage from github.com/settings/copilot using browser session cookies. Shows remaining premium requests and monthly reset.
- **Provider detection** — On first launch we detect installed CLIs and enable Codex by default (Claude turns on when the `claude` binary is present). Toggle providers in Settings → Providers or rerun detection after installing a CLI.
- **Privacy note** — Wondering if CodexBar scans your disk? It doesn't; see the discussion and audit notes in [issue #12](https://github.com/steipete/CodexBar/issues/12).

Icon bar mapping (grayscale)
- Top bar: 5‑hour window when available; if weekly is exhausted, the top becomes a thick credits bar (scaled to a 1k cap) to show paid credits left.
- Bottom bar: weekly window (a thin line). If weekly is zero you’ll see it empty under the credits bar; when weekly has budget it stays filled proportionally.
- Errors/unknowns dim the icon; no text is drawn in the icon to stay legible. Codex icons keep the eyelid blink; when Claude is enabled the template switches to the Claude notch/leg variant while keeping the same bar mapping.

![CodexBar Screenshot](codexbar.png)

## Features
- Multi-provider: Codex, Claude Code, Cursor, Gemini, Antigravity, Windsurf, GitHub Copilot, and z.ai can be shown together; enable what you use in Settings → Providers.
- Codex path: prefers the codex app-server RPC (run with `-s read-only -a untrusted`) for rate limits and credits; falls back to a PTY scrape of `codex /status`, keeping cached credits when RPC is unavailable.
- Codex optional: “Access OpenAI via web” adds Code review remaining + Usage breakdown + Credits usage history (dashboard scrape) by reusing existing browser cookies; no passwords stored.
- Claude path: runs `claude /usage` and `/status` in a local PTY (no tmux) to parse session/week/Sonnet percentages, reset strings, and account email/org/login method; debug view can copy the latest raw scrape.
- Account line keeps data siloed: Codex plan/email come from RPC/auth.json, Claude plan/email come only from the Claude CLI output; we never mix provider identity fields.
- Auto-update via Sparkle (auto-check + auto-download; menu shows “Update ready, restart now?” once downloaded). Feed defaults to the GitHub Releases appcast (replace SUPublicEDKey with your Ed25519 public key).

## Build & run
```bash
swift build -c release          # or debug for development
./Scripts/package_app.sh        # builds CodexBar.app in-place
open CodexBar.app
```

## Adding a provider
- Start here: `docs/provider.md` (provider authoring guide + target architecture).

## CLI
- macOS: Preferences → Advanced → "Install CLI" installs `codexbar` to `/usr/local/bin` + `/opt/homebrew/bin`.
- Linux: download `CodexBarCLI-<tag>-linux-<arch>.tar.gz` from GitHub Releases (x86_64 + aarch64) and run `./codexbar`.
- Linux tray: run `./Scripts/install_linux_tray.sh` for automated setup, or manually run `Sources/CodexBarLinux/codexbar_tray.py` for a GTK+AppIndicator system tray with live usage display.
- Docs: see `docs/cli.md` and `docs/linux.md`.

Requirements:
- macOS 15+ (for the menu bar app) or Linux (for CLI + tray).
- Codex: Codex CLI ≥ 0.55.0 installed and logged in (`codex --version`) to show the Codex row + credits. If your account hasn't reported usage yet, the menu will show "No usage yet."
- Claude: Claude Code CLI installed (`claude --version`) and logged in via `claude login` to show the Claude row. Run at least one `/usage` so session/week numbers exist.
- Cursor: sign in to cursor.com in Chrome (Linux) or Safari/Chrome/Firefox (macOS).
- Windsurf: sign in via the Windsurf app; CodexBar extracts the Firebase token from Chrome's IndexedDB or use `WINDSURF_TOKEN`.
- GitHub Copilot: sign in to github.com in Chrome (Linux) or Safari/Chrome/Firefox (macOS).
- OpenAI web (optional, macOS only): stay signed in to `chatgpt.com` in Safari, Chrome, or Firefox. Safari cookie import may require Full Disk Access (System Settings → Privacy & Security → Full Disk Access → enable CodexBar).

## Refresh cadence
Menu → “Refresh every …” presets: Manual, 1 min, 2 min, 5 min (default), 15 min. Manual still allows “Refresh now.”

## Notarization & signing
```bash
export APP_STORE_CONNECT_API_KEY_P8="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
export APP_STORE_CONNECT_KEY_ID="ABC123XYZ"
export APP_STORE_CONNECT_ISSUER_ID="00000000-0000-0000-0000-000000000000"
./Scripts/sign-and-notarize.sh
```
Outputs `CodexBar-<version>.zip` ready to ship. Adjust `APP_IDENTITY` in the script if needed.

## How account info is read
Account details stay local and per-provider:
- Codex: email/plan come from the codex RPC response; falls back to decoding `~/.codex/auth.json` (JWT only) if the RPC is unavailable.
- Claude: email/org/login method are pulled from the Claude CLI `/status` output.
- We never mix provider data (no showing Claude org in Codex mode, etc.). Nothing is sent anywhere.

## Limitations / edge cases
- Codex: if Codex hasn’t returned rate limits yet, you’ll see “No usage yet.” Run one Codex prompt and refresh.
- Codex: if the event schema changes, percentages may fail to parse; the menu will show the error string while keeping cached credits.
- Claude: if the CLI is missing or not logged in you’ll see the CLI error (e.g., “Claude CLI is not installed” or “claude login”).
- Claude: reset strings sometimes omit time zones; we surface the raw text when parsing fails.
- Only arm64 build is scripted; add `--arch x86_64` if you want a universal binary.

## Release checklist
See `docs/RELEASING.md` for the full CodexBar release flow, including signing, notarization, appcast generation, and asset validation.

## Changelog
See [CHANGELOG.md](CHANGELOG.md).

## Related
- ✂️ [Trimmy](https://github.com/steipete/Trimmy) — “Paste once, run once.” Flatten multi-line shell snippets so they paste and run.
- 🧳 [MCPorter](https://mcporter.dev) — TypeScript toolkit + CLI for Model Context Protocol servers.
- Cross-promote: Download CodexBar at [codexbar.app](https://codexbar.app) and Trimmy at [trimmy.app](https://trimmy.app).

Inspired by [ccusage](https://github.com/ryoppippi/ccusage) (MIT), specifically the cost usage tracking.

License: MIT • Peter Steinberger ([steipete](https://twitter.com/steipete))
