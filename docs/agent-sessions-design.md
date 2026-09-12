# Agent Sessions design

CodexBar tracks live Codex, Claude Code, and Pi-family agent sessions locally and over SSH. Discovery is process-backed: a transcript, session file, or terminal breadcrumb by itself is not evidence that a session is live.

## Data model

`AgentSession.Provider` contains `codex`, `claude`, and `pi`. Pi-family rows additionally carry `AgentSession.Dialect.pi` or `.omp`; other providers leave `dialect` absent. A resolved upstream session ID is preferred, while an unmatched process uses `pid:<pid>`.

The v1 JSON protocol remains a top-level array restricted to `codex` and `claude`. The v2 protocol retains the same array shape and adds current providers and optional fields, including Pi-family dialects. Remote fetching negotiates v2 first and falls back to v1 for mixed-version compatibility.

## Local scanner

`LocalAgentSessionScanner` combines bounded process and metadata signals. macOS process and cwd discovery stays in-process through libproc; Linux uses the existing guarded `ps` and `/proc` paths.

Pi-family processes are handed to one `PiFamilySessionScanner`:

- Plain pi uses process title `pi`; upstream also marks the process with `PI_CODING_AGENT=true`, which CodexBar does not need to read. Its default root is `~/.pi/agent/sessions`, whose project buckets encode cwd as `--<escaped-cwd>--`. A version-3 `session` header supplies id, timestamp, and cwd. The latest bounded `session_info.name` supplies the optional label.
- OMP uses process title/executable `omp`, including its Bun launcher form. It supports default, named-profile, and XDG roots; hashed `home|tmp|abs-<basename>-<sha256>` buckets; legacy bucket names; title-slot headers; and the legacy header-title form.
- `--session-dir` resolves to a direct session directory for either dialect. The scanner also honors custom-directory/profile values already present in its own environment, and plain pi resolves project-over-global `settings.json` `sessionDir` values. Relative paths use the live process cwd and leading `~` uses the scanner home.
- Profile flags are read from argv. Standard OMP profile directories can also be enumerated from their bounded roots. Custom roots and profiles that exist only in the target process remain unresolved because reading that process's environment would capture unrelated secrets. Those processes still produce PID-only rows.
- A record matches only when its normalized cwd equals the process cwd, its modification time is no older than process start, and its URL has not already been assigned. Records sort newest-first with deterministic id/path tie-breaks.
- Pi-family records never become file-only rows. This is especially important for plain pi, which creates its filename before launch but delays materializing JSONL until the first assistant message.

The Pi-family scan receives its own directory entry/time budget, preserving the independent Codex rollout and Claude transcript budgets. Header reads are bounded, pi name lookup uses bounded head/tail windows, future modification dates are clamped to scan time, and displayed titles are stripped of control characters and limited to 64 Unicode scalars.

The same deadline also gates work after enumeration: file-type inspection, Codex modification-time reads, Pi-family path canonicalization, and queued Claude Desktop root probes stop starting work once their budget expires. An in-flight filesystem call can still finish after the deadline; this is a best-effort work budget, not an interruptible wall-clock timeout. Entry counts, depth limits, root selection, and PID-only fallback behavior are unchanged.

## Presentation and focus

The menu uses `⌘` for Codex, `✦` for Claude Code, and `π` for the Pi family. Pi rows show their dialect tag (`pi` or `omp`) rather than a second provider name. The CLI table includes a `DIALECT` column. Project labels remain the default because descriptive titles can contain sensitive text.

Local focus walks from the session PID to the owning terminal/editor application and raises the best matching window when Accessibility permission is available. Remote focus invokes the same command over SSH. Pi-family sessions have no file-only focus target.

## Privacy and safety

CodexBar never invokes `ps eww`, reads `/proc/<pid>/environ`, or otherwise captures full target-process environments for session discovery. It reads only bounded session metadata under resolved roots, never loads prompt/tool transcript bodies for this feature, never changes upstream session state, and never persists extracted titles separately.

## Tests

Fixture directories cover pi version-3 headers and `session_info`, OMP title slots, hashed and legacy project buckets, XDG roots, resolvable custom directories, missing-JSONL PID fallbacks, process classification/correlation, one-record allocation, 64-scalar title bounds, JSON protocol compatibility, menu dialect tags, and remote v2-before-v1 negotiation. Tests use stubs and temporary roots; they do not probe live accounts, Keychain, or Accessibility.

## Non-goals

Historical browsing/analytics, cloud chat/task sessions, permission-waiting state, exact tmux pane focus, a persistent remote daemon, and treating either upstream on-disk dialect as a public compatibility guarantee are out of scope.
