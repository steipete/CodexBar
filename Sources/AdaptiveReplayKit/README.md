# AdaptiveReplayKit

`AdaptiveReplayKit` is an offline harness for comparing refresh-timing policies against an
explicit JSONL trace. `AdaptiveReplayCLI` is the command-line wrapper around the library.

## Scope

The replay targets do not import `CodexBar` or `CodexBarCore`; they share only the package-internal,
Foundation-only `AdaptiveRefreshCore` target with the app. They do not record app behavior, scan
Codex or Claude transcript directories, write trace files, call providers, or change the production
refresh policy at runtime. Trace capture and lifecycle management are deliberately outside this tool; callers
provide an existing trace path to the CLI.

Optional activity fields in the trace schema are inputs only. The replay kit never discovers or
collects them. Old records without those fields continue to decode.

## Components

- `AdaptiveRefreshTrace.swift` defines the version-tolerant trace schema.
- `AdaptiveRefreshTraceParser.swift` parses JSONL strictly by default. The tolerant entry point is
  available for exploratory work that explicitly accepts skipped malformed records.
- `AdaptiveRefreshCore` owns the production decision table. `ReplayPolicy.swift`,
  `BaselinePolicies.swift`, and `AgentAwarePolicies.swift` provide the plain and agent-aware production adapters plus
  fixed/manual baselines.
- `ReplayEngine.swift` and `ReplayMetrics.swift` calculate simulated refresh cadence, menu-open
  staleness, interaction advances, and constrained-state compliance.
- `ReplayTraceSegmentation.swift` excludes legacy deadline-overrun gaps with an explicit heuristic
  and reports the excluded duration.
- `RecordedScheduleAudit.swift` audits recorded timer-advance events independently from the replay
  clock.
- `Sources/AdaptiveReplayCLI` formats table or JSON reports.

`interactionAdvanceCount` is counterfactual. Replay assumes a zero-duration refresh, while the
live app waits for provider work and may already have a refresh in flight. Recorded schedule events
therefore have a separate audit instead of a direct count comparison.

The legacy gap heuristic cannot distinguish sleep or reboot from a long refresh or event-loop
stall. Reports expose the segment count, grace interval, and excluded time rather than assigning a
cause.
