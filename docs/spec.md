---
summary: "CodexBar implementation notes: data sources, refresh cadence, UI, and structure."
read_when:
  - Modifying usage fetching/parsing for Codex or Claude
  - Changing refresh cadence, background tasks, or menu UI
  - Reviewing architecture before feature work
---

# CodexBar – implementation notes

## Data source
- Codex: run `codex /status` inside a native PTY (no tmux, no web/cookie login). We parse the rendered rows for session/weekly limits and credits; when the CLI shows an update prompt we auto-press Down+Enter and retry.
- Account info is decoded locally from `~/.codex/auth.json` (`id_token` JWT → `email`, `chatgpt_plan_type`); no browser scraping involved.
- Claude: run `claude /usage` in a PTY and parse the text panel; retries enter and reports CLI errors verbosely.

## Refresh model
- `RefreshFrequency` presets: Manual, 1m, 2m (default), 5m; persisted in `UserDefaults`.
- Background Task detaches on app start, wakes per cadence, calls `UsageFetcher.loadLatestUsage()`.
- Manual “Refresh now” menu item always available; stale/errors are surfaced in-menu and dim the icon.
- Optional future: auto‑seed a log if none exists via `codex exec --skip-git-repo-check --json "ping"`; currently not executed to avoid unsolicited usage.

## UI / icon
- `MenuBarExtra` only (LSUIElement=YES). No Dock icon. Label replaced with custom NSImage.
- Icon: 20×18 template image; top bar = 5h window, bottom hairline = weekly window; fill represents “percent remaining.” Dimmed when last refresh failed.
- Menu shows 5h + weekly rows (percent left, used, reset time), last-updated time, account email + plan, refresh cadence picker, Refresh now, Quit.

## App structure (Swift 6, macOS 15+)
- `UsageFetcher`: log discovery + parsing, JWT decode for account.
- `UsageStore`: state, refresh loop, error handling.
- `SettingsStore`: persisted cadence.
- `IconRenderer`: template NSImage for bar.
- Entry: `CodexBarApp`.

## Packaging & signing
- `Scripts/package_app.sh`: swift build (arm64), writes `CodexBar.app` + Info.plist, copies `Icon.icns` if present; seeds Sparkle keys/feed.
- `Scripts/sign-and-notarize.sh`: uses APP_STORE_CONNECT_* creds and Developer ID identity (`Y5PE65HELJ`) to sign, notarize, staple, zip (`CodexBar-0.1.0.zip`). Adjust identity/versions as needed.
- Sparkle: Info.plist contains `SUFeedURL` (GitHub Releases appcast) and `SUPublicEDKey` placeholder; updater is `SPUStandardUpdaterController`, menu has “Check for Updates…”.

## Limits / edge cases
- If no `token_count` yet in the latest session, menu shows “No usage yet.”
- Schema changes to Codex events could break parsing; errors surface in the menu.
- Only arm64 scripted; add x86_64/universal if desired.

## Alternatives considered
- Fake TTY + `/status`: unnecessary; structured `token_count` already present in logs after any prompt.
- Browser scrape of `https://chatgpt.com/codex/settings/usage`: skipped (cookie handling & brittleness).

## Learnings / decisions
- About panel: `AboutPanelOptionKey.credits` needs `NSAttributedString`; we supply credits + icon safely.
- Menu palette: keep primary by default, apply `.secondary` only to meta lines, and use `.buttonStyle(.plain)` to avoid tint overriding colors.
- Usage fetch runs off-main via detached task to keep the menu responsive if logs grow.
- Emoji branding lives only in README; app name stays `CodexBar`.
- Swift 6 strict concurrency enabled via `StrictConcurrency` upcoming feature to catch data-race risks early.
