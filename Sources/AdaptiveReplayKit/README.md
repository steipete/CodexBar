# AdaptiveReplayKit

Adaptive-refresh replay harness. It lets CodexBar answer
"how would a different refresh-timing policy have behaved on this machine's real
usage history" without touching the live app or any provider.

## How it fits together

- **Trace recording** (`Sources/CodexBar/AdaptiveRefreshTraceRecording.swift`, app target):
  OFF by default, gated on the `adaptiveRefreshTraceEnabled` defaults key. When enabled,
  it appends one JSONL line per `AdaptiveRefreshTraceRecord` (`AdaptiveRefreshTrace.swift`)
  to `adaptive-refresh-trace.jsonl`. `timerAdvanceEvaluated` records every accepted/rejected
  live schedule comparison; `timerAdvanced` remains the accepted subset. The writer stops
  appending at 10 MiB so an unattended diagnostic trace cannot grow without bound.
- **Parsing** (`AdaptiveRefreshTraceParser.swift`): strict by default — a malformed line
  fails the whole parse, since a trace is acceptance evidence for replay metrics.
- **Replay** (`ReplayEngine.swift`, `ReplayPolicy.swift`, `BaselinePolicies.swift`): heuristically
  splits legacy deadline-overrun/unobserved gaps after the last recorded timer deadline, then simulates
  a candidate policy's tick schedule against a trace's ground-truth `menuOpen`/signal events
  and reports `ReplayMetrics.swift` (refresh count, staleness at menu-open, constrained-tier
  compliance).
- **CLI** (`Sources/AdaptiveReplayCLI`): thin wrapper — parses a trace file, runs one or more
  policies through `ReplayEngine`, prints the table/JSON, and audits recorded schedule events.
  JSON output is a report object containing `policies`, `activityCoverage`,
  `recordedScheduleAudit` (including `isValid` and every mismatch count), and the exact
  `segmentation` mode/grace used for the run.

`interactionAdvanceCount` is a simulated/counterfactual count. It must not be compared directly
with recorded `timerAdvanced` count: replay assumes a zero-duration refresh, while the live loop
waits for real provider work and can encounter an already in-flight refresh. Recorded schedule
events are checked independently by `RecordedScheduleAuditor`.
The legacy gap heuristic cannot distinguish sleep/reboot from a long refresh or event-loop stall;
its excluded time is reported explicitly and is not a causal classification.

## Coding-activity shadow-mode signal (A/B layers)

`decision` records optionally carry a `CodingActivityProbe` (app target) reading: how many
seconds ago the newest local Codex/Claude Code session transcript was modified ("A layer"),
plus three per-CLI intensity fields read from the same stat call ("B layer") — session
duration (mtime − creationDate), transcript byte size, and a count of transcripts modified in
the last 5 minutes (concurrent-session intensity). All of it is **stat-only**: modification
time, creation time, file size — never file contents, paths, project names, or account data.
It is sampled only while tracing is enabled and is never fed into the production
`AdaptiveRefreshPolicy`. The replay-only `CodingActivityAdaptivePolicy` uses the A-layer signal in
offline replay to cap unconstrained active decisions at five minutes; B-layer fields remain
descriptive only. Every field is optional and independent, so old trace lines keep decoding.

Trace writing is serialized within one process. Do not enable the recorder in multiple CodexBar
instances that share the same Application Support directory; cross-process writing is unsupported.

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
