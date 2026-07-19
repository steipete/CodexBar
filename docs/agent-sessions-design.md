# Agent Sessions (prototype)

Track live Codex + Claude Code agent sessions — local Mac first, other Macs on the tailnet second — and surface them in the CodexBar menu with click-to-focus of the owning terminal window.

## Why in CodexBar

CodexBar already parses `~/.claude/projects` JSONL (cost scanner) and ships a bundled CLI on macOS + Linux. Sessions reuse both: the local scanner feeds the menu UI, and the same scanner exposed as `codexbar sessions --json` is what remote Macs run over SSH. No daemon, no new app.

## Data model (CodexBarCore)

```swift
public struct AgentSession: Codable, Sendable, Identifiable {
    public enum Provider: String, Codable, Sendable { case codex, claude }
    public enum Source: String, Codable, Sendable { case cli, desktopApp, ide, unknown }
    public enum State: String, Codable, Sendable { case active, idle }

    public var id: String            // session UUID when resolvable, else "pid:<pid>"
    public var provider: Provider
    public var source: Source
    public var state: State
    public var pid: Int32?           // nil for file-only (e.g. Codex desktop) sessions
    public var cwd: String?
    public var projectName: String?  // last path component of cwd
    public var startedAt: Date?
    public var lastActivityAt: Date? // transcript mtime
    public var transcriptPath: String?
    public var host: String          // local hostname, or remote host label
}
```

`active` = last activity ≤ 120 s ago. `idle` = live process (or recent file) with older activity. Constants live in one `SessionScanConfig` struct (activeWindow 120 s, fileOnlyWindow 30 min) so thresholds are tunable/testable.

## Local scanner (CodexBarCore, no new deps)

`LocalAgentSessionScanner` combines two signals:

1. **Process scan** — parse `ps -axo pid=,ppid=,lstart=,command=`.
   - Claude: command basename `claude` (skip obvious non-agent helpers). Source: path contains `Application Support/Claude/claude-code` → `.desktopApp`, else `.cli`. Deduplicate the wrapper/child pair (desktop spawns `disclaimer` parent + `claude` child with same argv; keep the child).
   - Codex: basename `codex` with no `app-server` argument → `.cli` (TUI or `exec`). `codex app-server` marks the desktop app as present but is not itself a session.
   - cwd per pid via one batched `lsof -a -d cwd -Fn -p <pid,pid,…>` call (parse `p`/`n` records). Failure → cwd nil, session still listed.
2. **Transcript correlation**
   - Claude: cwd → `~/.claude/projects/<escaped-cwd>/` (escape: every non-alphanumeric ASCII → `-`), newest `*.jsonl` by mtime → session id (filename UUID), lastActivityAt (mtime). Also reuse `ClaudeDesktopProjectsLocator` roots so desktop local-agent-mode sessions resolve.
   - Codex: enumerate `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` for today + yesterday (`$CODEX_HOME` respected). Read only the first line (`session_meta`: `session_id`, `cwd`, `originator`, `source`). File with mtime ≤ fileOnlyWindow and no matching live pid → file-only session, source from `originator` (`codex_exec`/`exec` → `.cli`; ide-ish originators → `.ide`; desktop → `.desktopApp`). Live `codex` pids match to rollouts by cwd (newest wins); unmatched live pid still listed with nil transcript.
   - Never read more than the first line of any JSONL; never load whole transcripts.

Scanner is `Sendable`, pure functions where possible; ps/lsof output parsing lives in dedicated parser types fed by strings so tests use fixtures.

## CLI (CodexBarCLI)

- `codexbar sessions` — table; `--json` — `[AgentSession]` (stable field names above; ISO-8601 dates).
- `codexbar sessions focus <id>` — macOS only: focus the session's terminal window (see Focus). Exit 1 if id unknown, 2 if focus failed.
- Follows existing `CLI*Command.swift` conventions. Works on Linux for listing (ps/proc paths guarded), focus is Darwin-only.

## Remote hosts (CodexBarCore + app)

`RemoteSessionFetcher`:

- Host list = manual entries (settings, ssh destinations like `steipete@clawmac`) ∪ automatic Tailscale discovery (no-op when tailscale is absent): run `tailscale status --json` (PATH, then `/Applications/Tailscale.app/Contents/MacOS/Tailscale`), take online peers with `"OS": "macOS"|"linux"`, use first `DNSName` label as host. Local host excluded.
- Fetch per host (parallel, 5 s budget): `ssh -o BatchMode=yes -o ConnectTimeout=3 <host> sh -lc 'codexbar sessions --json'` with fallback to the bundled app CLI path (resolve the canonical bundled location from `Scripts/package_app.sh` and hardcode it as fallback: `… || <bundled-path> sessions --json`). Host errors are non-fatal: host shown as unreachable, others still render.
- Remote focus: fire-and-forget `ssh <host> sh -lc 'codexbar sessions focus <id>'`.
- Refresh: local scan every 30 s while the status item exists (cheap), remote every 60 s and immediately on menu open; both skipped when the feature is off. Reuse existing refresh loop plumbing rather than new timers if it fits.

## Menu UI (CodexBar app)

- New menu section **Agent Sessions (N)** (N = total, all hosts) above the settings/footer area, built through the existing `MenuDescriptor`-style seam so it's testable headless.
- Local sessions first, then one group per remote host (`clawmac — 2`, unreachable hosts greyed with a tooltip). Row: state dot (● active / ○ idle), provider glyph, `projectName — provider · source · 12m`.
- Click local row → `SessionWindowFocuser`. Click remote row → remote focus ssh call.
- Settings: "Sessions" group — a single enable toggle (default on) plus a manual hosts text field (comma-separated); Tailscale discovery is always on while the feature is enabled. Persist in `SettingsStore` like neighboring prefs.

## Focus (macOS, app + CLI shared in Core or app-adjacent target)

`SessionWindowFocuser`:

1. pid → walk ppid chain to the nearest ancestor whose `NSRunningApplication.bundleIdentifier` is a known terminal/editor host: Ghostty, iTerm2, Apple Terminal, Warp, WezTerm, kitty, Alacritty, VS Code, Cursor, Zed, Claude desktop (`com.anthropic.claudefordesktop`). Fallback: the app owning the pid.
2. Activate the app, then AX (`AXUIElementCreateApplication` → `AXWindows`): raise the window whose title contains projectName or the cwd tail; fallback to frontmost window of that app. Requires Accessibility permission — call `AXIsProcessTrustedWithOptions` with prompt on first use; degrade gracefully (activate app only) when untrusted.
3. File-only sessions (no pid): Claude desktop → activate Claude.app; Codex desktop → activate Codex.app; otherwise no-op with log.

tmux pane / terminal-tab precision is out of scope for the prototype.

## Tests (Tests/CodexBarTests)

Fixture-driven, no live processes, no Keychain/AX:

- ps output parser: desktop `disclaimer`+`claude` dedupe, codex vs `codex app-server`, weird argv.
- lsof `-Fn` parser.
- Claude cwd escaping → project dir mapping; newest-jsonl selection (temp dirs).
- Codex rollout first-line parse → AgentSession (fixture JSONL), file-only window cutoff.
- Tailscale status JSON → host list (fixture; offline/iOS peers excluded).
- Sessions JSON round-trip (CLI output schema stability).
- Menu section descriptor: counts, grouping, unreachable-host rendering.

## Non-goals (prototype)

Claude.ai chat sessions; Codex cloud tasks; historical session browsing/analytics; "waiting on permission" state; tmux pane/tab focus; Bonjour/mDNS; persistent remote daemon or push transport; widget changes. No new SPM dependencies.

## Proof

`make check` clean; `make test` (or focused `swift test --filter` covering the new tests) green; `swift run CodexBarCLI sessions --json` produces plausible output on this Mac.
