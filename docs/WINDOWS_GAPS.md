---
summary: "Inventory of CodexBar features not yet converted/working on Windows, with severity and per-provider impact."
read_when:
  - Planning Windows port work or prioritizing compatibility gaps
  - Triaging why a provider/feature behaves differently on Windows
last_reviewed: 2026-06-23
---

# Windows Compatibility Gaps

This document inventories everything in CodexBar that is **not yet converted, or
does not work, on Windows**. It is a planning/triage reference, not a promise of
support order.

## Architecture recap (why gaps exist)

- **macOS** ships the full native menu-bar app: the `CodexBar` SwiftUI/AppKit
  target with all its UI, plus helper targets (widget, watchdog, web probe).
- **Windows** ships a headless Swift engine (`CodexBarCLI` + `CodexBarCore`)
  exposed over a localhost HTTP server (`codexbar serve` → `/health`, `/usage`,
  `/cost`), consumed by a thin **.NET WPF tray** under `WindowsTray/`.

A "gap" is therefore any of:
1. A macOS-only build target (no Windows build at all), or
2. A shared-engine capability gated `#if os(macOS)` / stubbed on Windows, or
3. A macOS UI feature the WPF tray has not reimplemented.

---

## 1. Whole subsystems with no Windows equivalent (macOS-only targets)

From `Package.swift`, these targets/dependencies build only on macOS:

| Feature | Source | Windows status |
|---|---|---|
| Native menu-bar UI (rich menu + cards) | `CodexBar` target | Replaced by minimal WPF tray (see §4) |
| WidgetKit widgets (Usage/History/Metric/Burn-Down) | `CodexBarWidget` + `WidgetExtension/` | Partial — pinnable **desktop widget windows** in the tray (`WindowsTray/Widgets/`): Usage, Cost (session/today/30-day), and Cost-History mini-chart. Still missing: OS Widgets-Board host, usage-history & session/weekly **burn-down** charts (need a new CLI history endpoint — `/usage` and `/cost` expose no intra-window time series) |
| Claude usage watchdog helper | `CodexBarClaudeWatchdog` | Missing |
| Claude web probe helper | `CodexBarClaudeWebProbe` | Missing |
| Auto-update | `Sparkle` + `appcast.xml` | No updater in the tray |
| Global keyboard shortcuts | `KeyboardShortcuts` dep | Missing |
| Particle / visual effects | `Vortex` dep | Missing |

## 2. Shared-engine subsystems gated off on Windows

These live in `CodexBarCore` but are `#if os(macOS)`-only or stubbed, so even the
headless engine loses them on Windows:

- **Browser cookie import (`SweetCookieKit`)** — the entire cookie-extraction
  stack is macOS-only (returns `nil`/`false` on Windows); 37 files depend on it.
  This is the single largest gap. The Windows Settings window already states:
  *"cookie-based providers aren't fully supported on Windows yet."*
- **macOS Keychain** — `KeychainAccessGate`, `KeychainCacheStore`,
  `KeychainMigration`, `KeychainPromptCoordinator`, `KeychainNoUIQuery`, and the
  `security` CLI reader for Claude OAuth. On Windows tokens fall back to a
  **plaintext file** (`TokenAccounts` file store) — no DPAPI / Credential Manager
  encryption. **Security gap.**
- **WebKit dashboard scraping** — `OpenAIWeb/*` (OpenAI credits/usage dashboard),
  `ClaudeWeb`, the Codex web dashboard strategy, Copilot budget web fetch,
  `WebKit/WebKitTeardown`. All macOS-only (no WebView2 replacement yet).
- **Interactive CLI / PTY login** — `Host/PTY/TTYCommandRunner` is stubbed by
  `TTYCommandRunnerWindowsStub`. Claude/Codex/Antigravity CLI sessions throw
  *"… PTY session is not supported on Windows yet."*
- **App Group / shared container** (`AppGroupSupport`) — macOS-only (widget data
  sharing).
- **Browser detection / cookie access gate / import order** — all macOS-only.

## 3. Per-provider impact

Legend: **Works** = API-key / network path is cross-platform; **Degraded** = has
a working API-key path but loses its cookie/web/CLI extras on Windows; **Broken**
= its only supported auth on Windows is unavailable.

### Broken on Windows (cookie/web/CLI-only, no API-key fallback)

| Provider | Reason |
|---|---|
| Abacus | Browser-cookie only |
| CommandCode | Browser-cookie only |
| Grok | Browser-cookie only |
| Manus | Browser-cookie only |
| MiMo | Browser-cookie only |
| Mistral | Browser-cookie only |
| OpenCode (web) | Browser-cookie only |
| Perplexity | Browser-cookie only |

### Degraded on Windows (API-key works; cookie/web/CLI path lost)

| Provider | Lost on Windows |
|---|---|
| Alibaba (Coding Plan) | Cookie import; Token Plan has an API path |
| Kimi | Cookie import (API key still works) |
| MiniMax | Cookie + localStorage import (API token still works) |
| OpenAI | Dashboard credits/usage web scraping (API usage works) |
| Claude | Web fetch + CLI PTY login (existing OAuth/API token works) |
| Codex | Web dashboard + CLI session (existing OAuth token works) |
| Antigravity | CLI session login |
| Copilot | Budget web fetch |
| Cursor | Cookie/web status probe |
| Factory | localStorage import |
| Devin / Windsurf | Browser session import |
| T3Chat | Cookie/web session |

### Expected to work on Windows (pure API-key / network)

OpenAI API, Azure OpenAI, Gemini API, Vertex AI, Bedrock, z.ai, DeepSeek, Chutes,
Groq, GroqCloud, Ollama, OpenRouter, LiteLLM, LLM-proxy, Moonshot, Kimi-K2, Kilo,
Kiro, Amp, Synthetic, Warp, ElevenLabs, Deepgram, Doubao, Codebuff, Crof, Venice,
StepFun, Poe, JetBrains, Zed, OpenCode-Go (local), and other token-based
providers route through the cross-platform fetchers.

> Note: classification is by descriptor credential source + presence of a cookie
> importer / web fetcher / CLI session. A few "status probe" providers may degrade
> only in their status-badge feature, not core usage — verify individually before
> relying on this for release notes.

## 4. Menu-bar / UI features missing in the WPF tray

The macOS app has ~80 menu/preferences source files. The Windows tray
(`WindowsTray/App.xaml.cs`) implements only: tray icon, a usage popup window, and
the menu items **Refresh**, **Settings…**, **Always on screen**,
**Start with Windows**, **Quit**. Not yet ported:

- **Sign-in flows**: `ClaudeLoginRunner`, `CodexLoginRunner`, `CursorLoginRunner`,
  `GeminiLoginRunner` (no interactive login UI on Windows).
- **Charts**: cost history, credits history, plan-utilization history, usage
  breakdown, storage breakdown, Z.ai hourly.
- **Multi-account management**: managed Codex accounts, account switching /
  promotion / reconciliation (`CodexAccount*`, `ManagedCodexAccount*`).
- **Menu-bar display customization**: display modes, custom metric text, icon
  rendering / remaining resolver, stacked & overview submenus.
- **Preferences panes**: General, Display, Advanced, Debug, About, Providers
  detail / sidebar / error views, Codex Accounts section.
- **Native notifications**: ✅ *Implemented* — the tray now fires Windows balloon
  notifications for session depleted/restored and quota-low threshold crossings
  (`WindowsTray/QuotaNotifications.cs` + `QuotaNotificationCoordinator.cs`), a
  port of macOS `SessionQuotaNotifications`. Not yet ported: Antigravity
  quota-summary windows, window-source tracking, and per-notification sound
  control (Windows manages notification sound per-app).
- **Cost view**: the CLI serves `/cost` but the tray consumes only `/usage`.
- **Misc**: click-to-copy overlay, OpenAI credits purchase window, memory-pressure
  monitor/relief, main-thread hang watchdog. (Launch-at-login exists on Windows
  via registry `StartupRegistration`, in place of macOS `SMAppService`.)

## 5. Other gaps

- **Localization** — Mac app has `Localization.swift` + locale resources; the tray
  is English-only.
- **Diagnostics UI** — `codexbar diagnose` exists, but the Mac diagnostics/debug
  panes are not surfaced in the tray.
- **Packaging / signing / update pipeline** — Windows packaging exists
  (`build.ps1`, `Scripts/win-package.ps1`) but there is no signed-installer or
  auto-update pipeline equivalent to the macOS appcast.

---

## Suggested priority order

1. **Browser cookie import** on Windows — unlocks ~12+ providers (Broken +
   Degraded cookie cases).
2. **Secure token storage** (DPAPI / Windows Credential Manager) replacing the
   plaintext `TokenAccounts` file.
3. **Interactive login** (PTY replacement) for Claude / Codex / Antigravity.
4. **WebKit dashboard scraping** replacement (e.g. WebView2) for OpenAI / Claude /
   Codex web paths.
5. **Tray UI parity** — charts, multi-account, cost view. (Native notifications
   are now implemented.)
