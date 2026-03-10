# CodexBar 🎚️ - May your tokens never run out. (LARKIN FORK)

Tiny macOS 14+ menu bar app that keeps your Codex, Claude, Cursor, Gemini, Antigravity, Droid (Factory), Copilot, z.ai, Kiro, Vertex AI, Augment, Amp, JetBrains AI, and OpenRouter limits visible (session + weekly where available) and shows when each window resets. One status item per provider (or Merge Icons mode with a provider switcher and optional Overview tab); enable what you use from Settings. No Dock icon, minimal UI, dynamic bar icons in the menu bar.

<img src="codexbar.png" alt="CodexBar menu screenshot" width="520" />

> ![IMPORTANT]
> This is a FORKED project. I'll tell you why I did that below. 
>
> That being said, you should check out https://github.com/steipete/CodexBar for the original project...
>
> But you should still probably star both.

# Differences from the Original CodexBar

## Auth Changes

This is actually inspiration from a pretty slept on project: https://github.com/richhickson/claudecodeusage

I really like this project because it's dead simple. There are also probably ~50 different Github repos doing the same thing where it's a MacOS Menu Bar to track <insert generic AI lab's CLI tool>'s usage. That's all great. That's the world we're living in when software is that cheap.

steipete's is probably the most popular because of the wide range of tooling support. I fucking hate it because the auth model is an absolute joke. Does it need to DDOS your computer with notifications saying it basically needs FDA, macOS security permissions, AND keychain access? It scrapes browser cookies, etc, etc. 

That's fine, but the beauty of claudecodeusage is... it just works based on your existing auth tokens from running either `claude` or `codex` in your preferred shell.

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
- [OpenRouter](docs/openrouter.md) — API token for credit-based usage tracking across multiple AI providers.
- Open to new providers: [provider authoring guide](docs/provider.md).

## Projected Usage

I like the notion of pace, but I think it's even more helpful to see the week over week pace. I also want to see it visually , so that's why there is a `Weekly Projection` option. 

## Features
- Multi-provider menu bar with per-provider toggles (Settings → Providers).
- Session + weekly meters with reset countdowns.
- Optional Codex web dashboard enrichments (code review remaining, usage breakdown, credits history).
- Local cost-usage scan for Codex + Claude (last 30 days).
- Provider status polling with incident badges in the menu and icon overlay.
- Merge Icons mode to combine providers into one status item + switcher, with an optional Overview tab for up to three providers.
- Refresh cadence presets (manual, 1m, 2m, 5m, 15m).
- Bundled CLI (`codexbar`) for scripts and CI (including `codexbar cost --provider codex|claude` for local cost usage); Linux CLI builds available.
- WidgetKit widget mirrors the menu card snapshot.
- Privacy-first: on-device parsing by default; browser cookies are opt-in and reused (no passwords stored).

## 5 hour Window Pace

I like the notion of pace, but I think it should also render for the 5 hour windows for Codex and Claude.

## Coloring of the Icons

I want to look at my menu bar and immediately know my CC usage or my Codex usage. @richhickson's project does that better by showing 🟢🟡🔴 so I wanted to do something similar with my version of CodexBar, but instead I wanted to color the claude / codex menu bar options. 

![Color Gradient Usage](Public/bar-usage-pace.png)

Ya see how it's colored. 

## Bar vs Dot dividing Usage vs Pace 

See this: 

![Bar vs Dot dividing Usage vs Pace](Public/bar-usage-pace.png)

and this new option:

![Separator Option](Public/separator-option.png)


## Better Menu Bar Configurations

More flexibility for your menu bar again:

### Menu Bar Options (Part 1)

![Menu Bar Options Part 1](Public/menu-bar-options-pt1.png)

### Menu Bar Options (Part 2)

![Menu Bar Options Part 2](Public/menu-bar-options-pt2.png)




