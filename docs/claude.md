---
summary: "Plan for adding Claude Code support to CodexBar (detect, toggle, icon, menu UX)."
read_when:
  - Planning or implementing Claude/dual-provider support
  - Adjusting menu-bar icons or usage rows for Claude
  - Estimating work for Claude CLI detection or settings
---

# Claude support plan (CodexBar)

Goal: add optional Claude Code usage alongside Codex, with a Claude-themed menu bar icon and independent on/off toggles.

## Proposed UX
- On launch, detect availability:
  - Codex CLI: `codex --version`.
  - Claude Code CLI: `claude --version`.
- Settings: two checkboxes, “Show Codex” and “Show Claude”; display detected version number next to each (e.g., “Claude (2.0.44)” or “Not installed”).
- Menu bar:
- When both are enabled, render a Claude-specific template icon; inside the menu content show two usage rows (Codex 5h/weekly, Claude session/week). Keep current icon style for Codex-only, Claude icon for Claude-only.
- If neither source is enabled, show empty/dim bars with a hint to enable a source.
- Refresh: reuse existing cadence; Claude probe runs only if Claude is enabled and present.

### Claude menu-bar icon (crab notch homage)
- Base two-bar metaphor remains.
- Top bar: add two 1 px “eye” cutouts spaced by 2 px; add 1 px outward bumps (“claws”) on each end; same height/weight as current.
- Bottom bar: unchanged hairline.
- Size: 20×18 template, 1 px padding; monochrome-friendly; substitute this template whenever Claude is enabled (or use Codex icon for Codex-only).

## Data path (Claude)

### How we fetch usage now (no tmux)
- We launch the Claude CLI inside a pseudo-TTY using `TTYCommandRunner`.
- Driver steps:
  1) Boot loop waits for the TUI header and handles first-run prompts:
     - “Do you trust the files in this folder” → send `1` + Enter
     - “Select a workspace” → send Enter
     - Telemetry `(y/n)` → send `n` + Enter
     - Login prompts → abort with a nice error (“claude login”).
  2) Send the `/usage` slash command directly (type `/usage`, press Enter once) so we land on the Usage tab.
  3) Re-press Enter every ~1.5s (Claude sometimes drops the first one under load).
  4) If still no usage after a few seconds, re-send `/usage` + Enter up to 3 times.
  5) Stop as soon as the buffer contains both “Current session” and “Current week (all models)”.
  6) Keep reading ~2s more so percent lines are captured cleanly, then exit.
- Parsing:
  - We strip ANSI codes, then look for percent lines within 4 lines of these headers:
    - `Current session`
    - `Current week (all models)`
    - `Current week (Sonnet only)` (optional)
  - `X% used` is converted to `% left = 100 - X`; `X% left` is used as-is.
  - If the CLI surfaces `Failed to load usage data` with a JSON blob (e.g. `authentication_error` + `token_expired`),
    we surface that message directly ("Claude CLI token expired. Run `claude login`"), rather than the generic
    "Missing Current session" parse failure.
  - We also extract `Account:` and `Org:` lines when present.
- Strictness: if Session or Weekly blocks are missing, parsing fails loudly (no silent “100% left” defaults).
- Resilience: `ClaudeStatusProbe` retries once with a slightly longer timeout (20s + 6s) to ride out slow redraws or ignored Enter presses.

### What we display
- Session and weekly usage bars; Sonnet-only weekly limit if present.
- Account line prefers Claude CLI data (email + login method) and falls back to Codex auth only if Claude did not expose email. Plan is shown verbatim from Claude (no capitalization).

## Implementation steps
1) Settings model: add provider flags + detected versions; persist in UserDefaults.
2) Detection: on startup, run `codex --version` / `claude --version` once (background) and cache strings.
3) Provider abstraction: allow Codex, Claude, Both; gate refresh loop per selection.
4) Bundle script: add `Resources/claude_usage_capture.sh`, mark executable at runtime before launching.
5) ClaudeUsageFetcher: small async wrapper that runs the script, decodes JSON, maps to UI model.
6) IconRenderer: accept a style enum; use new Claude template image when Claude is enabled (or both).
7) Menu content: conditionally show Codex row, Claude row, or an empty-state message when none enabled.
8) Tests: fixture JSON parsing; guard the runtime script test behind an env flag.

## Open items / decisions
- Which template asset to use for the Claude icon (color vs monochrome template); default to a monochrome template PDF sized 20×18.
- Whether to auto-enable Claude when detected the first time; proposal: keep default off, show “Detected Claude 2.0.44 (enable in Settings)”.
- Weekly vs session reset text: display the string parsed from the CLI; do not attempt to compute it locally.

## Debugging tips
- Quick live probe: `LIVE_CLAUDE_FETCH=1 swift test --filter liveClaudeFetchPTY` (prints raw PTY output on failure).
- Manually drive the runner: `swift run claude-probe` (if you add a temporary target) or reuse the TTYCommandRunner from a Swift REPL.
- Check the raw text: log the buffer before ANSI stripping if parsing fails—look for stuck autocomplete lists instead of the Usage pane.
- Things that commonly break:
  - Claude CLI not logged in (`claude login` needed).
  - CLI auth token expired: the Usage pane shows `Error: Failed to load usage data: {"error_code":"token_expired", …}`;
    rerun `claude login` to refresh tokens. CodexBar now surfaces this message directly.
  - Enter ignored because the CLI is “Thinking” or busy; rerun with longer timeout or more Enter retries.
  - Running inside tmux/screen: our PTY driver is standalone, so disable tmux for this path.
  - Settings > General now shows the last Claude fetch error inline under the toggle to make it clear why usage is stale.
- Codex parity: when credits are missing because the Codex CLI shows an update prompt, our PTY driver now auto-sends Down+Enter, re-runs `/status`, and retries once with a longer timeout; if it still fails, run `LIVE_CODEX_STATUS=1 swift test --filter liveCodexStatus` to dump the raw screen.
- To rebuild and reload the menubar app after code changes: `./scripts/compile_and_run.sh`. Ensure the packaged app is restarted so the new PTY driver is in use.
