---
summary: "Accepted design for opt-in predictive pace warning notifications."
read_when:
  - Reviewing or implementing predictive quota notifications
  - Changing pace-driven notification cooldown or recovery behavior
---

# Predictive pace warning notifications

**Status:** accepted design; not implemented
**Date:** 2026-07-01
**Issue:** #1299

## Decision

CodexBar may add the bounded, default-off warning below in a separate implementation PR. Send one alert per risk
episode, not hourly reminders. Re-arm only after a successful, authoritative observation says the quota will last until
reset. Keep the existing pace model as the only forecast authority and keep episode state in memory. Do not add
configurable thresholds or additional provider scope in the first version.

## Why this is a decision, not an implementation PR

`VISION.md` requires sign-off for new features. The trigger mechanics are straightforward, but notification noise, provider scope, cooldown behavior, and default state are product choices. PR #1789 already changes pace presentation, historical confidence settings, and localization; combining proactive notifications with it would make both decisions harder to review.

## Accepted behavior

### Scope and default

- Add one preference: **Predictive pace warnings**, default off.
- Evaluate Codex and Claude only.
- Evaluate session and weekly windows only.
- Do not change existing threshold or depleted/restored notifications.

### Eligibility

Evaluate only after a provider refresh completed successfully and produced a current `UsagePace` for the window. A window is warning-eligible only when all conditions hold:

- `willLastToReset == false`.
- `etaSeconds` exists and is greater than zero.
- If `runOutProbability` exists, it is at least `0.5`.
- The provider, account, and window are all identifiable enough to form a stable in-memory key.

A missing probability does not suppress a warning because linear/workday pace does not produce one. A probability below `0.5` does suppress it because the historical model is explicitly reporting low confidence.

### State machine

Key state by provider, stable account discriminator, and window. Do not share state across accounts.

The key must include the reset-window identity so a new quota window cannot inherit the previous window's warning state.
For each key:

1. First eligible observation may notify; this is already a forecast derived from history/current-window progress, not an ordinary percentage transition.
2. After notifying, suppress every later observation while that risk episode remains active. Elapsed time alone never
   permits a repeat.
3. A successful observation where the pace recovers (`willLastToReset == true`) re-arms the key. A later relapse may
   notify once.
4. Low-confidence risk, missing pace, missing window, failed refresh, or incomplete provider enrichment neither notifies
   nor counts as recovery. Preserve current state until a successful, authoritative observation arrives.
5. A new reset-window identity starts with fresh state. Prune expired window keys rather than carrying episode state
   across resets.
6. Keep this state in memory only. App restart resets episodes; do not add persisted notification history.

### Copy and privacy

Use the existing notification delivery path and sound preference. Suggested copy:

- Title: `<Provider> <window> pace warning`
- Body without visible identity: `At the current pace, this quota may run out in <duration>, before it resets.`
- Body with visible identity: prefix the existing redaction-aware account label.

When personal information is hidden, do not include email, organization, workspace, plan, or other identity fields. Account discrimination may remain local internal state but must not be logged or rendered as notification text.

## Non-goals

- Default-on or opt-out warnings.
- Providers other than Codex and Claude.
- Daily, monthly, credits, spend, or extra rate windows.
- New probability or ETA modeling.
- User-configurable probability thresholds or cooldown duration.
- Persistent warning history across launches.
- Changes to #1789's headroom label, historical-week control, or pace model.

## Implementation seams after approval

- A pure evaluator/state reducer accepting provider, account discriminator, reset-window identity, pace, and prior state.
- A small `UsageStore` integration after successful snapshot/pace calculation, separate from static threshold transition state.
- One default-off `SettingsStore` value and one General notifications control.
- Localized notification title/body through the existing presenter.
- No new dependency and no provider fetch changes.

## Required tests

- Default is off; migration does not silently enable existing users.
- Codex/Claude session and weekly are eligible; all other provider/window combinations are ignored.
- `willLastToReset == true`, missing/non-positive ETA, and probability below `0.5` do not notify.
- Nil probability remains eligible.
- Provider/account/window keys are isolated.
- Same at-risk key never repeats merely because time passes.
- A successful healthy observation re-arms the key; missing, low-confidence, and failed/incomplete observations do not.
- A new reset-window identity has independent state and expired identities are pruned.
- Restart/new evaluator has no persisted episode state.
- Hidden-personal-info copy omits identity; visible copy uses only the provider-owned account label.
- Existing threshold and depleted/restored notification tests remain unchanged and green.

## Tradeoffs

- Default off limits surprise and notification fatigue, but reduces discovery.
- One alert per risk episode minimizes notification fatigue, but a sustained forecast is not repeated until it first
  recovers and then relapses.
- In-memory state is simple and privacy-preserving, but a relaunch can produce another warning.
- Restricting scope to Codex and Claude leaves other providers out until their pace and account identity semantics are reviewed.

## Recorded product choice

Approved: default off; Codex/Claude; session/weekly; one alert per provider/account/reset-window risk episode;
authoritative recovery re-arms; in-memory state. Hourly repeats are rejected.
