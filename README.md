# CodexBar 🎚️ - May your tokens never run out.

Tiny macOS 14+ menu bar app that keeps AI coding-provider limits visible and shows when each window resets. CodexBar supports Codex, Claude, Cursor, Gemini, Copilot, z.ai, Kiro, Vertex AI, Augment, OpenRouter, Codebuff, and many newer coding providers. One status item per provider (or Merge Icons mode with a provider switcher); enable what you use from Settings. No Dock icon, minimal UI, dynamic bar icons in the menu bar.

<img src="codexbar.png" alt="CodexBar menu screenshot" width="520" />

## Install

### Requirements
- macOS 14+ (Sonoma)

### GitHub Releases
Download: <https://github.com/steipete/CodexBar/releases>

### Homebrew
```bash
brew install --cask steipete/tap/codexbar
```

### CLI Tarballs (macOS/Linux)
Homebrew formula (Linux today):
```bash
brew install steipete/tap/codexbar
```
Or download release tarballs from GitHub Releases:
- macOS: `CodexBarCLI-v<tag>-macos-arm64.tar.gz`, `CodexBarCLI-v<tag>-macos-x86_64.tar.gz`
- Linux: `CodexBarCLI-v<tag>-linux-aarch64.tar.gz`, `CodexBarCLI-v<tag>-linux-x86_64.tar.gz`

### First run
- Open Settings → Providers and enable what you use.
- Install/sign in to the provider sources you rely on: CLIs, browser sessions, OAuth/device flow, API keys, local app files, or provider apps depending on the provider.
- Optional: Settings → Providers → Codex → OpenAI cookies (Automatic or Manual) to add dashboard extras.

## Providers

- [Codex](docs/codex.md) — OAuth API or local Codex CLI, plus optional OpenAI web dashboard extras.
- [Claude](docs/claude.md) — OAuth API, browser cookies, or CLI PTY fallback; session and weekly usage where available.
- [Cursor](docs/cursor.md) — Browser session cookies for plan + usage + billing resets.
- [OpenCode](docs/opencode.md) — Browser cookies for workspace subscription usage.
- [OpenCode Go](docs/opencode.md) — Browser cookies for Go usage windows.
- [Alibaba Coding Plan](docs/alibaba-coding-plan.md) — Web cookies or API key for coding-plan quotas.
- [Gemini](docs/gemini.md) — OAuth-backed quota API using Gemini CLI credentials (no browser cookies).
- [Antigravity](docs/antigravity.md) — Local language server probe (experimental); no external auth.
- [Droid](docs/factory.md) — Browser cookies + WorkOS token flows for Factory usage + billing.
- [Copilot](docs/copilot.md) — GitHub device flow + Copilot internal usage API.
- [z.ai](docs/zai.md) — API token for quota + MCP windows.
- [MiniMax](docs/minimax.md) — API token, cookie header, or browser cookies for coding-plan usage.
- [Kimi](docs/kimi.md) — Auth token (JWT from `kimi-auth` cookie) for weekly quota + 5‑hour rate limit.
- [Kimi K2](docs/kimi-k2.md) — API key for credit-based usage totals.
- [Kilo](docs/kilo.md) — API token with CLI-auth fallback for Kilo Pass usage.
- [Kiro](docs/kiro.md) — CLI-based usage; monthly credits + bonus credits.
- [Vertex AI](docs/vertexai.md) — Google Cloud gcloud OAuth with token cost tracking from local Claude logs.
- [Augment](docs/augment.md) — Augment CLI or browser cookies for credits tracking and usage monitoring.
- [Amp](docs/amp.md) — Browser cookie-based authentication with Amp Free usage tracking.
- [Ollama](docs/ollama.md) — Browser cookies for Ollama Cloud usage windows.
- [JetBrains AI](docs/jetbrains.md) — Local XML-based quota from JetBrains IDE configuration; monthly credits tracking.
- [Warp](docs/warp.md) — API token for GraphQL request limits and monthly credits.
- [OpenRouter](docs/openrouter.md) — API token for credit-based usage tracking across multiple AI providers.
- Perplexity — Account usage credits from Perplexity usage data.
- [Abacus AI](docs/abacus.md) — Browser cookie auth for ChatLLM/RouteLLM compute credit tracking.
- Mistral — Browser cookies for monthly spend tracking.
- [DeepSeek](docs/deepseek.md) — API key for credit balance tracking (paid vs. granted breakdown).
- [Codebuff](docs/codebuff.md) — API token (or `~/.config/manicode/credentials.json`) for credit balance + weekly rate limit.
- [Crof](docs/crof.md) — API key for dollar credit balance and request quota tracking.
- Open to new providers: [provider authoring guide](docs/provider.md).

## Icon & Screenshot
The menu bar icon is a tiny usage meter. Bar meaning is provider-specific, and errors/stale data can dim the icon or
show an incident indicator.

## Features
- Multi-provider menu bar with per-provider toggles (Settings → Providers).
- Provider-specific usage meters with reset countdowns.
- Optional Codex web dashboard enrichments (code review remaining, usage breakdown, credits history).
- Local cost-usage scan for Codex + Claude (last 30 days).
- Provider status polling with incident badges in the menu and icon overlay.
- Merge Icons mode to combine providers into one status item + switcher.
- Display controls for provider icons, labels, bars, reset-time style, and highest-usage auto-selection.
- Refresh cadence presets (manual, 1m, 2m, 5m, 15m).
- Bundled CLI (`codexbar`) for scripts and CI (including `codexbar cost --provider codex`, `claude`, or `both` for local cost usage); macOS and Linux CLI builds available.
- WidgetKit widgets for supported providers.
- Optional session quota notifications and weekly-reset confetti.
- Privacy-first: on-device parsing by default; browser cookies are opt-in and reused (no passwords stored).

## Privacy note
Wondering if CodexBar scans your disk? It doesn’t crawl your filesystem; it reads a small set of known locations (browser cookies/local storage, provider config files, local JSONL logs) when the related features are enabled. Provider tokens and token-account settings live in `~/.codexbar/config.json` with restrictive file permissions. See the discussion and audit notes in [issue #12](https://github.com/steipete/CodexBar/issues/12).

## macOS permissions (why they’re needed)
- **Full Disk Access (optional)**: only required to read Safari cookies/local storage for web-based providers. If you don’t grant it, use another supported browser, manual cookies/API keys, OAuth, or CLI/local sources where that provider supports them.
- **Keychain access (prompted by macOS)**:
  - Chromium cookie import needs the browser “Safe Storage” key to decrypt cookies.
  - Claude OAuth bootstrap may read the Claude CLI Keychain item when CodexBar has no usable cached credentials.
  - CodexBar may use Keychain for browser cookie decryption, cached cookie headers, and OAuth/device-flow credentials where those sources require it.
  - **How do I prevent those keychain alerts?**
    - Open **Keychain Access.app** → login keychain → search the prompted item (for Claude OAuth, usually “Claude Code-credentials”).
    - Open the item → **Access Control** → add `CodexBar.app` under “Always allow access by these applications”.
    - Prefer adding just CodexBar (avoid “Allow all applications” unless you want it wide open).
    - Relaunch CodexBar after saving.
    - Reference screenshot: ![Keychain access control](docs/keychain-allow.png)
  - **How to do the same for the browser?**
    - Find the browser’s “Safe Storage” key (e.g., “Chrome Safe Storage”, “Brave Safe Storage”, “Microsoft Edge Safe Storage”).
    - Open the item → **Access Control** → add `CodexBar.app` under “Always allow access by these applications”.
    - This removes the prompt when CodexBar decrypts cookies for that browser.
- **Files & Folders prompts (folder/volume access)**: CodexBar launches provider CLIs and local probes for some providers. If those helpers read a project directory or external drive, macOS may ask CodexBar for that folder/volume (e.g., Desktop or an external volume). This is driven by the helper’s working directory, not background disk scanning.
- **What we do not request in the background**: no Screen Recording or Accessibility permissions; user-triggered helper actions may ask macOS for Automation permission to open Terminal. No passwords are stored (browser cookies are reused when you opt in).

## Docs
- Providers overview: [docs/providers.md](docs/providers.md)
- Provider authoring: [docs/provider.md](docs/provider.md)
- Issue labeling guide: [docs/ISSUE_LABELING.md](docs/ISSUE_LABELING.md)
- UI & icon notes: [docs/ui.md](docs/ui.md)
- CLI reference: [docs/cli.md](docs/cli.md)
- Configuration: [docs/configuration.md](docs/configuration.md)
- Widgets: [docs/widgets.md](docs/widgets.md)
- Architecture: [docs/architecture.md](docs/architecture.md)
- Refresh loop: [docs/refresh-loop.md](docs/refresh-loop.md)
- Status polling: [docs/status.md](docs/status.md)
- Sparkle updates: [docs/sparkle.md](docs/sparkle.md)
- Packaging: [docs/packaging.md](docs/packaging.md)
- Development: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- Release checklist: [docs/RELEASING.md](docs/RELEASING.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)

## Getting started (dev)
- Clone the repo and open it in Xcode or run the scripts directly.
- Launch once, then toggle providers in Settings → Providers.
- Install/sign in to provider sources you rely on (CLIs, browser cookies, OAuth/device flow, API keys, or local app/config files).
- Optional: set OpenAI cookies (Automatic or Manual) for Codex dashboard extras.

## Build from source
Requires macOS 14+ and Swift 6.2+.

```bash
./Scripts/package_app.sh        # builds CodexBar.app in-place
CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh  # ad-hoc signing (no Apple Developer account)
open CodexBar.app
```

Dev loop:
```bash
./Scripts/compile_and_run.sh
./Scripts/compile_and_run.sh --test  # also run swift test before packaging/relaunching
pnpm check                           # SwiftFormat + SwiftLint
pnpm docs:list                       # list docs with frontmatter summaries
```

CLI install:
```bash
# after installing CodexBar.app in /Applications
./bin/install-codexbar-cli.sh
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
