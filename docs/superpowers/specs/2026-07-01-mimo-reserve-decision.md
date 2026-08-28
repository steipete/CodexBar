---
summary: "Decision brief for pace and reserve reporting on Xiaomi MiMo token plans."
read_when:
  - Designing MiMo reserve or deficit text
  - Changing MiMo token-plan period mapping
---

# MiMo reserve reporting

**Status:** accepted fail-closed evidence contract; not implemented
**Issue:** [#1205](https://github.com/steipete/CodexBar/issues/1205)
**Date:** 2026-07-01

## Problem

CodexBar shows MiMo token usage and the plan's current period end, but does not show whether consumption is in reserve or
deficit. Shared pace math requires both the used percentage and a trustworthy window duration. MiMo's observed plan
response supplies the former and an end timestamp, but not the period start, duration, or billing cadence.

## Verified constraints

- MiMo sells monthly and annual token plans. Plan validity and token-credit reset cadence are not interchangeable.
- The redacted live response documented in [#1205](https://github.com/steipete/CodexBar/issues/1205) includes plan code,
  plan name, current period end, expiry, and auto-renew fields. It does not include a start timestamp, duration, or
  monthly/annual cadence discriminator.
- The usage response provides token used, limit, and percentage. Current main therefore maps a primary `RateWindow` with
  `resetsAt` and `windowMinutes == nil`.
- Shared pace calculations intentionally return no reserve/deficit result when window duration is unknown.
- Closed PR [#1310](https://github.com/steipete/CodexBar/pull/1310) inferred 30 or 31 days from the period end. That
  misclassifies annual plans during their final month and treats calendar proximity as a data contract.
- Shared pace presentation owns reserve/deficit calculations. MiMo must not bypass it with provider-specific math.
- PR [#1565](https://github.com/steipete/CodexBar/pull/1565) concerns MiMo cookie import only; it does not supply
  missing cadence data.

## Options

### A. Wait for an authoritative window — accepted

Keep `windowMinutes` nil. Enable reserve text only when a documented response supplies period start/duration, an
unambiguous cadence, or a separate token-credit reset contract.

Benefits: correct for monthly and annual plans, preserves shared pace semantics, and avoids confident but wrong reserve
text. Cost: #1205 remains visibly unsupported until upstream evidence exists.

### B. Infer one month from the reset timestamp

Set 30 or 31 days based on the current date and period end.

Rejected: a reset's proximity does not prove its duration. It fails for annual validity, final-month annual plans,
calendar-month boundaries, delayed refreshes, and reset schedules that differ from billing validity.

### C. Add a user-selected cadence

Let users choose monthly or annual in Preferences and derive a duration locally.

Not recommended: this adds persistent provider configuration, still cannot prove whether credits reset monthly within an
annual plan, and makes incorrect reserve text look authoritative.

### D. Learn duration from consecutive observations

Persist prior reset timestamps and infer the next duration after a rollover.

Not recommended as the initial contract: it withholds pace until a rollover, fails when the service changes or extends a
period, and turns historical coincidence into authority. It could become a separately approved heuristic with explicit
confidence and expiry rules.

## Accepted contract

1. Preserve MiMo's used percentage and `resetsAt` exactly as received.
2. Keep `windowMinutes` nil while cadence is unknown; shared reserve/deficit text stays absent.
3. Never derive duration from days remaining, plan validity, plan price, or plan-name text.
4. If upstream adds `periodStart`, compute duration from start to end and reject non-positive or implausible intervals.
5. If upstream adds a cadence enum, map only documented values and leave unknown values nil.
6. Annual-plan support needs explicit proof of the token-credit reset window, not only subscription expiry.
7. Use shared `UsagePace` and menu-card presentation once the window is authoritative; no MiMo-specific reserve formula.
8. Treat missing, malformed, contradictory, or undocumented period evidence identically: fail closed without reserve or
   deficit text.

## Proof required before implementation

- Redacted monthly-plan detail and usage responses.
- Redacted annual-plan detail and usage responses outside and inside the final month.
- Public documentation or repeated live evidence distinguishing subscription validity from token-credit reset cadence.
- Packaged-app screenshots for monthly and annual plans showing correct reserve/deficit text and reset time.

## Acceptance tests

- Unknown cadence keeps `windowMinutes` and reserve text nil.
- Monthly and annual fixtures cannot be distinguished from `planCode` or `planName` alone.
- A proven start/end window maps to the shared pace model without provider-specific arithmetic.
- Final-month annual and credit-reset fixtures do not become 30/31-day windows by proximity.
- Invalid, reversed, or unknown period fields fail closed.
- `make check` and `make test` pass on the exact implementation head.

## Decision

CodexBar accepts the fail-closed contract above. This decision does not authorize runtime inference or change current MiMo
behavior: `windowMinutes` remains nil and reserve/deficit text remains absent until authoritative evidence satisfies the
contract. Issue [#1205](https://github.com/steipete/CodexBar/issues/1205) stays open for that evidence and a separately
reviewed implementation. The next useful input is an annual-plan payload plus an authoritative token-credit reset source.
