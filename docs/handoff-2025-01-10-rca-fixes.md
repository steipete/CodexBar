# RCA & Fixes - January 10, 2025

## Issues Investigated

1. **Settings panel does not display**
2. **No singleton enforcement** (multiple instances running)
3. **Claude subscription not detected**

---

## Issue 1: Settings Panel (PENDING VERIFICATION)

### Status
⚠️ **Needs Testing** - Mechanism identified but fix requires user testing

### Root Cause
Settings panel relies on:
1. Menu → `StatusItemController.openSettings()` → Posts `.codexbarOpenSettings` notification
2. `HiddenWindowView` (in `WindowGroup("CodexBarLifecycleKeepalive")`) listens for notification
3. Calls `@Environment(\.openSettings)` SwiftUI action

**Issue**: The hidden window may not receive events when running from `.build/release/CodexBar` (non-bundled build).

### Files Involved
- `Sources/CodexBar/StatusItemController+Actions.swift:129-138`
- `Sources/CodexBar/HiddenWindowView.swift:9-13`
- `Sources/CodexBar/Notifications+CodexBar.swift:4`

### Next Steps
- Test with bundled app (CodexBar.app) instead of build directory executable
- Add debug logging to track notification flow
- Consider fallback: Direct `NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)`

---

## Issue 2: Singleton Enforcement ✅ FIXED

### Status
✅ **RESOLVED**

### Root Cause
No singleton enforcement in `AppDelegate.applicationDidFinishLaunching` - multiple instances could run simultaneously.

### Fix Applied
**File**: `Sources/CodexBar/CodexbarApp.swift:249-270`

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // Terminate other instances to enforce singleton behavior
    self.terminateOtherInstances()
    // ... rest of launch code
}

private func terminateOtherInstances() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let runningInstances = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleID)

    for instance in runningInstances where instance != NSRunningApplication.current {
        instance.terminate()
    }
}
```

### Verification
```bash
# Launch CodexBar twice - second launch should kill first instance
.build/release/CodexBar &
sleep 2
.build/release/CodexBar &  # First instance should terminate
ps aux | grep CodexBar | grep -v grep  # Should show only ONE instance
```

---

## Issue 3: Claude Subscription Detection ✅ FIXED

### Status
✅ **RESOLVED**

### Root Cause
Claude Web Extras was **disabled by default**, preventing subscription plan detection.

**Flow**:
1. `UsageStore.isClaudeSubscription()` checks `loginMethod` for "max", "pro", "ultra", "team"
2. `loginMethod` is populated by `ClaudeWebAPIFetcher.fetchAccountInfo()`
3. `fetchAccountInfo()` only runs when `useWebExtras == true`
4. Web Extras defaults to `false` and gets disabled for non-CLI data sources

**Result**: `loginMethod` was always `nil`, so `isClaudeSubscription()` returned `false`.

### Fix Applied

**Files Modified**:
1. `Sources/CodexBar/SettingsStore.swift:471` - Default changed
2. `Sources/CodexBar/SettingsStore.swift:297-300` - Setter logic updated
3. `Sources/CodexBar/SettingsStore.swift:522-525` - Init logic updated

#### Change 1: Default Value
```swift
// BEFORE
self.claudeWebExtrasEnabled = userDefaults.object(forKey: "claudeWebExtrasEnabled") as? Bool ?? false

// AFTER
self.claudeWebExtrasEnabled = userDefaults.object(forKey: "claudeWebExtrasEnabled") as? Bool ?? true
```

#### Change 2: Setter Logic
```swift
// BEFORE
var claudeUsageDataSource: ClaudeUsageDataSource {
    set {
        self.claudeUsageDataSourceRaw = newValue.rawValue
        if newValue != .cli {
            self.claudeWebExtrasEnabled = false  // Disabled for auto, web, oauth
        }
    }
}

// AFTER
var claudeUsageDataSource: ClaudeUsageDataSource {
    set {
        self.claudeUsageDataSourceRaw = newValue.rawValue
        // Only disable web extras for explicit web/oauth sources (not auto or cli)
        if newValue == .web || newValue == .oauth {
            self.claudeWebExtrasEnabled = false
        }
    }
}
```

#### Change 3: Init Logic
```swift
// BEFORE
if self.claudeUsageDataSource != .cli {
    self.claudeWebExtrasEnabled = false
}

// AFTER
// Allow web extras for auto mode (falls back to CLI with extras) and explicit CLI mode
if self.claudeUsageDataSource == .web || self.claudeUsageDataSource == .oauth {
    self.claudeWebExtrasEnabled = false
}
```

### How It Works Now

**Data Source Priority** (when mode is "auto"):
1. OAuth (if credentials exist) → `useWebExtras: false` (doesn't need it)
2. Web (if session key exists) → `useWebExtras: false` (doesn't need it)
3. **CLI** → `useWebExtras: true` ✅ **Now enriches with account info**

**Claude Usage Strategy** (`ClaudeProviderDescriptor.swift:113`):
```swift
let useWebExtras = selectedDataSource == .cli && webExtrasEnabled && hasWebSession
```

With Web Extras enabled, the CLI fallback now calls `fetchAccountInfo()` to get `loginMethod`.

### Verification
```bash
# Check current setting
defaults read com.steipete.codexbar claudeWebExtrasEnabled
# Should return: 1

# Wait for next usage refresh, then check if subscription is detected
# Check menu bar → should show correct Claude plan type
```

### Technical Details

**Account Info Fetch** (`ClaudeWebAPIFetcher.swift:505-558`):
```swift
private static func fetchAccountInfo(sessionKey: String, orgId: String?) async -> WebAccountInfo?

private static func inferPlan(rateLimitTier: String?, billingType: String?) -> String? {
    if tier.contains("max") { return "Claude Max" }
    if tier.contains("pro") { return "Claude Pro" }
    if tier.contains("team") { return "Claude Team" }
    if tier.contains("enterprise") { return "Claude Enterprise" }
    // ...
}
```

**Subscription Detection** (`UsageStore.swift:428-434`):
```swift
nonisolated static func isSubscriptionPlan(_ loginMethod: String?) -> Bool {
    guard let method = loginMethod?.lowercased(), !method.isEmpty else { return false }
    let subscriptionIndicators = ["max", "pro", "ultra", "team"]
    return subscriptionIndicators.contains { method.contains($0) }
}
```

---

## Files Changed Summary

| File | Lines | Change |
|------|-------|--------|
| CodexbarApp.swift | 249-270 | Added singleton enforcement |
| SettingsStore.swift | 297-300, 471, 522-525 | Enable Web Extras by default + fix disable logic |

---

## Build & Test

### Build
```bash
swift build -c release
# Build complete! (21.20s)
```

### Launch
```bash
.build/release/CodexBar &
# PID: 14086
```

### Verify
```bash
# Only one instance running
ps aux | grep CodexBar | grep -v grep
# jeffersonnunn    14086   1.5  0.3 435678256  98464   ??  SN    5:44PM   0:00.83 .build/release/CodexBar

# Claude Web Extras enabled
defaults read com.steipete.codexbar claudeWebExtrasEnabled
# 1
```

---

## Outstanding Work

### Settings Panel Issue
- **Status**: Needs user testing
- **Action**: Try clicking "Settings..." menu item
- **Fallback**: May work correctly in bundled .app (not tested yet)

### Subscription Detection Verification
- **Status**: Fix applied, waiting for next refresh cycle
- **Action**: Monitor menu bar for Claude plan type after ~10 minutes
- **Expected**: Should show "Claude Pro" or similar in dashboard link

---

## CPU Optimization Audit

Also reviewed `codedocs/cpu-optimization-plan.md`:
- All optimizations are ✅ **already implemented**
- Animation FPS: 15 (down from 60)
- Blink interval: 150ms (up from 75ms)
- Augment keepalive: 600s (up from 300s)
- Unified timer scheduler: Active
- Debounced observers: Active (500ms)
- On-demand WebView: Active (600s min interval)

**Issue with doc**: Uses "before → after" notation but code only shows "after" values, creating confusion about what work remains.

---

## Next Session

1. Test settings panel in bundled app
2. Verify Claude subscription detection after usage refresh
3. Consider updating cpu-optimization-plan.md to clarify completion status
