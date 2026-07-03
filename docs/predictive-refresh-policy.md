---
summary: "Decision record for an optional deterministic adaptive refresh cadence."
read_when:
  - Planning refresh cadence or background provider updates
  - Evaluating adaptive or predictive refresh behavior
  - Changing UsageStore timer scheduling
---

# Adaptive refresh decision record

- **Status:** Accepted design; not implemented
- **Decision owner:** Maintainer
- **Runtime impact:** None until separately implemented

## Decision

CodexBar may offer an opt-in `Adaptive` refresh frequency that adjusts the existing provider-batch timer between 2 and
30 minutes using the deterministic policy below. Do not implement the broader
per-account prediction, persistent interaction history, learned ranking, or menu prewarming proposed in the original
RFC.

This approval covers the bounded design only. Runtime implementation, tests, localization, and packaged proof remain a
separate change.

## Options considered

| Option | Freshness | Complexity | Provider work | Decision |
|---|---|---|---|---|
| Keep fixed frequencies only | Predictable | Lowest | Predictable | Safe fallback |
| Add bounded adaptive batch cadence | Better while active; quieter while idle | Small | Bounded | Recommended experiment |
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

- `Sources/CodexBar/SettingsStore.swift`: `RefreshFrequency` and fixed interval mapping.
- `Sources/CodexBar/UsageStore.swift`: timer ownership and provider-batch refresh.
- `Sources/CodexBar/UsageStore+Refresh.swift`: provider refresh coalescing and result application.
- `Sources/CodexBar/StatusItemController+Menu.swift`: missing/error-only menu-open refresh.
- `Sources/CodexBar/StatusItemController+MenuInteractionRefresh.swift`: deferred non-interactive refresh safety.
- `Tests/CodexBarTests/StatusMenuInstantOpenTests.swift`: fresh, missing, in-flight, and close-during-refresh contracts.

The adaptive experiment must change only the first path. It must not alter the menu-open setting, its default, provider
selection, interaction context, or promise that menu-open refresh does not reset the periodic refresh clock.

## Accepted product contract

- Add `Adaptive` as a mutually exclusive `RefreshFrequency` choice.
- Keep `5 minutes` as the default for new and existing users.
- Never migrate an existing fixed selection to `Adaptive`.
- Preserve `Manual` and every existing fixed interval exactly.
- Schedule the same enabled-provider batch as fixed refresh; do not select accounts, workspaces, or data lanes.
- Keep manual refresh immediate and user-initiated.
- When refresh-all-on-open is disabled, keep menu-open refresh missing/error-only and background/non-interactive.
- Preserve the opt-in refresh-all-on-open path exactly. Recording a menu-open timestamp for adaptive scheduling must
  not itself fetch, cancel the periodic timer, or count a menu-originated refresh as an adaptive timer tick.
- Never make an automatic provider, account, workspace, or credential-source selection.
- Never bypass provider-specific auth, prompt, coalescing, or failure gates.

## Deterministic policy

Use a pure `AdaptiveRefreshPolicy` that returns the delay before the next ordinary provider-batch refresh.

```swift
struct AdaptiveRefreshPolicy: Sendable {
    struct Input: Sendable, Equatable {
        let now: Date
        let lastMenuOpenAt: Date?
        let lowPowerModeEnabled: Bool
        let thermalState: ProcessInfo.ThermalState
    }

    enum Reason: String, Sendable {
        case recentInteraction
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
| Menu opened more than 1 hour and less than 4 hours ago | 15 minutes | `idle` |
| No menu open recorded, or last open at least 4 hours ago | 30 minutes | `longIdle` |

Bounds are part of the contract:

- minimum automatic interval: 2 minutes;
- maximum automatic interval: 30 minutes;
- one timer task at a time;
- one global provider-batch refresh at a time;
- canceled timers do not launch work;
- settings changes cancel and replace the pending timer.

The policy deliberately excludes quota level, provider latency, error count, account choice, time-of-day, and content
change rate. Those signals require new durable state or provider-specific semantics and do not belong in the first
experiment.

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

`NSBackgroundActivityScheduler` is out of scope. Current refresh choices include intervals below the range where that
API is intended to help, and using two scheduling mechanisms would make cancellation and exact timing harder to audit.
Revisit it only with separate energy measurements and a design for launch/relaunch behavior.

## State, privacy, and observability

The first experiment stores no interaction history.

- Keep `lastMenuOpenAt` in memory; reset it on launch.
- Read Low Power Mode and thermal state at decision time.
- Log only the selected delay and stable `Reason` code through the existing local logger.
- Do not log or store provider identity, account identity, email, workspace, path, credentials, response data, or menu
  content for scheduling.
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

Each step should be independently reviewable:

1. Add the pure policy and table-driven tests; no settings or runtime changes.
2. Add the `Adaptive` setting and localization, default unchanged.
3. Teach the existing timer to request fixed/manual/adaptive delays.
4. Wire the in-memory menu-open signal without changing `scheduleOpenMenuRefresh(for:)`.
5. Add local reason-code logging and documentation.
6. Package and validate the opt-in mode before considering a default change.

Do not add target adapters, outcome databases, account/workspace prediction, learned models, visible ordering changes,
or menu prewarming as part of these steps.

## Required tests

### Pure policy

- every table boundary, including exactly 5 minutes, 1 hour, and 4 hours;
- Low Power Mode wins over recent interaction;
- serious and critical thermal states select 30 minutes;
- nominal/fair thermal states do not force the constrained branch;
- future or clock-adjusted menu timestamps are treated as recent and never produce a negative delay;
- every decision stays within the 2-to-30-minute bounds.

### Timer integration

- fixed and manual modes retain current behavior;
- adaptive mode sleeps for the policy result and recomputes after refresh;
- changing frequency cancels the old timer without one extra refresh;
- overlapping timer ticks do not overlap `UsageStore.refresh()`;
- launch with no menu history begins at 30 minutes;
- menu-open signal changes the next decision but does not itself start a batch.

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

Before changing the default, a separate proposal must provide measured evidence. Minimum evidence:

- deterministic replay tests show fewer scheduled batches than the 5-minute baseline during idle traces;
- active traces never schedule slower than the existing 5-minute default;
- no regression in menu-open responsiveness or prompt safety;
- packaged opt-in use shows understandable reason logs and no timer overlap.

Rollback is deleting the `Adaptive` option and policy helper. Fixed/manual scheduling and stored fixed selections remain
valid because the experiment does not migrate them or change their raw values.

## Explicit non-decisions

Approval of this document does not approve:

- making adaptive refresh the default;
- changing the refresh-all-on-open default or its existing provider/auth behavior;
- per-provider, per-account, per-workspace, or per-source scheduling;
- persistent interaction or outcome history;
- `NSBackgroundActivityScheduler` adoption;
- account/menu ordering changes;
- EWMA, Bayesian, bandit, ranker, or language-model decisions;
- new telemetry collection or external analytics.

Any of those requires its own evidence and product/privacy review.
