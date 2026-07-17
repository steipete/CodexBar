---
summary: "Universal design for estimating weekly session capacity, capacity before reset, and quota reachability."
read_when:
  - Implementing issue #2261 or session-to-weekly quota estimates
  - Adding quota-planning support to a provider
  - Changing quota-pair inference, calibration, or menu presentation
---

# Universal quota planning — design

**Status:** product direction approved; implementation design proposed
**Date:** 2026-07-17
**Issue:** [#2261](https://github.com/steipete/CodexBar/issues/2261)

## Decision summary

Add one shared quota-planning capability for providers that can explicitly identify a short quota and a longer quota
which meter the same workload. The initial product surface is a compact planning line on the longer-window menu row.

The number-first presentation answers three related questions:

1. **Fundable (`N`):** at the recently observed workload mix, how many full short-window session equivalents can the
   remaining longer-window quota fund?
2. **Maximum before reset (`M`):** how many short-window allowance equivalents can become available before the longer
   window resets if every allowance is used flat out?
3. **Reachability:** does the conservative evidence show that the longer quota can or cannot be exhausted before reset?

`N` is the headline. `M` and the reachability verdict are supporting context. `N` is learned from synchronized movement
in the two quotas; `M` is deterministic schedule capacity. The planning block remains hidden until `N` passes its
evidence gates because `M` alone does not answer the user's main question.

Provider eligibility is descriptor-driven. The shared estimator and UI must not contain a Codex/Claude/Antigravity
allowlist, infer pairs from labels, or assume that any two windows with five-hour and weekly cadences share a pool.

Ship the first implementation for Codex, Claude, and Antigravity. This validates the common primary/secondary shape,
Claude's synthetic-session edge case, and Antigravity's multiple named quota groups before enabling other providers.
Keep calibration in memory for the first version; do not reuse or expand persisted utilization history.

## Motivation

Issue #2261 shows a short quota exhausted while weekly capacity remains. The user must infer how many full short
allowances the weekly quota can fund, how many can become available before reset, and whether capacity will be
stranded. The same problem exists across providers, but short and weekly percentages are not interchangeable. Wrong
pairing, stale data, or mixed account/source state would make the estimate misleading.

The [maintainer decision](https://github.com/steipete/CodexBar/issues/2261#issuecomment-5006555635) approves estimated
`N`, maximum `M`, and a reachability verdict on top of the pacing engine. This spec defines the remaining product and
implementation contract.

## Goals

- Show `N`, supporting `M`, and a conservative verdict on the existing long-window row.
- Use one descriptor-driven Core estimator for primary/secondary and multiple named pairs.
- Compose with existing pace presentation without duplicating pace calculations.
- Isolate provider, account, group, source, and reset-window state and fail closed on incomplete evidence.

## Non-goals

- Guaranteeing how a provider will enforce a rolling or undocumented quota.
- Inferring shared quota semantics from labels, array order, duration, or matching reset times.
- Estimating daily/monthly, credits, spend, token balance, or regeneration-only quotas in the first version.
- Predicting a user's future activity level or model mix.
- Adding alerts, notification settings, warning colors, menu-bar icon changes, or automatic provider switching.
- Adding a setting, Overview history, widgets, or CLI output in the first version.
- Persisting observations or learned calibration across app launches.
- Changing `UsagePace`, workday pace, or plan-utilization history semantics.

## Terminology and product contract

| Term                              | Meaning                                                                             |
| --------------------------------- | ----------------------------------------------------------------------------------- |
| Short window                      | The repeatedly replenished quota, normally about five hours in the first rollout.   |
| Long window                       | The containing quota, normally one week in the first rollout.                       |
| Quota pair                        | A provider-declared short and long window that meter the same workload.             |
| Group                             | A stable quota-pair identity, such as Antigravity Gemini or Antigravity Claude/GPT. |
| Full-session equivalent           | One full short-window quota; values may be fractional.                              |
| Fundable full-session equivalents | Full-session equivalents the remaining long quota can fund at the observed mix.     |
| Maximum before reset              | Current short remainder plus full short allowances scheduled before the long reset. |
| Long cost                         | Estimated long-window percentage consumed by one full short allowance.              |
| Reachability                      | Conservative comparison of fundable capacity with maximum capacity before reset.    |

A value of `1.4` means one full session plus about `40%` of another. “Fundable” is conditional, not a promise. It means
“funded by the remaining long quota at the workload mix observed during this long window.” Different models or request
types may consume the short and long quotas at different relative rates. Fundable `N` uses an approximation marker;
deterministic `M` is labeled “up to.” Neither promises that the user has enough time to consume that capacity before
reset.

By returning a pair, a provider also asserts that `100` short-window percentage points represent one full short
allowance, each reported short reset replenishes one full allowance, and resets repeat at the declared short duration
while the long window remains active. Providers with incremental regeneration, irregular refill schedules, or only a
next-refill amount must not opt in to the initial calculation.

## Accepted user behavior

### Placement

Render the planning summary as a separate footnote on the **long-window metric row**. Do not place it on the short row,
in the provider header, in a tooltip, or in the menu-bar icon.

Keep the existing row order:

1. metric title;
2. progress bar;
3. percentage and reset;
4. quota-planning headline and supporting line;
5. existing pace/headroom detail, when present;
6. existing provider detail, when present.

Planning leads because it answers remaining capacity; existing pace detail still answers whether quota lasts at the
user's observed or configured schedule.

### Presentation states

The copy below is semantic guidance. Final strings must be localized as complete templates; do not interpolate a
provider metric title into the sentence.

| State                                                           | Example on the weekly row                                                                                                                                    |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Calibration learning or unstable                                | No planning line                                                                                                                                             |
| One qualifying candidate; verdict learning                      | `Remaining weekly quota: ≈4 full-session equivalents`<br>`Up to 9 before reset`                                                         |
| Conservatively reachable                                        | `Remaining weekly quota: ≈4 full-session equivalents`<br>`Up to 9 before reset · weekly quota can likely be exhausted`                  |
| Conservatively stranded                                         | `Remaining weekly quota: ≈9 full-session equivalents`<br>`Only up to 4 before reset · weekly quota will likely go unused`               |
| Candidate range crosses boundary                                | `Remaining weekly quota: ≈4 full-session equivalents`<br>`Up to 4 before reset · reachability uncertain`                                |
| No capacity before reset; verdict learning                      | `Remaining weekly quota: ≈0.6 full-session equivalents`<br>`No short-window capacity before reset`                                      |
| No capacity before reset; stranded evidence qualifies           | `Remaining weekly quota: ≈0.6 full-session equivalents`<br>`No short-window capacity before reset · weekly quota will likely go unused` |
| Ineligible, freshness-expired, exhausted long quota, or invalid | No planning line                                                                                                                                             |

The visible copy deliberately favors brevity. Accessibility text must state the full relationship, for example: “At
the recently observed workload mix, the remaining weekly quota can fund approximately 4 full-session equivalents. Up
to 9 full-session equivalents can become available before the weekly reset. The weekly quota can likely be exhausted.”
When `M` is fractional, accessibility text must distinguish the current partial allowance from later full refills; for
example, `4.4` means roughly 40% of the current allowance plus four future full allowances. Do not add success or
warning color; existing pace and threshold UI already carry risk semantics.

### Formatting

- Format with the current locale, round half-up to at most one decimal place, and omit `.0` for whole numbers.
- Render a positive value below `0.1` as `<0.1`.
- Prefix learned `N` with `≈`; deterministic `M` uses “up to” and no approximation marker.
- Localize the complete template and use the locale's plural form for “full-session equivalent.” Do not compose it
  from provider metric titles.
- Do not impose an absolute display cutoff such as `20`. Evidence gates determine whether the learned estimate is
  trustworthy.
- Provide complete localized headline and supporting templates for every verdict. The normal presentation is two
  planning lines; allow the block to wrap to at most three visual lines when localization requires it. Never
  abbreviate translated words, truncate either value, shrink the font, or cover percentage/reset content.
- Compare unrounded `N` and `M` and candidate bounds. Formatting never determines a verdict.
- Do not expose candidate bounds, a confidence percentage, or internal sample count.

## Eligibility: explicit and fail-closed

A provider must opt in through `ProviderDescriptor.quotaPlanning`. The descriptor returns zero or more resolved quota
pairs for a snapshot. Returning no pair is the only unsupported state; the estimator and UI do not maintain a separate
provider allowlist.

Returning a pair is also the provider's assertion that both measurements belong to the same successful fetch result
or are sampled closely enough by that fetcher to support a ratio. A provider that combines delayed counters from
different calls must first expose trustworthy capture/skew evidence; the shared estimator cannot repair source skew.

Pair IDs must be non-empty, stable across refreshes, and unique within a provider snapshot. Short and long metric IDs
must be non-empty and different, and one long metric ID may belong to at most one pair. If resolver output collides,
drop every colliding pair rather than choosing by array order; other independent pairs may continue.

A resolved pair is eligible only when all of these conditions hold:

- The descriptor explicitly asserts that both windows meter the same workload for the group.
- The descriptor explicitly asserts that the winning fetch strategy reports both percentages and reset facts exactly
  enough for this calculation.
- Both usages are known, finite percentages.
- Both used percentages are within `0...100`; do not clamp malformed provider values into eligibility.
- Neither window is `isSyntheticPlaceholder`.
- Neither window uses `nextRegenPercent`; incremental-regeneration semantics are out of scope.
- Both `windowMinutes` values are authoritative and positive.
- The short duration is less than the long duration.
- Both `resetsAt` values are present and in the future.
- Each reset is no farther away than its declared duration plus the reset-equivalence tolerance.
- The snapshot came from a successful in-process provider refresh whose per-result observation freshness is `.live`.
- The long window has remaining quota.

Resolvers see parsed `RateWindow` values, so each opted-in fetch strategy must validate raw percentages before any
provider-side clamping. A malformed, non-finite, or out-of-range raw value must fail parsing or remain explicitly
unknown; a clamped value must not become an eligible observation. Provider fixtures must prove this boundary.

Set estimate freshness to `60 minutes`, twice the maximum adaptive refresh interval. Start that TTL when CodexBar
receives the successful result and measure elapsed time with `ContinuousClock`, so a wall-clock correction cannot make
a fresh estimate instantly stale or extend it indefinitely. The hard display deadline is the earlier of that monotonic
TTL and the canonical long-reset anchor. If wall time reaches the long reset without a successful refresh, hide the
estimate and discard calibration from the prior long window. A forward wall-clock correction may hide early; the
60-minute monotonic TTL still prevents a backward correction from retaining the estimate indefinitely.

Do not globally compare `snapshot.updatedAt` with the local wall clock. Receipt time alone cannot prove that a cached
provider payload is current, and a server timestamp may use a skewed clock. A strategy with cache or server-age
semantics must validate them at its fetch/parser boundary and mark the individual result `.cached` or `.unknown` when
freshness cannot be proven. Wall-clock `Date` remains necessary for calibration reset identity and keeps the existing
`120`-second tolerance.

Initial provider opt-ins must additionally use an inclusive short duration from `240...360` minutes and an exact
seven-day (`10080` minute) long duration. The Core types and estimator remain duration-generic, but daily/monthly
behavior needs separate product review rather than silently entering this rollout.

## Architecture fit

### Existing seams

| Existing component               | Relevant responsibility                                              | Design consequence                                           |
| -------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------ |
| `RateWindow` / `NamedRateWindow` | Usage, duration, reset, placeholder, and known-usage facts           | Keep the fetched snapshot schema unchanged.                  |
| `ProviderDescriptor`             | Core source of provider capabilities and fetch behavior              | Put opt-in and pair resolution here.                         |
| `ProviderImplementation`         | App settings/login/menu hooks                                        | Do not add quota math or pairing here.                       |
| `UsageStore` refresh path        | Owns successful snapshots, accounts, and source context              | Own in-memory calibration and observation lifecycle here.    |
| `UsagePace`                      | Pure time-based pace model                                           | Compose a companion estimate without duplicating pace logic. |
| `UsageMenuCardView.Model`        | Converts store state into stable menu metrics                        | Decorate the matching long metric without provider branches. |
| Plan-utilization history         | Persisted chart/history series with provider-specific lane selection | Do not use it as calibration input.                          |

The existing history recorder is not a safe universal source. It records semantic Codex/Claude lanes, collapses
Antigravity to one most-used weekly lane, and records only a generic weekly lane for many providers. Reusing it would
mix a new paired-quota meaning into established chart storage and would require migration and privacy decisions.

### Core capability model

Add an optional `ProviderDescriptor.quotaPlanning` capability. Its resolver receives the winning result's snapshot,
strategy identity/kind, and per-result freshness, then returns zero or more pairs. Each pair carries a stable pair ID
and short/long values containing the metric ID, `RateWindow`, and known-usage state. Absence means unsupported.

`ProviderFetchResult` gains transient `observationFreshness`, defaulting to `.unknown` in its initializer and shared
result builders. A strategy sets `.live` only when the quota facts came from the current successful transport/local
probe and any provider-specific cache/server-age checks passed; reused observations are `.cached`. This field is not
encoded in `UsageSnapshot` or persisted.

The resolution input comes directly from the winning result, and quota planning rejects every value except `.live`.
This lets a provider accept an exact API result but reject a cached, percent-only, or synthesized fallback without
teaching the shared estimator about strategies. `UsageSnapshot.dataConfidence` may additionally inform that decision
when a provider sets it, but its default `.unknown` is not a global rejection: several current exact quota parsers do
not populate the coarse snapshot-wide field.

Provide a shared `primarySecondary(...)` resolver for the common shape. Providers with grouped extras return pairs
from their stable named-window IDs. The resolved long `metricID` is the join key used to decorate the menu metric; the
app must not rediscover the pair by title or array position.

Codex currently classifies source slots into semantic session/weekly lanes inside the app-side
`CodexConsumerProjection`. Extract that classification into a Core helper used by both the projection and the Codex
quota-planning resolver. Do not duplicate the duration/slot fallback or make the descriptor resolve raw slots
differently from the menu. Planning uses the projection's source windows, not the display-only window adjusted when a
weekly cap is already binding.

Do not add pairing fields to `RateWindow`, duplicate windows in `UsageSnapshot`, or add a central switch over
`UsageProvider`. Pairing is provider capability metadata, while the window remains a provider-neutral measurement.

### Pace companion and pure estimator

Keep stateful calibration out of `UsagePace`, but build the result on the same Core and menu-model seams. `UsageStore`
must resolve pace and planning per long metric ID and pass a typed, metric-keyed companion map into the menu model.
This is required for Antigravity, where each weekly group has independent pace and planning state. Extra-window view
helpers must not recompute pace. The shared decorating pass attaches both values to the matching metric. The planner
must not recompute expected progress, ETA, workday time, reserve/deficit, or run-out probability.

The companion Core estimate carries pair and long-metric IDs, `N`, `M`, future full-refill count, learned long cost,
and one of `insufficientEvidence`, `likelyReachable`, `likelyStranded`, or `uncertain`.

The pure schedule estimator accepts a resolved pair and `now`. The pure calibration reducer accepts a scoped
observation and prior in-memory state. A pure composer combines their outputs into `QuotaPlanningEstimate` after the
calibration gates pass. Core contains no settings, disk I/O, AppKit, localization, account lookup, or provider-specific
branches.

### App state and scope

`UsageStore` owns a small in-memory calibration dictionary. Key each entry by:

- provider;
- stable provider-owned account discriminator;
- pair/group ID;
- fetch strategy identity.

Each reducer entry also stores `requiresActiveRequalification`. Set it after a material usage decrease without a
matching reset or a short reset that moves backward beyond tolerance. While set, retained completed candidates cannot
produce a presentation. Clear it only when the new active segment produces a qualifying candidate; normal dispersion
and eligibility gates still apply.

Published estimates expire without requiring a refresh at the earlier of the monotonic TTL and long reset. Expiry
work is cancellable and generation-guarded so stale tasks cannot clear replacement state. Clock changes and app wake
reschedule it; wall and monotonic clocks remain injectable for tests. TTL expiry hides only the presentation;
calibration remains reusable after a new eligible live observation until the canonical long reset discards it.

Keep the dictionary and its receipt-time freshness metadata `@MainActor`-isolated with the rest of `UsageStore`.
Concurrent provider fetches may perform network and parsing work off actor, but every calibration lookup, reducer-state
replacement, estimate publication, and prune occurs after returning to `UsageStore`'s existing main-actor boundary.
Do not add a serial queue or second state-owning actor. The pure Core reducer remains `Sendable` and actor-independent;
only the app-owned mutable dictionary requires main-actor isolation.

Do not put raw reset dates in the dictionary key. The reducer state stores canonical short and long reset anchors and
compares incoming dates with a `120`-second equivalence tolerance. Tolerant date equality is not a valid `Hashable`
relation; keeping it inside the reducer avoids ambiguous keys.

Reuse or extract the account ownership logic already used by plan-utilization/reset detection. Do not implement a
second email-based shortcut. Token-account UUIDs, Codex visible-account ownership, and Claude OAuth ownership need the
same isolation guarantees as current history/reset features.

If a stable account discriminator cannot be formed, do not learn or show an estimate. Never put observations from an
unscoped account bucket into calibration.

Use the successful `ProviderFetchResult.strategyID` plus `strategyKind` as the fetch strategy identity. Do not key on
the user-facing `sourceLabel`: that label is presentation text and can be normalized or decorated by provider app code.
If the strategy ID is empty or otherwise unavailable, do not learn or show an estimate, matching an unscoped account.

Create or update estimates only from a successful in-process fetch result with its matching account/source context.
A startup cache, arbitrary `presentationSnapshot`, or menu `snapshotOverride` is not sufficient evidence. Override
cards show no quota-planning line in the first version; they must never inherit a live estimate from another account.

Decorate the matching long metric in one shared pass after provider metrics are built. The typed presentation contains
localized headline/supporting/accessibility text, does not overwrite `detailText`, and participates in redaction and
layout identity so primary, secondary, and extra windows behave consistently.

## Maximum-before-reset calculation

Let:

- `S` be the short duration in seconds;
- `sReset` be the next short reset;
- `lReset` be the next long reset;
- `T` be the reset-equivalence tolerance of `120` seconds;
- `shortRemaining` be the short remaining fraction clamped to `0...1` after eligibility validates its percentage.

Count only full short refills that occur more than `T` before the long reset:

```text
delta = lReset - sReset

if delta <= T:
    futureFullShortAllowanceCount = 0
else:
    futureFullShortAllowanceCount = ceil((delta - T) / S)

maximumFullSessionEquivalentsBeforeReset =
    shortRemaining + futureFullShortAllowanceCount
```

The current short-window remainder is fractional capacity, not an extra full window. A reset at `sReset` counts when
it is materially before the long reset. If `delta` is exactly one short duration, only the reset at `sReset` counts; a
second counts only when it is more than `T` before the long reset. Short and long resets within `T` are simultaneous.

`M` is a provider-capacity upper bound. It assumes immediate flat-out use of every allowance and ignores
`weeklyProgressWorkDays`, historical pace, weekends, sleep, and personal availability. That deliberate choice makes
the stranded verdict strong: if the weekly quota cannot be exhausted under `M`, it cannot be exhausted under a less
aggressive schedule. Existing `UsagePace` remains the personalized projection.

## Fundable full-session calculation

### Observation

After each successful eligible refresh, form one synchronized observation containing:

- capture time;
- short and long used percentages;
- short and long reset identities;
- provider/account/pair/strategy scope.

Within one short-window segment, compare the latest observation with the segment baseline:

```text
shortDelta = latest.shortUsedPercent - baseline.shortUsedPercent
longDelta  = latest.longUsedPercent  - baseline.longUsedPercent

longPercentPerFullShortAllowance = 100 * longDelta / shortDelta
fundableFullSessionEquivalents = longRemainingPercent / longPercentPerFullShortAllowance
```

Compute `longRemainingPercent` from the latest eligible observation as
`max(0, 100 - latest.longUsedPercent)`. Eligibility has already rejected values outside `0...100`, so this lower clamp
handles the exact exhausted boundary rather than sanitizing malformed provider data.

Example: if 40 percentage points of short usage correspond to 6 percentage points of weekly usage, one full short
allowance is estimated to cost `15%` of the weekly quota. With `9%` weekly remaining, the fundable capacity is
estimated at `0.6` full-session equivalents.

This measures the user's recently observed workload mix. It deliberately does not infer model-specific token prices
or ask a provider for undocumented conversion factors.

### Evidence gates

A segment may produce a candidate long cost only when:

- `shortDelta >= 20` percentage points;
- `longDelta >= 1` percentage point;
- both deltas are monotonic after allowing the `120`-second reset-identity tolerance and `0.5`-point percentage
  jitter;
- the later long usage is below `99.5%`; `99.5...100%` is saturation for candidate derivation;
- the candidate is finite and greater than zero. Values above `100` are valid: they mean the recently observed workload
  would exhaust a full long allowance before consuming one full short allowance.

The `20`/`1` gates let integer-quantized weekly sources accumulate a measurable change while still producing a useful
estimate during one active short window. They are initial product constants, not settings.

Maintain the current qualifying candidate plus the five most recently completed short-segment candidates inside the
current long window. Updating an active segment replaces its current candidate; it does not append another sample.
When a segment completes, append its qualifying candidate and evict the oldest completed candidate if the FIFO now
contains more than five.

A later observation in the `99.5...100%` saturation range cannot create or replace the active candidate. Retain any
earlier qualifying active and completed candidates, use the latest eligible long remainder for composition, and hide
the presentation at exact exhaustion.

Use the conventional median: sort candidates; choose the middle value for an odd count and the arithmetic mean of the
two middle values for an even count. Once two or more candidates exist, require every candidate's relative deviation
`abs(candidate - median) / median` to be at most `0.30`, inclusive. If any candidate fails, suppress the fundable
full-session estimate without deleting the outlier. New active candidates may stabilize as they update, and completed
outliers eventually age out through FIFO eviction. A single qualifying current or completed candidate is shown with
`≈`, because the feature is most useful before several five-hour cycles have completed.

Do not relax the dispersion limit when only two or three candidates exist. Early disagreement is weaker evidence, not
a reason to accept more variance. Revisit the fixed `0.30` threshold only with fixture or production evidence and a
separately reviewed confidence model.

No separate candidate-age limit applies inside one long window. The five-segment FIFO favors recent mix, while the
60-minute estimate freshness rule requires a recent eligible observation before any old candidate can be rendered.

Do not extrapolate through a capped long-window endpoint. A long quota at its limit reveals only that at least the
remaining capacity was consumed, not the full relative cost.

### Conservative reachability verdict

The numeric headline uses the candidate median. The verdict uses the full stable candidate range so a near-boundary
median cannot produce false certainty. Let `C` be the same current/completed candidate set that passed dispersion:

```text
if C.count < 2:
    reachability = insufficientEvidence
else:
    lowerFundable = longRemainingPercent / max(C)
    upperFundable = longRemainingPercent / min(C)

    if lowerFundable > maximumFullSessionEquivalentsBeforeReset:
        reachability = likelyStranded
    else if upperFundable <= maximumFullSessionEquivalentsBeforeReset:
        reachability = likelyReachable
    else:
        reachability = uncertain
```

`likelyStranded` means every stable observed conversion requires more short-window capacity than can become available.
`likelyReachable` means every stable observed conversion fits within the theoretical maximum. `uncertain` means the
observed range crosses the boundary. Use “likely” even for a unanimous range because future workload mix can change.
Do not show a verdict from one candidate, invent a fixed numeric guard band, or expose the internal range.

### Calibration state machine

For each scoped pair:

1. The first valid observation starts a segment and produces no fundable full-session value.
2. Treat an incoming reset within `120` seconds of its stored anchor as the same reset and retain the original anchor.
3. A monotonic observation with equivalent reset anchors updates or replaces the current candidate.
4. When the short reset moves later by more than `120` seconds, append the previous segment candidate only if it passed
   all gates, then start a new segment from the new observation. Completed candidates may continue to provide an
   estimate while the new active segment is learning.
5. Any non-equivalent long reset change, later or earlier, clears all candidates and starts fresh. A short reset that
   moves earlier by more than the tolerance is a discontinuity: discard the active candidate, retain completed
   candidates, start a new baseline, and set `requiresActiveRequalification`.
6. If short usage drops without a short reset advance, or long usage drops without a long reset advance beyond
   tolerance, discard the active candidate, retain completed candidates, start a new baseline, and set
   `requiresActiveRequalification`.
7. A qualifying candidate from the new active segment clears `requiresActiveRequalification`; until then, suppress
   the composed `N`, `M`, and verdict even if completed candidates remain.
8. A strategy or account change selects a different key; it never inherits the other key's observations. Returning to
   the original key before expiry may reuse it only after a new eligible observation confirms its reset anchors.
9. Missing/ineligible data and failed refreshes do not update, recover, or erase state. Expired keys are pruned after
   their long reset.
10. App termination discards all state.

Do not add a generic 15-minute reset-anchor slide. That can merge distinct calibration segments. A provider with
genuinely sliding reset identity needs an explicit descriptor policy, provider-side normalization, and separate
calibration tests before it can opt in.

The `0.5`-point percentage jitter tolerance may absorb rounding noise, but it must not turn a material decrease into
an increase or manufacture a positive delta. A decrease of at most that amount keeps the prior high-water value, while
a larger decrease invalidates the active segment. Tolerated decreases never lower the baseline or contribute positive
movement.

## Provider rollout

### First implementation

| Provider    | Pair shape                                                            | Required provider-specific work                                                                               |
| ----------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Codex       | Standard session/weekly pair from shared semantic lane classification | Extract the classifier to Core and use it from both the consumer projection and descriptor resolver.          |
| Claude      | Standard primary/secondary pair                                       | Opt in fixture-proven exact strategies; reject the synthetic five-hour placeholder and incomplete enrichment. |
| Antigravity | Multiple named five-hour/weekly groups in extras                      | Opt in fixture-proven exact strategies and pair by stable parser IDs; never collapse to the most-used group.  |

Later opt-ins require fixture-backed proof of shared metering semantics; cadence alone is insufficient.

## Privacy, storage, and diagnostics

- Keep calibration in memory; do not add preferences, migrations, files, `UserDefaults`, or history reuse.
- Do not log account discriminators, emails, organization names, raw percentages, or observation sequences.
- Debug logging may state provider, non-personal pair ID, and a coarse suppression reason such as `missingReset`,
  `insufficientMovement`, or `unstableCalibration`.
- The rendered text contains no identity and remains safe when personal-information hiding is enabled.

## Failure behavior

Fail closed to no planning line:

| Condition | Result |
| --- | --- |
| No qualifying/stable calibration, including discontinuity requalification | Hide and continue learning. |
| One qualifying candidate | Show `N` and `M`; omit the verdict. |
| Two or more stable candidates | Show the range-derived reachable, stranded, or uncertain verdict. |
| Unsupported, ambiguous, invalid, unscoped, stale, or exhausted long quota | Hide; do not learn from that observation. |
| `M == 0` with long quota remaining | Show `N`, explicit no-capacity copy, and a verdict only when evidence qualifies. |
| Ineligible successful refresh | Hide, preserve scoped state, and require a new eligible observation. |
| Provider refresh failure | Retain the last good block until the earlier of its 60-minute TTL and long reset. |
| Canonical long reset | Hide and discard prior-window calibration. |
| App relaunch | Clear in-memory calibration and relearn. |

No fallback may guess a reset from `resetDescription`, title text, another account, or a default duration.

## Required tests

### Core schedule and verdict tests

- Cover fractional/zero current remainder; reset order; the `120`-second boundary; exact and multiple short-duration
  separations; and independence from workday/history inputs.
- Cover one-candidate evidence, reachable/stranded/uncertain range boundaries including equality, unrounded
  comparison, and `M == 0`.

### Core calibration and eligibility tests

- Cover the exact `20`/`1` thresholds, formula, odd/even median, five completed-candidate FIFO plus the current
  candidate, dispersion, saturation, and valid long cost above `100`.
- Cover jitter/high-water behavior; short/long reset transitions; discontinuity requalification; and repeated,
  failed, or incomplete observations.
- Reject every invalid eligibility class, including malformed raw percentages that provider clamping might otherwise
  hide.
- Prove provider/account/group/strategy isolation, stable-reset reuse, and empty state after restart.
- Cover live/cached/unknown freshness, monotonic TTL, long-reset expiry, wake/clock rescheduling, generation guards, and
  main-actor serialization with injected clocks.

### Provider resolution tests

- Codex resolves its normalized semantic pair; Claude accepts only real approved-strategy sessions; Antigravity
  resolves every complete stable-ID group independently and in any order.
- Cover incomplete groups, live versus cached results under one strategy, coarse confidence, pair/metric collisions,
  raw malformed percentages, and descriptor absence.

### Menu tests

- Cover hidden, one-candidate, all verdict, and zero-capacity presentations on only the matching long row.
- Prove each Antigravity group receives its own pace/planning companion and view helpers do not recompute pace.
- Preserve existing detail, pace, reset, warnings, percent direction, and estimator inputs; override cards cannot
  inherit live estimates.
- Cover identity hiding, complete localization templates, fractional-`M` accessibility, three-line wrapping, redaction,
  and layout identity.

Prefer pure Core/model tests and provider fixtures. Do not use real accounts, browser-cookie imports, live provider
probes, Keychain reads, or AppKit status-bar automation for behavior that these seams can verify.

## Acceptance criteria

The feature is done when:

- A qualifying same-scope observation sequence adds correct approximate `N` and deterministic `M` values for Codex,
  Claude, and every complete Antigravity group without an app restart.
- Two or more stable candidates produce the conservative range-based reachability verdict; one candidate never does.
- Unsupported, ambiguous, freshness-expired, unscoped, and unstable cases show no planning line.
- Existing pace/detail behavior remains intact; no observation is persisted and no setting is added.
- Focused suites, `make test`, `make check`, and synthetic-data menu captures pass.
