# Global Low Power Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a non-destructive global low-power mode that clamps CodexBar's automatic provider, local cost, storage, and OpenAI Web background work while preserving manual refreshes.

**Architecture:** A pure `BackgroundWorkPowerPolicy` owns the 30-minute lower bound. `SettingsStore` persists one default-off toggle, and each automatic scheduling seam asks the shared policy for its effective interval. Manual entry points continue to bypass automatic cooldowns.

**Tech Stack:** Swift 6.2+, SwiftUI, Observation, Swift Testing, UserDefaults, Swift Package Manager

## Global Constraints

- macOS minimum remains 14.0.
- Low-power minimum automatic interval is exactly 1800 seconds.
- `backgroundWorkLowPowerModeEnabled` defaults to `false`.
- Do not rewrite `refreshFrequency` or disable cost/storage settings.
- Manual refresh remains immediate.
- Do not change Agent Sessions cadence.
- Add no dependency and no telemetry.
- User-facing review material remains available in Chinese.

---

### Task 1: Pure background power policy

**Files:**
- Create: `Sources/CodexBar/BackgroundWorkPowerPolicy.swift`
- Create: `Tests/CodexBarTests/BackgroundWorkPowerPolicyTests.swift`

**Interfaces:**
- Produces: `BackgroundWorkPowerPolicy.lowPowerMinimumInterval: TimeInterval`
- Produces: `BackgroundWorkPowerPolicy.automaticInterval(_:lowPowerModeEnabled:) -> TimeInterval?`

- [ ] **Step 1: Write the failing policy tests**

```swift
import Foundation
import Testing
@testable import CodexBar

struct BackgroundWorkPowerPolicyTests {
    @Test
    func `disabled mode preserves requested automatic intervals`() {
        #expect(BackgroundWorkPowerPolicy.automaticInterval(nil, lowPowerModeEnabled: false) == nil)
        #expect(BackgroundWorkPowerPolicy.automaticInterval(300, lowPowerModeEnabled: false) == 300)
        #expect(BackgroundWorkPowerPolicy.automaticInterval(3600, lowPowerModeEnabled: false) == 3600)
    }

    @Test
    func `enabled mode clamps automatic intervals to thirty minutes`() {
        #expect(BackgroundWorkPowerPolicy.automaticInterval(nil, lowPowerModeEnabled: true) == nil)
        #expect(BackgroundWorkPowerPolicy.automaticInterval(60, lowPowerModeEnabled: true) == 1800)
        #expect(BackgroundWorkPowerPolicy.automaticInterval(1800, lowPowerModeEnabled: true) == 1800)
        #expect(BackgroundWorkPowerPolicy.automaticInterval(3600, lowPowerModeEnabled: true) == 3600)
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run the repository's `swift test --filter BackgroundWorkPowerPolicyTests` command, with the documented local Command Line Tools compatibility flags when full Xcode is unavailable.

Expected: FAIL because `BackgroundWorkPowerPolicy` does not exist.

- [ ] **Step 3: Implement the minimal pure policy**

```swift
import Foundation

enum BackgroundWorkPowerPolicy {
    static let lowPowerMinimumInterval: TimeInterval = 30 * 60

    static func automaticInterval(
        _ requested: TimeInterval?,
        lowPowerModeEnabled: Bool) -> TimeInterval?
    {
        guard let requested else { return nil }
        guard lowPowerModeEnabled else { return requested }
        return max(requested, self.lowPowerMinimumInterval)
    }
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Expected: both policy tests pass.

### Task 2: Persist and expose the global setting

**Files:**
- Modify: `Sources/CodexBar/SettingsStoreState.swift`
- Modify: `Sources/CodexBar/SettingsStore.swift`
- Modify: `Sources/CodexBar/SettingsStore+Defaults.swift`
- Modify: `Sources/CodexBar/SettingsStore+MenuObservation.swift`
- Modify: `Tests/CodexBarTests/SettingsStoreCoverageTests.swift`

**Interfaces:**
- Consumes: `SettingsStore.noteBackgroundWorkSettingsChanged()`
- Produces: `SettingsStore.backgroundWorkLowPowerModeEnabled: Bool`
- Produces: `SettingsStore.effectiveOpenAIWebBatterySaverEnabled: Bool`

- [ ] **Step 1: Add failing settings persistence tests**

Add a test that creates isolated defaults, verifies the new key defaults to false and is absent, toggles it on, verifies `backgroundWorkSettingsRevision` increments once, reloads `SettingsStore`, and verifies the value persists. Also assert:

```swift
#expect(initial.effectiveOpenAIWebBatterySaverEnabled == false)
initial.backgroundWorkLowPowerModeEnabled = true
#expect(initial.effectiveOpenAIWebBatterySaverEnabled)
initial.backgroundWorkLowPowerModeEnabled = false
initial.openAIWebBatterySaverEnabled = true
#expect(initial.effectiveOpenAIWebBatterySaverEnabled)
```

- [ ] **Step 2: Run the focused settings test and verify RED**

Expected: FAIL because the properties do not exist.

- [ ] **Step 3: Add state loading, persistence, and observation**

Add `backgroundWorkLowPowerModeEnabled` beside existing background-related settings. Load it with:

```swift
let backgroundWorkLowPowerModeEnabled =
    userDefaults.object(forKey: "backgroundWorkLowPowerModeEnabled") as? Bool ?? false
```

The setter stores the value, logs only `enabled=0|1`, and calls `noteBackgroundWorkSettingsChanged()`. The effective web saver is the OR of the global and provider-specific values.

- [ ] **Step 4: Run the focused settings test and verify GREEN**

Expected: default, persistence, revision, and effective-web assertions pass.

### Task 3: Clamp provider and Adaptive refresh timers

**Files:**
- Modify: `Sources/CodexBar/UsageStore.swift`
- Modify: `Sources/CodexBar/UsageStore+AdaptiveRefresh.swift`
- Modify: `Tests/CodexBarTests/AdaptiveRefreshTimerTests.swift`

**Interfaces:**
- Consumes: `BackgroundWorkPowerPolicy.automaticInterval(_:lowPowerModeEnabled:)`
- Consumes: `SettingsStore.backgroundWorkLowPowerModeEnabled`

- [ ] **Step 1: Add failing timer tests**

Add fixed and Adaptive cases proving a requested 300-second fixed interval and an Adaptive 300-second decision both resolve to 1800 seconds when the global setting is on, while 3600 seconds remains unchanged. Keep existing sleep overrides test-only and separate from the policy's computed delay.

- [ ] **Step 2: Run the focused timer tests and verify RED**

Expected: low-power cases observe the old short delay.

- [ ] **Step 3: Apply the shared policy at all provider timer seams**

In `startTimer`, clamp `frequency.seconds` before creating the fixed timer. In `nextAdaptiveTimerSleepDuration`, clamp the policy decision before assigning `adaptiveRefreshScheduledAt` and before sleeping. Apply the same clamped value in `advanceAdaptiveTimerIfEarlier` and `normalRefreshIntervalForHeuristics` so scheduling metadata does not disagree with the actual timer.

- [ ] **Step 4: Run the focused timer tests and verify GREEN**

Expected: existing timer behavior stays green and low-power cases resolve to 1800 seconds.

### Task 4: Clamp local cost and storage scans

**Files:**
- Modify: `Sources/CodexBar/UsageStore.swift`
- Modify: `Sources/CodexBar/UsageStore+ProviderStorage.swift`
- Modify: `Tests/CodexBarTests/UsageStoreTokenRefreshCadenceTests.swift`
- Modify: `Tests/CodexBarTests/ProviderStorageFootprintTests.swift`

**Interfaces:**
- Consumes: `BackgroundWorkPowerPolicy.automaticInterval(_:lowPowerModeEnabled:)`
- Produces: `UsageStore.tokenFetchTTL(for:lowPowerModeEnabled:) -> TimeInterval?`
- Produces: `UsageStore.automaticStorageRefreshInterval(lowPowerModeEnabled:) -> TimeInterval`

- [ ] **Step 1: Add failing cadence and manual-refresh tests**

Extend token cadence table tests so five minutes becomes 1800 seconds only when low-power mode is enabled, manual remains nil, and one hour remains one hour. Add storage policy assertions for 300 versus 1800 seconds. Extend the existing manual storage refresh test by enabling global low-power mode and proving the explicit second refresh still sees a deleted directory immediately.

- [ ] **Step 2: Run focused token and storage tests and verify RED**

Expected: automatic token/storage intervals remain 300 seconds.

- [ ] **Step 3: Route automatic token and storage cooldowns through the shared policy**

Pass the global setting into `tokenFetchTTL`. Replace the storage constant comparison with `automaticStorageRefreshInterval(lowPowerModeEnabled:)`. Do not add a low-power guard to `refreshTokenUsageNow(force:)` or `refreshStorageFootprintsNow`.

- [ ] **Step 4: Run focused token and storage tests and verify GREEN**

Expected: automatic cooldowns clamp and explicit refreshes remain immediate.

### Task 5: Apply global saver to OpenAI Web and expose UI

**Files:**
- Modify: `Sources/CodexBar/UsageStore+OpenAIWeb.swift`
- Modify: `Sources/CodexBar/UsageStore+RefreshEnrichment.swift`
- Modify: `Sources/CodexBar/UsageStore+Logging.swift`
- Modify: `Sources/CodexBar/PreferencesGeneralPane.swift`
- Modify: `Sources/CodexBar/Providers/Codex/CodexProviderImplementation.swift`
- Modify: `Sources/CodexBar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Tests/CodexBarTests/CodexBackgroundRefreshCoalescingTests.swift`

**Interfaces:**
- Consumes: `SettingsStore.effectiveOpenAIWebBatterySaverEnabled`

- [ ] **Step 1: Add a failing OpenAI Web gate test**

Use existing refresh-policy test seams to set `backgroundWorkLowPowerModeEnabled = true`,
`openAIWebBatterySaverEnabled = false`, and verify a routine background Web refresh is suppressed while a forced
user refresh remains eligible.

- [ ] **Step 2: Run the focused Web test and verify RED**

Expected: routine Web refresh is still allowed.

- [ ] **Step 3: Wire effective saver and add localized controls**

Use `effectiveOpenAIWebBatterySaverEnabled` everywhere the runtime creates an `OpenAIWebRefreshPolicyContext`.
Add the General-pane toggle with the approved title/subtitle. Rename the provider-specific title to
`OpenAI web battery saver`. Keep the English literals as the built-in fallback and add audited Simplified Chinese
overrides; adding them to `en.lproj` would make every complete locale require an unaudited translation.

- [ ] **Step 4: Run focused Web/settings/UI tests and verify GREEN**

Expected: Web policy and persistence tests pass; UI source compiles.

### Task 6: Verification, local package, and handoff

**Files:**
- Modify only if needed: `docs/superpowers/specs/2026-07-30-global-low-power-mode-design.zh-CN.md`
- Create local artifact outside Git: `CodexBar-Low-Power-Local.app`

**Interfaces:**
- Consumes: all prior tasks

- [ ] **Step 1: Restore local-only compatibility exclusions before reviewing Git diff**

Restore the five temporarily excluded XCTest files. Confirm the only tracked source compatibility change retained for the local Command Line Tools build is intentionally excluded from the feature commit or split into a separate commit.

- [ ] **Step 2: Run format, lint, focused tests, and app build**

Run `swiftformat --lint`, `swiftlint`, all changed-area tests, and `swift build`. When full Xcode is unavailable, record the exact local compatibility flags and distinguish environment limitations from source failures.

- [ ] **Step 3: Inspect the final diff**

Confirm no credentials, account identifiers, local paths, build cache changes, Widget removal, or unrelated provider changes are tracked.

- [ ] **Step 4: Create focused commits with Codex attribution**

Commit implementation and documentation using repository conventions. Add a Codex/ChatGPT co-author trailer, not a Claude trailer.

- [ ] **Step 5: Build and ad-hoc sign a no-Widget local app**

Assemble the app from the exact committed executable and resources, disable Sparkle auto-update, omit the Widget only for this local artifact, sign with `codesign --sign -`, verify the signature, and save a copy under the user's visible project path.

- [ ] **Step 6: Back up and install**

Quit CodexBar, copy the current `/Applications/CodexBar.app` to a timestamped backup, install the local app, launch it, verify the menu appears, enable Low Power Mode, and confirm existing settings remain readable.

- [ ] **Step 7: Push the branch and prepare the upstream contribution**

Push `codex/global-low-power-mode` to `Carl723000/CodexBar`. Prepare a PR referencing #2508 with the root cause, behavior table, tests, and explicit note that the no-Widget packaging workaround is local-only.
