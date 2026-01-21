# CodexBar 🎚️ - May your tokens never run out.

Tiny macOS 14+ menu bar app (with Linux CLI + tray support via fork) that keeps your Codex, Claude Code, Cursor, Gemini, Antigravity, Windsurf, GitHub Copilot, Droid (Factory), z.ai, Kiro, Vertex AI, Augment, Amp, and JetBrains AI limits visible (session + weekly where available) and shows when each window resets. One status item per provider; enable what you use from Settings. No Dock icon, minimal UI, dynamic bar icons in the menu bar.

<img src="codexbar.png" alt="CodexBar menu screenshot" width="520" />

## Install

### GitHub Releases
Download: <https://github.com/steipete/CodexBar/releases>

### Homebrew
```bash
brew install --cask steipete/tap/codexbar
```

### Linux (CLI only)
```bash
brew install steipete/tap/codexbar
```
Or download `CodexBarCLI-v<tag>-linux-<arch>.tar.gz` from GitHub Releases.
Linux support via Omarchy: community Waybar module and TUI, driven by the `codexbar` executable.
Fork specific: Python-based system tray included (see `Sources/CodexBarLinux/codexbar_tray.py`).

### First run
- Open Settings → Providers and enable what you use.
- Install/sign in to the provider sources you rely on (e.g. `codex`, `claude`, `gemini`, browser cookies, API keys, or OAuth).
- Optional: Settings → Providers → Codex → OpenAI cookies (Automatic or Manual) to add dashboard extras.

### Requirements
- macOS 14+ (Sonoma) for the app
- Linux for CLI/Tray

### GitHub Releases
Download: <https://github.com/steipete/CodexBar/releases>

### Homebrew
```bash
brew install --cask steipete/tap/codexbar
```

### Linux (CLI only)
```bash
brew install steipete/tap/codexbar
```
Or download `CodexBarCLI-v<tag>-linux-<arch>.tar.gz` from GitHub Releases.
Linux support via Omarchy: community Waybar module and TUI, driven by the `codexbar` executable.

### First run
- Open Settings → Providers and enable what you use.
- Install/sign in to the provider sources you rely on (e.g. `codex`, `claude`, `gemini`, browser cookies, or OAuth; Antigravity requires the Antigravity app running).
- Optional: Settings → Providers → Codex → OpenAI cookies (Automatic or Manual) to add dashboard extras.

## Providers

- [Codex](docs/codex.md) — Local Codex CLI RPC (+ PTY fallback) and optional OpenAI web dashboard extras.
- [Claude](docs/claude.md) — OAuth API or browser cookies (+ CLI PTY fallback); session + weekly usage.
- [Cursor](docs/cursor.md) — Browser session cookies for plan + usage + billing resets.
- [Gemini](docs/gemini.md) — OAuth-backed quota API using Gemini CLI credentials (no browser cookies).
- [Antigravity](docs/antigravity.md) — Local language server probe (experimental); no external auth.
- [Droid](docs/factory.md) — Browser cookies + WorkOS token flows for Factory usage + billing.
- [Copilot](docs/copilot.md) — GitHub device flow + Copilot internal usage API.
- [z.ai](docs/zai.md) — API token (Keychain) for quota + MCP windows.
- [Kimi](docs/kimi.md) — Auth token (JWT from `kimi-auth` cookie) for weekly quota + 5‑hour rate limit.
- [Kimi K2](docs/kimi-k2.md) — API key for credit-based usage totals.
- [Kiro](docs/kiro.md) — CLI-based usage via `kiro-cli /usage` command; monthly credits + bonus credits.
- [Vertex AI](docs/vertexai.md) — Google Cloud gcloud OAuth with token cost tracking from local Claude logs.
- [Augment](docs/augment.md) — Browser cookie-based authentication with automatic session keepalive; credits tracking and usage monitoring.
- [Amp](docs/amp.md) — Browser cookie-based authentication with Amp Free usage tracking.
- [JetBrains AI](docs/jetbrains.md) — Local XML-based quota from JetBrains IDE configuration; monthly credits tracking.
- Open to new providers: [provider authoring guide](docs/provider.md).

## Icon & Screenshot
The menu bar icon is a tiny two-bar meter:
- Top bar: 5‑hour/session window. If weekly is missing/exhausted and credits are available, it becomes a thicker credits bar.
- Bottom bar: weekly window (hairline).
- Errors/stale data dim the icon; status overlays indicate incidents.

## Features
- Multi-provider: Codex, Claude, Cursor, Gemini, Antigravity, Windsurf, GitHub Copilot, Droid (Factory), z.ai, Kiro, Vertex AI, Augment, Amp, and JetBrains AI limits visible (session + weekly where available) and shows when each window resets. One status item per provider (or Merge Icons mode); enable what you use from Settings.
- Codex path: prefers the local codex app-server RPC (run with `-s read-only -a untrusted`) for rate limits and credits; falls back to a PTY scrape of `codex /status`, keeping cached credits when RPC is unavailable.
- Codex optional: “Access OpenAI via web” adds Code review remaining + Usage breakdown + Credits usage history (dashboard scrape) by reusing existing browser cookies; no passwords stored.
- Claude path: runs `claude /usage` and `/status` in a local PTY (no tmux) to parse session/week/Sonnet percentages, reset strings, and account email/org/login method; debug view can copy the latest raw scrape.
- Account line keeps data siloed: Codex plan/email come from RPC/auth.json, Claude plan/email come only from the Claude CLI output; we never mix provider identity fields.
- Auto-update via Sparkle (auto-check + auto-download; menu shows “Update ready, restart now?” once downloaded). Feed defaults to the GitHub Releases appcast (replace SUPublicEDKey with your Ed25519 public key).
- Local cost-usage scan for Codex + Claude (last 30 days).
- Provider status polling with incident badges in the menu and icon overlay.
- Merge Icons mode to combine providers into one status item + switcher.
- Refresh cadence presets (manual, 1m, 2m, 5m, 15m).
- Bundled CLI (`codexbar`) for scripts and CI (including `codexbar cost --provider codex|claude` for local cost usage); Linux CLI builds available.
- WidgetKit widget mirrors the menu card snapshot.
- Privacy-first: on-device parsing by default; browser cookies are opt-in and reused (no passwords stored).

## Privacy note
Wondering if CodexBar scans your disk? It doesn’t crawl your filesystem; it reads a small set of known locations (browser cookies/local storage, local JSONL logs) when the related features are enabled. See the discussion and audit notes in [issue #12](https://github.com/steipete/CodexBar/issues/12).

## macOS permissions (why they’re needed)
- **Full Disk Access (optional)**: only required to read Safari cookies/local storage for web-based providers (Codex web, Claude web, Cursor, Droid/Factory). If you don’t grant it, use Chrome/Firefox cookies or CLI-only sources instead.
- **Keychain access (prompted by macOS)**:
  - Chrome cookie import needs the “Chrome Safe Storage” key to decrypt cookies.
  - Claude OAuth credentials (written by the Claude CLI) are read from Keychain when present.
  - z.ai API token is stored in Keychain from Preferences → Providers; Copilot stores its API token in Keychain during device flow.
  - **How do I prevent those keychain alerts?**
    - Open **Keychain Access.app** → login keychain → search the item (e.g., “Claude Code-credentials”).
    - Open the item → **Access Control** → add `CodexBar.app` under “Always allow access by these applications”.
    - Prefer adding just CodexBar (avoid “Allow all applications” unless you want it wide open).
    - Relaunch CodexBar after saving.
    - Reference screenshot: ![Keychain access control](docs/keychain-allow.png)
  - **How to do the same for the browser?**
    - Find the browser’s “Safe Storage” key (e.g., “Chrome Safe Storage”, “Brave Safe Storage”, “Firefox”, “Microsoft Edge Safe Storage”).
    - Open the item → **Access Control** → add `CodexBar.app` under “Always allow access by these applications”.
    - This removes the prompt when CodexBar decrypts cookies for that browser.
- **Files & Folders prompts (folder/volume access)**: CodexBar launches provider CLIs (codex/claude/gemini/antigravity). If those CLIs read a project directory or external drive, macOS may ask CodexBar for that folder/volume (e.g., Desktop or an external volume). This is driven by the CLI’s working directory, not background disk scanning.
- **What we do not request**: no Screen Recording, Accessibility, or Automation permissions; no passwords are stored (browser cookies are reused when you opt in).

## Docs
- Providers overview: [docs/providers.md](docs/providers.md)
- Provider authoring: [docs/provider.md](docs/provider.md)
- UI & icon notes: [docs/ui.md](docs/ui.md)
- CLI reference: [docs/cli.md](docs/cli.md)
- Architecture: [docs/architecture.md](docs/architecture.md)
- Refresh loop: [docs/refresh-loop.md](docs/refresh-loop.md)
- Status polling: [docs/status.md](docs/status.md)
- Sparkle updates: [docs/sparkle.md](docs/sparkle.md)
- Release checklist: [docs/RELEASING.md](docs/RELEASING.md)

## Getting started (dev)
- Clone the repo and open it in Xcode or run the scripts directly.
- Launch once, then toggle providers in Settings → Providers.
- Install/sign in to provider sources you rely on (CLIs, browser cookies, or OAuth).
- Optional: set OpenAI cookies (Automatic or Manual) for Codex dashboard extras.

## Build from source
```bash
swift build -c release          # or debug for development
./Scripts/package_app.sh        # builds CodexBar.app in-place
CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh  # ad-hoc signing (no Apple Developer account)
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
Dev loop:
```bash
./Scripts/compile_and_run.sh
```

## Related
- ✂️ [Trimmy](https://github.com/steipete/Trimmy) — “Paste once, run once.” Flatten multi-line shell snippets so they paste and run.
- 🧳 [MCPorter](https://mcporter.dev) — TypeScript toolkit + CLI for Model Context Protocol servers.
- 🧿 [oracle](https://askoracle.dev) — Ask the oracle when you're stuck. Invoke GPT-5 Pro with a custom context and files.

## Looking for a Windows version?
- [Win-CodexBar](https://github.com/Finesssee/Win-CodexBar)

## Credits
Inspired by [ccusage](https://github.com/ryoppippi/ccusage) (MIT), specifically the cost usage tracking.

## License
MIT • Peter Steinberger ([steipete](https://twitter.com/steipete))
