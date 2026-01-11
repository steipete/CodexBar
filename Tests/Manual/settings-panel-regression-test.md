# Settings Panel Regression Test

**Date Created:** 2026-01-10
**Bug Fixed:** Settings panel not opening in non-bundled builds
**Root Cause:** `@Environment(\.openSettings)` fails in `.build/release/CodexBar`
**Fix:** Added `NSApp.sendAction(Selector(("showPreferencesWindow:")))` fallback

## Purpose

Prevent regression of Settings panel opening functionality across different build configurations.

## When to Run

- After any changes to Settings/Preferences UI code
- After changes to menu bar or status item code
- Before each release
- When testing new macOS versions

## Test Matrix

| Build Type | Expected Behavior | Risk Level |
|------------|-------------------|------------|
| Non-bundled (`.build/release`) | Settings opens via selector fallback | High (primary fix) |
| Bundled app (`.app`) | Settings opens (watch for double-open) | Medium (regression risk) |
| Debug build | Settings opens | Low |

## Test Procedure

### Prerequisites
```bash
# Ensure CodexBar is NOT running
killall CodexBar 2>/dev/null || true

# Verify git state
git status
```

### Test 1: Non-bundled Build (Critical)

**Purpose:** Verify the primary fix works

```bash
# Build release executable
swift build -c release

# Run non-bundled
.build/release/CodexBar &
sleep 2
```

**Steps:**
1. Click CodexBar menu bar icon
2. Select "Settings..."
3. **Expected:** Settings window opens immediately
4. **Check:** Window title is "Settings" or "Preferences"
5. **Check:** General tab is selected by default

**Result:** [ ] PASS / [ ] FAIL

**If FAIL:**
- Does menu item appear? (check `StatusItemController+Menu.swift`)
- Check Console.app for errors
- Run with `CODEXBAR_LOG_LEVEL=debug` and check logs

---

### Test 2: Tab Selection

**Purpose:** Verify `preferencesSelection.tab` is respected

**Steps:**
1. Close Settings if open
2. Select menu → "Settings..." → **Expected:** General tab
3. Close Settings
4. Select menu → "About CodexBar" → **Expected:** About tab
5. Close Settings
6. Click Settings again → **Expected:** Returns to General tab

**Result:** [ ] PASS / [ ] FAIL

**If FAIL:**
- Check if `preferencesSelection.tab` is being set correctly
- Verify `PreferencesView` respects the selection

---

### Test 3: Bundled App (Regression Check)

**Purpose:** Verify no double-window opens

```bash
# Build bundled app (if script exists)
# OR: open existing CodexBar.app

open CodexBar.app
sleep 2
```

**Steps:**
1. Click menu → "Settings..."
2. **Expected:** ONE Settings window opens
3. **Check:** No second window appears after 500ms delay
4. **Check:** Window is responsive and fully loaded

**Result:** [ ] PASS / [ ] FAIL

**Known Risk:** Medium - both notification and selector might fire
**Mitigation:** Selector is idempotent, double-open unlikely but possible

---

### Test 4: Repeated Opens

**Purpose:** Verify no memory leaks or window stacking

**Steps:**
1. Open Settings → Close → Repeat 5 times
2. **Expected:** Each open/close cycle works cleanly
3. **Check:** Memory usage stable (Activity Monitor)
4. **Check:** No duplicate windows in Window menu

**Result:** [ ] PASS / [ ] FAIL

---

### Test 5: Edge Cases

**5a: Settings Already Open**
1. Open Settings window
2. Click menu → "Settings..." again
3. **Expected:** Existing window brought to front (no duplicate)

**5b: Different Tabs**
1. Open Settings → General tab
2. Close Settings
3. Menu → "About CodexBar"
4. **Expected:** Settings opens to About tab

**5c: Multiple Displays**
(If available)
1. Move Settings window to secondary display
2. Close it
3. Reopen Settings
4. **Expected:** Opens on secondary display (window frame remembered)

**Results:**
- 5a: [ ] PASS / [ ] FAIL
- 5b: [ ] PASS / [ ] FAIL
- 5c: [ ] PASS / [ ] FAIL / [ ] N/A

---

## Automated Test Potential

**Current Status:** Manual only (UI interaction required)

**Future Automation Ideas:**
- XCUITest for bundled app
- AppleScript to trigger menu items
- Accessibility API to verify window opened

**Blockers:**
- Non-bundled builds don't support XCUITest
- AppleScript requires Accessibility permissions
- Menu bar apps not standard app structure

---

## Failure Triage

| Symptom | Likely Cause | Debug Steps |
|---------|--------------|-------------|
| Settings doesn't open at all | Notification AND selector both fail | Check Console.app, verify `showPreferencesWindow:` responder chain |
| Settings opens twice | Both notification and selector succeed | Expected in bundled apps, acceptable trade-off |
| Wrong tab selected | `preferencesSelection.tab` not updated | Check `StatusItemController+Actions.swift:131` |
| Window appears off-screen | Saved frame invalid | Delete window frame from UserDefaults |

---

## Related Files

| File | Purpose |
|------|---------|
| `Sources/CodexBar/StatusItemController+Actions.swift:129-141` | Fix implementation |
| `Sources/CodexBar/HiddenWindowView.swift:9-13` | Notification receiver (SwiftUI path) |
| `Sources/CodexBar/Notifications+CodexBar.swift:4` | Notification name definition |
| `Sources/CodexBar/CodexbarApp.swift:57-64` | Settings scene definition |

---

## Acceptance Criteria

**ALL of the following must PASS:**
- [ ] Test 1 (Non-bundled) PASS
- [ ] Test 2 (Tab selection) PASS
- [ ] Test 3 (Bundled app) PASS - no double-open
- [ ] Test 4 (Repeated opens) PASS
- [ ] Test 5a-5c (Edge cases) PASS or N/A

**If ANY test FAILS:**
1. Document failure in issue tracker
2. Revert commit if blocking release
3. Debug using triage guide above
4. Re-test after fix

---

## Changelog

| Date | Change | Tester |
|------|--------|--------|
| 2026-01-10 | Initial test plan created | Auto-generated |
|  |  |  |
