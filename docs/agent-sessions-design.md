---
summary: "Agent Sessions discovery, protocol versions, presentation, and privacy boundaries."
read_when:
  - Changing local or SSH agent-session discovery
  - Reviewing Agent Sessions architecture
---

# Agent Sessions design

CodexBar discovers Codex, Claude Code, and Pi-family agent sessions locally and over SSH. Local discovery correlates processes with bounded metadata and can show recent Codex file-only fallback rows. Those fallback rows do not prove process lifetime and never activate Stay Awake.

## Data model

`AgentSession.Provider` contains `codex`, `claude`, and `pi`. Pi-family rows additionally carry `AgentSession.Dialect.pi` or `.omp`; other providers leave `dialect` absent. A resolved upstream session ID is preferred, while an unmatched process uses `pid:<pid>`.

The v1 JSON protocol remains a top-level array restricted to `codex` and `claude`. The v2 protocol retains the same array shape and adds current providers and optional fields, including Pi-family dialects. Remote fetching negotiates v2 first and falls back to v1 for mixed-version compatibility.

## Local scanner

`LocalAgentSessionScanner` combines bounded process and metadata signals. macOS process and cwd discovery stays in-process through libproc; Linux uses the existing guarded `ps` and `/proc` paths.

On macOS, Codex and Claude bundle checks, provider identity, and CLI/desktop source labels use the preserved executable argument, so prompt paths do not change session classification. Existing executable allowlists, wrapper handling, and command-only fallbacks still apply.
Pi-family detection also uses the executable and script arguments, so a prompt mentioning a Claude path does not change its provider.

Pi-family processes are handed to one `PiFamilySessionScanner`:

- Plain pi uses process title `pi`; upstream also marks the process with `PI_CODING_AGENT=true`, which CodexBar does not need to read. Its default root is `~/.pi/agent/sessions`, whose project buckets encode cwd as `--<escaped-cwd>--`. A version-3 `session` header supplies id, timestamp, and cwd. The latest bounded `session_info.name` supplies the optional label.
- OMP uses process title/executable `omp`, including its Bun launcher form. It supports default, named-profile, and XDG roots; hashed `home|tmp|abs-<basename>-<sha256>` buckets; legacy bucket names; title-slot headers; and the legacy header-title form.
- `--session-dir` resolves to a direct session directory for either dialect. The scanner also honors custom-directory/profile values already present in its own environment, and plain pi resolves project-over-global `settings.json` `sessionDir` values. Relative paths use the live process cwd and leading `~` uses the scanner home.
- Profile flags are read from argv. Standard OMP profile directories can also be enumerated from their bounded roots. Custom roots and profiles that exist only in the target process remain unresolved because reading that process's environment would capture unrelated secrets. Those processes still produce PID-only rows.
- A record matches only when its normalized cwd equals the process cwd, its modification time is no older than process start, and its URL has not already been assigned. Records sort newest-first with deterministic id/path tie-breaks.
- Pi-family records never become file-only rows. This is especially important for plain pi, which creates its filename before launch but delays materializing JSONL until the first assistant message.

The Pi-family scan receives its own directory entry/time budget, preserving the independent Codex rollout and Claude transcript budgets. Header reads are bounded, pi name lookup uses bounded head/tail windows, future modification dates are clamped to scan time, and displayed titles are stripped of control characters and limited to 64 Unicode scalars.

The deadline also gates file-type inspection, Codex modification-time reads, Pi-family path canonicalization, and queued Claude Desktop root probes. In-flight filesystem calls can finish after the deadline; this is a best-effort work budget, not an interruptible timeout.

## Presentation and focus

The menu uses `⌘` for Codex, `✦` for Claude Code, and `π` for the Pi family. Pi rows show their dialect tag (`pi` or `omp`) rather than a second provider name. The CLI table includes a `DIALECT` column. Project labels remain the default because descriptive titles can contain sensitive text.

Local focus walks from the session PID to the owning terminal/editor application and raises the best matching window when Accessibility permission is available. Remote focus invokes the same command over SSH. Pi-family sessions have no file-only focus target.

## Privacy and safety

CodexBar never invokes `ps eww`, reads `/proc/<pid>/environ`, or otherwise captures full target-process environments for session discovery. It reads only bounded session metadata under resolved roots, never loads prompt/tool transcript bodies for this feature, never changes upstream session state, and never persists extracted titles separately.

## Stay Awake

Settings → Menu → Agent Sessions → **Stay Awake** is off by default and local to this Mac. It scans locally every 30 seconds without enabling the sessions menu or remote discovery. One `PreventUserIdleSystemSleep` assertion stays active while at least one session has a positive PID, including idle processes waiting for a prompt. Remote sessions and file-only rollouts do not count. The menu shows “Stay Awake: local agent session is live” while active.

The assertion releases at the next scan with no process-backed sessions, immediately on disablement or quit, and through macOS on a crash. Stale scans cannot reacquire it after disablement or shutdown; failed acquisitions retry on the next scan. Stay Awake can use battery power. It cannot wake a Mac or prevent display, explicit, or lid-close sleep, and has no timer, grace period, or always-on mode.

Final store teardown cancels its tasks and releases an owned assertion on the thread that drops the last reference, without a main-actor cleanup hop. Live state changes remain on the main actor; teardown uses Sendable task handles and the thread-safe assertion-release closure.

## Non-goals

Historical browsing/analytics, cloud chat/task sessions, permission-waiting state, exact tmux pane focus, a persistent remote daemon, and treating either upstream on-disk dialect as a public compatibility guarantee are out of scope.
