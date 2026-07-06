# AdaptiveReplayKit

Fork-only adaptive-refresh replay harness (never upstreamed). It lets the fork answer
"how would a different refresh-timing policy have behaved on this machine's real
usage history" without touching the live app or any provider.

## How it fits together

- **Trace recording** (`Sources/CodexBar/AdaptiveRefreshTraceRecording.swift`, app target):
  OFF by default, gated on the `adaptiveRefreshTraceEnabled` defaults key. When enabled,
  it appends one JSONL line per `AdaptiveRefreshTraceRecord` (`AdaptiveRefreshTrace.swift`)
  to `adaptive-refresh-trace.jsonl` for four event kinds: `decision`, `menuOpen`,
  `refreshCompleted`, `timerAdvanced`.
- **Parsing** (`AdaptiveRefreshTraceParser.swift`): strict by default — a malformed line
  fails the whole parse, since a trace is acceptance evidence for replay metrics.
- **Replay** (`ReplayEngine.swift`, `ReplayPolicy.swift`, `BaselinePolicies.swift`): simulates
  a candidate policy's tick schedule against a trace's ground-truth `menuOpen`/signal events
  and reports `ReplayMetrics.swift` (refresh count, staleness at menu-open, constrained-tier
  compliance).
- **CLI** (`Sources/AdaptiveReplayCLI`): thin wrapper — parses a trace file, runs one or more
  policies through `ReplayEngine`, prints the table/JSON.

## Coding-activity shadow-mode signal (A/B layers)

`decision` records optionally carry a `CodingActivityProbe` (app target) reading: how many
seconds ago the newest local Codex/Claude Code session transcript was modified ("A layer"),
plus three per-CLI intensity fields read from the same stat call ("B layer") — session
duration (mtime − creationDate), transcript byte size, and a count of transcripts modified in
the last 5 minutes (concurrent-session intensity). All of it is **stat-only**: modification
time, creation time, file size — never file contents, paths, project names, or account data.
It is **record-only telemetry**: sampled only while tracing is enabled, and never fed into
`AdaptiveRefreshPolicy` or any replay policy's decision logic. Every field is optional and
independent, so old trace lines (written before a given field existed) keep decoding with
that field `nil`.

## Deferred: token-level probe (C layer)

Richer local data exists but is deliberately **not** collected yet:

- Codex rollout files' `token_count` events carry `total_token_usage` (already parsed by
  `CostUsageScanner` for cost tracking) alongside a sibling `rate_limits` object
  (`used_percent`, `window_minutes`, `resets_at`, `plan_type`) that the scanner does not
  currently read.
- Claude Code transcripts carry a per-message `usage` object (`input_tokens`,
  `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`) with
  timestamps and a `sessionId`, also already parsed by `CostUsageScanner+Claude.swift`.
- The repo already has a reusable, incremental parser for exactly these files:
  `Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner*.swift` — byte-offset resume via
  `parsedBytes`, a per-file cache (`CostUsageScanner+CacheHelpers.swift`), and a 60-second
  minimum refresh interval. Any future C layer must reuse this scanner rather than
  reimplementing JSONL token parsing.

**Why deferred** (user decision, 2026-07-06): reading transcript *contents* — even just the
`usage`/`rate_limits` objects — crosses the A/B-layer probe's stat-only privacy line. It is
postponed until offline replay analysis of A/B-layer traces shows the activity signals
actually correlate with `menuOpen` events or quota-burn patterns worth acting on. If a C
layer is ever built, the trace should still only record aggregate numbers (token counts,
`used_percent`) — never message content, paths, project names, or account data.

One more note: Codex's `rate_limits.used_percent` is effectively a local, offline read of the
same quota number the Codex OAuth usage fetcher gets from the network. Reading it as a
*data source* (not just telemetry) is a separate design question — provider-quota semantics,
staleness, trust relative to the network fetch — beyond "probe telemetry" and out of scope
for this harness.
