---
summary: "Decision record for the deterministic agent-aware adaptive refresh cadence."
read_when:
  - Planning refresh cadence or background provider updates
  - Evaluating adaptive or predictive refresh behavior
  - Changing UsageStore timer scheduling
---

# Adaptive refresh decision record

- **Status:** Opt-in policy accepted in [#1861](https://github.com/steipete/CodexBar/pull/1861); agent-aware extension shipped as a separate explicit mode
- **Decision owner:** Maintainer
- **Runtime impact:** Bounded fresh-install default of 2–30-minute provider-batch cadence; an explicitly allowed local activity scan runs every 30 seconds when unconstrained

## Decision

CodexBar uses plain `Adaptive` for a missing refresh preference only when no prior-launch marker or existing config exists.
The resolved value is persisted immediately, so later launches preserve that choice. Existing installations without a
stored cadence, and unrecognized stored values, resolve to the legacy 5-minute fallback. Every valid stored choice,
including Manual and each fixed interval, remains unchanged. Both adaptive modes adjust the existing provider-batch
timer between 2 and 30 minutes. Only the separately selected `Adaptive (agent-aware)` mode may use recent local Codex
or Claude transcript activity to cap otherwise slower unconstrained decisions at 5 minutes.

The rollout boundary uses an existing config or launch markers that predate this change (`providerDetectionCompleted`
and the app-group migration version), captured before startup migrations can create them. This covers installations from
v0.4 onward plus any installation with a config. A completely untouched, configless v0.1-v0.3 installation leaves no
durable signal that can distinguish it from a new install; that historical cohort follows the fresh-install default.
Selecting a fixed cadence or Manual remains authoritative.

The original #1861 decision approved a menu-only opt-in policy. The 2026-07-12 extension below adds one local,
in-memory activity timestamp and changes the fallback after the offline replay, timer integration, privacy projection,
and scanner-cost proof recorded here. It does not approve per-account prediction, persistent interaction history,
learned ranking, or menu prewarming.

## Options considered

| Option | Freshness | Complexity | Provider work | Decision |
|---|---|---|---|---|
| Keep fixed frequencies only | Predictable | Lowest | Predictable | Safe fallback |
| Keep plain Adaptive as the fresh-install default; add agent-aware as explicit opt-in | Better while active; quieter while idle | Small | Bounded | Selected |
| Add per-provider/account prediction | Potentially best | High | Harder to reason about | Reject for now |
| Add learned ranking or contextual bandits | Unproven | Very high | Harder to audit | Reject |

The recommended option is intentionally less ambitious than “predictive refresh.” It solves the scheduling question
without creating a second account model, persistent behavioral telemetry, or a new menu-rendering architecture.

## Current behavior and code seams

Current `main` has two independent refresh paths:

1. `UsageStore.startTimer()` reads `SettingsStore.refreshFrequency.seconds`, sleeps for the fixed interval, then calls
   `UsageStore.refresh()`. A refresh is one concurrent batch over `enabledProvidersForBackgroundWork()`.
2. `StatusItemController.scheduleOpenMenuRefresh(for:)` retries rendered providers with missing/stale data. When the
   default-off **Refresh when the menu opens** setting is enabled, it refreshes every enabled provider instead. Both
   modes use the background interaction context, coalesce in-flight provider work, and keep prompt-capable OpenAI
   dashboard work deferred until menu tracking ends.

Relevant implementation seams:

- `Sources/AdaptiveRefreshCore/AdaptiveRefreshPolicyCore.swift`: canonical package-internal policy table shared by the
  app adapter and offline replay tooling.
- `Sources/CodexBar/SettingsStore.swift`: `RefreshFrequency` and fixed interval mapping.
- `Sources/CodexBar/UsageStore.swift`: timer ownership and provider-batch refresh.
- `Sources/CodexBar/AgentSessionsStore.swift`: 30-second local scan ownership and timestamp-only Adaptive projection.
- `Sources/CodexBarCore/LocalAgentSessionScanner.swift`: existing local process/transcript correlation reused by
  Agent Sessions and Adaptive.
- `Sources/CodexBar/UsageStore+Refresh.swift`: provider refresh coalescing and result application.
- `Sources/CodexBar/StatusItemController+Menu.swift`: missing/error-only menu-open refresh.
- `Sources/CodexBar/StatusItemController+MenuInteractionRefresh.swift`: deferred non-interactive refresh safety.
- `Tests/CodexBarTests/StatusMenuInstantOpenTests.swift`: fresh, missing, in-flight, and close-during-refresh contracts.

Adaptive changes only the first provider-refresh path. The local scanner supplies an in-memory scheduling signal; it
does not fetch provider usage. The change does not alter the menu-open setting, its default, provider selection,
interaction context, or the promise that menu-open refresh does not reset the periodic refresh clock.

## Accepted product contract

- Keep plain `Adaptive` as the default adaptive `RefreshFrequency` choice and use it for an unset cadence only when no
  prior-launch marker or existing config exists.
- Preserve the old implicit 5-minute fallback for existing installations without a stored cadence and for unrecognized
  stored values. Persist either resolved fallback immediately.
- Preserve every valid stored value exactly, including `Manual`, every fixed interval, and `Adaptive`.
- Do not treat plain Adaptive as authorization to inspect local process or session metadata. Add a distinct
  `Adaptive (agent-aware)` choice and persist an explicit `undecided`, `allowed`, or `declined` decision. Both the
  agent-aware selection and `allowed` consent are required before scanning.
- Present the choice when the agent-aware option is selected and consent is undecided. Declining returns to plain
  Adaptive. Selecting the agent-aware option again requests consent again.
- Schedule the same enabled-provider batch as fixed refresh; do not select accounts, workspaces, or data lanes.
- Keep manual refresh immediate and user-initiated.
- When refresh-all-on-open is disabled, keep menu-open refresh missing/error-only and background/non-interactive.
- Preserve the opt-in refresh-all-on-open path exactly. Recording a menu-open timestamp for adaptive scheduling must
  not itself fetch, cancel the periodic timer, or count a menu-originated refresh as an adaptive timer tick.
- Never make an automatic provider, account, workspace, or credential-source selection.
- Never bypass provider-specific auth, prompt, coalescing, or failure gates.
- Use only local Agent Sessions activity for scheduling. Remote discovery, Tailscale, and SSH remain behind the
  explicit Agent Sessions setting.
- When the Agent Sessions UI is off, discard scanned PID, CWD, project, transcript path, and session identity fields;
  retain only the newest activity timestamp in memory.

## Deterministic policy

Use a pure `AdaptiveRefreshPolicy` that returns the delay before the next ordinary provider-batch refresh.

```swift
struct AdaptiveRefreshPolicy: Sendable {
    struct Input: Sendable, Equatable {
        let now: Date
        let lastMenuOpenAt: Date?
        let lastCodingActivityAt: Date?
        let lowPowerModeEnabled: Bool
        let thermalState: ProcessInfo.ThermalState
    }

    enum Reason: String, Sendable {
        case recentInteraction
        case codingActivity
        case warm
        case idle
        case longIdle
        case constrained
    }

    struct Decision: Sendable, Equatable {
        let delay: Duration
        let reason: Reason
    }

    func nextDelay(for input: Input) -> Decision
}
```

Policy table, evaluated after startup and after every completed or skipped timer tick:

| Condition, first match wins | Next delay | Reason |
|---|---:|---|
| Low Power Mode or serious/critical thermal state | 30 minutes | `constrained` |
| Menu opened at or after 5 minutes ago, including a future clock-adjusted timestamp | 2 minutes | `recentInteraction` |
| Menu opened more than 5 minutes and at most 1 hour ago | 5 minutes | `warm` |
| Local coding activity observed less than 5 minutes ago and the menu-only result would be slower | 5 minutes | `codingActivity` |
| Menu opened more than 1 hour and less than 4 hours ago | 15 minutes | `idle` |
| No menu open recorded, or last open at least 4 hours ago | 30 minutes | `longIdle` |

Bounds are part of the contract:

- minimum automatic interval: 2 minutes;
- maximum automatic interval: 30 minutes;
- one timer task at a time;
- one global provider-batch refresh at a time;
- canceled timers do not launch work;
- settings changes cancel and replace the pending timer.

The policy deliberately excludes quota level, provider latency, error count, account choice, time-of-day, transcript
contents, and content-change rate. Those signals require durable state or provider-specific semantics. The activity
input is only the newest local transcript modification time already derived by the Agent Sessions scanner.

## Scheduler integration

Keep scheduling inside `UsageStore`; do not add a second scheduler abstraction.

1. Extend `RefreshFrequency` with `adaptive`; its fixed `seconds` value remains `nil`.
2. Replace the fixed `startTimer()` loop with a loop that asks a small helper for the next delay:
   - fixed mode returns the selected fixed delay;
   - manual mode returns no delay and ends the task;
   - adaptive mode calls `AdaptiveRefreshPolicy`.
3. After sleeping, check cancellation and call the existing `refresh()` batch path.
4. Recompute the next delay after the batch completes.
5. Record menu-open time through a minimal callback owned by `UsageStore` or a dedicated in-memory signal object. Do
   not couple the policy to `NSMenu`, menu descriptors, account switchers, or rendering state.
6. Feed the newest local transcript activity timestamp from `AgentSessionsStore` into `UsageStore`. A new observation
   may replace a pending Adaptive sleep only when its candidate refresh is earlier.

`NSBackgroundActivityScheduler` is out of scope. Current refresh choices include intervals below the range where that
API is intended to help, and using two scheduling mechanisms would make cancellation and exact timing harder to audit.
Revisit it only with separate energy measurements and a design for launch/relaunch behavior.

## State, privacy, and observability

Adaptive stores no persistent interaction history.

- Keep `lastMenuOpenAt` and `lastCodingActivityAt` in memory; reset both on launch.
- Read Low Power Mode and thermal state at decision time.
- Log only the selected delay and stable `Reason` code through the existing local logger.
- After the agent-aware mode is selected and explicit consent is granted, reuse the existing local scanner every 30 seconds. It inspects the running-process list and
  command lines via `ps`, runs `lsof` when needed, and, only after detecting an agent process, enumerates recent Codex
  rollouts; reads rollout first-line metadata and mtimes; and inspects Claude transcript metadata. This is a local
  metadata scan, not a provider request. Pause agent-aware scans under Low Power Mode or serious/critical thermal
  pressure; keep scanning when the user explicitly enables Agent Sessions presentation.
- Bound each scan to the newest 64 agent processes, 128 Codex rollout metadata records, and 64 Claude transcript
  candidates per project. Share a 512-entry, depth-1, 150 ms budget across agent-aware Codex and Claude directory
  enumeration, and
  clamp future transcript mtimes to the scan time. Keep the first clamped value for an unchanged future-dated file so
  repeated scans cannot synthesize newer activity.
- When Agent Sessions presentation is disabled, discard the full scan result after deriving the newest `Date`. Do not
  retain or publish its PID, CWD, project, transcript path, or session identity fields.
- Do not log or persist provider identity, account identity, email, workspace, path, credentials, response data, menu
  content, or the activity timestamp for scheduling.
- Do not invoke remote host discovery, Tailscale, or SSH unless Agent Sessions is explicitly enabled.
- Clear the in-memory activity timestamp when consent is revoked so it cannot continue influencing later decisions.
- Do not add analytics or send refresh-policy data off device.

This avoids a new retention policy, migration, deletion UI, and behavioral profile. Persistent history requires a new
privacy and storage decision; it is not an incremental extension of this proposal.

## Failure and auth behavior

Adaptive scheduling controls only when the existing batch is requested. All provider behavior remains downstream:

- background interaction context remains the default for automatic work;
- provider refresh coalescing remains authoritative;
- background work must not request interactive Keychain or browser authentication;
- a failed batch does not trigger an immediate policy retry;
- missing/error menu rows continue to use the existing delayed, rendered-provider-only retry path;
- manual refresh remains the only path allowed to opt into user-initiated behavior.

Do not add a scheduler-level failure backoff in the first experiment. Providers have different failure semantics, and
the current failure gates primarily control error publication rather than retry eligibility. A shared backoff would
need a separate contract for partial batch success.

## Implementation sequence

The work remained independently reviewable:

1. Add the pure policy and table-driven tests; no settings or runtime changes.
2. Add the `Adaptive` setting and localization as an opt-in choice.
3. Teach the existing timer to request fixed/manual/adaptive delays.
4. Wire the in-memory menu-open signal without changing `scheduleOpenMenuRefresh(for:)`.
5. Add local reason-code logging and documentation.
6. Add offline replay tooling and evaluate the frozen trace in #2029.
7. Add a separate agent-aware Adaptive option and explicit persisted consent, then reuse the local Agent Sessions
   scanner only after both gates pass, project its output to one in-memory timestamp when presentation is off, and
   advance only an otherwise later agent-aware Adaptive timer.
8. Make Adaptive the fresh-install default after policy, timer, projection, and scanner-cost verification, while
   preserving the legacy 5-minute fallback for existing unset or invalid state.

Do not add target adapters, outcome databases, account/workspace prediction, learned models, visible ordering changes,
or menu prewarming as part of these steps.

## Required tests

### Pure policy

- every table boundary, including exactly 5 minutes, 1 hour, and 4 hours;
- Low Power Mode wins over recent interaction;
- serious and critical thermal states select 30 minutes;
- nominal/fair thermal states do not force the constrained branch;
- future or clock-adjusted menu timestamps are treated as recent and never produce a negative delay;
- recent coding activity caps only otherwise slower decisions and never overrides a constrained 30-minute decision;
- the coding-activity threshold is exclusive at exactly 5 minutes;
- every decision stays within the 2-to-30-minute bounds.

### Timer integration

- fixed and manual modes retain current behavior and ignore coding-activity observations;
- adaptive mode sleeps for the policy result and recomputes after refresh;
- changing frequency cancels the old timer without one extra refresh;
- overlapping timer ticks do not overlap `UsageStore.refresh()`;
- launch with no menu history begins at 30 minutes;
- menu-open signal changes the next decision but does not itself start a batch.
- a newer coding-activity observation advances a 30-minute sleep to the 5-minute cap without starting a batch;
- repeated, older, or later observations never postpone an earlier scheduled refresh;
- fixed, manual, and plain Adaptive modes ignore coding-activity observations.

### Agent Sessions and consent boundary

- plain Adaptive always keeps the historical menu-only policy and performs no local session scan;
- the agent-aware option without consent performs no local session scan;
- allowing local coding activity enables monitoring only while the agent-aware option remains selected;
- an agent-aware scan retains the newest attributable timestamp and discards complete session records;
- agent-aware scans pause under Low Power Mode and serious/critical thermal pressure;
- scanner limits cap agent processes, Codex rollout parsing, and Claude transcript candidates;
- remote fetch remains guarded by the explicit Agent Sessions setting;
- a refresh-frequency change does not invalidate or retry an in-flight remote refresh.

### Menu regression

- opening a fresh menu still does not schedule a menu-originated refresh;
- missing/error rows still refresh only rendered providers;
- enabling refresh-all-on-open still refreshes every enabled provider without resetting the periodic timer;
- adaptive and menu-open work arriving together still coalesce per provider instead of duplicating requests;
- closing a menu still controls deferred prompt-capable dashboard work;
- in-flight provider work still coalesces;
- manual refresh remains user-initiated.

Use stubs and test stores. Do not run live providers, browser-cookie imports, or Keychain reads for policy validation.

## Acceptance and rollback

The 2026-07-12 extension requires evidence from separate seams rather than treating one replay as end-to-end proof:

- deterministic decision-point replay must show fewer scheduled batches than fixed 5 minutes, no unconstrained active
  decision above 5 minutes, and unchanged 30-minute constrained decisions;
- timer integration tests must show an activity callback advancing a pending long-idle sleep without starting a batch,
  postponing an earlier tick, or affecting fixed/manual scheduling;
- the agent-aware scan projection must discard complete session records and retain one in-memory timestamp;
- remote discovery and SSH must remain guarded by the explicit Agent Sessions setting;
- the local scanner's cost must be measured and disclosed separately from provider-batch savings.

Rollback is restoring the fresh-install fallback to 5 minutes and omitting `lastCodingActivityAt` from the policy input.
Existing unset/invalid state already retains the 5-minute fallback; fixed/manual scheduling and every valid stored
selection remain compatible because their raw values do not change.

## Explicit non-decisions

Approval of this extension does not approve:

- changing the refresh-all-on-open default or its existing provider/auth behavior;
- enabling Agent Sessions presentation or remote discovery by default;
- per-provider, per-account, per-workspace, or per-source scheduling;
- persistent interaction or outcome history;
- `NSBackgroundActivityScheduler` adoption;
- account/menu ordering changes;
- EWMA, Bayesian, bandit, ranker, or language-model decisions;
- new telemetry collection or external analytics.

Any of those requires its own evidence and product/privacy review.

## Local replay follow-up (2026-07-10, evidence only)

This follow-up adds offline replay tooling only. It does not add app-side recording, persistent diagnostic storage,
transcript-directory scanning, or a new production-policy input. The evaluated 1,780-record snapshot came from local
experimental instrumentation that is not part of this change. Its SHA-256 is
`b1e4aa33180b7c177293eb9ed16b45e24e026d259600fba2b1b67b931b904f0b`; the raw trace remains local.

The app and replay adapter call the same package-internal policy core. Platform-specific adapters normalize thermal
state and output units; they do not copy the policy thresholds or decision table.

The replay splits legacy deadline-overrun gaps five minutes after the most recent recorded timer deadline. It found 28
observed segments and excluded 26.10 hours of unobserved wall time. The heuristic cannot distinguish sleep or reboot from
a long refresh or event-loop stall, so the excluded time is not a causal classification.

| Policy | Simulated refreshes | Per observed 24h | Simulated advances | Unconstrained active over 5m | Menu staleness p50 / p95 |
|---|---:|---:|---:|---:|---:|
| Current adaptive | 694 | 143.47 | 53 | 4 / 145 | 142s / 1093s |
| Activity-cap candidate | 696 | 143.88 | 53 | 0 / 145 | 139s / 1093s |
| Fixed 5m | 1383 | 285.90 | 0 | 0 / 99 | 150s / 281s |

The replay-only candidate caps an otherwise slower adaptive decision at five minutes when an input trace reports recent
coding activity. It adds two simulated refreshes and removes the four active-delay violations in this snapshot, but does
not improve p95 menu staleness. The sample is one machine and the candidate changes only a small number of decisions, so
this is not sufficient evidence for a production or default change.

Replay advances are counterfactual events on a zero-service-time policy clock. They are intentionally not compared by
count with live `timerAdvanced` events, whose schedule includes real refresh duration and in-flight coalescing. The
offline audit reports recorded schedule events separately when the supplied trace contains them.

## Agent-aware opt-in follow-up (2026-07-12)

This extension moves the previously replay-only activity cap into `AdaptiveRefreshPolicyCore`, retains the former
menu-only input projection as the plain `Adaptive` fresh-install default, and exposes local activity as a separate
`Adaptive (agent-aware)` option. The legacy 5-minute fallback remains for existing unset or invalid preferences. The
existing local Agent Sessions scanner is wired into the live timer only after the agent-aware mode is selected and
explicit consent is granted; undecided or declined users perform no agent-aware scan. The
`adaptive-activity` CLI spelling remains the distinct agent-aware replay mode shipped in 0.42.1.

The same frozen 1,780-record trace and segmentation settings produce:

| Policy | Simulated refreshes | Per observed 24h | Simulated advances | Unconstrained active over 5m | Menu staleness p50 / p95 |
|---|---:|---:|---:|---:|---:|
| Agent-aware adaptive | 696 | 143.88 | 53 | 0 / 145 | 139s / 1093s |
| Plain adaptive | 694 | 143.47 | 53 | 4 / 145 | 142s / 1093s |
| Fixed 5m | 1383 | 285.90 | 0 | 0 / 99 | 150s / 281s |

On this trace, agent-aware Adaptive schedules 49.7% fewer simulated refreshes than fixed 5 minutes. Compared with plain
Adaptive, it adds 2 simulated refreshes (0.29%) and removes all 4 observed active-delay violations. It
does not improve p95 menu staleness. Activity fields are present on 462 of 733 decision records (63%); 185 of those 462
samples (40%) report activity under 5 minutes old. This is one machine's trace, not a population or energy study. The
SHA-256 remains `b1e4aa33180b7c177293eb9ed16b45e24e026d259600fba2b1b67b931b904f0b`.

Replay proves the policy table at reconstructed decision points. It does not reproduce the new 30-second scanner
callback, because the frozen trace sampled activity only on decision records. Timer integration tests separately prove
that a live activity observation can pull a pending 30-minute sleep forward and cannot postpone an earlier refresh.

A 20-run `hyperfine` sample of exact-head `.build/debug/CodexBarCLI sessions --json`, with one attributable Codex
session, measured 153.0 ms ± 14.4 ms wall time and 134.3 ms combined user plus system CPU time per invocation. At the
30-second unconstrained cadence, that CPU figure extrapolates to 6.5 CPU-minutes per day. Agent-aware scans pause under
Low Power Mode and serious/critical thermal pressure. The CLI process startup is included, so this is a conservative
same-machine sample for in-process work, not a scanner upper bound or general energy claim. Simulated refresh counts and
scanner CPU are reported separately; the replay does not claim net energy savings.

An exact-head synthetic stress fixture then exercised 12 agent-like processes and 512 recent Codex rollout entries.
After bounding the scanner, 20 runs of `.build/debug/CodexBarCLI sessions --json` measured 231.4 ms ± 12.4 ms wall time
and 209.3 ms combined user plus system CPU time. At a continuous 30-second cadence that CPU figure extrapolates to 10.1
CPU-minutes per day. The CLI startup is included. This is a stress sample rather than a population or energy claim, and
directory metadata enumeration is additionally capped by the shared entry, depth, and time budget.
