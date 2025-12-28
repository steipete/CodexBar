# CodexBar 🎚️ - May your tokens never run out.

Tiny macOS 14+ menu bar app that keeps your Codex, Claude Code, Cursor, Gemini, Antigravity, Droid (Factory), Copilot, and z.ai limits visible (session + weekly where available) and shows when each window resets. One status item per provider; enable what you use from Settings. No Dock icon, minimal UI, dynamic bar icons in the menu bar.

## Install

### Requirements
- macOS 14+ (Sonoma).
- Apple Silicon (arm64). Intel builds are not currently published.

### Option A: GitHub Releases (recommended, Sparkle updates)
1) Download the latest zip from GitHub Releases.
2) Unzip and move `CodexBar.app` to `/Applications`.
3) Open it (first run: right-click → Open).
4) Sparkle will keep you updated automatically (About → “Automatically check for updates”).

Download: <https://github.com/steipete/CodexBar/releases>

### Option B: Homebrew (updates via brew, Sparkle disabled)
```bash
brew install --cask steipete/tap/codexbar
```
Upgrade:
```bash
brew upgrade --cask steipete/tap/codexbar
```

### First run (developer-friendly)
- Open Settings → Providers and enable what you use.
- Install/log in to the provider CLIs you rely on (Codex, Claude, Gemini, Antigravity).
- Optional: Settings → General → “Access OpenAI via web” to add Codex dashboard extras.

## Providers

### Codex
Local Codex CLI RPC with PTY fallback; optional OpenAI web dashboard for code review remaining, usage breakdown, and credits history. More: [docs/codex.md](docs/codex.md).

### Claude Code
OAuth API or browser cookies with CLI PTY fallback; shows session + weekly usage (and model-specific weekly when available). More: [docs/claude.md](docs/claude.md).

### Cursor
Browser session cookies to fetch plan + on-demand usage and billing resets. More: [docs/cursor.md](docs/cursor.md).

### Gemini
OAuth-backed quota API using Gemini CLI credentials (no browser cookies). More: [docs/gemini.md](docs/gemini.md).

### Antigravity
Local Antigravity language server probe; no external auth. More: [docs/antigravity.md](docs/antigravity.md).

### Droid (Factory)
Browser cookies + WorkOS token flows to fetch Factory usage and billing window. More: [docs/factory.md](docs/factory.md).

### Copilot
GitHub device flow + Copilot internal usage API. More: [docs/copilot.md](docs/copilot.md).

### z.ai
API token via Keychain or env var for quota + MCP windows. More: [docs/zai.md](docs/zai.md).

Open to new providers — see the authoring guide at [docs/provider.md](docs/provider.md).

## Icon & Screenshot
The menu bar icon is a tiny two-bar meter:
- Top bar: 5‑hour/session window. If weekly is exhausted, it becomes a thicker credits bar.
- Bottom bar: weekly window (hairline).
- Errors/stale data dim the icon; status overlays indicate incidents.

![CodexBar Screenshot](codexbar.png)

## Features
- Multi-provider menu bar with per-provider toggles (Settings → Providers).
- Session + weekly meters with reset countdowns.
- Optional Codex web dashboard enrichments (code review remaining, usage breakdown, credits history).
- Local cost-usage scan for Codex + Claude (last 30 days).
- Provider status polling with incident badges in the menu and icon overlay.
- Merge Icons mode to combine providers into one status item + switcher.
- Refresh cadence presets (manual, 1m, 2m, 5m, 15m).
- Bundled CLI (`codexbar`) for scripts and CI; Linux CLI builds available.
- WidgetKit widget mirrors the menu card snapshot.
- Privacy-first: on-device parsing by default; browser cookies are opt-in and reused (no passwords stored).

## Privacy note
Wondering if CodexBar scans your disk? It doesn't; see the discussion and audit notes in [issue #12](https://github.com/steipete/CodexBar/issues/12).

## macOS permissions (why they’re needed)
- **Full Disk Access (optional)**: only required to read Safari cookies/local storage for web-based providers (Codex web, Claude web, Cursor, Droid/Factory). If you don’t grant it, use Chrome/Firefox cookies or CLI-only sources instead.
- **Keychain access (prompted by macOS)**:
  - Chrome cookie import needs the “Chrome Safe Storage” key to decrypt cookies.
  - Claude OAuth credentials (written by the Claude CLI) are read from Keychain when present.
  - z.ai and Copilot API tokens are stored in Keychain from Preferences → Providers.
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
- Install provider CLIs and log in (Codex, Claude, Gemini, Antigravity) to see data.
- Optional: enable “Access OpenAI via web” for Codex dashboard extras.

## Build from source
```bash
swift build -c release          # or debug for development
./Scripts/package_app.sh        # builds CodexBar.app in-place
CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh  # ad-hoc signing (no Apple Developer account)
open CodexBar.app
```

Dev loop:
```bash
./Scripts/compile_and_run.sh
```

## Related (from Peter)
- ✂️ [Trimmy](https://github.com/steipete/Trimmy) — “Paste once, run once.” Flatten multi-line shell snippets so they paste and run.
- 🧳 [MCPorter](https://mcporter.dev) — TypeScript toolkit + CLI for Model Context Protocol servers.
- Cross-promote: Download CodexBar at [codexbar.app](https://codexbar.app) and Trimmy at [trimmy.app](https://trimmy.app).

## Credits
Inspired by [ccusage](https://github.com/ryoppippi/ccusage) (MIT), specifically the cost usage tracking.

## License
MIT • Peter Steinberger ([steipete](https://twitter.com/steipete))
