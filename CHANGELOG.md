# Changelog

## Unreleased
### Highlights
- Add a merged-menu Overview tab with configurable providers and row-to-provider navigation (#416).
- Add an experimental option to suppress Claude Keychain prompts (#388).
- Add OpenRouter provider for credit-based usage tracking (#396). Thanks @chountalas!
- Add Ollama provider, including token-account support in Settings and CLI (#380). Thanks @CryptoSageSnr!
- Reduce CPU/energy regressions and JSONL scanner overhead in Codex/web usage paths (#402, #392). Thanks @bald-ai and @asonawalla!

### Providers & Usage
- OpenRouter: add credit tracking, key-quota popup support, token-account labels, fallback status icons, and updated icon/color (#396). Thanks @chountalas!
- Ollama: add provider support with token-account support in app/CLI, Chrome-default auto cookie import, and manual-cookie mode (#380). Thanks @CryptoSageSnr!
- Codex: in percent display mode with "show remaining," show remaining credits in the menu bar when session or weekly usage is exhausted (#336). Thanks @teron131!
- Menu: rebuild the merged provider switcher when “Show usage as used” changes so switcher progress updates immediately (#306). Thanks @Flohhhhh!
- Update Kiro parsing for `kiro-cli` 1.24+ / Q Developer formats and non-managed plan handling (#288). Thanks @kilhyeonjun!
- Kimi: in automatic metric mode, prioritize the 5-hour rate-limit window for menu bar and merged highest-usage calculations (#390). Thanks @ajaxjiang96!
- OpenCode: treat explicit `null` subscription responses as missing usage data, skip POST fallback, and return a clearer workspace-specific error (#412).
- OpenCode: surface clearer HTTP errors. Thanks @SalimBinYousuf1!
- Warp: update API key setup guidance.
- Fix Claude setup message package name (#376). Thanks @daegwang!

### Menu & Settings
- Merged menu: add an Overview switcher tab that shows up to three provider usage rows in provider order (#416).
- Settings: add "Overview tab providers" controls to choose/deselect Overview providers, with persisted selection reconciliation as enabled providers change (#416).
- Menu: hide contextual provider actions while Overview is selected and rebuild switcher state when overview availability changes (#416).

### Claude OAuth & Keychain
- Add an experimental Claude OAuth Security-CLI reader path and option in settings.
- Apply stored prompt mode and fallback policy to silent/noninteractive keychain probes.
- Add cooldown for background OAuth keychain retries.
- Disable experimental toggle when keychain access is disabled.

### Performance & Reliability
- Codex/OpenAI web: reduce CPU and energy overhead by shortening failed CLI probe windows, capping web retry timeouts, and using adaptive idle blink scheduling (#402). Thanks @bald-ai!
- Cost usage scanner: optimize JSONL chunk parsing to avoid buffer-front removal overhead on large logs (#392). Thanks @asonawalla!
- TTY runner: fence shutdown registration to avoid launch/shutdown races, isolate process groups before shutdown rejection, and ensure lingering CLI descendants are cleaned up on app termination (#429). Thanks @uraimo!

### Dev & Tests
- Run provider fetches and Claude debug OAuth probes off `MainActor`.
- Split Claude OAuth test overrides and isolate coordinator tests.
- Docs: explain pace tracking terminology in the UI guide, including "deficit", "reserve", and "on pace" meanings (#421). Thanks @bald-ai!


## 0.18.0-beta.3 — 2026-02-13
### Highlights
- Claude OAuth/keychain flows were reworked across a series of follow-up PRs to reduce prompt storms, stabilize background behavior, surface a setting to control prompt policy and make failure modes deterministic (#245, #305, #308, #309, #364). Thanks @manikv12!
- Claude: harden Claude Code PTY capture for `/usage` and `/status` (prompt automation, safer command palette confirmation, partial UTF-8 handling, and parsing guards against status-bar context meters) (#320).
- New provider: Warp (credits + add-on credits) (#352). Thanks @Kathie-yu!
- Provider correctness fixes landed for Cursor plan parsing and MiniMax region routing (#240, #234, #344). Thanks @robinebers and @theglove44!
- Menu bar animation behavior was hardened in merged mode and fallback mode (#283, #291). Thanks @vignesh07 and @Ilakiancs!
- CI/tooling reliability improved via pinned lint tools, deterministic macOS test execution, and PTY timing test stabilization plus Node 24-ready GitHub Actions upgrades (#292, #312, #290).

### Claude OAuth & Keychain
- Claude OAuth creds are cached in CodexBar Keychain to reduce repeated prompts.
- Prompts can still appear when Claude OAuth credentials are expired, invalid, or missing and re-auth is required.
- In Auto mode, background refresh keeps prompts suppressed; interactive prompts are limited to user actions (menu open or manual refresh).
- OAuth-only mode remains strict (no silent Web/CLI fallback); Auto mode may do one delegated CLI refresh + one OAuth retry before falling back.
- Preferences now expose a Claude Keychain prompt policy (Never / Only on user action / Always allow prompts) under Providers → Claude; if global Keychain access is disabled in Advanced, this control remains visible but inactive.

### Provider & Usage Fixes
- Warp: add Warp provider support (credits + add-on credits), configurable via Settings or `WARP_API_KEY`/`WARP_TOKEN` (#352). Thanks @Kathie-yu!
- Cursor: compute usage against `plan.limit` rather than `breakdown.total` to avoid incorrect limit interpretation (#240). Thanks @robinebers!
- MiniMax: correct API region URL selection to route requests to the expected regional endpoint (#234). Thanks @theglove44!
- MiniMax: always show the API region picker and retry the China endpoint when the global host rejects the token to avoid upgrade regressions for users without a persisted region (#344). Thanks @apoorvdarshan!
- Claude: add Opus 4.6 pricing so token cost scanning tracks USD consumed correctly (#348). Thanks @arandaschimpf!
- z.ai: handle quota responses with missing token-limit fields, avoid incorrect used-percent calculations, and harden empty-response behavior with safer logging (#346). Thanks @MohamedMohana and @halilertekin!
- z.ai: fix provider visibility in the menu when enabled with token-account credentials (availability now considers the effective fetch environment).
- Amp: detect login redirects during usage fetch and fail fast when the session is invalid (#339). Thanks @JosephDoUrden!
- Resource loading: fix app bundle lookup path to avoid "could not load resource bundle" startup failures (#223). Thanks @validatedev!
- OpenAI Web dashboard: keep WebView instances cached for reuse to reduce repeated network fetch overhead; tests were updated to avoid network-dependent flakes (#284). Thanks @vignesh07!
- Token-account precedence: selected token account env injection now correctly overrides provider config `apiKey` values in app and CLI environments. Thanks @arvindcr4!
- Claude: make Claude CLI probing more resilient by scoping auto-input to the active subcommand and trimming to the latest Usage panel before parsing to avoid false matches from earlier screen fragments (#320).

### Menu Bar & UI Behavior
- Prevent fallback-provider loading animation loops (battery/CPU drain when no providers are enabled) (#283). Thanks @vignesh07!
- Prevent status overlay rendering for disabled providers while in merged mode (#291). Thanks @Ilakiancs!

### CI, Tooling & Test Stability
- Pin SwiftFormat/SwiftLint versions and harden lint installer behavior (version drift + temp-file leak fixes) (#292).
- Use more deterministic macOS CI test settings (including non-parallel paths where needed) and align runner/toolchain behavior for stability (#292).
- Stabilize PTY command timing tests to reduce CI flakiness (#312).
- Upgrade `actions/checkout` to v6 and `actions/github-script` to v8 for Node 24 compatibility in `upstream-monitor.yml` (#290). Thanks @salmanmkc!
- Tests: add TaskLocal-based keychain/cache overrides so keychain gating and KeychainCacheStore test stores do not leak across concurrent test execution (#320).

### Docs & Maintenance
- Update docs for Claude data fetch behavior and keychain troubleshooting notes.
- Update MIT license year.

## 0.18.0-beta.2 — 2026-01-21
### Highlights
- OpenAI web dashboard refresh cadence now follows 5× the base refresh interval.
- OpenAI web dashboard WebView is kept warm between scrapes to avoid repeated SPA downloads while idle CPU stays low (#284). Thanks @vignesh07!
- Menu bar: avoid fallback animation loop when all providers are disabled (#283). Thanks @vignesh07!
- Codex settings now include a toggle to disable OpenAI web extras.

### Providers
- Providers: add Dia browser support across cookie import and profile detection (#209). Thanks @validatedev!
- Codex: include archived session logs in local token cost scanning and dedupe by session id.
- Claude: harden CLI /usage parsing and avoid ANTHROPIC_* env interference during probes.

### Menu & Menu Bar
- Menu: opening OpenAI web submenus triggers a refresh when the data is stale.
- Menu: fix usage line labels to honor “Show usage as used”.
- Debug: add a toggle to keep Codex/Claude CLI sessions alive between probes.
- Debug: add a button to reset CLI probe sessions.
- App icon: use the classic icon on macOS 15 and earlier while keeping Liquid Glass for macOS 26+ (#178). Thanks @zerone0x!

## 0.18.0-beta.1 — 2026-01-18
### Highlights
- New providers: OpenCode (web usage), Vertex AI, Kiro, Kimi, Kimi K2, Augment, Amp, Synthetic.
- Provider source controls: usage source pickers for Codex/Claude, manual cookie headers, cookie caching with source/timestamp.
- Menu bar upgrades: display mode picker (percent/pace/both), auto-select near limit, absolute reset times, pace summary line.
- CLI/config revamp: config-backed provider settings, JSON-only errors, config validate/dump.

### Providers
- OpenCode: add web usage provider with workspace override + Chrome-first cookie import (#188). Thanks @anthnykr!
- OpenCode: refresh provider logo (#190). Thanks @anthnykr!
- Vertex AI: add provider with quota-based usage from gcloud ADC. Thanks @bahag-chaurasiak!
- Vertex AI: token costs are shown via the Claude provider (same local logs).
- Vertex AI: harden quota usage parsing for edge-case responses.
- Kiro: add CLI-based usage provider via kiro-cli. Thanks @neror!
- Kiro: clean up provider wiring and show plan name in the menu.
- Kiro: harden CLI idle handling to avoid partial usage snapshots (#145). Thanks @chadneal!
- Kimi: add usage provider with cookie-based API token stored in Keychain (#146). Thanks @rehanchrl!
- Kimi K2: add API-key usage provider for credit totals (#147). Thanks @0-CYBERDYNE-SYSTEMS-0!
- Augment: add provider with browser-cookie usage tracking.
- Augment: prefer Auggie CLI usage with web fallback, plus session refresh + recovery tools (#142). Thanks @bcharleson!
- Amp: add provider with Amp Free usage tracking (#167). Thanks @duailibe!
- Synthetic: add API-key usage provider with quota snapshots (#171). Thanks @monotykamary!
- JetBrains AI: include IDEs missing quota files, expand custom paths, and add Android Studio base paths (#194). Thanks @steipete!
- JetBrains AI: detect IDE directories case-insensitively (#200). Thanks @zerone0x!
- Cursor: support legacy request-based plans and show individual on-demand usage (#125) — thanks @vltansky
- Cursor: avoid Intel crash when opening login and harden WebKit teardown. Thanks @meghanto!
- Cursor: load stored session cookies before reads to make relaunches deterministic.
- z.ai: add BigModel CN region option for API endpoint selection (#140). Thanks @nailuoGG!
- MiniMax: add China mainland region option + host overrides (#143). Thanks @nailuoGG!
- MiniMax: support API token or cookie auth; API token takes precedence and hides cookie UI (#149). Thanks @aonsyed!
- Gemini: prefer loadCodeAssist project IDs for quota fetches (#172). Thanks @lolwierd!
- Gemini: honor loadCodeAssist project IDs for quota + support Nix CLI layout (#184). Thanks @HaukeSchnau!
- Claude: fix OAuth “Extra usage” spend/limit units when the API returns minor currency units (#97).
- Claude: rescale extra usage costs when plan hints are missing and prefer web plan hints for extras (#181). Thanks @jorda0mega!
- Usage formatting: fix currency parsing/formatting on non-US locales (e.g., pt-BR). Thanks @mneves75!

### Provider Sources & Security
- Providers: cache browser cookies in Keychain (per provider) and show cached source/time in settings.
- Codex/Claude/Cursor/Factory/MiniMax: cookie sources now include Manual (paste a Cookie header) in addition to Automatic.
- Codex/Claude/Cursor/Factory/MiniMax: skip cookie imports from browsers without usable cookie stores (profile/cookie DB) to avoid unnecessary Keychain prompts.
- Providers: suppress repeated Chromium Keychain prompts after access denied and honor disabled Keychain access.

### Preferences & Settings
- Preferences: swap provider refresh button and enable toggle order.
- Preferences: animate settings width and widen Providers on selection.
- Preferences: shrink default settings size and reduce overall height.
- Preferences: move “Hide personal information” to Advanced.
- Providers: shorten fetch subtitle to relative time only.
- Preferences: soften provider sidebar background and stabilize drag reordering.
- Preferences: restrict provider drag handle to handle-only.
- Preferences: move provider refresh timing to a dedicated second line.
- Preferences: tighten provider usage metrics spacing.
- Preferences: show refresh timing inline in provider detail subtitle.
- Preferences: move “Access OpenAI via web” into Providers → Codex.
- Preferences: add usage source pickers for Codex + Claude with auto fallback.
- Preferences: add cookie source pickers with contextual helper text for the selected mode.
- Preferences: move “Disable Keychain access” to Advanced and require manual cookies when enabled.
- Preferences: add per-provider menu bar metric picker (#185) — thanks @HaukeSchnau
- Preferences: tighten provider rows (inline pickers, compact layout, inline refresh + auto-source status).
- Preferences: remove the “experimental” label from Antigravity.

### Menu & Menu Bar
- Menu: add a toggle to show reset times as absolute clock values (instead of countdowns).
- Menu: show an “Open Terminal” action when Claude OAuth fails.
- Menu: add “Hide personal information” toggle and redact emails in menu UI (#137). Thanks @t3dotgg!
- Menu: keep a pace summary line alongside the visual marker (#155). Thanks @antons!
- Menu: reduce provider-switch flicker and avoid redundant menu card sizing for faster opens (#132). Thanks @ibehnam!
- Menu: keep background refresh on open without forcing token usage (#158). Thanks @weequan93!
- Menu: Cursor switcher shows On-Demand remaining when Plan is exhausted in show-remaining mode (#193). Thanks @vltansky!
- Menu: avoid single-letter wraps in provider switcher titles.
- Menu: widen provider switcher buttons to avoid clipped titles.
- Menu bar: rebuild provider status items on reorder so icons update correctly.
- Menu bar: optional auto-select provider closest to its rate limit and keep switcher progress visible (#159). Thanks @phillco!
- Menu bar: add display mode picker for percent/pace/both in the menu bar icon (#169). Thanks @PhilETaylor!
- Menu bar: fix combined loading indicator flicker during loading animation (incl. debug replay).
- Menu bar: prevent blink updates from clobbering the loading animation.

### CLI & Config
- CLI: respect the reset time display setting.
- CLI: add pink accents, usage bars, and weekly pace lines to text output.
- CLI: add config-backed provider settings, `--json-only`, and `--source api` for key-based providers.
- CLI: add `config validate`/`config dump` commands and per-provider JSON error payloads.
- CLI/App: move provider secrets + ordering to `~/.codexbar/config.json` (no Keychain persistence).
- Providers: resolve API tokens from config/env only (no Keychain fallback).

### Dev & Tests
- Dev: move Chromium profile discovery into SweetCookieKit (adds Helium net.imput.helium). Thanks @hhushhas!
- Dev: bump SweetCookieKit to 0.2.0.
- Dev: migrate stored Keychain items to reduce rebuild prompts.
- Dev: move path debug snapshot off the main thread and debounce refreshes to avoid startup hitches (#131). Thanks @ibehnam!
- Tests: expand Kiro CLI coverage.
- Tests: stabilize Claude PTY integration cleanup and reset CLI sessions after probes.
- Tests: kill leaked codex app-server after tests.
- Tests: add regression coverage for merged loading icon layout stability.
- Tests: cover config validation and JSON-only CLI errors.
- Build: stabilize Swift test runtime.

## 0.17.0 — 2025-12-31
- New providers: MiniMax.
- Keychain: show a preflight explanation before macOS prompts for OAuth tokens or cookie decryption.
- Providers: defer z.ai + Copilot Keychain reads until the user interacts with the token field.
- Menu bar: avoid status item menu reattachment and layout flips during refresh to reduce icon flicker.
- Dev: align SweetCookieKit local-storage tests with Swift Testing.
- Charts: align hover selection bands with visible bars in credits + usage breakdown history.
- About: fix website link in the About panel. Thanks @felipeorlando!

## 0.16.1 — 2025-12-29
- Menu: reduce layout thrash when opening menus and sizing charts. Thanks @ibehnam!
- Packaging: default release notarization builds universal (arm64 + x86_64) zip.
- OpenAI web: reduce idle CPU by suspending cached WebViews when not scraping. Thanks @douglascamata!
- Icons: switch provider brand icons to SVGs for sharper rendering. Thanks @vandamd!

## 0.16.0 — 2025-12-29
- Menu bar: optional “percent mode” (provider brand icons + percentage labels) via Advanced toggle.
- CLI: add `codexbar cost` to print local cost usage (text/JSON) for Codex + Claude.
- Cost: align local cost scanner with ccusage; stabilize parsing/decoding and handle large JSONL lines.
- Claude: skip pricing for unknown models (tokens still tracked) to avoid hard-coded legacy prices.
- Performance: reduce menu bar CPU usage by caching morph icons, skipping redundant status-item updates, and caching provider enablement/order during animations.
- Menu: improve provider switcher hover contrast in light mode.
- Icons: refresh Droid + Claude brand assets to better match menu sizing.
- CI: avoid interactive login-shell probes to reduce noisy “CLI missing” errors.

## 0.15.3 — 2025-12-28
- Codex: default to OAuth usage API (ChatGPT backend) with CLI-only override in Debug.
- Codex: map OAuth credits balance directly, avoiding web fallback for credits.
- Preferences: add optional “Access OpenAI via web” toggle and show blended source labels when web extras are active.
- Copilot: replace blocking auth wait dialog with a non-modal sheet to avoid stuck login.

## 0.15.2 — 2025-12-28
- Copilot: fix device-flow waiting modal to close reliably after auth (and avoid stuck waits).
- Packaging: include the KeyboardShortcuts resource bundle to prevent Settings → Keyboard shortcut crashes in packaged builds.

## 0.15.1 — 2025-12-28
- Preferences: fix provider API key fields reusing the wrong input when switching rows.
- Preferences: avoid Advanced tab crash when opening settings.

## 0.15.0 — 2025-12-28
- New providers: Droid (Factory), Cursor, z.ai, Copilot.
- macOS: CodexBar now supports Intel Macs (x86_64 builds + Sonoma fallbacks). Thanks @epoyraz!
- Droid (Factory): new provider with Standard + Premium usage via browser cookies, plus dashboard + status links. Thanks @shashank-factory!
- Menu: allow multi-line error messages in the provider subtitle (up to 4 lines).
- Menu: fix subtitle sizing for multi-line error states.
- Menu: avoid clipping on multi-line error subtitles.
- Menu: widen the menu card when 7+ providers are enabled.
- Providers: Codex, Claude Code, Cursor, Gemini, Antigravity, z.ai.
- Gemini: switch plan detection to loadCodeAssist tier lookup (Paid/Workspace/Free/Legacy). Thanks @381181295!
- Codex: OpenAI web dashboard is now the primary source for usage + credits; CLI fallback only when no matching cookies exist.
- Claude: prefer OAuth when credentials exist; fall back to web cookies or CLI (thanks @ibehnam).
- CLI: replace `--web`/`--claude-source` with `--source` (auto/web/cli/oauth); auto falls back only when cookies are missing.
- Homebrew: cask now installs the `codexbar` CLI symlink. Thanks @dalisoft!
- Cursor: add new usage provider with browser cookie auth (cursor.com + cursor.sh), on-demand bar support, and dashboard access.
- Cursor: keep stored sessions on transient failures; clear only on invalid auth.
- z.ai: new provider support with Tokens + MCP usage bars and MCP details submenu; API token now lives in Preferences (stored in Keychain); usage bars respect the show-used toggle. Thanks @uwe-schwarz for the initial work!
- Copilot: new GitHub Copilot provider with device flow login plus Premium + Chat usage bars (including CLI support). Thanks @roshan-c!
- Preferences: fix Advanced Display checkboxes and move the Quit button to the bottom of General.
- Preferences: hide “Augment Claude via web” unless Claude usage source is CLI; rename the cost toggle to “Show cost summary”.
- Preferences: add an Advanced toggle to show/hide optional Codex Credits + Claude Extra usage sections (on by default).
- Widgets: add a new “CodexBar Switcher” widget that lets you switch providers and remember the selection.
- Menu: provider switcher now uses crisp brand icons with equal-width segments and a per-provider usage indicator.
- Menu: tighten provider switcher sizing and increase spacing between label and weekly indicator bar.
- Menu: provider switcher no longer forces a wider menu when many providers are enabled; segments clamp to the menu width.
- Menu: provider switcher now aligns to the same horizontal padding grid as the menu cards when space allows.
- Dev: `compile_and_run.sh` now force-kills old instances to avoid launching duplicates.
- Dev: `compile_and_run.sh` now waits for slow launches (polling for the process).
- Dev: `compile_and_run.sh` now launches a single app instance (no more extra windows).
- CI: build/test Linux `CodexBarCLI` (x86_64 + aarch64) and publish release assets as `CodexBarCLI-<tag>-linux-<arch>.tar.gz` (+ `.sha256`).
- CLI: add alias fallback for Codex/Claude detection when PATH lookups fail.
- Providers: support Arc browser cookies for Factory/Droid (and other Chromium-based cookie imports).
- Providers: support ChatGPT Atlas browser data for Chromium cookie imports.
- Providers: accept Auth.js secure session cookies for Factory/Droid login detection.
- Providers: accept Factory auth session cookies (session/access-token) for Droid.
- Droid: surface Factory API errors instead of masking them as missing sessions.
- Droid: retry auth without access-token cookies when Factory flags a stale token.
- Droid: try all detected browser profiles before giving up.
- Droid: fall back to auth.factory.ai endpoints when cookies live on the auth host.
- Droid: use WorkOS refresh tokens from browser local storage when cookies fail.
- Droid: read WorkOS refresh tokens from Safari local storage.
- Droid: try stored/WorkOS tokens before Chrome cookies to reduce Chrome Safe Storage prompts.
- Menu: provider switcher bars now track primary quotas (Plan/Tokens/Pro), with Premium shown for Droid.
- Menu: avoid duplicate summary blocks when a provider has no action rows.
- OpenAI web: ignore cookie sets without session tokens to avoid false-positive dashboard fetches.
- Providers: hide z.ai in the menu until an API key is set.
- Menu: refresh runs automatically when opening the menu with a short retry (refresh row removed).
- Menu: hide the Status Page row when a provider has no status URL.
- Menu: align switcher bar with the “show usage as used” toggle.
- Antigravity: fix lsof port filtering by ANDing listen + pid conditions. Thanks @shaw-baobao!
- Claude: default to Claude Code OAuth usage API (credentials from Keychain or `~/.claude/.credentials.json`), with Debug selector + `--claude-source` CLI override (OAuth/Web/CLI).
- OpenAI web: allow importing any signed-in browser session when Codex email is unknown (first-run friendly).
- Core: Linux CLI builds now compile (mac-only WebKit/logging gated; FoundationNetworking imports where needed).
- Core: fix CI flake for Claude trust prompts by making PTY writes fully reliable.
- Core: Cursor provider is macOS-only (Linux CLI builds stub it).
- Core: make `RateWindow` equatable (used by OpenAI dashboard snapshots and tests).
- Tests: cover alias fallback resolution for Codex/Claude and add Linux platform gating coverage (run in CI).
- Tests: cover hiding Codex Credits + Claude Extra usage via the Advanced toggle.
- Docs: expand CLI docs for Linux install + flags.

## 0.14.0 — 2025-12-25
- New providers: Antigravity.
- Antigravity: new local provider for the Antigravity language server (Claude + Gemini quotas) with an experimental toggle; improved plan display + debug output; clearer not-running/port errors; hide account switch.
- Status: poll Google Workspace incidents for Gemini + Antigravity; Status Page opens the Workspace status page.
- Settings: add Providers tab; move ccusage + status toggles to General; keep display controls in Advanced.
- Menu/UI: widen the menu for four providers; cards/charts adapt to menu width; tighten provider switcher/toggle spacing; keep menus refreshed while open.
- Gemini: hide the dashboard action when unsupported.
- Claude: fix Extra usage spend/limit units (cents); improve CLI probe stability; surface web session info in Debug.
- OpenAI web: fix dashboard ghost overlay on desktop (WebKit keepalive window).
- Debug: add a debug-lldb build mode for troubleshooting.

## 0.13.0 — 2025-12-24
- Claude: add optional web-first usage via Safari/Chrome cookies (no CLI fallback) including “Extra usage” budget bar.
- Claude: web identity now uses `/api/account` for email + plan (via rate_limit_tier).
- Settings: standardize “Augment … via web” copy for Codex + Claude web cookie features.
- Debug: Claude dump now shows web strategy, cookie discovery, HTTP status codes, and parsed summary.
- Dev: add Claude web probe CLI to enumerate endpoints/fields using browser cookies.
- Tests: add unit coverage for Claude web API usage, overage, and account parsing.
- Menu: custom menu items now use the native selection highlight color (plus matching selection text/track colors).
- Charts: boost hover highlight contrast for credits/usage history bands.
- Menu: reorder Codex blocks to show credits before cost.
- Menu: split Claude “Extra usage” (no submenu) from “Cost” (history submenu) and trim redundant extra-usage subtext.

## 0.12.0 — 2025-12-23
- Widgets: add WidgetKit extension backed by a shared app‑group usage snapshot.
- New local cost usage tracking (Codex + Claude) via a lightweight scanner — inspired by ccusage (MIT). Computes cost from local JSONL logs without Node CLIs. Thanks @ryoppippi!
- Cost summary now includes last‑30‑days tokens; weekly pace indicators (with runout copy) hide when usage is fully depleted. Thanks @Remedy92!
- Claude: PTY probes now stop after idle, auto‑clean on restart, and run under a watchdog to avoid runaway CLI processes.
- Menu polish: group history under card sections, simplify history labels, and refresh menus live while open.
- Performance: faster usage log scanning + cost parsing; cache menu icons and speed up OpenAI dashboard parsing.
- Sparkle: auto-download updates when auto-check is enabled, and only show the restart menu entry once an update is ready.
- Widgets: experimental WidgetKit extension (may require restarting the widget gallery/Dock to appear).
- Credits: show credits as a progress bar and add a credits history chart when OpenAI web data is available.
- Credits: move “Buy Credits…” into its own menu item and improve auto-start checkout flow.

## 0.11.2 — 2025-12-21
- ccusage-codex cost fetch is faster and more reliable by limiting the session scan window.
- Fix ccusage cost fetch hanging for large Codex histories by draining subprocess output while commands run.
- Fix merged-icon loading animation when another provider is fetching (only the selected provider animates).
- CLI PATH capture now uses an interactive login shell and merges with the app PATH, fixing missing Node/Codex/Claude/Gemini resolution for NVM-style installs.

## 0.11.1 — 2025-12-21
- Gemini OAuth token refresh now supports Bun/npm installations. Thanks @ben-vargas!

## 0.11.0 — 2025-12-21
- New optional cost display in the menu (session + last 30 days), powered by ccusage. Thanks @Xuanwo!
- Fix loading-state card spacing to avoid double separators.

## 0.10.0 — 2025-12-20
- Gemini provider support (usage, plan detection, login flow). Thanks @381181295!
- Unified menu bar icon mode with a provider switcher and Merge Icons toggle (default on when multiple providers are enabled). Thanks @ibehnam!
- Fix regression from 0.9.1 where CLI detection failed for some installs by restoring interactive login-shell PATH loading.

## 0.9.1 — 2025-12-19
- CLI resolution now uses the login shell PATH directly (no more heuristic path scanning), so Codex/Claude match your shell config reliably.

## 0.9.0 — 2025-12-19
- New optional OpenAI web access: reuses your signed-in Safari/Chrome session to show **Code review remaining**, **Usage breakdown**, and **Credits usage history** in the menu (no credentials stored).
- Credits still come from the Codex CLI; OpenAI web access is only used for the dashboard extras above.
- OpenAI web sessions auto-sync to the Codex CLI email, support multiple accounts, and reset/re-import cookies on account switches to avoid stale cross-account data.
- Fix Chrome cookie import (macOS 10): signed-in Chrome sessions are detected reliably (thanks @tobihagemann!).
- Usage breakdown submenu: compact chart with hover details for day/service totals.
- New “Show usage as used” toggle to invert progress bars (default remains “% left”, now in Advanced).
- Session (5-hour) reset now shows a relative countdown (“Resets in 3h 31m”) in the menu card for Codex and Claude.
- Claude: fix reset parsing so “Resets …” can’t be mis-attributed to the wrong window (session vs weekly).

## 0.8.1 — 2025-12-17
- Claude trust prompts (“Do you trust the files in this folder?”) are now auto-accepted during probes to prevent stuck refreshes. Thanks @tobihagemann!

## 0.8.0 — 2025-12-17
- CodexBar is now available via Homebrew: `brew install --cask steipete/tap/codexbar` (updates via `brew upgrade --cask steipete/tap/codexbar`).
- Added session quota notifications for the sliding 5-hour window (Codex + Claude): notifies when it hits 0% and when it’s available again, based only on observed refresh data (including startup when already depleted). Thanks @GKannanDev!

## 0.7.3 — 2025-12-17
- Claude Enterprise accounts whose Claude Code `/usage` panel only shows “Current session” no longer fail parsing; weekly usage is treated as unavailable (fixes #19).

## 0.7.2 — 2025-12-13
- Claude “Open Dashboard” now routes subscription accounts (Max/Pro/Ultra/Team) to the usage page instead of the API console billing page. Thanks @auroraflux!
- Codex/Claude binary resolution now detects mise/rtx installs (shims and newest installed tool version), fixing missing CLI detection for mise users. Thanks @philipp-spiess!
- Claude usage/status probes now auto-accept the first-run “Ready to code here?” permission prompt (when launched from Finder), preventing timeouts and parse errors. Thanks @alexissan!
- General preferences now surface full Codex/Claude fetch errors with one-click copy and expandable details, reducing first-run confusion when a CLI is missing.
- Polished the menu bar “critter” icons: Claude is now a crisper, blockier pixel crab, and Codex has punchier eyes with reduced blurring in SwiftUI/menu rendering.

## 0.7.1 — 2025-12-09
- Menu bar icons now render on a true 18 pt/2× backing with pixel-aligned bars and overlays for noticeably crisper edges.
- PTY runner now preserves the caller’s environment (HOME/TERM/bun installs) while enriching PATH, preventing Codex/Claude
  probes from failing when CLIs are installed via bun/nvm or need their auth/config paths.
- Added regression tests to lock in the enriched environment behavior.
- Fixed a first-launch crash on macOS 26 caused by the 1×1 keepalive window triggering endless constraint updates; the hidden
  window now uses a safe size and no longer spams SwiftUI state warnings.
- Menu action rows now ship with SF Symbol icons (refresh, dashboard, status, settings, about, quit, copy error) for clearer at-a-glance affordances.
- When the Codex CLI is missing, menu and CLI now surface an actionable install hint (`npm i -g @openai/codex` / bun) instead of a generic PATH error.
- Node manager (nvm/fnm) resolution corrected so codex/claude binaries — and their `node` — are found reliably even when installed via fnm aliases or nvm defaults. Thanks @aliceisjustplaying for surfacing the gaps.
- Login menu now shows phase-specific subtitles and disables interaction while running: “Requesting login…” while starting the CLI, then “Waiting in browser…” once the auth URL is printed; success still triggers the macOS notification.
- Login state is tracked per provider so Codex and Claude icons/menus no longer share the same in-flight status when switching accounts.
- Claude login PTY runner detects the auth URL without clearing buffers, keeps the session alive until confirmation, and exposes a Sendable phase callback used by the menu.
- Claude CLI detection now includes Claude Code’s self-updating paths (`~/.claude/local/claude`, `~/.claude/bin/claude`) so PTY probes work even when only the bundled installer is used.

## 0.7.0 — 2025-12-07
- ✨ New rich menu card with inline progress bars and reset times for each provider, giving the menu a beautiful, at-a-glance dashboard feel (credit: Anton Sotkov @antons).

## 0.6.1 — 2025-12-07
- Claude CLI probes stop passing `--dangerously-skip-permissions`, aligning with the default permission prompt and avoiding hidden first-run failures.

## 0.6.0 — 2025-12-04
- New bundled CLI (`codexbar`) with single `usage` command, `--format text|json`, `--status`, and fast `-h/-V`.
- CLI output now shows consistent headers (`Codex 0.x.y (codex-cli)`, `Claude Code <ver> (claude)`) and JSON includes `source` + `status`.
- Advanced prefs install button symlinks `codexbar` into /usr/local/bin and /opt/homebrew/bin; docs refreshed.

## 0.5.7 — 2025-11-26
- Status Page and Usage Dashboard menu actions now honor the icon you click; Codex menus no longer open the Claude status site.

## 0.5.6 — 2025-11-25
- New playful “Surprise me” option adds occasional blinks/tilts/wiggles to the menu bar icons (one random effect at a time) plus a Debug “Blink now” trigger.
- Preferences now include an Advanced tab (refresh cadence, Surprise me toggle, Debug visibility); window height trimmed ~20% for a tighter fit.
- Motion timing eased and lengthened so blinks/wiggles feel smoother and less twitchy.

## 0.5.5 — 2025-11-25
- Claude usage scrape now recognizes the new “Current week (Sonnet only)” bar while keeping the legacy Opus label as a fallback.
- Menu and docs now label the Claude tertiary limit as Sonnet to match the latest CLI wording.
- PATH seeding now uses a deterministic binary locator plus a one-shot login-shell capture at startup (no globbed nvm paths); the Debug tab shows the resolved Codex binary and effective PATH layers.

## 0.5.4 — 2025-11-24
- Status blurb under “Status Page” no longer prefixes the text with “Status:”, keeping the incident description concise.
- PTY runner now registers cleanup before launch so both ends of the TTY and the process group are torn down even when `Process.run()` throws (no leaked fds when spawn fails).

## 0.5.3 — 2025-11-22
- Added a per-provider “Status Page” menu item beneath Usage that opens the provider’s live status page (OpenAI or Claude).
- Status API now refreshes alongside usage; incident states show a dot/! overlay on the status icon plus a status blurb under the menu item.
- General preferences now include a default-on “Check provider status” toggle above refresh cadence.

## 0.5.2 — 2025-11-22
- Release packaging now includes uploading the dSYM archive alongside the app zip to aid crash symbolication (policy documented in the shared mac release guide).
- Claude PTY fallback removed: Claude probes now rely solely on `script` stdout parsing, and the generic TTY runner is trimmed to Codex `/status` handling.
- Fixed a busy-loop on the codex RPC stderr pipe (handler now detaches on EOF), eliminating the long-running high-CPU spin reported in issue #9.

## 0.5.1 — 2025-11-22
- Debug pane now exposes the Claude parse dump toggle, keeping the captured raw scrape in memory for inspection.
- Claude About/debug views embed the current git hash so builds can be identified precisely.
- Minor runtime robustness tweaks in the PTY runner and usage fetcher.

## 0.5.0 — 2025-11-22
- Codex usage/credits now use the codex app-server RPC by default (with PTY `/status` fallback when RPC is unavailable), reducing flakiness and speeding refreshes.
- Codex CLI launches seed PATH with Homebrew/bun/npm/nvm/fnm defaults to avoid ENOENT in hardened/release builds; TTY probes reuse the same PATH.
- Claude CLI probe now runs `/usage` and `/status` in parallel (no simulated typing), captures reset strings, and uses a resilient parser (label-first with ordered fallback) while keeping org/email separate by provider.
- TTY runner now always tears down the spawned process group (even on early Claude login prompts) to avoid leaking CLI processes.
- Default refresh cadence is now 5 minutes, and a 15-minute option was added to the settings picker.
- Claude probes/version detection now start with `--allowed-tools ""` (tool access disabled) while keeping interactive PTY mode working.
- Codex probes and version detection now launch the CLI with `-s read-only -a untrusted` to keep PTY runs sandboxed.
- Codex warm-up screens (“data not available yet”) are handled gracefully: cached credits stay visible and the menu skips the scary parse error.
- Codex reset times are shown for both RPC and TTY fallback, and plan labels are capitalized while emails stay verbatim.

## 0.4.3 — 2025-11-21
- Fix status item creation timing on macOS 15 by deferring NSStatusItem setup to after launch; adds a regression test for the path.
- Menu bar icon with unknown usage now draws empty tracks (instead of a full bar when decorations are shown) by treating nil values as 0%.

## 0.4.2 — 2025-11-21
- Sparkle updates re-enabled in release builds (disabled only for the debug bundle ID).

## 0.4.1 — 2025-11-21
- Both Codex and Claude probes now run off the main thread (background PTY), avoiding menu/UI stalls during `/status` or `/usage` fetches.
- Codex credits stay available even when `/status` times out: cached values are kept and errors are surfaced separately.
- Claude/Codex provider autodetect runs on first launch (defaults to Codex if neither is installed) with a debug reset button.
- Sparkle updates re-enabled in release builds (disabled only for debug bundle ID).
- Claude probe now issues the `/usage` slash command directly to land on the Usage tab reliably and avoid palette misfires.

## 0.4.0 — 2025-11-21
- Claude Code support: dedicated Claude menu/icon plus dual-wired menus when both providers are enabled; shows email/org/plan and Sonnet usage with clickable errors.
- New Preferences window: General/About tabs with provider toggles, refresh cadence, start-at-login, and always-on Quit.
- Codex credits without web login: we now read `codex /status` in a PTY, auto-skip the update prompt, and parse session/weekly/credits; cached credits stay visible on transient timeouts.
- Resilience: longer PTY timeouts, cached-credit fallback, one-line menu errors, and clearer parse/update messages.

## 0.3.0 — 2025-11-18
- Credits support: reads Codex CLI `/status` via PTY (no browser login), shows remaining credits inline, and moves history to a submenu.
- Sign-in window with cookie reuse and a logout/clear-cookies action; waits out workspace picker and auto-navigates to usage page.
- Menu: credits line bolded; login prompt hides once credits load; debug toggle always visible (HTML dump).
- Icon: when weekly is empty, top bar becomes a thick credits bar (capped at 1k); otherwise bars stay 5h/weekly.

## 0.2.2 — 2025-11-17
- Menu bar icon stays static when no account/usage is present; loading animation only runs while fetching (12 fps) to keep idle CPU low.
- Usage refresh first tails the newest session log (512 KB window) before scanning everything, reducing IO on large Codex logs.
- Packaging/signing hardened: strip extended attributes, delete AppleDouble (`._*`) files, and re-sign Sparkle + app bundle to satisfy Gatekeeper.

## 0.2.1 — 2025-11-17
- Patch bump for refactor/relative-time changes; packaging scripts set to 0.2.1 (5).
- Streamlined Codex usage parsing: modern rate-limit handling, flexible reset time parsing, and account rate-limit updates (thanks @jazzyalex and https://jazzyalex.github.io/agent-sessions/).

## 0.2.0 — 2025-11-16
- CADisplayLink-based loading animations (macOS 15 displayLink API) with randomized patterns (Knight Rider, Cylon, outside-in, race, pulse) and debug replay cycling through all.
- Debug replay toggle (`defaults write com.steipete.codexbar debugMenuEnabled -bool YES`) to view every pattern.
- Usage Dashboard link in menu; menu layout tweaked.
- Updated time now shows relative formatting when fresher than 24h; refactored sources into smaller files for maintainability.
- Version bumped to 0.2.0 (4).

## 0.1.2 — 2025-11-16
- Animated loading icon (dual bars sweep until usage arrives); always uses rendered template icon.
- Sparkle embedding/signing fixed with deep+timestamp; notarization pipeline solid.
- Icon conversion scripted via ictool with docs.
- Menu: settings submenu, no GitHub item; About link clickable.

## 0.1.1 — 2025-11-16
- Launch-at-login toggle (SMAppService) and saved preference applied at startup.
- Sparkle auto-update wiring (SUFeedURL to GitHub, SUPublicEDKey set); Settings submenu with auto-update toggle + Check for Updates.
- Menu cleanup: settings grouped, GitHub menu removed, About link clickable.
- Usage parser scans newest session logs until it finds `token_count` events.
- Icon pipeline fixed: regenerated `.icns` via ictool with proper transparency (docs in docs/icon.md).
- Added lint/format configs, Swift Testing, strict concurrency, and usage parser tests.
- Notarized release build "CodexBar-0.1.0.zip" remains current artifact; app version 0.1.1.

## 0.1.0 — 2025-11-16
- Initial CodexBar release: macOS 15+ menu bar app, no Dock icon.
- Reads latest Codex CLI `token_count` events from session logs (5h + weekly usage, reset times); no extra login or browser scraping.
- Shows account email/plan decoded locally from `auth.json`.
- Horizontal dual-bar icon (top = 5h, bottom = weekly); dims on errors.
- Configurable refresh cadence, manual refresh, and About links.
- Async off-main log parsing for responsiveness; strict-concurrency build flags enabled.
- Packaging + signing/notarization scripts (arm64); build scripts convert `.icon` bundle to `.icns`.
