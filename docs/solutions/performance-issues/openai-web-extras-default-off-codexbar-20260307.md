---
module: CodexBar
date: 2026-03-07
problem_type: performance_issue
component: tooling
symptoms:
  - "Hidden chatgpt.com web content could spike to extremely high Energy Impact values in Activity Monitor"
  - "CodexBar battery usage stayed abnormally high even when the app appeared idle"
  - "Users did not realize optional OpenAI web extras were enabled by default"
root_cause: wrong_api
resolution_type: config_change
severity: high
tags: [codexbar, battery-drain, openai-web, webview, chatgpt, defaults]
---

# Troubleshooting: Default OpenAI Web Extras Off

## Problem
CodexBar exposed optional OpenAI dashboard extras through a hidden `chatgpt.com` WebView, but the feature was enabled by default. That created a mismatch between user expectations for a lightweight menu bar app and the real cost of running a hidden single-page web app in the background.

## Environment
- Module: CodexBar
- Affected component: Codex OpenAI web extras
- Date: 2026-03-07

## Symptoms
- Activity Monitor showed extreme energy usage attributed to `https://chatgpt.com` under the CodexBar process tree.
- Users observed battery drain that was out of proportion to the visible work the app was doing.
- The optional setting existed, but it was easy to miss, so affected users often did not know they could disable it.

## What Didn't Work

**Attempted solution 1:** Throttle failed OpenAI dashboard refresh attempts and evict cached WebViews more aggressively.
- **Why it failed:** This reduced the runaway failure loop, but it did not change the product default. Users could still pay the cost of a hidden ChatGPT dashboard without explicitly opting into it.

**Attempted solution 2:** Keep the feature enabled by default and rely on a visible opt-out toggle.
- **Why it failed:** The battery and network cost was too high for a background utility. An opt-out-only design still left many users exposed to behavior they did not expect or understand.

## Solution
Change OpenAI web extras to be off by default for new installs while preserving existing explicit configurations.

**Code changes**
- `SettingsStore` now defaults `openAIWebAccessEnabled` to `false` when no prior preference exists.
- `SettingsStore` now defaults `openAIWebBatterySaverEnabled` to `false`; users can still opt into reduced routine OpenAI web refreshes separately.
- Existing users with an explicit Codex cookie configuration are inferred as enabled so upgrades do not silently break working setups.
- The Codex settings copy now describes the feature as optional and warns about battery and network cost.
- Documentation now labels the OpenAI web dashboard path as optional and off by default.

## Why This Works
The root problem was not that the app had a toggle. The root problem was that an optional feature with heavyweight implementation details was enabled by default.

The OpenAI web extras path uses a hidden `WKWebView` against `chatgpt.com` to gather dashboard-only data. That mechanism is fundamentally more expensive than the main Codex data paths, which already provide the normal information users expect from the app: session usage, weekly usage, reset timers, account identity, plan label, and normal credits remaining.

Making the feature opt-in aligns the default behavior with the actual technical cost:
1. The normal Codex card continues to work without the hidden ChatGPT dashboard.
2. Users only incur the WebView cost if they deliberately choose the extra dashboard data.
3. Existing users with a configured Codex web setup keep their behavior on upgrade instead of being silently broken.

## Prevention
- Do not default-enable optional features that load heavyweight hidden web content in a background utility.
- If a feature depends on a hidden SPA or WebView, require explicit user opt-in unless it is essential to core functionality.
- Prefer direct API or cookie-backed HTTP requests over hidden browser automation for background data collection.
- Surface the operational cost of optional features in the settings copy, not only in debug notes or issue threads.

## Related Issues
- See also: [perf-energy-issue-139-simulation-report-2026-02-19.md](../../perf-energy-issue-139-simulation-report-2026-02-19.md)
- See also: [perf-energy-issue-139-main-fix-validation-2026-02-19.md](../../perf-energy-issue-139-main-fix-validation-2026-02-19.md)
