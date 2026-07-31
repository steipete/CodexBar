# Agent Sessions (prototype)

Track live Codex, Claude Code, and OhMyPi agent sessions — local Mac first, other Macs on the tailnet second — and surface them in the CodexBar menu with click-to-focus of the owning terminal, editor, or desktop window. Discovery is process-backed: a session file or terminal breadcrumb by itself is not evidence that a live session exists.

## Why in CodexBar

CodexBar already parses local agent metadata and ships a bundled CLI on macOS + Linux. Sessions reuse both: the local scanner feeds the menu UI, and the same scanner exposed as `codexbar sessions --json` is what remote Macs run over SSH. No daemon, no new app.

## Data model (CodexBarCore)

```swift
public struct AgentSession: Codable, Sendable, Identifiable {
    public enum Provider: String, Codable, Sendable {
        case codex
        case claude
        case ohMyPi = "oh-my-pi"
    }
    public enum Source: String, Codable, Sendable { case cli, desktopApp, ide, unknown }
    public enum State: String, Codable, Sendable { case active, idle }

    public var id: String // session UUID when resolvable, else "pid:<pid>"
    public var provider: Provider
    public var source: Source
    public var state: State
    public var pid: Int32? // nil only for providers that support a file-only session
    public var cwd: String?
    public var projectName: String?  // last path component of cwd
    public var sessionName: String?  // bounded descriptive title when available
    public var startedAt: Date?
    public var lastActivityAt: Date?
    public var transcriptPath: String?
    public var host: String          // local hostname, or remote host label
}
```

The normalized JSON provider values are `codex`, `claude`, and `oh-my-pi`. `active` means last activity is within the configured active window; an older live process is `idle`. File-only windows apply only to providers and records that explicitly support them: OhMyPi never becomes a file-only session.

## Local scanner (CodexBarCore, no new deps)

`LocalAgentSessionScanner` combines process and bounded metadata signals:

1. **Process scan** — parse `ps -axo pid=,ppid=,lstart=,command=`.
   - Claude Code: command basename `claude` (skip obvious non-agent helpers). Source: path contains `Application Support/Claude/claude-code` → `.desktopApp`, else `.cli`. Deduplicate the wrapper/child pair (desktop can spawn a `disclaimer` parent plus `claude` child with the same argv; keep the child).
   - Codex: basename `codex` with no `app-server`, `--help`, or `--version` argument → `.cli` (TUI or `exec`). `codex app-server` marks the desktop app as present but is not itself a session.
   - OhMyPi: recognize an executable whose basename is `omp`, or a Bun launcher whose command line contains an `omp` executable argument. Obvious helpers such as help/version, smoke-test, and internal worker commands are excluded. This is a process heuristic, not a stable OhMyPi API; launcher and helper behavior is implementation-detail/version-sensitive.
   - Resolve cwd per pid via one batched `lsof -a -d cwd -Fn -p <pid,pid,…>` call (parse `p`/`n` records). Failure → cwd nil, session still listed.

2. **Transcript/session correlation**
   - Claude Code: map cwd to `~/.claude/projects/<escaped-cwd>/` (escape every non-alphanumeric ASCII character to `-`) and select the newest bounded-known JSONL metadata for the live process. Reuse desktop project roots where applicable.
   - Codex: enumerate `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` for today and yesterday (`$CODEX_HOME` respected). Read the first line (`session_meta`: session id, cwd, originator, source). A recent unmatched rollout may be file-only; live `codex` pids match rollouts by cwd (newest wins), and an unmatched live pid is still listed.
   - OhMyPi: resolve roots independently for every live `omp` process. A bounded, best-effort environment lookup supplies only `HOME`, `PI_CONFIG_DIR`, `PI_CODING_AGENT_DIR`, `XDG_DATA_HOME`, `OMP_PROFILE`, and `PI_PROFILE`; the process's exact profile selects its roots, and relative custom-agent paths are resolved against that process's cwd. If the environment is unavailable, the per-process entry is missing or empty, or `HOME` is unusable, ambient profile selectors and custom/config/XDG values are discarded and no transcript metadata is matched; with a valid process `HOME` but missing other keys, only the safe default-profile root derived from that `HOME` is considered, and the process falls back to `pid:<pid>` when no safe root can be proven. A root or named profile learned from another process is never reused. Records are accepted only when `modifiedAt >= process.startedAt` (equal timestamps are valid), allocated in deterministic order (newest mtime, then id, then URL), and a URL is used by at most one process. Use only the session id, cwd, timestamp, and a sanitized bounded title; an unmatched live process uses the `pid:<pid>` fallback. An OhMyPi file, breadcrumb, or stale record without a matched live process never creates an AgentSession.
   - The OhMyPi session schema, root layout, profile variables, and process/launcher recognition are implementation details and version-sensitive. They are deliberately not a public compatibility contract.
   - Never read whole Codex, Claude Code, or OhMyPi transcripts. Directory enumeration, file metadata, and title/session-header parsing are bounded by the scanner budget and entry/record limits. OhMyPi has a separate directory-metadata budget initialized with the same configured entry/depth/time limits (including the adaptive limit), so its traversal cannot consume the budget reserved for Codex rollouts and Claude transcript discovery. Future timestamps are clamped to the scan time.

The scanner is `Sendable`; ps/lsof parsing and session-header parsing are dedicated pure parser types fed by strings or bounded fixture data so tests do not need live processes. Process command lines, cwd values, and the allowlisted process-environment values are sensitive metadata and are retained only long enough to correlate a row under the privacy rules below. Environment reads are bounded and fail closed; raw environment, stdout, and stderr contents are never logged.

## CLI (CodexBarCLI)

- `codexbar sessions` — table; `--json` — `[AgentSession]` (stable field names above; ISO-8601 dates).
- `codexbar sessions focus <id>` — macOS only: focus the session's terminal window (see Focus). Exit 1 if id unknown, 2 if focus failed.
- Follows existing `CLI*Command.swift` conventions. Works on Linux for listing (ps/proc paths guarded), focus is Darwin-only.

## Remote hosts (CodexBarCore + app)

`RemoteSessionFetcher`:

- Host list = manual entries (settings, SSH destinations like `steipete@clawmac`) ∪ automatic Tailscale discovery (no-op when tailscale is absent): run `tailscale status --json` (PATH, then `/Applications/Tailscale.app/Contents/MacOS/Tailscale`), take online peers with `"OS": "macOS"|"linux"`, use the first `DNSName` label as host. Local host excluded.
- Fetch per host (parallel, 5 s budget): `ssh -o BatchMode=yes -o ConnectTimeout=3 <host> sh -lc 'codexbar sessions --json'` with fallback to the bundled app CLI path (resolve the canonical bundled location from `Scripts/package_app.sh` and hardcode it as fallback: `… || <bundled-path> sessions --json`). Host errors are non-fatal: host shown as unreachable, others still render.
- Remote focus: fire-and-forget `ssh <host> sh -lc 'codexbar sessions focus <id>'`.
- Refresh: local scan every 30 s while the status item exists, remote every 60 s and immediately on menu open; both are skipped when Agent Sessions is off. Reuse existing refresh loop plumbing rather than new timers if it fits.

## Menu UI (CodexBar app)

- New menu section **Agent Sessions (N)** (N = total, all hosts) above the settings/footer area, built through the existing `MenuDescriptor` seam so it is testable headlessly.
- Local sessions first, then one group per remote host (`clawmac — 2`; unreachable hosts greyed with a tooltip). Row: state dot (● active / ○ idle), provider glyph (`⌘` Codex, `✦` Claude Code, `π` OhMyPi), project or descriptive label — provider · source · age.
- Click local row → `SessionWindowFocuser`. Click remote row → the existing remote focus SSH call.
- Settings: the **Agent sessions** group contains one enable toggle (default off), a label-style picker, and a manual hosts text field (comma-separated); Tailscale discovery is on while the feature is enabled.

The setting is intentionally separate from adaptive activity awareness. When Agent Sessions is enabled, local rows are retained and remote discovery/fetching is allowed. Turning it off clears published local and remote session rows and suppresses remote fetches. If the user separately grants adaptive-agent-aware refresh, local metadata may still be sampled for the activity timestamp used by refresh policy, but session identities, paths, and rows remain cleared while Agent Sessions is off.

## Focus (macOS, app + CLI shared in Core or app-adjacent target)

`SessionWindowFocuser`:

1. pid → walk the ppid chain to the nearest ancestor whose `NSRunningApplication.bundleIdentifier` is a known terminal/editor host: Ghostty, iTerm2, Apple Terminal, Warp, WezTerm, kitty, Alacritty, VS Code, Cursor, Zed, Claude desktop (`com.anthropic.claudefordesktop`). Fallback: the app owning the pid.
2. Activate the app, then AX (`AXUIElementCreateApplication` → `AXWindows`): raise the window whose title contains projectName or the cwd tail; fallback to the frontmost window of that app. Requires Accessibility permission — call `AXIsProcessTrustedWithOptions` with prompt on first use; degrade gracefully (activate app only) when untrusted.
3. File-only sessions (no pid): Claude desktop → activate Claude.app; Codex desktop → activate Codex.app; OhMyPi has no file-only focus target.

Tmux pane / terminal-tab precision is out of scope for the prototype.

## Privacy

Project labels remain the default because thread/session titles, cwd values, process command lines, and process-environment values can contain sensitive text. Descriptive labels are opt-in. CodexBar reads only bounded metadata needed for correlation and display; it does not load prompts, tool payloads, or whole transcripts, does not modify provider state, and does not persist title text separately. OhMyPi metadata is read only under the root resolved for that process and only contributes to a row associated with a live process. Environment acquisition is best-effort and allowlisted to the six root/profile keys; raw environment, stdout, and stderr are never logged. Remote discovery and SSH fetching occur only while Agent Sessions is enabled.

## Tests (Tests/CodexBarTests)

Fixture-driven, no live processes, no Keychain/AX:

- ps output parser: desktop `disclaimer`+`claude` dedupe, codex vs `codex app-server`, OhMyPi `omp` and Bun launcher recognition, and helper exclusion.
- lsof `-Fn` parser.
- Claude cwd escaping → project dir mapping; newest-jsonl selection (temporary dirs).
- Codex rollout first-line parse → AgentSession, file-only window cutoff.
- OhMyPi per-process environment/profile resolution (including same-cwd isolation), inaccessible-environment safe fallback/PID-only behavior, process-start freshness (including equal mtime), deterministic one-URL allocation, bounded metadata parsing, and independent-budget preservation of Codex/Claude metadata.
- Tailscale status JSON → host list (fixture; offline/iOS peers excluded).
- Sessions JSON round-trip (including normalized `oh-my-pi` provider value).
- Menu section descriptor: provider glyphs, counts, grouping, unreachable-host rendering, focus action mapping, and settings privacy cases.

## Non-goals (prototype)

Claude.ai chat sessions; Codex cloud tasks; historical session browsing/analytics; “waiting on permission” state; tmux pane/tab focus; Bonjour/mDNS; persistent remote daemon or push transport; widget changes. No new SPM dependencies. OhMyPi's on-disk schema and launcher heuristics are not promised as a stable integration API.

## Verification targets

Focused parser/metadata fixtures should cover the behavior above. The CLI should produce plausible `codexbar sessions --json` output on a host where the relevant live processes are present; no claim is made that a stale session file or breadcrumb is live.
